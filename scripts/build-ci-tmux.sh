#!/bin/bash
#
# Builds the pinned tmux releases that scripts/run-ci-ios-tests.sh runs
# TmuxTransportE2ETests against, besides the runner's own Homebrew tmux.
#
#   scripts/build-ci-tmux.sh [version ...]
#
# With no version it builds every pinned release. stdout gets one line per
# release, `<version> <absolute path to its tmux binary>`, and nothing else;
# progress and errors go to stderr.
#
# Hosts run whatever their distribution ships, and tmux's control-mode surface
# changes between releases, so the gate pins one release per behaviour:
#
#   3.2a  Ubuntu 22.04, EL9  the version floor: `attach -f` but no
#                             no-detach-on-destroy, so the reattach path runs
#   3.4   Ubuntu 24.04       command replies come back vis-escaped (cmdq_print)
#   3.5a  Debian 13          the same escaping on the 3.5 command set
#
# Each release builds from its official tarball, checked against the SHA-256
# below (the same digests as the Ubuntu and Debian .orig.tar.gz), into a
# per-machine cache: $WAYCAR_CI_TMUX_CACHE, by default
# ~/Library/Caches/waycar-ci/tmux. An entry is keyed by version and checksum,
# and is reused only while its stamp names that key and build recipe and its
# binary still runs and reports that version; a Homebrew upgrade that breaks a
# linked library makes it rebuild. Every build holds an owned lock on its
# entry, so concurrent gates build a release once and the others wait for it.
#
# A build needs a C compiler and make (Xcode Command Line Tools), yacc or
# bison, pkg-config, and libevent 2, ncurses and utf8proc visible to
# pkg-config (on macOS: brew install pkg-config libevent ncurses utf8proc).
# This script checks for them and installs nothing.

set -euo pipefail

pinned_versions=(3.2a 3.4 3.5a)

pinned_sha256() {
    case "$1" in
        3.2a) echo 551553a4f82beaa8dadc9256800bcc284d7c000081e47aa6ecbb6ff36eacd05f ;;
        3.4) echo 551ab8dea0bf505c0ad6b7bb35ef567cdde0ccb84357df142c254f35a23e19aa ;;
        3.5a) echo 16216bd0877170dfcc64157085ba9013610b12b082548c7c9542cc0103198951 ;;
        *) return 1 ;;
    esac
}

# Bump when the configure flags or the staged layout change: every cached
# entry built by an older recipe is then rebuilt rather than trusted.
build_recipe=1

cache_root="${WAYCAR_CI_TMUX_CACHE:-$HOME/Library/Caches/waycar-ci/tmux}"
# A cold build takes about a minute; a waiter gives up well after that.
lock_wait_seconds=900

lock_owner_token="$$-$(uuidgen)"
lock_owner_start="$(ps -o lstart= -p "$$" | sed 's/^ *//; s/ *$//')"
held_lock=""
active_claim_guard=""
work_dir=""
dependencies_checked=0
build_cppflags=""
build_ldflags=""

