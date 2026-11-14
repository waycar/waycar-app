#!/usr/bin/env bash
# Exercise the merge gate's own assertions without running the merge gate.
#
# A developer tool, run by hand. It is deliberately not wired into CI or into
# run-ci-ios-tests.sh: it proves the gate's guards can fail, which is a claim
# about the gate rather than about the app.
#
# The guards it exercises are the ones the full lane gained under #135. Those
# guards exist because a gate run reported `864 tests in 92 suites passed` while
# 95 of those tests executed nothing, so the standard they are held to here is
# that each one has been *seen* to go red for its own stated reason. A guard
# that has only ever been seen green is not known to work.
#
# Four properties of this script matter as much as the cases:
#
#   * It does not copy the guards. It extracts their function text verbatim out
#     of scripts/run-ci-ios-tests.sh and evals it, so what runs here is the code
#     that ships. A transcription would drift silently and this file would keep
#     reporting green about a function nobody runs.
#   * It does not restate the gate's numbers either. The executed floor is read
#     back out of the gate's own call site, because a second copy of it here
#     drifted silently and left the gate loosenable with every case still green.
#   * A red case must print the words of the guard it is named after, not merely
#     exit non-zero. One case here used to go red through a different guard than
#     its name claimed, which reads as coverage while being none.
#   * It refuses to report success having run nothing. A missing function, a
#     missing call site, a swapped capture and a miscounted case list are all
#     fatal. Passing zero cases while printing a summary is precisely the
#     failure #135 exists to oppose, and it would be an unusually poor thing to
#     ship inside the fix for it.
#
# Fixtures are derived from one committed capture of a real passing gate run,
# scripts/testdata/gate-2f50170.log, whose only edit is that the developer home
# path it was recorded under is rewritten to /Users/ci. That substitution is
# mechanical and total, and provably touches no line any guard or the lane
# splitter reads. Everything else -- the per-lane logs the gate writes, and
# every degraded variant -- is generated from it here, so a fresh clone
# reproduces the whole set with no manual reconstruction.

set -uo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
gate_script="$repo_root/scripts/run-ci-ios-tests.sh"
green_log="$repo_root/scripts/testdata/gate-2f50170.log"
work="$(mktemp -d "${TMPDIR:-/tmp}/waycar-gate-guards.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Facts about the committed capture, asserted rather than assumed: if the
# fixture is ever replaced, these say which number moved.
expected_full_lane_total=864
expected_full_lane_skips=95
expected_capture_executed=769
expected_cases=64

# The lanes run-ci-ios-tests.sh writes, in the order it writes them. The capture
# is the concatenation of exactly these, so splitting it on the xcodebuild
# invocation banners reproduces the files the gate's own assertions read.
lane_names=(
    WaycarSSHSessionE2ETests
    WaycarSSHPTYE2ETests
    WaycarSSHDirectStreamLocalE2ETests
    WaycarSSHJumpHostGateE2ETests
    WaycarSSHTransportBehaviorE2ETests
    ImageStagingE2ETests
    WeakNetworkE2ETests
    PairingCeremonyE2ETests
    package-e2e
    full-lane
)

die() {
    printf 'FATAL: %s\n' "$1" >&2
    exit 2
}

[[ -r "$gate_script" ]] || die "cannot read $gate_script"
[[ -r "$green_log" ]] || die "cannot read $green_log"

# Lift a function out of the shipped gate script by name. Renaming a guard over
# there must break this loudly rather than quietly leave it untested, so an
# empty extraction is fatal and so is a body that does not define the function.
extract_shipped_function() {
    local name=$1 body
    body=$(awk -v fn="$name" \
        '$0 ~ "^" fn "\\(\\) \\{$" { inside = 1 }
         inside { print }
         inside && /^\}$/ { exit }' "$gate_script")
    [[ -n "$body" ]] || die "no function '$name' in $gate_script (renamed?)"
    eval "$body" || die "could not eval '$name' from $gate_script"
    [[ "$(type -t "$name")" == function ]] || die "'$name' did not define a function"
}

extract_shipped_function assert_full_lane_coverage
extract_shipped_function log_proves_test_passed
extract_shipped_function assert_behavior
extract_shipped_function run_suite
extract_shipped_function dump_fixture_logs
extract_shipped_function preserve_failure_diagnostics
extract_shipped_function cleanup
extract_shipped_function stop_host_load_sampler
extract_shipped_function summarize_host_load
extract_shipped_function delete_password_user
extract_shipped_function pick_password_username
extract_shipped_function clear_simulator_environment
extract_shipped_function stop_privileged_sshd
extract_shipped_function release_resource_lock
extract_shipped_function kill_descendants
extract_shipped_function start_orphan_watchdog
extract_shipped_function stop_orphan_watchdog
extract_shipped_function claim_resource_lock
extract_shipped_function acquire_claim_guard
extract_shipped_function release_claim_guard
extract_shipped_function write_lock_owner
extract_shipped_function lock_is_stale
extract_shipped_function provisioning_step
extract_shipped_function redact_secret_in_file
extract_shipped_function stop_core_fixture
extract_shipped_function stop_codex_fixture
extract_shipped_function stop_opencode_fixture
extract_shipped_function stop_zellij_fixture

# The optimized gate has exactly seven unconditional app fixture invocations:
# Session, DirectStreamLocal, the shared, herdr-core, Codex, OpenCode and Zellij lanes (the
# tmux lanes are indented under their own conditions and are not counted). The package
# suite runs in its own workflow job, so putting it back into the app lane or
# silently expanding the fixture invocations must make this harness fail.
app_fixture_lane_count=$(grep -c '^run_suite ' "$gate_script")
[[ "$app_fixture_lane_count" == 7 ]] \
    || die "gate has $app_fixture_lane_count app fixture lanes, expected 7"
# These are source-code literals. The variable-looking text must not expand.
# shellcheck disable=SC2016
grep -qF 'if [[ "$ci_lane" == "package" ]]; then' "$gate_script" \
    || die "gate has no isolated package lane"
grep -qF 'WAYCAR_CI_LANE: package' "$repo_root/.github/workflows/ci.yml" \
    || die "workflow has no package-only job"
grep -qF 'WAYCAR_CI_LANE: app' "$repo_root/.github/workflows/ci.yml" \
    || die "workflow does not pin the app-only job"
# shellcheck disable=SC2016
grep -qF '"KexAlgorithms curve25519-sha256" >> "$modern_config"' "$gate_script" \
    || die "shared modern fixture does not pin the Curve25519 baseline"
# shellcheck disable=SC2016
grep -qF '"KexAlgorithms mlkem768x25519-sha256" >> "$post_quantum_config"' \
    "$gate_script" \
    || die "post-quantum coverage does not use a dedicated fixture"
# The password fixture block used to fail under set -e with nothing printed
# (#348). Each of its silent steps must stay routed through provisioning_step,
# and the sysadminctl transcript must be a fixture_dir .log so that
# preserve_failure_diagnostics copies it with the sshd logs.
# shellcheck disable=SC2016
grep -qF 'provisioning_step create_password_user create_password_user || exit 1' \
    "$gate_script" \
    || die "create_password_user is not routed through provisioning_step"
provisioning_step_calls=$(grep -cE '^[[:space:]]*provisioning_step ' "$gate_script")
[[ "$provisioning_step_calls" == 4 ]] \
    || die "gate routes $provisioning_step_calls password fixture steps through provisioning_step, expected 4"
# shellcheck disable=SC2016
grep -qF 'sysadminctl_log="$fixture_dir/sysadminctl.log"' "$gate_script" \
    || die "sysadminctl transcript is not a fixture_dir .log that preserve_failure_diagnostics copies"
awk '
    /if \[\[ "\$ci_lane" == "app" \]\]; then/ { in_app_lane = 1; next }
    in_app_lane && /clear_simulator_environment/ { cleared = 1 }
    in_app_lane && /^fi$/ { in_app_lane = 0 }
    END { exit cleared ? 0 : 1 }
' "$gate_script" \
    || die "app lane does not clear fixture environment before the full test lane"
awk '
    /if \[\[ "\$ci_lane" == "package" \]\]; then/ { in_pkg = 1 }
    in_pkg && /WaycarSSH package build/ { saw_build_label = 1 }
    in_pkg && /build-for-testing/ { build = NR }
    in_pkg && /^wait_for_simulator_boot$/ { boot = NR }
    in_pkg && /test-without-building/ { test_action = NR }
    in_pkg && /^exit 0$/ {
        ok = (saw_build_label && build && boot && test_action \
            && build < boot && boot < test_action)
        exit
    }
    END { exit ok ? 0 : 1 }
' "$gate_script" \
    || die "package lane does not overlap simulator boot with build-for-testing"
# Simulator claim/boot must precede fixture keygen so boot overlaps setup, not
# only build-for-testing. A late claim puts CoreSimulator wake back on the
# critical path in front of compilation.
awk '
    /^claim_port_block$/ { claimed_ports = NR }
    /xcrun simctl boot "/ { boot = NR }
    /host_ed25519"/ && /ssh-keygen/ { keygen = NR }
    END { exit (claimed_ports && boot && keygen \
        && claimed_ports < boot && boot < keygen) ? 0 : 1 }
' "$gate_script" \
    || die "simulator boot must start before fixture keygen"
# shellcheck disable=SC2016
grep -qF 'clonedSourcePackagesDirPath "$source_packages_dir"' "$gate_script" \
    || die "app lane must pin a stable clonedSourcePackagesDirPath"
# shellcheck disable=SC2016
grep -qF 'if [[ "$ci_lane" == "app" ]]; then' "$gate_script" \
    || die "clonedSourcePackagesDirPath must stay app-lane only"
awk '
    /^run_xcodebuild\(\) \{/ { inside = 1 }
    inside && /ci_lane" == "app"/ { app_gate = 1 }
    inside && /clonedSourcePackagesDirPath/ { flag = 1 }
    inside && /^}$/ { exit (app_gate && flag) ? 0 : 1 }
    END { exit (app_gate && flag) ? 0 : 1 }
' "$gate_script" \
    || die "clonedSourcePackagesDirPath must be gated inside run_xcodebuild"
grep -qF 'Cache SwiftPM checkouts' "$repo_root/.github/workflows/ci.yml" \
    || die "workflow must cache SwiftPM checkouts for the app job"
grep -qF '.ci/source-packages' "$repo_root/.github/workflows/ci.yml" \
    || die "workflow cache must include .ci/source-packages"
if grep -qE '^[[:space:]]+xcrun simctl list runtimes' "$repo_root/.github/workflows/ci.yml"; then
    die "workflow must not cold-start CoreSimulator via simctl list runtimes"
fi
grep -qF 'Show Xcode version' "$repo_root/.github/workflows/ci.yml" \
    || die "workflow must keep a lightweight Xcode version step"

# cleanup reads these ownership slots even when a case never claimed a
# resource. The real gate initializes them before installing its trap; the
# extracted function needs the same empty starting state. Only the extracted
# functions read them, which static analysis cannot follow.
# shellcheck disable=SC2034
{
    active_claim_guard=""
    active_resource_lock=""
    account_lock_dir=""
    run_lock_dir=""
    device_lock_dir=""
    diagnostic_root=""
    app_derived_data_path=""
    package_derived_data_path=""
    password_home=""
    core_home=""
    core_binary=""
    core_path=/usr/bin
    codex_home=""
    codex_binary=""
    codex_path=/usr/bin
    codex_physical_socket=""
    opencode_home=""
    opencode_binary=""
    opencode_path=/usr/bin
    zellij_home=""
    zellij_binary=""
    zellij_socket_dir=""
    zellij_path=/usr/bin
    tmux_binary=""
    tmux_tmpdir=""
    host_load_pid=""
    orphan_watchdog_pid=""
    fixture_log_tail_lines=80
}

