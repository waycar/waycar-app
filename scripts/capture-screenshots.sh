#!/usr/bin/env bash
# Regenerates docs/images/screenshots/{iphone,ipad}/*.png from the DEBUG
# simulator demo fixture (--demo-screenshots) via the WaycarScreenshots
# UI-test target. Both simulators run in one xcodebuild invocation, through the
# app test runner so the accessibility tree the UI tests query is enabled.
#
# Usage: scripts/capture-screenshots.sh "<iPhone simulator name>" "<iPad simulator name>"
set -euo pipefail

iphone_name=${1:?iPhone simulator name required}
ipad_name=${2:?iPad simulator name required}
repo_root=$(cd "$(dirname "$0")/.." && pwd)
output_dir="$repo_root/docs/images/screenshots"
derived="$repo_root/build/DerivedData"

# The waycar.dev hero at the end needs these; fail now, not after the whole
# UI-test run.
for tool in ffmpeg ffprobe img2webp; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: $tool not found; the waycar.dev hero needs it. Install with: brew install ffmpeg webp" >&2
        exit 1
    fi
done

# Both at once through the machine-wide queue (AGENTS.md, Simulators): any
# free simulator of each model's pool, printed in request order.
granted=$("$repo_root/scripts/sim-slot.py" acquire "$iphone_name" "$ipad_name")
{ read -r iphone && read -r ipad; } <<< "$granted" || {
    echo "sim-slot granted no iPhone and iPad pair ($granted)" >&2
    exit 1
}

# Put each simulator's status bar and appearance back as found. Every step
# tolerates failure so one shut-down simulator cannot skip the rest.
restore() {
    xcrun simctl status_bar "$iphone" clear 2>/dev/null || true
    xcrun simctl status_bar "$ipad" clear 2>/dev/null || true
    case "$iphone_appearance" in light|dark) xcrun simctl ui "$iphone" appearance "$iphone_appearance" || true ;; esac
    case "$ipad_appearance" in light|dark) xcrun simctl ui "$ipad" appearance "$ipad_appearance" || true ;; esac
}

iphone_appearance=$(xcrun simctl ui "$iphone" appearance)
ipad_appearance=$(xcrun simctl ui "$ipad" appearance)
trap restore EXIT
for udid in "$iphone" "$ipad"; do
    xcrun simctl ui "$udid" appearance dark
    xcrun simctl status_bar "$udid" override --time 9:41 \
        --dataNetwork wifi --wifiMode active --wifiBars 3 \
        --cellularMode active --cellularBars 4 \
        --batteryState charged --batteryLevel 100
done

rm -rf "$output_dir/iphone" "$output_dir/ipad"
mkdir -p "$derived"
test_status=0
WAYCAR_SCREENSHOT_DIR="$output_dir" python3 "$repo_root/scripts/run-app-simulator-tests.py" test \
    -project "$repo_root/Waycar.xcodeproj" -scheme WaycarScreenshots \
    -only-testing:WaycarScreenshots/ReadmeScreenshots \
    -destination "platform=iOS Simulator,id=$iphone" \
    -destination "platform=iOS Simulator,id=$ipad" \
    -derivedDataPath "$derived" \
    -clonedSourcePackagesDirPath "$repo_root/.ci/source-packages" \
    2>&1 | tee "$derived/screenshots.log" || test_status=$?
# Non-fatal actor-isolation gate (AGENTS.md, Conventions): this build shares
# DerivedData with `make test-app`, so touch offenders for it to report.
"$repo_root/scripts/check-actor-isolated-calls.sh" --touch "$derived/screenshots.log" || {
    [[ $? -ne 1 ]] || echo "actor-isolation warnings found; touched the files so \`make test-app\` reports them" >&2
}
[[ $test_status == 0 ]] || exit "$test_status"

ls "$output_dir/iphone" "$output_dir/ipad"

# The marketing site (apps/web) ships copies of six screens per device,
# plus the iPhone Closed screen; settings and dictation are left out on
# purpose (the site's hero comes from src/assets/hero/).
web_screens="$repo_root/apps/web/src/assets/screens"
for device in iphone ipad; do
    for screen in agent ai-usage chat console hosts new-agent; do
        cp "$output_dir/$device/$screen.png" "$web_screens/$device-$screen.png"
    done
done
cp "$output_dir/iphone/closed.png" "$web_screens/iphone-closed.png"
echo "copied site screenshots to ${web_screens#"$repo_root"/}"

# The waycar.dev hero animation, recorded while the iPhone still has the dark
# appearance and 9:41 status bar above, and the slot is held.
"$repo_root/scripts/record-dictation-hero.sh" "$iphone"
