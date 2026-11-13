#!/bin/bash
#
# TmuxTransportE2ETests (iOS Simulator) against a Linux test box
# (scripts/testboxes) instead of the local macOS sshd fixture.
#
#   scripts/run-tmux-e2e-remote.sh [options] <box>
#   make test-tmux-remote BOX=<box> [DRY_RUN=1] [HERDR_STUB=auto|on|off] [KEEP_SIM=1]
#
# <box> is ubuntu-24.04, ubuntu-22.04, debian-12, fedora or rocky-9. The suite
# logs in as `waycar-e2e`, whose sessions export a private TMUX_TMPDIR through
# sshd's `SetEnv`, so every tmux command reaches that account's own server;
# TmuxFixtureHost refuses to run tmux until it has read that value back.
#
# Options:
#   --dry-run          probe the box and print the decoded fixture configuration
#                      (Device Key seed redacted) and the commands a run would
#                      issue; changes nothing on the box or the Simulator
#   --herdr-stub MODE  auto (default): serve scripts/fixtures/fake-herdr-streamlocal.py
#                      at ~/.config/herdr/herdr.sock for the run when the box has
#                      Python 3.9+, else run without it. on: require it. off:
#                      never; the box is then a tmux-only Host and the three
#                      tests that need herdr skip.
#   --no-build         reuse the build/DerivedData test products as they are
#   --keep-simulator   leave the simulator leased and booted afterwards
#   --clean-box        only remove what an interrupted run left on the box
#
# Environment: WAYCAR_TESTBOX_HOST (required: the Docker host that publishes the box), WAYCAR_TESTBOX_PORT (the
# box's default), WAYCAR_TESTBOX_KEY (~/.ssh/waycar_testbox_e2e),
# WAYCAR_TESTBOX_USER (waycar-e2e), SIM (iPhone 17 Pro Max), DERIVED
# (build/DerivedData), WAYCAR_SSH_E2E_TIMEOUT_SCALE (2: a LAN Host, not
# loopback), WAYCAR_TMUX_REMOTE_TIMEOUT_SECONDS (1800).
#
# The box keeps nothing: the run takes ~/.waycar-ci as its lock and scratch
# directory (the tests write there, as on the macOS fixture), and cleanup
# stops the herdr stub and every tmux process of the account, empties
# TMUX_TMPDIR, and removes every top-level home entry the run added.

set -euo pipefail

script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
export PYTHONDONTWRITEBYTECODE=1

# The header comment from the synopsis down.
usage() {
    sed -n '6,/^set -euo/p' "$script_path" | sed -e '$d' -e 's/^# \{0,1\}//' >&2
    exit 2
}

dry_run=0
herdr_stub_mode=auto
build=1
keep_simulator=0
clean_only=0
box=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) dry_run=1 ;;
        --herdr-stub)
            [[ $# -ge 2 ]] || usage
            herdr_stub_mode=$2
            shift
            ;;
        --no-build) build=0 ;;
        --keep-simulator) keep_simulator=1 ;;
        --clean-box) clean_only=1 ;;
        -h | --help) usage ;;
        -*)
            echo "unknown option: $1" >&2
            usage
            ;;
        *)
            [[ -z "$box" ]] || usage
            box=$1
            ;;
    esac
    shift
done
[[ -n "$box" ]] || usage
case "$herdr_stub_mode" in
    auto | on | off) ;;
    *)
        echo "--herdr-stub must be auto, on or off, got: $herdr_stub_mode" >&2
        exit 2
        ;;
esac

# The ports the maintainers' deploy publishes each box on (WAYCAR_TESTBOX_PORT
# overrides).
case "$box" in
    ubuntu-24.04) default_port=22201 ;;
    ubuntu-22.04) default_port=22202 ;;
    debian-12) default_port=22203 ;;
    fedora) default_port=22204 ;;
    rocky-9) default_port=22205 ;;
    *)
        echo "unknown box: $box (ubuntu-24.04, ubuntu-22.04, debian-12, fedora, rocky-9)" >&2
        exit 2
        ;;