# The floor is read out of the gate's own call site rather than restated here.
# Restating it made the two literals drift silently, and the drift that matters
# is someone loosening the gate: with the floor duplicated, lowering the gate's
# call site to 1 left every case green, so the harness could not see the one
# regression it most needs to. Reading it means lowering the gate makes the
# coverage-loss cases stop failing, and raising it makes the control case stop
# passing -- drift in either direction lands on a case rather than nowhere.
# The literal `$full_lane_log` is the gate's text, not an expansion here.
# shellcheck disable=SC2016
gate_executed_floor=$(sed -n \
    's/^assert_full_lane_coverage "\$full_lane_log" \([0-9][0-9]*\)$/\1/p' \
    "$gate_script")
[[ -n "$gate_executed_floor" ]] \
    || die "no assert_full_lane_coverage call site with a floor in $gate_script"
[[ "$(printf '%s\n' "$gate_executed_floor" | wc -l | tr -d ' ')" == 1 ]] \
    || die "more than one assert_full_lane_coverage call site in $gate_script"

# The gate's named full-lane assertions. Counted so that adding one over there
# without adding a case here is fatal: the case total below checks how many
# cases ran, not which, so a tenth gate assertion would otherwise go untested.
gate_full_lane_assertions=$(awk '
    { line = cont ? line " " $0 : $0 }
    line ~ /\\$/ { sub(/[ \t]*\\$/, "", line); cont = 1; next }
    { cont = 0; if (line ~ /^assert_behavior .* full-lane /) count += 1 }
    END { print count + 0 }' "$gate_script")

# Split the capture into the per-lane logs. Each chunk carries its own
# `Command line invocation:` banner, so the split is checked against the
# -only-testing identifier in the banner rather than trusted to line arithmetic.
split_capture() {
    mkdir -p "$work/lanes"
    LANES="${lane_names[*]}" /usr/bin/python3 - "$green_log" "$work/lanes" <<'PY'
import os, re, sys

source, out_dir = sys.argv[1], sys.argv[2]
names = os.environ["LANES"].split()
lines = open(source, encoding="utf-8").read().splitlines(keepends=True)
starts = [i for i, l in enumerate(lines) if l.startswith("Command line invocation:")]
if len(starts) != len(names):
    sys.exit(f"capture has {len(starts)} lanes, expected {len(names)}")

bounds = starts + [len(lines)]
for index, name in enumerate(names):
    chunk = lines[bounds[index]:bounds[index + 1]]
    banner = chunk[1] if len(chunk) > 1 else ""
    found = re.search(r"only-testing:WaycarTests/(\w+)", banner)
    if name == "package-e2e":
        expected_ok = "-scheme WaycarSSH" in banner
    elif name == "full-lane":
        expected_ok = found is None and "-scheme Waycar" in banner
    else:
        expected_ok = found is not None and found.group(1) == name
    if not expected_ok:
        sys.exit(f"lane {index} is not {name}: {banner.strip()[:120]}")
    with open(os.path.join(out_dir, name + ".log"), "w", encoding="utf-8") as handle:
        handle.writelines(chunk)
PY
}

split_capture || die "could not split $green_log into lanes"

# Confirm the capture still says what the cases below are calibrated against,
# so replacing it surfaces as a named mismatch instead of as odd case results.
actual_total=$(sed -n \
    's/^.*Test run with \([0-9][0-9]*\) tests in .* passed after .*$/\1/p' \
    "$work/lanes/full-lane.log" | tail -n 1)
actual_skips=$(grep -c 'Test .* skipped:' "$work/lanes/full-lane.log")
[[ -n "$actual_total" ]] \
    || die "capture's full lane states no passing run summary (truncated?)"
[[ "$actual_total" == "$expected_full_lane_total" ]] \
    || die "capture full lane totals $actual_total, expected $expected_full_lane_total"
[[ "$actual_skips" == "$expected_full_lane_skips" ]] \
    || die "capture full lane skips $actual_skips, expected $expected_full_lane_skips"
(( actual_total - actual_skips == expected_capture_executed )) \
    || die "capture executes $((actual_total - actual_skips)), expected $expected_capture_executed"

passed=0
failed=0
ran=0
case_labels=()

new_case() {
    local dir="$work/cases/$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$work/lanes/"*.log "$dir/"
    cat \
        "$dir/WaycarSSHPTYE2ETests.log" \
        "$dir/WaycarSSHJumpHostGateE2ETests.log" \
        "$dir/WaycarSSHTransportBehaviorE2ETests.log" \
        "$dir/ImageStagingE2ETests.log" \
        "$dir/WeakNetworkE2ETests.log" \
        "$dir/PairingCeremonyE2ETests.log" \
        > "$dir/SharedFixtureE2ETests.log"
    printf '%s' "$dir"
}

# Run one assertion against one case directory and compare its verdict to the
# expected one. $1 pass|fail, $2 the text a red case must print (empty for a
# green one), $3 label, $4 case directory, rest the invocation.
#
# The expected text is not decoration. A red case proves nothing unless it went
# red for the reason its label claims, and this harness already shipped one that
# did not: "a missing run summary is caught" went red through the *floor*
# (total="" reads as 0, and 0 - 95 is below any floor) rather than through the
# guard it was named after, so deleting that guard entirely left the case green.
# Matching the message is what makes each case discriminate between the guards.
#
# fixture_dir is set to the case directory because that is where the gate's
# assertions look: assert_behavior derives its log path as
# "$fixture_dir/$log_name.log" rather than taking a path. Pointing fixture_dir
# somewhere else makes every assert_behavior case go red on a missing file while
# claiming it went red because the behaviour was neutered -- an expected-fail
# case that passes for the wrong reason, which this harness produced once before
# the derivation was noticed. Any change here should be re-checked against the
# control block, which is the only part that would notice.
run_case() {
    local expect=$1 expect_text=$2 label=$3 case_dir=$4
    shift 4
    local output status verdict lane reason
    output=$(
        set +e
        # Read by the extracted functions, which shellcheck cannot see into.
        # shellcheck disable=SC2034
        fixture_dir="$case_dir"
        # shellcheck disable=SC2034
        password_fixture_available="$case_password_fixture"
        # The capture predates the tmux backend (ADR 0026): no lane in it has a
        # tmux test, so the gate's no-tmux exemption has nothing to cover.
        # shellcheck disable=SC2034
        tmux_fixture_available=1
        pinned_lane_logs=(
            "$case_dir/WaycarSSHSessionE2ETests.log"
            "$case_dir/WaycarSSHDirectStreamLocalE2ETests.log"
            "$case_dir/SharedFixtureE2ETests.log"
        )
        # The guards signal failure with `exit`, which would take this capture
        # subshell down with them and leave no status to read. Nesting one more
        # subshell keeps the status observable, so a red case is recorded as the
        # code the gate would really exit with rather than as an absence.
        ( "$@" ) 2>&1
        printf 'HARNESS_STATUS=%s\n' "$?"
    )
    status=$(printf '%s' "$output" | sed -n 's/^HARNESS_STATUS=//p' | tail -n 1)
    [[ -n "$status" ]] || die "case '$label' produced no status"
    verdict=pass
    [[ "$status" != 0 ]] && verdict=fail

    reason=""
    if [[ "$verdict" != "$expect" ]]; then
        reason="expected $expect, got $verdict"
    elif [[ "$expect" == fail ]]; then
        # A red case must carry the guard's own words, not merely a non-zero
        # status that some other guard in the same function could have produced.
        # Every line of expect_text must appear, so a case can demand both the
        # guard that spoke and the specific test it named.
        local fragment
        while IFS= read -r fragment; do
            [[ -n "$fragment" ]] || continue
            printf '%s\n' "$output" | grep -qF "$fragment" && continue
            reason="went red without saying: $fragment"
            break
        done <<< "$expect_text"
    elif [[ -n "$expect_text" ]]; then
        die "green case '$label' declares an expected failure message"
    fi

    case_labels+=("$label")
    ran=$((ran + 1))
    if [[ -z "$reason" ]]; then
        printf 'ok    expected-%-4s  exit=%-3s  %s\n' "$expect" "$status" "$label"
        passed=$((passed + 1))
    else
        printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$status" "$label" "$reason"
        failed=$((failed + 1))
    fi
    if [[ "$verdict" == fail ]]; then
        printf '%s\n' "$output" | grep -v '^HARNESS_STATUS=' | sed 's/^/        | /'
    fi
}

# The capture is a laptop run: no passwordless sudo, so the privileged
# password fixture was absent. Cases that need the other setting say so.
case_password_fixture=0

# Each entry is `assert_behavior label|test name`, for the behaviours that
# appear only in the full lane and so had no assertion of any kind before #135.
full_lane_behaviors=(
    "admission reserves the production slots|productionLimitsReserveEventsAndAttachWithinTheConnectionCeiling()"
    "admission stays non-blocking|sessionSaturationDoesNotBlockForwardingAdmission()"
    "admission respects the connection ceiling|connectionCeilingBoundsForwardingAndSessionTogether()"
    "a cancelled waiter frees its capacity|cancelledWaiterDoesNotLeakConnectionCapacity()"
    "TOFU migrates a legacy record|matchingLegacyRecordMigratesAlgorithmMetadata()"
    "TOFU refuses a changed key|changedKeyFailsWithoutConfirmationOrOverwrite()"
    "no obsolete algorithm is negotiable|\"the session driver negotiates no obsolete algorithm\""
    "no private key entry point exists|\"the SSH package has no private key entry point\""
    "signing never exports a key|\"the transport signs through CryptoKit rather than exporting a key\""
)

jump_host_product_path='"protocol 17 ping traverses independent SSH hops"'

# The provenance guard's own opening words. Naming it once keeps the cases below
# demanding that guard specifically rather than any non-zero exit.
unproven_says="no pinned lane proved:"

echo "== control: the unmodified capture of a passing gate run =="
case_dir=$(new_case green)
run_case pass '' "full-lane coverage holds" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"
for entry in "${full_lane_behaviors[@]}"; do
    run_case pass '' "full lane proves: ${entry%%|*}" "$case_dir" \
        assert_behavior "${entry%%|*}" full-lane "${entry#*|}"
done
run_case pass '' "Jump Host product path is proven" "$case_dir" \
    assert_behavior "Jump Host product path" WaycarSSHJumpHostGateE2ETests \
    "$jump_host_product_path"

echo
echo "== a ninth suite silently joins the full-lane skip list =="
# The headline case. `SSH channel admission` runs only in the full lane, so
# nothing else in the gate would notice it stopping.
case_dir=$(new_case ninth-suite)
/usr/bin/python3 - "$case_dir/full-lane.log" <<'PY'
import re, sys

path = sys.argv[1]
out = []
for line in open(path, encoding="utf-8").read().splitlines(keepends=True):
    admission = 'Suite "SSH channel admission"' in line or re.search(
        r"Test (productionLimits|sessionSaturation|connectionCeiling|cancelledWaiter)\w*\(\)",
        line)
    if admission and " passed after" in line:
        out.append(re.sub(r" passed after .*$",
                          ' skipped: "requires the disposable unprivileged sshd fixture"\n',
                          line))
    elif admission and " started." in line:
        continue
    else:
        out.append(line)
open(path, "w", encoding="utf-8").writelines(out)
PY
run_case fail \
    "$unproven_says
sessionSaturationDoesNotBlockForwardingAdmission()" \
    "a ninth skipping suite is caught by name" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

echo
echo "== coverage removed outright, with nothing skipped to show for it =="
retotal() {
    TOTAL="$1" SUITES="$2" /usr/bin/python3 - "$3" <<'PY'
import os, sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = "Test run with 864 tests in 92 suites passed"
assert old in text, "capture no longer states 864 in 92"
new = f"Test run with {os.environ['TOTAL']} tests in {os.environ['SUITES']} suites passed"
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY
}
case_dir=$(new_case lost-many)
retotal 800 88 "$case_dir/full-lane.log"
run_case fail \
    "executed 705 tests (800 minus 95 skipped); at least $gate_executed_floor must run" \
    "sixty-four lost tests are caught" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

case_dir=$(new_case lost-one)
retotal 863 92 "$case_dir/full-lane.log"
run_case fail \
    "executed 768 tests (863 minus 95 skipped); at least $gate_executed_floor must run" \
    "a single lost test is caught" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

case_dir=$(new_case added-tests)
retotal 871 93 "$case_dir/full-lane.log"
run_case pass '' "added tests do not require editing the gate" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

echo
echo "== a parameterized test a pinned lane proved =="
# Swift Testing ends a parameterized test's pass line with its case count
# (`Test f(x:) with 2 test cases passed after ...`) but its skip line without
# one; the full lane's skip must still match the pinned lane's pass.
case_dir=$(new_case parameterized)
printf '%s\n' \
    '✔ Test parameterizedGate(withClient:) with 2 test cases passed after 2.690 seconds.' \
    >> "$case_dir/SharedFixtureE2ETests.log"
printf '%s\n' \
    '➜ Test parameterizedGate(withClient:) skipped: "requires the disposable fixture"' \
    >> "$case_dir/full-lane.log"
retotal 865 92 "$case_dir/full-lane.log"
run_case pass '' "a parameterized pinned pass proves its full-lane skip" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

echo
echo "== a full-lane skip loses the lane that proved it =="
case_dir=$(new_case unproven-skip)
/usr/bin/python3 - "$case_dir/SharedFixtureE2ETests.log" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = 'Test "PTY EOF remains observable after a clean remote exit" passed'
assert old in text, "capture no longer proves the PTY EOF test"
open(path, "w", encoding="utf-8").write(text.replace(old, old.replace('"', '" ', 1)))
PY
run_case fail \
    "$unproven_says
\"PTY EOF remains observable after a clean remote exit\"" \
    "an unproven full-lane skip is caught" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

echo
echo "== each named full-lane behaviour, neutered one at a time =="
neuter() {
    NAME="$1" /usr/bin/python3 - "$2" <<'PY'
import os, sys

path, name = sys.argv[1], os.environ["NAME"]
text = open(path, encoding="utf-8").read()
# A renamed test renames both of its records. Renaming only `passed` leaves
# `started` for log_proves_test_passed to prove it from.
for record in ("passed", "started"):
    old = f"Test {name} {record}"
    assert old in text, f"capture has no {record} record for {name}; nothing to neuter"
    text = text.replace(old, f"Test {name}Renamed {record}")
open(path, "w", encoding="utf-8").write(text)
PY
}
index=0
for entry in "${full_lane_behaviors[@]}"; do
    index=$((index + 1))
    case_dir=$(new_case "neutered-$index")
    neuter "${entry#*|}" "$case_dir/full-lane.log" || die "could not neuter ${entry%%|*}"
    run_case fail "Mandatory behaviour not proven: ${entry%%|*} (${entry#*|})" \
        "neutered: ${entry%%|*}" "$case_dir" \
        assert_behavior "${entry%%|*}" full-lane "${entry#*|}"
done

case_dir=$(new_case neutered-jump-host)
neuter "$jump_host_product_path" "$case_dir/WaycarSSHJumpHostGateE2ETests.log" \
    || die "could not neuter the Jump Host product path"
run_case fail \
    "Mandatory behaviour not proven: Jump Host product path ($jump_host_product_path)" \
    "neutered: Jump Host product path" "$case_dir" \
    assert_behavior "Jump Host product path" WaycarSSHJumpHostGateE2ETests \
    "$jump_host_product_path"

echo
echo "== a passed record cut by another writer's output =="
# CI run 41144568333 logged `Test "x" pa[WaycarSSH] ... ssed after`: the test
# passed and only its `passed` record was cut. The started record and a passing
# run summary prove it; a failing run summary must not.
cut_passed_record() {
    NAME="$1" /usr/bin/python3 - "$2" <<'PY'
import os, sys

path, name = sys.argv[1], os.environ["NAME"]
text = open(path, encoding="utf-8").read()
old = f"Test {name} passed"
assert old in text, f"capture does not prove {name}; nothing to cut"
cut = f"Test {name} pa[WaycarSSH] 2026-10-31T00:14:52.121Z handshake failed [elapsed=0.003s]"
open(path, "w", encoding="utf-8").write(text.replace(old, cut))
PY
}
cut_entry=${full_lane_behaviors[0]}
case_dir=$(new_case cut-passed-record)
cut_passed_record "${cut_entry#*|}" "$case_dir/full-lane.log" \
    || die "could not cut the passed record of ${cut_entry%%|*}"
run_case pass '' "a cut passed record still proves its test" "$case_dir" \
    assert_behavior "${cut_entry%%|*}" full-lane "${cut_entry#*|}"

case_dir=$(new_case cut-passed-record-failing-run)
cut_passed_record "${cut_entry#*|}" "$case_dir/full-lane.log" \
    || die "could not cut the passed record of ${cut_entry%%|*}"
/usr/bin/python3 - "$case_dir/full-lane.log" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = "Test run with 864 tests in 92 suites passed"
assert old in text, "capture has no passing run summary"
open(path, "w", encoding="utf-8").write(text.replace(old, old.replace("passed", "failed")))
PY
run_case fail "Mandatory behaviour not proven: ${cut_entry%%|*} (${cut_entry#*|})" \
    "a cut passed record in a failing run proves nothing" "$case_dir" \
    assert_behavior "${cut_entry%%|*}" full-lane "${cut_entry#*|}"

echo
echo "== the full lane reports no passing run at all =="
case_dir=$(new_case no-summary)
/usr/bin/python3 - "$case_dir/full-lane.log" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = "Test run with 864 tests in 92 suites passed"
assert old in text
open(path, "w", encoding="utf-8").write(text.replace(old, "TEST EXECUTE SUCCEEDED"))
PY
run_case fail "The full lane printed no passing run summary" \
    "a missing run summary is caught by its own guard" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

echo
echo "== the developer-laptop exemption is narrow, not a blanket pass =="
# The capture's two real-password tests skip in both lanes, because the machine
# had no passwordless sudo. Told the privileged fixture was present -- which is
# what merge CI is -- the gate must refuse exactly those two.
case_dir=$(new_case exemption)
case_password_fixture=1
run_case fail \
    "$unproven_says
\"password authentication and exec round trip through real sshd\"
\"incorrect password has a distinct authentication error\"" \
    "with the privileged fixture present, the two password skips fail" \
    "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"
case_password_fixture=0
run_case pass '' "with it absent, exactly those two are exempt" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

case_dir=$(new_case exemption-cannot-widen)
/usr/bin/python3 - "$case_dir/SharedFixtureE2ETests.log" <<'PY'
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = 'Test "Jump Host Events preserve framing, concurrency, and slot reuse" passed'
assert old in text
open(path, "w", encoding="utf-8").write(text.replace(old, old.replace('"', '" ', 1)))
PY
run_case fail \
    "$unproven_says
\"Jump Host Events preserve framing, concurrency, and slot reuse\"" \
    "a third unproven skip is not absorbed by the exemption" "$case_dir" \
    assert_full_lane_coverage "$case_dir/full-lane.log" "$gate_executed_floor"

echo
echo "== the evidence run_suite feeds the provenance guard =="
# Everything above hands the guards a pinned_lane_logs array this harness builds
# itself, which tests the guards but not the plumbing that fills that array in
# the real script. Deleting `pinned_lane_logs+=("$log")` from run_suite left
# every case above green while leaving the gate with no evidence at all, so
# run_suite is driven here for real, against a stubbed xcodebuild that replays
# one lane of the capture.
#
# $1 pass|fail, $2 expected text, $3 label, $4 lane, then run_suite's arguments.
run_suite_case() {
    local expect=$1 expect_text=$2 label=$3 lane=$4
    shift 4
    local case_dir output status verdict reason
    case_dir=$(new_case "run-suite-$(printf '%s' "$label" | tr -c 'a-zA-Z0-9' '-')")
    mv "$case_dir/$lane.log" "$case_dir/replay.log"
    output=$(
        set +e
        # run_suite reports on stderr, so point it at the capture. run_suite is
        # then called unnested, because the property under test is a side effect
        # on pinned_lane_logs that a nested subshell would discard: a lane it
        # refuses exits here and simply prints no status, which reads as red.
        exec 2>&1
        # Both read by the extracted run_suite, which shellcheck cannot see.
        # shellcheck disable=SC2034
        fixture_dir="$case_dir"
        # shellcheck disable=SC2034
        simulator_destination="stub"
        # shellcheck disable=SC2034
        app_derived_data_path="$case_dir/AppDerivedData"
        # shellcheck disable=SC2034
        xcodebuild_test_timeout_seconds=1
        pinned_lane_logs=()
        # run_xcodebuild owns the log capture so simulator replacement stays
        # in the calling shell. Replay into that log for the suite guards.
        # shellcheck disable=SC2329
        run_xcodebuild() {
            local output_log=$3
            cat "$case_dir/replay.log" | tee "$output_log"
        }
        run_suite "$@" >/dev/null
        printf 'PINNED_COUNT=%s\n' "${#pinned_lane_logs[@]}"
        printf 'PINNED_LAST=%s\n' "${pinned_lane_logs[*]-}"
        printf 'HARNESS_STATUS=0\n'
    )
    status=$(printf '%s' "$output" | sed -n 's/^HARNESS_STATUS=//p' | tail -n 1)
    verdict=fail
    [[ "$status" == 0 ]] && verdict=pass

    reason=""
    if [[ "$verdict" != "$expect" ]]; then
        reason="expected $expect, got $verdict"
    elif ! printf '%s\n' "$output" | grep -qF "$expect_text"; then
        reason="did not report: $expect_text"
    fi

    case_labels+=("$label")
    ran=$((ran + 1))
    if [[ -z "$reason" ]]; then
        printf 'ok    expected-%-4s  %s\n' "$expect" "$label"
        passed=$((passed + 1))
    else
        printf 'FAIL  %s\n          (%s)\n' "$label" "$reason"
        failed=$((failed + 1))
        printf '%s\n' "$output" | sed 's/^/        | /'
    fi
}

# A lane that passes its counts must be appended, or the provenance guard has
# nothing to reason from. This is the case that dies if the append is removed.
run_suite_case pass "PINNED_LAST=$work/cases" \
    "a passing lane is recorded as evidence" WaycarSSHPTYE2ETests \
    WaycarSSHPTYE2ETests 3 1 0 WaycarSSHPTYE2ETests

# And run_suite's own guards, which were equally untested: a lane whose executed
# count moved, and a lane that skipped where no skip was budgeted.
run_suite_case fail "did not execute all 4 tests" \
    "a lane with the wrong executed count is refused" WaycarSSHPTYE2ETests \
    WaycarSSHPTYE2ETests 4 1 0 WaycarSSHPTYE2ETests
run_suite_case fail "skipped 2 tests; exactly 0 may skip" \
    "an unbudgeted skip is refused" WaycarSSHSessionE2ETests \
    WaycarSSHSessionE2ETests 14 1 0 WaycarSSHSessionE2ETests

echo
echo "== privileged sshd stop is bounded before preserving evidence =="
case_dir=$(new_case privileged-stop-timeout)
command_log="$case_dir/commands.log"
printf '%s\n' 4242 > "$case_dir/sshd-password.pid"
# The extracted cleanup functions consume these variables and command stubs
# through eval, which static analysis cannot follow.
# shellcheck disable=SC2034,SC2329
(
    fixture_dir="$case_dir"
    fixture_username=ci
    fixture_home="$case_dir/home"
    simulator_udid=""
    stall_pid=""
    fake_herdr_pid=""
    weak_network_pid=""
    unprivileged_sshd_pids=()
    password_pid=4242
    password_pid_file="$case_dir/sshd-password.pid"
    password_log="$case_dir/sshd-password.log"
    password_log_printed=0
    password_username=waycar-ci-password
    password_user_cleanup_needed=1
    password_ssh_sacl_added=1
    ps_probe_count=0

    sudo() {
        printf 'sudo %s\n' "$*" >> "$command_log"
        return 0
    }
    ps() {
        ps_probe_count=$((ps_probe_count + 1))
        (( ps_probe_count <= 100 ))
    }
    sleep() {
        printf 'sleep %s\n' "$*" >> "$command_log"
    }
    wait() {
        printf 'wait %s\n' "$*" >> "$command_log"
        return 0
    }

    cleanup
)
cleanup_exit=$?
sleep_count=$(grep -c '^sleep ' "$command_log")
reason=""
if [[ "$cleanup_exit" == 0 ]]; then
    reason="cleanup succeeded while privileged sshd stayed live"
elif grep -q '^wait ' "$command_log"; then
    reason="cleanup waited on a privileged sshd that was still live"
elif (( sleep_count == 0 )); then
    reason="cleanup did not poll for bounded privileged sshd shutdown"
elif (( sleep_count > 60 )); then
    reason="cleanup exceeded the bounded privileged sshd shutdown polls"
elif grep -qE 'dseditgroup|sysadminctl' "$command_log"; then
    reason="cleanup modified the account after privileged sshd stop failed"
elif [[ ! -d "$case_dir" ]]; then
    reason="cleanup removed fixture evidence after privileged sshd stop failed"
fi
case_labels+=("a live privileged sshd times out and preserves evidence")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' "$cleanup_exit" \
        "a live privileged sshd times out and preserves evidence"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$cleanup_exit" \
        "a live privileged sshd times out and preserves evidence" "$reason"
    failed=$((failed + 1))
fi

echo
echo "== a distinct privileged sshd launcher is also bounded =="
case_dir=$(new_case privileged-launcher-timeout)
command_log="$work/privileged-launcher-timeout-commands.log"
printf '%s\n' 4242 > "$case_dir/sshd-password.pid"
# The target daemon is already gone, but the distinct sudo launcher remains a
# live non-zombie. Cleanup must not enter an unbounded Bash 3 wait for it.
# shellcheck disable=SC2034,SC2329
(
    fixture_dir="$case_dir"
    fixture_username=ci
    fixture_home="$case_dir/home"
    simulator_udid=""
    stall_pid=""
    fake_herdr_pid=""
    weak_network_pid=""
    unprivileged_sshd_pids=()
    password_pid=4343
    password_pid_file="$case_dir/sshd-password.pid"
    password_log="$case_dir/sshd-password.log"
    password_log_printed=0
    password_username=waycar-ci-password
    password_user_cleanup_needed=0
    password_ssh_sacl_added=0

    sudo() {
        printf 'sudo %s\n' "$*" >> "$command_log"
        return 0
    }
    ps() {
        local pid=""
        while (( $# > 0 )); do
            if [[ "$1" == "-p" && $# -gt 1 ]]; then
                pid=$2
            fi
            shift
        done
        if [[ "$pid" == "4343" ]]; then
            printf 'S\n'
            return 0
        fi
        return 1
    }
    sleep() {
        printf 'sleep %s\n' "$*" >> "$command_log"
    }
    wait() {
        printf 'wait %s\n' "$*" >> "$command_log"
        return 0
    }

    cleanup
)
cleanup_exit=$?
sleep_count=$(grep -c '^sleep ' "$command_log" || true)
reason=""
if [[ "$cleanup_exit" == 0 ]]; then
    reason="cleanup succeeded while the distinct launcher stayed live"
elif grep -q '^wait ' "$command_log"; then
    reason="cleanup waited on a live non-zombie launcher"
elif (( sleep_count == 0 )); then
    reason="cleanup did not poll the distinct launcher for bounded shutdown"
elif (( sleep_count > 60 )); then
    reason="cleanup exceeded the bounded distinct-launcher shutdown polls"
elif [[ ! -d "$case_dir" ]]; then
    reason="cleanup removed fixture evidence while the distinct launcher stayed live"
fi
case_labels+=("a live distinct privileged launcher times out without wait")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' "$cleanup_exit" \
        "a live distinct privileged launcher times out without wait"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$cleanup_exit" \
        "a live distinct privileged launcher times out without wait" "$reason"
    failed=$((failed + 1))
fi

echo
echo "== password SSH access removal failure preserves evidence =="
case_dir=$(new_case password-sacl-removal-failure)
command_log="$work/password-sacl-removal-failure-commands.log"
# The extracted cleanup function consumes these variables and command stubs
# through eval, which static analysis cannot follow.
# shellcheck disable=SC2034,SC2329
cleanup_output=$(
    (
        fixture_dir="$case_dir"
        fixture_username=ci
        fixture_home="$case_dir/home"
        simulator_udid=""
        stall_pid=""
        fake_herdr_pid=""
        weak_network_pid=""
        unprivileged_sshd_pids=()
        password_pid=""
        password_pid_file="$case_dir/sshd-password.pid"
        password_log="$case_dir/sshd-password.log"
        password_log_printed=0
        password_username=waycar-ci-password
        password_user_cleanup_needed=1
        password_ssh_sacl_added=1

        dscl() {
            printf 'dscl %s\n' "$*" >> "$command_log"
            return 0
        }
        sudo() {
            printf 'sudo %s\n' "$*" >> "$command_log"
            if [[ "$*" == *"/usr/sbin/dseditgroup -o edit -d "* ]]; then
                return 1
            fi
            return 0
        }

        cleanup
    ) 2>&1
)
cleanup_exit=$?
reason=""
if [[ "$cleanup_exit" == 0 ]]; then
    reason="cleanup succeeded after SSH access removal failed"
elif grep -qF '/usr/sbin/sysadminctl -deleteUser' "$command_log"; then
    reason="cleanup deleted the account after SSH access removal failed"
elif [[ ! -d "$case_dir" ]]; then
    reason="cleanup removed fixture evidence after SSH access removal failed"
elif ! printf '%s\n' "$cleanup_output" \
    | grep -qF "Failed to remove password account waycar-ci-password from SSH access."; then
    reason="cleanup did not diagnose the SSH access removal failure"
fi
case_labels+=("password SSH access removal failure preserves evidence")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' "$cleanup_exit" \
        "password SSH access removal failure preserves evidence"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$cleanup_exit" \
        "password SSH access removal failure preserves evidence" "$reason"
    failed=$((failed + 1))
fi

echo
echo "== an absent password account is a successful cleanup no-op =="
# There is no hermetic seam for injecting EXIT/INT/TERM between the cleanup
# intent assignment and the privileged sysadminctl spawn. The cases below
# prove both resulting record states instead; do not replace them with a
# source-order assertion.
case_dir=$(new_case password-account-absent)
command_log="$work/password-account-absent-commands.log"
# The extracted cleanup function consumes these variables and command stubs
# through eval, which static analysis cannot follow.
# shellcheck disable=SC2034,SC2329
(
    fixture_dir="$case_dir"
    fixture_username=ci
    fixture_home="$case_dir/home"
    simulator_udid=""
    stall_pid=""
    fake_herdr_pid=""
    weak_network_pid=""
    unprivileged_sshd_pids=()
    password_pid=""
    password_pid_file="$case_dir/sshd-password.pid"
    password_log="$case_dir/sshd-password.log"
    password_log_printed=0
    password_username=waycar-ci-password
    password_user_cleanup_needed=1
    password_ssh_sacl_added=0

    dscl() {
        printf 'dscl %s\n' "$*" >> "$command_log"
        return 1
    }
    sudo() {
        printf 'sudo %s\n' "$*" >> "$command_log"
        return 0
    }

    cleanup
)
cleanup_exit=$?
reason=""
if [[ "$cleanup_exit" != 0 ]]; then
    reason="cleanup failed when the password account record was absent"
elif ! grep -qF 'dscl . -read /Users/waycar-ci-password' "$command_log"; then
    reason="cleanup did not query the exact password account record"
elif grep -qF '/usr/sbin/sysadminctl -deleteUser' "$command_log"; then
    reason="cleanup tried to delete an absent password account"
elif [[ -d "$case_dir" ]]; then
    reason="cleanup preserved fixture evidence for an absent password account"
fi
case_labels+=("an absent password account is a successful cleanup no-op")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' "$cleanup_exit" \
        "an absent password account is a successful cleanup no-op"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$cleanup_exit" \
        "an absent password account is a successful cleanup no-op" "$reason"
    failed=$((failed + 1))
fi

echo
echo "== a failed delete without -keepHome keeps the account's home and the evidence =="
# The retry without -keepHome is reached only for this run's own home. When it
# fails the account still owns that home, so root must not remove it and the
# fixture stays for diagnosis. Falling through to the rm would report success
# while the account remains for the next run's sysadminctl -addUser to trip on.
case_dir=$(new_case password-delete-failure)
case_home="$case_dir/password-home"
command_log="$work/password-delete-failure-commands.log"
# The extracted cleanup functions consume these variables and command stubs
# through eval, which static analysis cannot follow.
# shellcheck disable=SC2034,SC2329
cleanup_output=$(
    (
        fixture_dir="$case_dir"
        fixture_username=ci
        fixture_home="$case_dir/home"
        simulator_udid=""
        stall_pid=""
        fake_herdr_pid=""
        weak_network_pid=""
        unprivileged_sshd_pids=()
        password_pid=""
        password_pid_file="$case_dir/sshd-password.pid"
        password_log="$case_dir/sshd-password.log"
        password_log_printed=0
        password_username=waycar-ci-password
        password_home="$case_home"
        password_user_cleanup_needed=1
        password_ssh_sacl_added=0

        dscl() {
            printf 'dscl %s\n' "$*" >> "$command_log"
            if [[ "$*" == ". -read /Users/waycar-ci-password NFSHomeDirectory" ]]; then
                printf 'NFSHomeDirectory: %s\n' "$case_home"
            fi
            return 0
        }
        sudo() {
            printf 'sudo %s\n' "$*" >> "$command_log"
            if [[ "$*" == *" -keepHome" ]]; then
                echo "'-keepHome' options is not available on this system systems." >&2
                return 255
            fi
            if [[ "$*" == "-n /usr/sbin/sysadminctl -deleteUser waycar-ci-password" ]]; then
                return 1
            fi
            return 0
        }

        cleanup
    ) 2>&1
)
cleanup_exit=$?
reason=""
if [[ "$cleanup_exit" == 0 ]]; then
    reason="cleanup succeeded after the delete without -keepHome failed"
elif ! grep -qxF 'sudo -n /usr/sbin/sysadminctl -deleteUser waycar-ci-password' \
    "$command_log"; then
    reason="cleanup did not retry the deletion without -keepHome"
elif grep -qF 'rm -rf' "$command_log"; then
    reason="cleanup removed the home of an account it failed to delete"
elif [[ ! -d "$case_dir" ]]; then
    reason="cleanup removed fixture evidence after the account deletion failed"
elif ! printf '%s\n' "$cleanup_output" \
    | grep -qF "Failed to delete password account waycar-ci-password."; then
    reason="cleanup did not diagnose the password account deletion failure"
fi
case_labels+=("a failed delete without -keepHome keeps the account's home and the evidence")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' "$cleanup_exit" \
        "a failed delete without -keepHome keeps the account's home and the evidence"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$cleanup_exit" \
        "a failed delete without -keepHome keeps the account's home and the evidence" \
        "$reason"
    failed=$((failed + 1))
fi

echo
echo "== a rejected -keepHome deletes this run's account without it =="
# macOS 27 refuses -keepHome and keeps the account, whose full name then fails
# the next run's sysadminctl -addUser. Without the flag sysadminctl may remove
# the home, which is safe only for the home this run created.
case_dir=$(new_case password-keephome-rejected)
case_home="$case_dir/password-home"
command_log="$work/password-keephome-rejected-commands.log"
# The extracted cleanup functions consume these variables and command stubs
# through eval, which static analysis cannot follow.
# shellcheck disable=SC2034,SC2329
cleanup_output=$(
    (
        fixture_dir="$case_dir"
        fixture_username=ci
        fixture_home="$case_dir/home"
        simulator_udid=""
        stall_pid=""
        fake_herdr_pid=""
        weak_network_pid=""
        unprivileged_sshd_pids=()
        password_pid=""
        password_pid_file="$case_dir/sshd-password.pid"
        password_log="$case_dir/sshd-password.log"
        password_log_printed=0
        password_username=waycar-ci-password
        password_home="$case_home"
        password_user_cleanup_needed=1
        password_ssh_sacl_added=0

        dscl() {
            printf 'dscl %s\n' "$*" >> "$command_log"
            if [[ "$*" == ". -read /Users/waycar-ci-password NFSHomeDirectory" ]]; then
                printf 'NFSHomeDirectory: %s\n' "$case_home"
            fi
            return 0
        }
        sudo() {
            printf 'sudo %s\n' "$*" >> "$command_log"
            if [[ "$*" == *" -keepHome" ]]; then
                echo "'-keepHome' options is not available on this system systems." >&2
                return 255
            fi
            return 0
        }

        cleanup
    ) 2>&1
)
cleanup_exit=$?
reason=""
if [[ "$cleanup_exit" != 0 ]]; then
    reason="cleanup failed after macOS rejected -keepHome"
elif ! grep -qxF 'sudo -n /usr/sbin/sysadminctl -deleteUser waycar-ci-password' \
    "$command_log"; then
    reason="cleanup did not retry the deletion without -keepHome"
elif ! grep -qxF "sudo -n rm -rf -- $case_home" "$command_log"; then
    reason="cleanup left the home to a UID that no longer exists"
elif [[ -d "$case_dir" ]]; then
    reason="cleanup preserved the fixture after deleting the account"
elif printf '%s\n' "$cleanup_output" | grep -qF "Failed to delete password account"; then
    reason="cleanup reported a failed deletion after the retry deleted the account"
fi
case_labels+=("a rejected -keepHome deletes this run's account without it")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' "$cleanup_exit" \
        "a rejected -keepHome deletes this run's account without it"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$cleanup_exit" \
        "a rejected -keepHome deletes this run's account without it" "$reason"
    failed=$((failed + 1))
fi

echo
echo "== a rejected -keepHome spares a home this run did not create =="
case_dir=$(new_case password-keephome-foreign-home)
command_log="$work/password-keephome-foreign-home-commands.log"
# The extracted cleanup functions consume these variables and command stubs
# through eval, which static analysis cannot follow.
# shellcheck disable=SC2034,SC2329
cleanup_output=$(
    (
        fixture_dir="$case_dir"
        fixture_username=ci
        fixture_home="$case_dir/home"
        simulator_udid=""
        stall_pid=""
        fake_herdr_pid=""
        weak_network_pid=""
        unprivileged_sshd_pids=()
        password_pid=""
        password_pid_file="$case_dir/sshd-password.pid"
        password_log="$case_dir/sshd-password.log"
        password_log_printed=0
        password_username=waycar-ci-password
        password_home="$case_dir/password-home"
        password_user_cleanup_needed=1
        password_ssh_sacl_added=0

        dscl() {
            printf 'dscl %s\n' "$*" >> "$command_log"
            if [[ "$*" == ". -read /Users/waycar-ci-password NFSHomeDirectory" ]]; then
                printf 'NFSHomeDirectory: /Users/waycar-ci-password\n'
            fi
            return 0
        }
        sudo() {
            printf 'sudo %s\n' "$*" >> "$command_log"
            if [[ "$*" == *" -keepHome" ]]; then
                echo "'-keepHome' options is not available on this system systems." >&2
                return 255
            fi
            return 0
        }

        cleanup
    ) 2>&1
)
cleanup_exit=$?
reason=""
if [[ "$cleanup_exit" == 0 ]]; then
    reason="cleanup succeeded while the account kept a home this run did not create"
elif grep -qxF 'sudo -n /usr/sbin/sysadminctl -deleteUser waycar-ci-password' \
    "$command_log"; then
    reason="cleanup dropped -keepHome for a home this run did not create"
elif grep -qF 'rm -rf' "$command_log"; then
    reason="cleanup removed a home this run did not create"
elif [[ ! -d "$case_dir" ]]; then
    reason="cleanup removed fixture evidence after the account deletion failed"
elif ! printf '%s\n' "$cleanup_output" \
    | grep -qF "Failed to delete password account waycar-ci-password."; then
    reason="cleanup did not diagnose the password account deletion failure"
fi
case_labels+=("a rejected -keepHome spares a home this run did not create")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' "$cleanup_exit" \
        "a rejected -keepHome spares a home this run did not create"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$cleanup_exit" \
        "a rejected -keepHome spares a home this run did not create" "$reason"
    failed=$((failed + 1))
fi

echo
echo "== an accepted -keepHome deletes only the record =="
# Where macOS still honors -keepHome the first delete is the whole teardown.
# The home is read once, before it, to prove the account is this run's;
# reading it afterwards would query a deleted record and fail a passing run.
# Retrying without the flag or removing the home as root would be work the
# accepted delete already made unnecessary.
case_dir=$(new_case password-keephome-accepted)
case_home="$case_dir/password-home"
command_log="$work/password-keephome-accepted-commands.log"
# The extracted cleanup functions consume these variables and command stubs
# through eval, which static analysis cannot follow.
# shellcheck disable=SC2034,SC2329
cleanup_output=$(
    (
        fixture_dir="$case_dir"
        fixture_username=ci
        fixture_home="$case_dir/home"
        simulator_udid=""
        stall_pid=""
        fake_herdr_pid=""
        weak_network_pid=""
        unprivileged_sshd_pids=()
        password_pid=""
        password_pid_file="$case_dir/sshd-password.pid"
        password_log="$case_dir/sshd-password.log"
        password_log_printed=0
        password_username=waycar-ci-password
        password_home="$case_home"
        password_user_cleanup_needed=1
        password_ssh_sacl_added=0

        dscl() {
            printf 'dscl %s\n' "$*" >> "$command_log"
            if [[ "$*" == ". -read /Users/waycar-ci-password NFSHomeDirectory" ]]; then
                printf 'NFSHomeDirectory: %s\n' "$case_home"
            fi
            return 0
        }
        sudo() {
            printf 'sudo %s\n' "$*" >> "$command_log"
            return 0
        }

        cleanup
    ) 2>&1
)
cleanup_exit=$?
sysadminctl_calls=$(grep -cF '/usr/sbin/sysadminctl' "$command_log")
reason=""
if [[ "$cleanup_exit" != 0 ]]; then
    reason="cleanup failed after macOS accepted -keepHome"
elif [[ "$sysadminctl_calls" != 1 ]]; then
    reason="cleanup ran sysadminctl $sysadminctl_calls times, expected one -keepHome delete"
elif ! grep -qxF 'sudo -n /usr/sbin/sysadminctl -deleteUser waycar-ci-password -keepHome' \
    "$command_log"; then
    reason="cleanup did not delete the password account with -keepHome"
elif grep -qxF 'sudo -n /usr/sbin/sysadminctl -deleteUser waycar-ci-password' \
    "$command_log"; then
    reason="cleanup retried without -keepHome after macOS accepted it"
elif [[ "$(grep -cF 'NFSHomeDirectory' "$command_log")" != 1 ]] \
    || [[ "$(grep -nF 'NFSHomeDirectory' "$command_log" | cut -d: -f1)" \
        -gt "$(grep -nF -- '-keepHome' "$command_log" | cut -d: -f1)" ]]; then
    reason="cleanup read the home other than once, before the delete"
elif grep -qF 'rm -rf' "$command_log"; then
    reason="cleanup removed the home as root after macOS accepted -keepHome"
elif [[ -d "$case_dir" ]]; then
    reason="cleanup preserved the fixture after deleting the account"
fi
case_labels+=("an accepted -keepHome deletes only the record")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' "$cleanup_exit" \
        "an accepted -keepHome deletes only the record"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$cleanup_exit" \
        "an accepted -keepHome deletes only the record" "$reason"
    failed=$((failed + 1))
fi

echo
echo "== an account this run did not create is never deleted =="
# A concurrent run that drew the same name owns the record: even the first,
# -keepHome delete must not touch it.
case_dir=$(new_case password-foreign-account)
command_log="$work/password-foreign-account-commands.log"
# The extracted cleanup functions consume these variables and command stubs
# through eval, which static analysis cannot follow.
# shellcheck disable=SC2030,SC2034,SC2329
cleanup_output=$(
    (
        fixture_dir="$case_dir"
        fixture_username=ci
        fixture_home="$case_dir/home"
        simulator_udid=""
        stall_pid=""
        fake_herdr_pid=""
        weak_network_pid=""
        unprivileged_sshd_pids=()
        password_pid=""
        password_pid_file="$case_dir/sshd-password.pid"
        password_log="$case_dir/sshd-password.log"
        password_log_printed=0
        password_username=waycar-ci-password
        password_home="$case_dir/password-home"
        password_user_cleanup_needed=1
        password_ssh_sacl_added=0

        dscl() {
            printf 'dscl %s\n' "$*" >> "$command_log"
            if [[ "$*" == ". -read /Users/waycar-ci-password NFSHomeDirectory" ]]; then
                printf 'NFSHomeDirectory: /private/tmp/other-run/password-home\n'
            fi
            return 0
        }
        sudo() {
            printf 'sudo %s\n' "$*" >> "$command_log"
            return 0
        }

        cleanup
    ) 2>&1
)
cleanup_exit=$?
reason=""
if [[ "$cleanup_exit" == 0 ]]; then
    reason="cleanup succeeded while the account belonged to another run"
elif grep -qF '/usr/sbin/sysadminctl -deleteUser' "$command_log"; then
    reason="cleanup deleted an account this run did not create"
elif grep -qF 'rm -rf' "$command_log"; then
    reason="cleanup removed a home this run did not create"
elif [[ ! -d "$case_dir" ]]; then
    reason="cleanup removed fixture evidence after refusing the deletion"
elif ! printf '%s\n' "$cleanup_output" \
    | grep -qF "Failed to delete password account waycar-ci-password."; then
    reason="cleanup did not diagnose the refused deletion"
fi
case_labels+=("an account this run did not create is never deleted")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' "$cleanup_exit" \
        "an account this run did not create is never deleted"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$cleanup_exit" \
        "an account this run did not create is never deleted" "$reason"
    failed=$((failed + 1))
fi

echo
echo "== the password account name skips existing records =="
command_log="$work/password-name-commands.log"
# The extracted function consumes the dscl stub and RANDOM through eval,
# which static analysis cannot follow.
# shellcheck disable=SC2031,SC2034,SC2329
picked=$(
    dscl() {
        printf 'dscl %s\n' "$*" >> "$command_log"
        # The first two names drawn already exist.
        [[ $(grep -c . "$command_log") -le 2 ]]
    }
    pick_password_username
    printf '%s\n' "$password_username"
)
reason=""
if [[ "$(grep -c '^dscl . -read /Users/waycarssh[0-9]*$' "$command_log")" != 3 ]]; then
    reason="the name was not redrawn while a record with it existed"
elif [[ ! "$picked" =~ ^waycarssh[0-9]+$ ]]; then
    reason="the picked name '$picked' is not a waycarssh name"
elif [[ "$(tail -n 1 "$command_log")" != "dscl . -read /Users/$picked" ]]; then
    reason="the picked name is not the one found free"
fi
case_labels+=("the password account name skips existing records")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' 0 \
        "the password account name skips existing records"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' 1 \
        "the password account name skips existing records" "$reason"
    failed=$((failed + 1))
fi

echo
echo "== a failed run copies diagnostics then deletes the fixture =="
case_dir=$(new_case failed-run-diagnostics)
diagnostic_copy="$work/failed-run-diagnostics-copy"
printf 'sshd-ready-marker\n' > "$case_dir/sshd-modern.log"
printf 'weak-proxy-marker\n' > "$case_dir/weak-network.log"
printf 'BEGIN PRIVATE KEY\nSECRET-KEY-MATERIAL\n' > "$case_dir/device_key"
mkdir -p "$case_dir/AppDerivedData/Logs/Test/Sample.xcresult"
printf 'xcresult-marker\n' \
    > "$case_dir/AppDerivedData/Logs/Test/Sample.xcresult/Info.plist"
# The extracted cleanup function consumes these variables and command stubs
# through eval, which static analysis cannot follow.
# shellcheck disable=SC2034,SC2329
cleanup_output=$(
    (
        fixture_dir="$case_dir"
        diagnostic_root="$diagnostic_copy"
        app_derived_data_path="$case_dir/AppDerivedData"
        package_derived_data_path="$case_dir/PackageDerivedData"
        fixture_username=ci
        fixture_home="$case_dir/home"
        simulator_udid=""
        stall_pid=""
        fake_herdr_pid=""
        weak_network_pid=""
        unprivileged_sshd_pids=()
        password_pid=""
        password_pid_file="$case_dir/sshd-password.pid"
        password_log="$case_dir/sshd-password.log"
        password_log_printed=0
        password_username=waycar-ci-password
        password_user_cleanup_needed=0
        password_ssh_sacl_added=0
        fixture_log_tail_lines=80

        false
        cleanup
    ) 2>&1
)
cleanup_exit=$?
reason=""
if [[ "$cleanup_exit" == 0 ]]; then
    reason="cleanup succeeded after a failed run"
elif [[ -d "$case_dir" ]]; then
    reason="cleanup left the fixture directory after copying diagnostics"
elif [[ ! -f "$diagnostic_copy/fixture/exit-status.txt" ]]; then
    reason="cleanup did not record the original nonzero status"
elif [[ "$(cat "$diagnostic_copy/fixture/exit-status.txt")" != 1 ]]; then
    reason="cleanup recorded $(cat "$diagnostic_copy/fixture/exit-status.txt") instead of 1"
elif [[ ! -f "$diagnostic_copy/fixture/logs/sshd-modern.log" ]]; then
    reason="cleanup did not copy the fixture sshd log"
elif [[ ! -f "$diagnostic_copy/fixture/logs/weak-network.log" ]]; then
    reason="cleanup did not copy the weak-network proxy log"
elif [[ ! -f "$diagnostic_copy/fixture/AppDerivedData-Logs-Test/Sample.xcresult/Info.plist" ]]; then
    reason="cleanup did not copy the xcresult bundle"
elif [[ -e "$diagnostic_copy/fixture/device_key" \
    || -e "$diagnostic_copy/fixture/logs/device_key" ]]; then
    reason="cleanup copied private-key material into diagnostics"
elif ! printf '%s\n' "$cleanup_output" | grep -qF "sshd-ready-marker"; then
    reason="cleanup did not print a bounded sshd log tail"
elif ! printf '%s\n' "$cleanup_output" | grep -qF "weak-proxy-marker"; then
    reason="cleanup did not print a bounded weak-network log tail"
elif printf '%s\n' "$cleanup_output" | grep -qF "SECRET-KEY-MATERIAL"; then
    reason="cleanup printed private-key material"
elif printf '%s\n' "$cleanup_output" | grep -qF "BEGIN PRIVATE KEY"; then
    reason="cleanup printed private-key PEM header"
fi
case_labels+=("a failed run copies diagnostics then deletes the fixture")
ran=$((ran + 1))
if [[ -z "$reason" ]]; then
    printf 'ok    expected-pass  exit=%-3s  %s\n' "$cleanup_exit" \
        "a failed run copies diagnostics then deletes the fixture"
    passed=$((passed + 1))
else
    printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$cleanup_exit" \
        "a failed run copies diagnostics then deletes the fixture" "$reason"
    failed=$((failed + 1))
    printf '%s\n' "$cleanup_output" | sed 's/^/        | /'
fi

record_case() {
    local label=$1 reason=$2 status=$3
    case_labels+=("$label")
    ran=$((ran + 1))
    if [[ -z "$reason" ]]; then
        printf 'ok    expected-pass  exit=%-3s  %s\n' "$status" "$label"
        passed=$((passed + 1))
    else
        printf 'FAIL  exit=%-3s  %s\n          (%s)\n' "$status" "$label" "$reason"
        failed=$((failed + 1))
    fi
}
echo
echo "== Zellij cleanup is scratch-only and spares a bystander =="
# The owned process carries HOME only in its environment, not argv, like
# a daemonized pane program. The binary records the actual scratch env used
# by both destructive commands; an inherited marker must not reach either.
# Read by the extracted stop function, which static analysis cannot follow.
# shellcheck disable=SC2034
{
    zellij_home="$work/zellij-cleanup"
    zellij_binary="$zellij_home/bin/zellij"
    zellij_socket_dir="$zellij_home/s"
    zellij_path=/usr/bin:/bin
}
mkdir -p "$zellij_home/bin"
cat > "$zellij_binary" <<'SH'
#!/bin/sh
printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "$*" "$HOME" "$ZELLIJ_SOCKET_DIR" "$PATH" "$TMPDIR" \
    "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" \
    "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "${WAYCAR_ZELLIJ_GUARD_LEAK-unset}" >> "$HOME/cleanup.log"
SH
chmod 755 "$zellij_binary"
env -i "HOME=$zellij_home" /bin/sleep 300 &
zellij_owned_pid=$!
sleep 300 &
zellij_bystander_pid=$!
WAYCAR_ZELLIJ_GUARD_LEAK=must-not-reach-the-binary stop_zellij_fixture
zellij_cleanup_status=$?
reason=""
expected_env="|$zellij_home|$zellij_socket_dir|$zellij_path|$zellij_home/tmp|$zellij_home/run"
expected_env+="|$zellij_home/.config|$zellij_home/.local/state|$zellij_home/.local/share|$zellij_home/.cache|unset"
if [[ "$zellij_cleanup_status" != 0 ]]; then
    reason="stop_zellij_fixture failed with $zellij_cleanup_status"
elif kill -0 "$zellij_owned_pid" 2>/dev/null; then
    reason="cleanup left the environment-owned process running"
elif ! kill -0 "$zellij_bystander_pid" 2>/dev/null; then
    reason="cleanup signalled the bystander"
elif ! grep -qxF "kill-all-sessions -y$expected_env" "$zellij_home/cleanup.log" \
    || ! grep -qxF "delete-all-sessions -y -f$expected_env" "$zellij_home/cleanup.log"; then
    reason="cleanup did not run both destructive commands through the scratch env only"
fi
kill "$zellij_owned_pid" "$zellij_bystander_pid" 2>/dev/null || true
wait "$zellij_owned_pid" "$zellij_bystander_pid" 2>/dev/null || true
zellij_home=""
record_case "Zellij cleanup stops only owned processes using scratch-only commands" \
    "$reason" "$zellij_cleanup_status"

echo
echo "== password fixture provisioning names its failing step (#348) =="
# Five CI runs exited 1 between "Claimed simulator" and the first xcodebuild
# with nothing printed: every command in the password fixture block was silent
# under set -e. These cases hold the wrapper, the transcript scrub, and the
# expect script's exit paths to the contract that the job log names the step,
# the reason, and never the account password.
provisioning_fail_3() {
    return 3
}
step_output=$(
    set +e
    provisioning_step "fake step" provisioning_fail_3 2>&1
    printf 'STATUS=%s\n' "$?"
)
step_status=$(printf '%s\n' "$step_output" | sed -n 's/^STATUS=//p')
reason=""
if [[ "$step_status" != 3 ]]; then
    reason="status $step_status, expected the step's own 3"
elif ! printf '%s\n' "$step_output" \
    | grep -qF 'Password fixture provisioning failed at fake step (status 3).'; then
    reason="failure did not name the step and status"
fi
record_case "a failing provisioning step names itself and keeps its status" \
    "$reason" "$step_status"

step_output=$(
    set +e
    provisioning_step "fake step" true 2>&1
    printf 'STATUS=%s\n' "$?"
)
reason=""
[[ "$step_output" == "STATUS=0" ]] \
    || reason="a passing step returned or printed something: $step_output"
record_case "a passing provisioning step is silent" "$reason" \
    "$(printf '%s\n' "$step_output" | sed -n 's/^STATUS=//p')"

fake_secret="secret-$RANDOM-$RANDOM"
transcript="$work/redact-transcript.log"
printf 'User password: %s\r\nagain %s and %s\n' \
    "$fake_secret" "$fake_secret" "$fake_secret" > "$transcript"
redact_secret_in_file "$transcript" "$fake_secret"
reason=""
if grep -qF "$fake_secret" "$transcript"; then
    reason="the secret survived redaction"
elif [[ "$(grep -o '\[redacted\]' "$transcript" | wc -l | tr -d ' ')" != 3 ]]; then
    reason="expected three redactions, transcript reads: $(cat "$transcript")"
elif ! grep -qF 'User password:' "$transcript"; then
    reason="redaction removed more than the secret"
fi
record_case "the sysadminctl transcript is scrubbed of the account password" \
    "$reason" 0

printf 'User password:\nnothing secret here\n' > "$transcript"
before=$(cat "$transcript")
redact_secret_in_file "$transcript" ""
reason=""
[[ "$(cat "$transcript")" == "$before" ]] \
    || reason="an empty secret rewrote the transcript: $(cat "$transcript")"
record_case "an empty secret leaves the transcript untouched" "$reason" 0

# The expect script is lifted out of create_password_user as shipped, then only
# its spawn target and deadline are redirected: the stand-in sysadminctl is a
# shell script, and the 30s deadline becomes 5s so the timeout path is cheap
# while a loaded machine still starts a stand-in well inside the deadline.
sysadminctl_expect="$work/sysadminctl.exp"
awk '/^create_password_user\(\) \($/ { in_function = 1 }
     in_function && /<<'"'"'EXPECT'"'"'$/ { inside = 1; next }
     inside && /^EXPECT$/ { exit }
     inside { print }' "$gate_script" > "$sysadminctl_expect"
[[ -s "$sysadminctl_expect" ]] \
    || die "no sysadminctl expect script inside create_password_user"
perl -0pi -e 's/spawn \/usr\/bin\/sudo -n \/usr\/sbin\/sysadminctl \\\n(?:    [^\n]*\\\n)*    -password -\n/spawn \$env(WAYCAR_FAKE_SYSADMINCTL)\n/; s/^set timeout 30$/set timeout 5/m' \
    "$sysadminctl_expect"
# shellcheck disable=SC2016
grep -qF 'spawn $env(WAYCAR_FAKE_SYSADMINCTL)' "$sysadminctl_expect" \
    || die "could not redirect the sysadminctl spawn in the lifted expect script"
grep -qF 'set timeout 5' "$sysadminctl_expect" \
    || die "could not shorten the sysadminctl deadline in the lifted expect script"
sysadminctl_transcript="$work/sysadminctl.log"
# Runs the lifted script against one stand-in; prints its output then STATUS=.
run_sysadminctl_expect() {
    set +e
    WAYCAR_FAKE_SYSADMINCTL="$1" \
    WAYCAR_SYSADMINCTL_LOG="$sysadminctl_transcript" \
    WAYCAR_SYSADMINCTL_PASSWORD="$fake_secret" \
    WAYCAR_SYSADMINCTL_USERNAME=waycarssh0 \
    WAYCAR_SYSADMINCTL_UID=600 \
    WAYCAR_SYSADMINCTL_HOME="$work/password-home" \
        /usr/bin/expect "$sysadminctl_expect" 2>&1
    printf 'STATUS=%s\n' "$?"
}
write_stand_in() {
    printf '#!/bin/bash\n%s\n' "$2" > "$1"
    chmod +x "$1"
}
# The real prompt is "User password:". The stand-ins read with echo left on,
# so a transcript that records the pty would record the password unless the
# script turns echo off first.
write_stand_in "$work/sysadminctl-exit7.sh" \
    'printf "User password:"; read -r pw; echo; echo "boom" >&2; exit 7'
write_stand_in "$work/sysadminctl-noprompt.sh" \
    'echo "Password is required!"; exit 3'
write_stand_in "$work/sysadminctl-hang.sh" \
    'echo "thinking"; sleep 30'
# shellcheck disable=SC2016
write_stand_in "$work/sysadminctl-ok.sh" \
    'printf "User password:"; read -r pw; printf "\nread %s bytes\n" "${#pw}"; exit 0'

rm -f "$sysadminctl_transcript"
expect_output=$(run_sysadminctl_expect "$work/sysadminctl-exit7.sh")
expect_status=$(printf '%s\n' "$expect_output" | sed -n 's/^STATUS=//p')
reason=""
if [[ "$expect_status" != 7 ]]; then
    reason="status $expect_status, expected sysadminctl's own 7"
elif ! printf '%s\n' "$expect_output" | grep -qF 'sysadminctl exited with status 7'; then
    reason="the exit status was not reported: $expect_output"
fi
record_case "a sysadminctl failure reports its exit status" "$reason" "$expect_status"

rm -f "$sysadminctl_transcript"
expect_output=$(run_sysadminctl_expect "$work/sysadminctl-noprompt.sh")
expect_status=$(printf '%s\n' "$expect_output" | sed -n 's/^STATUS=//p')
reason=""
if [[ "$expect_status" != 1 ]]; then
    reason="status $expect_status, expected 1"
elif ! printf '%s\n' "$expect_output" \
    | grep -qF 'sysadminctl exited without prompting for a password'; then
    reason="the missing prompt was not reported: $expect_output"
elif ! grep -qF 'Password is required!' "$sysadminctl_transcript"; then
    reason="the transcript did not record what sysadminctl printed"
fi
record_case "a sysadminctl that never prompts is reported with its transcript" \
    "$reason" "$expect_status"

rm -f "$sysadminctl_transcript"
expect_output=$(run_sysadminctl_expect "$work/sysadminctl-hang.sh")
expect_status=$(printf '%s\n' "$expect_output" | sed -n 's/^STATUS=//p')
reason=""
if [[ "$expect_status" != 1 ]]; then
    reason="status $expect_status, expected 1"
elif ! printf '%s\n' "$expect_output" \
    | grep -qF 'sysadminctl timed out after 5s (password sent: 0)'; then
    reason="the deadline was not reported: $expect_output"
fi
record_case "a sysadminctl that hangs is reported as timed out" \
    "$reason" "$expect_status"

rm -f "$sysadminctl_transcript"
expect_output=$(run_sysadminctl_expect "$work/sysadminctl-ok.sh")
expect_status=$(printf '%s\n' "$expect_output" | sed -n 's/^STATUS=//p')
reason=""
if [[ "$expect_status" != 0 ]]; then
    reason="status $expect_status: $expect_output"
elif [[ "$expect_output" != "STATUS=0" ]]; then
    reason="a successful sysadminctl printed something: $expect_output"
elif grep -qF "$fake_secret" "$sysadminctl_transcript"; then
    # The stand-in reads with echo on, so only the script's own stty -echo
    # keeps the password out of the transcript before any scrub runs.
    reason="the transcript recorded the password before redaction"
elif ! grep -qF 'User password:' "$sysadminctl_transcript"; then
    reason="the transcript did not record the prompt"
else
    redact_secret_in_file "$sysadminctl_transcript" "$fake_secret"
    grep -qF 'User password:' "$sysadminctl_transcript" \
        || reason="redaction removed the prompt as well"
fi
record_case "a successful sysadminctl never records the password" \
    "$reason" "$expect_status"

echo "== host-load sampler survives strict mode (WAY-505) =="
# The sampler runs under the gate's `set -euo pipefail`. A count of 0 booted
# simulators (`grep -c` exits 1) or a `head` that closes the pipe on `ps` used
# to kill it before its first line, so a failed run printed no host load.
# Runs one sample in a subshell with the gate's strict mode. The status is read
# with errexit off in the caller: `x=$(...) || y` would switch errexit off inside
# the substitution as well and hide the bug under test.
run_sampler_strict() {
    sampler_output=$(
        # Stand-ins for the macOS tools; Linux has none of them.
        sysctl() { echo '{ 1.50 1.20 1.00 }'; }
        ps() {
            if [[ "$*" == *pcpu* ]]; then
                yes '0.1 /usr/bin/stand-in' | head -n 50000
            else
                printf '/usr/bin/xcodebuild\n/usr/bin/clang\n'
            fi
        }
        simctl_output=$1
        xcrun() { printf '%s' "$simctl_output"; }
        set -euo pipefail
        sample_host_load
    ) 2>&1
}
extract_shipped_function sample_host_load
set +e
run_sampler_strict ''
sampler_status=$?
set -e
reason=""
if [[ "$sampler_status" != 0 ]]; then
    reason="exited $sampler_status with no booted simulator: $sampler_output"
elif ! grep -qF 'booted sims 0' <<<"$sampler_output"; then
    reason="no sample line for zero booted simulators: $sampler_output"
fi
record_case "a sample with no booted simulator still prints a line" \
    "$reason" "$sampler_status"
set +e
run_sampler_strict '    iPhone (UDID) (Booted)'
sampler_status=$?
set -e
reason=""
if [[ "$sampler_status" != 0 ]]; then
    reason="exited $sampler_status when head closed the ps pipe: $sampler_output"
elif ! grep -qF 'booted sims 1' <<<"$sampler_output"; then
    reason="no sample line when head closed the ps pipe: $sampler_output"
elif grep -qF 'Broken pipe' <<<"$sampler_output"; then
    reason="the sample line carries a ps error: $sampler_output"
fi
record_case "a sample whose ps output is cut by head still prints a line" \
    "$reason" "$sampler_status"

echo "== a cancelled step ends the gate it started (WAY-525) =="
# The sampler cases above end with `set -e`, which this harness otherwise never
# runs under, and a step ended by SIGTERM makes `wait` return 143: the first
# seeded case would end the whole harness without a word.
set +e
# A cancelled job stops the step's shell and nothing below it: SIGINT to that
# shell alone, SIGTERM after it, and the runner stops reading the step's output.
# seeded_cancel replays that against a stand-in gate built from the shipped
# watchdog, cleanup and claim code (declare -f of the extracted functions, not
# copies), holding what the real gate holds when it is cancelled: a Simulator
# claim, a background listener and a fixture directory, blocked in a foreground
# pipeline the way run_xcodebuild is. A bystander the gate did not start runs
# beside it.
process_alive() {
    local state
    state=$(ps -o stat= -p "$1" 2>/dev/null)
    [[ -n "$state" && "$state" != Z* ]]
}

write_seeded_gate() {
    local dir=$1
    {
        printf '#!/bin/bash\nset -eo pipefail\n'
        declare -f kill_descendants start_orphan_watchdog stop_orphan_watchdog \
            cleanup clear_simulator_environment preserve_failure_diagnostics \
            dump_fixture_logs release_resource_lock acquire_claim_guard \
            release_claim_guard claim_resource_lock write_lock_owner \
            lock_is_stale stop_host_load_sampler summarize_host_load \
            stop_core_fixture stop_codex_fixture stop_opencode_fixture stop_zellij_fixture
        cat <<'STUB'
dir=$1
mode=$2
lock_root="$dir/locks"
mkdir -p "$lock_root"
lock_owner_token="$$-seeded"
lock_owner_start="$(ps -o lstart= -p "$$" | sed 's/^ *//; s/ *$//')"
fixture_dir="$(mktemp -d "$dir/fixture.XXXXXX")"
diagnostic_root="$dir/diagnostics"
device_lock_dir="$lock_root/device-seeded"
run_lock_dir=""
account_lock_dir=""
active_claim_guard=""
active_resource_lock=""
app_derived_data_path=""
package_derived_data_path=""
stall_pid=""
fake_herdr_pid=""
weak_network_pid=""
password_pid=""
password_log="$fixture_dir/sshd-password.log"
password_log_printed=0
password_user_cleanup_needed=0
password_username=""
password_home=""
simulator_udid=""
simulator_environment_variables=()
tmux_binary=""
host_load_pid=""
core_home=""
core_binary=""
core_path=/usr/bin
codex_home=""
codex_binary=""
codex_path=/usr/bin
codex_physical_socket=""
opencode_home=""
opencode_binary=""
opencode_path=/usr/bin
zellij_home=""
zellij_binary=""
zellij_socket_dir=""
zellij_path=/usr/bin
tmux_tmpdir=""
fixture_log_tail_lines=80
unprivileged_sshd_pids=()
orphan_watchdog_pid=""
orphan_check_interval_seconds=0.2
orphan_cleanup_deadline_seconds=$3
case "$mode" in
    stuck) cleanup() { trap '' INT TERM; sleep 100; } ;;
    slow) clear_simulator_environment() { sleep 3; } ;;
    late)
        # The step is cancelled while the gate is still before its trap and
        # its watchdog, as it would be during the first-launch check.
        echo "$$" > "$dir/gate.pid"
        sleep 2
        ;;
esac
trap cleanup EXIT INT TERM
start_orphan_watchdog
claim_resource_lock "$device_lock_dir" "simulator"
sleep 300 &
unprivileged_sshd_pids+=("$!")
echo "$!" > "$dir/listener.pid"
echo "$$" > "$dir/gate.pid"
if [[ "$mode" == slow ]]; then
    sleep 1
    exit 0
fi
( sleep 200 ) 2>&1 | tee "$fixture_dir/lane.log"
STUB
    } > "$dir/gate.sh"
    chmod +x "$dir/gate.sh"
}

# Starts the step shell and a bystander, and waits until the gate holds its
# claim. Sets seeded_dir, seeded_step, seeded_gate, seeded_listener,
# seeded_reader and seeded_bystander.
start_seeded_run() {
    local github_actions=$1 mode=$2 deadline=$3
    local attempt
    seeded_dir="$work/seeded-$mode-${github_actions:-local}"
    rm -rf "$seeded_dir"
    mkdir -p "$seeded_dir"
    write_seeded_gate "$seeded_dir"
    printf '"%s/gate.sh" "%s" "%s" "%s"\necho step-finished\n' \
        "$seeded_dir" "$seeded_dir" "$mode" "$deadline" > "$seeded_dir/step.sh"
    mkfifo "$seeded_dir/pipe"
    cat "$seeded_dir/pipe" > /dev/null &
    seeded_reader=$!
    GITHUB_ACTIONS="$github_actions" bash -e "$seeded_dir/step.sh" \
        > "$seeded_dir/pipe" 2>&1 &
    seeded_step=$!
    sleep 300 &
    seeded_bystander=$!
    for ((attempt = 0; attempt < 100; attempt += 1)); do
        [[ -s "$seeded_dir/gate.pid" ]] && break
        sleep 0.1
    done
    seeded_gate=$(cat "$seeded_dir/gate.pid" 2>/dev/null)
    seeded_listener=$(cat "$seeded_dir/listener.pid" 2>/dev/null)
}

# Seconds until the process is gone, or -1 if it is still there after max_wait.
seconds_until_gone() {
    local pid=$1 max_wait=$2 started=$SECONDS
    while process_alive "$pid"; do
        if (( SECONDS - started >= max_wait )); then
            echo -1
            return
        fi
        sleep 0.2
    done
    echo $((SECONDS - started))
}

# Removes whatever the seeded run left, and only that: the gate, what it
# started, the bystander and the pipe reader.
finish_seeded_run() {
    if process_alive "$seeded_gate"; then
        kill_descendants "$seeded_gate"
        kill "$seeded_gate" 2>/dev/null
    fi
    kill "$seeded_listener" "$seeded_bystander" "$seeded_reader" 2>/dev/null
    wait "$seeded_step" "$seeded_bystander" "$seeded_reader" 2>/dev/null
}

seeded_state() {
    seeded_listener_alive=0
    process_alive "$seeded_listener" && seeded_listener_alive=1
    seeded_bystander_alive=0
    process_alive "$seeded_bystander" && seeded_bystander_alive=1
    seeded_claim_left=0
    [[ -d "$seeded_dir/locks/device-seeded" ]] && seeded_claim_left=1
    seeded_fixture_left=0
    ls -d "$seeded_dir"/fixture.* > /dev/null 2>&1 && seeded_fixture_left=1
    seeded_exit_status=$(cat "$seeded_dir/diagnostics/fixture/exit-status.txt" \
        2>/dev/null || echo none)
}

# The runner's sequence: SIGINT to the step shell alone, then SIGTERM, then it
# closes the pipe it read the output from. A second between them stands in for
# its 7.5 s.
cancel_seeded_step() {
    seeded_step_after_sigint=0
    seeded_gate_after_sigint=0
    kill -INT "$seeded_step"
    sleep 1
    process_alive "$seeded_step" && seeded_step_after_sigint=1
    process_alive "$seeded_gate" && seeded_gate_after_sigint=1
    kill -TERM "$seeded_step"
    wait "$seeded_step" 2>/dev/null
    kill "$seeded_reader" 2>/dev/null
    wait "$seeded_reader" 2>/dev/null
}

# Without the watchdog (the replay is faithful): the step survives SIGINT, the
# gate never hears about the cancel, and after the step is gone the gate is
# still running with its claim and listener.
start_seeded_run "" real 60
cancel_seeded_step
seeded_gone=$(seconds_until_gone "$seeded_gate" 4)
seeded_state
reason=""
if [[ "$seeded_step_after_sigint" != 1 || "$seeded_gate_after_sigint" != 1 ]]; then
    reason="SIGINT to the step shell reached the gate or ended the step; the replay does not match the runner"
elif [[ "$seeded_gone" != -1 || "$seeded_claim_left" != 1 \
    || "$seeded_listener_alive" != 1 ]]; then
    reason="the gate ended on its own (gone after $seeded_gone s, claim left $seeded_claim_left, listener alive $seeded_listener_alive)"
fi
finish_seeded_run
record_case "without the watchdog a cancelled step leaves the gate running with its claim" \
    "$reason" "$seeded_gone"

# With it: the gate cleans up after itself within 30 s of the cancel.
start_seeded_run true real 60
cancel_seeded_step
seeded_gone=$(seconds_until_gone "$seeded_gate" 30)
seeded_state
reason=""
if [[ "$seeded_gone" == -1 ]]; then
    reason="the gate was still running 30 s after the step was cancelled"
elif [[ "$seeded_claim_left" != 0 ]]; then
    reason="the Simulator claim was left behind"
elif [[ "$seeded_listener_alive" != 0 ]]; then
    reason="the background listener outlived the gate"
elif [[ "$seeded_fixture_left" != 0 ]]; then
    reason="the fixture directory was left behind"
elif [[ "$seeded_exit_status" != 143 ]]; then
    reason="the cancelled run recorded exit status $seeded_exit_status, expected 143"
fi
bystander_reason=""
[[ "$seeded_bystander_alive" == 1 ]] \
    || bystander_reason="the cleanup killed a process the gate never started"
finish_seeded_run
record_case "a cancelled step ends the gate within 30 s and frees its claim, listener and directory" \
    "$reason" "$seeded_gone"
record_case "a cancelled step's cleanup leaves processes the gate did not start alone" \
    "$bystander_reason" "$seeded_gone"

# A cleanup that never finishes must not hold the claim forever.
start_seeded_run true stuck 3
cancel_seeded_step
seeded_gone=$(seconds_until_gone "$seeded_gate" 20)
seeded_state
reason=""
if [[ "$seeded_gone" == -1 ]]; then
    reason="a cleanup stuck past the 3 s deadline was still running 20 s later"
elif [[ "$seeded_listener_alive" != 0 ]]; then
    reason="the stuck run's listener outlived it"
fi
finish_seeded_run
record_case "a cancelled gate whose cleanup never finishes is killed after the deadline" \
    "$reason" "$seeded_gone"

# A step cancelled before the watchdog starts leaves a gate whose parent is
# already gone by then: it must still see that the parent changed.
start_seeded_run true late 60
cancel_seeded_step
seeded_gone=$(seconds_until_gone "$seeded_gate" 30)
seeded_listener=$(cat "$seeded_dir/listener.pid" 2>/dev/null)
seeded_state
reason=""
if [[ "$seeded_gone" == -1 ]]; then
    reason="a gate whose step was cancelled before its watchdog started was still running 30 s later"
elif [[ "$seeded_claim_left" != 0 || "$seeded_listener_alive" != 0 ]]; then
    reason="the claim or the listener outlived it (claim left $seeded_claim_left, listener alive $seeded_listener_alive)"
fi
finish_seeded_run
record_case "a gate whose step was cancelled before its watchdog started still ends itself" \
    "$reason" "$seeded_gone"

# A signal that arrives while cleanup runs (the runner sends SIGINT and then
# SIGTERM) must not stop it halfway: that strands the claim.
start_seeded_run "" slow 60
sleep 2
kill -TERM "$seeded_gate" 2>/dev/null
seeded_gone=$(seconds_until_gone "$seeded_gate" 10)
seeded_state
reason=""
if [[ "$seeded_gone" == -1 ]]; then
    reason="the cleanup was still running 10 s after it began"
elif [[ "$seeded_claim_left" != 0 ]]; then
    reason="a SIGTERM during cleanup stopped it before it released the claim"
fi
finish_seeded_run
record_case "a SIGTERM during cleanup does not stop it before the claim is released" \
    "$reason" "$seeded_gone"

echo
# The point of the count: a harness that silently stops running cases would
# otherwise report the same "0 failed" as one that runs them all and passes.
# It counts quantity, not identity -- see the note at the foot of this file.
if (( ran != expected_cases )); then
    printf 'FATAL: ran %s cases, expected %s\n' "$ran" "$expected_cases" >&2
    exit 2
fi

# Two cheap identity checks the count cannot make. Neither closes the gap fully.
#
# Duplicated labels: two entries with the same name keep the count right while
# testing one thing twice and something else not at all.
duplicate_label=$(printf '%s\n' "${case_labels[@]}" | LC_ALL=C sort \
    | LC_ALL=C uniq -d | head -n 1)
[[ -z "$duplicate_label" ]] || die "two cases share the label: $duplicate_label"

# A tenth full-lane assertion added to the gate with no case added here. The
# count would still read 33, because it never knew there should be 34.
if (( gate_full_lane_assertions != ${#full_lane_behaviors[@]} )); then
    printf 'FATAL: the gate makes %s full-lane assertions, this harness knows %s\n' \
        "$gate_full_lane_assertions" "${#full_lane_behaviors[@]}" >&2
    exit 2
fi

printf '%s of %s gate-guard cases behaved as expected, %s did not.\n' \
    "$passed" "$ran" "$failed"
(( failed == 0 ))

# Known gap, stated rather than papered over: the checks above catch a case
# being duplicated and a gate assertion going unmirrored, but not a case whose
# body is replaced by something vacuous. Closing that needs each case to prove
# it exercised its subject, which is a bigger machine than this file deserves.
# The mutation runs in the commit message are what stand in for it today.