die() {
    printf 'build-ci-tmux.sh: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local status=$?
    trap - EXIT INT TERM
    if [[ -n "$active_claim_guard" ]]; then
        release_claim_guard "$active_claim_guard"
    fi
    if [[ -n "$held_lock" ]]; then
        release_build_lock "$held_lock" || true
    fi
    if [[ -n "$work_dir" ]]; then
        rm -rf -- "$work_dir"
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

# The lock protocol of scripts/run-ci-ios-tests.sh: an owned lock directory
# records its holder's pid and start time, and a short-lived claim guard
# serializes inspecting, reclaiming and releasing it. A guard is never
# reclaimed automatically; one left by a killed run is reported instead.
write_lock_owner() {
    local lock=$1

    printf '%s' "$lock_owner_token" > "$lock/token"
    printf '%s' "$$" > "$lock/pid"
    printf '%s' "$lock_owner_start" > "$lock/start"
}

lock_is_stale() {
    local lock=$1
    local owner
    local expected_start
    local actual_start

    owner=$(cat "$lock/pid" 2>/dev/null) || true
    expected_start=$(cat "$lock/start" 2>/dev/null) || true
    if [[ -z "$owner" || -z "$expected_start" ]]; then
        return 0
    fi
    actual_start=$(ps -o lstart= -p "$owner" 2>/dev/null \
        | sed 's/^ *//; s/ *$//') || true
    [[ -n "$actual_start" && "$actual_start" == "$expected_start" ]] \
        && return 1
    return 0
}

acquire_claim_guard() {
    local lock=$1
    local guard="$lock.claiming"
    local attempt

    for ((attempt = 0; attempt < 100; attempt += 1)); do
        if mkdir "$guard" 2>/dev/null; then
            active_claim_guard="$guard"
            printf '%s' "$lock_owner_token" > "$guard/token"
            return 0
        fi
        sleep 0.05
    done
    printf 'build-ci-tmux.sh: cannot claim %s: another run is changing it.\n' \
        "$lock" >&2
    printf 'If no build is starting, remove orphaned guard %s manually.\n' \
        "$guard" >&2
    return 1
}

release_claim_guard() {
    local guard=$1
    local token

    token=$(cat "$guard/token" 2>/dev/null) || true
    if [[ "$token" == "$lock_owner_token" \
        || "$active_claim_guard" == "$guard" ]]; then
        rm -f -- "$guard/token"
        rmdir "$guard" 2>/dev/null || true
    fi
    if [[ "$active_claim_guard" == "$guard" ]]; then
        active_claim_guard=""
    fi
}

# 0 claimed, 1 held by a live owner, 2 the guard itself could not be taken.
try_claim_build_lock() {
    local lock=$1
    local owner
    local status=1

    acquire_claim_guard "$lock" || return 2
    if [[ ! -d "$lock" ]]; then
        if mkdir "$lock"; then
            write_lock_owner "$lock"
            held_lock="$lock"
            status=0
        fi
    elif lock_is_stale "$lock"; then
        owner=$(cat "$lock/pid" 2>/dev/null) || true
        printf 'build-ci-tmux.sh: reclaiming the stale lock %s (owner pid %s is gone)\n' \
            "$lock" "${owner:-unknown}" >&2
        rm -rf -- "$lock"
        if mkdir "$lock"; then
            write_lock_owner "$lock"
            held_lock="$lock"
            status=0
        fi
    fi
    release_claim_guard "$active_claim_guard"
    return "$status"
}

acquire_build_lock() {
    local lock=$1
    local deadline=$((SECONDS + lock_wait_seconds))
    local status
    local announced=0

    while :; do
        status=0
        try_claim_build_lock "$lock" || status=$?
        case "$status" in
            0) return 0 ;;
            2) return 1 ;;
        esac
        if ((SECONDS >= deadline)); then
            printf 'build-ci-tmux.sh: gave up after %ss waiting for pid %s to release %s\n' \
                "$lock_wait_seconds" "$(cat "$lock/pid" 2>/dev/null || echo unknown)" \
                "$lock" >&2
            return 1
        fi
        if [[ "$announced" == 0 ]]; then
            printf '==> waiting for pid %s, which is building into %s\n' \
                "$(cat "$lock/pid" 2>/dev/null || echo unknown)" "$lock" >&2
            announced=1
        fi
        sleep 2
    done
}

release_build_lock() {
    local lock=$1
    local token

    [[ -d "$lock" ]] || { held_lock=""; return 0; }
    acquire_claim_guard "$lock" || return 1
    token=$(cat "$lock/token" 2>/dev/null) || true
    if [[ "$token" == "$lock_owner_token" ]]; then
        rm -rf -- "$lock"
    fi
    release_claim_guard "$active_claim_guard"
    held_lock=""
}

entry_is_valid() {
    local entry=$1
    local version=$2
    local sha256=$3

    [[ "$(cat "$entry/stamp" 2>/dev/null)" == "$version $sha256 $build_recipe" ]] \
        || return 1
    [[ -x "$entry/bin/tmux" ]] || return 1
    [[ "$(env -u TMUX "$entry/bin/tmux" -V 2>/dev/null)" == "tmux $version" ]]
}

