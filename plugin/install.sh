#!/bin/sh
# Install or update Waycar's host tools: the herdr plugin (id `waycar`) and,
# on a box with tmux 3.2 or later or with herdr-core, the `waycar` command and
# the agent status hooks.
#
#   curl -fsSL https://waycar.dev/install.sh | sh
#   curl -fsSL https://waycar.dev/install.sh | sh -s -- --tmux --no-hooks
#   curl -fsSL https://waycar.dev/install.sh | sh -s -- --pair-only
#
# On a fresh machine with a terminal, the script first asks whether to
# install the host tools or pair this computer only. Pair-only runs the
# Pairing Code from a temporary download and installs nothing, for machines
# where you may not install software; it needs neither herdr nor tmux, only a
# terminal. The question is skipped when there is no
# terminal (the script installs, as before), when updating an existing
# install, for WAYCAR_PLUGIN_SOURCE runs (a developer checkout), and when
# WAYCAR_NO_PAIR is set.
#
# Downloads the plugin package published with this script for this computer
# (Linux or macOS, x86_64 or arm64; the `waycar` binary in it is native and
# needs nothing else on the computer), verifies its SHA-256 and unpacks it to
# ~/.local/share/waycar/plugin. With herdr on PATH
# it links that directory into herdr (herdr mode). Without herdr but with
# tmux, herdr-core (`herdr-core` or `hc`, found on PATH or in the usual
# install directories; only `--version` is ever run, since any other
# subcommand starts a core) or --tmux, it sets Waycar up without the herdr
# plugin instead (tmux mode, also the shape of a core-only Host). When tmux
# 3.2+ or herdr-core is present, in either mode, it links ~/.local/bin/waycar
# and installs the agent status hooks (`waycar hooks install`). With opencode or
# kilo on PATH, in either mode and without the tmux gate, it also installs
# their Chat Prompt extension (ADR 0025). Rerun to update.
# Before the pairing offer it prints a reach status (is Tailscale on this
# computer) and installs nothing for it.
# The plugin's config (pairing and notification keys) is kept.
#
# An update is staged and checked before it replaces anything: the package is
# unpacked next to the install directory (never in /tmp, which can be
# mounted noexec) and `bin/waycar version` must run there, else the script
# stops with the old install untouched. After the swap `waycar status --json`
# must pass, else the old install is moved back. The old install is deleted
# only after that.
#
# Moving a Host from the Node version (plugin 1.x): the swap drops `src`,
# `bin/node.sh`, `node_modules` and `package*.json`; the script also deletes
# Waycar's own Node leftovers (~/.cache/waycar/node-versions and
# ~/.local/state/waycar/bridge-off) and rewrites the agents' hook entries that
# called `node.sh` (`waycar hooks migrate`, also under --no-hooks). It never
# touches the user's own Node, npm, nvm or Homebrew, the plugin config, any
# key, the authorized_keys lines or the @waycar_* options, and it kills no
# process.
#
# This file is a template: scripts/package-plugin.sh fills in the version and
# each target's file name and checksum on every waycar.dev deploy.
#
# Options:
#   --tmux       set Waycar up for tmux even when herdr is installed
#   --no-hooks   skip the agent status hooks and the opencode and kilo Chat
#                Prompt extensions
#   --pair-only  pair only, never ask, install nothing
#
# Environment overrides:
#   WAYCAR_PAIR_ONLY         set to anything for the same as --pair-only
#   WAYCAR_INSTALL_BASE_URL  where the package lives (default https://waycar.dev)
#   WAYCAR_PLUGIN_DIR        absolute install directory
#                            (default ~/.local/share/waycar/plugin)
#   WAYCAR_PLUGIN_SOURCE     install from this local plugin directory (an
#                            unpacked package, or a checkout's plugin/ with the
#                            built binary copied to bin/waycar) instead of
#                            downloading; for testing before a deploy
#   WAYCAR_NO_PAIR           set to skip the pairing prompt
#   WAYCAR_INTERNAL          set by Waycar's own automation: marks the package
#                            download as ours in waycar.dev's analytics
set -eu

version='@PLUGIN_VERSION@'
tarball_x86_64_linux='@PLUGIN_TARBALL_X86_64_LINUX@'
sha256_x86_64_linux='@PLUGIN_SHA256_X86_64_LINUX@'
tarball_aarch64_linux='@PLUGIN_TARBALL_AARCH64_LINUX@'
sha256_aarch64_linux='@PLUGIN_SHA256_AARCH64_LINUX@'
tarball_aarch64_darwin='@PLUGIN_TARBALL_AARCH64_DARWIN@'
sha256_aarch64_darwin='@PLUGIN_SHA256_AARCH64_DARWIN@'
tarball_x86_64_darwin='@PLUGIN_TARBALL_X86_64_DARWIN@'
sha256_x86_64_darwin='@PLUGIN_SHA256_X86_64_DARWIN@'