esac
box_host="${WAYCAR_TESTBOX_HOST:?set WAYCAR_TESTBOX_HOST to the Docker host that publishes the box}"
box_port="${WAYCAR_TESTBOX_PORT:-$default_port}"
box_user="${WAYCAR_TESTBOX_USER:-waycar-e2e}"
box_key="${WAYCAR_TESTBOX_KEY:-$HOME/.ssh/waycar_testbox_e2e}"
simulator="${SIM:-iPhone 17 Pro Max}"
derived_data="${DERIVED:-build/DerivedData}"
timeout_scale="${WAYCAR_SSH_E2E_TIMEOUT_SCALE:-2}"
test_timeout_seconds="${WAYCAR_TMUX_REMOTE_TIMEOUT_SECONDS:-1800}"
suite=TmuxTransportE2ETests
suite_source=Tests/WaycarTests/TmuxTransportE2ETests.swift
stub_source=scripts/fixtures/fake-herdr-streamlocal.py

[[ -f "$box_key" ]] || { echo "no test box key at $box_key" >&2; exit 1; }

# -F /dev/null: the developer's ssh_config (ControlMaster, SendEnv TMUX, ...)
# must not decide what the box sees. The box is recreated freely, so its host
# key is never pinned.
ssh_box() {
    ssh -F /dev/null -i "$box_key" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=15 \
        -p "$box_port" "$box_user@$box_host" "$@"
}

# Read-only. One `key=value` per line.
read -r -d '' remote_probe <<'EOF' || true
uid=$(id -u)
printf 'uid=%s\n' "$uid"
printf 'home=%s\n' "$HOME"
printf 'tmux_tmpdir=%s\n' "${TMUX_TMPDIR-}"
printf 'tmux_env=%s\n' "${TMUX-}"
if [ -n "${TMUX_TMPDIR-}" ] && [ -d "$TMUX_TMPDIR" ]; then
    printf 'tmux_tmpdir_owner=%s\n' "$(stat -c %u "$TMUX_TMPDIR")"
    printf 'tmux_tmpdir_mode=%s\n' "$(stat -c %a "$TMUX_TMPDIR")"
    printf 'tmux_tmpdir_entries=%s\n' "$(find "$TMUX_TMPDIR" -mindepth 1 | wc -l | tr -d ' ')"
fi
printf 'tmux_version=%s\n' "$(tmux -V 2>/dev/null | sed -n 's/^tmux //p')"
printf 'tmux_processes=%s\n' "$(pgrep -u "$uid" -x tmux | wc -l | tr -d ' ')"
printf 'python=%s\n' "$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
printf 'herdr_binary=%s\n' "$(command -v herdr 2>/dev/null)"
printf 'os=%s\n' "$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME-}")"
if [ -e "$HOME/.waycar-ci" ]; then printf 'busy=1\n'; fi
if [ -e "$HOME/.config/herdr/herdr.sock" ] || [ -L "$HOME/.config/herdr/herdr.sock" ]; then
    printf 'herdr_socket_taken=1\n'
fi
EOF

# $1: 1 to prepare ~/.config/herdr for the stub. ~/.waycar-ci is the lock: a
# second run (or one an interruption left behind) finds it and stops.
read -r -d '' remote_setup <<'EOF' || true
set -eu
umask 077
d="$HOME/.waycar-ci"
before=$(find "$HOME" -mindepth 1 -maxdepth 1 -printf '%f\n')
if ! mkdir "$d" 2>/dev/null; then
    echo "$d exists: another run holds this box, or an interrupted one left it (--clean-box)" >&2
    exit 3
fi
printf '%s\n' "$before" > "$d/home-before"
if [ "$1" = 1 ]; then
    for dir in "$HOME/.config" "$HOME/.config/herdr"; do
        if [ ! -d "$dir" ]; then
            mkdir "$dir"
            printf '%s\n' "$dir" >> "$d/created-dirs"
        fi
    done
