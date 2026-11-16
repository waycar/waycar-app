#!/bin/bash
#
# Flake hunt (.github/workflows/flake-hunt.yml): the full app test lane, run
# several times on one hosted runner, to find timing-sensitive tests before
# they turn a main run red. Like scripts/run-ci-ios-tests.sh it builds once on
# a simulator of its own, boots it after the build and waits out its
# first-boot work, then it runs the full lane FLAKE_HUNT_PASSES times with
# that lane's flags. FLAKE_HUNT_CPU_HOGS busy loops at normal priority stand in
# for the stalls of a loaded runner, which is when these races show.
#
# It reports and never fails: every outcome, a failed build included, lands in
# FLAKE_HUNT_OUT for scripts/ci/flake-hunt-report.py, and the script exits 0,
# so a failing test never shows as a red check on main. It creates and deletes
# a simulator, so it runs only on a GitHub-hosted runner, never on the shared
# Mac (see AGENTS.md, Simulators).

set -uo pipefail

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
    echo "flake-hunt.sh creates its own simulator: it runs only in GitHub Actions" >&2
    exit 2
fi

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root" || exit 0

out="${FLAKE_HUNT_OUT:?FLAKE_HUNT_OUT names the folder for the logs}"
passes="${FLAKE_HUNT_PASSES:-4}"
if [[ ! "$passes" =~ ^[1-9]$|^1[0-9]$ ]]; then
    echo "::warning::FLAKE_HUNT_PASSES must be 1 to 19, got '$passes'; running 4"
    passes=4
fi
hogs="${FLAKE_HUNT_CPU_HOGS:-0}"
build_timeout_seconds=2400
settle_limit_seconds=1200
# The CI lane allows the full lane 900 s on this runner; a pass beside busy
# loops is slower.
pass_timeout_seconds=1800
# Inside the job's 150 minutes, with room left to report and upload.
deadline=$((SECONDS + ${FLAKE_HUNT_BUDGET_SECONDS:-8100}))
derived="$repo_root/build/DerivedData"
simulator_name="Waycar Flake Hunt"
udid=""
hog_pids=()

mkdir -p "$out"
printf '%s\n' "${FLAKE_HUNT_LABEL:-hunt}" > "$out/label"
printf '%s\n' "$passes" > "$out/passes"

# shellcheck disable=SC2329 # run by the EXIT trap
cleanup() {
    if ((${#hog_pids[@]} > 0)); then
        kill "${hog_pids[@]}" 2>/dev/null
    fi
    if [[ -n "$udid" ]]; then
        xcrun simctl shutdown "$udid" >/dev/null 2>&1
        xcrun simctl delete "$udid" >/dev/null 2>&1
    fi
}
trap cleanup EXIT

# One step under a deadline; its status goes beside its log.
run_step() {
    local name=$1
    local timeout_seconds=$2
    shift 2
    local status=0
    "$repo_root/scripts/run-with-timeout.py" \
        --timeout-seconds "$timeout_seconds" \
        --label "$name" \
        --diagnostics-dir "$out/diagnostics/$name" \
        -- "$@" > "$out/$name.log" 2>&1 || status=$?
    printf '%s\n' "$status" > "$out/$name.status"
    echo "==> $name: status $status after ${SECONDS}s"
    return "$status"
}

# A fresh simulator, as CI's own Waycar CI is the first time.
if ! udid=$(xcrun simctl create "$simulator_name" \
    com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max 2>"$out/build.log"); then
    udid=""
    printf '%s\n' 1 > "$out/build.status"
    echo "==> could not create the $simulator_name simulator"
    exit 0
fi
destination="platform=iOS Simulator,id=$udid"
echo "==> $simulator_name $udid; $passes passes, $hogs CPU hogs"

# The full lane runs as run-ci-ios-tests.sh runs it: under the merge gate with
# no fixture (the scheme forwards this variable), so the fixture-backed suites
# skip and none falls back on the runner's own sshd.
export WAYCAR_SSH_E2E_REQUIRED=0

# The committed project, as CI builds it (no xcodegen), before the boot: a
# first boot beside the build saturates this runner.
run_step build "$build_timeout_seconds" \
    xcodebuild build-for-testing \
    -project Waycar.xcodeproj -scheme Waycar \
    -destination "$destination" -derivedDataPath "$derived" \
    -collect-test-diagnostics never || exit 0

xcrun simctl boot "$udid" >/dev/null 2>&1
xcrun simctl bootstatus "$udid" -b > "$out/boot.log" 2>&1
cores=$(sysctl -n hw.ncpu)
settle_deadline=$((SECONDS + settle_limit_seconds))
while :; do
    load=$(sysctl -n vm.loadavg | awk '{ print $2 }')
    if awk -v load="$load" -v cores="$cores" 'BEGIN { exit !(load < 10 * cores) }' \
        || ((SECONDS >= settle_deadline)); then
        echo "==> First boot settled at 1-minute load $load on $cores cores"
        break
    fi
    sleep 15
done

for ((hog = 0; hog < hogs; hog += 1)); do
    /bin/sh -c 'while :; do :; done' &
    hog_pids+=($!)
done

# The harness lab is left out by name, as in the CI lane.
for ((pass = 1; pass <= passes; pass += 1)); do
    remaining=$((deadline - SECONDS))
    if ((remaining < 600)); then
        echo "==> out of time: passes $pass to $passes do not run"
        break
    fi
    run_step "pass-$pass" "$((remaining < pass_timeout_seconds ? remaining : pass_timeout_seconds))" \
        python3 scripts/run-app-simulator-tests.py \
        -project Waycar.xcodeproj -scheme Waycar \
        -destination "$destination" \
        -derivedDataPath "$derived" \
        -parallel-testing-enabled NO \
        -skip-testing:WaycarTests/HarnessLabE2ETests \
        test-without-building
done
exit 0
