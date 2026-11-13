#!/bin/sh
# Guards the Waycar plugin's version: the app reads it on each Host to decide
# whether the installed plugin is new enough, so a version must name exactly
# one set of shipped files.
#
#   scripts/check-plugin-version.sh
#
# Fails when:
#   1. plugin/herdr-plugin.toml, plugin/Cargo.toml and the `waycar` package
#      entry of plugin/Cargo.lock disagree;
#   2. WaycarPluginRequirement.minimumVersion, .nativeToolsMinimumVersion,
#      .coreMinimumVersion or .zellijMinimumVersion
#      (Sources/Waycar/Transport/WaycarPlugin.swift) is missing, unparseable,
#      or newer than the plugin version: the app would ask for a plugin that
#      does not exist yet; or WaycarPluginRequirement.currentVersion is not
#      the plugin version: the app would call an older Host up to date, or
#      offer it a plugin that is not shipped;
#   3. The version is already released and a file the plugin package ships
#      differs from that release: the change would reach users from
#      waycar.dev/install.sh under a version that already means something
#      else, and the app could not tell the two apart. Bump the version.
#      "Released" is the `plugin-v<version>` tag or, when that tag does not
#      exist yet, the baseline commit if it already declares this version
#      (a change landing on top of a bump that is not tagged yet). The
#      baseline is $PLUGIN_BASE (CI: the PR base or the push's previous
#      commit), default origin/main. An unset/empty/all-zero baseline or a
#      ref that cannot be resolved falls back to the tag alone, with a note.
#      A version neither tagged nor in the baseline passes: the next release.
#
# Shipped files mirror scripts/package-plugin.sh: bin/ (waycar-hook; the native
# bin/waycar is built from the Rust sources), hooks/, herdr-plugin.toml and
# test-vectors/tmux-pane-options-v1.json in the tarball, the Rust sources the
# native bin/waycar is built from (Cargo.toml, Cargo.lock, rust-toolchain.toml,
# rust/), plus install.sh, which it renders as the installer, and
# scripts/package-plugin.sh and scripts/build-plugin-binaries.sh themselves.
# README.md, LICENSE and NOTICE ship too but are documentation, never
# behavior, so they are left out: a doc fix needs no release.
#
# Works in a shallow checkout: a tag missing locally is fetched from origin
# (depth 1 when the clone is shallow; the diff needs only the tag's tree),
# and so is a baseline commit.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

fail() { echo "check-plugin-version: $*" >&2; exit 1; }

# 1. One version everywhere.
version=$(sed -n 's/^version = "\(.*\)"$/\1/p' plugin/herdr-plugin.toml)
[ -n "$version" ] || fail "no version in plugin/herdr-plugin.toml"
cargo_version=$(sed -n '/^\[package\]/,/^\[/{s/^version = "\(.*\)"$/\1/p;}' plugin/Cargo.toml)
[ -n "$cargo_version" ] || fail "no [package] version in plugin/Cargo.toml"
cargo_lock_version=$(awk '
  /^\[\[package\]\]$/ { name = ""; next }
  /^name = "waycar"$/ { name = "waycar"; next }
  name == "waycar" && /^version = / { gsub(/^version = "|"$/, ""); print; exit }
' plugin/Cargo.lock)
[ -n "$cargo_lock_version" ] || fail "no waycar package entry in plugin/Cargo.lock"
mismatch=
[ "$cargo_version" = "$version" ] || mismatch="$mismatch
  plugin/Cargo.toml version $cargo_version"
[ "$cargo_lock_version" = "$version" ] || mismatch="$mismatch
  plugin/Cargo.lock waycar version $cargo_lock_version"
[ -z "$mismatch" ] || fail "plugin versions disagree with plugin/herdr-plugin.toml $version:$mismatch
Set them together: edit plugin/Cargo.toml, then run cargo update -p waycar --offline in plugin/"
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
  || fail "bad version '$version' in plugin/herdr-plugin.toml"

# 2. The app's minimum is a version that exists.
requirement=Sources/Waycar/Transport/WaycarPlugin.swift
[ -f "$requirement" ] || fail "$requirement not found"
minimum=$(sed -n 's/^[[:space:]]*static let minimumVersion = "\([^"]*\)".*/\1/p' "$requirement")
printf '%s' "$minimum" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || fail "no parseable 'static let minimumVersion = \"X.Y.Z\"' in $requirement (found '$minimum')"
# Exit 0 when $1 <= $2, comparing major.minor.patch numerically; a
# prerelease suffix on $2 is ignored.
version_le() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, "."); split(b, y, "."); sub(/-.*/, "", y[3])
    for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
    exit 0
  }'
}
version_le "$minimum" "$version" \
  || fail "WaycarPluginRequirement.minimumVersion $minimum is newer than plugin $version; bump the plugin in the same change"
