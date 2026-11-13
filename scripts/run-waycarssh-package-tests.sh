#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
destination=${1:-platform=iOS Simulator,name=iPhone 17 Pro Max}
test_log=$(mktemp -t waycar-ssh-tests.XXXXXX)

cleanup() {
    rm -f "$test_log"
}
trap cleanup EXIT

(
    cd "$repo_root/Packages/WaycarSSH"
    xcodebuild test \
        -scheme WaycarSSH \
        -destination "$destination" \
        -derivedDataPath "$repo_root/build/WaycarSSHDerivedData" \
        -collect-test-diagnostics never
) 2>&1 | tee "$test_log"

total=$(sed -n \
    's/^.*Test run with \([0-9][0-9]*\) tests in .* passed after .*$/\1/p' \
    "$test_log" | tail -n 1)
if [[ -z "$total" ]]; then
    echo "The WaycarSSH package suite printed no passing run summary" >&2
    exit 1
fi

skips=$(grep -c 'Test .* skipped:' "$test_log" || true)
executed=$((total - skips))
if ((executed <= 0)); then
    echo "The WaycarSSH package suite executed no tests ($total registered, $skips skipped)" >&2
    exit 1
fi

echo "WaycarSSH package suite executed $executed of $total tests ($skips skipped)."
