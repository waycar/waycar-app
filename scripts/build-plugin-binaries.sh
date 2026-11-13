#!/bin/sh
# Build the native `waycar` binary (plugin/Cargo.toml) for every release
# target.
#
#   scripts/build-plugin-binaries.sh <out-dir>
#
# Writes <out-dir>/<target>/waycar for x86_64-unknown-linux-musl,
# aarch64-unknown-linux-musl, aarch64-apple-darwin and x86_64-apple-darwin,
# then prints a size table (bytes and MiB), and appends it as a markdown
# table to $GITHUB_STEP_SUMMARY when that is set. Fails when any target fails
# to build or produces an empty file.
#
# The toolchain (pinned Rust, zig, cargo-zigbuild) is installed on demand into
# a user cache by scripts/ci/provision-plugin-build.sh and is a no-op when
# already present, so a bare runner needs nothing set up. Set
# WAYCAR_SKIP_PROVISION=1 to use the toolchain already on PATH untouched.
# scripts/package-plugin.sh consumes <out-dir> through WAYCAR_PLUGIN_BINARIES.
set -eu

out=${1:?usage: scripts/build-plugin-binaries.sh <out-dir>}
root=$(cd "$(dirname "$0")/.." && pwd)
targets="x86_64-unknown-linux-musl aarch64-unknown-linux-musl aarch64-apple-darwin x86_64-apple-darwin"

if [ -z "${WAYCAR_SKIP_PROVISION:-}" ]; then
  eval "$(sh "$root/scripts/ci/provision-plugin-build.sh")"
fi

# Pins the macOS minimum so the binaries run on every macOS the app supports.
MACOSX_DEPLOYMENT_TARGET=11.0
export MACOSX_DEPLOYMENT_TARGET

mkdir -p "$out"
out=$(cd "$out" && pwd)
rows=
for target in $targets; do
  echo "build-plugin-binaries: $target" >&2
  (cd "$root/plugin" && cargo zigbuild --release --locked --target "$target") \
    || { echo "build-plugin-binaries: build failed for $target" >&2; exit 1; }
  built="$root/plugin/target/$target/release/waycar"
  [ -s "$built" ] || { echo "build-plugin-binaries: $built missing or empty" >&2; exit 1; }
  mkdir -p "$out/$target"
  cp "$built" "$out/$target/waycar"
  chmod 755 "$out/$target/waycar"
  bytes=$(wc -c <"$out/$target/waycar" | tr -d ' ')
  [ "$bytes" -gt 0 ] || { echo "build-plugin-binaries: empty binary for $target" >&2; exit 1; }
  mib=$(awk -v b="$bytes" 'BEGIN { printf "%.2f", b / 1048576 }')
  rows="$rows$target $bytes $mib
"
done

printf '%-30s %12s %8s\n' target bytes MiB
printf '%s' "$rows" | while read -r target bytes mib; do
  printf '%-30s %12s %8s\n' "$target" "$bytes" "$mib"
done

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '### waycar binary sizes\n\n| target | bytes | MiB |\n| --- | ---: | ---: |\n'
    printf '%s' "$rows" | while read -r target bytes mib; do
      printf '| %s | %s | %s |\n' "$target" "$bytes" "$mib"
    done
  } >>"$GITHUB_STEP_SUMMARY"
fi