native_minimum=$(sed -n 's/^[[:space:]]*static let nativeToolsMinimumVersion = "\([^"]*\)".*/\1/p' "$requirement")
printf '%s' "$native_minimum" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || fail "no parseable 'static let nativeToolsMinimumVersion = \"X.Y.Z\"' in $requirement (found '$native_minimum')"
version_le "$native_minimum" "$version" \
  || fail "WaycarPluginRequirement.nativeToolsMinimumVersion $native_minimum is newer than plugin $version; the app would prompt Hosts to update to a plugin that is not shipped yet. Bump the plugin in the same change, and merge only after waycar.dev serves it"
core_minimum=$(sed -n 's/^[[:space:]]*static let coreMinimumVersion = "\([^"]*\)".*/\1/p' "$requirement")
printf '%s' "$core_minimum" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || fail "no parseable 'static let coreMinimumVersion = \"X.Y.Z\"' in $requirement (found '$core_minimum')"
version_le "$core_minimum" "$version" \
  || fail "WaycarPluginRequirement.coreMinimumVersion $core_minimum is newer than plugin $version; the app would prompt core Hosts to update to a plugin that is not shipped yet. Bump the plugin in the same change, and merge only after waycar.dev serves it"
zellij_minimum=$(sed -n 's/^[[:space:]]*static let zellijMinimumVersion = "\([^"]*\)".*/\1/p' "$requirement")
printf '%s' "$zellij_minimum" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || fail "no parseable 'static let zellijMinimumVersion = \"X.Y.Z\"' in $requirement (found '$zellij_minimum')"
version_le "$zellij_minimum" "$version" \
  || fail "WaycarPluginRequirement.zellijMinimumVersion $zellij_minimum is newer than plugin $version; the app would prompt Zellij Hosts to update to a plugin that is not shipped yet. Bump the plugin in the same change, and merge only after waycar.dev serves it"
current=$(sed -n 's/^[[:space:]]*static let currentVersion = "\([^"]*\)".*/\1/p' "$requirement")
[ "$current" = "$version" ] \
  || fail "WaycarPluginRequirement.currentVersion '$current' in $requirement is not plugin $version; set it to $version in the same change"

# 3. A released version's shipped files are frozen.
tag="plugin-v$version"
released=$tag
if ! git rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null; then
  # Exit 2: origin has no such tag. Anything else non-zero: origin is
  # unreachable, and passing then would skip the guard silently.
  set +e
  git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null
  status=$?
  set -e
  case $status in
    0)
      depth=
      [ "$(git rev-parse --is-shallow-repository)" = true ] && depth=--depth=1
      # shellcheck disable=SC2086 # $depth is empty or one flag
      git fetch -q --no-tags $depth origin "refs/tags/$tag:refs/tags/$tag" \
        || fail "could not fetch $tag from origin"
      ;;
    2) released= ;;
    *) fail "could not list tags on origin (git ls-remote exit $status)" ;;
  esac
fi

if [ -z "$released" ]; then
  base=${PLUGIN_BASE-origin/main}
  case $base in
    '' | *[!0]*) ;;
    *) base= ;; # all-zero `before` of a new branch
  esac
  if [ -n "$base" ] && ! git rev-parse -q --verify "$base^{commit}" >/dev/null; then
    depth=
    [ "$(git rev-parse --is-shallow-repository)" = true ] && depth=--depth=1
    # shellcheck disable=SC2086 # $depth is empty or one flag
    git fetch -q --no-tags $depth origin "$base" 2>/dev/null \
      && git rev-parse -q --verify "$base^{commit}" >/dev/null \
      || base=
  fi
  if [ -z "$base" ]; then
    echo "check-plugin-version: note: no usable baseline (PLUGIN_BASE='${PLUGIN_BASE-origin/main}'); checking the tag only"
  else
    base_version=$(git show "$base:plugin/herdr-plugin.toml" 2>/dev/null \
      | sed -n 's/^version = "\(.*\)"$/\1/p')
    [ "$base_version" = "$version" ] && released=$base
  fi
  if [ -z "$released" ]; then
    echo "check-plugin-version: plugin $version (minimum $minimum) is not released yet; $tag will be cut when it reaches main"
    exit 0
  fi
fi

shipped="plugin/bin plugin/hooks plugin/herdr-plugin.toml plugin/install.sh
plugin/test-vectors/tmux-pane-options-v1.json scripts/package-plugin.sh
plugin/Cargo.toml plugin/Cargo.lock plugin/rust-toolchain.toml plugin/rust scripts/build-plugin-binaries.sh"
# shellcheck disable=SC2086 # $shipped is a list of paths without spaces
changed=$( {
  git diff --name-only "$released" -- $shipped
  git ls-files --others --exclude-standard -- $shipped
} | sort -u)

if [ -n "$changed" ]; then
  echo "check-plugin-version: plugin/ changed since plugin $version was released ($released); bump version in plugin/herdr-plugin.toml and plugin/Cargo.toml (then cargo update -p waycar --offline in plugin/). Changed:" >&2
  printf '%s\n' "$changed" | sed 's/^/  /' >&2
  exit 1
fi
echo "check-plugin-version: plugin $version (minimum $minimum) matches its release $released"
