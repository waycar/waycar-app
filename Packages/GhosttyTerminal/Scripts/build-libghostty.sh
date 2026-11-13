#!/bin/bash
# Builds the GhosttyKit.xcframework.zip for Package.swift's `libghostty`
# binary target without GNU gettext (libintl, LGPL). See ADR 0025.
#
# Pinned inputs: libghostty-spm's build scripts and Ghostty patch set at
# release 1.6.20260909, the Ghostty commit that release ships (its
# Ghostty.ref), and Zig 0.16.0. Waycar adds -Di18n=false and one patch,
# 0100-gate-libintl-on-i18n.patch. The Apple SDK is whatever Xcode is
# selected; the script prints it, and PROVENANCE.md records the one used.
#
# Usage: Scripts/build-libghostty.sh [work-dir]
#   work-dir defaults to .build/libghostty-build in this package (git-ignored).
#   Results: <work-dir>/libghostty-spm/build/GhosttyKit.xcframework.zip, its
#   SwiftPM checksum on stdout, and <work-dir>/LICENSES/ with the third-party
#   notices to publish next to the zip. A full build takes about 30 minutes.
#   SKIP_BUILD=1 reuses the build already in work-dir (checkouts must be at
#   the pinned commits) and only re-runs the checks and the license step.

set -euo pipefail
shopt -s nullglob

SPM_REPO=https://github.com/Lakr233/libghostty-spm
SPM_COMMIT=7e45d27160f9b34aca9ca5c9820e9207482f9f04 # tag 1.6.20260909
GHOSTTY_REPO=https://github.com/ghostty-org/ghostty
GHOSTTY_COMMIT=82938b633ba646db38591d969c3c526332bd7e65 # Ghostty.ref at SPM_COMMIT
ZIG_VERSION=0.16.0
PLATFORMS=macos,ios,maccatalyst,visionos
EXPECTED_SLICES=6

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PACKAGE_DIR=$(dirname "$SCRIPT_DIR")
WORK_DIR=${1:-"$PACKAGE_DIR/.build/libghostty-build"}
mkdir -p "$WORK_DIR"
WORK_DIR=$(cd "$WORK_DIR" && pwd)
SPM_DIR="$WORK_DIR/libghostty-spm"
GHOSTTY_DIR="$WORK_DIR/ghostty"
XCFRAMEWORK="$SPM_DIR/BinaryTarget/GhosttyKit.xcframework"
ZIP="$SPM_DIR/build/GhosttyKit.xcframework.zip"

zig_version=$(zig version)
if [ "$zig_version" != "$ZIG_VERSION" ]; then
    echo "[!] Zig $ZIG_VERSION required, found $zig_version" >&2
    exit 1
fi
xcode_version=$(xcodebuild -version | tr '\n' ' ')
ios_sdk=$(xcrun --sdk iphoneos --show-sdk-version)
echo "[*] zig $zig_version; $xcode_version; iOS SDK $ios_sdk"

checkout() { # repo dir commit
    if [ ! -d "$2/.git" ]; then
        git clone --quiet "$1" "$2"
    fi
    git -C "$2" fetch --quiet --tags --force origin
    git -C "$2" checkout --quiet --force "$3"
    git -C "$2" clean --quiet -fdx
}

require_head() { # dir commit
    local head
    head=$(git -C "$1" rev-parse HEAD)
    if [ "$head" != "$2" ]; then
        echo "[!] $1 is at $head, expected $2" >&2
        exit 1
    fi
}

if [ "${SKIP_BUILD:-0}" = 1 ]; then
    require_head "$SPM_DIR" "$SPM_COMMIT"
    require_head "$GHOSTTY_DIR" "$GHOSTTY_COMMIT"
else
    checkout "$SPM_REPO" "$SPM_DIR" "$SPM_COMMIT"
    checkout "$GHOSTTY_REPO" "$GHOSTTY_DIR" "$GHOSTTY_COMMIT"

    # Upstream's apply-patches.sh applies Patches/ghostty in name order, so
    # ours runs last, on top of the release's own set.
    cp "$SCRIPT_DIR/0100-gate-libintl-on-i18n.patch" "$SPM_DIR/Patches/ghostty/"

    (
        cd "$SPM_DIR"
        ZIG_BUILD_EXTRA_ARGS='-Di18n=false' ./Script/build.sh \
            --source "$GHOSTTY_DIR" \
            --ref "$GHOSTTY_COMMIT" \
            --platforms "$PLATFORMS" \
            --skip-tests
    )
fi

# Fail unless every slice is present and has no gettext objects or symbols
# (defined or referenced). Fat archives are checked one architecture at a
# time, since ar(1) cannot read them. Each tool's output is captured first so
# a tool failure aborts instead of counting as zero.
fail() {
    echo "[!] $1" >&2
    rm -f "$ZIP"
    exit 1
}
archives=("$XCFRAMEWORK"/*/libghostty.a)
if [ ${#archives[@]} -ne "$EXPECTED_SLICES" ]; then
    fail "expected $EXPECTED_SLICES slices in $XCFRAMEWORK, found ${#archives[@]}"
fi
THIN_DIR=$(mktemp -d)
trap 'rm -rf "$THIN_DIR"' EXIT
for archive in "${archives[@]}"; do
    slice=$(basename "$(dirname "$archive")")
    archs=$(lipo -archs "$archive") || fail "lipo failed on $archive"
    [ -n "$archs" ] || fail "no architectures in $archive"
    for arch in $archs; do
        thin="$THIN_DIR/$slice-$arch.a"
        if [ "$(echo "$archs" | wc -w)" -gt 1 ]; then
            lipo "$archive" -thin "$arch" -output "$thin" || fail "lipo -thin $arch failed on $archive"
        else
            cp "$archive" "$thin"
        fi
        member_list=$(ar t "$thin") || fail "ar failed on $slice $arch"
        symbol_list=$(nm "$thin" 2>/dev/null) || fail "nm failed on $slice $arch"
        members=$(grep -Eic 'intl|gettext|textdom|localename|l10nflist|loadmsgcat' <<<"$member_list" || true)
        symbols=$(grep -Eic 'libintl|gettext|_nl_' <<<"$symbol_list" || true)
        echo "[*] $slice $arch: $(wc -l <<<"$member_list" | xargs) members, gettext members $members, gettext symbols $symbols"
        if [ "$members" != 0 ] || [ "$symbols" != 0 ]; then
            fail "libintl is still in $slice ($arch)"
        fi
    done
done

"$SCRIPT_DIR/collect-libghostty-licenses.sh" "$GHOSTTY_DIR" "$SPM_DIR" "$WORK_DIR/LICENSES"

checksum=$(cd "$PACKAGE_DIR" && swift package compute-checksum "$ZIP")
echo "[*] zip: $ZIP"
echo "[*] checksum: $checksum"