# Homebrew's ncurses is keg-only, so its .pc files are not on pkg-config's
# default path; add the kegs' directories when Homebrew is present.
check_build_dependencies() {
    local -a missing=()
    local brew_prefix
    local formula
    local pkgconfig_dir
    local curses_module=""
    local event_module=""

    [[ "$dependencies_checked" == 0 ]] || return 0
    command -v cc >/dev/null 2>&1 \
        || missing+=("a C compiler (cc; xcode-select --install)")
    command -v make >/dev/null 2>&1 || missing+=("make")
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v shasum >/dev/null 2>&1 || missing+=("shasum")
    command -v bison >/dev/null 2>&1 \
        || command -v byacc >/dev/null 2>&1 \
        || command -v yacc >/dev/null 2>&1 \
        || missing+=("yacc or bison")
    if ! command -v pkg-config >/dev/null 2>&1; then
        missing+=("pkg-config (brew install pkg-config)")
    else
        if command -v brew >/dev/null 2>&1 \
            && brew_prefix=$(brew --prefix 2>/dev/null); then
            for formula in ncurses libevent utf8proc; do
                pkgconfig_dir="$brew_prefix/opt/$formula/lib/pkgconfig"
                if [[ -d "$pkgconfig_dir" ]]; then
                    PKG_CONFIG_PATH="$pkgconfig_dir${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
                fi
            done
            export PKG_CONFIG_PATH
        fi
        if pkg-config --exists 'libevent_core >= 2'; then
            event_module=libevent_core
        elif pkg-config --exists 'libevent >= 2'; then
            event_module=libevent
        else
            missing+=("libevent 2 visible to pkg-config (brew install libevent)")
        fi
        if pkg-config --exists ncurses; then
            curses_module=ncurses
        elif pkg-config --exists ncursesw; then
            curses_module=ncursesw
        else
            missing+=("ncurses visible to pkg-config (brew install ncurses)")
        fi
        pkg-config --exists libutf8proc \
            || missing+=("utf8proc visible to pkg-config (brew install utf8proc)")
    fi
    if ((${#missing[@]} > 0)); then
        printf 'build-ci-tmux.sh: cannot build tmux; missing build dependencies:\n' >&2
        printf '  - %s\n' "${missing[@]}" >&2
        printf 'Install them and rerun; this script installs nothing.\n' >&2
        exit 1
    fi
    # tmux 3.2a looks for utf8proc by header and library alone, so its flags
    # go in explicitly; the others are harmless to repeat.
    build_cppflags=$(pkg-config --cflags "$event_module" "$curses_module" libutf8proc)
    build_ldflags=$(pkg-config --libs-only-L "$event_module" "$curses_module" libutf8proc)
    dependencies_checked=1
}

build_release() {
    local version=$1
    local sha256=$2
    local entry=$3
    local url="https://github.com/tmux/tmux/releases/download/$version/tmux-$version.tar.gz"
    local tarball
    local actual
    local source_dir
    local log
    local jobs

    check_build_dependencies
    mkdir -p "$cache_root"
    work_dir=$(mktemp -d "$cache_root/.work-$version.XXXXXX")
    tarball="$work_dir/tmux-$version.tar.gz"
    source_dir="$work_dir/tmux-$version"
    log="$work_dir/build.log"

    echo "==> tmux $version: downloading $url" >&2
    curl -fsSL --retry 3 --connect-timeout 30 -o "$tarball" "$url" \
        || die "tmux $version: download failed: $url"
    actual=$(shasum -a 256 "$tarball" | awk '{ print $1 }')
    if [[ "$actual" != "$sha256" ]]; then
        die "tmux $version: checksum mismatch for $url (expected $sha256, got $actual)"
    fi
    tar -xzf "$tarball" -C "$work_dir"
    [[ -x "$source_dir/configure" ]] \
        || die "tmux $version: the tarball has no $source_dir/configure"

    jobs=$(sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
    echo "==> tmux $version: building (log $log while it runs)" >&2
    # The prefix is the cache entry, so the default configuration file
    # ($prefix/etc/tmux.conf) is one that never exists: no machine tmux.conf
    # reaches the fixture server.
    if ! (
        cd "$source_dir"
        ./configure --prefix="$entry" --enable-utf8proc \
            CPPFLAGS="$build_cppflags" LDFLAGS="$build_ldflags"
        make -j "$jobs"
    ) > "$log" 2>&1; then
        tail -n 40 "$log" >&2
        die "tmux $version: configure or make failed (last 40 lines above)"
    fi

    mkdir -p "$work_dir/entry/bin"
    cp "$source_dir/tmux" "$work_dir/entry/bin/tmux"
    chmod 755 "$work_dir/entry/bin/tmux"
    printf '%s %s %s\n' "$version" "$sha256" "$build_recipe" > "$work_dir/entry/stamp"
    entry_is_valid "$work_dir/entry" "$version" "$sha256" \
        || die "tmux $version: the built binary does not report 'tmux $version'"
    rm -rf -- "$entry"
    mv "$work_dir/entry" "$entry"
    rm -rf -- "$work_dir"
    work_dir=""
}

provide_release() {
    local version=$1
    local sha256
    local entry
    local lock

    sha256=$(pinned_sha256 "$version") \
        || die "tmux $version is not pinned here (pinned: ${pinned_versions[*]})"
    entry="$cache_root/$version-${sha256:0:16}"
    lock="$entry.lock"

    if ! entry_is_valid "$entry" "$version" "$sha256"; then
        mkdir -p "$cache_root"
        acquire_build_lock "$lock" || die "tmux $version: could not lock $lock"
        # Another run may have finished it while this one waited.
        if entry_is_valid "$entry" "$version" "$sha256"; then
            echo "==> tmux $version: built by another run at $entry" >&2
        else
            build_release "$version" "$sha256" "$entry"
            echo "==> tmux $version: built into $entry" >&2
        fi
        release_build_lock "$lock" || die "tmux $version: could not release $lock"
    else
        echo "==> tmux $version: cached at $entry" >&2
    fi
    printf '%s %s\n' "$version" "$entry/bin/tmux"
}

if (($# == 0)); then
    set -- "${pinned_versions[@]}"
fi
for requested in "$@"; do
    provide_release "$requested"
done
