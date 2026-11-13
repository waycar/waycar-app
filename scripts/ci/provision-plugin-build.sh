#!/bin/sh
# Provision the toolchain that builds the Waycar plugin's native binaries
# (plugin/Cargo.toml): the Rust toolchain pinned by plugin/rust-toolchain.toml
# with its four release targets, zig, and cargo-zigbuild. Linux musl targets
# need zig as the C compiler for the TLS crate `ring`, so plain `cargo build`
# does not work for them.
#
#   eval "$(sh scripts/ci/provision-plugin-build.sh)"   # this shell's PATH
#   sh scripts/ci/provision-plugin-build.sh --github    # later GitHub steps
#
# Idempotent: anything already present (on PATH at the pinned version, or in
# the cache from an earlier run) is left alone. Installs go to
# ${XDG_CACHE_HOME:-$HOME/.cache}/waycar-build, never system-wide, so a
# runner needs nothing set up by hand except curl, tar and either
# xz or python3. Progress goes to stderr; stdout carries only `export` lines
# (default) or nothing (--github appends PATH, CARGO_HOME and RUSTUP_HOME to
# $GITHUB_PATH and $GITHUB_ENV).
set -eu

ZIG_VERSION=0.17.0
ZIG_SHA256_X86_64=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026
ZIG_SHA256_AARCH64=9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8
ZIGBUILD_VERSION=0.24.0

root=$(cd "$(dirname "$0")/../.." && pwd)
cache="${XDG_CACHE_HOME:-$HOME/.cache}/waycar-build"
mkdir -p "$cache"

log() { printf 'provision-plugin-build: %s\n' "$*" >&2; }
fail() { log "$*"; exit 1; }

mode=export
case "${1:-}" in
  '') ;;
  --github) mode=github ;;
  *) fail "usage: provision-plugin-build.sh [--github]" ;;
esac

