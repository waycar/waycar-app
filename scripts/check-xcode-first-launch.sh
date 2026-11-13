#!/bin/bash
#
# Fail fast while Xcode's first-launch setup is pending, after healing it once
# when passwordless sudo allows.
#
# Xcode finishes an install or update with first-launch work only an admin can
# complete (`sudo xcodebuild -runFirstLaunch`). Until then Xcode's `simctl` shim
# runs `xcodebuild -runFirstLaunch` on every call, and the system refuses it
# without authorization, so a burst of calls hangs instead of failing. An
# unattended Xcode update on the shared Mac left one run stuck for 40 minutes
# (WAY-505). macOS updates reset it too (27.2 and 27.2.1 each stopped every iOS
# CI job until someone ran the command by hand), so a pending status gets one
# `sudo -n xcodebuild -runFirstLaunch` and one re-check. `-n` never prompts: a
# runner without passwordless sudo fails at once, as before, with the reason.
#
# The watchdog bounds every step: this runs before anything else, so a hang
# here would be the same stall it exists to prevent.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
check_timeout_seconds=30
# The run installs a few packages: about 20 s on the CI Mac after macOS 27.2.
run_timeout_seconds=300
# What `xcodebuild -checkFirstLaunchStatus` exits while the setup is pending.
pending_status=69

work="$(mktemp -d /tmp/waycar-first-launch.XXXXXX)"
trap 'rm -rf "$work"' EXIT

with_timeout() { # <seconds> <label> <command...>
    local seconds=$1 label=$2
    shift 2
    "$repo_root/scripts/run-with-timeout.py" \
        --timeout-seconds "$seconds" \
        --label "$label" \
        --diagnostics-dir "$work/diagnostics" \
        -- "$@"
}

first_launch_status() {
    local status=0
    with_timeout "$check_timeout_seconds" "Xcode first-launch status" \
        xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1 || status=$?
    echo "$status"
}

fail() { # <check status> [reason]
    echo "Xcode first-launch setup is pending or its status check timed out" \
        "(xcodebuild -checkFirstLaunchStatus exited $1)." \
        "An admin must run: sudo xcodebuild -runFirstLaunch" >&2
    if [[ -n "${2:-}" ]]; then
        echo "Self-heal failed: $2" >&2
    fi
    exit 1
}

status="$(first_launch_status)"
[[ "$status" -ne 0 ]] || exit 0
[[ "$status" -eq "$pending_status" ]] || fail "$status"

# The child writes its own log so the watchdog's own lines stay out of the
# reason; the watchdog's exit status (124 on timeout) says the rest.
run_status=0
# shellcheck disable=SC2016 # expanded by the child shell
with_timeout "$run_timeout_seconds" "Xcode first-launch setup" \
    /bin/sh -c 'exec "$@" >"$0" 2>&1' "$work/run.log" \
    sudo -n xcodebuild -runFirstLaunch >/dev/null 2>&1 || run_status=$?
case "$run_status" in
    0) ;;
    124) fail "$status" "sudo -n xcodebuild -runFirstLaunch timed out after ${run_timeout_seconds}s" ;;
    *)
        last_line="$(grep -v '^[[:space:]]*$' "$work/run.log" 2>/dev/null | tail -n 1 || true)"
        fail "$status" "sudo -n xcodebuild -runFirstLaunch exited $run_status${last_line:+: $last_line}"
        ;;
esac

status="$(first_launch_status)"
[[ "$status" -eq 0 ]] \
    || fail "$status" "still pending after sudo -n xcodebuild -runFirstLaunch succeeded"

message="Xcode first-launch setup was pending; sudo -n xcodebuild -runFirstLaunch completed it."
echo "$message"
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    echo "::notice title=Xcode first-launch self-healed::$message"
fi
