#!/bin/bash
# Exercise the shipped recovery functions with fake CoreSimulator/xcodebuild
# boundaries, real device locks, and the real command watchdog.
# Use the gate's system Bash, including macOS Bash 3.2 empty-array behavior.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/waycar-simulator-recovery.XXXXXX")"
trap 'rm -rf "$work"' EXIT

for function in run_xcodebuild run_suite list_simulator_candidates recover_simulator_destination \
    claim_simulator claim_resource_lock release_resource_lock write_lock_owner \
    lock_is_stale acquire_claim_guard release_claim_guard \
    clear_simulator_environment push_simulator_environment; do
    body=$(awk -v fn="$function" '
        $0 == fn "() {" { inside = 1 }
        inside { print }
        inside && /^}$/ { exit }
    ' "$repo_root/scripts/run-ci-ios-tests.sh")
    [[ -n "$body" ]] || { echo "Missing shipped function: $function" >&2; exit 1; }
    eval "$body"
done

mkdir -p "$work/bin"
cat > "$work/bin/xcodebuild" <<'STUB'
#!/usr/bin/env bash
set -eu
count=$(cat "$CASE_DIR/calls" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$CASE_DIR/calls"
printf '%s\n' "$PWD $*" >> "$CASE_DIR/arguments"
# What the runner prepared, as the tests see it (the package lane has no runner).
[[ ! -d "$CASE_DIR/defaults" || -e "$CASE_DIR/defaults-during" ]] \
    || cp -R "$CASE_DIR/defaults" "$CASE_DIR/defaults-during"
case "$SCENARIO" in
    test-failure) echo 'Test failed'; exit 65 ;;
    other-70) echo 'Unrelated destination configuration error'; exit 70 ;;
    watchdog-status) exit 124 ;;
    # Wedged: deaf to the watchdog's SIGTERM and the runner's forwarded one.
    forwarded-signal)
        trap '' TERM
        while :; do /bin/sleep 0.2; done
        ;;
esac
if [[ "$count" == 1 || "$SCENARIO" == persistent ]]; then
    echo 'xcodebuild: error: Unable to find a device matching the provided destination specifier:' >&2
    exit 70
fi
echo 'Test run with 1 tests in 1 suite passed'
STUB

cat > "$work/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$CASE_DIR/simctl"
case "$*" in
    'simctl list devices available')
        [[ "$SCENARIO" != list-failure ]] || exit 1
        cat "$CASE_DIR/devices"
        ;;
    # The device boots for the first attempt (the app-lane runner boots it
    # too); after the loss it never comes back.
    'simctl bootstatus '*) [[ "$SCENARIO" != boot-failure || ! -e "$CASE_DIR/calls" ]] ;;
    # run-app-simulator-tests.py reads, writes and deletes the preferences it
    # prepares; the fake keeps them per device so restore can be checked.
    'simctl spawn '*' defaults '*)
        # On a loaded Mac a simctl call takes seconds. Once xcodebuild has
        # started, this restore takes 4.5 s: more than the 3 s a 5 s kill
        # grace left it after xcodebuild's 2 s.
        if [[ "$SCENARIO" == forwarded-signal && -e "$CASE_DIR/calls" ]]; then
            /bin/sleep 1.5
        fi
        exec python3 "$(dirname "$0")/fake-defaults.py" "$@"
        ;;
    *'launchctl setenv WAYCAR_SSH_E2E_REQUIRED '*) [[ "$SCENARIO" != env-failure ]] ;;
    *) exit 0 ;;
esac
STUB

# `simctl spawn <udid> defaults export|write|delete …` against one JSON file
# per device under $CASE_DIR/defaults, locked because the runner restores
# domains concurrently, and replaced whole, as cfprefsd does, so a call the
# watchdog kills never leaves half a file. Deleting a missing key fails, as on
# a simulator.
cat > "$work/bin/fake-defaults.py" <<'STUB'
import fcntl, json, os, plistlib, sys