say() { printf 'waycar: %s\n' "$*"; }
die() { printf 'waycar: error: %s\n' "$*" >&2; exit 1; }

# Everything runs from main so a truncated `curl | sh` download executes
# nothing, and herdr never reads the rest of this script from stdin.
main() {
  force_tmux=
  hooks=1
  pair_only=${WAYCAR_PAIR_ONLY:+1}
  for arg in "$@"; do
    case "$arg" in
      --tmux) force_tmux=1 ;;
      --no-hooks) hooks= ;;
      --pair-only) pair_only=1 ;;
      *) die "unknown option: $arg (expected --tmux, --no-hooks or --pair-only)" ;;
    esac
  done
  if [ -n "$pair_only" ] && { [ -n "$force_tmux" ] || [ -z "$hooks" ]; }; then
    die "--pair-only installs nothing; --tmux and --no-hooks do not apply"
  fi

  base_url="${WAYCAR_INSTALL_BASE_URL:-https://waycar.dev}"
  dest="${WAYCAR_PLUGIN_DIR:-$HOME/.local/share/waycar/plugin}"
  source_dir="${WAYCAR_PLUGIN_SOURCE:-}"
  case "$dest" in /*) ;; *) die "WAYCAR_PLUGIN_DIR must be an absolute path" ;; esac
  # The install dir is spliced into the opencode extension's plugin-root
  # string; a quote, backslash or newline there would break or inject into
  # that JS, so refuse it outright.
  case "$dest" in
    *'"'* | *'\'* | *"
"*) die 'WAYCAR_PLUGIN_DIR must not contain a double quote, backslash or newline (it is substituted into the opencode extension)' ;;
  esac
  recover_interrupted_update
  # Only ever replace a directory that holds this plugin.
  had_install=
  if [ -e "$dest" ]; then
    if grep -qx 'id = "waycar"' "$dest/herdr-plugin.toml" 2>/dev/null; then
      had_install=1
    else
      die "$dest exists and is not the Waycar plugin; move it or set WAYCAR_PLUGIN_DIR"
    fi
  fi

  if [ -z "$pair_only" ]; then
    ask_install_or_pair
  fi
  if [ -n "$pair_only" ]; then
    pair_only_main
    return
  fi

  detect_backends
  if [ -n "$force_tmux" ]; then
    mode=tmux
    say "setting Waycar up for tmux (--tmux)"
  elif [ -n "$have_herdr" ]; then
    mode=herdr
  elif [ -n "$tmux_ok" ]; then
    mode=tmux
    say "herdr not found, setting Waycar up for tmux"
  elif [ -n "$have_core" ]; then
    mode=tmux
    say "herdr not found, setting Waycar up for herdr-core $core_version"
  elif [ -n "$zellij_ok" ]; then
    mode=tmux
    say "herdr not found, setting Waycar up for Zellij $zellij_version"
  elif [ -n "$have_tmux" ]; then
    die "herdr not found, and tmux ${tmux_version:-(unknown version)} is too old; install herdr (https://herdr.dev), herdr-core, tmux 3.2 or later, or Zellij 0.46 or later"
  else
    die "neither herdr, herdr-core, tmux 3.2+ nor Zellij 0.46+ found; install a supported runtime"
  fi

  if [ -z "$source_dir" ]; then
    command -v curl >/dev/null 2>&1 || die "curl not found"
    command -v tar >/dev/null 2>&1 || die "tar not found"
  fi

  # The package is unpacked beside the install directory: the same file
  # system, so the swap below is a rename, and one that allows running the
  # binary when the install directory does (/tmp may be mounted noexec).
  parent=$(dirname "$dest")
  mkdir -p "$parent" || die "cannot create $parent"
  rm -rf "$parent"/.waycar-install.* "$dest.new"
  work=$(mktemp -d "$parent/.waycar-install.XXXXXX") || die "cannot create a staging directory in $parent"
  swapping=
  trap cleanup EXIT
  trap 'exit 1' HUP INT TERM

  if [ -n "$source_dir" ]; then
    copy_local_source
  else
    download_package
  fi
  [ -f "$work/waycar/herdr-plugin.toml" ] || die "package is missing herdr-plugin.toml"
  [ -f "$work/waycar/bin/waycar" ] || die "package is missing bin/waycar"

  # The state of an existing install, before it is replaced.
  node_era=
  if [ -n "$had_install" ] && [ -e "$dest/bin/node.sh" ]; then node_era=1; fi

  stage_package
  swap_in_package
  verify_installed

  # Agent hook entries written by the Node version call a script that is gone;
  # every agent event fails until they are rewritten. Run this before any step
  # that can fail or be cut off (herdr link, CLI link), and under --no-hooks too.
  migrate_node_era_hooks
  if [ -n "$node_era" ]; then
    say "moved this Host from the Node version to the native Host Tools"
  fi
  remove_node_leftovers
  report_old_node_processes

  if [ "$mode" = herdr ]; then
    link_herdr_plugin
    say "installed Waycar plugin $version"
  else
    say "installed Waycar $version in $dest"
  fi

  waycar_cmd="$dest/bin/waycar"
  if [ "$mode" = tmux ] || [ -n "$tmux_ok" ] || [ -n "$have_core" ] || [ -n "$zellij_ok" ]; then
    link_cli
  fi

  if [ -n "$hooks" ]; then
    if [ -n "$tmux_ok" ] || [ -n "$have_core" ] || [ -n "$zellij_ok" ]; then
      install_hooks
    fi
    install_chat_prompt_extension opencode
    install_chat_prompt_extension kilo
  else
    # The Node version's Chat Prompt extension loaded a script that is gone.
    install_chat_prompt_extension opencode node-era
    install_chat_prompt_extension kilo node-era
    if [ -n "$tmux_ok" ] || [ -n "$have_core" ] || [ -n "$zellij_ok" ]; then
      say "skipped the agent status hooks and the opencode and kilo Chat Prompt extensions (--no-hooks); add them later: $waycar_cmd hooks install"
    elif [ "$mode" = tmux ]; then
      say "tmux 3.2+, herdr-core or Zellij 0.46+ not found; agent status hooks not installed"
    fi
  fi

  print_reach_status "$dest"

  if [ "$mode" = herdr ]; then
    offer_pairing
  else
    offer_tmux_pairing
  fi
}

# Runs on every exit. A signal that arrives inside the swap puts the old
# install back; a SIGKILL there is repaired by the next run
# (recover_interrupted_update).
cleanup() {
  if [ -n "${swapping:-}" ] && [ ! -e "$dest" ] && [ -e "$dest.old" ]; then
    mv "$dest.old" "$dest" 2>/dev/null || true
  fi
  rm -rf "$work"
}

# A swap is two renames, so a process killed between them leaves no install
# directory and the old one next to it: put the old one back.
recover_interrupted_update() {
  if [ ! -e "$dest" ] && [ -d "$dest.old" ]; then
    mv "$dest.old" "$dest" && say "restored $dest, which an interrupted update had set aside"
  fi
}

# The staged package must run here before it replaces anything. A package
# that cannot run (a noexec mount, a kernel the binary does not support, a
# truncated file) stops the script with the old install exactly as it was.
stage_package() {
  rm -rf "$dest.new"
  mv "$work/waycar" "$dest.new" || die "cannot stage the package in $dest.new"
  chmod 755 "$dest.new/bin/waycar" 2>/dev/null || true
  if stage_output=$("$dest.new/bin/waycar" version </dev/null 2>&1); then
    case "$stage_output" in
      "waycar $version") return 0 ;;
    esac
    rm -rf "$dest.new"
    die "the package is inconsistent: $dest.new/bin/waycar says \"$stage_output\", expected \"waycar $version\"; $(kept_message)"
  fi
  rm -rf "$dest.new"
  die "the new Host Tools do not run on this computer ($(printf '%s' "$stage_output" | head -n 1)); is $parent mounted noexec? $(kept_message)"
}

kept_message() {
  if [ -n "$had_install" ]; then
    printf 'the existing install in %s is untouched' "$dest"
  else
    printf 'nothing was installed'
  fi
}

# Swap the directory in place; a link to $dest stays valid across updates.
swap_in_package() {
  rm -rf "$dest.old"
  swapping=1
  if [ -e "$dest" ]; then mv "$dest" "$dest.old"; fi
  mv "$dest.new" "$dest"
  swapping=
}

# The installed package must answer `waycar status --json`. When it does not,
# the old install goes back; the old one is deleted only after this passes.
verify_installed() {
  if status_output=$("$dest/bin/waycar" status --json </dev/null 2>&1); then
    rm -rf "$dest.old"
    return 0
  fi
  reason=$(printf '%s' "$status_output" | head -n 1)
  if [ -d "$dest.old" ]; then
    rm -rf "$dest"
    mv "$dest.old" "$dest"
    die "the new Host Tools failed \`waycar status --json\` after the swap (${reason:-no output}); the previous install is back in place"
  fi
  rm -rf "$dest"
  die "the new Host Tools failed \`waycar status --json\` after install (${reason:-no output}); nothing was installed"
}

# Waycar's own Node leftovers: the version cache of bin/node.sh and its record
# of features that were off for want of Node. The user's own Node, npm, nvm
# and Homebrew are never touched.
remove_node_leftovers() {
  cache_home=${XDG_CACHE_HOME:-}
  case "$cache_home" in /*) ;; *) cache_home=$HOME/.cache ;; esac
  state_home=${XDG_STATE_HOME:-}
  case "$state_home" in /*) ;; *) state_home=$HOME/.local/state ;; esac
  rm -rf "$cache_home/waycar/node-versions" "$state_home/waycar/bridge-off"
  rmdir "$cache_home/waycar" 2>/dev/null || true
}

# Node processes the old version started (a Mirror bridge, a plan-step tick)
# keep running on files that are gone until they end or herdr restarts. Count
# them and say so; kill nothing.
report_old_node_processes() {
  [ -n "$node_era" ] || return 0
  if [ -d /proc/self ]; then
    count=$(for f in /proc/[0-9]*/cmdline; do tr '\0' ' ' <"$f" 2>/dev/null; echo; done \
      | grep -cE 'src/(sidebar-hook|notify-hook|activity-hook|activity-tick|hook-session|approval-watch|mirror|waycar-cli)\.js|bin/node\.sh' || true)
  else
    count=$(ps -ww -A -o args= 2>/dev/null \
      | grep -cE 'src/(sidebar-hook|notify-hook|activity-hook|activity-tick|hook-session|approval-watch|mirror|waycar-cli)\.js|bin/node\.sh' || true)
  fi
  case "$count" in "" | 0 | *[!0-9]*) return 0 ;; esac
  say "$count Node process(es) from the old version are still running on files that are gone (herdr's hooks, a Mirror bridge). They stop when herdr restarts. Nothing was killed."
}

