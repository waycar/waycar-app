#!/usr/bin/env bash
#
# Smoke-test a release build the way a reviewer's device gets it, before it
# goes to the App Store (`make review-smoke`; `make publish` runs it in
# preflight). See docs/guides/releasing.md.
#
# 1. Builds the Release configuration for the simulator with no admin panel,
#    as `make publish` archives it, plus the walkthrough UI test
#    (Tests/WaycarScreenshots/ReviewSmokeTests.swift).
# 2. Builds the last App Store-approved release, REVIEW_SMOKE_PREVIOUS (a tag;
#    make sets it), once per tag: the app is cached in
#    ~/Library/Caches/waycar-review-smoke/<tag>/. The tag's tree comes from
#    `git archive` in REVIEW_SMOKE_REPO (default: this checkout), so a tag
#    that only another clone has works too. Empty installs fresh only.
# 3. After a warm-up UI test on both, on each reviewer-shaped simulator:
#    installs and launches the previous release, installs this build over it
#    (an update, so its data stays), then runs the walkthrough through
#    scripts/run-app-simulator-tests.py while recording the screen to
#    build/review-smoke/<device>.mp4.
# 4. Prints a summary and exits non-zero on any failure or crash report.
#
# The two simulators belong to this script (AGENTS.md › Simulators): created
# when missing, leased in one sim-slot call, then released and deleted when it
# ends, whatever happens. It never installs a runtime and never touches the
# shared set or Waycar CI. bash 3.2 (macOS's own) runs it.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

die() { printf 'review-smoke: %s\n' "$*" >&2; exit 1; }
step() { printf '==> %s\n' "$*"; }

[ -n "${REVIEW_SMOKE_PREVIOUS+set}" ] || die "set REVIEW_SMOKE_PREVIOUS to the last approved tag (make review-smoke does)"
previous=$REVIEW_SMOKE_PREVIOUS
previous_repo=${REVIEW_SMOKE_REPO:-$repo_root}

app_id=com.otreva.waycar
out=build/review-smoke
derived=$out/DerivedData
products=$derived/Build/Products
new_app=$products/Release-iphonesimulator/Waycar.app
cache=$HOME/Library/Caches/waycar-review-smoke

# One device each, beside the shared set the regular tests use: an iPhone 17
# Pro Max on iOS 27.2, and an iPad Air (5th generation) on an older iPadOS,
# 26.4.
iphone_name="Waycar Review iPhone"
iphone_type=com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max
iphone_runtime=com.apple.CoreSimulator.SimRuntime.iOS-27-2
ipad_name="Waycar Review iPad Air"
ipad_type=com.apple.CoreSimulator.SimDeviceType.iPad-Air-5th-generation
ipad_runtime=com.apple.CoreSimulator.SimRuntime.iOS-26-4

for tool in git xcodebuild xcrun python3 plutil; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is not installed"
done

started=$(date +%s)
scratch=""
recorder=""
acquired=""
crash_status=""
iphone=""
ipad=""
iphone_owned=""
ipad_owned=""
iphone_result="not run"
ipad_result="not run"
iphone_install=""
ipad_install=""

# Size of a file for the summary, or "missing".
size_of() {
    if [ -s "$1" ]; then
        du -h "$1" | awk '{ print $1 }'
    else
        echo "missing"
    fi
}

runtime_name() {
    xcrun simctl list runtimes --json | python3 -c '
import json, sys
for runtime in json.load(sys.stdin)["runtimes"]:
    if runtime["identifier"] == sys.argv[1]:
        print(runtime["name"], "(" + runtime["buildversion"] + ")")
' "$1"
}

stop_recording() {
    if [ -n "$recorder" ]; then
        kill -INT "$recorder" 2>/dev/null || true
        wait "$recorder" 2>/dev/null || true
        recorder=""
    fi
}

remove_scratch() {
    if [ -n "$scratch" ]; then
        rm -rf "$scratch"
        scratch=""
    fi
}

summary_row() { # device name runtime install result
    printf '  %s, %s: %s: %s\n' "$2" "$(runtime_name "$3")" "${4:-not installed}" "$5"
    printf '    video: %s (%s)\n' "$out/$1.mp4" "$(size_of "$out/$1.mp4")"
}