_, _, udid, _, verb, domain, *rest = sys.argv[1:]
path = os.path.join(os.environ["CASE_DIR"], "defaults", f"{udid}.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(f"{path}.lock", "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        with open(path) as handle:
            store = json.load(handle)
    except FileNotFoundError:
        store = {}
    values = store.setdefault(domain, {})
    if verb == "export":
        sys.stdout.buffer.write(plistlib.dumps(values))
        sys.exit(0)
    if verb == "write":
        key, kind, raw = rest
        values[key] = raw == "true" if kind == "-bool" else int(raw)
    elif verb == "delete":
        if rest[0] not in values:
            sys.exit(1)
        del values[rest[0]]
    else:
        sys.exit(64)
    with open(f"{path}.new", "w") as handle:
        json.dump(store, handle, sort_keys=True)
    os.replace(f"{path}.new", path)
STUB
chmod +x "$work/bin/xcodebuild" "$work/bin/xcrun"
export PATH="$work/bin:$PATH"
export WAYCAR_TIMEOUT_DISABLE_SAMPLE=1
# The app runner scans crash reports; keep real ones out and skip the settle.
export WAYCAR_CRASH_REPORT_SETTLE_SECONDS=0
export WAYCAR_CRASH_REPORTS_DIR="$work/crash-reports"
mkdir -p "$WAYCAR_CRASH_REPORTS_DIR"
export ORIGINAL=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA
export REPLACEMENT=BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB
export OCCUPIED=CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC
export SEEDED_DEFAULTS='{"com.apple.Accessibility": {"AccessibilityEnabled": false}, "com.apple.keyboard.preferences": {"AutomaticMinimizationEnabled": true, "HardwareKeyboardLastSeen": true}}'

fail() { echo "FAIL $SCENARIO: $*" >&2; exit 1; }
# Avoid delays in the test; simulator recovery still runs the shipped loop.
sleep() { :; }
# The watchdog deadline of every run that is not meant to time out. CI runs
# this on a Mac shared with parallel test runs, at nice 15, where one attempt
# took over 10 s; only a hang should reach it.
never_seconds=300

# Whatever the run did, every device ends with the preferences it started
# with: the seeded one exactly, any other with none.
check_preferences_restored() {
    python3 - "$CASE_DIR/defaults" "$ORIGINAL" "$SEEDED_DEFAULTS" <<'PY' \
        || fail 'simulator preferences were not restored'
import json, os, sys
directory, original, seeded = sys.argv[1:]
for name in (name for name in os.listdir(directory) if name.endswith(".json")):
    with open(os.path.join(directory, name)) as handle:
        domains = {domain: values for domain, values in json.load(handle).items() if values}
    expected = json.loads(seeded) if name == f"{original}.json" else {}
    if domains != expected:
        sys.exit(f"{name}: {domains} != {expected}")
PY
}

run_case() (
    export SCENARIO=$1
    export CASE_DIR="$work/$SCENARIO"
    mkdir -p "$CASE_DIR/locks" "$CASE_DIR/fixture"
    # A nounset exit can run the trap before a command's redirects unwind.
    # Keep diagnostics off that command's capture file.
    exec 3>&2
    local case_completed=0
    local case_status=0
    trap 'case_status=$?; if [[ "$case_status" != 0 || "$case_completed" != 1 ]]; then
        echo "FAIL $SCENARIO: assertions did not complete (exit $case_status)" >&3
        cat "$CASE_DIR/output" >&3 2>/dev/null || true
        exit 1
    fi' EXIT
    # These variables are consumed by extracted functions, not by eval here.
    # shellcheck disable=SC2034
    {
        ci_lane=app
        source_packages_dir="$CASE_DIR/packages"
        fixture_dir="$CASE_DIR/fixture"
        diagnostic_root="$CASE_DIR/diagnostics"
        app_derived_data_path="$CASE_DIR/app"
        package_derived_data_path="$CASE_DIR/package"
        lock_root="$CASE_DIR/locks"
        lock_owner_token=ours
        lock_owner_start="$(ps -o lstart= -p "$$" | sed 's/^ *//; s/ *$//')"
        active_resource_lock=""
        active_claim_guard=""
        device_lock_dir=""
        requested_simulator_udid=""
        simulator_environment_variables=()
        ci_simulator_name='iPhone 17'
        xcodebuild_test_timeout_seconds=$never_seconds
        pinned_lane_logs=()
        simulator_boot_started=1
    }
    # WAYCAR_CI_BOOT_AFTER_BUILD: the build runs before the simulator boots.
    # shellcheck disable=SC2034
    [[ "$SCENARIO" != deferred-boot ]] || simulator_boot_started=0
    simulator_udid=$ORIGINAL
    simulator_destination="platform=iOS Simulator,id=$ORIGINAL"
    claim_simulator "$ORIGINAL"
    printf '    iPhone 17 (%s) (Shutdown)\n' "$ORIGINAL" > "$CASE_DIR/devices"
    case "$SCENARIO" in
        replacement | occupied | explicit-pin | package | suite)
            printf '    iPhone 17 (%s) (Shutdown)\n' "$REPLACEMENT" > "$CASE_DIR/devices"
            # A similarly named model is never an eligible replacement.
            printf '    iPhone 17 Pro (%s) (Shutdown)\n' "$OCCUPIED" >> "$CASE_DIR/devices"
            ;;
        no-devices) echo '== Devices ==' > "$CASE_DIR/devices" ;;
    esac
    if [[ "$SCENARIO" == occupied ]]; then
        mkdir "$lock_root/device-$OCCUPIED"
        write_lock_owner "$lock_root/device-$OCCUPIED"
        echo other > "$lock_root/device-$OCCUPIED/token"
        printf '    iPhone 17 (%s) (Shutdown)\n' "$OCCUPIED" >> "$CASE_DIR/devices"
    fi
    # shellcheck disable=SC2034
    [[ "$SCENARIO" != explicit-pin ]] || requested_simulator_udid=$ORIGINAL
    if [[ "$SCENARIO" == pinned-other-name ]]; then
        # shellcheck disable=SC2034
        requested_simulator_udid=$ORIGINAL
        printf '    iPad Pro 13-inch (M5) (%s) (Shutdown)\n' "$ORIGINAL" > "$CASE_DIR/devices"
    fi
    # shellcheck disable=SC2034
    [[ "$SCENARIO" != package ]] || ci_lane=package
    if [[ "$SCENARIO" == replacement || "$SCENARIO" == env-failure || "$SCENARIO" == package ]]; then
        export WAYCAR_SSH_E2E_REQUIRED=1 WAYCAR_SSH_E2E_HOST=127.0.0.1
        # Equivalent to a previously successful environment push. The failure
        # case fails only while reapplying it during destination recovery.
        # shellcheck disable=SC2034
        simulator_environment_variables=(WAYCAR_SSH_E2E_REQUIRED WAYCAR_SSH_E2E_HOST)
    fi
    # The device starts with a value the runner must write back (Accessibility
    # off), one it must delete again (ApplicationAccessibilityEnabled, absent)
    # and the hardware-keyboard state of a simulator Simulator.app has used.
    mkdir -p "$CASE_DIR/defaults"
    printf '%s' "$SEEDED_DEFAULTS" > "$CASE_DIR/defaults/$ORIGINAL.json"
    local timeout=$never_seconds
    # forwarded-signal times out a wedged xcodebuild, so the SIGTERM has to
    # land after the runner prepared the device and started it. A loaded Mac
    # can still be preparing when a short deadline passes: that run must
    # restore too, and the case runs again with twice the deadline.
    [[ "$SCENARIO" != forwarded-signal ]] || timeout=2
    local status=0
    if [[ "$SCENARIO" == deferred-boot ]]; then
        run_xcodebuild first "$timeout" "$CASE_DIR/lane.log" build-for-testing \
            -destination "$simulator_destination" > "$CASE_DIR/output" 2>&1 || status=$?
    elif [[ "$SCENARIO" == suite ]]; then
        run_suite first 1 1 0 ExampleSuite > "$CASE_DIR/output" 2>&1 || status=$?
        cp "$fixture_dir/first.log" "$CASE_DIR/lane.log"
        [[ "${#pinned_lane_logs[@]}" == 1 ]] || fail 'suite log was not registered'
    else
        while :; do
            run_xcodebuild first "$timeout" "$CASE_DIR/lane.log" test-without-building \
                -destination "$simulator_destination" > "$CASE_DIR/output" 2>&1 || status=$?
            [[ "$SCENARIO" == forwarded-signal && "$status" == 124 && ! -e "$CASE_DIR/calls" ]] || break
            check_preferences_restored
            ((timeout < 64)) || fail "xcodebuild did not start within ${timeout}s"
            timeout=$((timeout * 2))
            status=0
        done
    fi
    check_preferences_restored
    if [[ "$SCENARIO" == same || "$SCENARIO" == forwarded-signal ]]; then
        python3 - "$CASE_DIR/defaults-during/$ORIGINAL.json" <<'PY' \
            || fail 'xcodebuild ran without the prepared preferences'