# Rewrite the agents' hook entries that call the Node version's node.sh. A
# Codex entry changes its trust hash, which `waycar hooks migrate` reports.
migrate_node_era_hooks() {
  migrated=$("$dest/bin/waycar" hooks migrate </dev/null 2>&1) || {
    say "warning: could not check the agent hooks for Node-era entries ($(printf '%s' "$migrated" | head -n 1)); run: $dest/bin/waycar hooks migrate"
    return 0
  }
  [ -n "$migrated" ] || return 0
  printf '%s\n' "$migrated"
  if [ -z "$hooks" ]; then
    say "--no-hooks does not skip that: the old entries called a script this version no longer has"
  fi
}

# Sets have_herdr, have_tmux, tmux_version and tmux_ok (tmux 3.2 or later),
# and have_core and core_version (herdr-core, see find_core).
detect_backends() {
  have_herdr=
  command -v herdr >/dev/null 2>&1 && have_herdr=1
  find_core
  find_zellij
  have_tmux=
  tmux_version=
  tmux_ok=
  if command -v tmux >/dev/null 2>&1; then
    have_tmux=1
    tmux_version=$(tmux -V </dev/null 2>/dev/null | sed -n 's/^tmux \([^ ]*\).*/\1/p' | head -n 1) || tmux_version=
    if tmux_supported "$tmux_version"; then tmux_ok=1; fi
  fi
  return 0
}