fi
EOF

# The same stub, flags and layout the macOS fixture runs (run-ci-ios-tests.sh),
# with the socket at the default path so `.defaultSession` detection sees it.
read -r -d '' remote_start_stub <<'EOF' || true
set -eu
d="$HOME/.waycar-ci"
s="$HOME/.config/herdr/herdr.sock"
if [ -e "$s" ] || [ -L "$s" ]; then
    echo "$s already exists; refusing to replace it" >&2
    exit 1
fi
nohup python3 "$d/fake-herdr-streamlocal.py" \
    --socket "$s" \
    --stale-socket "$d/stale.sock" \
    --stale-socket "$d/stale-wake-failure.sock" \
    --count-file "$d/streamlocal-count" \
    > "$d/fake-herdr.log" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" > "$d/fake-herdr.pid"
i=0
while [ ! -S "$s" ] || [ ! -S "$d/stale-wake-failure.sock" ]; do
    if ! kill -0 "$pid" 2>/dev/null || [ "$i" -ge 100 ]; then
        echo "the herdr stub did not come up:" >&2
        cat "$d/fake-herdr.log" >&2
        exit 1
    fi
    i=$((i + 1))
    sleep 0.1
done
EOF

# Idempotent; also what --clean-box runs. Everything here belongs to this
# dedicated account, and the ~/.waycar-ci lock keeps a second run out, so
# every tmux process of the account is the suite's.
read -r -d '' remote_cleanup <<'EOF' || true
uid=$(id -u)
d="$HOME/.waycar-ci"
s="$HOME/.config/herdr/herdr.sock"
have_snapshot=0
before=""
created=""
if [ -f "$d/home-before" ]; then
    have_snapshot=1
    before=$(cat "$d/home-before")
fi
if [ -f "$d/created-dirs" ]; then
    created=$(cat "$d/created-dirs")
