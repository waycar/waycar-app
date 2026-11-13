#!/bin/bash
#
# HarnessLabE2ETests (iOS Simulator) against the harness lab: the app's own
# Transports, launch builders and readers driving the real harnesses on the
# lab host, on both backends. See README.md, "The e2e suite".
#
#   scripts/harness-lab/run-e2e.sh [options]
#   make test-harness-lab [KINDS=claude,codex] [BACKENDS=herdr,tmux] [KEEP_SIM=1] [DRY_RUN=1]
#
# Options:
#   --kinds LIST       comma-separated kind ids (SupportedAgentKind raw values,
#                      e.g. claude,agy); default all 17 lab harnesses
#   --backends LIST    herdr, tmux or both (default herdr,tmux)
#   --dry-run          probe the lab and print the decoded configuration (seed
#                      redacted) and the commands a run would issue
#   --no-build         reuse the DerivedData test products as they are
#   --keep-simulator   leave the simulator leased afterwards
#
# Environment: SIM (iPhone 17 Pro Max), DERIVED (build/DerivedData),
# HARNESS_LAB_E2E_TIMEOUT_SECONDS (14400, the whole xcodebuild run).
#
# Brings the lab up (lab.sh up) when its SSH does not answer. Never clears the
# mock's shared request log. Every case resets the lab (e2e-reset.sh, copied
# to the host), which touches only harnesse2e-* tmux sessions and herdr
# workspaces; the run resets once more at the end.

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo_root=$(cd "$here/../.." && pwd)
cd "$repo_root"
export PYTHONDONTWRITEBYTECODE=1

usage() {
    sed -n '7,21p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

kinds=""
backends="herdr,tmux"
dry_run=0
build=1
keep_simulator=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --kinds) [[ $# -ge 2 ]] || usage; kinds=$2; shift ;;
        --backends) [[ $# -ge 2 ]] || usage; backends=$2; shift ;;
        --dry-run) dry_run=1 ;;
        --no-build) build=0 ;;
        --keep-simulator) keep_simulator=1 ;;
        -h | --help) usage ;;
        *) echo "unknown argument: $1" >&2; usage ;;
    esac
    shift
done

lab_host=127.0.0.1
lab_port=22300
lab_user=waycar
lab_key=$HOME/.ssh/waycar_harness_lab
simulator="${SIM:-iPhone 17 Pro Max}"
derived_data="${DERIVED:-build/DerivedData}"
test_timeout_seconds="${HARNESS_LAB_E2E_TIMEOUT_SECONDS:-14400}"
suite=HarnessLabE2ETests
config_variable=WAYCAR_HARNESS_LAB_CONFIG
remote_reset='$HOME/.cache/harness-lab/e2e-reset.sh'

# -F /dev/null: the developer's ssh_config must not decide what the lab sees.
# The lab's host key changes whenever the container is recreated.
lab_ssh() {
    ssh -F /dev/null -i "$lab_key" -o IdentitiesOnly=yes -o BatchMode=yes \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout=10 -p "$lab_port" "$lab_user@$lab_host" "$@"
}

if ! lab_ssh true 2>/dev/null; then
    [[ "$dry_run" == 0 ]] || { echo "the lab is down; a run would start it (lab.sh up)" >&2; exit 1; }
    echo "==> Starting the harness lab"
    "$here/lab.sh" up
fi

# Read-only. One key=value per line.
read -r -d '' remote_probe <<'EOF' || true
printf 'home=%s\n' "$HOME"
printf 'herdr=%s\n' "$(herdr --version 2>/dev/null)"
printf 'tmux=%s\n' "$(tmux -V 2>/dev/null)"
printf 'waycar=%s\n' "$(waycar version 2>/dev/null)"
if curl -fsS -o /dev/null http://mock:8080/_health 2>/dev/null; then printf 'mock=1\n'; fi
printf 'mock_health=%s\n' "$(curl -fsS http://mock:8080/_health 2>/dev/null)"
herdr integration status 2>/dev/null | sed -n 's/^\([a-z-]*\)\( (experimental)\)\{0,1\}: installed.*/integration=\1/p'
EOF