# Sets have_core and core_version when herdr-core is installed: `herdr-core`,
# then `hc`, on PATH and in the directories core's installer and package
# managers use (PATH is often without ~/.local/bin over SSH). A binary counts
# only when `--version` prints `hc <digits>` (herbstclient's `hc` does not).
# Nothing else is ever run: every other subcommand starts a core.
find_core() {
  have_core=
  core_version=
  mise_shims="${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims"
  for core_name in herdr-core hc; do
    core_candidates=$(command -v "$core_name" 2>/dev/null) || core_candidates=
    for core_dir in "$HOME/.local/bin" /opt/homebrew/bin /usr/local/bin "$mise_shims" "$HOME/.nix-profile/bin" /run/current-system/sw/bin "$HOME/.cargo/bin"; do
      core_candidates="$core_candidates
$core_dir/$core_name"
    done
    while IFS= read -r core_bin; do
      [ -n "$core_bin" ] && [ -x "$core_bin" ] && [ ! -d "$core_bin" ] || continue
      core_version=$("$core_bin" --version </dev/null 2>/dev/null | sed -n '1s/^hc[[:space:]][[:space:]]*\([0-9][^[:space:]]*\).*/\1/p') || core_version=
      if [ -n "$core_version" ]; then
        have_core=1
        return 0
      fi
    done <<EOF
$core_candidates
EOF
  done
  core_version=
  return 0
}