fi
wait_gone() {
    i=0
    while pgrep -u "$uid" "$@" > /dev/null 2>&1 && [ "$i" -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    pkill -KILL -u "$uid" "$@" 2> /dev/null || true
}
if [ -f "$d/fake-herdr.pid" ]; then
    kill "$(cat "$d/fake-herdr.pid")" 2> /dev/null || true
fi
pkill -u "$uid" -f 'fake-herdr-streamlocal\.py' 2> /dev/null || true
wait_gone -f 'fake-herdr-streamlocal\.py'
if [ -n "${TMUX_TMPDIR-}" ] && [ -d "$TMUX_TMPDIR" ]; then
    for socket in "$TMUX_TMPDIR"/tmux-*/*; do
        if [ -S "$socket" ]; then
            env -u TMUX tmux -S "$socket" kill-server 2> /dev/null || true
        fi
    done
fi
pkill -u "$uid" -x tmux 2> /dev/null || true
wait_gone -x tmux
# Pane commands the seeding helpers start; a server's SIGHUP normally ends them.
pkill -u "$uid" -fx 'sleep 86400' 2> /dev/null || true
if [ -n "${TMUX_TMPDIR-}" ] && [ -d "$TMUX_TMPDIR" ]; then
    find "$TMUX_TMPDIR" -mindepth 1 -delete
fi
if [ -S "$s" ]; then
    rm -f -- "$s"
fi
if [ "$have_snapshot" = 1 ]; then
    find "$HOME" -mindepth 1 -maxdepth 1 -printf '%f\n' | while IFS= read -r name; do
        if ! printf '%s\n' "$before" | grep -Fxq -- "$name"; then
            printf 'removing ~/%s\n' "$name"
            rm -rf -- "${HOME:?}/$name"
        fi
    done
else
    rm -rf -- "$d"
fi
printf '%s\n' "$created" | sed '1!G;h;$!d' | while IFS= read -r dir; do
    if [ -n "$dir" ] && [ -d "$dir" ]; then
        rmdir -- "$dir" 2> /dev/null || printf 'kept non-empty %s\n' "$dir"
    fi
done
leftover_tmux=$(pgrep -u "$uid" -x tmux | wc -l | tr -d ' ')
leftover_files=0
if [ -n "${TMUX_TMPDIR-}" ] && [ -d "$TMUX_TMPDIR" ]; then
    leftover_files=$(find "$TMUX_TMPDIR" -mindepth 1 | wc -l | tr -d ' ')
fi
printf 'after cleanup: %s tmux processes, %s entries in %s, ~/.waycar-ci %s\n' \
    "$leftover_tmux" "$leftover_files" "${TMUX_TMPDIR-}" \
    "$([ -e "$d" ] && echo present || echo absent)"
[ "$leftover_tmux" = 0 ] && [ "$leftover_files" = 0 ] && [ ! -e "$d" ]
EOF

if [[ "$clean_only" == 1 ]]; then
    echo "==> Cleaning $box_user@$box_host:$box_port ($box)"
    ssh_box 'sh -s' <<< "$remote_cleanup"
    exit
fi

# Mirrors HostBackendPresence.meetsTmuxFloor (and run-ci-ios-tests.sh): 3.2+,
# and a version without digits ("master") is a development build.
tmux_meets_floor() {
    local version=$1
    [[ "$version" =~ ([0-9]+)\.([0-9]+) ]] || return 0
    local major=${BASH_REMATCH[1]}
    local minor=${BASH_REMATCH[2]}
    ((major > 3 || (major == 3 && minor >= 2)))
}

echo "==> Probing $box_user@$box_host:$box_port ($box)"
probe_output=$(ssh_box 'sh -s' <<< "$remote_probe")
probe_uid="" probe_home="" probe_tmux_tmpdir="" probe_tmux_env=""
probe_tmux_tmpdir_owner="" probe_tmux_tmpdir_mode="" probe_tmux_version=""
probe_python="" probe_herdr_binary="" probe_busy="" probe_herdr_socket_taken=""
while IFS= read -r line; do
    value=${line#*=}
    case "${line%%=*}" in
        uid) probe_uid=$value ;;
        home) probe_home=$value ;;
        tmux_tmpdir) probe_tmux_tmpdir=$value ;;
        tmux_env) probe_tmux_env=$value ;;
        tmux_tmpdir_owner) probe_tmux_tmpdir_owner=$value ;;
        tmux_tmpdir_mode) probe_tmux_tmpdir_mode=$value ;;
        tmux_version) probe_tmux_version=$value ;;
        python) probe_python=$value ;;
        herdr_binary) probe_herdr_binary=$value ;;
        busy) probe_busy=$value ;;
        herdr_socket_taken) probe_herdr_socket_taken=$value ;;
    esac
done <<< "$probe_output"
while IFS= read -r line; do
    echo "    $line"
done <<< "$probe_output"

problems=()
[[ -n "$probe_home" ]] || problems+=("the session reports no HOME")
if [[ -z "$probe_tmux_tmpdir" ]]; then
    problems+=("the session exports no TMUX_TMPDIR (sshd SetEnv for $box_user)")
elif [[ -z "$probe_tmux_tmpdir_owner" ]]; then
    problems+=("TMUX_TMPDIR $probe_tmux_tmpdir does not exist")
elif [[ "$probe_tmux_tmpdir_owner" != "$probe_uid" || "$probe_tmux_tmpdir_mode" != 700 ]]; then
    problems+=("TMUX_TMPDIR $probe_tmux_tmpdir is not private to $box_user (owner $probe_tmux_tmpdir_owner, mode $probe_tmux_tmpdir_mode)")
fi
[[ -z "$probe_tmux_env" ]] || problems+=("the session inherits TMUX=$probe_tmux_env")
tmux_version=$probe_tmux_version
if [[ -z "$tmux_version" ]]; then
    problems+=("no tmux on the session PATH")
elif ! tmux_meets_floor "$tmux_version"; then
    problems+=("tmux $tmux_version is below the 3.2 floor")
fi
[[ -z "$probe_busy" ]] || problems+=("$probe_home/.waycar-ci exists: another run holds the box, or an interrupted one left it (--clean-box)")

python_version=$probe_python
python_ok=0
if [[ "$python_version" =~ ^([0-9]+)\.([0-9]+)$ ]] \
    && ((BASH_REMATCH[1] > 3 || (BASH_REMATCH[1] == 3 && BASH_REMATCH[2] >= 9))); then
    python_ok=1
fi
herdr_stub=0
case "$herdr_stub_mode" in
    on)
        herdr_stub=1
        [[ "$python_ok" == 1 ]] || problems+=("--herdr-stub on needs Python 3.9+ on the box (found: ${python_version:-none})")
        ;;
    auto) herdr_stub=$python_ok ;;
esac
if [[ "$herdr_stub" == 1 && -n "$probe_herdr_socket_taken" ]]; then
    problems+=("$probe_home/.config/herdr/herdr.sock already exists; the stub will not replace it")
fi
if [[ "$herdr_stub" == 0 && -n "$probe_herdr_binary" ]]; then
    problems+=("herdr is on the session PATH ($probe_herdr_binary), so the box is not tmux-only")
fi

# Programs live in variables rather than heredocs inside $(...), which
# macOS's bash 3.2 misparses.
read -r -d '' list_tests_program <<'EOF' || true
import re
import sys

source = open(sys.argv[1], encoding="utf-8").read()
pattern = (r'@Test\(\s*"((?:[^"\\]|\\.)*)"'
           r'(?:\s*,\s*\.enabled\(if: TmuxTransportE2EEnvironment\.(servesHerdr|hasCLIStubs))?')
for match in re.finditer(pattern, source):
    kind = {"servesHerdr": "herdr", "hasCLIStubs": "stubs"}.get(match.group(2), "plain")
    print(kind + "\t" + match.group(1))
EOF
# TmuxTransportE2EEnvironment.Fixture: the decoder ignores what it does not
# know, and only this suite runs, so the fields it reads are all it gets.
# socketPath is the default herdr path; nothing serves it when herdrStub is
# false, and only the herdr-gated tests, which then skip, read it.
read -r -d '' fixture_program <<'EOF' || true
import base64
import json
import sys

host, port, username, seed, home, directory, version, stub = sys.argv[1:]
print(base64.b64encode(json.dumps({
    "host": host,
    "port": int(port),
    "username": username,
    "deviceKeySeed": seed,
    "socketPath": f"{home}/.config/herdr/herdr.sock",
    "homePath": home,
    "tmux": {"directory": directory, "version": version, "herdrStub": stub == "1"},
}, separators=(",", ":")).encode()).decode())
EOF

# The tests by display name, and those gated on the herdr stub.
suite_listing=$(python3 -c "$list_tests_program" "$suite_source")
expected_passes=()
expected_skips=()
while IFS=$'\t' read -r kind name; do
    # The macOS fixture's codex and OpenCode stubs never exist on a box.
    if [[ "$kind" == stubs || ("$kind" == herdr && "$herdr_stub" == 0) ]]; then
        expected_skips+=("$name")
    else
        expected_passes+=("$name")
    fi
done <<< "$suite_listing"
((${#expected_passes[@]} > 0)) || problems+=("found no @Test in $suite_source")

device_key_seed=$(python3 scripts/fixtures/openssh-ed25519-seed.py "$box_key")
fixture_base64=$(python3 -c "$fixture_program" "$box_host" "$box_port" "$box_user" \
    "$device_key_seed" "$probe_home" "$probe_tmux_tmpdir" "$tmux_version" "$herdr_stub")

echo "==> WAYCAR_SSH_E2E_CONFIG for $box (decoded, seed redacted)"
python3 -c '
import base64, json, sys
config = json.loads(base64.b64decode(sys.argv[1]))
config["deviceKeySeed"] = "<redacted>"
print(json.dumps(config, indent=2))
' "$fixture_base64"
echo "    herdr stub: $([[ "$herdr_stub" == 1 ]] && echo "served for the run (Python $python_version)" || echo "none (mode $herdr_stub_mode, Python ${python_version:-none}); Host role tmux-only")"
echo "    expect ${#expected_passes[@]} passing, ${#expected_skips[@]} skipped:"
for name in "${expected_skips[@]:+${expected_skips[@]}}"; do
    echo "      skip $name"
done

if ((${#problems[@]} > 0)); then
    printf 'box not usable: %s\n' "${problems[@]}" >&2
    exit 1
fi

build_command=(xcodebuild build-for-testing -project Waycar.xcodeproj -scheme Waycar
    -destination "platform=iOS Simulator,name=$simulator" -derivedDataPath "$derived_data")
# The destination is pinned to the leased UDID below.
test_arguments=(test-without-building -disableAutomaticPackageResolution
    -project Waycar.xcodeproj -scheme Waycar
    -derivedDataPath "$derived_data"
    -collect-test-diagnostics never -parallel-testing-enabled NO
    "-only-testing:WaycarTests/$suite")

if [[ "$dry_run" == 1 ]]; then
    echo "==> Dry run; a run would:"
    [[ "$build" == 1 ]] && echo "    ${build_command[*]}"
    echo "    scripts/sim-slot.py acquire '$simulator'"
    echo "    lock the box (~/.waycar-ci)$([[ "$herdr_stub" == 1 ]] && echo ", start the herdr stub at $probe_home/.config/herdr/herdr.sock")"
    echo "    xcrun simctl spawn <UDID> launchctl setenv WAYCAR_SSH_E2E_CONFIG <${#fixture_base64} base64 chars>"
    echo "    xcrun simctl spawn <UDID> launchctl setenv WAYCAR_SSH_E2E_TIMEOUT_SCALE $timeout_scale"
    echo "    WAYCAR_SSH_E2E_REQUIRED=1 python3 scripts/run-app-simulator-tests.py ${test_arguments[*]} -destination platform=iOS Simulator,id=<UDID>"
    echo "    clean the box, unset the Simulator environment$([[ "$keep_simulator" == 0 ]] && echo ", scripts/sim-slot.py release <UDID>")"
    exit 0
fi

work_dir=$(mktemp -d "/tmp/waycar-tmux-remote-$box.XXXXXX")
log="$work_dir/$suite.log"
box_claimed=0
simulator_udid=""
environment_pushed=0
# Set only once this run holds the device lock; claim_guard while it holds the
# guard that serializes taking it.
device_lock=""
claim_guard=""
lock_token="$$-$(uuidgen)"
lock_start=$(ps -o lstart= -p "$$" | sed 's/^ *//; s/ *$//')
status=0

cleanup() {
    local exit_status=$?
    trap - EXIT INT TERM
    ((status != 0)) || status=$exit_status
    if [[ "$box_claimed" == 1 ]]; then
        echo "==> Cleaning $box"
        if [[ "$herdr_stub" == 1 ]]; then
            # shellcheck disable=SC2016 # expands on the box
            ssh_box 'cat "$HOME/.waycar-ci/fake-herdr.log" 2>/dev/null' \
                > "$work_dir/fake-herdr.log" 2>/dev/null || true
        fi
        if ! ssh_box 'sh -s' <<< "$remote_cleanup"; then
            echo "box cleanup incomplete; rerun: $script_path --clean-box $box" >&2
            ((status != 0)) || status=1
        fi
    fi
    if [[ "$environment_pushed" == 1 ]]; then
        xcrun simctl spawn "$simulator_udid" launchctl unsetenv WAYCAR_SSH_E2E_CONFIG || true
        xcrun simctl spawn "$simulator_udid" launchctl unsetenv WAYCAR_SSH_E2E_TIMEOUT_SCALE || true
    fi
    if [[ -n "$device_lock" && "$(cat "$device_lock/token" 2> /dev/null || true)" == "$lock_token" ]]; then
        rm -rf -- "$device_lock"
    fi
    if [[ -n "$claim_guard" ]]; then
        rmdir "$claim_guard" 2> /dev/null || true
    fi
    if [[ -n "$simulator_udid" && "$keep_simulator" == 0 ]]; then
        scripts/sim-slot.py release "$simulator_udid" || true
    fi
    if [[ "$status" == 0 ]]; then
        rm -rf -- "$work_dir"
    else
        echo "==> $box: FAILED (status $status); logs kept in $work_dir" >&2
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'status=130; exit 130' INT
trap 'status=143; exit 143' TERM

# Compile before taking the box or a simulator slot, as `make test-app` does.
if [[ "$build" == 1 ]]; then
    echo "==> Build for testing"
    build_status=0
    "${build_command[@]}" > "$work_dir/build-for-testing.log" 2>&1 || build_status=$?
    # Non-fatal actor-isolation gate (AGENTS.md, Conventions): this build shares
    # DerivedData with `make test-app`, so touch offenders for it to report.
    scripts/check-actor-isolated-calls.sh --touch "$work_dir/build-for-testing.log" || {
        [[ $? -ne 1 ]] || echo "actor-isolation warnings found; touched the files so \`make test-app\` reports them" >&2
    }
    if [[ "$build_status" != 0 ]]; then
        tail -n 40 "$work_dir/build-for-testing.log" >&2
        exit 1
    fi
elif ! compgen -G "$derived_data/Build/Products/*.xctestrun" > /dev/null; then
    echo "--no-build, but $derived_data has no .xctestrun" >&2
    exit 1
fi

echo "==> Acquiring $simulator"
simulator_udid=$(scripts/sim-slot.py acquire "$simulator" | tail -n 1)
[[ "$simulator_udid" =~ ^[0-9A-F-]{36}$ ]] || {
    echo "sim-slot granted no UDID ($simulator_udid)" >&2
    simulator_udid=""
    exit 1
}
# The fixture reaches the tests through per-device launchd state, so one run
# per device at a time: another box's run on this UDID waits here.

# True when the run that took lock $1 is gone: no pid, no such process, or a
# process that reused the pid but started at another time.
lock_is_stale() {
    local owner actual start
    owner=$(cat "$1/pid" 2> /dev/null || true)
    [[ -n "$owner" ]] || return 0
    actual=$(ps -o lstart= -p "$owner" 2> /dev/null | sed 's/^ *//; s/ *$//' || true)
    [[ -n "$actual" ]] || return 0
    start=$(cat "$1/start" 2> /dev/null || true)
    [[ -n "$start" && "$start" != "$actual" ]]
}

# Takes lock $1 when it is free or its run is gone (status 1 while another run
# holds it), as scripts/run-ci-ios-tests.sh claims its resource locks: the
# $1.claiming guard serializes the stale check with the removal and the take,
# so no run removes a lock another run has just taken. The guard is never
# reclaimed automatically; one left by a run killed inside this instant is
# reported for the operator to remove (status 2).
take_device_lock() {
    local lock=$1 attempt taken=1
    for ((attempt = 0; attempt < 100; attempt += 1)); do
        if mkdir "$lock.claiming" 2> /dev/null; then
            claim_guard="$lock.claiming"
            break
        fi
        sleep 0.05
    done
    if [[ -z "$claim_guard" ]]; then
        echo "another run is changing $lock; if none is starting, remove the orphaned guard $lock.claiming" >&2
        return 2
    fi
    if [[ -d "$lock" ]] && lock_is_stale "$lock"; then
        echo "    reclaiming the lock on $simulator_udid (pid $(cat "$lock/pid" 2> /dev/null || echo '?') is gone)"
        rm -rf -- "$lock"
    fi
    if mkdir "$lock" 2> /dev/null; then
        printf '%s' "$lock_token" > "$lock/token"
        printf '%s' "$$" > "$lock/pid"
        printf '%s' "$lock_start" > "$lock/start"
        taken=0
    fi
    rmdir "$claim_guard"
    claim_guard=""
    return "$taken"
}

lock_path="/tmp/waycar-tmux-remote-$simulator_udid.lock"
waited=0
until take_device_lock "$lock_path"; do
    lock_status=$?
    ((lock_status == 1)) || exit 1
    holder=$(cat "$lock_path/pid" 2> /dev/null || true)
    ((waited % 60 == 0)) && echo "    waiting for the remote tmux run holding $simulator_udid (pid ${holder:-?})"
    ((waited < 3600)) || { echo "timed out waiting for $simulator_udid" >&2; exit 1; }
    sleep 5
    waited=$((waited + 5))
    # Keep the lease fresh while queued behind the other run.
    ((waited % 300 == 0)) && scripts/sim-slot.py acquire "$simulator_udid" > /dev/null
done
device_lock=$lock_path

# Exit 3 is the lock held by someone else: nothing of ours to clean. Any
# other failure after the script started may have left our state; 255 is ssh
# itself failing, before the script could take anything.
echo "==> Preparing $box"
set +e
ssh_box 'sh -s' "$herdr_stub" <<< "$remote_setup"
setup_status=$?
set -e
if ((setup_status != 3 && setup_status != 255)); then
    box_claimed=1
fi
((setup_status == 0)) || exit 1
if [[ "$herdr_stub" == 1 ]]; then
    # shellcheck disable=SC2016 # expands on the box
    ssh_box 'cat > "$HOME/.waycar-ci/fake-herdr-streamlocal.py"' < "$stub_source"
    ssh_box 'sh -s' <<< "$remote_start_stub"
fi

xcrun simctl spawn "$simulator_udid" launchctl setenv WAYCAR_SSH_E2E_CONFIG "$fixture_base64"
environment_pushed=1
xcrun simctl spawn "$simulator_udid" launchctl setenv WAYCAR_SSH_E2E_TIMEOUT_SCALE "$timeout_scale"
# The scheme forwards this one from the shell (project.yml): a fixture the
# suite cannot use fails it instead of skipping it.
export WAYCAR_SSH_E2E_REQUIRED=1

echo "==> $suite against $box (tmux $tmux_version) on $simulator_udid; log: $log"
set +e
python3 scripts/run-with-timeout.py \
    --timeout-seconds "$test_timeout_seconds" \
    --label "$suite-$box" \
    --diagnostics-dir "$work_dir/diagnostics" \
    -- python3 scripts/run-app-simulator-tests.py "${test_arguments[@]}" \
    -destination "platform=iOS Simulator,id=$simulator_udid" 2>&1 | tee "$log" \
    | grep -E '(Test|Suite) .* (passed|failed|skipped)|recorded an issue|error:|\*\* TEST|^\[[0-9]+\] |^    (frame|test|reports): '
test_status=${PIPESTATUS[0]}
set -e

failures=()
((test_status == 0)) || failures+=("test run exited $test_status")
for name in "${expected_passes[@]}"; do
    grep -qF "Test \"$name\" passed" "$log" || failures+=("did not pass: $name")
done
for name in "${expected_skips[@]:+${expected_skips[@]}}"; do
    grep -qF "Test \"$name\" skipped" "$log" || failures+=("did not skip: $name")
done
skips=$(grep -cE '(Test|Suite) .* skipped' "$log" || true)
((skips == ${#expected_skips[@]})) || failures+=("$skips skipped; expected ${#expected_skips[@]}")

if ((${#failures[@]} > 0)); then
    printf '%s: %s\n' "$box" "${failures[@]}" >&2
    status=1
    exit 1
fi
echo "==> $box: ${#expected_passes[@]} passed, ${#expected_skips[@]} skipped (tmux $tmux_version, herdr stub $([[ "$herdr_stub" == 1 ]] && echo on || echo off))"
