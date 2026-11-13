#!/bin/sh
# Build the native `waycar` Host Tools binary for the machine this runs on and
# print its path on stdout (progress goes to stderr). The iOS job uses it as
# WAYCAR_PAIR_ACCEPT_BIN: the Pairing ceremony e2e runs `waycar pair-accept` as
# the sshd forced command.
#
# scripts/ci/provision-plugin-build.sh cannot serve a Mac runner (its zig
# install is Linux-only, and the release targets are musl), so this builds the
# host target with plain cargo. The toolchain version comes from
# plugin/rust-toolchain.toml; rustup is installed into the cache if absent.
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)
cache="${XDG_CACHE_HOME:-$HOME/.cache}/waycar-build"
mkdir -p "$cache"
log() { printf 'build-native-waycar: %s\n' "$*" >&2; }

if ! command -v rustup >/dev/null 2>&1; then
  if [ -x "$HOME/.cargo/bin/rustup" ]; then
    PATH="$HOME/.cargo/bin:$PATH"
  else
    CARGO_HOME="$cache/cargo"; RUSTUP_HOME="$cache/rustup"
    export CARGO_HOME RUSTUP_HOME
    PATH="$CARGO_HOME/bin:$PATH"
    if ! command -v rustup >/dev/null 2>&1; then
      log "installing rustup into $cache"
      curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o "$cache/rustup-init.sh"
      sh "$cache/rustup-init.sh" -y --no-modify-path --profile minimal --default-toolchain none >&2
    fi
  fi
fi

channel=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$root/plugin/rust-toolchain.toml")
[ -n "$channel" ] || { log "no channel in plugin/rust-toolchain.toml"; exit 1; }
# Install the pinned channel for the host only; the file's musl targets are for
# the Linux release build. `+channel` below overrides the file.
rustup toolchain install "$channel" --profile minimal --no-self-update >&2
cargo "+$channel" build --release --locked --manifest-path "$root/plugin/Cargo.toml" >&2
bin="$root/plugin/target/release/waycar"
[ -x "$bin" ] || { log "missing $bin"; exit 1; }
printf '%s\n' "$bin"