# Detection runs only --version: never attach or a bare zellij invocation.
find_zellij() {
  zellij_ok=
  zellij_version=
  zellij_candidates=$(command -v zellij 2>/dev/null) || zellij_candidates=
  for zellij_dir in "$HOME/.local/bin" "$HOME/.cargo/bin" /opt/homebrew/bin /usr/local/bin "$HOME/.nix-profile/bin" /nix/var/nix/profiles/default/bin /run/current-system/sw/bin; do
    zellij_candidates="$zellij_candidates
$zellij_dir/zellij"
  done
  while IFS= read -r zellij_bin; do
    [ -n "$zellij_bin" ] && [ -x "$zellij_bin" ] && [ ! -d "$zellij_bin" ] || continue
    zellij_version=$("$zellij_bin" --version </dev/null 2>/dev/null | sed -n '1s/^zellij \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p') || zellij_version=
    [ -n "$zellij_version" ] || continue
    zellij_major=${zellij_version%%.*}
    zellij_rest=${zellij_version#*.}
    zellij_minor=${zellij_rest%%.*}
    if [ "$zellij_major" -gt 0 ] || [ "$zellij_minor" -ge 46 ]; then
      zellij_ok=1
      return 0
    fi
  done <<EOF
$zellij_candidates
EOF
  return 0
}

# `tmux -V` versions: 3.2a, 3.7c, next-3.6, openbsd-7.4 (OpenBSD's base tmux,
# newer than 3.2), master (a source build).
tmux_supported() {
  case "$1" in
    openbsd-* | master) return 0 ;;
  esac
  v=${1#next-}
  major=$(printf '%s' "$v" | sed -n 's/^\([0-9][0-9]*\)\..*/\1/p')
  minor=$(printf '%s' "$v" | sed -n 's/^[0-9][0-9]*\.\([0-9][0-9]*\).*/\1/p')
  [ -n "$major" ] && [ -n "$minor" ] || return 1
  [ "$major" -gt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -ge 2 ]; }
}

# How the phone reaches this computer from away: print whether Tailscale is
# here, then the one option that needs nothing on this computer. It only
# reads this machine's interface addresses and PATH, installs and changes
# nothing, and never fails the run: a missing or broken probe prints nothing.
# The wording lives in `waycar reach-status`, which the pairing popup's address
# rules also feed, so the two agree on what counts as Tailscale.
# $1: the plugin directory.
print_reach_status() {
  reach_cli=
  if command -v tailscale >/dev/null 2>&1 || [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
    reach_cli=--tailscale-cli
  fi
  # shellcheck disable=SC2086 # empty or one flag
  "$1/bin/waycar" reach-status $reach_cli </dev/null 2>/dev/null \
    | while IFS= read -r line; do say "$line"; done
}

# The package URL, with the properties its download event carries. waycar.dev
# counts the download (plugin_package_downloaded) as an anonymous event, and
# these fixed values say what kind of run it is: `via` is install, or pair for
# a pair-only run that installs nothing; `kind` is update when a plugin was
# already here, else install. WAYCAR_INTERNAL, set by our own automation,
# adds `internal=1` so those runs stay out of the customer counts. Nothing
# else is added, and a base URL that is not http(s) (a file:// copy, a test
# server path) gets a plain URL.
package_url() {
  url="$base_url/plugin/$tarball"
  case "$base_url" in
    http://* | https://*)
      if [ -n "$pair_only" ]; then
        query='via=pair'
      elif [ -n "$had_install" ]; then
        query='via=install&kind=update'
      else
        query='via=install&kind=install'
      fi
      if [ -n "${WAYCAR_INTERNAL:-}" ]; then query="$query&internal=1"; fi
      url="$url?$query"
      ;;
  esac
  printf '%s' "$url"
}

# Sets target, tarball and sha256 for this computer. Only the download path
# needs it; a WAYCAR_PLUGIN_SOURCE install never calls uname.
select_package() {
  os=$(uname -s)
  arch=$(uname -m)
  case "$os" in
    Linux)
      case "$arch" in
        x86_64 | amd64) key=x86_64_linux; target=x86_64-unknown-linux-musl ;;
        aarch64 | arm64) key=aarch64_linux; target=aarch64-unknown-linux-musl ;;
        *) unsupported_platform ;;
      esac
      ;;
    Darwin)
      # A shell running under Rosetta reports x86_64 on an Apple silicon Mac;
      # the arm64 build is the native one there.
      if [ "$arch" = x86_64 ] && [ "$(sysctl -n hw.optional.arm64 2>/dev/null || true)" = 1 ]; then
        arch=arm64
      fi
      case "$arch" in
        arm64 | aarch64) key=aarch64_darwin; target=aarch64-apple-darwin ;;
        x86_64) key=x86_64_darwin; target=x86_64-apple-darwin ;;
        *) unsupported_platform ;;
      esac
      ;;
    *) unsupported_platform ;;
  esac
  eval "tarball=\$tarball_$key; sha256=\$sha256_$key"
}

