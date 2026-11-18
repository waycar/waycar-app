#!/bin/bash
#
# Flake hunt (.github/workflows/flake-hunt.yml): the full app test lane and the
# WaycarSSH package E2E lane, each run several times on one hosted runner, to
# find timing-sensitive tests before they turn a main run red. Like
# scripts/run-ci-ios-tests.sh it builds once on a simulator of its own, boots it
# after the build and waits out its first-boot work. Then it runs CI's package
# lane FLAKE_HUNT_PACKAGE_PASSES times on that simulator, through
# run-ci-ios-tests.sh with that lane's settings, and the full lane
# FLAKE_HUNT_PASSES times with that lane's flags. FLAKE_HUNT_CPU_HOGS busy
# loops at normal priority stand in for the stalls of a loaded runner, which is
# when these races show.
#
# It reports and never fails: every outcome, a failed build included, lands in
# FLAKE_HUNT_OUT for scripts/ci/flake-hunt-report.py, every step runs under a
# deadline inside one budget that ends before the job's timeout, and the script
# exits 0, so a failing test never shows as a red check on main. It creates a
# simulator and leaves it to the hosted VM, which is discarded after the job,
# so it runs only in GitHub Actions, never on the shared Mac (see AGENTS.md,
# Simulators).

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
package_passes="${FLAKE_HUNT_PACKAGE_PASSES:-4}"
if [[ ! "$package_passes" =~ ^[0-9]$|^1[0-9]$ ]]; then
    echo "::warning::FLAKE_HUNT_PACKAGE_PASSES must be 0 to 19, got '$package_passes'; running 4"
    package_passes=4
fi
hogs="${FLAKE_HUNT_CPU_HOGS:-0}"
# Every step's deadline is capped by this budget, which ends inside the job's
# 150 minutes with room left to report and upload.
deadline=$((SECONDS + ${FLAKE_HUNT_BUDGET_SECONDS:-8100}))
derived="$repo_root/build/DerivedData"
hog_pids=()

mkdir -p "$out"
printf '%s\n' "${FLAKE_HUNT_LABEL:-hunt}" > "$out/label"
printf '%s\n' "$passes" > "$out/passes"
printf '%s\n' "$package_passes" > "$out/package-passes"

# shellcheck disable=SC2329 # run by the EXIT trap
stop_hogs() {
    if ((${#hog_pids[@]} > 0)); then
        kill "${hog_pids[@]}" 2>/dev/null
    fi
}
trap stop_hogs EXIT

# The smaller of a step's own cap and what is left of the budget.
within() {
    local left=$((deadline - SECONDS))
    if ((left < 1)); then
        left=1
    fi
    echo $(($1 < left ? $1 : left))
}

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

# Ends the hunt at a setup step that failed; the report names it.
stop_at() {
    printf '%s\n' "$1" > "$out/stopped"
    exit 0
}

# A fresh simulator, as CI's own Waycar CI is the first time.
run_step create "$(within 120)" \
    xcrun simctl create "Waycar Flake Hunt" \
    com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max || stop_at create
udid=$(tail -n 1 "$out/create.log")
if [[ ! "$udid" =~ ^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$ ]]; then
    stop_at create
fi
destination="platform=iOS Simulator,id=$udid"
echo "==> Simulator $udid; $passes passes, $hogs CPU hogs"

# The full lane runs as run-ci-ios-tests.sh runs it: under the merge gate with
# no fixture (the scheme forwards this variable), so the fixture-backed suites
# skip and none falls back on the runner's own sshd.
export WAYCAR_SSH_E2E_REQUIRED=0

# The committed project, as CI builds it (no xcodegen), before the boot: a
# first boot beside the build saturates this runner.
run_step build "$(within 2400)" \
    xcodebuild build-for-testing \
    -project Waycar.xcodeproj -scheme Waycar \
    -destination "$destination" -derivedDataPath "$derived" \
    -collect-test-diagnostics never || stop_at build

run_step boot "$(within 300)" xcrun simctl boot "$udid"
run_step bootstatus "$(within 900)" xcrun simctl bootstatus "$udid" -b || stop_at bootstatus
cores=$(sysctl -n hw.ncpu)
settle_deadline=$((SECONDS + $(within 1200)))
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

# CI's package lane, first: its passes are short (about 4 minutes, a fresh
# fixture and package build each time) and the full lane's skip these suites.
# Settings as in ci.yml's package job; the simulator is this one, already
# booted and settled. Each pass's failure diagnostics go beside its log.
for ((pass = 1; pass <= package_passes; pass += 1)); do
    if ((deadline - SECONDS < 600)); then
        echo "==> out of time: package passes $pass to $package_passes do not run"
        break
    fi
    run_step "package-pass-$pass" "$(within 1500)" \
        env WAYCAR_CI_LANE=package \
        WAYCAR_CI_MANDATORY=1 \
        WAYCAR_SSH_E2E_TIMEOUT_SCALE=4 \
        WAYCAR_CI_SIMULATOR_UDID="$udid" \
        RUNNER_TEMP="$out/package-pass-$pass" \
        scripts/run-ci-ios-tests.sh
done

# The harness lab is left out by name, as in the CI lane. The CI lane allows
# the full lane 900 s on this runner; a pass beside busy loops is slower.
for ((pass = 1; pass <= passes; pass += 1)); do
    if ((deadline - SECONDS < 600)); then
        echo "==> out of time: passes $pass to $passes do not run"
        break
    fi
    run_step "pass-$pass" "$(within 1800)" \
        python3 scripts/run-app-simulator-tests.py \
        -project Waycar.xcodeproj -scheme Waycar \
        -destination "$destination" \
        -derivedDataPath "$derived" \
        -disableAutomaticPackageResolution \
        -parallel-testing-enabled NO \
        -skip-testing:WaycarTests/HarnessLabE2ETests \
        test-without-building
done
exit 0