import json, sys
with open(sys.argv[1]) as handle:
    store = json.load(handle)
assert store["com.apple.Accessibility"] == {"AccessibilityEnabled": True, "ApplicationAccessibilityEnabled": 1}, store
assert store["com.apple.keyboard.preferences"]["AutomaticMinimizationEnabled"] is False, store
PY
    fi
    case "$SCENARIO" in
        same | pinned-other-name | replacement | occupied | package | suite)
            [[ "$status" == 0 && "$(cat "$CASE_DIR/calls")" == 2 ]] || fail 'expected one retry and success'
            grep -qF 'Test run with 1 test' "$CASE_DIR/lane.log" || fail 'missing passing log'
            if grep -qF 'Unable to find' "$CASE_DIR/lane.log"; then fail 'failed attempt contaminated gate log'; fi
            [[ -s "$fixture_dir/first-attempt-1.log" ]] || fail 'first failure log lost'
            # The app runner turns off xcodebuild's post-failure `simctl
            # diagnose`, which can hang for 600 s while the run holds its simulator.
            if [[ "$SCENARIO" == same ]]; then
                grep -qF -- '-collect-test-diagnostics never' "$CASE_DIR/arguments" \
                    || fail 'the app runner left test diagnostics on'
            fi
            if [[ "$SCENARIO" != same && "$SCENARIO" != pinned-other-name ]]; then
                [[ "$simulator_udid" == "$REPLACEMENT" ]] || fail 'replacement did not reach calling shell'
                [[ "$device_lock_dir" == "$lock_root/device-$REPLACEMENT" ]] || fail 'cleanup lock is stale'
                [[ ! -d "$lock_root/device-$ORIGINAL" ]] || fail 'old lock leaked'
            fi
            # Subsequent actions must inherit the recovered destination.
            run_xcodebuild next "$never_seconds" "$CASE_DIR/next.log" test-without-building \
                -destination "$simulator_destination" >> "$CASE_DIR/output" 2>&1
            tail -n 1 "$CASE_DIR/arguments" | grep -qF "id=$simulator_udid" || fail 'next action used stale UDID'
            if [[ "$SCENARIO" == replacement || "$SCENARIO" == package ]]; then
                grep -qF "simctl spawn $REPLACEMENT launchctl setenv WAYCAR_SSH_E2E_REQUIRED 1" "$CASE_DIR/simctl" || fail 'fixture environment was not restored'
            fi
            if [[ "$SCENARIO" == occupied ]]; then
                [[ "$(cat "$lock_root/device-$OCCUPIED/token")" == other ]] || fail 'another owner was disturbed'
            fi
            if [[ "$SCENARIO" == package ]]; then
                grep -qF "$repo_root/Packages/WaycarSSH test-without-building" "$CASE_DIR/arguments" || fail 'wrong package working directory'
            fi
            ;;
        deferred-boot)
            [[ "$status" == 0 && "$(cat "$CASE_DIR/calls")" == 2 ]] || fail 'expected one retry and success'
            grep -qF 'Recovering simulator' "$CASE_DIR/output" || fail 'the destination was not recovered'
            ! grep -qE '^simctl (boot|bootstatus) ' "$CASE_DIR/simctl" \
                || fail 'recovery booted a simulator whose boot is deferred'
            ;;
        test-failure | other-70 | watchdog-status | forwarded-signal)
            local expected=65
            [[ "$SCENARIO" != other-70 ]] || expected=70
            [[ "$SCENARIO" != watchdog-status && "$SCENARIO" != forwarded-signal ]] || expected=124
            [[ "$status" == "$expected" && "$(cat "$CASE_DIR/calls")" == 1 ]] || fail 'non-destination failure retried or changed'
            # The app-lane runner's accessibility preparation is expected;
            # rediscovery is not.
            ! grep -qF 'simctl list devices available' "$CASE_DIR/simctl" 2>/dev/null \
                || fail 'non-destination failure rediscovered simulators'
            ;;
        *)
            [[ "$status" == 70 ]] || fail 'missing destination status lost'
            local expected_calls=1
            [[ "$SCENARIO" != persistent ]] || expected_calls=4
            [[ "$(cat "$CASE_DIR/calls")" == "$expected_calls" ]] || fail 'retry was not bounded'
            grep -qF "recovery exhausted for UDID $ORIGINAL" "$CASE_DIR/output" || fail 'missing UDID diagnostic'
            [[ "$(grep -cF 'simctl list devices available' "$CASE_DIR/simctl")" == 4 ]] || fail 'expected three rediscoveries and final live listing'
            if [[ "$SCENARIO" != list-failure ]]; then
                grep -qF 'Simulators visible while recovering' "$CASE_DIR/output" || fail 'rediscovery did not record the live listing'
            fi
            ;;
    esac
    release_resource_lock "$device_lock_dir" simulator
    printf 'PASS %s\n' "$SCENARIO"
    case_completed=1
)

for scenario in same pinned-other-name replacement occupied package suite no-devices persistent \
    test-failure other-70 watchdog-status forwarded-signal explicit-pin boot-failure env-failure \
    list-failure deferred-boot; do
    run_case "$scenario"
done
echo 'Passed 17 simulator recovery scenarios.'