unsupported_platform() {
  die "unsupported platform $os $arch; Waycar supports x86_64-unknown-linux-musl, aarch64-unknown-linux-musl, aarch64-apple-darwin and x86_64-apple-darwin"
}

download_package() {
  select_package
  say "downloading plugin $version for $target"
  curl -fsSL "$(package_url)" -o "$work/$tarball" || die "download failed: $base_url/plugin/$tarball"

  if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$work/$tarball" | cut -d ' ' -f 1)
  elif command -v shasum >/dev/null 2>&1; then
    got=$(shasum -a 256 "$work/$tarball" | cut -d ' ' -f 1)
  else
    die "sha256sum or shasum required to verify the download"
  fi
  [ "$got" = "$sha256" ] || die "checksum mismatch for $tarball (expected $sha256, got $got)"

  tar -C "$work" -xzf "$work/$tarball"
}

# WAYCAR_PLUGIN_SOURCE: copy a local plugin directory instead of downloading.
copy_local_source() {
  source_dir=$(cd "$source_dir" 2>/dev/null && pwd -P) \
    || die "WAYCAR_PLUGIN_SOURCE is not a directory: $WAYCAR_PLUGIN_SOURCE"
  grep -qx 'id = "waycar"' "$source_dir/herdr-plugin.toml" 2>/dev/null \
    || die "$source_dir is not the Waycar plugin (no herdr-plugin.toml with id \"waycar\")"
  version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$source_dir/herdr-plugin.toml" | head -n 1)
  say "installing plugin $version from $source_dir"
  mkdir "$work/waycar"
  cp -R "$source_dir/." "$work/waycar/"
  # A checkout's build output is not part of the package.
  rm -rf "$work/waycar/target"
  [ -f "$work/waycar/bin/waycar" ] \
    || die "$source_dir has no bin/waycar; build it (cargo build --release in plugin/) and copy target/release/waycar there"
}

link_herdr_plugin() {
  real_dest=$(cd "$dest" && pwd -P)
  plugins=$(herdr plugin list </dev/null 2>/dev/null || true)

  existing=$(printf '%s\n' "$plugins" | grep '^- waycar ' || true)
  case "$existing" in
    *"[local:$dest]"* | *"[local:$real_dest]"*)
      say "updated linked plugin in $dest"
      ;;
    "")
      herdr plugin link "$dest" </dev/null >/dev/null || die "herdr plugin link failed"
      say "linked plugin from $dest"
      ;;
    *) replace_existing ;;
  esac
}

# Link ~/.local/bin/waycar to the installed launcher. A file there that is not
# a link is someone else's: leave it and use the full path.
link_cli() {
  bin_dir="$HOME/.local/bin"
  link="$bin_dir/waycar"
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    say "$link exists and is not a link; leaving it (run $dest/bin/waycar instead)"
    return
  fi
  mkdir -p "$bin_dir"
  rm -f "$link"
  ln -s "$dest/bin/waycar" "$link"
  say "linked $link -> $dest/bin/waycar"
  case ":$PATH:" in
    *":$bin_dir:"*) waycar_cmd=waycar ;;
    *) say "add $bin_dir to your PATH to run waycar" ;;
  esac
}

# `waycar hooks install` prints the files it changed and Codex's one-time
# /hooks review step. A failure leaves the plugin installed.
install_hooks() {
  say "installing agent status hooks"
  if ! "$dest/bin/waycar" hooks install </dev/null; then
    say "warning: agent status hooks were not installed; retry: $waycar_cmd hooks install"
  fi
}