echo "==> Probing $lab_user@$lab_host:$lab_port"
probe=$(lab_ssh 'bash -lc "$(cat)"' <<< "$remote_probe")
home="" herdr_version="" tmux_version="" waycar_version="" mock="" mock_health=""
integrations=()
while IFS= read -r line; do
    value=${line#*=}
    case "${line%%=*}" in
        home) home=$value ;;
        herdr) herdr_version=$value ;;
        tmux) tmux_version=$value ;;
        waycar) waycar_version=$value ;;
        mock) mock=$value ;;
        mock_health) mock_health=$value ;;
        # herdr's integration target for agy is antigravity-cli.
        integration) integrations+=("$([[ "$value" == antigravity-cli ]] && echo agy || echo "$value")") ;;
    esac
done <<< "$probe"
echo "    home $home; $herdr_version; $tmux_version; waycar $waycar_version"
echo "    herdr integrations installed: ${integrations[*]:-none}"

problems=()
[[ -n "$home" ]] || problems+=("the lab session reports no HOME")
[[ -n "$herdr_version" ]] || problems+=("no herdr on the lab host")
[[ -n "$tmux_version" ]] || problems+=("no tmux on the lab host")
[[ -n "$waycar_version" ]] || problems+=("Waycar Host Tools are not installed (make harness-lab-reinstall-plugin)")
[[ "$mock" == 1 ]] || problems+=("the host cannot reach the mock at http://mock:8080")
# The suite reads the log by `?since=` and each record's `ts`, a launch's
# first turn needs the opening delay, and grok's tool-carrying title request
# must read as bookkeeping; an older image lacks them, and the suite would
# then see no requests or the wrong one. Rebuild: lab.sh up (or compose build mock).
for feature in log-since log-ts opening-delay title-tool system-notice; do
    [[ "$mock" != 1 || "$mock_health" == *"\"$feature\""* ]] \
        || problems+=("the mock image is stale (its /_health lacks \"$feature\"): rebuild it, docker compose build mock")
