#!/bin/sh
# Package plugin/ for the public installer and render the installer script.
#
#   scripts/package-plugin.sh <out-dir>
#
# Writes into <out-dir>, for each of the four targets (x86_64-unknown-linux-musl,
# aarch64-unknown-linux-musl, aarch64-apple-darwin, x86_64-apple-darwin):
#   plugin/waycar-<version>-<target>-<sha12>.tar.gz         plugin with the
#                                                           native bin/waycar
#   plugin/waycar-<version>-<target>-<sha12>.tar.gz.sha256  "<hex>  <file>" line
# and
#   install.sh                                              plugin/install.sh
#                                                           with the version
#                                                           and each target's
#                                                           file and checksum
#
# Native binaries come from $WAYCAR_PLUGIN_BINARIES/<target>/waycar when that
# is set (the plugin-binaries job in ci-node.yml builds them first and logs
# their sizes); otherwise
# scripts/build-plugin-binaries.sh builds them into a temporary directory
# first, which installs its own toolchain on demand (slow on a cold cache).
#
# In the tarball bin/waycar is that native binary; bin/waycar-hook is a POSIX
# sh script, and hooks/ holds the extension files the agents load. Nothing in
# the package needs Node: no src/, node_modules or package.json.
#
# The tarball is not byte-reproducible (fresh mtimes each build), so its name
# carries its own hash: each build gets a new URL and a cached or mid-deploy
# response can never pair one build's install.sh with another's bytes.
#
# apps/web runs this before `astro build` with <out-dir> = public, so every
# site deploy ships the plugin built from the same commit and waycar.dev/
# install.sh always names those tarballs. The release workflow reuses it to
# attach the same files to a GitHub release.
#
set -eu

out=${1:?usage: scripts/package-plugin.sh <out-dir>}
root=$(cd "$(dirname "$0")/.." && pwd)
src="$root/plugin"
# target, then the placeholder suffix install.sh uses for it.
targets="x86_64-unknown-linux-musl:X86_64_LINUX aarch64-unknown-linux-musl:AARCH64_LINUX aarch64-apple-darwin:AARCH64_DARWIN x86_64-apple-darwin:X86_64_DARWIN"

version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$src/herdr-plugin.toml")
cargo_version=$(sed -n '/^\[package\]/,/^\[/{s/^version = "\(.*\)"$/\1/p;}' "$src/Cargo.toml")
# The version is spliced into shell source and file names: allow semver only.
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
  || { echo "package-plugin: bad version '$version' in herdr-plugin.toml" >&2; exit 1; }
[ "$version" = "$cargo_version" ] || {
  echo "package-plugin: herdr-plugin.toml $version != Cargo.toml $cargo_version" >&2
  exit 1
}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

binaries=${WAYCAR_PLUGIN_BINARIES:-}
if [ -z "$binaries" ]; then
  binaries="$stage/binaries"
  sh "$root/scripts/build-plugin-binaries.sh" "$binaries"
fi

# First four bytes of a file as hex: 7f454c46 is ELF, cffaedfe is 64-bit
# little-endian Mach-O.
magic() { od -An -tx1 -N4 | tr -d ' \n'; }

common="$stage/common/waycar"
mkdir -p "$common/bin"
cp "$src/bin/waycar-hook" "$common/bin/"
cp -R "$src/hooks" "$src/README.md" "$src/LICENSE" "$src/NOTICE" "$src/THIRD-PARTY-LICENSES" \
  "$src/herdr-plugin.toml" "$common/"
# The tmux pane-option vector pins what the hooks write; ship it with them.
mkdir -p "$common/test-vectors"
cp "$src/test-vectors/tmux-pane-options-v1.json" "$common/test-vectors/"

mkdir -p "$out/plugin"
rm -f "$out"/plugin/*.tar.gz "$out"/plugin/*.tar.gz.sha256

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

sed_args="-e s/@PLUGIN_VERSION@/$version/g"
summary=
for entry in $targets; do
  target=${entry%%:*}
  suffix=${entry#*:}
  bin="$binaries/$target/waycar"
  [ -s "$bin" ] || { echo "package-plugin: no native binary for $target at $bin" >&2; exit 1; }
  case "$target" in
    *-linux-*) want=7f454c46 ;;
    *-apple-darwin) want=cffaedfe ;;
  esac
  [ "$(magic <"$bin")" = "$want" ] || { echo "package-plugin: $bin is not a native $target binary" >&2; exit 1; }

  tdir="$stage/$target"
  mkdir -p "$tdir"
  cp -R "$stage/common/waycar" "$tdir/waycar"
  # bin/waycar (linked as ~/.local/bin/waycar) and bin/waycar-hook (run by the
  # agent hooks) are executed directly or by path, so they keep their exec bit.
  cp "$bin" "$tdir/waycar/bin/waycar"
  chmod 755 "$tdir/waycar/bin/waycar" "$tdir/waycar/bin/waycar-hook"

  # COPYFILE_DISABLE keeps macOS tar from adding ._ AppleDouble entries.
  COPYFILE_DISABLE=1 tar -C "$tdir" -czf "$stage/$target.tar.gz" waycar
  sum=$(sha256_of "$stage/$target.tar.gz")
  printf '%s' "$sum" | grep -Eq '^[0-9a-f]{64}$' || { echo "package-plugin: bad sha256" >&2; exit 1; }
  tarball="waycar-$version-$target-$(printf '%s' "$sum" | cut -c 1-12).tar.gz"
  mv "$stage/$target.tar.gz" "$out/plugin/$tarball"
  printf '%s  %s\n' "$sum" "$tarball" >"$out/plugin/$tarball.sha256"
  rm -rf "$tdir"

  # What a user gets: exec bits, a native bin/waycar and no JavaScript tree.
  listing=$(tar -tzvf "$out/plugin/$tarball")
  for f in bin/waycar bin/waycar-hook; do
    printf '%s\n' "$listing" | grep -E "^-[r-][w-]x.* waycar/$f\$" >/dev/null \
      || { echo "package-plugin: $tarball: waycar/$f is missing or not executable" >&2; exit 1; }
  done
  if printf '%s\n' "$listing" | grep -E ' waycar/(src/|node_modules|package(-lock)?\.json|bin/node\.sh)' >/dev/null; then
    echo "package-plugin: $tarball: carries Node files" >&2
    exit 1
  fi
  printf '%s\n' "$listing" | grep -E " waycar/THIRD-PARTY-LICENSES\$" >/dev/null \
    || { echo "package-plugin: $tarball: waycar/THIRD-PARTY-LICENSES is missing" >&2; exit 1; }
  [ "$(tar -xzOf "$out/plugin/$tarball" waycar/bin/waycar | magic)" = "$want" ] \
    || { echo "package-plugin: $tarball: bin/waycar is not the native binary" >&2; exit 1; }

  sed_args="$sed_args -e s/@PLUGIN_TARBALL_$suffix@/$tarball/g -e s/@PLUGIN_SHA256_$suffix@/$sum/g"
  summary="$summary
package-plugin: $tarball $sum"
done

# shellcheck disable=SC2086 # $sed_args holds only space-free sed arguments
sed $sed_args "$src/install.sh" >"$out/install.sh"
grep -q '@PLUGIN_' "$out/install.sh" && { echo "package-plugin: unrendered placeholder" >&2; exit 1; }

printf '%s\n' "$summary" | sed '/^$/d'