# The opencode and kilo Chat Prompt extension (ADR 0025; kilo is an opencode
# fork and loads the same file) rides the plugin on every host with that
# agent, herdr or tmux: unlike the Status Hooks it does not depend on the
# tmux 3.2+ gate. `waycar hooks install` installs the same file on tmux
# hosts, so an already-current copy is left as it is, and a file that is not
# ours is never overwritten, like the other extension files. The plugin root
# goes where `hooks install` puts it: the template's
# `"__WAYCAR_PLUGIN_ROOT__"` placeholder becomes the quoted install dir.
# $1: opencode or kilo, the command and its config dir name.
# $2 (node-era): only replace a copy the Node version installed, which loaded
# a script that no longer exists (used under --no-hooks).
install_chat_prompt_extension() {
  command -v "$1" >/dev/null 2>&1 || return 0
  oc_plugins="${XDG_CONFIG_HOME:-$HOME/.config}/$1/plugins"
  target="$oc_plugins/waycar-chat-prompt.js"
  if [ "${2:-}" = node-era ]; then
    grep -q 'installed by waycar' "$target" 2>/dev/null \
      && grep -q 'host-config.js' "$target" 2>/dev/null || return 0
  fi
  escaped=$(printf '%s' "$dest" | sed 's/[\\&@]/\\&/g')
  sed "s@\"__WAYCAR_PLUGIN_ROOT__\"@\"$escaped\"@g" \
    "$dest/hooks/opencode/waycar-chat-prompt.js" >"$work/chat-prompt.js"
  # Command substitution drops trailing newlines on both sides, so two
  # copies differing only in those compare equal here; anything else keeps
  # a rewritten, byte-identical file. Avoided cmp: it lives in diffutils,
  # which minimal hosts need not have.
  if [ -f "$target" ] \
    && [ "$(cat "$work/chat-prompt.js" 2>/dev/null)" = "$(cat "$target" 2>/dev/null)" ]; then
    return 0
  fi
  if [ -f "$target" ] && ! grep -q 'installed by waycar' "$target"; then
    say "$target exists and was not installed by Waycar; left unchanged"
    return 0
  fi
  mkdir -p "$oc_plugins"
  mv "$work/chat-prompt.js" "$target"
  say "installed the $1 Chat Prompt extension in $oc_plugins"
}

# First run: offer to pair without installing anything. A machine the user
# may not install software on can still pair: the plugin is downloaded to a
# temporary directory, `waycar pair` runs from it, and the directory is
# deleted again. Pairing needs neither herdr nor tmux.
# The question reads /dev/tty, not stdin (`curl | sh` feeds the script the
# pipe), so it only appears with a terminal. Without one, when updating an
# existing install, for WAYCAR_PLUGIN_SOURCE runs (a developer checkout),
# and with WAYCAR_NO_PAIR set, the script installs as it always did.
ask_install_or_pair() {
  if [ -n "$had_install" ] || [ -n "$source_dir" ] || [ -n "${WAYCAR_NO_PAIR:-}" ]; then
    return 0
  fi
  if ! { true </dev/tty; } 2>/dev/null; then
    return 0
  fi
  {
    printf 'waycar: install the host tools, or pair this computer only?\n'
    printf 'waycar:   1) install (default)\n'
    printf 'waycar:   2) pair only, installing nothing\n'
  } >/dev/tty
  while true; do
    printf 'waycar: choose [1/2]: ' >/dev/tty
    answer=
    read -r answer </dev/tty || die 'cancelled; nothing was installed'
    case "$answer" in
      "" | 1 | i | I | install) return 0 ;;
      2 | p | P | pair | pair-only) pair_only=1; return 0 ;;
      *) printf 'waycar: choose 1 to install or 2 to pair only\n' >/dev/tty ;;
    esac
  done
}