done
if ((${#problems[@]} > 0)); then
    printf 'lab not usable: %s\n' "${problems[@]}" >&2
    exit 1
fi

read -r -d '' config_program <<'EOF' || true
import base64
import json
import sys

host, port, user, seed, home, kinds, backends, integrations = sys.argv[1:]
split = lambda text: [item for item in text.split(",") if item]
config = {
    "host": host,
    "port": int(port),
    "username": user,
    "deviceKeySeed": seed,
    "homePath": home,
    "workDirectory": f"{home}/work/demo",
    "mockURL": "http://mock:8080",
    "resetScript": f"{home}/.cache/harness-lab/e2e-reset.sh",
    "backends": split(backends),
    "herdrIntegrations": split(integrations),
}
if kinds:
    config["kinds"] = split(kinds)
print(base64.b64encode(json.dumps(config, separators=(",", ":")).encode()).decode())
EOF

seed=$(python3 scripts/fixtures/openssh-ed25519-seed.py "$lab_key")
integration_list=$(IFS=,; echo "${integrations[*]:-}")
config_base64=$(python3 -c "$config_program" "$lab_host" "$lab_port" "$lab_user" "$seed" \
    "$home" "$kinds" "$backends" "$integration_list")

echo "==> $config_variable (decoded, seed redacted)"
python3 -c '
import base64, json, sys
config = json.loads(base64.b64decode(sys.argv[1]))
config["deviceKeySeed"] = "<redacted>"
print(json.dumps(config, indent=2))
' "$config_base64"

build_command=(xcodebuild build-for-testing -project Waycar.xcodeproj -scheme Waycar
    -destination "platform=iOS Simulator,name=$simulator" -derivedDataPath "$derived_data")
test_arguments=(test-without-building -disableAutomaticPackageResolution
    -project Waycar.xcodeproj -scheme Waycar -derivedDataPath "$derived_data"
    -collect-test-diagnostics never -parallel-testing-enabled NO
    "-only-testing:WaycarTests/$suite")

if [[ "$dry_run" == 1 ]]; then
    echo "==> Dry run; a run would:"
    [[ "$build" == 1 ]] && echo "    ${build_command[*]}"
    echo "    copy e2e-reset.sh to $remote_reset and run it"
    echo "    scripts/sim-slot.py acquire '$simulator'"
    echo "    xcrun simctl spawn <UDID> launchctl setenv $config_variable <${#config_base64} base64 chars>"
    echo "    python3 scripts/run-app-simulator-tests.py ${test_arguments[*]} -destination platform=iOS Simulator,id=<UDID>"
    echo "    reset the lab, unset the Simulator environment$([[ "$keep_simulator" == 0 ]] && echo ", scripts/sim-slot.py release <UDID>")"
    exit 0
fi

work_dir=$(mktemp -d /tmp/waycar-harness-lab-e2e.XXXXXX)
log="$work_dir/$suite.log"
simulator_udid=""
environment_pushed=0
status=0
lab_locked=0
# One harness at a time on the lab (its VM is small): every lab user takes
# this lock on the host first (README.md, "One harness at a time").
lab_lock=/tmp/harness-lab.lock
lab_lock_wait_seconds="${HARNESS_LAB_LOCK_WAIT_SECONDS:-3600}"

cleanup() {
    local exit_status=$?
    trap - EXIT INT TERM
    ((status != 0)) || status=$exit_status
    if [[ "$lab_locked" == 1 ]]; then
        lab_ssh "sh $remote_reset" || echo "lab reset failed; rerun: scripts/harness-lab/lab.sh e2e-reset" >&2
        lab_ssh "rm -rf $lab_lock" || echo "could not release $lab_lock on the lab host" >&2
    fi
    if [[ "$environment_pushed" == 1 ]]; then
        xcrun simctl spawn "$simulator_udid" launchctl unsetenv "$config_variable" || true
    fi
    if [[ -n "$simulator_udid" && "$keep_simulator" == 0 ]]; then
        scripts/sim-slot.py release "$simulator_udid" || true
    fi
    if [[ "$status" == 0 ]]; then
        rm -rf -- "$work_dir"
    else
        echo "==> harness lab e2e: FAILED (status $status); logs kept in $work_dir" >&2
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'status=130; exit 130' INT
trap 'status=143; exit 143' TERM

# Compile before taking the lab or a simulator slot, as `make test-app` does.
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
fi

echo "==> Taking the lab lock ($lab_lock)"
lock_deadline=$((SECONDS + lab_lock_wait_seconds))
until lab_ssh "mkdir $lab_lock 2>/dev/null && echo 'run-e2e $repo_root pid $$' > $lab_lock/owner"; do
    if ((SECONDS >= lock_deadline)); then
        echo "the lab lock is still held: $(lab_ssh "cat $lab_lock/owner" 2>/dev/null)" >&2
        exit 1
    fi
    echo "    held by $(lab_ssh "cat $lab_lock/owner" 2>/dev/null); waiting"
    sleep 30
done
lab_locked=1

# shellcheck disable=SC2016 # expands on the host
lab_ssh 'mkdir -p "$HOME/.cache/harness-lab" && cat > "$HOME/.cache/harness-lab/e2e-reset.sh"' \
    < "$here/e2e-reset.sh"
lab_ssh "sh $remote_reset"

echo "==> Acquiring $simulator"
simulator_udid=$(scripts/sim-slot.py acquire "$simulator" | tail -n 1)
[[ "$simulator_udid" =~ ^[0-9A-F-]{36}$ ]] || {
    echo "sim-slot granted no UDID ($simulator_udid)" >&2
    simulator_udid=""
    exit 1
}
xcrun simctl spawn "$simulator_udid" launchctl setenv "$config_variable" "$config_base64"
environment_pushed=1

echo "==> $suite on $simulator_udid; log: $log"
set +e
python3 scripts/run-with-timeout.py \
    --timeout-seconds "$test_timeout_seconds" \
    --label "$suite" \
    --diagnostics-dir "$work_dir/diagnostics" \
    -- python3 scripts/run-app-simulator-tests.py "${test_arguments[@]}" \
    -destination "platform=iOS Simulator,id=$simulator_udid" 2>&1 | tee "$log" \
    | grep -E '(Test|Suite) .* (passed|failed|skipped)|recorded an issue|error:|\*\* TEST|^\[[0-9]+\] |^    (frame|test|reports): |^harness lab case |^[a-z]+ on (herdr|tmux): |^↳ [a-z]+ on (herdr|tmux): '
test_status=${PIPESTATUS[0]}
set -e

if grep -qE 'Suite "Harness lab e2e" skipped' "$log"; then
    echo "the suite skipped: $config_variable did not reach the test process" >&2
    status=1
    exit 1
fi
if ((test_status != 0)); then
    status=$test_status
    exit "$test_status"
fi
# The suite fails an unknown KINDS or BACKENDS entry itself; this catches a
# run that still executed no case at all.
if ! grep -qE '^harness lab case .*: finished in ' "$log"; then
    echo "the suite ran no lab case" >&2
    status=1
    exit 1
fi
echo "==> harness lab e2e passed"
