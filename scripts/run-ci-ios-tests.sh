#!/bin/bash
#
# Merge-gate fixture plus the iOS Simulator test run.
#
# Every sshd instance runs unprivileged: as the invoking user, on a loopback
# high port, out of one disposable directory. No sudo, no system SSH service,
# no machine state to undo. `SetEnv HOME=` gives each session an isolated home
# so nothing here can reach a real herdr socket, and a forced POSIX-sh wrapper
# puts a herdr stub ahead of PATH so an explicit start can never start or talk
# to a live server. `SetEnv TMUX_TMPDIR=` does the same for tmux: every fixture
# session's `tmux` reaches a private server in this run's directory, never the
# invoking account's own. The weak-network route is unprivileged for the same
# reason: a TCP proxy in front of one sshd, steered per test, rather than
# `pfctl` or a machine-wide Network Link Conditioner.
#
# One exception. macOS cannot verify a password without root, and an
# unprivileged sshd can only authenticate the account it already runs as, whose
# password CI does not know. The two real-password tests therefore need a
# disposable account and one root-owned sshd, provisioned only when passwordless
# sudo is available. Merge CI demands it (WAYCAR_CI_MANDATORY=1) unless the
# runner opts out with WAYCAR_CI_PASSWORD_FIXTURE=0, as a developer's own Mac
# serving as the CI runner must, since the fixture creates a macOS account. A
# laptop without passwordless sudo, or an opted-out runner, still runs twelve
# of the thirteen mandatory behaviours, and the script says loudly which one it
# left out.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

ci_lane="${WAYCAR_CI_LANE:-app}"
case "$ci_lane" in
    app | package) ;;
    *)
        echo "WAYCAR_CI_LANE must be app or package, got: $ci_lane" >&2
        exit 2
        ;;
esac

# A pending Xcode first-launch setup makes every `simctl` call hang (WAY-505),
# and every macOS update leaves it pending. Heal it once through passwordless
# sudo, or fail in seconds and name the command.
"$repo_root/scripts/check-xcode-first-launch.sh"

# The gate must leave the worktree byte-identical: this workflow treats a clean
# worktree as a verification precondition, so a stray `__pycache__` beside the
# Python fixtures is a standing false signal. `.gitignore` covers it too; this
# stops it being written in the first place.
export PYTHONDONTWRITEBYTECODE=1

# Fixture ports are a contiguous block that a run claims at startup rather than
# twenty fixed numbers every run shares. Fixed numbers made this script a
# machine-wide mutex: whichever run started second failed its port preflight and
# could only wait for the first to finish.
#
# assign_port_block below is the one place the ports are named; sshd configs,
# the impairment proxy's arguments and the JSON handed to the tests all read the
# variables it sets, so moving the base moves the whole fixture.

# Must equal the number of ports assign_port_block sets; assign_port_block
# asserts that itself rather than trusting this comment.
port_block_size=20
# The historical block. A run that finds the machine idle still lands exactly
# here, so the common case is unchanged.
port_block_base_default=55222
# How many disjoint blocks the machine hands out before it refuses to guess.
port_block_count=8
# Pin a block explicitly, for a caller that would rather not negotiate.
port_block_base_override="${WAYCAR_CI_PORT_BASE:-}"

# Cross-run coordination lives here: one owned lock per port block, Simulator,
# or account-allocation critical section. A short-lived atomic claim guard
# serializes owner publication, stale reclamation, and token-checked release.
# Ports still decide whether a block is usable; these locks only let a run say
# what it holds, and let the next run tell "someone is working" apart from
# "something crashed".
lock_root=/tmp/waycar-ci-locks
run_lock_dir=""
device_lock_dir=""
account_lock_dir=""
active_claim_guard=""
active_resource_lock=""
lock_owner_token="$$-$(uuidgen)"
lock_owner_start="$(ps -o lstart= -p "$$" | sed 's/^ *//; s/ *$//')"

# AF_UNIX paths cap at 104 bytes on macOS and the fixture nests herdr sockets
# several directories deep, so anchor at /tmp: the per-user TMPDIR alone is
# already 69 characters and overflows the limit.
fixture_dir="$(mktemp -d /tmp/waycar-ci.XXXXXX)"
app_derived_data_path="$fixture_dir/AppDerivedData"
package_derived_data_path="$fixture_dir/PackageDerivedData"
# Stable SourcePackages tree for the app lane. Hosted CI restores this via
# actions/cache so libghostty's XCFramework is not re-fetched every run.
# Package-lane builds have no remote SwiftPM deps and leave this unused.
source_packages_dir="${WAYCAR_CI_SOURCE_PACKAGES_DIR:-$repo_root/.ci/source-packages}"
diagnostic_run_id="${GITHUB_RUN_ID:-local-$$}"
diagnostic_attempt="${GITHUB_RUN_ATTEMPT:-1}"
diagnostic_root="${RUNNER_TEMP:-/tmp}/waycar-ci-diagnostics-$diagnostic_run_id-$diagnostic_attempt"
xcodebuild_build_timeout_seconds="${WAYCAR_XCODEBUILD_BUILD_TIMEOUT_SECONDS:-900}"
xcodebuild_test_timeout_seconds="${WAYCAR_XCODEBUILD_TEST_TIMEOUT_SECONDS:-600}"
fixture_username="$(id -un)"
fixture_home="$fixture_dir/home"
modern_pid=""
post_quantum_pid=""
legacy_pid=""
restricted_pid=""
stall_pid=""
streamlocal_global_policy_pid=""
streamlocal_key_policy_pid=""
jump_target_pid=""
jump_forwarding_denied_pid=""
pairing_pid=""
pairing_mismatched_pid=""
password_pid=""
fake_herdr_pid=""
weak_network_pid=""
core_pid=""
codex_pid=""
host_load_pid=""
simulator_udid=""
simulator_destination=""
# Set once this run has booted (or begun booting) its simulator; until then
# destination recovery leaves the boot to wait_for_simulator_boot.
simulator_boot_started=0
simulator_environment_variables=()
simulator_listing=""

# The herdr-core fixture (WAY-519): the pinned release, installed into a scratch
# HOME of its own, behind its own user-mode sshd. The HOME lives inside
# fixture_dir and stays short: herdr-core keeps its socket under it, and a
# socket path over 103 bytes (macOS) makes it refuse to start. Everything that
# touches the core runs with `env -i`, so no HERDR_*, HC_* or TMUX variable of
# the account running this script reaches it.
core_home="$fixture_dir/hc"
core_path=/usr/bin:/bin:/usr/sbin:/sbin
core_binary="$core_home/.local/bin/herdr-core"
core_fixture_configuration_base64=""

# Codex's managed daemon needs its complete npm package (not a bare binary).
# Its advertised socket is under this scratch HOME, but the physical socket
# and startup lock are hashed paths in /tmp/codex-daemon-<uid> (design X2).
# Record only our exact target; never clean that shared directory by glob.
codex_home="$fixture_dir/cx"
codex_path="$codex_home/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
codex_binary="$codex_home/.local/bin/codex"
codex_physical_socket=""
codex_fixture_configuration_base64=""

# OpenCode 2's shared server, from the pinned npm platform package, under a
# scratch HOME that also holds every XDG directory, the registration with its
# password and the model stand-in. It listens on a fixture-block port, never
# the default 49374 a developer's own server may hold. The path is canonical
# (macOS /tmp is /private/tmp), so the folders the server reports are the ones
# the suite asks for, and cleanup matches it in each process's command line or
# environment.
opencode_home="$(cd "$fixture_dir" && pwd -P)/oc"
opencode_path="$opencode_home/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
opencode_binary="$opencode_home/.local/bin/opencode"
opencode_pid=""
opencode_fixture_configuration_base64=""

# Zellij's pin and every runtime path stay inside this short scratch HOME.
# In particular, its contract_version_1 sockets must fit macOS's sun_path.
# Canonicalize /tmp (macOS /private/tmp) for exact executable-path checks.
zellij_home="$(cd "$fixture_dir" && pwd -P)/zj"
zellij_socket_dir="$zellij_home/s"
zellij_path="$zellij_home/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
zellij_binary="$zellij_home/.local/bin/zellij"
zellij_pid=""
zellij_fixture_configuration_base64=""

# The tmux backend fixture (ADR 0026): the runner's tmux, linked into the
# fixture PATH, serving a private server under this directory. tmux_binary is
# whichever binary serves that server now; the matrix below swaps it.
tmux_binary=""
tmux_version=""
tmux_tmpdir=""
tmux_fixture_available=0
# The pinned tmux releases (scripts/build-ci-tmux.sh) the suite runs against
# after the runner's own tmux, as parallel arrays: version, binary.
tmux_matrix_versions=()
tmux_matrix_binaries=()

# The privileged password fixture, provisioned only when sudo -n works.
password_username=""
password_secret=""
password_home=""
password_uid=550
password_fixture_available=0
password_user_cleanup_needed=0
password_ssh_sacl_added=0
password_pid_file="$fixture_dir/sshd-password.pid"
password_log="$fixture_dir/sshd-password.log"
# sysadminctl transcript from create_password_user, preserved with the other
# fixture logs and scrubbed of the account password before anything reads it.
sysadminctl_log="$fixture_dir/sysadminctl.log"
password_log_printed=0

# Merge CI must run the complete mandatory matrix; a laptop need not.
mandatory_matrix=0
case "${WAYCAR_CI_MANDATORY:-${CI:-}}" in
    1 | true | TRUE) mandatory_matrix=1 ;;
esac

unprivileged_sshd_pids=()