finish() {
    local status=$?
    trap - EXIT INT TERM
    stop_recording
    remove_scratch
    if [ -n "$acquired" ] && [ -z "$crash_status" ]; then
        crash_status=0
        python3 scripts/check-crash-reports.py --since "$started" --udid "$iphone" --udid "$ipad" \
            | tee "$out/crash-reports.txt" || crash_status=$?
    fi
    # Release before deleting: the queue then frees the slots at once.
    local udids=""
    [ -z "$iphone_owned" ] || udids="$iphone"
    [ -z "$ipad_owned" ] || udids="$udids $ipad"
    if [ -n "$udids" ]; then
        step "Releasing and deleting the review simulators"
        # shellcheck disable=SC2086 # One word per UDID.
        scripts/sim-slot.py release $udids || true
        for udid in $udids; do
            xcrun simctl shutdown "$udid" 2>/dev/null || true
            xcrun simctl delete "$udid" || status=1
        done
    fi

    if [ "$iphone_result" != PASS ] || [ "$ipad_result" != PASS ] || [ "$crash_status" != 0 ]; then
        [ "$status" != 0 ] || status=1
    fi
    local verdict=PASS elapsed=$(($(date +%s) - started))
    [ "$status" = 0 ] || verdict=FAIL
    printf '\nReview smoke: %s in %dm %02ds\n' "$verdict" $((elapsed / 60)) $((elapsed % 60))
    summary_row iphone "$iphone_name" "$iphone_runtime" "$iphone_install" "$iphone_result"
    summary_row ipad "$ipad_name" "$ipad_runtime" "$ipad_install" "$ipad_result"
    case "$crash_status" in
        0) echo "  Crash reports: none" ;;
        1) echo "  Crash reports: FOUND, see above and $out/crash-reports.txt" ;;
        "") echo "  Crash reports: not checked (no simulator ran)" ;;
        *) echo "  Crash reports: the check failed ($crash_status)" ;;
    esac
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$out"
rm -rf "$out"/*.mp4 "$out"/*.xcresult "$out"/*.log "$out/crash-reports.txt"

# --- Builds (before any simulator is leased) ---------------------------------

step "Building the Release app and the walkthrough test (no admin panel)"
# A stale run file from another SDK would be picked up instead of this one.
rm -f "$products"/*.xctestrun
# ARCHS=arm64: the Mac's simulators run arm64, and a Release build would
# compile every simulator architecture. WAYCAR_ADMIN_CONDITION= is what
# `make archive ADMIN_BUILD=` passes.
xcodebuild build-for-testing -project Waycar.xcodeproj -scheme WaycarScreenshots \
    -configuration Release -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath "$derived" ARCHS=arm64 WAYCAR_ADMIN_CONDITION= \
    >"$out/build.log" 2>&1 || { tail -40 "$out/build.log" >&2; die "the Release build failed; see $out/build.log"; }
xctestrun=$(find "$products" -maxdepth 1 -name 'WaycarScreenshots_*.xctestrun' | head -1)
[ -n "$xctestrun" ] && [ -d "$new_app" ] || die "the Release build left no test run file or app in $products"
new_version="$(plutil -extract CFBundleShortVersionString raw "$new_app/Info.plist") ($(plutil -extract CFBundleVersion raw "$new_app/Info.plist"))"

old_app=""
old_version=""
if [ -n "$previous" ]; then
    old_app=$cache/$previous/Waycar.app
    if [ -d "$old_app" ]; then
        step "Using the cached $previous build ($old_app)"
    else
        git -C "$previous_repo" rev-parse -q --verify "refs/tags/$previous^{commit}" >/dev/null \
            || die "no tag $previous in $previous_repo (git fetch --tags, or point REVIEW_SMOKE_REPO at a clone that has it), or set REVIEW_SMOKE_PREVIOUS"
        step "Building $previous, the last approved release, once (cached afterwards)"
        scratch=$(mktemp -d "${TMPDIR:-/tmp}/waycar-review-smoke.XXXXXX")
        mkdir "$scratch/src"
        git -C "$previous_repo" archive --format=tar "$previous" | tar -x -C "$scratch/src"
        # The tag's committed project is what its release archived.
        xcodebuild build -project "$scratch/src/Waycar.xcodeproj" -scheme Waycar \
            -configuration Release -destination 'generic/platform=iOS Simulator' \
            -derivedDataPath "$scratch/DerivedData" ARCHS=arm64 WAYCAR_ADMIN_CONDITION= \
            >"$out/previous-build.log" 2>&1 \
            || { tail -40 "$out/previous-build.log" >&2; die "building $previous failed; see $out/previous-build.log"; }
        mkdir -p "$cache/$previous"
        rm -rf "$old_app.partial"
        cp -R "$scratch/DerivedData/Build/Products/Release-iphonesimulator/Waycar.app" "$old_app.partial"
        mv "$old_app.partial" "$old_app"
        remove_scratch
    fi
    old_version="$(plutil -extract CFBundleShortVersionString raw "$old_app/Info.plist") ($(plutil -extract CFBundleVersion raw "$old_app/Info.plist"))"
fi

# --- Simulators --------------------------------------------------------------

# The UDID of an available simulator with this name, type and runtime; empty
# when there is none. Fails when the runtime is not installed.
find_simulator() { # name type runtime
    xcrun simctl list --json devices runtimes | python3 -c '
import json, sys
name, kind, runtime = sys.argv[1:]
listing = json.load(sys.stdin)
if not any(r["identifier"] == runtime and r["isAvailable"] for r in listing["runtimes"]):
    sys.exit(f"review-smoke: runtime {runtime} is not installed; install it by hand (this never does)")
for device in listing["devices"].get(runtime, []):
    if device["name"] == name and device["deviceTypeIdentifier"] == kind and device["isAvailable"]:
        print(device["udid"])
        break
' "$@"
}

iphone=$(find_simulator "$iphone_name" "$iphone_type" "$iphone_runtime")
if [ -z "$iphone" ]; then
    iphone=$(xcrun simctl create "$iphone_name" "$iphone_type" "$iphone_runtime")
    iphone_owned=1
    step "Created $iphone_name ($iphone)"
fi
ipad=$(find_simulator "$ipad_name" "$ipad_type" "$ipad_runtime")
if [ -z "$ipad" ]; then
    ipad=$(xcrun simctl create "$ipad_name" "$ipad_type" "$ipad_runtime")
    ipad_owned=1
    step "Created $ipad_name ($ipad)"
fi

step "Leasing both review simulators (one sim-slot call; waits in the queue)"
granted=$(scripts/sim-slot.py acquire "$iphone" "$ipad")
[ "$granted" = "$(printf '%s\n%s' "$iphone" "$ipad")" ] || die "sim-slot granted '$granted', not $iphone and $ipad"
acquired=1
iphone_owned=1
ipad_owned=1

# --- Upgrade and walkthrough, one simulator at a time ------------------------

# The app's own files in its data container: what an update must keep. The
# container moves to a new path on every install, so its contents are
# compared: a SHA-256 per file in Documents and Application Support, and the
# names alone in Preferences (cfprefsd may still flush a plist after the
# previous release quits).
# One line per file, sorted whole (LC_ALL=C) for comm; fails when a file
# cannot be hashed.
app_data() { # udid
    local dir file digest
    dir=$(xcrun simctl get_app_container "$1" "$app_id" data)
    # A folder the app never wrote to is simply absent.
    {
        while IFS= read -r file; do
            digest=$(shasum -a 256 <"$dir/$file") || { echo "review-smoke: cannot hash $file" >&2; return 1; }
            printf '%s  %s\n' "${digest%% *}" "$file"
        done < <(cd "$dir" && { find Documents "Library/Application Support" -type f 2>/dev/null || true; })
        (cd "$dir" && { find Library/Preferences -type f 2>/dev/null || true; })
    } | LC_ALL=C sort
}

# A file the previous release's container gets before the update, which must
# still hold the same token after the walkthrough: the update, xcodebuild's
# own reinstall and the new build's launches all keep the app's data.
marker="Library/Application Support/waycar-review-smoke-marker"
write_marker() { # udid token
    local dir
    dir=$(xcrun simctl get_app_container "$1" "$app_id" data)
    mkdir -p "$dir/Library/Application Support"
    printf '%s\n' "$2" >"$dir/$marker"
}
read_marker() { # udid
    local dir
    dir=$(xcrun simctl get_app_container "$1" "$app_id" data) || return 0
    cat "$dir/$marker" 2>/dev/null || true
}

# Sets <device>_install and <device>_result for the summary. A failing check
# is recorded and the walkthrough still runs; a failing command (an install)
# ends the script, leaving "did not finish".
smoke() { # device udid
    local device=$1 udid=$2 result=PASS pid before after token=""
    local video=$out/$device.mp4
    printf -v "${device}_result" '%s' "FAIL (did not finish)"
    if [ -n "$old_app" ]; then
        printf -v "${device}_install" '%s' "$previous $old_version -> $new_version"
        step "$device: installing and launching $previous $old_version"
        xcrun simctl uninstall "$udid" "$app_id" 2>/dev/null || true
        xcrun simctl install "$udid" "$old_app"
        pid=$(xcrun simctl launch "$udid" "$app_id" | awk '{ print $NF }')
        sleep 10
        kill -0 "$pid" 2>/dev/null || result="FAIL ($previous quit within 10 s of launch)"
        xcrun simctl terminate "$udid" "$app_id" 2>/dev/null || true
        token="$device-$(date +%s)-$$-$RANDOM"
        write_marker "$udid" "$token"
        before=$(app_data "$udid")
    else
        printf -v "${device}_install" '%s' "fresh install of $new_version"
    fi

    step "$device: installing $new_version as an update"
    xcrun simctl install "$udid" "$new_app"
    if [ -n "$old_app" ]; then
        after=$(app_data "$udid")
        # Nothing has launched since the update: every file is unchanged.
        if [ -z "$before" ] || [ -n "$(LC_ALL=C comm -23 <(echo "$before") <(echo "$after"))" ]; then
            [ "$result" != PASS ] || result="FAIL (the update did not keep the app's data)"
        fi
    fi

    step "$device: walkthrough, recording to $video"
    xcrun simctl io "$udid" recordVideo --codec=h264 --force "$video" >"$out/$device-record.log" 2>&1 &
    recorder=$!
    local tries=0
    until grep -q "Recording started" "$out/$device-record.log" || [ "$tries" -ge 20 ]; do
        sleep 0.5
        tries=$((tries + 1))
    done
    python3 scripts/run-app-simulator-tests.py test-without-building -xctestrun "$xctestrun" \
        -destination "platform=iOS Simulator,id=$udid" \
        -only-testing:WaycarScreenshots/ReviewSmokeTests/testReviewerWalkthrough \
        -resultBundlePath "$out/$device.xcresult" 2>&1 | tee "$out/$device-test.log" \
        || { [ "$result" != PASS ] || result="FAIL (walkthrough, see $out/$device-test.log)"; }
    stop_recording
    if [ -n "$token" ] && [ "$(read_marker "$udid")" != "$token" ]; then
        [ "$result" != PASS ] || result="FAIL (the app's data was gone after the walkthrough)"
    fi
    [ -s "$video" ] || { [ "$result" != PASS ] || result="FAIL (no video)"; }
    printf -v "${device}_result" '%s' "$result"
}

# The first UI test session on a freshly booted simulator fails at its first
# query (kAXError -25218); this one absorbs that, without launching the app.
step "Warming up UI testing on both simulators"
python3 scripts/run-app-simulator-tests.py test-without-building -xctestrun "$xctestrun" \
    -destination "platform=iOS Simulator,id=$iphone" -destination "platform=iOS Simulator,id=$ipad" \
    -only-testing:WaycarScreenshots/ReviewSmokeTests/testAccessibilityWarmUp \
    -resultBundlePath "$out/warm-up.xcresult" >"$out/warm-up.log" 2>&1 || echo "    (failed, as it usually does on a fresh simulator; see $out/warm-up.log)"

smoke iphone "$iphone"
smoke ipad "$ipad"