# Pair without installing: download (or copy) the package into a temporary
# directory, run `waycar pair` from it, and leave nothing behind except the
# Device Key line `waycar pair-accept` appends to ~/.ssh/authorized_keys. The
# pairing session's pending and Enrollment records go to a state directory
# inside the temporary one (`waycar pair` takes HERDR_PLUGIN_STATE_DIR before
# the resolved state dir), so the only lasting change is that one
# authorized_keys line.
pair_only_main() {
  if ! { true </dev/tty; } 2>/dev/null; then
    die "pair-only needs an interactive terminal (it shows a Pairing Code QR); run it in a terminal"
  fi
  say "pairing only; nothing will be installed"
  if [ -z "$source_dir" ]; then
    command -v curl >/dev/null 2>&1 || die "curl not found"
    command -v tar >/dev/null 2>&1 || die "tar not found"
  fi

  work=$(mktemp -d)
  trap 'rm -rf "$work"' EXIT

  if [ -n "$source_dir" ]; then
    copy_local_source
  else
    download_package
  fi
  [ -f "$work/waycar/herdr-plugin.toml" ] || die "package is missing herdr-plugin.toml"

  [ -f "$work/waycar/bin/waycar" ] || die "package is missing bin/waycar"
  chmod 755 "$work/waycar/bin/waycar" 2>/dev/null || true
  # The binary runs from the temporary directory: some computers mount /tmp
  # noexec. TMPDIR picks another place.
  if ! pair_output=$("$work/waycar/bin/waycar" version </dev/null 2>&1); then
    die "the Host Tools do not run from $work ($(printf '%s' "$pair_output" | head -n 1)); is that directory mounted noexec? Set TMPDIR to a directory that allows running programs and run this again"
  fi

  print_reach_status "$work/waycar"

  # Exit 0 covers both outcomes (enrolled, or the user quit the QR screen);
  # the Pairing Code screen itself shows whether a device enrolled, so the
  # script stays neutral about it.
  if HERDR_PLUGIN_STATE_DIR="$work/state" "$work/waycar/bin/waycar" pair </dev/tty >/dev/tty 2>&1; then
    say "pairing screen closed; nothing was installed; add the host tools later with the install command"
  else
    say "pairing did not finish; run the install command again and choose pair only"
  fi
}

# Offer to draw the pairing QR in this terminal on every run, so running the
# install command again is how you pair another device. `curl | sh` gives
# the script no stdin, so ask on the terminal; with none, print the command.
# The same works on a herdr Host: `waycar pair` resolves the plugin's config
# and state dirs from herdr (`herdr plugin list --json`, `config-dir`), so it
# needs no herdr action invocation, whose JSON reply would only clutter the
# terminal and whose popup opens in herdr's window, not where the user typed.
offer_pairing() {
  pair_cmd="$waycar_cmd pair"
  if [ -z "${WAYCAR_NO_PAIR:-}" ] && { true </dev/tty; } 2>/dev/null; then
    printf 'waycar: show a pairing QR code now? [Y/n] ' >/dev/tty
    answer=
    read -r answer </dev/tty || answer=n
    case "$answer" in
      "" | [Yy]*)
        if "$dest/bin/waycar" pair </dev/tty >/dev/tty 2>&1; then
          say "pair another device any time: $pair_cmd"
        else
          say "pairing did not finish; run: $pair_cmd"
        fi
        return
        ;;
    esac
  fi
  say "pair a device: $pair_cmd"
}

# tmux mode: the same offer, with `waycar pair` drawing the QR in this
# terminal. The tmux key binding is printed, never installed.
offer_tmux_pairing() {
  pair_cmd="$waycar_cmd pair"
  if [ -z "${WAYCAR_NO_PAIR:-}" ] && { true </dev/tty; } 2>/dev/null; then
    printf 'waycar: show a pairing QR code now? [Y/n] ' >/dev/tty
    answer=
    read -r answer </dev/tty || answer=n
    case "$answer" in
      "" | [Yy]*)
        if "$dest/bin/waycar" pair </dev/tty >/dev/tty 2>&1; then
          say "pair another device any time: $pair_cmd"
        else
          say "pairing did not finish; run: $pair_cmd"
        fi
        print_tmux_binding
        return
        ;;
    esac
  fi
  say "pair a device: $pair_cmd"
  print_tmux_binding
}

print_tmux_binding() {
  [ -n "$have_tmux" ] || return 0
  say "optional tmux key for pairing (add to ~/.tmux.conf): bind W display-popup -E \"$waycar_cmd pair\""
}

# Replace a `waycar` install linked from another path.
# herdr keeps the plugin's config dir across uninstall.
replace_existing() {
  say "replacing existing waycar plugin"
  herdr plugin uninstall waycar </dev/null >/dev/null 2>&1 \
    || herdr plugin unlink waycar </dev/null >/dev/null 2>&1 \
    || die "could not remove the existing waycar plugin"
  herdr plugin link "$dest" </dev/null >/dev/null || die "herdr plugin link failed"
  say "linked plugin from $dest"
}

main "$@"