run_xcodebuild() {
    local label=$1
    local timeout_seconds=$2
    local output_log=$3
    local safe_label
    local status=70
    local started_at=$SECONDS
    local action
    local attempt
    local attempt_log
    local backoff
    local needs_recovery=0
    local failed_udid="$simulator_udid"
    local working_directory="$repo_root"
    local index
    local -a arguments=()
    local -a runner=(xcodebuild)
    shift 3

    safe_label=$(printf '%s' "$label" | tr -cs 'A-Za-z0-9._-' '-')
    echo "::group::$label"
    # build-for-testing already resolved packages. Repeating that on
    # test-without-building is the half-minute of redundant work this flag
    # removes; it does not skip plugin validation or change the resolved pin.
    if [[ "${1:-}" == "test-without-building" ]]; then
        action=$1
        shift
        set -- "$action" -disableAutomaticPackageResolution "$@"
        echo "==> $label: skipping automatic package resolution"
    fi
    if [[ "$ci_lane" == "app" ]]; then
        mkdir -p "$source_packages_dir"
        set -- "$@" -clonedSourcePackagesDirPath "$source_packages_dir"
        # App suites need the simulator accessibility tree (#339); the runner
        # prepares it and restores the preferences afterwards.
        if [[ "${1:-}" == "test-without-building" ]]; then
            runner=(python3 "$repo_root/scripts/run-app-simulator-tests.py")
        fi
    else
        working_directory="$repo_root/Packages/WaycarSSH"
    fi
    arguments=("$@")
    # Keep this function in the calling shell. In particular, an outer tee
    # pipeline or package-directory subshell would discard a replacement UDID
    # and leave later suites and cleanup pointing at the missing device.
    for attempt in 1 2 3 4; do
        if [[ "$needs_recovery" == 1 ]]; then
            # The observed loss (#327) emptied CoreSimulator's whole visible
            # set, so a couple of seconds is not a recovery window. Back off
            # 2s, 10s, 30s: about 42s in total before the retry is exhausted.
            case "$attempt" in
                2) backoff=2 ;;
                3) backoff=10 ;;
                *) backoff=30 ;;
            esac
            echo "==> $label: recovering simulator $failed_udid in ${backoff}s (attempt $attempt/4)"
            sleep "$backoff"
            if ! recover_simulator_destination; then
                continue
            fi
        fi
        for ((index = 0; index < ${#arguments[@]} - 1; index += 1)); do
            if [[ "${arguments[$index]}" == "-destination" ]]; then
                arguments[index + 1]="$simulator_destination"
            fi
        done
        attempt_log="$fixture_dir/$safe_label-attempt-$attempt.log"
        if (
            cd "$working_directory" || exit 1
            "$repo_root/scripts/run-with-timeout.py" \
                --timeout-seconds "$timeout_seconds" \
                --label "$label" \
                --diagnostics-dir "$diagnostic_root/$safe_label/attempt-$attempt" \
                --artifact-path "$app_derived_data_path/Logs/Test" \
                --artifact-path "$package_derived_data_path/Logs/Test" \
                --artifact-glob "$fixture_dir/*.log" \
                -- "${runner[@]}" "${arguments[@]}"
        ) 2>&1 | tee "$attempt_log" "$output_log"; then
            status=0
            break
        else
            status=$?
        fi
        # Exit 70 alone is not enough: only a missing destination is retryable.
        # Compilation, test failures, watchdog expiry and lock contention keep
        # their original failure behavior.
        if [[ "$status" != 70 ]] || ! grep -qF \
            'Unable to find a device matching the provided destination specifier' \
            "$attempt_log"; then
            needs_recovery=0
            break
        fi
        needs_recovery=1
        failed_udid="$simulator_udid"
    done
    if [[ "$status" != 0 && "$needs_recovery" == 1 ]]; then
        echo "Simulator destination recovery exhausted for UDID $failed_udid ($ci_simulator_name)." >&2
        xcrun simctl list devices available >&2 || true
    fi
    echo "::endgroup::"
    echo "==> $label: $((SECONDS - started_at))s (status $status)"
    return "$status"
}

write_lock_owner() {
    local lock=$1

    printf '%s' "$lock_owner_token" > "$lock/token"
    printf '%s' "$$" > "$lock/pid"
    printf '%s' "$lock_owner_start" > "$lock/start"
    # Who a run waiting for this lock names as its holder.
    if [[ -n "${GITHUB_RUN_ID:-}" ]]; then
        printf 'GitHub run %s, job %s' "$GITHUB_RUN_ID" "${GITHUB_JOB:-?}" \
            > "$lock/owner"
    else
        printf 'local run in %s' "$repo_root" > "$lock/owner"
    fi
}

lock_is_stale() {
    local lock=$1
    local owner
    local expected_start
    local actual_start

    owner=$(cat "$lock/pid" 2>/dev/null)
    expected_start=$(cat "$lock/start" 2>/dev/null)
    if [[ -z "$owner" || -z "$expected_start" ]]; then
        return 0
    fi
    actual_start=$(ps -o lstart= -p "$owner" 2>/dev/null \
        | sed 's/^ *//; s/ *$//')
    [[ -n "$actual_start" && "$actual_start" == "$expected_start" ]] \
        && return 1
    return 0
}

# Serializes inspection and replacement of one resource lock. The guard is
# never reclaimed automatically: if a gate is killed inside this tiny critical
# section, a later run reports it and asks the operator to remove it. That is
# safer than one run deleting a guard another run has just acquired.
acquire_claim_guard() {
    local lock=$1
    local description=$2
    local guard="$lock.claiming"
    local attempt

    for ((attempt = 0; attempt < 100; attempt += 1)); do
        if mkdir "$guard" 2>/dev/null; then
            active_claim_guard="$guard"
            printf '%s' "$lock_owner_token" > "$guard/token"
            return 0
        fi
        sleep 0.05
    done
    printf 'Cannot claim %s: another run is changing its lock.\n' \
        "$description" >&2
    printf 'If no gate is starting, report and remove orphaned guard %s manually.\n' \
        "$guard" >&2
    return 1
}

release_claim_guard() {
    local guard=$1
    local token

    token=$(cat "$guard/token" 2>/dev/null)
    if [[ "$token" == "$lock_owner_token" \
        || "$active_claim_guard" == "$guard" ]]; then
        rm -f -- "$guard/token"
        rmdir "$guard"
    fi
    if [[ "$active_claim_guard" == "$guard" ]]; then
        active_claim_guard=""
    fi
}

claim_resource_lock() {
    local lock=$1
    local description=$2
    local owner
    local claim_status=1

    active_resource_lock="$lock"
    if ! acquire_claim_guard "$lock" "$description"; then
        active_resource_lock=""
        return 1
    fi
    if [[ ! -d "$lock" ]]; then
        if mkdir "$lock"; then
            write_lock_owner "$lock"
            claim_status=0
        fi
    elif lock_is_stale "$lock"; then
        owner=$(cat "$lock/pid" 2>/dev/null)
        printf 'Reclaiming the stale lock on %s (owner pid %s is gone)\n' \
            "$description" "${owner:-unknown}" >&2
        rm -rf -- "$lock"
        if mkdir "$lock"; then
            write_lock_owner "$lock"
            claim_status=0
        fi
    fi
    release_claim_guard "$active_claim_guard"
    active_resource_lock=""
    return "$claim_status"
}

release_resource_lock() {
    local lock=$1
    local description=$2
    local token

    [[ -n "$lock" && -d "$lock" ]] || return 0
    if ! acquire_claim_guard "$lock" "$description"; then
        return 1
    fi
    token=$(cat "$lock/token" 2>/dev/null)
    if [[ "$token" == "$lock_owner_token" ]]; then
        rm -rf -- "$lock"
    fi
    release_claim_guard "$active_claim_guard"
}

# Last 80 lines of each fixture log. Enough to see an sshd refusal or proxy
# stall without dumping private keys or a multi-megabyte xcodebuild capture.
fixture_log_tail_lines=80

dump_fixture_logs() {
    local log
    local name
    [[ -d "$fixture_dir" ]] || return 0
    # Lane xcodebuild logs already stream through tee into the job. Print
    # only the fixture process logs that otherwise die with the temp dir.
    for log in "$fixture_dir"/*.log; do
        [[ -s "$log" ]] || continue
        name=$(basename "$log")
        case "$name" in
            sshd-*.log | herdr-core-*.log | codex-*.log | opencode-*.log | weak-network.log | fake-herdr.log | host-load.log) ;;
            *) continue ;;
        esac
        echo "===== $log (last $fixture_log_tail_lines lines)" >&2
        tail -n "$fixture_log_tail_lines" "$log" >&2
    done
}

# The runner is the developer's shared Mac, where agents' simulator runs, local
# builds and the desktop compete with this job (WAY-505). One line of host
# state every 15 s lets a failed run say whether the Mac was oversubscribed at
# that moment, and by what, instead of leaving a rerun to guess. The lines
# print with the other fixture logs on failure; a green run prints a summary.
host_load_interval_seconds=15

sample_host_load() {
    local sims
    local processes
    local top
    # The sampler is diagnostics and runs under `set -euo pipefail`: `grep -c`
    # exits 1 on a count of 0, and `head` closing the pipe SIGPIPEs `ps`. Either
    # one would kill the sampler before its first line, leaving no log.
    sims=$(xcrun simctl list devices booted 2>/dev/null | grep -c '(Booted)' || true)
    processes=$(ps -Ao comm= | awk -F/ '{ n[$NF] += 1 } END {
        printf "xcodebuild %d swift-frontend %d clang %d",
            n["xcodebuild"], n["swift-frontend"], n["clang"] }' || true)
    top=$(ps -Ao pcpu=,comm= -r 2>/dev/null | head -5 | sed -E 's|^ *([0-9.]+) .*/|\1% |' | paste -sd, - || true)
    # Memory as well as CPU: a small hosted runner can be short of either.
    # memorystatus_level is the share of memory the kernel counts as free.
    memory=$(printf 'free %s%% swap %s' \
        "$(sysctl -n kern.memorystatus_level 2>/dev/null || echo '?')" \
        "$(sysctl -n vm.swapusage 2>/dev/null | sed -E 's/.*used = ([^ ]+).*/\1/' || echo '?')")
    printf '%s load %s | %s | booted sims %s | %s | top %s\n' "$(date -u +%H:%M:%S)" \
        "$(sysctl -n vm.loadavg | tr -d '{}' | xargs)" "$memory" "$sims" "$processes" "$top"
}

start_host_load_sampler() {
    local log="$fixture_dir/host-load.log"
    (
        trap 'exit 0' TERM
        while :; do
            sample_host_load >> "$log" 2>&1
            sleep "$host_load_interval_seconds" &
            wait $!
        done
    ) &
    host_load_pid=$!
}

stop_host_load_sampler() {
    [[ -n "$host_load_pid" ]] || return 0
    kill_descendants "$host_load_pid"
    kill "$host_load_pid" >/dev/null 2>&1
    wait "$host_load_pid" 2>/dev/null
    host_load_pid=""
}

# One line for a green run; a failed run prints every sample (dump_fixture_logs).
summarize_host_load() {
    local log="$fixture_dir/host-load.log"
    [[ -s "$log" ]] || return 0
    awk -v cores="$(sysctl -n hw.ncpu)" -v memory="$(sysctl -n hw.memsize)" '
        { for (i = 1; i < NF; i += 1) if ($i == "load") {
            n += 1; sum += $(i + 1); if ($(i + 1) > peak) peak = $(i + 1); break }
          for (i = 1; i < NF; i += 1) if ($i == "free") {
            level = $(i + 1) + 0; if (!m || level < low) low = level; m += 1; break } }
        END { if (n) printf "==> Host load over the run: %d samples, 1-minute load average %.1f, peak %.1f, %d cores, %.0f GB, lowest free memory %d%%\n",
            n, sum / n, peak, cores, memory / 1073741824, low }' "$log" >&2
}

# Copy lane logs, sshd logs, the weak-network proxy log, and xcresult
# bundles out of the disposable fixture directory before cleanup deletes it.
# Print the same log tails to the job so a later artifact-upload failure
# still leaves a bounded diagnosis. Never copies key material.
preserve_failure_diagnostics() {
    local status=$1
    local dest
    local log

    [[ "$status" -ne 0 ]] || return 0

    if [[ -n "${diagnostic_root:-}" ]]; then
        dest="$diagnostic_root/fixture"
        mkdir -p "$dest/logs"
        printf '%s\n' "$status" > "$dest/exit-status.txt"
        if [[ -d "$fixture_dir" ]]; then
            for log in "$fixture_dir"/*.log; do
                [[ -f "$log" ]] || continue
                cp "$log" "$dest/logs/" 2>/dev/null \
                    || echo "could not preserve $log" >&2
            done
        fi
        if [[ -n "${app_derived_data_path:-}" \
            && -d "$app_derived_data_path/Logs/Test" ]]; then
            mkdir -p "$dest/AppDerivedData-Logs-Test"
            cp -R "$app_derived_data_path/Logs/Test/." \
                "$dest/AppDerivedData-Logs-Test/" 2>/dev/null \
                || echo "could not preserve app test logs" >&2
        fi
        if [[ -n "${package_derived_data_path:-}" \
            && -d "$package_derived_data_path/Logs/Test" ]]; then
            mkdir -p "$dest/PackageDerivedData-Logs-Test"
            cp -R "$package_derived_data_path/Logs/Test/." \
                "$dest/PackageDerivedData-Logs-Test/" 2>/dev/null \
                || echo "could not preserve package test logs" >&2
        fi
        echo "==> Preserved failure diagnostics in $dest (status $status)" >&2
    fi

    dump_fixture_logs
}

# Killing an sshd listener leaves its per-connection sshd-session children
# running, reparented to launchd. Each keeps the listener's stderr pipe open, so
# the timestamp_lines filter and its process-substitution shell never exit
# either; runs leaked dozens of each. Stop the descendants first, deepest first.
kill_descendants() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        kill_descendants "$child"
        kill "$child" >/dev/null 2>&1
    done
}

# Stops the core this run started and every process it left, and reports any
# that survive. `server stop` is addressed through the scratch HOME, so it can
# only ever reach this run's core. A core that did not answer, or a terminal
# that ignored the stop, is found by the one thing only this run's processes
# carry: the scratch HOME in their command line (the core, its holder and the
# programs the tests start under it). Nothing else is signalled.
stop_core_fixture() {
    local pids

    [[ -n "$core_home" && -d "$core_home" ]] || return 0
    if [[ -x "$core_binary" ]]; then
        env -i "HOME=$core_home" "PATH=$core_path" \
            "$core_binary" server stop >/dev/null 2>&1
    fi
    pids=$(pgrep -f -- "$core_home/" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086
        kill $pids >/dev/null 2>&1
        sleep 1
        pids=$(pgrep -f -- "$core_home/" 2>/dev/null || true)
    fi
    if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086
        kill -9 $pids >/dev/null 2>&1
        sleep 0.5
        pids=$(pgrep -f -- "$core_home/" 2>/dev/null || true)
    fi
    if [[ -n "$pids" ]]; then
        echo "herdr-core fixture processes outlived the run: $pids" >&2
        return 1
    fi
    return 0
}

# Only the fetched Codex and processes carrying this run's scratch HOME.
# The updater is disabled, so all managed package paths remain under HOME.
# A forced stop can leave X2's socket/lock; remove only the canonical target
# calculated before startup, never another entry in the shared daemon dir.
stop_codex_fixture() {
    local pids
    [[ -n "$codex_home" && -d "$codex_home" ]] || return 0
    if [[ -x "$codex_home/.local/bin/tmux" ]]; then
        env -i "HOME=$codex_home" "TMUX_TMPDIR=$codex_home/tmux" "PATH=$codex_path" \
            "$codex_home/.local/bin/tmux" kill-server >/dev/null 2>&1 || true
    fi
    if [[ -x "$codex_binary" && -S "$codex_home/.codex/app-server-control/app-server-control.sock" ]]; then
        env -i "HOME=$codex_home" "CODEX_HOME=$codex_home/.codex" "PATH=$codex_path" \
            "$codex_binary" app-server daemon stop >/dev/null 2>&1
    fi
    pids=$(pgrep -f -- "$codex_home/" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086
        kill $pids >/dev/null 2>&1
        sleep 1
        pids=$(pgrep -f -- "$codex_home/" 2>/dev/null || true)
    fi
    if [[ -n "$pids" ]]; then
        # shellcheck disable=SC2086
        kill -9 $pids >/dev/null 2>&1
        sleep 0.5
        pids=$(pgrep -f -- "$codex_home/" 2>/dev/null || true)
    fi
    if [[ -n "$pids" ]]; then
        echo "Codex fixture processes outlived the run: $pids" >&2
        return 1
    fi
    if [[ -n "$codex_physical_socket" ]]; then
        rm -f -- "$codex_physical_socket" "$codex_physical_socket.lock"
    fi
}

# Only the fetched OpenCode and processes carrying this run's scratch HOME.
# `service stop` reads the scratch registration, so it can stop no other
# server; then every process whose command line or environment (`ps eww`)
# names that HOME is signalled, never one found by name or port. The
# matcher passes the HOME in its own argv and skips its own pid.
stop_opencode_fixture() {
    local pids
    local attempt
    [[ -n "$opencode_home" && -d "$opencode_home" ]] || return 0
    if [[ -x "$opencode_binary" && -f "$opencode_home/.local/state/opencode/service.json" ]]; then
        (cd "$opencode_home" && env -i "HOME=$opencode_home" "PATH=$opencode_path" \
            "XDG_CONFIG_HOME=$opencode_home/.config" "XDG_STATE_HOME=$opencode_home/.local/state" \
            "XDG_DATA_HOME=$opencode_home/.local/share" "XDG_CACHE_HOME=$opencode_home/.cache" \
            "$opencode_binary" service stop) >/dev/null 2>&1
    fi
    for attempt in TERM KILL check; do
        pids=$(/usr/bin/python3 -c '
import os, subprocess, sys
lines = subprocess.run(["ps", "eww", "-axo", "pid=,command="], capture_output=True, text=True).stdout
for line in lines.splitlines():
    pid, _, command = line.strip().partition(" ")
    if pid.isdigit() and int(pid) != os.getpid() and sys.argv[1] in command:
        print(pid)
' "$opencode_home/" 2>/dev/null || true)
        [[ -n "$pids" ]] || return 0
        [[ "$attempt" != check ]] || break
        # shellcheck disable=SC2086
        kill -s "$attempt" $pids >/dev/null 2>&1
        sleep 1
    done
    echo "OpenCode fixture processes outlived the run: $pids" >&2
    return 1
}

# Zellij reads only the scratch environment, never the developer's session
# index or sockets. Daemonized servers and pane programs are found by this
# HOME in argv or environment, not by program name (other runs use Zellij).
stop_zellij_fixture() {
    local pids attempt
    [[ -n "$zellij_home" && -d "$zellij_home" ]] || return 0
    if [[ -x "$zellij_binary" ]]; then
        local operation
        for operation in kill-all-sessions delete-all-sessions; do
            local arguments=(-y)
            [[ "$operation" != delete-all-sessions ]] || arguments+=(-f)
            (cd "$zellij_home" && env -i "HOME=$zellij_home" "PATH=$zellij_path" \
                "ZELLIJ_SOCKET_DIR=$zellij_socket_dir" "TMPDIR=$zellij_home/tmp" \
                "XDG_CONFIG_HOME=$zellij_home/.config" "XDG_STATE_HOME=$zellij_home/.local/state" \
                "XDG_DATA_HOME=$zellij_home/.local/share" "XDG_CACHE_HOME=$zellij_home/.cache" \
                "XDG_RUNTIME_DIR=$zellij_home/run" \
                "$zellij_binary" "$operation" "${arguments[@]}") >/dev/null 2>&1 || true
        done
    fi
    for attempt in TERM KILL check; do
        pids=$(/usr/bin/python3 -c '
import os, subprocess, sys
lines = subprocess.run(["ps", "axeww", "-o", "pid=,command="], capture_output=True, text=True, check=True).stdout
for line in lines.splitlines():
    pid, _, command = line.strip().partition(" ")
    if pid.isdigit() and int(pid) != os.getpid() and sys.argv[1] in command:
        print(pid)
' "$zellij_home") || {
            echo "Could not inspect Zellij fixture processes." >&2
            return 1
        }
        [[ -n "$pids" ]] || return 0
        [[ "$attempt" != check ]] || break
        # shellcheck disable=SC2086
        kill -s "$attempt" $pids >/dev/null 2>&1
        sleep 1
    done
    echo "Zellij fixture processes outlived the run: $pids" >&2
    return 1
}

# Deletes the password account, only when its home is the one this run created:
# a record with this name and any other home belongs to someone else (another
# run that drew the same name), and is never deleted. -keepHome makes this the
# record-only delete that `dscl . -delete` was before sysadminctl replaced it:
# the home is $password_home, inside the fixture directory, which cleanup
# itself removes or keeps for diagnosis. macOS 27 rejects the flag ("'-keepHome'
# options is not available on this system") and keeps the account, whose full
# name then fails the next run's create_password_user, so it retries without
# the flag. macOS 27.0.1 keeps the home then ("WILL NOT BE DELETED!"), owned by
# a UID that no longer exists, so anything the account wrote there is beyond
# the unprivileged rm of the fixture directory; remove it while root still can.
delete_password_user() {
    [[ "$(dscl . -read "/Users/$password_username" NFSHomeDirectory 2>/dev/null)" \
        == "NFSHomeDirectory: $password_home" ]] || return 1
    sudo -n /usr/sbin/sysadminctl -deleteUser "$password_username" -keepHome \
        && return 0
    echo "==> Deleting password account $password_username without -keepHome;" \
        "its home is this run's $password_home." >&2
    sudo -n /usr/sbin/sysadminctl -deleteUser "$password_username" || return 1
    sudo -n rm -rf -- "$password_home" \
        || echo "Could not remove password account home $password_home." >&2
}

# Draws a password account name no existing record uses, so cleanup can only
# ever meet the account this run creates.
pick_password_username() {
    password_username="waycarssh${RANDOM}"
    while dscl . -read "/Users/$password_username" >/dev/null 2>&1; do
        password_username="waycarssh${RANDOM}"
    done
}

# A cancelled job stops the step's shell and little else. The runner sends
# SIGINT to that shell alone, SIGTERM 7.5 s later, and 2.5 s after that kills
# part of the tree: on the Mac the xcodebuild watchdog and its subshell die,
# the script, its listeners and the `tee` after them do not. bash holds SIGINT
# while a foreground command runs and the SIGTERM ends the shell outright, so
# this script receives neither. launchd adopts it, xcodebuild runs on with the
# script blocked on a `tee` that waits for it, and the lane keeps its Simulator
# claim, port block, sshd listeners and fixture directory until someone kills
# it by hand (WAY-525). Its trap could not help in time anyway: bash runs a
# trap only after the foreground command returns.
#
# So under GitHub Actions a watchdog notices the adoption (the parent changes)
# and ends the run the way an interrupt would: SIGTERM to this script, which
# queues the trap, then SIGTERM to its descendants, which returns the blocked
# command so the trap runs `cleanup`. It signals descendants of this script and
# nothing else. Anywhere else the parent is a terminal or make, which outlives
# a script left running on purpose (nohup), so nothing changes there.
orphan_watchdog_pid=""
# The runner orphans xcodebuild about 3 s after the SIGTERM that ends the step,
# and a descendant stops being one when that happens, so the check has to be
# quick.
orphan_check_interval_seconds=0.25
# Once the watchdog has fired, a script still alive this long is stuck in its
# cleanup; killing it makes its claims stale, which the next run can reclaim.
orphan_cleanup_deadline_seconds=60

start_orphan_watchdog() {
    [[ "${GITHUB_ACTIONS:-}" == "true" ]] || return 0
    local gate=$$
    # bash reads $PPID once, at start, and never updates it when the parent
    # dies. A step cancelled before this runs is already a changed parent.
    local parent=$PPID
    (
        local current
        local child
        local waited=0
        set +e
        # By the time it speaks the step's log is gone, and a write to the dead
        # pipe it would inherit is worse than lost: bash 3.2 mixed up its own
        # descriptors after one, and a later command substitution returned the
        # message, whose words kill_descendants then took for process ids.
        # What it has to say goes to cancelled.log, which the failure
        # diagnostics copy with the other fixture logs.
        exec >/dev/null 2>&1
        # The kill pass below walks every descendant of the script, this
        # subshell included, so it ignores SIGTERM (stop_orphan_watchdog uses
        # SIGKILL).
        trap '' TERM
        while :; do
            sleep "$orphan_check_interval_seconds"
            current=$(ps -o ppid= -p "$gate" 2>/dev/null)
            current=${current//[[:space:]]/}
            [[ -n "$current" ]] || exit 0
            [[ "$current" == "$parent" ]] || break
        done
        echo "The step that started this run is gone (job cancelled?); stopping the lane." \
            > "$fixture_dir/cancelled.log"
        # A cleanup that already started needs no help, and keeps its children.
        if [[ ! -e "$fixture_dir/cleaning" ]]; then
            kill -TERM "$gate" 2>/dev/null
            # Newest first: what blocks the script is the last thing it
            # started, and the listeners are the first.
            for child in $(pgrep -P "$gate" 2>/dev/null | sort -rn); do
                kill_descendants "$child"
                kill "$child" 2>/dev/null
            done
        fi
        while kill -0 "$gate" 2>/dev/null; do
            if ((waited >= orphan_cleanup_deadline_seconds)); then
                echo "Cleanup did not finish in ${orphan_cleanup_deadline_seconds}s; killing the stuck run." \
                    >> "$fixture_dir/cancelled.log"
                kill_descendants "$gate"
                kill -KILL "$gate" 2>/dev/null
                break
            fi
            sleep 1
            waited=$((waited + 1))
        done
    ) &
    orphan_watchdog_pid=$!
}

stop_orphan_watchdog() {
    [[ -n "$orphan_watchdog_pid" ]] || return 0
    kill_descendants "$orphan_watchdog_pid"
    kill -KILL "$orphan_watchdog_pid" >/dev/null 2>&1
    wait "$orphan_watchdog_pid" 2>/dev/null
    orphan_watchdog_pid=""
}

cleanup() {
    local status=$?
    local preserve_password_fixture=0
    # Ignore INT and TERM from here on instead of restoring them: a second
    # signal must not stop a cleanup that is halfway through releasing its
    # claim, which would strand the claim.
    trap - EXIT
    trap '' INT TERM
    set +e
    : > "$fixture_dir/cleaning" 2>/dev/null
    if [[ -e "$fixture_dir/cancelled.log" ]]; then
        # The step and the log it fed are gone. A write to the dead pipe kills
        # bash with SIGPIPE, or on bash 3.2 scrambles its descriptors, either
        # way part way through this cleanup.
        exec >/dev/null 2>&1
        if [[ "$status" -eq 0 ]]; then
            status=143
        fi
    fi

    clear_simulator_environment
    if [[ -n "$stall_pid" ]]; then
        kill "$stall_pid" >/dev/null 2>&1
        wait "$stall_pid" 2>/dev/null
    fi
    stop_host_load_sampler
    if [[ -n "$fake_herdr_pid" ]]; then
        kill "$fake_herdr_pid" >/dev/null 2>&1
        wait "$fake_herdr_pid" 2>/dev/null
    fi
    if [[ -n "$weak_network_pid" ]]; then
        kill "$weak_network_pid" >/dev/null 2>&1
        wait "$weak_network_pid" 2>/dev/null
    fi
    local pid
    for pid in "${unprivileged_sshd_pids[@]:-}"; do
        if [[ -n "$pid" ]]; then
            kill_descendants "$pid"
            kill "$pid" >/dev/null 2>&1
            wait "$pid" 2>/dev/null
        fi
    done
    # The core daemonizes out of its sshd session, so stopping sshd leaves it
    # running; like the fixture tmux server it is stopped by address.
    if ! stop_core_fixture; then
        if [[ "$status" -eq 0 ]]; then
            status=1
        fi
    fi
    if ! stop_codex_fixture; then
        if [[ "$status" -eq 0 ]]; then
            status=1
        fi
    fi
    if ! stop_opencode_fixture; then
        if [[ "$status" -eq 0 ]]; then
            status=1
        fi
    fi
    if ! stop_zellij_fixture; then
        if [[ "$status" -eq 0 ]]; then
            status=1
        fi
    fi
    # The fixture tmux server daemonizes out of its sshd session, so stopping
    # sshd leaves it running. Address it by its socket path rather than by
    # resolution: a run started inside the developer's tmux has TMUX set, and
    # a bare `tmux kill-server` would follow that to their real server.
    if [[ -n "$tmux_tmpdir" ]]; then
        local tmux_socket
        tmux_socket="$tmux_tmpdir/tmux-$(id -u)/default"
        if [[ -n "$tmux_binary" && -S "$tmux_socket" ]]; then
            env -u TMUX TMUX_TMPDIR="$tmux_tmpdir" \
                "$tmux_binary" -S "$tmux_socket" kill-server >/dev/null 2>&1
        fi
        rm -rf -- "$tmux_tmpdir"
    fi
    if [[ -n "$password_pid" ]]; then
        if stop_privileged_sshd "$password_pid" "$password_pid_file"; then
            password_pid=""
        else
            preserve_password_fixture=1
            if [[ "$status" -eq 0 ]]; then
                status=1
            fi
            echo "Failed to stop privileged sshd PID $password_pid." >&2
            echo "Preserving password account $password_username and fixture" \
                "directory $fixture_dir for diagnosis and manual cleanup." >&2
        fi
    fi
    if [[ "$status" -ne 0 && "$password_log_printed" != "1" \
        && -f "$password_log" ]]; then
        cat "$password_log" >&2
    fi
    if [[ "$preserve_password_fixture" != "1" ]]; then
        if [[ "$password_user_cleanup_needed" == "1" ]] \
            && dscl . -read "/Users/$password_username" >/dev/null 2>&1; then
            if [[ "$password_ssh_sacl_added" == "1" ]]; then
                if ! sudo -n /usr/sbin/dseditgroup -o edit \
                    -d "$password_username" -t user com.apple.access_ssh; then
                    preserve_password_fixture=1
                    if [[ "$status" -eq 0 ]]; then
                        status=1
                    fi
                    echo "Failed to remove password account $password_username from SSH access." >&2
                fi
            fi
            if [[ "$preserve_password_fixture" != "1" ]] \
                && ! delete_password_user; then
                preserve_password_fixture=1
                if [[ "$status" -eq 0 ]]; then
                    status=1
                fi
                echo "Failed to delete password account $password_username." >&2
            fi
        fi
    fi
    if [[ "$status" -ne 0 ]]; then
        local core_log
        for core_log in "$core_home"/.local/state/herdr-core/*/*.log; do
            [[ -f "$core_log" ]] || continue
            cp "$core_log" "$fixture_dir/herdr-core-$(basename "$core_log")" \
                2>/dev/null || true
        done
    fi
    summarize_host_load
    preserve_failure_diagnostics "$status"
    if [[ "$preserve_password_fixture" != "1" && -d "$fixture_dir" ]]; then
        rm -rf -- "$fixture_dir"
    fi
    # Released last: while these stand, a concurrent run treats our block and
    # our device as taken. Dropping them after the fixtures are already down,
    # and after the simulator environment has been cleared, is the safe
    # ordering -- the device must not look free while it still holds our
    # WAYCAR_SSH_E2E_* variables.
    if [[ -n "$active_claim_guard" ]]; then
        if [[ -n "$active_resource_lock" && -d "$active_resource_lock" ]] \
            && [[ "$(cat "$active_resource_lock/token" 2>/dev/null)" \
                == "$lock_owner_token" ]]; then
            rm -rf -- "$active_resource_lock"
        fi
        release_claim_guard "$active_claim_guard"
    fi
    release_resource_lock "$account_lock_dir" "password account allocation" || true
    release_resource_lock "$run_lock_dir" "fixture port block" || true
    release_resource_lock "$device_lock_dir" "simulator" || true
    stop_orphan_watchdog

    exit "$status"
}
trap cleanup EXIT INT TERM
start_host_load_sampler
start_orphan_watchdog

# Clears the fixture environment from both the Simulator and this shell. The
# shell half matters: the Simulator test process inherits it, so unsetting only
# the launchd values leaves WAYCAR_SSH_E2E_REQUIRED visible and the
# fixture-backed suites fail instead of skipping once the fixture is gone.
clear_simulator_environment() {
    simulator_environment_variables=()
    local variable
    local pid
    local unsetenv_pids=()
    for variable in \
        WAYCAR_SSH_E2E_REQUIRED \
        WAYCAR_SSH_E2E_HOST \
        WAYCAR_SSH_E2E_PORT \
        WAYCAR_SSH_E2E_PQ_PORT \
        WAYCAR_SSH_E2E_USERNAME \
        WAYCAR_SSH_E2E_DEVICE_KEY_SEED \
        WAYCAR_SSH_E2E_NO_PTY_KEY_SEED \
        WAYCAR_SSH_E2E_WEAK_PORT \
        WAYCAR_SSH_E2E_WEAK_CONTROL_PORT \
        WAYCAR_SSH_E2E_LEGACY_PORT \
        WAYCAR_SSH_E2E_RESTRICTED_PORT \
        WAYCAR_SSH_E2E_STALL_PORT \
        WAYCAR_SSH_E2E_STREAMLOCAL_SOCKET \
        WAYCAR_SSH_E2E_TIMEOUT_SCALE \
        WAYCAR_SSH_E2E_CONFIG \
        WAYCAR_SSH_JUMP_E2E_CONFIG \
        WAYCAR_CORE_E2E_CONFIG \
        WAYCAR_CODEX_E2E_CONFIG \
        WAYCAR_OPENCODE_E2E_CONFIG \
        WAYCAR_ZELLIJ_E2E_CONFIG \
        WAYCAR_PAIRING_E2E_CONFIG; do
        # launchctl takes one variable per call and each `simctl spawn` costs
        # seconds; run the round trips concurrently and collect them below.
        if [[ -n "$simulator_udid" ]]; then
            xcrun simctl spawn "$simulator_udid" launchctl unsetenv "$variable" \
                >/dev/null 2>&1 &
            unsetenv_pids+=("$!")
        fi
        unset "$variable"
    done
    for pid in "${unsetenv_pids[@]:-}"; do
        if [[ -n "$pid" ]]; then
            wait "$pid" 2>/dev/null
        fi
    done
}

# The setenv half of the same trade: a dozen serial `simctl spawn` round trips
# put most of a minute on the critical path. Values are read through variable
# indirection, so callers assign first and pass names. Every push is still
# checked explicitly, including when recovery calls this from a conditional
# where Bash disables errexit.
push_simulator_environment() {
    simulator_environment_variables=("$@")
    local variable
    local pid
    local status=0
    local setenv_pids=()
    for variable in "$@"; do
        xcrun simctl spawn "$simulator_udid" launchctl setenv \
            "$variable" "${!variable}" &
        setenv_pids+=("$!")
    done
    for pid in "${setenv_pids[@]}"; do
        wait "$pid" || status=1
    done
    return "$status"
}

stop_privileged_sshd() {
    local launcher_pid=$1
    local pid_file=$2
    local attempt
    local daemon_pid=""
    local launcher_state=""
    local target_pid=""

    if [[ -f "$pid_file" ]]; then
        daemon_pid="$(<"$pid_file")"
    fi
    if [[ "$daemon_pid" =~ ^[0-9]+$ ]]; then
        target_pid=$daemon_pid
    elif [[ "$launcher_pid" =~ ^[0-9]+$ ]]; then
        target_pid=$launcher_pid
    else
        return 0
    fi

    if sudo -n kill "$target_pid" 2>/dev/null; then
        for ((attempt = 0; attempt < 50; attempt += 1)); do
            if ! ps -p "$target_pid" >/dev/null 2>&1; then
                break
            fi
            sleep 0.1
        done
        if ps -p "$target_pid" >/dev/null 2>&1; then
            return 1
        fi
    elif ps -p "$target_pid" >/dev/null 2>&1; then
        # Do not wait on a process that is still live: cleanup must retain its
        # state and report the failed stop instead of blocking indefinitely.
        return 1
    fi

    # sudo may remain as a distinct launcher after the daemon exits. Bash 3
    # has no bounded wait, so poll until that child is absent or a zombie
    # before reaping it. A live launcher after the deadline is a failed stop,
    # and cleanup must preserve its evidence without waiting on it.
    if [[ "$launcher_pid" =~ ^[0-9]+$ ]]; then
        for ((attempt = 0; attempt < 50; attempt += 1)); do
            launcher_state="$(ps -o state= -p "$launcher_pid" 2>/dev/null || true)"
            if [[ -z "$launcher_state" \
                || "$launcher_state" =~ ^[[:space:]]*Z ]]; then
                wait "$launcher_pid" 2>/dev/null || true
                break
            fi
            sleep 0.1
        done
        if [[ -n "$launcher_state" \
            && ! "$launcher_state" =~ ^[[:space:]]*Z ]]; then
            return 1
        fi
    fi

    ! ps -p "$target_pid" >/dev/null 2>&1
}

start_password_sshd() {
    local attempt

    # Start this short-lived root fixture only when its suite is ready to run.
    # The invoking shell intentionally owns the diagnostic log redirect.
    # shellcheck disable=SC2024
    sudo -n /usr/sbin/sshd -D -e -f "$password_config" \
        > >(timestamp_lines > "$password_log") 2>&1 &
    password_pid=$!

    for ((attempt = 0; attempt < 50; attempt += 1)); do
        if sudo -n kill -0 "$password_pid" >/dev/null 2>&1 \
            && nc -z 127.0.0.1 "$password_port" >/dev/null 2>&1; then
            return 0
        fi
        if ! sudo -n kill -0 "$password_pid" >/dev/null 2>&1; then
            break
        fi
        sleep 0.1
    done

    if stop_privileged_sshd "$password_pid" "$password_pid_file"; then
        password_pid=""
    fi
    cat "$password_log" >&2
    password_log_printed=1
    return 1
}

# Prove the disposable account through the same public boundary a Host uses.
# Expect owns a PTY but suppresses its transcript; only the exported secret is
# copied into Tcl, and it is removed from the child environment before ssh.
password_ssh_preflight() {
    local status

    export WAYCAR_PASSWORD_SSH_PREFLIGHT_PASSWORD="$password_secret"
    # 5 s per step on an idle Mac, stretched like the suites' sshd budgets: a
    # loaded 3-core hosted runner spent 3 s in PAM alone and missed a flat 5 s.
    WAYCAR_PASSWORD_SSH_PREFLIGHT_TIMEOUT=$(awk -v scale="${WAYCAR_SSH_E2E_TIMEOUT_SCALE:-1}" \
        'BEGIN { seconds = int(5 * scale + 0.5); print (seconds < 5 ? 5 : seconds) }')
    export WAYCAR_PASSWORD_SSH_PREFLIGHT_TIMEOUT
    if /usr/bin/expect <<'EXPECT'
set timeout $env(WAYCAR_PASSWORD_SSH_PREFLIGHT_TIMEOUT)
log_user 0

set password $env(WAYCAR_PASSWORD_SSH_PREFLIGHT_PASSWORD)
unset env(WAYCAR_PASSWORD_SSH_PREFLIGHT_PASSWORD)

spawn /usr/bin/ssh \
    -F /dev/null \
    -T \
    -o PreferredAuthentications=password \
    -o PasswordAuthentication=yes \
    -o KbdInteractiveAuthentication=no \
    -o PubkeyAuthentication=no \
    -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=$env(WAYCAR_PASSWORD_SSH_PREFLIGHT_TIMEOUT) \
    -o ConnectionAttempts=1 \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -o LogLevel=ERROR \
    -p $env(WAYCAR_PASSWORD_SSH_PREFLIGHT_PORT) \
    -l $env(WAYCAR_PASSWORD_SSH_PREFLIGHT_USERNAME) \
    127.0.0.1 \
    /bin/echo WAYCAR_PASSWORD_SSH_PREFLIGHT_OK

expect {
    -re {(?i)password:[[:space:]]*$} {
        send -- "$password\r"
    }
    timeout { exit 1 }
    eof { exit 1 }
}

set saw_sentinel 0
expect {
    -exact {WAYCAR_PASSWORD_SSH_PREFLIGHT_OK} {
        set saw_sentinel 1
        exp_continue
    }
    -re {(?i)password:[[:space:]]*$} { exit 1 }
    timeout { exit 1 }
    eof {}
}

if {!$saw_sentinel} {
    exit 1
}
set child_status [wait]
exit [lindex $child_status 3]
EXPECT
    then
        status=0
    else
        status=$?
    fi
    unset WAYCAR_PASSWORD_SSH_PREFLIGHT_PASSWORD
    unset WAYCAR_PASSWORD_SSH_PREFLIGHT_TIMEOUT
    return "$status"
}

# sysadminctl owns creation of the complete local account record. Expect feeds
# its password prompt without putting the secret in argv, the command line, or
# the sysadminctl environment; the pty transcript it records for diagnosis has
# echo turned off before the password is sent and is scrubbed afterwards.
# Every command in the password fixture block is silent on success and, under
# `set -e`, silent on failure too: five CI runs exited 1 between "Claimed
# simulator" and the first xcodebuild with nothing to read (#348). Route each
# step through here so the job log names the step and its exit status.
provisioning_step() {
    local label=$1
    local status
    shift
    "$@" && return 0
    status=$?
    echo "Password fixture provisioning failed at $label (status $status)." >&2
    return "$status"
}

# The expect transcript below records the pty. Echo is turned off before the
# password is sent, so the secret should never reach the file; this scrub is
# the second line, run before the transcript is printed or preserved. The
# secret travels in the environment so no quoting can leak or mangle it, and
# an empty secret must not become an empty match that rewrites the whole file.
redact_secret_in_file() {
    local file=$1
    local secret=$2
    [[ -f "$file" && -n "$secret" ]] || return 0
    WAYCAR_REDACT_SECRET="$secret" perl -pi -e \
        's/\Q$ENV{WAYCAR_REDACT_SECRET}\E/[redacted]/g' "$file"
}

create_password_user() (
    local status

    rm -f "$sysadminctl_log"
    export WAYCAR_SYSADMINCTL_PASSWORD="$password_secret"
    export WAYCAR_SYSADMINCTL_USERNAME="$password_username"
    export WAYCAR_SYSADMINCTL_UID="$password_uid"
    export WAYCAR_SYSADMINCTL_HOME="$password_home"
    export WAYCAR_SYSADMINCTL_LOG="$sysadminctl_log"
    # log_user 0 keeps the transcript off the job log; -a records it anyway so a
    # failure can show what sysadminctl said. Each exit path names its reason on
    # stderr, which the calling shell leaves connected to the job log.
    if /usr/bin/expect <<'EXPECT'
set timeout 30
log_user 0
log_file -a -noappend $env(WAYCAR_SYSADMINCTL_LOG)

set password $env(WAYCAR_SYSADMINCTL_PASSWORD)
unset env(WAYCAR_SYSADMINCTL_PASSWORD)

spawn /usr/bin/sudo -n /usr/sbin/sysadminctl \
    -addUser $env(WAYCAR_SYSADMINCTL_USERNAME) \
    -fullName {Waycar SSH CI} \
    -UID $env(WAYCAR_SYSADMINCTL_UID) \
    -GID 20 \
    -shell /bin/zsh \
    -home $env(WAYCAR_SYSADMINCTL_HOME) \
    -password -

set sent_password 0
expect {
    -re {(?i)password[^\r\n]*:[[:space:]]*$} {
        if {$sent_password} {
            puts stderr "sysadminctl prompted for the password a second time"
            close
            catch {wait}
            exit 1
        }
        catch {exec stty -echo < $spawn_out(slave,name)}
        send -- "$password\r"
        set sent_password 1
        exp_continue
    }
    timeout {
        puts stderr "sysadminctl timed out after ${timeout}s (password sent: $sent_password)"
        close
        catch {wait}
        exit 1
    }
    eof {}
}

if {!$sent_password} {
    puts stderr "sysadminctl exited without prompting for a password"
    exit 1
}
if {[catch {wait} child_status]} {
    puts stderr "could not wait for sysadminctl: $child_status"
    exit 1
}
if {[llength $child_status] < 4 || [lindex $child_status 2] ne "0"} {
    puts stderr "sysadminctl wait reported an error: $child_status"
    exit 1
}
if {[llength $child_status] >= 5 \
    && [lindex $child_status 4] eq "CHILDKILLED"} {
    puts stderr "sysadminctl was killed by a signal: $child_status"
    exit 1
}
set child_exit [lindex $child_status 3]
if {![string is integer -strict $child_exit] \
    || $child_exit < 0 || $child_exit > 255} {
    puts stderr "sysadminctl exit status is unreadable: $child_status"
    exit 1
}
if {$child_exit != 0} {
    puts stderr "sysadminctl exited with status $child_exit"
}
exit $child_exit
EXPECT
    then
        status=0
    else
        status=$?
    fi
    unset WAYCAR_SYSADMINCTL_PASSWORD
    unset WAYCAR_SYSADMINCTL_USERNAME
    unset WAYCAR_SYSADMINCTL_UID
    unset WAYCAR_SYSADMINCTL_HOME
    unset WAYCAR_SYSADMINCTL_LOG
    redact_secret_in_file "$sysadminctl_log" "$password_secret"
    if [[ "$status" != 0 && -s "$sysadminctl_log" ]]; then
        echo "===== sysadminctl transcript ($sysadminctl_log)" >&2
        cat "$sysadminctl_log" >&2
    fi
    return "$status"
)

# `sshd -e` writes no timestamps, so a preserved log could not be matched
# against the wall-clock window of a failing test (#343). Prefix every line
# with the same UTC format GitHub prints for job log lines. Process
# substitution keeps `$!` as sshd's own pid for the kill/wait bookkeeping;
# the filter exits on its own when sshd closes the pipe.
timestamp_lines() {
    perl -MPOSIX -pe '$| = 1; $_ = POSIX::strftime("%Y-%m-%dT%H:%M:%SZ ", gmtime) . $_'
}

# Sets started_sshd_pid rather than printing it: a command substitution would
# run the append to unprivileged_sshd_pids in a subshell and lose it.
started_sshd_pid=""
start_unprivileged_sshd() {
    local config=$1
    local log=$2

    /usr/sbin/sshd -D -e -f "$config" > >(timestamp_lines > "$log") 2>&1 &
    started_sshd_pid=$!
    unprivileged_sshd_pids+=("$started_sshd_pid")
}

# The single place fixture ports are named. Every other reference in this
# script, and every port the tests are handed, comes from these nineteen
# variables, so moving the base moves the whole fixture.
assign_port_block() {
    local base=$1
    local highest

    modern_port=$((base + 0))
    legacy_port=$((base + 1))
    restricted_port=$((base + 2))
    stall_port=$((base + 3))
    streamlocal_global_policy_port=$((base + 4))
    streamlocal_key_policy_port=$((base + 5))
    jump_target_port=$((base + 6))
    jump_forwarding_denied_port=$((base + 7))
    pairing_port=$((base + 8))
    password_port=$((base + 9))
    # The unprivileged impairment proxy: a degraded route to the modern sshd,
    # plus the control port the weak-network suite steers it through.
    weak_network_port=$((base + 10))
    weak_network_control_port=$((base + 11))
    # Post-quantum coverage uses a dedicated endpoint so the established
    # resource and timing suites keep exercising their Curve25519 baseline.
    post_quantum_port=$((base + 12))
    # The herdr-core fixture's own sshd: its sessions run under a scratch HOME.
    core_port=$((base + 13))

    # Adding a port above without widening port_block_size would overlap the
    # next block, which no test could distinguish from a flaky fixture.
    codex_port=$((base + 14))
    codex_model_port=$((base + 15))
    # The OpenCode fixture: its sshd, its model stand-in and its server.
    opencode_port=$((base + 16))
    opencode_model_port=$((base + 17))
    opencode_server_port=$((base + 18))
    zellij_port=$((base + 19))
    highest=$zellij_port
    if [[ "$highest" -ne "$((base + port_block_size - 1))" ]]; then
        echo "assign_port_block assigns past port_block_size=$port_block_size" >&2
        exit 1
    fi
}

# The pairing fixture is reached over both loopback families, so a listener on
# either one is a genuine conflict. Checking both for every port costs nothing
# and can only ever reject a block, never wave a busy one through.
port_is_busy() {
    local port=$1

    nc -z 127.0.0.1 "$port" >/dev/null 2>&1 && return 0
    nc -z ::1 "$port" >/dev/null 2>&1 && return 0
    return 1
}

# Names who holds a port, so a refusal can say more than "already in use".
# A listener whose parent is init was reparented when its run died: that is an
# orphan from a crashed gate, not a colleague mid-run. It is reported and never
# killed -- guessing wrong about ownership costs someone else their run.
describe_port_holder() {
    local port=$1
    local only_orphans=${2:-0}
    local pid
    local parent
    local command
    local described=1

    for pid in $(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | sort -u); do
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        command=$(ps -o command= -p "$pid" 2>/dev/null)
        if [[ -z "$command" ]]; then
            continue
        fi
        if [[ "$parent" == "1" ]]; then
            described=0
            printf '      port %s: ORPHAN pid %s (reparented to init) %s\n' \
                "$port" "$pid" "$command" >&2
        elif [[ "$only_orphans" != "1" ]]; then
            described=0
            printf '      port %s: pid %s (parent %s) %s\n' \
                "$port" "$pid" "${parent:-unknown}" "$command" >&2
        fi
    done
    return "$described"
}

mkdir -p "$lock_root"

# Blocks are tried in order and the first wholly free one wins, so an idle
# machine is deterministic. Every rejection is recorded rather than fatal:
# if nothing is free the operator gets the whole picture at once instead of
# the first port that happened to be taken.
claim_port_block() {
    local -a bases=()
    local base
    local slot
    local busy
    local port
    local offset
    local lock
    local owner
    local -a rejections=()

    if [[ -n "$port_block_base_override" ]]; then
        bases=("$port_block_base_override")
    else
        for ((slot = 0; slot < port_block_count; slot += 1)); do
            bases+=("$((port_block_base_default + slot * port_block_size))")
        done
    fi

    for base in "${bases[@]}"; do
        lock="$lock_root/block-$base"
        busy=""
        for ((offset = 0; offset < port_block_size; offset += 1)); do
            port=$((base + offset))
            if port_is_busy "$port"; then
                busy+=" $port"
                # A run may move to the next free block, but an orphan from a
                # crashed gate still needs to be visible to the operator. It
                # is reported here and deliberately left untouched.
                describe_port_holder "$port" 1 || true
            fi
        done

        # Recorded as "<base> <kind> <detail...>". The kind is explicit because
        # the two rejections carry different trailing numbers -- ports for one,
        # a pid for the other -- and only ports may be looked up as ports.
        if [[ -n "$busy" ]]; then
            rejections+=("$base ports$busy")
            continue
        fi

        if claim_resource_lock "$lock" "port block $base"; then
            run_lock_dir="$lock"
            assign_port_block "$base"
            return 0
        fi

        owner=$(cat "$lock/pid" 2>/dev/null)
        rejections+=("$base lock ${owner:-unknown}")
    done

    echo "Every fixture port block on this machine is taken." >&2
    echo "The merge gate needs $port_block_size consecutive free ports." >&2
    local -a fields=()
    local rejection
    for rejection in "${rejections[@]}"; do
        read -r -a fields <<<"$rejection"
        if [[ "${fields[1]}" == "ports" ]]; then
            printf '  block %s: ports in use:%s\n' \
                "${fields[0]}" "${rejection#"${fields[0]} ports"}" >&2
            for port in "${fields[@]:2}"; do
                describe_port_holder "$port" || true
            done
        else
            printf '  block %s: claimed by live run pid %s\n' \
                "${fields[0]}" "${fields[2]}" >&2
        fi
    done
    echo >&2
    echo "What to do:" >&2
    echo "  - a block held by a live run: wait for it, or widen" >&2
    echo "    port_block_count in this script." >&2
    echo "  - an ORPHAN above outlived its run. Confirm it is yours, then" >&2
    echo "    kill it by pid. This script never kills what it did not start." >&2
    echo "  - to pin a block yourself: WAYCAR_CI_PORT_BASE=<base>" >&2
    exit 1
}

claim_port_block
printf 'Claimed fixture port block %s-%s\n' \
    "$modern_port" "$((modern_port + port_block_size - 1))" >&2

# Claim the simulator before fixture keygen/sshd work so boot overlaps that
# setup as well as build-for-testing. Ports alone are not enough for two runs
# to coexist: the fixture reaches the tests through `simctl launchctl setenv`,
# which is per-device state. Two runs sharing one device overwrite each other's
# WAYCAR_SSH_E2E_* and one of them tests the other's fixture -- silently,
# unlike a port clash.
#
# CI owns its device. The runner is a developer's Mac, where local flows
# (make sim, make test-app, agents' own xcodebuild runs) find the shared
# "iPhone 17 Pro Max" by name, by grepping its UDID, or as the booted device,
# and one of them installing Waycar there SIGKILLs the test host mid-suite
# (run 36244193057). No local flow finds a device named "Waycar CI", so only
# runs that honour the device claim below ever touch it. The script creates
# it on first use.
#
# Candidates come back last-first, preserving the previous choice of the last
# matching device for a run that finds the machine idle. The name is matched
# as a literal prefix plus " (" so "iPhone 17" claims neither "iPhone 17 Pro"
# nor someone's "repro iPhone 17", and names with parentheses (iPad Pro
# 13-inch (M5)) stay literal rather than becoming an awk regex.
ci_default_simulator_name="Waycar CI"
ci_simulator_name="${WAYCAR_CI_SIMULATOR_NAME:-$ci_default_simulator_name}"
requested_simulator_udid="${WAYCAR_CI_SIMULATOR_UDID:-}"
# A run that finds every device held by a live run waits for one rather than
# fail. The runner is a developer's Mac, where a local `make test-ci-app` holds
# Waycar CI for a whole lane (20 to 30 min), and failing at once cost CI whole
# runs (42943473339). It looks again every ci_simulator_poll_seconds and gives
# up after WAYCAR_CI_SIM_WAIT_SECONDS; 0 fails at once, as before. ci.yml's
# step timeouts leave room for the whole wait.
ci_simulator_wait_seconds="${WAYCAR_CI_SIM_WAIT_SECONDS:-2700}"
ci_simulator_poll_seconds=20
if [[ ! "$ci_simulator_wait_seconds" =~ ^(0|[1-9][0-9]*)$ ]]; then
    printf 'WAYCAR_CI_SIM_WAIT_SECONDS must be a whole number of seconds, got: %s\n' \
        "$ci_simulator_wait_seconds" >&2
    exit 2
fi
# Keeps the raw listing in simulator_listing so a recovery attempt can print
# what CoreSimulator saw at that moment, not only the filtered candidates.
list_simulator_candidates() {
    local candidate
    simulator_listing=$(xcrun simctl list devices available) || return 1
    simulator_candidates=()
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] && simulator_candidates+=("$candidate")
    done < <(printf '%s\n' "$simulator_listing" | awk -v name="$ci_simulator_name" \
        -v pinned="$requested_simulator_udid" '
        { line = $0; sub(/^[ \t]+/, "", line) }
        index(line, name " (") == 1 || (pinned != "" && index($0, "(" pinned ")")) {
            candidate = ""
            for (field = 1; field <= NF; field += 1) {
                value = $field
                gsub(/[()]/, "", value)
                if (value ~ /^[0-9A-F-]{36}$/) {
                    candidate = value
                }
            }
            if (candidate != "") {
                list[++count] = candidate
            }
        }
        END { for (index_ = count; index_ >= 1; index_ -= 1) print list[index_] }
    ')
}

list_simulator_candidates
if [[ "${#simulator_candidates[@]}" -eq 0 && -z "$requested_simulator_udid" \
    && "$ci_simulator_name" == "$ci_default_simulator_name" ]]; then
    printf 'Creating the dedicated %s Simulator\n' "$ci_simulator_name" >&2
    xcrun simctl create "$ci_simulator_name" \
        com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max >/dev/null
    list_simulator_candidates
fi
if [[ "${#simulator_candidates[@]}" -eq 0 ]]; then
    echo "No available ${ci_simulator_name} Simulator was found" >&2
    exit 1
fi

# Reports the live pid holding this device, nothing if it is free.
simulator_held_by() {
    local udid=$1
    local owner

    owner=$(cat "$lock_root/device-$udid/pid" 2>/dev/null)
    if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
        printf '%s' "$owner"
        return 0
    fi
    return 1
}

# The device uses the same token-checked resource claim as a port block. A
# separate device claim is necessary because its launchctl environment is
# shared even when the fixture ports are not.
claim_simulator() {
    local udid=$1
    local lock="$lock_root/device-$udid"

    if claim_resource_lock "$lock" "simulator $udid"; then
        device_lock_dir="$lock"
        return 0
    fi
    return 1
}

# Called only after xcodebuild explicitly reports a missing destination. Keep
# an explicit caller pin; otherwise use another unclaimed device of the same
# name. Never reset CoreSimulator or disturb another run's device lock.
recover_simulator_destination() {
    local candidate
    local current_available=0

    list_simulator_candidates || return 1
    # The next reader needs to know whether the device was gone for seconds or
    # for the whole window, so every rediscovery records the live listing.
    printf 'Simulators visible while recovering %s:\n%s\n' \
        "${simulator_udid:-<released>}" "$simulator_listing" >&2
    # Bash 3.2 treats an empty array expansion as unbound under nounset.
    # Handle it before iterating so recovery can retry and report diagnostics.
    if [[ "${#simulator_candidates[@]}" == 0 ]]; then
        echo "No available $ci_simulator_name Simulator during destination recovery." >&2
        return 1
    fi
    for candidate in "${simulator_candidates[@]}"; do
        if [[ "$candidate" == "$simulator_udid" ]]; then
            current_available=1
        fi
    done
    if [[ "$current_available" == 0 ]]; then
        if [[ -n "$requested_simulator_udid" ]]; then
            echo "Explicitly pinned simulator $requested_simulator_udid is still unavailable." >&2
            return 1
        fi
        # Clear the old device while still owning it, but preserve shell values
        # for the replacement. Release before claiming so cleanup owns one lock.
        (clear_simulator_environment) || true
        release_resource_lock "$device_lock_dir" "simulator" || return 1
        device_lock_dir=""
        simulator_udid=""
        simulator_destination=""
        for candidate in "${simulator_candidates[@]}"; do
            if claim_simulator "$candidate"; then
                simulator_udid="$candidate"
                simulator_destination="platform=iOS Simulator,id=$candidate"
                break
            fi
        done
        if [[ -z "$simulator_udid" ]]; then
            echo "Every replacement $ci_simulator_name Simulator is claimed by a live run." >&2
            return 1
        fi
    fi
    printf 'Recovering simulator %s\n' "$simulator_udid" >&2
    # A deferred boot (WAYCAR_CI_BOOT_AFTER_BUILD) stays deferred: compilation
    # needs the destination to exist, and wait_for_simulator_boot boots it.
    if [[ "$simulator_boot_started" == "1" ]]; then
        xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
        xcrun simctl bootstatus "$simulator_udid" -b || return 1
    fi
    if [[ "${#simulator_environment_variables[@]}" -gt 0 ]]; then
        push_simulator_environment "${simulator_environment_variables[@]}" || return 1
    fi
}

# "pid <pid> (<who>)" for the live run holding this device. Who comes from the
# lock (a GitHub job or a local checkout) or, for a lock an older gate wrote,
# from the holder's command line.
simulator_holder() {
    local udid=$1
    local owner
    local who=""

    owner=$(simulator_held_by "$udid") || owner=""
    if [[ -n "$owner" ]]; then
        who=$(cat "$lock_root/device-$udid/owner" 2>/dev/null) \
            || who=$(ps -o command= -p "$owner" 2>/dev/null) || who=""
    fi
    printf 'pid %s%s' "${owner:-unknown}" "${who:+ ($who)}"
}

# Claims the pinned device, or the first free candidate, waiting while live
# runs hold them all (see ci_simulator_wait_seconds). Every attempt is the same
# guarded claim as ever, so two waiters never both win a device that frees up,
# and a stale claim (its owner gone) is reclaimed on the first try. Waiting
# never creates or pins another device.
claim_ci_simulator() {
    local -a wanted=("${simulator_candidates[@]}")
    local candidate
    local started=$SECONDS
    local waited=0
    local next_report=0
    local holders
    local first_holders=""
    local nap

    if [[ -n "$requested_simulator_udid" ]]; then
        wanted=("$requested_simulator_udid")
    fi
    while :; do
        for candidate in "${wanted[@]}"; do
            claim_simulator "$candidate" || continue
            simulator_udid=$candidate
            [[ -n "$first_holders" ]] || return 0
            waited=$((SECONDS - started))
            printf 'Waited %dm%02ds for simulator %s.\n' \
                $((waited / 60)) $((waited % 60)) "$candidate" >&2
            if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
                printf '::notice title=Waited for the %s Simulator::Waited %dm%02ds for %s. Waiting began on: %s\n' \
                    "$ci_simulator_name" $((waited / 60)) $((waited % 60)) \
                    "$candidate" "$first_holders"
            fi
            return 0
        done
        waited=$((SECONDS - started))
        if ((waited >= ci_simulator_wait_seconds)); then
            break
        fi
        if ((waited >= next_report)); then
            holders=""
            for candidate in "${wanted[@]}"; do
                holders+="; $candidate held by $(simulator_holder "$candidate")"
            done
            holders=${holders#; }
            [[ -n "$first_holders" ]] || first_holders=$holders
            printf 'Waiting for a %s Simulator, %dm of up to %dm: %s\n' \
                "$ci_simulator_name" $((waited / 60)) \
                $((ci_simulator_wait_seconds / 60)) "$holders" >&2
            next_report=$((waited + 60))
        fi
        # The last nap ends at the bound, for one last try there.
        nap=$((ci_simulator_wait_seconds - waited))
        if ((nap > ci_simulator_poll_seconds)); then
            nap=$ci_simulator_poll_seconds
        fi
        sleep "$nap"
    done

    if [[ -n "$first_holders" ]]; then
        printf 'Gave up after %dm%02ds (WAYCAR_CI_SIM_WAIT_SECONDS=%s).\n' \
            $((waited / 60)) $((waited % 60)) "$ci_simulator_wait_seconds" >&2
    fi
    if [[ -n "$requested_simulator_udid" ]]; then
        printf 'Requested simulator %s is claimed by live run %s.\n' \
            "$requested_simulator_udid" \
            "$(simulator_holder "$requested_simulator_udid")" >&2
        echo "Choose a different WAYCAR_CI_SIMULATOR_UDID or wait for that run." >&2
        return 1
    fi
    echo "Every available ${ci_simulator_name} Simulator is claimed by a live run." >&2
    for candidate in "${wanted[@]}"; do
        printf '  %s: held by %s\n' "$candidate" "$(simulator_holder "$candidate")" >&2
    done
    echo >&2
    echo "A run needs a device of its own: the fixture is delivered through" >&2
    echo "per-device launchctl environment, which two runs would overwrite." >&2
    echo "Create another ${ci_simulator_name} with 'xcrun simctl create', or pin one" >&2
    echo "explicitly with WAYCAR_CI_SIMULATOR_UDID=<udid>." >&2
    return 1
}

simulator_udid=""
if ! claim_ci_simulator; then
    exit 1
fi
printf 'Claimed simulator %s\n' "$simulator_udid" >&2
simulator_destination="platform=iOS Simulator,id=$simulator_udid"
# Kick the boot off now and wait for it only after build-for-testing below:
# compilation needs the destination to exist, not to be booted, so boot
# happens under fixture provisioning and build instead of in front of them.
#
# WAYCAR_CI_BOOT_AFTER_BUILD=1 (the hosted runners) defers the boot to after
# the build and then waits for the device's first-boot work to finish. On a
# 3-core hosted runner a new iOS 27 device's first boot keeps the 1-minute
# load above 300 for about 15 minutes (simulator boot probe, 2026-11-13: 234 s
# to bootstatus, load under 30 only 1,030 s after the boot began). Overlapped,
# it stretched the build past its 30-minute watchdog and failed the password
# preflight; still running when the suites started, it starves their tests.
boot_after_build=0
if [[ "${WAYCAR_CI_BOOT_AFTER_BUILD:-0}" == "1" ]]; then
    boot_after_build=1
else
    simulator_boot_started=1
    xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
fi

# Waits for the claimed simulator before the first test action: whatever is
# left of the boot kicked off above, or, deferred, the whole boot and then its
# first-boot work. That work has no completion signal, so the wait polls the
# 1-minute load average until it is under ten per core (a booted, settled
# device on the hosted runner idles at 15 to 25 on 3 cores), and gives up,
# loudly, after settle_limit_seconds.
settle_limit_seconds=1200
wait_for_simulator_boot() {
    local started=$SECONDS
    local limit
    local load
    local cores

    if [[ "$boot_after_build" == "1" ]]; then
        simulator_boot_started=1
        xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
    fi
    xcrun simctl bootstatus "$simulator_udid" -b
    if [[ "$boot_after_build" != "1" ]]; then
        echo "==> Simulator boot wait after the build overlap: $((SECONDS - started))s"
        return 0
    fi
    echo "==> Simulator boot after the build: $((SECONDS - started))s"
    cores=$(sysctl -n hw.ncpu)
    limit=$((SECONDS + settle_limit_seconds))
    while :; do
        load=$(sysctl -n vm.loadavg | awk '{ print $2 }')
        if awk -v load="$load" -v cores="$cores" 'BEGIN { exit !(load < 10 * cores) }'; then
            echo "==> Simulator first-boot work settled: 1-minute load $load" \
                "on $cores cores, $((SECONDS - started))s after the boot began"
            return 0
        fi
        if ((SECONDS >= limit)); then
            echo "WARNING: the simulator's first-boot work has not settled after" \
                "${settle_limit_seconds}s (1-minute load $load on $cores cores);" \
                "the suites start on a loaded machine." >&2
            return 0
        fi
        sleep 15
    done
}

sftp_server=""
for candidate in /usr/libexec/sftp-server /usr/lib/openssh/sftp-server; do
    if [[ -x "$candidate" ]]; then
        sftp_server="$candidate"
        break
    fi
done
if [[ -z "$sftp_server" ]]; then
    echo "No sftp-server binary was found; the SFTP suites cannot run" >&2
    exit 1
fi

chmod 755 "$fixture_dir"
mkdir -p \
    "$fixture_home/.config/herdr/sessions/fixture" \
    "$fixture_home/.codex/skills/fixture" \
    "$fixture_home/.waycar-ci" \
    "$fixture_dir/bin"
printf '%s\n' \
    '---' \
    'name: fixture' \
    'description: Real SSH fixture skill.' \
    '---' \
    'Fixture body.' \
    > "$fixture_home/.codex/skills/fixture/SKILL.md"
# The dollar expressions below belong to the generated fixture script.
# shellcheck disable=SC2016
printf '%s\n' \
    '#!/bin/sh' \
    'stty -echo' \
    'printf "TTY-OK\\n"' \
    'printf "ARGS:%s\\n" "$*"' \
    'printf "SOCKET:%s\\n" "$HERDR_SOCKET_PATH"' \
    'stty size' \
    'while IFS= read -r line; do' \
    '    case "$line" in' \
    '        __exit__) exit 0 ;;' \
    '        __fail__) exit 23 ;;' \
    '        __end_race__)' \
    '            printf "END-RACE-READY\\n"' \
    '            sleep 1' \
    '            printf "END-RACE-BEFORE\\n"' \
    '            sleep 10' \
    '            printf "END-RACE-AFTER\\n"' \
    '            continue ;;' \
    '    esac' \
    '    printf "GOT:%s\\n" "$line"' \
    '    stty size' \
    'done' \
    > "$fixture_home/.waycar-ci/fake-attach"
chmod 755 "$fixture_home/.waycar-ci/fake-attach"

# Only an explicit start runs `herdr remote-client-bridge` on the Host. The
# fixture has no herdr server, and a real one must never be reached, so stand
# in for the binary with a stub that succeeds and does nothing. It also makes
# the read-only diagnostic classify a missing socket as stopped (folder exists)
# or a missing session (folder absent), rather than herdr absent from PATH.
printf '%s\n' '#!/bin/sh' 'exit 0' > "$fixture_dir/bin/herdr"
chmod 755 "$fixture_dir/bin/herdr"

# Backend detection and the launch probes run codex and opencode wherever a
# fixture session finds them. This sshd runs on the CI runner, whose Homebrew
# codex once never started from SSH (macOS had not approved it) and hung every
# detection exec, so the sessions find these stubs instead: a current Codex
# whose server is stopped, and an OpenCode 2 whose server is stopped.
# TmuxTransportE2ETests checks that nothing a session looks for resolves
# outside this directory.
fixture_codex_version=0.167.1
fixture_opencode_version=2.2.7
printf '%s\n' '#!/bin/sh' 'case "$*" in' \
    "    --version) echo 'codex-cli $fixture_codex_version' ;;" \
    "    --help) echo '      --no-daemon  Run without the shared app-server' ;;" \
    '    "app-server daemon version") exit 1 ;;' \
    '    *) echo "fixture codex stub: $*" >&2; exit 2 ;;' 'esac' \
    > "$fixture_dir/bin/codex"
printf '%s\n' '#!/bin/sh' 'case "$*" in' \
    "    --version) echo 'opencode v$fixture_opencode_version' ;;" \
    '    "service status") echo stopped ;;' \
    '    *) echo "fixture opencode stub: $*" >&2; exit 2 ;;' 'esac' \
    > "$fixture_dir/bin/opencode"
chmod 755 "$fixture_dir/bin/codex" "$fixture_dir/bin/opencode"

# The tmux backend suite runs a real tmux server over the fixture sshd, which
# runs as the invoking account: a bare `tmux` in a fixture session would reach
# that account's own server under /tmp/tmux-<uid>. Every disposable sshd
# therefore exports `TMUX_TMPDIR` (write_common_config, write_pairing_config)
# pointing at this private directory, cleanup() kills that server by its socket
# path and removes the directory, and TmuxTransportE2ETests refuses to run any
# tmux command until it has read the same value back over SSH. tmux realpaths
# the directory, so the socket path stays short of the 104-byte AF_UNIX limit.
tmux_tmpdir="$fixture_dir/tmux"
mkdir -m 0700 "$tmux_tmpdir"

# Mirrors HostBackendPresence.meetsTmuxFloor: major.minor at least 3.2, and a
# version without digits ("master") is a development build.
tmux_meets_floor() {
    local version=$1
    local major
    local minor
    if [[ ! "$version" =~ ([0-9]+)\.([0-9]+) ]]; then
        return 0
    fi
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
    ((major > 3 || (major == 3 && minor >= 2)))
}

# The fixture tmux server daemonizes out of its sshd session, so it outlives
# a suite. Stop it by its socket path with the binary that started it, then
# drop the socket, which tmux leaves behind: the next pass's binary then
# starts a fresh server rather than talking to the last one.
stop_fixture_tmux_server() {
    local tmux_socket
    tmux_socket="$tmux_tmpdir/tmux-$(id -u)/default"
    if [[ -n "$tmux_binary" && -S "$tmux_socket" ]]; then
        env -u TMUX TMUX_TMPDIR="$tmux_tmpdir" \
            "$tmux_binary" -S "$tmux_socket" kill-server >/dev/null 2>&1 || true
    fi
    rm -f -- "$tmux_socket"
}

# Every TmuxTransportE2ETests test, by name. The lane asserts each one passed and
# pins the executed count to this list, and a run without tmux exempts exactly
# these from the full lane's provenance check — nothing wider.
tmux_suite_tests=(
    '"backend detection reports the tmux version beside the fixture herdr"'
    '"backend detection finds the herdr socket with no herdr on the PATH"'
    '"fixture detection finds every Host program inside the fixture"'
    '"a Host program that never answers times out and detection reports the rest"'
    '"ping answers as the tmux backend"'
    '"the Host resource sample reads finite fractions over SSH"'
    '"the snapshot lists sessions, windows and panes under tmux ids"'
    '"a new window in another session arrives as a resync event"'
    '"a pane status option change arrives as pane.agent_status_changed"'
    '"separators in a pane directory neither forge nor drop a pane"'
    '"separators in a status option forge no status change"'
    '"focusing a done agent makes it idle and keeps later replies in step"'
    '"herdr and tmux share one pooled SSH session"'
    '"a multi-line draft reaches cat byte-exact"'
    '"a shell terminal opens a WAYCAR_SHELL window that renames"'
    '"closing a pane and a tab removes exactly those"'
    '"attach produces output and survives a resize"'
    '"the control channel reattaches after its anchor session is killed"'
    '"without no-detach-on-destroy the control channel reattaches after %exit"'
    '"a bulk Close across the anchor exit closes every window"'
    '"close leaves no waycar sessions or control clients behind"'
)

tmux_binary="$(command -v tmux || true)"
if [[ -n "$tmux_binary" ]]; then
    tmux_version="$("$tmux_binary" -V 2>/dev/null | sed -n 's/^tmux //p' || true)"
fi
if [[ -n "$tmux_version" ]] && tmux_meets_floor "$tmux_version"; then
    # The fixture PATH below is the only PATH a fixture session sees, so link
    # tmux alone into it rather than widening that PATH to tmux's prefix.
    ln -s "$tmux_binary" "$fixture_dir/bin/tmux"
    tmux_fixture_available=1
elif [[ "$ci_lane" == "app" && "$mandatory_matrix" == "1" ]]; then
    echo "tmux 3.2 or later is required for the mandatory tmux backend suite" \
        "(found: ${tmux_version:-none})" >&2
    exit 1
elif [[ "$ci_lane" == "app" ]]; then
    echo "WARNING: no tmux 3.2 or later on this machine (found:" \
        "${tmux_version:-none}); TmuxTransportE2ETests will not run and this" \
        "gate does not prove the tmux backend." >&2
fi

# The runner's tmux is one release, and Hosts run what their distribution
# ships. Between 3.2a (Ubuntu 22.04, EL9), 3.4 (Ubuntu 24.04) and 3.5a
# (Debian 13) control mode differs in ways the current release cannot show:
# 3.4 and 3.5 vis-escape command replies, and nothing before 3.6 has
# no-detach-on-destroy. scripts/build-ci-tmux.sh builds each pinned release
# from its checksummed tarball into a per-machine cache, so only a cold cache
# pays for a build. Merge CI needs every one; elsewhere a missing build
# dependency narrows the run to the runner's tmux, loudly.
if [[ "$ci_lane" == "app" ]]; then
    if tmux_matrix_listing=$("$repo_root/scripts/build-ci-tmux.sh"); then
        while read -r matrix_version matrix_binary; do
            tmux_matrix_versions+=("$matrix_version")
            tmux_matrix_binaries+=("$matrix_binary")
        done <<< "$tmux_matrix_listing"
    elif [[ "$mandatory_matrix" == "1" ]]; then
        echo "The pinned tmux releases are required for the mandatory tmux" \
            "backend matrix and could not be built (see above)" >&2
        exit 1
    else
        echo "WARNING: the pinned tmux releases could not be built (see" \
            "above); TmuxTransportE2ETests will not run against them and" \
            "this gate does not prove the tmux backend on older tmux." >&2
    fi
fi

# The acceptance Host must have no socat. The forced session PATH below is the
# only PATH the product ever sees on this Host, so assert socat is absent from
# it rather than from the machine: a developer with socat in Homebrew still runs
# a genuinely socat-free Host.
fixture_session_path="$fixture_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin"
IFS=':' read -r -a fixture_path_entries <<< "$fixture_session_path"
for entry in "${fixture_path_entries[@]}"; do
    if [[ -x "$entry/socat" ]]; then
        echo "socat is reachable at $entry/socat; the Host must not provide it" >&2
        exit 1
    fi
done

ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/host_ed25519"
ssh-keygen -q -t rsa -b 3072 -N '' -f "$fixture_dir/host_rsa"
ssh-keygen -q -t ed25519 -N '' -f "$fixture_dir/host_jump_target_ed25519"

# A throwaway Device Key per run. The suites receive its seed in the fixture
# configuration, so no key committed to this repository ever authorizes a login.
ssh-keygen -q -t ed25519 -N '' -C waycar-ci-device-key -f "$fixture_dir/device_key"
device_key_seed="$(/usr/bin/python3 \
    scripts/fixtures/openssh-ed25519-seed.py "$fixture_dir/device_key")"
cp "$fixture_dir/device_key.pub" "$fixture_dir/authorized_keys"

# A separate RSA identity exercises the callback signer used by RSA Key auth.
# Security.framework consumes PKCS#1 DER, while sshd consumes the matching
# OpenSSH public line. The app only offers RSA-SHA2-512; it has no SHA-1
# signing fallback.
/usr/bin/openssl genrsa -out "$fixture_dir/rsa_key.pem" 3072 >/dev/null 2>&1
chmod 600 "$fixture_dir/rsa_key.pem"
/usr/bin/openssl rsa \
    -in "$fixture_dir/rsa_key.pem" \
    -outform DER \
    -out "$fixture_dir/rsa_key.der" \
    >/dev/null 2>&1
rsa_public_key="$(ssh-keygen -y -f "$fixture_dir/rsa_key.pem")"
printf '%s waycar-ci-rsa-key\n' "$rsa_public_key" > "$fixture_dir/rsa_key.pub"
cat "$fixture_dir/rsa_key.pub" >> "$fixture_dir/authorized_keys"
rsa_key_der="$(base64 < "$fixture_dir/rsa_key.der" | tr -d '\n')"
printf 'no-port-forwarding %s\n' "$(<"$fixture_dir/device_key.pub")" \
    > "$fixture_dir/authorized_keys-no-forwarding"
cp "$fixture_dir/authorized_keys" "$fixture_dir/authorized_keys-jump-target"

pairing_username="$fixture_username"
pairing_home="$fixture_dir/pairing-home"
pairing_authorized_keys="$pairing_home/.ssh/authorized_keys"
pairing_state_root="$fixture_dir/pairing-state"
mkdir -p "$pairing_home/.ssh" "$pairing_state_root"
cp "$fixture_dir/authorized_keys" "$pairing_authorized_keys"
chmod 700 "$pairing_home/.ssh"
chmod 600 "$pairing_authorized_keys"

# A key whose authorized_keys line forbids a PTY, so the package suite can
# prove a refused pty-req fails a PTY open cleanly. Appended after the
# copies above: only the shared file's sshd instances accept it.
ssh-keygen -q -t ed25519 -N '' -C waycar-ci-no-pty-key -f "$fixture_dir/no_pty_key"
no_pty_key_seed="$(/usr/bin/python3 \
    scripts/fixtures/openssh-ed25519-seed.py "$fixture_dir/no_pty_key")"
printf 'no-pty %s\n' "$(<"$fixture_dir/no_pty_key.pub")" >> "$fixture_dir/authorized_keys"

modern_config="$fixture_dir/sshd-modern.conf"
post_quantum_config="$fixture_dir/sshd-post-quantum.conf"
legacy_config="$fixture_dir/sshd-legacy.conf"
restricted_config="$fixture_dir/sshd-restricted.conf"
streamlocal_global_policy_config="$fixture_dir/sshd-streamlocal-global-policy.conf"
streamlocal_key_policy_config="$fixture_dir/sshd-streamlocal-key-policy.conf"
jump_target_config="$fixture_dir/sshd-jump-target.conf"
jump_forwarding_denied_config="$fixture_dir/sshd-jump-forwarding-denied.conf"
pairing_config="$fixture_dir/sshd-pairing.conf"
pairing_mismatched_config="$fixture_dir/sshd-pairing-mismatched.conf"
password_config="$fixture_dir/sshd-password.conf"

# DEBUG1, not VERBOSE: VERBOSE stops at "Starting session", so a client that
# never sees its channel reply (#343: exec request timed out 5s after sshd had
# started the pty session) cannot be told apart from one that never read it.
# DEBUG1 logs each channel request as sshd handles it, timestamped by the
# filter in start_unprivileged_sshd. The full logs go to the diagnostics
# artifact; the console tail is only an excerpt.
# Both variables share one `SetEnv` line on purpose: sshd keeps only the first
# `SetEnv` directive it reads, so a second line would silently drop
# TMUX_TMPDIR and send the tmux suite to the invoking account's own server.
write_common_config() {
    local port=$1
    local host_key=$2
    local pid_file=$3
    local session_env=${4:-"HOME=$fixture_home TMUX_TMPDIR=$tmux_tmpdir"}
    local force_command=${5:-$force_posix_shell}

    printf '%s\n' \
        "Port $port" \
        "ListenAddress 127.0.0.1" \
        "HostKey $host_key" \
        "PidFile $pid_file" \
        "PasswordAuthentication no" \
        "KbdInteractiveAuthentication no" \
        "PubkeyAuthentication yes" \
        "PubkeyAcceptedAlgorithms ssh-ed25519,rsa-sha2-512" \
        "AuthorizedKeysFile $fixture_dir/authorized_keys" \
        "UsePAM yes" \
        "PermitRootLogin no" \
        "AllowUsers $fixture_username" \
        "StrictModes no" \
        "PerSourcePenalties no" \
        "PrintMotd no" \
        "PrintLastLog no" \
        "LogLevel DEBUG1" \
        "Subsystem sftp $sftp_server" \
        "SetEnv $session_env" \
        "ForceCommand $force_command"
}

# An unprivileged sshd runs sessions under the invoking account's login shell,
# so the fixture would otherwise mean something different on every machine (the
# old privileged fixture pinned /bin/zsh on its throwaway account). Re-exec every
# session under POSIX sh instead, with the fixture PATH asserted above: sshd
# overwrites a `SetEnv PATH` with its own default, so it has to happen here.
# SSH_ORIGINAL_COMMAND carries the subsystem command too, so SFTP keeps working.
# This must never be set on the Pairing sshd, where it would override the
# authorized_keys forced command.
# The leading `exec` matters: without it the account's login shell forks a child
# for the wrapper, and a session that kills its own parent (the package's native
# resource reclamation test) would kill that child instead of the sshd session.
force_posix_shell="exec /bin/sh -c 'PATH=$fixture_session_path; export PATH;"
force_posix_shell+=" if [ -n \"\$SSH_ORIGINAL_COMMAND\" ]; then"
force_posix_shell+=" exec /bin/sh -c \"\$SSH_ORIGINAL_COMMAND\"; else exec /bin/sh; fi'"

write_common_config \
    "$modern_port" \
    "$fixture_dir/host_ed25519" \
    "$fixture_dir/sshd-modern.pid" > "$modern_config"
printf '%s\n' "KexAlgorithms curve25519-sha256" >> "$modern_config"
write_common_config \
    "$post_quantum_port" \
    "$fixture_dir/host_ed25519" \
    "$fixture_dir/sshd-post-quantum.pid" > "$post_quantum_config"
printf '%s\n' "KexAlgorithms mlkem768x25519-sha256" >> "$post_quantum_config"
write_common_config \
    "$legacy_port" \
    "$fixture_dir/host_rsa" \
    "$fixture_dir/sshd-legacy.pid" > "$legacy_config"
printf '%s\n' "HostKeyAlgorithms ssh-rsa" >> "$legacy_config"
write_common_config \
    "$restricted_port" \
    "$fixture_dir/host_ed25519" \
    "$fixture_dir/sshd-restricted.pid" > "$restricted_config"
printf '%s\n' \
    "KexAlgorithms curve25519-sha256" \
    "MaxSessions 0" \
    >> "$restricted_config"
write_common_config \
    "$streamlocal_global_policy_port" \
    "$fixture_dir/host_ed25519" \
    "$fixture_dir/sshd-streamlocal-global-policy.pid" \
    > "$streamlocal_global_policy_config"
printf '%s\n' \
    "AllowTcpForwarding yes" \
    "AllowStreamLocalForwarding no" \
    >> "$streamlocal_global_policy_config"
write_common_config \
    "$streamlocal_key_policy_port" \
    "$fixture_dir/host_ed25519" \
    "$fixture_dir/sshd-streamlocal-key-policy.pid" \
    > "$streamlocal_key_policy_config"
sed -i '' \
    "s|AuthorizedKeysFile $fixture_dir/authorized_keys|AuthorizedKeysFile $fixture_dir/authorized_keys-no-forwarding|" \
    "$streamlocal_key_policy_config"
printf '%s\n' \
    "AllowTcpForwarding yes" \
    "AllowStreamLocalForwarding yes" \
    >> "$streamlocal_key_policy_config"
write_common_config \
    "$jump_target_port" \
    "$fixture_dir/host_jump_target_ed25519" \
    "$fixture_dir/sshd-jump-target.pid" > "$jump_target_config"
sed -i '' \
    "s|AuthorizedKeysFile $fixture_dir/authorized_keys|AuthorizedKeysFile $fixture_dir/authorized_keys-jump-target|" \
    "$jump_target_config"
printf '%s\n' \
    "AllowTcpForwarding yes" \
    "AllowStreamLocalForwarding yes" \
    >> "$jump_target_config"
write_common_config \
    "$jump_forwarding_denied_port" \
    "$fixture_dir/host_ed25519" \
    "$fixture_dir/sshd-jump-forwarding-denied.pid" \
    > "$jump_forwarding_denied_config"
printf '%s\n' \
    "AllowTcpForwarding no" \
    "AllowStreamLocalForwarding yes" \
    >> "$jump_forwarding_denied_config"

write_pairing_config() {
    local listen_address=$1
    local host_key=$2
    local pid_file=$3

    printf '%s\n' \
        "Port $pairing_port" \
        "ListenAddress $listen_address" \
        "HostKey $host_key" \
        "PidFile $pid_file" \
        "PasswordAuthentication no" \
        "KbdInteractiveAuthentication no" \
        "PubkeyAuthentication yes" \
        "AuthorizedKeysFile $pairing_authorized_keys" \
        "UsePAM yes" \
        "PermitRootLogin no" \
        "AllowUsers $pairing_username" \
        "StrictModes no" \
        "PerSourcePenalties no" \
        "PrintMotd no" \
        "PrintLastLog no" \
        "LogLevel DEBUG1" \
        "Subsystem sftp $sftp_server" \
        "SetEnv TMUX_TMPDIR=$tmux_tmpdir"
}

write_pairing_config \
    127.0.0.1 \
    "$fixture_dir/host_ed25519" \
    "$fixture_dir/sshd-pairing.pid" > "$pairing_config"
write_pairing_config \
    ::1 \
    "$fixture_dir/host_jump_target_ed25519" \
    "$fixture_dir/sshd-pairing-mismatched.pid" > "$pairing_mismatched_config"

streamlocal_socket="$fixture_home/.config/herdr/herdr.sock"
streamlocal_stale_socket="$fixture_home/.waycar-ci/stale.sock"
streamlocal_wake_failure_socket="$fixture_home/.waycar-ci/stale-wake-failure.sock"
# In a folder that never exists: with the fixture's herdr stub on PATH this
# is a missing session, not a stopped herdr. A request starts neither.
streamlocal_missing_socket="$fixture_home/.waycar-ci/missing/herdr.sock"
streamlocal_count_file="$fixture_home/.waycar-ci/streamlocal-count"
ln -s \
    "$streamlocal_socket" \
    "$fixture_home/.config/herdr/sessions/fixture/herdr.sock"
/usr/bin/python3 scripts/fixtures/fake-herdr-streamlocal.py \
    --socket "$streamlocal_socket" \
    --stale-socket "$streamlocal_stale_socket" \
    --stale-socket "$streamlocal_wake_failure_socket" \
    --count-file "$streamlocal_count_file" \
    > "$fixture_dir/fake-herdr.log" 2>&1 &
fake_herdr_pid=$!

# The weak-network route. `pfctl`/`dummynet` need root and the Network Link
# Conditioner is machine-wide, so degrade one TCP path instead: the suite
# points its Host at this port and steers latency, bandwidth, fragmentation
# and abrupt severance through the control port. Deterministic by construction
# — every knob is a fixed duration or a byte count.
/usr/bin/python3 scripts/fixtures/weak-network-proxy.py \
    --listen-port "$weak_network_port" \
    --control-port "$weak_network_control_port" \
    --target-host 127.0.0.1 \
    --target-port "$modern_port" \
    > "$fixture_dir/weak-network.log" 2>&1 &
weak_network_pid=$!

start_unprivileged_sshd "$modern_config" "$fixture_dir/sshd-modern.log"
modern_pid=$started_sshd_pid
start_unprivileged_sshd \
    "$post_quantum_config" "$fixture_dir/sshd-post-quantum.log"
post_quantum_pid=$started_sshd_pid
start_unprivileged_sshd "$legacy_config" "$fixture_dir/sshd-legacy.log"
legacy_pid=$started_sshd_pid
start_unprivileged_sshd "$restricted_config" "$fixture_dir/sshd-restricted.log"
restricted_pid=$started_sshd_pid
start_unprivileged_sshd \
    "$streamlocal_global_policy_config" \
    "$fixture_dir/sshd-streamlocal-global-policy.log"
streamlocal_global_policy_pid=$started_sshd_pid
start_unprivileged_sshd \
    "$streamlocal_key_policy_config" \
    "$fixture_dir/sshd-streamlocal-key-policy.log"
streamlocal_key_policy_pid=$started_sshd_pid
start_unprivileged_sshd "$jump_target_config" "$fixture_dir/sshd-jump-target.log"
jump_target_pid=$started_sshd_pid
start_unprivileged_sshd \
    "$jump_forwarding_denied_config" \
    "$fixture_dir/sshd-jump-forwarding-denied.log"
jump_forwarding_denied_pid=$started_sshd_pid
start_unprivileged_sshd "$pairing_config" "$fixture_dir/sshd-pairing.log"
pairing_pid=$started_sshd_pid
start_unprivileged_sshd \
    "$pairing_mismatched_config" "$fixture_dir/sshd-pairing-mismatched.log"
pairing_mismatched_pid=$started_sshd_pid

# The herdr-core fixture (WAY-519): the 15 tests of CoreTransportE2ETests run
# against the real, pinned herdr-core behind a user-mode sshd whose sessions
# run under the scratch HOME $core_home, so every state file, socket and
# terminal of the core lives inside fixture_dir and nothing reaches the
# account's own core, the Herdr app's sockets or ~/Library. The release is
# fetched and checksum-verified by scripts/ci/core-contract.py, which owns the
# pin. A failed fetch fails the run: without it the suite skips, and its skips
# are exactly what the full lane's provenance check refuses to excuse.
if [[ "$ci_lane" == "app" ]]; then
    echo "==> Fetching the pinned herdr-core for CoreTransportE2ETests" >&2
    mkdir -p "$core_home/.local/bin"
    if ! core_download=$(/usr/bin/python3 \
        "$repo_root/scripts/ci/core-contract.py" \
        --fetch "$fixture_dir/core-download"); then
        echo "Could not fetch the pinned herdr-core (reason above)." \
            "CoreTransportE2ETests needs it and would skip without it, so" \
            "the lane fails here instead." >&2
        exit 1
    fi
    cp "$core_download" "$core_binary"
    chmod 755 "$core_binary"
    rm -rf -- "$fixture_dir/core-download"
    # macOS ships no profile that puts ~/.local/bin on a login shell's PATH,
    # as Ubuntu's stock .profile does for a Host that has the directory. The
    # suite's login-PATH test needs that Host shape.
    printf '%s\n' \
        'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac' \
        'export PATH' > "$core_home/.profile"
    cp "$core_home/.profile" "$core_home/.zprofile"
    # The session PATH is the plain system one: no fixture `herdr` stub or
    # tmux link, and no ~/.local/bin, which the suite asserts an SSH exec lacks.
    core_force_command="exec /bin/sh -c 'PATH=$core_path; export PATH;"
    core_force_command+=" if [ -n \"\$SSH_ORIGINAL_COMMAND\" ]; then"
    core_force_command+=" exec /bin/sh -c \"\$SSH_ORIGINAL_COMMAND\"; else exec /bin/sh; fi'"
    core_config="$fixture_dir/sshd-core.conf"
    write_common_config \
        "$core_port" \
        "$fixture_dir/host_ed25519" \
        "$fixture_dir/sshd-core.pid" \
        "HOME=$core_home" \
        "$core_force_command" > "$core_config"
    printf '%s\n' "KexAlgorithms curve25519-sha256" >> "$core_config"
    # `env -i`: the sshd, and so every session and the core it starts, inherits
    # nothing from this account's environment (HERDR_*, HC_*, TMUX).
    /usr/bin/env -i "PATH=$core_path" /usr/sbin/sshd -D -e -f "$core_config" \
        > >(timestamp_lines > "$fixture_dir/sshd-core.log") 2>&1 &
    core_pid=$!
    unprivileged_sshd_pids+=("$core_pid")
    core_fixture_configuration_base64=$(printf \
        '{"host":"127.0.0.1","port":%s,"username":"%s","deviceKeySeed":"%s"}' \
        "$core_port" \
        "$fixture_username" \
        "$device_key_seed" | base64)
fi

# Codex's real-SSH fixture, like core's, fails closed on a missing pin. The
# mock and sshd inherit no credentials, real Codex config, or backend env.
# Do not start the daemon here: the suite proves detection is side-effect-free
# and calls the production explicit-start path itself.
if [[ "$ci_lane" == "app" ]]; then
    echo "==> Fetching the pinned Codex for CodexTransportE2ETests" >&2
    mkdir -p "$codex_home/.local/bin" "$codex_home/.codex/app-server-daemon" \
        "$codex_home/tmp" "$codex_home/config" "$codex_home/data" \
        "$codex_home/state" "$codex_home/cache" "$codex_home/run" "$codex_home/tmux"
    if ! codex_download=$(/usr/bin/python3 "$repo_root/scripts/ci/codex-contract.py" \
        --fetch "$codex_home/package"); then
        echo "Could not fetch the pinned Codex; its mandatory E2E lane cannot run." >&2
        exit 1
    fi
    ln -s "$codex_download" "$codex_binary"
    if ! codex_node=$(command -v node); then
        echo "Codex's npm wrapper and model stand-in require Node on PATH (CI sets up Node 24)." >&2
        exit 1
    fi
    ln -s "$codex_node" "$codex_home/.local/bin/node"
    if [[ "$tmux_fixture_available" != "1" ]]; then
        echo "The Codex desk-TUI E2E requires tmux 3.2+ (as does the tmux lane)." >&2
        exit 1
    fi
    ln -s "$tmux_binary" "$codex_home/.local/bin/tmux"
    # shellcheck disable=SC2016
    printf '%s\n' 'export PATH="$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"' \
        > "$codex_home/.profile"
    cp "$codex_home/.profile" "$codex_home/.zprofile"
    cp "$repo_root/scripts/harness-lab/mock/server.js" "$codex_home/model.js"
    codex_fixture_configuration_base64=$(/usr/bin/python3 - \
        "$codex_home" "$codex_port" "$fixture_username" "$device_key_seed" "$codex_model_port" <<'PY'
import base64, hashlib, json, os, pathlib, subprocess, sys
home, port, username, seed, model_port = sys.argv[1:]
codex_home = pathlib.Path(home) / '.codex'
(codex_home / 'config.toml').write_text('''model = "mock-model"
model_provider = "e2e"
check_for_update_on_startup = false
approval_policy = "on-request"
approvals_reviewer = "user"
sandbox_mode = "read-only"
thread_unload_delay_secs = 2
[model_providers.e2e]
name = "E2E loopback model"
base_url = "http://127.0.0.1:%s/v1"
wire_api = "responses"
requires_openai_auth = false
[analytics]
enabled = false
[feedback]
enabled = false
[projects.%s]
trust_level = "trusted"
''' % (model_port, json.dumps(home)))
(codex_home / 'app-server-daemon/settings.json').write_text(json.dumps({
    'updater': {'autoUpdateEnabled': False}, 'shutdownGraceSeconds': 5}))
# X2 hashes the canonical advertised path, including macOS's /private prefix.
alias = (codex_home / 'app-server-control').resolve() / 'app-server-control.sock'
physical = pathlib.Path('/tmp').resolve() / ('codex-daemon-%d' % os.geteuid()) / hashlib.sha256(os.fsencode(alias)).hexdigest()
version = subprocess.check_output([home + '/.local/bin/codex', '--version'], env={
    'HOME': home, 'CODEX_HOME': str(codex_home), 'PATH': home + '/.local/bin:/usr/bin:/bin'}, text=True).strip()
assert version.startswith('codex-cli '), version
print(base64.b64encode(json.dumps(dict(host='127.0.0.1', port=int(port), username=username,
    deviceKeySeed=seed, home=home, physicalSocket=str(physical), version=version[len('codex-cli '):])).encode()).decode())
PY
    )
    codex_physical_socket=$(printf '%s' "$codex_fixture_configuration_base64" \
        | /usr/bin/python3 -c 'import base64,json,sys; print(json.loads(base64.b64decode(sys.stdin.read()))["physicalSocket"])')
    /usr/bin/env -i "HOME=$codex_home" "PATH=$codex_path" "PORT=$codex_model_port" \
        MOCK_FIRST_MS=1500 MOCK_DELAY_MS=1500 \
        "$codex_home/.local/bin/node" "$codex_home/model.js" \
        > "$fixture_dir/codex-model.log" 2>&1 &
    codex_model_pid=$!
    codex_model_ready=0
    for ((attempt = 0; attempt < 100; attempt += 1)); do
        # Quiet: refused connections before the server listens are expected.
        if /usr/bin/curl --noproxy '*' -fs "http://127.0.0.1:$codex_model_port/_health" >/dev/null; then
            codex_model_ready=1
            break
        fi
        kill -0 "$codex_model_pid" 2>/dev/null || break
        sleep 0.1
    done
    if [[ "$codex_model_ready" != 1 ]]; then
        echo "Codex model stand-in did not become healthy" >&2
        exit 1
    fi
    codex_force_command="exec /bin/sh -c 'PATH=$codex_path; export PATH;"
    codex_force_command+=" if [ -n \"\$SSH_ORIGINAL_COMMAND\" ]; then"
    codex_force_command+=" exec /bin/sh -c \"\$SSH_ORIGINAL_COMMAND\"; else exec /bin/sh; fi'"
    codex_session_env="HOME=$codex_home CODEX_HOME=$codex_home/.codex TMPDIR=$codex_home/tmp"
    codex_session_env+=" XDG_CONFIG_HOME=$codex_home/config XDG_DATA_HOME=$codex_home/data"
    codex_session_env+=" XDG_STATE_HOME=$codex_home/state XDG_CACHE_HOME=$codex_home/cache"
    codex_session_env+=" XDG_RUNTIME_DIR=$codex_home/run LANG=en_US.UTF-8 TMUX_TMPDIR=$codex_home/tmux"
    codex_config="$fixture_dir/sshd-codex.conf"
    write_common_config "$codex_port" "$fixture_dir/host_ed25519" \
        "$fixture_dir/sshd-codex.pid" "$codex_session_env" "$codex_force_command" > "$codex_config"
    printf '%s\n' "KexAlgorithms curve25519-sha256" >> "$codex_config"
    /usr/bin/env -i "PATH=$codex_path" /usr/sbin/sshd -D -e -f "$codex_config" \
        > >(timestamp_lines > "$fixture_dir/sshd-codex.log") 2>&1 &
    codex_pid=$!
    unprivileged_sshd_pids+=("$codex_pid")
fi

# OpenCode 2's real-SSH fixture, like Codex's, fails closed on a missing pin.
# The server, the model stand-in and every sshd session run with `env -i` and
# the scratch HOME/XDG directories, so nothing reads the account's own
# OpenCode config, state or server. The server is started here, as OpenCode's
# own clients would have started it on a Host (O3); the suite restarts it.
if [[ "$ci_lane" == "app" ]]; then
    echo "==> Fetching the pinned OpenCode for OpenCodeTransportE2ETests" >&2
    mkdir -p "$opencode_home/.local/bin" "$opencode_home/.local/state" "$opencode_home/.local/share" \
        "$opencode_home/.config/opencode" "$opencode_home/.cache" "$opencode_home/tmp" "$opencode_home/project"
    if ! opencode_download=$(/usr/bin/python3 "$repo_root/scripts/ci/opencode-contract.py" \
        --fetch "$opencode_home/package"); then
        echo "Could not fetch the pinned OpenCode; its mandatory E2E lane cannot run." >&2
        exit 1
    fi
    ln -s "$opencode_download" "$opencode_binary"
    if ! opencode_node=$(command -v node); then
        echo "OpenCode's model stand-in requires Node on PATH (CI sets up Node 24)." >&2
        exit 1
    fi
    ln -s "$opencode_node" "$opencode_home/.local/bin/node"
    cp "$repo_root/scripts/harness-lab/mock/server.js" "$opencode_home/model.js"
    # The contract check's provider and permission rules: shell asks (O23).
    /usr/bin/python3 - "$opencode_home" "$opencode_model_port" <<'PY'
import json, pathlib, sys
home, port = sys.argv[1:]
(pathlib.Path(home) / '.config/opencode/opencode.jsonc').write_text(json.dumps({
    'model': 'mock/mock-model', 'providers': {'mock': {'name': 'Mock', 'env': ['MOCK_API_KEY'],
        'package': '@opencode/ai/providers/openai-compatible',
        'settings': {'baseURL': 'http://127.0.0.1:%s/v1' % port, 'apiKey': 'mock'},
        'models': {'mock-model': {'name': 'Mock'}}}},
    'permissions': [{'action': 'shell', 'resource': '*', 'effect': 'ask'}]}))
PY
    /usr/bin/env -i "HOME=$opencode_home" "PATH=$opencode_path" "PORT=$opencode_model_port" \
        MOCK_FIRST_MS=100 MOCK_DELAY_MS=100 \
        "$opencode_home/.local/bin/node" "$opencode_home/model.js" \
        > "$fixture_dir/opencode-model.log" 2>&1 &
    opencode_model_pid=$!
    opencode_model_ready=0
    for ((attempt = 0; attempt < 100; attempt += 1)); do
        if /usr/bin/curl --noproxy '*' -fs "http://127.0.0.1:$opencode_model_port/_health" >/dev/null; then
            opencode_model_ready=1
            break
        fi
        kill -0 "$opencode_model_pid" 2>/dev/null || break
        sleep 0.1
    done
    if [[ "$opencode_model_ready" != 1 ]]; then
        echo "OpenCode model stand-in did not become healthy" >&2
        exit 1
    fi
    # The server inherits the environment of whatever starts it (O4): this
    # script now, an sshd session when the suite restarts it.
    opencode_session_env="HOME=$opencode_home TMPDIR=$opencode_home/tmp"
    opencode_session_env+=" XDG_CONFIG_HOME=$opencode_home/.config XDG_STATE_HOME=$opencode_home/.local/state"
    opencode_session_env+=" XDG_DATA_HOME=$opencode_home/.local/share XDG_CACHE_HOME=$opencode_home/.cache"
    opencode_session_env+=" LANG=en_US.UTF-8 SHELL=/bin/sh MOCK_API_KEY=mock"
    opencode_session_env+=" OPENCODE_DISABLE_AUTOUPDATE=1 OPENCODE_DISABLE_MODELS_FETCH=1"
    opencode_service() {
        # shellcheck disable=SC2086
        (cd "$opencode_home/project" && /usr/bin/env -i "PATH=$opencode_path" $opencode_session_env \
            "$opencode_binary" service "$@")
    }
    if ! opencode_service set port "$opencode_server_port" >/dev/null \
        || ! opencode_service set hostname 127.0.0.1 >/dev/null; then
        echo "Could not configure the scratch OpenCode server's port." >&2
        exit 1
    fi
    opencode_started=$(opencode_service start 2>&1) || true
    if [[ "$opencode_started" != *"http://127.0.0.1:$opencode_server_port"* ]]; then
        echo "The scratch OpenCode server did not start: $opencode_started" >&2
        exit 1
    fi
    # shellcheck disable=SC2086
    opencode_version=$(/usr/bin/env -i "PATH=$opencode_path" $opencode_session_env "$opencode_binary" --version)
    opencode_version=${opencode_version#opencode v}
    opencode_force_command="exec /bin/sh -c 'PATH=$opencode_path; export PATH;"
    opencode_force_command+=" if [ -n \"\$SSH_ORIGINAL_COMMAND\" ]; then"
    opencode_force_command+=" exec /bin/sh -c \"\$SSH_ORIGINAL_COMMAND\"; else exec /bin/sh; fi'"
    opencode_config="$fixture_dir/sshd-opencode.conf"
    write_common_config "$opencode_port" "$fixture_dir/host_ed25519" \
        "$fixture_dir/sshd-opencode.pid" "$opencode_session_env" "$opencode_force_command" > "$opencode_config"
    # direct-tcpip to the server's loopback port is all the suite forwards (O7).
    printf '%s\n' "KexAlgorithms curve25519-sha256" "AllowTcpForwarding local" >> "$opencode_config"
    /usr/bin/env -i "PATH=$opencode_path" /usr/sbin/sshd -D -e -f "$opencode_config" \
        > >(timestamp_lines > "$fixture_dir/sshd-opencode.log") 2>&1 &
    opencode_pid=$!
    unprivileged_sshd_pids+=("$opencode_pid")
    opencode_fixture_configuration_base64=$(printf \
        '{"host":"127.0.0.1","port":%s,"username":"%s","deviceKeySeed":"%s","home":"%s","serverPort":%s,"modelPort":%s,"version":"%s"}' \
        "$opencode_port" "$fixture_username" "$device_key_seed" "$opencode_home" \
        "$opencode_server_port" "$opencode_model_port" "$opencode_version" | base64)
fi

# Zellij's real-SSH fixture starts no sessions during provisioning. A failed
# pinned download fails the lane rather than turning its tests into skips.
if [[ "$ci_lane" == "app" ]]; then
    echo "==> Fetching the pinned Zellij for ZellijTransportE2ETests" >&2
    mkdir -p "$zellij_home/.local/bin" "$zellij_socket_dir" "$zellij_home/tmp" \
        "$zellij_home/.config" "$zellij_home/.local/state" \
        "$zellij_home/.local/share" "$zellij_home/.cache" "$zellij_home/run"
    chmod 700 "$zellij_socket_dir" "$zellij_home/run"
    if ! zellij_download=$(/usr/bin/python3 \
        "$repo_root/scripts/ci/zellij-contract.py" --fetch "$fixture_dir/zellij-download"); then
        echo "Could not fetch the pinned Zellij (reason above)." \
            "ZellijTransportE2ETests needs it and would skip without it, so" \
            "the lane fails here instead." >&2
        exit 1
    fi
    cp "$zellij_download" "$zellij_binary"
    chmod 755 "$zellij_binary"
    rm -rf -- "$fixture_dir/zellij-download"
    cat > "$zellij_home/.local/bin/fake-osc-agent" <<'SH'
#!/bin/sh
report() { printf '\033]7501;state=%s:app=pi\033\\' "$1"; }
report idle
while IFS= read -r line; do
    report working
    printf 'fake-reply: %s\n' "$line"
    case "$line" in HOLD*)
        i=0
        while [ ! -f "$HOME/run/fake-osc-release" ] && [ "$i" -lt 1200 ]; do
            sleep 0.1
            i=$((i+1))
        done
        rm -f "$HOME/run/fake-osc-release"
        ;;
    esac
    report done
done
SH
    chmod 755 "$zellij_home/.local/bin/fake-osc-agent"
    # The login profile expands HOME when sourced, not while provisioning.
    # shellcheck disable=SC2016
    printf '%s\n' 'PATH="$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"; export PATH' \
        > "$zellij_home/.profile"
    cp "$zellij_home/.profile" "$zellij_home/.zprofile"
    zellij_session_env="HOME=$zellij_home ZELLIJ_SOCKET_DIR=$zellij_socket_dir PATH=$zellij_path"
    zellij_session_env+=" TMPDIR=$zellij_home/tmp XDG_RUNTIME_DIR=$zellij_home/run"
    zellij_session_env+=" XDG_CONFIG_HOME=$zellij_home/.config XDG_STATE_HOME=$zellij_home/.local/state"
    zellij_session_env+=" XDG_DATA_HOME=$zellij_home/.local/share XDG_CACHE_HOME=$zellij_home/.cache"
    zellij_session_env+=" SHELL=/bin/sh TERM=xterm-256color LANG=en_US.UTF-8"
    zellij_force_command="exec /bin/sh -c 'PATH=$zellij_path; export PATH;"
    zellij_force_command+=" if [ -n \"\$SSH_ORIGINAL_COMMAND\" ]; then"
    zellij_force_command+=" exec /bin/sh -c \"\$SSH_ORIGINAL_COMMAND\"; else exec /bin/sh; fi'"
    zellij_config="$fixture_dir/sshd-zellij.conf"
    write_common_config "$zellij_port" "$fixture_dir/host_ed25519" \
        "$fixture_dir/sshd-zellij.pid" "$zellij_session_env" "$zellij_force_command" > "$zellij_config"
    printf '%s\n' "KexAlgorithms curve25519-sha256" >> "$zellij_config"
    /usr/bin/env -i "PATH=/usr/bin:/bin:/usr/sbin:/sbin" /usr/sbin/sshd -D -e -f "$zellij_config" \
        > >(timestamp_lines > "$fixture_dir/sshd-zellij.log") 2>&1 &
    zellij_pid=$!
    unprivileged_sshd_pids+=("$zellij_pid")
    zellij_fixture_configuration_base64=$(printf \
        '{"host":"127.0.0.1","port":%s,"username":"%s","deviceKeySeed":"%s","zellij":"%s","home":"%s","socketDir":"%s"}' \
        "$zellij_port" "$fixture_username" "$device_key_seed" "$zellij_binary" \
        "$zellij_home" "$zellij_socket_dir" | base64)
fi

# Real password authentication is the one behaviour macOS cannot exercise
# unprivileged: only root can verify an account password, and an unprivileged
# sshd can only authenticate the account it already runs as.
password_fixture_opted_out=0
if [[ "${WAYCAR_CI_PASSWORD_FIXTURE:-1}" == "0" ]]; then
    password_fixture_opted_out=1
fi
if [[ "$ci_lane" == "app" && "$password_fixture_opted_out" == "0" ]] \
    && sudo -n true >/dev/null 2>&1; then
    password_secret="$(uuidgen)-$(uuidgen)"
    password_home="$fixture_dir/password-home"
    account_lock_dir="$lock_root/password-account-allocation"
    if ! claim_resource_lock "$account_lock_dir" "password account allocation"; then
        echo "Another gate is allocating its temporary password account; retry shortly." >&2
        exit 1
    fi
    while dscl . -search /Users UniqueID "$password_uid" | grep -q .; do
        password_uid=$((password_uid + 1))
    done
    pick_password_username
    mkdir -p "$password_home"
    # EXIT/INT/TERM may arrive after sysadminctl creates only part of the user
    # record, so declare cleanup intent before starting that side effect.
    password_user_cleanup_needed=1
    provisioning_step create_password_user create_password_user || exit 1
    release_resource_lock "$account_lock_dir" "password account allocation"
    account_lock_dir=""
    provisioning_step "dscl IsHidden" \
        sudo -n dscl . -create "/Users/$password_username" IsHidden 1 || exit 1
    provisioning_step "chown password home" \
        sudo -n chown "$password_uid":20 "$password_home" || exit 1
    if dscl . -read /Groups/com.apple.access_ssh >/dev/null 2>&1; then
        password_ssh_sacl_added=1
        provisioning_step "dseditgroup com.apple.access_ssh" \
            sudo -n /usr/sbin/dseditgroup -o edit \
            -a "$password_username" -t user com.apple.access_ssh || exit 1
    fi
    printf '%s\n' \
        "Port $password_port" \
        "ListenAddress 127.0.0.1" \
        "HostKey $fixture_dir/host_ed25519" \
        "PidFile $password_pid_file" \
        "PasswordAuthentication yes" \
        "KbdInteractiveAuthentication no" \
        "PubkeyAuthentication yes" \
        "AuthorizedKeysFile $fixture_dir/authorized_keys" \
        "UsePAM yes" \
        "PermitRootLogin no" \
        "AllowUsers $password_username" \
        "StrictModes no" \
        "PerSourcePenalties no" \
        "PrintMotd no" \
        "PrintLastLog no" \
        "LogLevel DEBUG1" \
        "Subsystem sftp $sftp_server" \
        > "$password_config"
    password_fixture_available=1
    # Fail on host account authentication before compilation can hide it.
    export WAYCAR_PASSWORD_SSH_PREFLIGHT_PORT="$password_port"
    export WAYCAR_PASSWORD_SSH_PREFLIGHT_USERNAME="$password_username"
    preflight_status=0
    start_password_sshd || exit 1
    password_ssh_preflight || preflight_status=$?
    stop_status=0
    stop_privileged_sshd "$password_pid" "$password_pid_file" \
        || stop_status=$?
    if [[ "$stop_status" == "0" ]]; then
        password_pid=""
    fi
    unset WAYCAR_PASSWORD_SSH_PREFLIGHT_PORT
    unset WAYCAR_PASSWORD_SSH_PREFLIGHT_USERNAME
    if [[ "$preflight_status" != "0" || "$stop_status" != "0" ]]; then
        cat "$password_log" >&2
        password_log_printed=1
        exit 1
    fi
elif [[ "$ci_lane" == "app" && "$password_fixture_opted_out" == "1" ]]; then
    echo "==> WAYCAR_CI_PASSWORD_FIXTURE=0: skipping the real-password sshd" \
        "fixture, so no temporary macOS account is created." >&2
    echo "==> Twelve of the thirteen mandatory behaviours still run." >&2
elif [[ "$ci_lane" == "app" && "$mandatory_matrix" == "1" ]]; then
    echo "Merge CI requires passwordless sudo for the real-password fixture" \
        "(or WAYCAR_CI_PASSWORD_FIXTURE=0 to opt out)" >&2
    exit 1
elif [[ "$ci_lane" == "app" ]]; then
    echo "==> No passwordless sudo: skipping the real-password sshd fixture." >&2
    echo "==> Twelve of the thirteen mandatory behaviours still run." >&2
fi

/usr/bin/python3 -c '
import socket
import sys

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", int(sys.argv[1])))
server.listen()
connections = []
while True:
    connection, _ = server.accept()
    connections.append(connection)
' "$stall_port" >/dev/null 2>&1 &
stall_pid=$!

fixture_pids=(
    "$modern_pid"
    "$post_quantum_pid"
    "$legacy_pid"
    "$restricted_pid"
    "$stall_pid"
    "$streamlocal_global_policy_pid"
    "$streamlocal_key_policy_pid"
    "$jump_target_pid"
    "$jump_forwarding_denied_pid"
    "$pairing_pid"
    "$pairing_mismatched_pid"
    "$fake_herdr_pid"
    "$weak_network_pid"
)
fixture_ports=(
    "$modern_port"
    "$post_quantum_port"
    "$legacy_port"
    "$restricted_port"
    "$stall_port"
    "$streamlocal_global_policy_port"
    "$streamlocal_key_policy_port"
    "$jump_target_port"
    "$jump_forwarding_denied_port"
    "$pairing_port"
    "$weak_network_port"
    "$weak_network_control_port"
)
if [[ -n "$core_pid" ]]; then
    fixture_pids+=("$core_pid")
    fixture_ports+=("$core_port")
fi
if [[ -n "$codex_pid" ]]; then
    fixture_pids+=("$codex_pid" "$codex_model_pid")
    fixture_ports+=("$codex_port" "$codex_model_port")
fi
if [[ -n "$opencode_pid" ]]; then
    fixture_pids+=("$opencode_pid" "$opencode_model_pid")
    fixture_ports+=("$opencode_port" "$opencode_model_port" "$opencode_server_port")
fi

if [[ -n "$zellij_pid" ]]; then
    fixture_pids+=("$zellij_pid")
    fixture_ports+=("$zellij_port")
fi

fixture_is_listening() {
    local port
    for port in "${fixture_ports[@]}"; do
        nc -z 127.0.0.1 "$port" >/dev/null 2>&1 || return 1
    done
    nc -z ::1 "$pairing_port" >/dev/null 2>&1 || return 1
    [[ -S "$streamlocal_socket" ]] || return 1
    [[ -S "$streamlocal_stale_socket" ]] || return 1
    [[ -S "$streamlocal_wake_failure_socket" ]] || return 1
    return 0
}

for attempt in $(seq 1 50); do
    if fixture_is_listening; then
        break
    fi
    for pid in "${fixture_pids[@]}"; do
        if ! kill -0 "$pid" 2>/dev/null; then
            dump_fixture_logs
            exit 1
        fi
    done
    sleep 0.1
done

if ! fixture_is_listening; then
    dump_fixture_logs
    exit 1
fi

# `WAYCAR_SSH_E2E_REQUIRED=1` is the contract that turns a missing fixture into
# a failure instead of a green skip: see Tests/WaycarTests/Support/RealSSHFixture.
export WAYCAR_SSH_E2E_REQUIRED=1
# Stretches the real-sshd operation budgets (`Duration.sshdBudget` in both test
# targets) on a loaded host; 1 keeps the idle-machine literals.
export WAYCAR_SSH_E2E_TIMEOUT_SCALE="${WAYCAR_SSH_E2E_TIMEOUT_SCALE:-1}"
export WAYCAR_SSH_E2E_HOST=127.0.0.1
export WAYCAR_SSH_E2E_PORT="$modern_port"
export WAYCAR_SSH_E2E_PQ_PORT="$post_quantum_port"
export WAYCAR_SSH_E2E_LEGACY_PORT="$legacy_port"
export WAYCAR_SSH_E2E_RESTRICTED_PORT="$restricted_port"
export WAYCAR_SSH_E2E_STALL_PORT="$stall_port"
export WAYCAR_SSH_E2E_USERNAME="$fixture_username"
export WAYCAR_SSH_E2E_DEVICE_KEY_SEED="$device_key_seed"
export WAYCAR_SSH_E2E_NO_PTY_KEY_SEED="$no_pty_key_seed"
export WAYCAR_SSH_E2E_STREAMLOCAL_SOCKET="$streamlocal_socket"
export WAYCAR_SSH_E2E_WEAK_PORT="$weak_network_port"
export WAYCAR_SSH_E2E_WEAK_CONTROL_PORT="$weak_network_control_port"

password_fixture_json=null
if [[ "$password_fixture_available" == "1" ]]; then
    password_fixture_json=$(printf \
        '{"port":%s,"username":"%s","password":"%s"}' \
        "$password_port" \
        "$password_username" \
        "$password_secret")
fi
# The tmux fixture closes the object, so the tmux matrix can re-issue the
# configuration once per pinned release without rebuilding the rest of it.
fixture_configuration_head=$(printf \
    '{"host":"127.0.0.1","port":%s,"legacyPort":%s,"restrictedPort":%s,"stallPort":%s,"globalPolicyPort":%s,"keyPolicyPort":%s,"weakNetworkPort":%s,"weakNetworkControlPort":%s,"username":"%s","deviceKeySeed":"%s","rsaKeyDER":"%s","passwordFixture":%s,"streamLocalSocketPath":"%s","socketPath":"%s","staleSocketPath":"%s","wakeFailureStaleSocketPath":"%s","missingSocketPath":"%s","countFilePath":"%s","homePath":"%s","tmux":' \
    "$modern_port" \
    "$legacy_port" \
    "$restricted_port" \
    "$stall_port" \
    "$streamlocal_global_policy_port" \
    "$streamlocal_key_policy_port" \
    "$weak_network_port" \
    "$weak_network_control_port" \
    "$fixture_username" \
    "$device_key_seed" \
    "$rsa_key_der" \
    "$password_fixture_json" \
    "$streamlocal_socket" \
    "$streamlocal_socket" \
    "$streamlocal_stale_socket" \
    "$streamlocal_wake_failure_socket" \
    "$streamlocal_missing_socket" \
    "$streamlocal_count_file" \
    "$fixture_home")
# The base64 fixture configuration whose tmux fixture reports the given
# version, or that has no tmux fixture when the version is empty.
encode_fixture_configuration() {
    local version=$1
    local tmux_fixture_json=null
    if [[ -n "$version" ]]; then
        tmux_fixture_json=$(printf \
            '{"directory":"%s","version":"%s","cliStubs":{"root":"%s","codex":"%s","opencode":"%s"}}' \
            "$tmux_tmpdir" \
            "$version" \
            "$fixture_dir" \
            "$fixture_codex_version" \
            "$fixture_opencode_version")
    fi
    printf '%s%s}' "$fixture_configuration_head" "$tmux_fixture_json" | base64
}
fixture_tmux_version=""
if [[ "$tmux_fixture_available" == "1" ]]; then
    fixture_tmux_version="$tmux_version"
fi
fixture_configuration_base64=$(encode_fixture_configuration "$fixture_tmux_version")
jump_fixture_configuration=$(printf \
    '{"host":"127.0.0.1","jumpPort":%s,"forwardingDeniedPort":%s,"targetHost":"127.0.0.1","targetPort":%s,"outerStallPort":%s,"innerStallHost":"127.0.0.1","innerStallPort":%s,"username":"%s","deviceKeySeed":"%s","socketPath":"%s"}' \
    "$modern_port" \
    "$jump_forwarding_denied_port" \
    "$jump_target_port" \
    "$stall_port" \
    "$stall_port" \
    "$fixture_username" \
    "$device_key_seed" \
    "$streamlocal_socket")
jump_fixture_configuration_base64=$(printf '%s' "$jump_fixture_configuration" | base64)
pairing_fixture_configuration_base64=""
if [[ "$ci_lane" == "app" ]]; then
    # `WAYCAR_PAIR_ACCEPT_BIN` names a native Host Tools binary: the accept
    # entrypoint is `<bin> pair-accept`, and the empty `nodePath` tells the
    # test so. The Node accept script is gone (WAY-443); CI builds the binary
    # (scripts/ci/build-native-waycar.sh), a developer points at their own.
    pairing_node_path=""
    pairing_accept_script="${WAYCAR_PAIR_ACCEPT_BIN:-}"
    if [[ -z "$pairing_accept_script" ]]; then
        echo "WAYCAR_PAIR_ACCEPT_BIN is required for the mandatory Pairing ceremony suite;" \
            "build one with scripts/ci/build-native-waycar.sh" >&2
        exit 1
    fi
    if [[ ! -x "$pairing_accept_script" ]]; then
        echo "WAYCAR_PAIR_ACCEPT_BIN is not an executable: $pairing_accept_script" >&2
        exit 1
    fi
    pairing_fixture_configuration=$(printf \
        '{"host":"127.0.0.1","port":%s,"mismatchedHostAddress":"::1","username":"%s","deviceKeySeed":"%s","nodePath":"%s","acceptScriptPath":"%s","homePath":"%s","authorizedKeysPath":"%s","localStateRoot":"%s","remoteStateRoot":"%s"}' \
        "$pairing_port" \
        "$pairing_username" \
        "$device_key_seed" \
        "$pairing_node_path" \
        "$pairing_accept_script" \
        "$pairing_home" \
        "$pairing_authorized_keys" \
        "$pairing_state_root" \
        "$pairing_state_root")
    pairing_fixture_configuration_base64=$(printf \
        '%s' "$pairing_fixture_configuration" | base64)
fi

# Every lane whose executed count and skip budget this script pins exactly. The
# full lane's provenance assertion draws its evidence from these, so a lane that
# is not listed here proves nothing.
pinned_lane_logs=()

# Swift Testing filters exit zero having run nothing, so every mandatory suite
# asserts its executed count. `run_suite` also refuses any skip: with
# WAYCAR_SSH_E2E_REQUIRED set a fixture-backed suite must fail rather than skip,
# so a skip here means a condition that can still hide missing coverage.
run_suite() {
    local lane=$1
    local expected_tests=$2
    local expected_suites=$3
    local expected_skips=${4:-0}
    shift 4
    local log="$fixture_dir/$lane.log"
    local noun="suite"
    local skips
    local suite
    local -a selectors=()

    if [[ "$#" -eq 0 ]]; then
        echo "$lane has no test selectors" >&2
        exit 1
    fi
    for suite in "$@"; do
        selectors+=("-only-testing:WaycarTests/$suite")
    done

    if [[ "$expected_suites" != "1" ]]; then
        noun="suites"
    fi
    run_xcodebuild "$lane" "$xcodebuild_test_timeout_seconds" "$log" \
        test-without-building \
        -project Waycar.xcodeproj \
        -scheme Waycar \
        -derivedDataPath "$app_derived_data_path" \
        -destination "$simulator_destination" \
        -collect-test-diagnostics never \
        -parallel-testing-enabled NO \
        "${selectors[@]}"

    skips=$(grep -cE '(Test|Suite) .* skipped' "$log" || true)
    if [[ "$skips" != "$expected_skips" ]]; then
        echo "$lane skipped $skips tests; exactly $expected_skips may skip" >&2
        exit 1
    fi
    if ! grep -q \
        "Test run with $expected_tests tests in $expected_suites $noun passed" \
        "$log"; then
        echo "$lane did not execute all $expected_tests tests" >&2
        exit 1
    fi
    pinned_lane_logs+=("$log")
}

# Swift Testing's records and the library's own diagnostics (`[WaycarSSH] ...`,
# installed by the fixture and the package tests) share one merged output
# stream that xcodebuild relays in chunks, and a chunk can end inside a line.
# CI run 41144568333 logged `✔ Test "an IPv4 loopback ..." pa[WaycarSSH] ...
# ssed after 0.008 seconds.`: the test passed, but its `passed` record no
# longer matched, so the gate failed a green run. A test is proven when its
# `passed` record is intact, or when its `started` record is intact and the
# log's run summary says every test passed (a failed test never prints that
# summary). A name sits in both records, so a single cut cannot hide a test.
log_proves_test_passed() {
    local log=$1
    local test_name=$2

    if grep -qF "Test $test_name passed" "$log"; then
        return 0
    fi
    grep -qF "Test $test_name started" "$log" \
        && grep -qE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$log"
}

# Every behaviour the merge gate treats as mandatory names the test that proves
# it. A count alone cannot show that Events, resize, or SFTP specifically ran.
assert_behavior() {
    local behavior=$1
    local log_name=$2
    local test_name=$3
    local log="$fixture_dir/$log_name.log"

    if ! log_proves_test_passed "$log" "$test_name"; then
        echo "Mandatory behaviour not proven: $behavior ($test_name)" >&2
        exit 1
    fi
}

# The full lane runs with no fixture configured, so the fixture-backed suites
# skip there by design. That design is also how eleven percent of the lane's
# headline total can execute nothing while the run still reports success, which
# is why the full lane is not asserted on a total: the number a total guard
# would compare is satisfied by exactly the failure it exists to catch.
#
# Provenance is asserted instead. A full-lane skip is permitted only when one of
# the lanes this script pins with an exact executed count and an exact skip
# budget ran that same test to a pass. This is deliberately not an allow-list of
# suite names: a suite cannot be entered into it without also being made to run
# somewhere the gate checks, so a ninth suite joining the skip list fails here,
# by name, rather than reading as a rounding difference.
assert_full_lane_coverage() {
    local log=$1
    local executed_floor=$2
    local covered="$fixture_dir/pinned-lane-passes.txt"
    local skipped="$fixture_dir/full-lane-skips.txt"
    local unproven
    local total
    local skips
    local executed

    # `Test <name> passed after 1.234 seconds.` — the run summary reads
    # `Test run with N tests in M suites passed after ...`, which the same
    # pattern would otherwise reduce to a name, so it is deleted first. A
    # parameterized test passes as `Test <name> with N test cases passed
    # after ...` but skips as plain `Test <name> skipped`, so the count goes.
    cat "${pinned_lane_logs[@]}" \
        | sed -n \
            -e '/Test run with /d' \
            -e 's/^.*Test \(.*\) passed after .*$/\1/p' \
        | sed 's/ with [0-9][0-9]* test cases$//' \
        | LC_ALL=C sort -u > "$covered"
    if [[ "$password_fixture_available" != "1" ]]; then
        # The one behaviour a developer laptop or an opted-out runner
        # (WAYCAR_CI_PASSWORD_FIXTURE=0) may omit, and the only place a
        # full-lane skip is allowed to go unproven. Merge CI reaches this
        # branch only through that explicit opt-out. The two tests are named
        # rather than counted, so the exemption cannot widen into a budget
        # that later skips can hide inside.
        printf '%s\n' \
            '"password authentication and exec round trip through real sshd"' \
            '"incorrect password has a distinct authentication error"' \
            >> "$covered"
        LC_ALL=C sort -u -o "$covered" "$covered"
    fi
    if [[ "$tmux_fixture_available" != "1" ]]; then
        # A machine without tmux 3.2+ outside merge CI, which refuses to
        # start without it. The same named list the tmux lane asserts.
        printf '%s\n' "${tmux_suite_tests[@]}" >> "$covered"
        LC_ALL=C sort -u -o "$covered" "$covered"
    fi

    sed -n 's/^.*Test \(.*\) skipped: .*$/\1/p' "$log" \
        | LC_ALL=C sort -u > "$skipped"
    unproven=$(LC_ALL=C comm -23 "$skipped" "$covered")
    if [[ -n "$unproven" ]]; then
        echo "The full lane skipped tests that no pinned lane proved:" >&2
        echo "$unproven" >&2
        echo "Make each one run in a lane run_suite pins, or fix the skip." >&2
        exit 1
    fi

    total=$(sed -n \
        's/^.*Test run with \([0-9][0-9]*\) tests in .* passed after .*$/\1/p' \
        "$log" | tail -n 1)
    if [[ -z "$total" ]]; then
        echo "The full lane printed no passing run summary" >&2
        exit 1
    fi
    skips=$(grep -c 'Test .* skipped:' "$log" || true)
    executed=$((total - skips))
    # A floor, not an equality: adding tests must not require editing this
    # script, but losing coverage must be a deliberate act. Re-derive it as the
    # run summary's total minus the count of `Test ... skipped:` lines in the
    # same log. The total alone is not usable here — it counts the skips.
    if ((executed < executed_floor)); then
        echo "The full lane executed $executed tests ($total minus $skips" \
            "skipped); at least $executed_floor must run" >&2
        exit 1
    fi
    echo "==> Full lane executed $executed of $total tests," \
        "$skips skipped and all of them proven elsewhere." >&2
}

if [[ "$ci_lane" == "app" ]]; then
# The direct-streamlocal suite asserts that a stale socket is still stale.
# WaycarSSHTransportBehaviorE2ETests relinks that socket, so it must run after.
# Swift Testing counts a skipped test in the run total, so only the permitted
# skip count changes when the privileged password fixture is absent.
session_skip_count=0
if [[ "$password_fixture_available" != "1" ]]; then
    session_skip_count=2
fi
echo "==> Fixture provisioning finished at t+${SECONDS}s"
# One compilation for every app lane. Building up front keeps it outside the
# short-lived privileged fixture window, and every suite below plus the full
# lane then runs test-without-building against these products instead of
# paying a package-resolution and incremental-build check per session --
# measured at roughly half a minute per xcodebuild invocation on CI.
run_xcodebuild "Build for testing" "$xcodebuild_build_timeout_seconds" \
    "$fixture_dir/build-for-testing.log" \
    build-for-testing \
    -project Waycar.xcodeproj \
    -scheme Waycar \
    -derivedDataPath "$app_derived_data_path" \
    -destination "$simulator_destination" \
    -collect-test-diagnostics never
# A View helper called off the main actor only warns (View's MainActor is
# @preconcurrency, so -warnings-as-errors exempts it) and can trap at runtime.
# A retried attempt builds incrementally, so every attempt's log counts.
gate_status=0
"$repo_root/scripts/check-actor-isolated-calls.sh" \
    "$fixture_dir"/Build-for-testing-attempt-*.log || gate_status=$?
if [[ $gate_status -eq 1 ]]; then
    echo "Actor-isolation gate failed: @preconcurrency View isolation only warns, and can trap at runtime; mark the pure helper nonisolated or the caller @MainActor." >&2
    exit 1
elif [[ $gate_status -ne 0 ]]; then
    echo "actor-isolation gate could not read the build logs (status $gate_status)" >&2
    exit 1
fi
wait_for_simulator_boot
# Read through variable indirection by push_simulator_environment, which
# static analysis cannot follow; unset again by clear_simulator_environment.
# shellcheck disable=SC2034
{
    WAYCAR_SSH_E2E_CONFIG="$fixture_configuration_base64"
    WAYCAR_SSH_JUMP_E2E_CONFIG="$jump_fixture_configuration_base64"
    WAYCAR_PAIRING_E2E_CONFIG="$pairing_fixture_configuration_base64"
}
push_simulator_environment \
    WAYCAR_SSH_E2E_CONFIG \
    WAYCAR_SSH_JUMP_E2E_CONFIG \
    WAYCAR_SSH_E2E_TIMEOUT_SCALE \
    WAYCAR_PAIRING_E2E_CONFIG
if [[ "$password_fixture_available" == "1" ]]; then
    start_password_sshd || exit 1
fi
run_suite WaycarSSHSessionE2ETests 13 1 "$session_skip_count" \
    WaycarSSHSessionE2ETests
if [[ "$password_fixture_available" == "1" ]]; then
    if stop_privileged_sshd "$password_pid" "$password_pid_file"; then
        password_pid=""
    else
        exit 1
    fi
fi
run_suite WaycarSSHDirectStreamLocalE2ETests 9 1 0 \
    WaycarSSHDirectStreamLocalE2ETests
run_suite SharedFixtureE2ETests 155 6 0 \
    WaycarSSHPTYE2ETests \
    WaycarSSHJumpHostGateE2ETests \
    WaycarSSHTransportBehaviorE2ETests \
    ImageStagingE2ETests \
    WeakNetworkE2ETests \
    PairingCeremonyE2ETests

# Named behaviour assertions still identify their owning suite. Point those
# logical names at the one serialized lane log rather than duplicating it.
for suite in \
    WaycarSSHPTYE2ETests \
    WaycarSSHJumpHostGateE2ETests \
    WaycarSSHTransportBehaviorE2ETests \
    ImageStagingE2ETests \
    WeakNetworkE2ETests \
    PairingCeremonyE2ETests; do
    ln -s "SharedFixtureE2ETests.log" "$fixture_dir/$suite.log"
done

# The tmux backend (ADR 0026) against real sshd and the fixture's private tmux
# server. Its own lane: every test resets that one server, so nothing else may
# share the run with it.
if [[ "$tmux_fixture_available" == "1" ]]; then
    run_suite TmuxTransportE2ETests "${#tmux_suite_tests[@]}" 1 0 \
        TmuxTransportE2ETests
    for test_name in "${tmux_suite_tests[@]}"; do
        assert_behavior "tmux backend" TmuxTransportE2ETests "$test_name"
    done
fi

# The same suite once per pinned tmux release, each its own lane held to the
# same executed count and the same named tests as the pass above. Between
# passes the previous server is stopped and the fixture's `tmux` relinked, so
# every pass starts a fresh server of its own release under the same
# TMUX_TMPDIR, and the configuration tells the suite which version to expect.
tmux_matrix_count=${#tmux_matrix_versions[@]}
for ((tmux_matrix_index = 0; tmux_matrix_index < tmux_matrix_count; tmux_matrix_index += 1)); do
    stop_fixture_tmux_server
    tmux_binary="${tmux_matrix_binaries[$tmux_matrix_index]}"
    tmux_version="${tmux_matrix_versions[$tmux_matrix_index]}"
    ln -sfn "$tmux_binary" "$fixture_dir/bin/tmux"
    # Read through variable indirection by push_simulator_environment.
    # shellcheck disable=SC2034
    WAYCAR_SSH_E2E_CONFIG=$(encode_fixture_configuration "$tmux_version")
    push_simulator_environment \
        WAYCAR_SSH_E2E_CONFIG \
        WAYCAR_SSH_JUMP_E2E_CONFIG \
        WAYCAR_SSH_E2E_TIMEOUT_SCALE \
        WAYCAR_PAIRING_E2E_CONFIG
    tmux_matrix_lane="TmuxTransportE2ETests-tmux-$tmux_version"
    run_suite "$tmux_matrix_lane" "${#tmux_suite_tests[@]}" 1 0 \
        TmuxTransportE2ETests
    for test_name in "${tmux_suite_tests[@]}"; do
        assert_behavior "tmux $tmux_version backend" "$tmux_matrix_lane" \
            "$test_name"
    done
done

# herdr-core (ADR 0031) against the pinned release: one suite, 15 tests, none
# of which may skip. This is the lane the full lane's 15 skips are proven in.
# Test setup explicitly starts core through SSHTransportConnector; connecting
# to a stopped core must never start it.
# The core is stopped as soon as the suite ends, so nothing of it runs under
# the full lane, which has no fixture configured.
# Read through variable indirection by push_simulator_environment.
# shellcheck disable=SC2034
WAYCAR_CORE_E2E_CONFIG="$core_fixture_configuration_base64"
push_simulator_environment \
    WAYCAR_SSH_E2E_CONFIG \
    WAYCAR_SSH_JUMP_E2E_CONFIG \
    WAYCAR_SSH_E2E_TIMEOUT_SCALE \
    WAYCAR_PAIRING_E2E_CONFIG \
    WAYCAR_CORE_E2E_CONFIG
run_suite CoreTransportE2ETests 15 1 0 CoreTransportE2ETests
assert_behavior "Core explicit start" CoreTransportE2ETests \
    '"a stopped core stays stopped until the explicit SSH start and then connects"'
stop_core_fixture || exit 1

# The pinned real Codex lane proves the full lane's nine intentional skips.
# Read through variable indirection by push_simulator_environment.
# shellcheck disable=SC2034
WAYCAR_CODEX_E2E_CONFIG="$codex_fixture_configuration_base64"
push_simulator_environment \
    WAYCAR_SSH_E2E_TIMEOUT_SCALE \
    WAYCAR_CODEX_E2E_CONFIG
run_suite CodexTransportE2ETests 9 1 0 CodexTransportE2ETests
stop_codex_fixture || exit 1

# The pinned real OpenCode 2 lane proves the full lane's ten intentional skips.
# Read through variable indirection by push_simulator_environment.
# shellcheck disable=SC2034
WAYCAR_OPENCODE_E2E_CONFIG="$opencode_fixture_configuration_base64"
push_simulator_environment \
    WAYCAR_SSH_E2E_TIMEOUT_SCALE \
    WAYCAR_OPENCODE_E2E_CONFIG
run_suite OpenCodeTransportE2ETests 10 1 0 OpenCodeTransportE2ETests
stop_opencode_fixture || exit 1

# Two fixture-level tests against pinned Zellij; later transport tests extend
# this same counted, no-skips suite and its full-lane provenance.
# Read through variable indirection by push_simulator_environment.
# shellcheck disable=SC2034
WAYCAR_ZELLIJ_E2E_CONFIG="$zellij_fixture_configuration_base64"
push_simulator_environment \
    WAYCAR_SSH_E2E_TIMEOUT_SCALE \
    WAYCAR_ZELLIJ_E2E_CONFIG
run_suite ZellijTransportE2ETests 6 1 0 ZellijTransportE2ETests
stop_zellij_fixture || exit 1

if [[ "$password_fixture_available" == "1" ]]; then
    assert_behavior "real Password" WaycarSSHSessionE2ETests \
        '"password authentication and exec round trip through real sshd"'
fi
assert_behavior "Device Key" WaycarSSHSessionE2ETests \
    '"authorized Device Key authenticates and executes through real sshd"'
assert_behavior "RSA-SHA2-512" WaycarSSHTransportBehaviorE2ETests \
    '"RSA credentials authenticate when the Host accepts only RSA-SHA2-512"'
assert_behavior "Jump Host RSA-SHA2-512" WaycarSSHTransportBehaviorE2ETests \
    '"RSA authenticates both hops when each Host accepts only RSA-SHA2-512"'
assert_behavior "Bootstrap Key" PairingCeremonyE2ETests \
    'fullCeremonyEnrollsTheDeviceKeyAndVerifies()'
assert_behavior "two-hop trust" WaycarSSHJumpHostGateE2ETests \
    '"TOFU records both endpoints once and identifies either mismatch"'
# Trust at both hops is not the product. This is: connect the jump, forward to
# the target, authenticate it, exchange a real ping, and tear the two sessions
# down in order. Folded into the trust assertion it was invisible to rename.
assert_behavior "Jump Host product path" WaycarSSHJumpHostGateE2ETests \
    '"protocol 17 ping traverses independent SSH hops"'
assert_behavior "Jump Host direct mosh peer" WaycarSSHJumpHostGateE2ETests \
    '"a direct dial by name pins mosh to the address SSH reached"'
assert_behavior "Jump Host mosh keeps the Host name" WaycarSSHJumpHostGateE2ETests \
    '"a Jump Host dial keeps mosh on the Host name"'
assert_behavior "mosh loopback guard" WaycarSSHJumpHostGateE2ETests \
    '"the loopback guard adds -s only for an off-loopback arrival"'
assert_behavior "Events" WaycarSSHTransportBehaviorE2ETests \
    '"direct Host Events preserve framing, concurrency, and slot reuse"'
assert_behavior "PTY" WaycarSSHPTYE2ETests \
    '"PTY exec preserves raw IO, merged output, geometry, and exit status"'
assert_behavior "resize" WaycarSSHTransportBehaviorE2ETests \
    '"direct Host Attach preserves PTY IO, resize, end, and reuse"'
assert_behavior "shell terminal creation" WaycarSSHTransportBehaviorE2ETests \
    '"shell terminal creation sends one exact tab create request"'
assert_behavior "direct Host shell terminal Attach" \
    WaycarSSHTransportBehaviorE2ETests \
    '"direct Host ordinary terminal Attach preserves PTY behavior"'
assert_behavior "Jump Host shell terminal Attach" \
    WaycarSSHTransportBehaviorE2ETests \
    '"Jump Host ordinary terminal Attach preserves PTY behavior"'
assert_behavior "RPC does not stall Attach" WaycarSSHTransportBehaviorE2ETests \
    '"direct Host RPC does not stall Attach"'
assert_behavior "RPC does not stall Attach on a Jump Host" \
    WaycarSSHTransportBehaviorE2ETests \
    '"Jump Host RPC does not stall Attach"'
# These writes can return healthy response envelopes even when a serializer
# silently drops a field. Keep every distinct wire contract named (#165).
assert_behavior "agent focus target" WaycarSSHTransportBehaviorE2ETests \
    '"agent focus sends the exact opaque target through the RPC channel"'
assert_behavior "agent rename params" WaycarSSHTransportBehaviorE2ETests \
    '"agent rename sends its custom name and target exactly"'
assert_behavior "agent rename clear omission" WaycarSSHTransportBehaviorE2ETests \
    '"agent rename omits name when clearing a custom name"'
assert_behavior "worktree group tab close" WaycarSSHTransportBehaviorE2ETests \
    '"a refused worktree-group tab close closes the group"'
assert_behavior "worktree group pane close" WaycarSSHTransportBehaviorE2ETests \
    '"a refused worktree-group pane close closes the group"'
assert_behavior "worktree group close re-check" WaycarSSHTransportBehaviorE2ETests \
    '"a worktree-group close whose Workspace gained a tab closes nothing"'
assert_behavior "unconfirmed pane close keeps worktree group" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a pane close not confirmed by the user leaves a worktree group"'
assert_behavior "workspace rename params" WaycarSSHTransportBehaviorE2ETests \
    '"workspace rename sends its label and workspace id exactly"'
assert_behavior "pane read params and result" WaycarSSHTransportBehaviorE2ETests \
    '"pane read sends exact params and round trips the result"'
assert_behavior "worktree remove params" WaycarSSHTransportBehaviorE2ETests \
    '"confirmed worktree removal crosses the real wire dispatch seam"'
assert_behavior "worktree remove stale authorization writes nothing" \
    WaycarSSHTransportBehaviorE2ETests \
    '"stale worktree authorization writes no request bytes"'
# A tapped terminal path is remote-controlled; the SFTP-only preview read must
# keep it data and refuse anything but a bounded regular file, from one handle.
assert_behavior "untrusted path preview" WaycarSSHTransportBehaviorE2ETests \
    '"a tapped path previews only a regular file within the limit"'
assert_behavior "herdr API rejection" WaycarSSHTransportBehaviorE2ETests \
    '"a herdr error envelope surfaces as a typed API rejection"'
assert_behavior "session API rejection mapping" WaycarSSHTransportBehaviorE2ETests \
    '"the session maps a herdr rejection to apiRejected"'
# herdr's `agent_pane_busy` window: 0.7.5 opened it, 0.8.0 did not, and 0.9.1
# opens it again while a fresh pane's shell rc is still running, so the retry
# is live again. The named assertion keeps a refactor from silently dropping
# this documented server behaviour (#128).
assert_behavior "agent_pane_busy retry" WaycarSSHTransportBehaviorE2ETests \
    '"agent start waits out a fresh pane'"'"'s booting shell"'
# Each compensation cleans up different Host state; a count alone cannot tell
# which of them a change removed. New Workspace (#230) also names the
# create-then-start shape and the ambiguous-failure preserve rule, because
# those are the two ways that path can silently drift without changing the
# suite total.
assert_behavior "failed launch closes its pane" WaycarSSHTransportBehaviorE2ETests \
    '"a refused agent start closes the pane it created"'
assert_behavior "failed launch removes its worktree" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a refused worktree agent start removes the worktree it created"'
# herdr never fetches before `git worktree add`; these run real git on the
# fixture Host, so a fetch that silently fell back to the stale checkout, or a
# create sent after a failed fetch, cannot pass.
assert_behavior "latest-main worktree agent base" WaycarSSHTransportBehaviorE2ETests \
    '"a latest-main worktree agent start branches from origin'"'"'s fetched tip"'
assert_behavior "latest-main worktree shell base" WaycarSSHTransportBehaviorE2ETests \
    '"a latest-main worktree shell start branches from origin'"'"'s fetched tip"'
assert_behavior "latest-main non-main default branch" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a latest-main start follows origin'"'"'s HEAD to a non-main default branch"'
assert_behavior "latest-main existing branch skips the network" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a latest-main start of an existing branch sends no base and needs no origin"'
assert_behavior "latest-main linked worktree source refused" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a latest-main start from a linked worktree is refused before any Host work"'
assert_behavior "unfetchable origin creates nothing" \
    WaycarSSHTransportBehaviorE2ETests \
    '"an unfetchable origin fails a latest-main start before anything is created"'
# The Host-side bound under the worktree base resolution and CodexBar: past
# its limit a command must report 143 and leave no child behind.
assert_behavior "Host watchdog expiry" WaycarSSHTransportBehaviorE2ETests \
    '"the Host watchdog stops an overrunning command and its children"'
# Launch Prompt Files: the writer's real `/bin/sh` run must read back
# byte-exact and private, and sweep only stale `waycar-<uuid>` Codex
# profiles, through a symlinked Codex home too.
assert_behavior "Launch Prompt File writer" WaycarSSHTransportBehaviorE2ETests \
    '"Launch Prompt Files are written byte-exact and private, and only stale Waycar Codex profiles are swept"'
# The live Transport stages files at plain paths a launch line can carry.
assert_behavior "Launch Prompt File staging" WaycarSSHTransportBehaviorE2ETests \
    '"the Transport stages Launch Prompt Files at plain paths the launch line can carry"'
# The capability probe reads wrapped help, runs once per connection, finds
# the pane shell's Codex home, and fails uncached past its watchdog.
assert_behavior "Launch Prompt capability probe" WaycarSSHTransportBehaviorE2ETests \
    '"the Launch Prompt capability probe reads wrapped help once per connection and caches no failure"'
# A staged Chat Mode launch's typed line stays under the tty's MAX_CANON.
assert_behavior "staged Chat Mode launch line" WaycarSSHTransportBehaviorE2ETests \
    '"a staged Chat Mode launch types a short line that points at its staged prompts"'
# A worktree launch sends `worktree.create` at most once and recognises a
# worktree only by its exact branch: one on a minted branch is its own (and
# removable while no Agent can run there), one on a typed branch is adopted
# and never removed. An open worktree is jumped into before any fetch.
assert_behavior "unanswered worktree create is found, not resent" \
    WaycarSSHTransportBehaviorE2ETests \
    '"an unanswered worktree create is found and started in, never sent twice"'
assert_behavior "replayed worktree launch continues in its lost try's worktree" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a replayed worktree launch continues in its lost try'"'"'s worktree without fetching"'
assert_behavior "replay after a dispatched agent start joins that Agent" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a replay after a dispatched agent start returns the Agent already running"'
assert_behavior "unanswered create that made nothing is unconfirmed" \
    WaycarSSHTransportBehaviorE2ETests \
    '"an unanswered worktree create that made nothing fails unconfirmed after one create"'
assert_behavior "refused start removes the own worktree" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a refused agent start removes the own worktree found after an unanswered create"'
assert_behavior "typed branch after an unanswered create is adopted" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a typed-branch worktree found after an unanswered create is adopted, never removed"'
assert_behavior "slow worktree create needs no reconcile" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a slow worktree create inside its own budget needs no reconcile"'
assert_behavior "open branch with an Agent is joined" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a worktree launch on a branch already open with an Agent joins it without fetching"'
assert_behavior "joining prefers the requested Agent kind" \
    WaycarSSHTransportBehaviorE2ETests \
    '"joining an open worktree prefers an Agent of the requested kind"'
assert_behavior "open branch without an Agent starts one there" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a worktree launch on a branch already open without an Agent starts one there"'
assert_behavior "adopted worktree is never removed" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a refused agent start in an adopted worktree closes only its pane"'
assert_behavior "shell launch on an open branch opens a marked tab" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a shell worktree launch on a branch already open opens a marked tab there"'
assert_behavior "new-workspace launch skips tab.create" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a new-workspace agent start creates the workspace then starts in its root pane"'
assert_behavior "failed launch closes its workspace" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a refused new-workspace agent start closes the workspace it created"'
assert_behavior "ambiguous launch preserves its workspace" \
    WaycarSSHTransportBehaviorE2ETests \
    '"an ambiguous new-workspace agent start does not close the workspace"'
# The New Agent sheet awaits the start; a registration poll here once held it
# open for its whole 10 s budget on most launches.
assert_behavior "agent start does not wait for the launch to settle" \
    WaycarSSHTransportBehaviorE2ETests \
    '"an agent start returns without waiting for the launch to settle"'
# herdr 0.9.1 promotes a pending launch only on `agent.get` or a status change
# after its 3 s settle; an agent that idled before then stays unpromptable
# (#17). The window half keeps the settle clear of herdr's deadline, where
# `agent.get` clears the name instead.
assert_behavior "launch settle promotes a pending launch" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a launch herdr leaves pending becomes promptable with no composer"'
assert_behavior "launch settle stays inside its window" \
    WaycarSSHTransportBehaviorE2ETests \
    '"a launch that never settles is polled only inside the settle window"'
assert_behavior "SFTP" ImageStagingE2ETests \
    'directStagingStreamsPrivateFileAndAtomicallyRenamesThePart()'
assert_behavior "forwarding denial" WaycarSSHDirectStreamLocalE2ETests \
    '"global forwarding denial reports the honest combined cause"'
assert_behavior "key-policy forwarding denial" WaycarSSHDirectStreamLocalE2ETests \
    '"authorized_keys forwarding denial reports the honest combined cause"'
assert_behavior "forwarding denial never starts herdr" \
    WaycarSSHDirectStreamLocalE2ETests \
    '"a forwarding denial never runs the start command"'
assert_behavior "cancellation" WaycarSSHDirectStreamLocalE2ETests \
    '"cancellation closes only its channel and preserves connection reuse"'
assert_behavior "teardown" WaycarSSHSessionE2ETests \
    '"clean channel close leaves the connection reusable"'

# The weak-network half of the stress criterion. Each of these runs the named
# behaviour over the impairment proxy — added latency, a bandwidth cap,
# fragmentation, and abrupt severance — rather than over loopback at full speed.
assert_behavior "weak-network concurrent RPCs" WeakNetworkE2ETests \
    '"concurrent RPCs survive latency, a bandwidth cap, and fragmentation"'
assert_behavior "weak-network Events, Attach and SFTP staging" WeakNetworkE2ETests \
    '"Events and Attach stay live while SFTP stages over a degraded link"'
assert_behavior "weak-network cancellation" WeakNetworkE2ETests \
    '"cancelling a rate-starved upload frees only its own channel"'
assert_behavior "weak-network timeout" WeakNetworkE2ETests \
    '"bandwidth starvation times out instead of wedging the connection"'
assert_behavior "weak-network reconnect" WeakNetworkE2ETests \
    '"an abruptly severed link surfaces and a fresh connection recovers"'
assert_behavior "weak-network app lifecycle" WeakNetworkE2ETests \
    '"the events session survives a cut and a background round trip"'
assert_behavior "weak-network descriptor reclamation" WeakNetworkE2ETests \
    '"repeated degraded rounds reclaim every file descriptor"'
# The producer side of the property EventsSession redials on. Every other
# assertion of it in the repo is positive, so this is the only one that would
# notice it sticking true on a dead connection.
assert_behavior "disconnect is reported" WeakNetworkE2ETests \
    '"a severed link makes the transport report itself disconnected"'
# A Trust answered after the server dropped the waiting handshake (sshd's
# LoginGraceTime) must still connect, on a fresh connection.
assert_behavior "trust after the waiting connection dropped" WeakNetworkE2ETests \
    '"a key trusted after its waiting connection dropped still connects"'

fi

if [[ "$ci_lane" == "app" ]]; then
    clear_simulator_environment
fi

if [[ "$ci_lane" == "package" ]]; then
# Same overlap as the app lane: compilation needs the destination to exist,
# not to be booted, so remaining simulator boot runs under the build.
run_xcodebuild "WaycarSSH package build" "$xcodebuild_build_timeout_seconds" \
    "$fixture_dir/package-build.log" \
    build-for-testing \
    -scheme WaycarSSH \
    -derivedDataPath "$package_derived_data_path" \
    -destination "$simulator_destination" \
    -collect-test-diagnostics never
wait_for_simulator_boot

push_simulator_environment \
    WAYCAR_SSH_E2E_REQUIRED \
    WAYCAR_SSH_E2E_TIMEOUT_SCALE \
    WAYCAR_SSH_E2E_HOST \
    WAYCAR_SSH_E2E_PORT \
    WAYCAR_SSH_E2E_PQ_PORT \
    WAYCAR_SSH_E2E_RESTRICTED_PORT \
    WAYCAR_SSH_E2E_USERNAME \
    WAYCAR_SSH_E2E_DEVICE_KEY_SEED \
    WAYCAR_SSH_E2E_NO_PTY_KEY_SEED \
    WAYCAR_SSH_E2E_WEAK_PORT \
    WAYCAR_SSH_E2E_WEAK_CONTROL_PORT \
    WAYCAR_SSH_E2E_STREAMLOCAL_SOCKET

package_e2e_log="$fixture_dir/package-e2e.log"
run_xcodebuild "WaycarSSH package E2E" "$xcodebuild_test_timeout_seconds" \
    "$package_e2e_log" \
    test-without-building \
    -scheme WaycarSSH \
    -derivedDataPath "$package_derived_data_path" \
    -destination "$simulator_destination" \
    -collect-test-diagnostics never
clear_simulator_environment

package_e2e_tests=(
    '"exec stream round-trips several writes through cat without a PTY"'
    '"exec stream drains a stderr flood so stdout is not stalled"'
    '"exec stream stdout that the stderr drain queued is read at once"'
    '"post-negotiation transport loss is not an algorithm mismatch"'
    '"a key exchange failure is redialled once and then reported"'
    '"handshake negotiates post-quantum key exchange"'
    '"handshake falls back to Curve25519 key exchange"'
    '"remote transport loss reclaims every owned native resource"'
    '"an abruptly severed weak link reclaims every owned native resource"'
    '"a severed link makes a stream-local connection report itself disconnected"'
    '"a teardown that only runs out of its budget spares the session"'
    '"a genuine transport failure during teardown still invalidates the session"'
    '"issue 149 exec cleanup expiry invalidates allocated channels"'
    '"openSFTP pre-init failures spare the SSH session"'
    '"openSFTP pending init failures invalidate the SSH session"'
    '"compensation expiry reclaims SFTP and spares the SSH session"'
    '"compensation shutdown failure invalidates the SSH session"'
    '"issue 149 transport failures invalidate each tracked operation"'
    '"direct TCP/IP pump backpressures a fast raw writer without losing bytes"'
    '"multiplexed direct TCP shares SSH with exec and closes independently"'
    '"outbound backpressure does not livelock a channel open"'
    '"cancelling a transport-send owner drains"'
    '"cancelling a transport-send owner invalidates"'
    '"timing out a transport-send owner at loop-top drains"'
    '"timing out a transport-send owner at loop-top invalidates"'
    '"one-shot RPCs yield so a live PTY can progress"'
    '"cancelling a yielded one-shot distinguishes cleanup outcomes"'
    '"timing out a yielded one-shot distinguishes cleanup outcomes"'
    '"invalidation during a yielding wait does not touch a stale native pointer"'
    '"yielded channel teardown rejects same-id I/O and preserves close"'
    '"repeated invalidation reclaims every file descriptor"'
    '"measurement: Attach throughput with concurrent RPCs"'
    '"SFTP operations and close wait out an in-flight handle use"'
    '"a serialized channel-open wait honors deadline and cancellation"'
    '"an invalidation generation rejects a watch armed before it"'
    '"exec output and EOF that the stderr read queued finish the exec at once"'
    '"a transport-send owner error with outbound pending invalidates"'
    '"a bridge write to a closed peer reports peerClosed"'
    '"an IPv4 loopback connection reads its numeric peer"'
    '"a v4-mapped peer reads as dotted IPv4"'
    '"a link-local peer keeps its scope"'
    '"a NAT64 well-known-prefix peer reads as its embedded IPv4"'
    '"a non-IP socket has no peer address"'
)
package_e2e_proven=1
for package_e2e_test in "${package_e2e_tests[@]}"; do
    if ! log_proves_test_passed "$package_e2e_log" "$package_e2e_test"; then
        echo "Mandatory package test not proven: $package_e2e_test" >&2
        package_e2e_proven=0
    fi
done

if grep -q 'Suite "Session driver resource e2e" skipped' "$package_e2e_log" \
    || grep -q 'skipped:' "$package_e2e_log" \
    || ! grep -q 'Test run with 137 tests in 10 suites passed' "$package_e2e_log" \
    || [[ "$package_e2e_proven" != "1" ]]; then
    echo "The mandatory WaycarSSH package suites did not execute all one hundred thirty-seven tests" >&2
    exit 1
fi
exit 0
fi

# The full lane runs with no fixture configured, so every fixture-backed suite
# must skip — hence the clear above. The gate is still in force, though, and
# `WAYCAR_SSH_E2E_REQUIRED=0` says exactly that: driven by the gate, nothing
# configured. Suites whose only remaining route is a machine-owned resource
# (PairingCeremonyE2ETests would otherwise re-target the developer's own sshd
# and rewrite their real authorized_keys) refuse it and skip; see
# RealSSHFixture.isUnderMergeGate. cleanup() unsets it again on exit.
export WAYCAR_SSH_E2E_REQUIRED=0
push_simulator_environment WAYCAR_SSH_E2E_REQUIRED

# HarnessLabE2ETests drives the harness lab (scripts/harness-lab), which no CI
# runner has; it runs only through `make test-harness-lab`. Left in, its
# disabled suite would print a per-test skip that no pinned lane can prove, so
# the lane leaves it out by name rather than widening the provenance check.
full_lane_log="$fixture_dir/full-lane.log"
run_xcodebuild "Full app test lane" "$xcodebuild_test_timeout_seconds" \
    "$full_lane_log" \
    test-without-building \
    -project Waycar.xcodeproj \
    -scheme Waycar \
    -derivedDataPath "$app_derived_data_path" \
    -destination "$simulator_destination" \
    -collect-test-diagnostics never \
    -skip-testing:WaycarTests/HarnessLabE2ETests

# 769 is a floor, not the current count: it is what the lane executed the day it
# was written, deliberately left below what the lane reaches now so that adding
# tests never requires editing this script. Adding tests to a fixture-backed
# suite cannot move it at all — the full lane runs with no fixture, so those
# tests skip here and execute in a lane run_suite pins. The floor is not what
# proves the coverage; the skip-versus-pinned-lane comparison above it is.
assert_full_lane_coverage "$full_lane_log" 769

# The three groups that run only here, and so had no assertion of any kind
# before this. Each names the behaviour rather than counting the suite.
assert_behavior "admission reserves the production Events and Attach slots" \
    full-lane 'productionLimitsReserveEventsAndAttachWithinTheConnectionCeiling()'
assert_behavior "admission stays non-blocking" full-lane \
    'sessionSaturationDoesNotBlockForwardingAdmission()'
assert_behavior "admission respects the connection ceiling" full-lane \
    'connectionCeilingBoundsForwardingAndSessionTogether()'
assert_behavior "a cancelled waiter frees its admission capacity" full-lane \
    'cancelledWaiterDoesNotLeakConnectionCapacity()'
assert_behavior "TOFU migrates a legacy record rather than re-prompting" \
    full-lane 'matchingLegacyRecordMigratesAlgorithmMetadata()'
assert_behavior "TOFU refuses a changed key without overwriting it" full-lane \
    'changedKeyFailsWithoutConfirmationOrOverwrite()'
assert_behavior "no obsolete algorithm is negotiable" full-lane \
    '"the session driver negotiates no obsolete algorithm"'
assert_behavior "no private key entry point exists" full-lane \
    '"the SSH package has no private key entry point"'
assert_behavior "signing never exports a key" full-lane \
    '"the transport signs through CryptoKit rather than exporting a key"'
