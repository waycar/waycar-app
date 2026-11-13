#!/bin/bash
#
# scripts/check-xcode-first-launch.sh against stub `xcodebuild` and `sudo` on
# PATH: it never touches the real Xcode state or sudo, so it runs on any host.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
check="$repo_root/scripts/check-xcode-first-launch.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/waycar-first-launch-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
# Pending while $STUB_STATE/pending exists. STUB_RUN: heal (clears it), noop
# (succeeds and leaves it), fail.
cat >"$work/bin/xcodebuild" <<'EOF'
#!/bin/sh
echo "xcodebuild $*" >>"$STUB_STATE/calls"
case "$1" in
    -checkFirstLaunchStatus)
        [ -n "${STUB_CHECK_STATUS:-}" ] && exit "$STUB_CHECK_STATUS"
        [ -e "$STUB_STATE/pending" ] && exit 69
        exit 0
        ;;
    -runFirstLaunch)
        case "$STUB_RUN" in
            heal) rm -f "$STUB_STATE/pending" ;;
            fail)
                echo "Install Failed: package refused" >&2
                exit 1
                ;;
        esac
        echo "Install Succeeded"
        ;;
    *) exit 2 ;;
esac
EOF
# STUB_SUDO: ok (runs the command), password (refuses, as `sudo -n` does).
cat >"$work/bin/sudo" <<'EOF'
#!/bin/sh
echo "sudo $*" >>"$STUB_STATE/calls"
[ "$1" = "-n" ] || {
    echo "stub sudo: called without -n" >&2
    exit 99
}
shift
if [ "$STUB_SUDO" = password ]; then
    echo "sudo: a password is required" >&2
    exit 1
fi
exec "$@"
EOF
chmod +x "$work/bin/xcodebuild" "$work/bin/sudo"

failures=0
case_dir=""
case_status=0

# run_case <name> <pending: yes|no> [VAR=value...]
run_case() {
    local name=$1 pending=$2
    shift 2
    case_dir="$work/$name"
    mkdir -p "$case_dir/state"
    if [[ "$pending" == yes ]]; then
        touch "$case_dir/state/pending"
    fi
    : >"$case_dir/state/calls"
    case_status=0
    env PATH="$work/bin:$PATH" STUB_STATE="$case_dir/state" STUB_RUN=heal \
        STUB_SUDO=ok GITHUB_ACTIONS=true "$@" \
        "$check" >"$case_dir/stdout" 2>"$case_dir/stderr" || case_status=$?
}

expect() { # <description> <condition...>
    local description=$1
    shift
    if ! "$@"; then
        echo "FAIL [$(basename "$case_dir")] $description" >&2
        sed 's/^/  stdout: /' "$case_dir/stdout" >&2
        sed 's/^/  stderr: /' "$case_dir/stderr" >&2
        sed 's/^/  calls: /' "$case_dir/state/calls" >&2
        failures=$((failures + 1))
    fi
}

calls() { grep -c -- "$1" "$case_dir/state/calls" || true; }
has() { grep -qF -- "$2" "$case_dir/$1"; }
original_message="Xcode first-launch setup is pending or its status check timed out (xcodebuild -checkFirstLaunchStatus exited 69). An admin must run: sudo xcodebuild -runFirstLaunch"

run_case ready no
expect "exits 0" [ "$case_status" -eq 0 ]
expect "never calls sudo" [ "$(calls '^sudo')" -eq 0 ]
expect "prints nothing" [ ! -s "$case_dir/stdout" ]
expect "warns about nothing" [ ! -s "$case_dir/stderr" ]

run_case heals yes
expect "exits 0" [ "$case_status" -eq 0 ]
expect "runs sudo -n xcodebuild -runFirstLaunch once" \
    [ "$(calls '^sudo -n xcodebuild -runFirstLaunch$')" -eq 1 ]
expect "checks again after the run" [ "$(calls 'checkFirstLaunchStatus')" -eq 2 ]
expect "says it healed" has stdout \
    "Xcode first-launch setup was pending; sudo -n xcodebuild -runFirstLaunch completed it."
expect "emits a GitHub notice" has stdout "::notice title=Xcode first-launch self-healed::"

run_case heals-locally yes GITHUB_ACTIONS=
expect "exits 0" [ "$case_status" -eq 0 ]
expect "emits no GitHub notice outside Actions" [ "$(grep -c '::notice' "$case_dir/stdout" || true)" -eq 0 ]

run_case needs-password yes STUB_SUDO=password
expect "exits 1" [ "$case_status" -eq 1 ]
expect "tries sudo once" [ "$(calls '^sudo')" -eq 1 ]
expect "never runs the setup" [ "$(calls '^xcodebuild -runFirstLaunch$')" -eq 0 ]
expect "keeps the original message" has stderr "$original_message"
expect "gives the reason" has stderr \
    "Self-heal failed: sudo -n xcodebuild -runFirstLaunch exited 1: sudo: a password is required"
expect "prints no success line" [ ! -s "$case_dir/stdout" ]

run_case still-pending yes STUB_RUN=noop
expect "exits 1" [ "$case_status" -eq 1 ]
expect "runs the setup once" [ "$(calls '^xcodebuild -runFirstLaunch$')" -eq 1 ]
expect "checks again after the run" [ "$(calls 'checkFirstLaunchStatus')" -eq 2 ]
expect "keeps the original message" has stderr "$original_message"
expect "gives the reason" has stderr \
    "Self-heal failed: still pending after sudo -n xcodebuild -runFirstLaunch succeeded"

run_case run-fails yes STUB_RUN=fail
expect "exits 1" [ "$case_status" -eq 1 ]
expect "runs the setup once" [ "$(calls '^xcodebuild -runFirstLaunch$')" -eq 1 ]
expect "gives the setup's own error" has stderr \
    "Self-heal failed: sudo -n xcodebuild -runFirstLaunch exited 1: Install Failed: package refused"

run_case other-failure no STUB_CHECK_STATUS=1
expect "exits 1" [ "$case_status" -eq 1 ]
expect "only heals a pending status" [ "$(calls '^sudo')" -eq 0 ]
expect "fails as before" has stderr \
    "(xcodebuild -checkFirstLaunchStatus exited 1). An admin must run: sudo xcodebuild -runFirstLaunch"

if [[ "$failures" -ne 0 ]]; then
    echo "$failures expectation(s) failed" >&2
    exit 1
fi
echo "Xcode first-launch check: 7 cases passed"
