#!/bin/bash
#
# The Waycar CI Simulator wait in scripts/run-ci-ios-tests.sh. Its claim
# functions are extracted verbatim and run against a scratch lock root, with
# `sleep` stubbed to advance the clock instead of waiting. It never touches a
# simulator or the machine's /tmp/waycar-ci-locks, so it runs on any host.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
gate="$repo_root/scripts/run-ci-ios-tests.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/waycar-sim-wait-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

for function in claim_ci_simulator simulator_holder simulator_held_by \
    claim_simulator claim_resource_lock write_lock_owner lock_is_stale \
    acquire_claim_guard release_claim_guard; do
    body=$(awk -v fn="$function" '
        $0 == fn "() {" { inside = 1 }
        inside { print }
        inside && /^}$/ { exit }
    ' "$gate")
    [[ -n "$body" ]] || { echo "Missing shipped function: $function" >&2; exit 1; }
    eval "$body"
done
poll_line=$(grep '^ci_simulator_poll_seconds=' "$gate") \
    || { echo "Missing ci_simulator_poll_seconds in $gate" >&2; exit 1; }
eval "$poll_line"

udid=AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA
holder_label="local run in /Users/ci/elsewhere"
# Consumed by the extracted functions, not here.
# shellcheck disable=SC2034
{
    lock_owner_token=ours
    lock_owner_start="$(ps -o lstart= -p "$$" | sed 's/^ *//; s/ *$//')"
    active_claim_guard=""
    active_resource_lock=""
    device_lock_dir=""
    ci_simulator_name="Waycar CI"
    simulator_candidates=("$udid")
    requested_simulator_udid=""
    simulator_udid=""
}

# Unset, SECONDS is a plain variable: the clock moves only when the stub sleeps.
unset SECONDS
SECONDS=0

# Advances the clock instead of waiting. On nap number $release_after the
# holder lets go, as its cleanup would.
sleep() {
    [[ "$1" =~ ^[0-9]+$ ]] || { command sleep "$1"; return; }
    SECONDS=$((SECONDS + $1))
    sleeps=$((sleeps + 1))
    slept=$((slept + $1))
    echo "$sleeps" > "$case_dir/sleeps"
    echo "$slept" > "$case_dir/slept"
    if [[ "$sleeps" == "$release_after" ]]; then
        rm -rf -- "$lock_root/device-$udid"
    fi
}

failures=0
case_dir=""
case_status=0
lock_root=""
sleeps=0
slept=0
release_after=""

new_case() { # <name>
    case_dir="$work/$1"
    lock_root="$case_dir/locks"
    mkdir -p "$lock_root"
    echo 0 > "$case_dir/sleeps"
}

hold() { # <pid> <start>: another run's claim on the device
    local lock="$lock_root/device-$udid"
    mkdir "$lock"
    printf other > "$lock/token"
    printf '%s' "$1" > "$lock/pid"
    printf '%s' "$2" > "$lock/start"
    printf '%s' "$holder_label" > "$lock/owner"
}

claim() { # <wait seconds> [release after poll n]
    case_status=0
    (
        # shellcheck disable=SC2034
        ci_simulator_wait_seconds=$1
        release_after=${2:-}
        export GITHUB_ACTIONS=true
        unset GITHUB_RUN_ID
        claim_ci_simulator || exit
        echo "$simulator_udid" > "$case_dir/claimed"
    ) > "$case_dir/stdout" 2> "$case_dir/stderr" || case_status=$?
}

expect() { # <description> <condition...>
    local description=$1
    shift
    if ! "$@"; then
        echo "FAIL [$(basename "$case_dir")] $description" >&2
        sed 's/^/  stdout: /' "$case_dir/stdout" >&2
        sed 's/^/  stderr: /' "$case_dir/stderr" >&2
        failures=$((failures + 1))
    fi
}

has() { grep -qF -- "$2" "$case_dir/$1"; }
count() { grep -cF -- "$2" "$case_dir/$1" || true; }
file_is() { [[ "$(cat "$case_dir/$1" 2>/dev/null)" == "$2" ]]; }
token_is() { [[ "$(cat "$lock_root/device-$udid/token" 2>/dev/null)" == "$1" ]]; }

# Held by this test shell, alive throughout, until its fourth poll.
new_case released
hold "$$" "$lock_owner_start"
claim 2700 4
expect "exits 0" [ "$case_status" -eq 0 ]
expect "claims the device" file_is claimed "$udid"
expect "owns its lock" token_is ours
expect "polls until the holder lets go" file_is sleeps 4
expect "reports once a minute" [ "$(count stderr 'Waiting for a Waycar CI Simulator')" -eq 2 ]
expect "names the holder" has stderr \
    "Waiting for a Waycar CI Simulator, 0m of up to 45m: $udid held by pid $$ ($holder_label)"
expect "says how long it waited" has stderr "Waited 1m20s for simulator $udid."
expect "emits a GitHub notice" has stdout \
    "::notice title=Waited for the Waycar CI Simulator::Waited 1m20s for $udid. Waiting began on: $udid held by pid $$ ($holder_label)"

# Held by a run that is gone.
new_case stale
( : ) &
dead_pid=$!
wait "$dead_pid"
hold "$dead_pid" "Thu Jan  1 00:00:00 1970"
claim 2700
expect "exits 0" [ "$case_status" -eq 0 ]
expect "claims the device" file_is claimed "$udid"
expect "owns its lock" token_is ours
expect "names itself as the holder" \
    [ "$(cat "$lock_root/device-$udid/owner")" == "local run in $repo_root" ]
expect "never waits" file_is sleeps 0
expect "reclaims it as before" has stderr \
    "Reclaiming the stale lock on simulator $udid (owner pid $dead_pid is gone)"
expect "emits no notice" [ ! -s "$case_dir/stdout" ]

# Held by this test shell for longer than the bound, which is no multiple of
# the poll: the last nap is shorter and ends on the bound.
new_case bound
hold "$$" "$lock_owner_start"
claim 130
expect "exits 1" [ "$case_status" -eq 1 ]
expect "claims nothing" [ ! -e "$case_dir/claimed" ]
expect "leaves the holder's lock alone" token_is other
expect "polls up to the bound" file_is sleeps 7
expect "never sleeps past the bound" file_is slept 130
expect "reports once a minute" [ "$(count stderr 'Waiting for a Waycar CI Simulator')" -eq 3 ]
expect "says it gave up" has stderr \
    "Gave up after 2m10s (WAYCAR_CI_SIM_WAIT_SECONDS=130)."
expect "keeps today's message" has stderr \
    "Every available Waycar CI Simulator is claimed by a live run."
expect "names the holder" has stderr "  $udid: held by pid $$ ($holder_label)"
expect "emits no notice" [ ! -s "$case_dir/stdout" ]

if [[ "$failures" -ne 0 ]]; then
    echo "$failures expectation(s) failed" >&2
    exit 1
fi
echo "CI simulator wait: 3 cases passed"