# Directories to put on PATH, in order, and variables to export.
path_add=
env_add=
add_path() { path_add="$path_add
$1"; PATH="$1:$PATH"; export PATH; }
add_env() { env_add="$env_add
$1=$2"; export "$1=$2"; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

# --- Rust -------------------------------------------------------------------
# rustup reads plugin/rust-toolchain.toml (channel, targets, profile).
if ! command -v rustup >/dev/null 2>&1; then
  if [ -x "$HOME/.cargo/bin/rustup" ]; then
    add_path "$HOME/.cargo/bin"
  else
    # No system rustup: keep our own in the cache.
    add_env CARGO_HOME "$cache/cargo"
    add_env RUSTUP_HOME "$cache/rustup"
    add_path "$cache/cargo/bin"
    if ! command -v rustup >/dev/null 2>&1; then
      log "installing rustup into $cache"
      command -v curl >/dev/null 2>&1 || fail "curl not found"
      curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o "$cache/rustup-init.sh"
      sh "$cache/rustup-init.sh" -y --no-modify-path --profile minimal --default-toolchain none >&2
    fi
  fi
fi
[ -f "$root/plugin/rust-toolchain.toml" ] || fail "plugin/rust-toolchain.toml not found"
# Targets pinned by the toolchain file; install the toolchain when it, or any
# of them, is missing. `rustup toolchain install` with no argument installs
# what the file in the current directory names.
targets=$(sed -n '/^targets/,/\]/p' "$root/plugin/rust-toolchain.toml" | grep -o '"[^"]*"' | tr -d '"')
[ -n "$targets" ] || fail "no targets in plugin/rust-toolchain.toml"
need_rust=
installed=$(cd "$root/plugin" && rustup target list --installed 2>/dev/null) || need_rust=1
for t in $targets; do
  printf '%s\n' "$installed" | grep -qx "$t" || need_rust=1
done
if [ -n "$need_rust" ]; then
  log "installing the Rust toolchain from plugin/rust-toolchain.toml"
  (cd "$root/plugin" && rustup toolchain install >&2)
fi

# --- zig ----------------------------------------------------------------------
if [ "$(zig version 2>/dev/null || true)" != "$ZIG_VERSION" ]; then
  [ "$(uname -s)" = Linux ] || fail "zig $ZIG_VERSION is not on PATH and this script installs the Linux build only; install zig $ZIG_VERSION, or build the binaries on Linux and set WAYCAR_PLUGIN_BINARIES to their directory"
  case "$(uname -m)" in
    x86_64 | amd64) zig_arch=x86_64; zig_sha=$ZIG_SHA256_X86_64 ;;
    aarch64 | arm64) zig_arch=aarch64; zig_sha=$ZIG_SHA256_AARCH64 ;;
    *) fail "no zig $ZIG_VERSION pin for $(uname -m)" ;;
  esac
  zig_name="zig-$zig_arch-linux-$ZIG_VERSION"
  zig_dir="$cache/$zig_name"
  if [ ! -x "$zig_dir/zig" ]; then
    log "installing zig $ZIG_VERSION into $zig_dir"
    command -v curl >/dev/null 2>&1 || fail "curl not found"
    tmp=$(mktemp -d "$cache/zig-download.XXXXXX")
    curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/$zig_name.tar.xz" -o "$tmp/zig.tar.xz"
    [ "$(sha256_of "$tmp/zig.tar.xz")" = "$zig_sha" ] || { rm -rf "$tmp"; fail "zig tarball checksum mismatch"; }
    if command -v xz >/dev/null 2>&1; then
      xz -dc "$tmp/zig.tar.xz" | tar -C "$tmp" -xf -
    elif command -v python3 >/dev/null 2>&1; then
      python3 -c 'import sys, tarfile; tarfile.open(sys.argv[1]).extractall(sys.argv[2])' "$tmp/zig.tar.xz" "$tmp"
    else
      rm -rf "$tmp"; fail "need xz or python3 to unpack zig"
    fi
    [ -x "$tmp/$zig_name/zig" ] || chmod 755 "$tmp/$zig_name/zig"
    rm -rf "$zig_dir"
    mv "$tmp/$zig_name" "$zig_dir"
    rm -rf "$tmp"
  fi
  add_path "$zig_dir"
fi

# --- cargo-zigbuild -----------------------------------------------------------
case "$(cargo-zigbuild --version 2>/dev/null || true)" in
  *" $ZIGBUILD_VERSION") ;;
  *)
    zb_root="$cache/cargo-zigbuild-$ZIGBUILD_VERSION"
    if [ ! -x "$zb_root/bin/cargo-zigbuild" ]; then
      log "installing cargo-zigbuild $ZIGBUILD_VERSION into $zb_root"
      (cd "$root/plugin" && cargo install --locked --version "$ZIGBUILD_VERSION" --root "$zb_root" cargo-zigbuild >&2)
    fi
    add_path "$zb_root/bin"
    ;;
esac

# --- output -------------------------------------------------------------------
if [ "$mode" = github ]; then
  [ -n "${GITHUB_PATH:-}" ] && [ -n "${GITHUB_ENV:-}" ] || fail "--github needs GITHUB_PATH and GITHUB_ENV"
  # path_add was built front-to-back; GITHUB_PATH prepends each line it reads.
  printf '%s\n' "$path_add" | sed '/^$/d' >>"$GITHUB_PATH"
  printf '%s\n' "$env_add" | sed '/^$/d' >>"$GITHUB_ENV"
else
  printf '%s\n' "$path_add" | sed '/^$/d' | while IFS= read -r dir; do
    printf "export PATH='%s':\"\$PATH\"\n" "$dir"
  done
  printf '%s\n' "$env_add" | sed '/^$/d' | while IFS= read -r pair; do
    printf "export %s='%s'\n" "${pair%%=*}" "${pair#*=}"
  done
fi
