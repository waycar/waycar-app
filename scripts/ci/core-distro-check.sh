#!/bin/bash
#
# Checks Waycar's Host Tools (plugin/) on a Host that runs herdr-core, the way
# a user on that distribution installs them.
#
#   WAYCAR_NATIVE_BIN=<waycar> scripts/ci/core-distro-check.sh
#
# Run it as root inside a throwaway container (.github/workflows/core-distros.yml
# runs it in ubuntu:24.04, debian:12 and fedora:latest, and in ubuntu:24.04 with
# tmux too). It changes the machine: it installs packages and a user, so never
# run it on a real host.
#
# WAYCAR_NATIVE_BIN is a static `waycar` for this machine's CPU (a musl build
# from scripts/build-plugin-binaries.sh). The Host Tools need nothing else: no
# Node anywhere. As root the script installs curl, tar, procps (the hook asks
# `ps` for a tty when it can) and Python 3 for the test's own tools: the
# stand-in relay (scripts/ci/relay-standin.py) and reading the hook entries out
# of ~/.claude/settings.json. With WAYCAR_CI_WITH_TMUX=1 it also installs the
# distribution's tmux (3.2 or later). Without it the container is a core-only
# Host: no herdr, no tmux. Then, as a fresh non-root user with a clean,
# non-interactive environment (no TMUX, TMUX_PANE, HERDR_ENV, HERDR_PANE_ID, no
# HC_*, `~/.local/bin` not on PATH), it:
#
#   1. installs herdr-core with its own installer
#      (https://releases.herdr.dev/core/install.sh, at the version
#      scripts/ci/core-contract.py pins), assembles the package the way
#      scripts/package-plugin.sh does and runs `sh install.sh` from it as a
#      Claude Code user (~/.claude exists), with no flag: the installer must find
#      core in `~/.local/bin` by itself. It checks `waycar status --json`
#      reports this core (and tmux when installed, never herdr) and `waycar hooks
#      status --json` reports the Claude hooks;
#   2. starts a core terminal whose program is a fake agent that prints OSC 7501
#      (what a real agent does) and runs the installed Claude hook commands from
#      ~/.claude/settings.json through `sh -c` with CLAUDECODE=1, the way Claude
#      Code does. Each step checks the terminal's labels (`herdr-core get`) and
#      a Blocked and a Done step must each send a push for pane `hc:<address>`
#      to a local stand-in for the relay (the push's collapse id is a digest of
#      the pane id, checked here). A hook run from outside any terminal, and one
#      that names the terminal but runs on another tty, must change nothing and
#      print nothing;
#   3. with tmux, the core is first started from inside a tmux pane, so every
#      core terminal inherits that pane's TMUX_PANE (the stale environment a
#      core started in a pane hands out); the same pane then runs a second fake
#      agent as a real tmux agent. Each agent's hooks must push once per Blocked
#      and Done, for its own pane id and no other.
#
# The checkout is the repository holding this script. It is only read.

set -euo pipefail

ci_user=wc
step() { printf '\n==> %s\n' "$*"; }
die() { printf 'core-distro-check: error: %s\n' "$*" >&2; exit 1; }

tmux_at_least_3_2() {
    case $1 in
        next-*) return 0 ;;
    esac
    local major=${1%%.*} rest=${1#*.} minor
    minor=${rest//[!0-9]*/}
    case $major in '' | *[!0-9]*) return 1 ;; esac
    [ "$major" -gt 3 ] || { [ "$major" -eq 3 ] && [ "${minor:-0}" -ge 2 ]; }
}

# ---------------------------------------------------------------- root phase

install_packages() {
    local packages_apt="curl ca-certificates tar procps python3"
    local packages_dnf="curl ca-certificates tar procps-ng python3 util-linux shadow-utils"
    if [ "${WAYCAR_CI_WITH_TMUX:-}" = 1 ]; then
        packages_apt="$packages_apt tmux"
        packages_dnf="$packages_dnf tmux"
    fi
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        # shellcheck disable=SC2086
        apt-get install -y -qq --no-install-recommends $packages_apt >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        # curl-minimal ships on fedora and rocky; `curl` conflicts with it.
        # shellcheck disable=SC2086
        dnf install -y -q --allowerasing $packages_dnf >/dev/null
    else
        die "no apt-get or dnf: unsupported distribution"
    fi
}

root_phase() {
    [ "$(id -u)" -eq 0 ] || die "run as root in a throwaway container"
    local script repo
    script=$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
    repo=$(cd "$(dirname "$script")/../.." && pwd -P)
    [ -f "$repo/plugin/install.sh" ] || die "$repo has no plugin/install.sh"
    [ -n "${WAYCAR_NATIVE_BIN:-}" ] || die "WAYCAR_NATIVE_BIN is not set (a static waycar for this CPU)"
    [ -x "$WAYCAR_NATIVE_BIN" ] || die "WAYCAR_NATIVE_BIN $WAYCAR_NATIVE_BIN is not an executable file"

    . /etc/os-release
    local distro="$PRETTY_NAME"

    step "installing the test tools on $distro"
    install_packages
    command -v ps >/dev/null || die "ps not installed"
    for tool in node nodejs npm herdr; do
        if command -v "$tool" >/dev/null 2>&1; then die "$tool is installed ($(command -v "$tool")); this container must be a core Host with no Node"; fi
    done

    local tmux_version=""
    if [ "${WAYCAR_CI_WITH_TMUX:-}" = 1 ]; then
        tmux_version=$(tmux -V | sed -n 's/^tmux \([^ ]*\).*/\1/p')
        tmux_at_least_3_2 "$tmux_version" || die "$distro ships tmux ${tmux_version:-?}, older than 3.2"
    else
        ! command -v tmux >/dev/null 2>&1 || die "tmux is installed in a core-only container"
    fi

    local pin
    pin=$(python3 "$repo/scripts/ci/core-contract.py" --print-pin)
    local summary="$distro: herdr-core $pin, tmux ${tmux_version:-none}, no Node"
    echo "$summary"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "- $summary" >>"$GITHUB_STEP_SUMMARY"
    fi

    # bash, as most users have: tmux runs a string command through the default
    # shell, and Debian's dash would stay the pane's process-group leader.
    id "$ci_user" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ci_user"
    # The user phase cannot read the job's workspace in every container.
    install -D -m 755 "$WAYCAR_NATIVE_BIN" /opt/waycar-native/waycar
    local home
    home=$(getent passwd "$ci_user" | cut -d : -f 6)

    # A clean login-like environment: nothing from the job (TMUX, TMUX_PANE,
    # HERDR_*, HC_*, CI variables) reaches the user phase, and `~/.local/bin`,
    # where core's installer puts herdr-core, is not on PATH: the Host Tools
    # must find it there themselves, as they must under an SSH exec or a hook.
    runuser -u "$ci_user" -- env -i \
        HOME="$home" USER="$ci_user" LOGNAME="$ci_user" SHELL=/bin/bash \
        PATH="/usr/local/bin:/usr/bin:/bin" \
        WAYCAR_CI_CORE_VERSION="$pin" WAYCAR_CI_TMUX_VERSION="$tmux_version" \
        WAYCAR_NATIVE_BIN=/opt/waycar-native/waycar \
        bash "$script" --user-phase "$repo"
    echo
    echo "PASS $summary"
}

# ---------------------------------------------------------------- user phase

# The package a user downloads, assembled from the checkout and the native
# binary (scripts/package-plugin.sh stages the same files).
assemble_package() {
    local repo=$1 dest=$2
    rm -rf "$dest"
    mkdir -p "$dest/bin" "$dest/test-vectors"
    cp "$repo/plugin/bin/waycar-hook" "$dest/bin/"
    cp -R "$repo/plugin/hooks" "$repo/plugin/README.md" "$repo/plugin/LICENSE" "$repo/plugin/NOTICE" \
        "$repo/plugin/THIRD-PARTY-LICENSES" "$repo/plugin/herdr-plugin.toml" "$dest/"
    cp "$repo/plugin/test-vectors/tmux-pane-options-v1.json" "$dest/test-vectors/"
    install -m 755 "$WAYCAR_NATIVE_BIN" "$dest/bin/waycar"
    chmod 755 "$dest/bin/waycar-hook"
}

# Reads one hook command out of ~/.claude/settings.json: the one that runs
# waycar-hook for an event (and Notification matcher).
hook_command() {
    python3 - "$@" <<'PY'
import json, os, sys
settings = json.load(open(os.path.expanduser("~/.claude/settings.json")))
event = sys.argv[1]
matcher = sys.argv[2] if len(sys.argv) > 2 else None
for group in settings["hooks"][event]:
    if matcher is not None and group.get("matcher") != matcher:
        continue
    for hook in group["hooks"]:
        if "/bin/waycar-hook" in hook["command"]:
            sys.stdout.write(hook["command"])
            sys.exit(0)
sys.exit("no waycar-hook command for " + event)
PY
}

core_bin() { printf '%s' "$HOME/.local/bin/herdr-core"; }

# Whether a core process of this user runs (a zombie left by an earlier core
# does not). Never `herdr-core server status`: every subcommand but --version
# starts a core when none listens.
core_running() {
    ps -u "$(id -u)" -o stat=,comm= | grep -Eq '^[^Z[:space:]][^[:space:]]*[[:space:]]+(herdr-core|hc)$'
}

# Core's own installer, pinned to the version the contract check pins.
install_core() {
    step "installing herdr-core $WAYCAR_CI_CORE_VERSION with its own installer"
    curl -fsSL https://releases.herdr.dev/core/install.sh | HC_VERSION="$WAYCAR_CI_CORE_VERSION" sh
    [ "$("$(core_bin)" --version)" = "hc $WAYCAR_CI_CORE_VERSION" ] ||
        die "herdr-core --version is '$("$(core_bin)" --version)', want 'hc $WAYCAR_CI_CORE_VERSION'"
    # Detecting must not start a core: nothing listens yet.
    ! core_running || die "a core is running before the test started one"
}

check_install() {
    local repo=$1 source="$HOME/waycar-package" status hooks leftover out
    step "assembling the package in $source"
    assemble_package "$repo" "$source"
    step "install.sh, no flag, on a core Host (herdr-core is in ~/.local/bin, which is not on PATH)"
    # A Claude Code user: hooks install only into agents it finds.
    mkdir -p "$HOME/.claude"
    out=$(WAYCAR_PLUGIN_SOURCE="$source" WAYCAR_NO_PAIR=1 sh "$repo/plugin/install.sh" </dev/null 2>&1) ||
        { echo "$out"; die "install.sh failed on a core Host"; }
    echo "$out"
    [ -L "$HOME/.local/bin/waycar" ] || die "~/.local/bin/waycar was not linked"
    for leftover in bin/node.sh src node_modules package.json package-lock.json; do
        [ ! -e "$HOME/.local/share/waycar/plugin/$leftover" ] || die "the install has $leftover"
    done
    # The installer must not have started a core.
    ! core_running || die "install.sh started a core"

    status=$("$HOME/.local/bin/waycar" status --json </dev/null)
    echo "status --json: $status"
    python3 -c '
import json, sys
j = json.loads(sys.argv[1])
core, tmux = sys.argv[2], sys.argv[3] or None
assert j["backends"]["core"] == core, j["backends"]
assert j["backends"]["tmux"] == tmux, j["backends"]
assert j["backends"]["herdr"] is False, j["backends"]
' "$status" "$WAYCAR_CI_CORE_VERSION" "$WAYCAR_CI_TMUX_VERSION" ||
        die "status --json does not report core $WAYCAR_CI_CORE_VERSION, tmux '${WAYCAR_CI_TMUX_VERSION:-none}' and no herdr"
    ! core_running || die "waycar status started a core"

    hooks=$("$HOME/.local/bin/waycar" hooks status --json </dev/null)
    echo "hooks status --json: $hooks"
    python3 -c '
import json, sys
j = json.loads(sys.argv[1])
assert [a for a in j["agents"] if a["agent"] == "claude"][0]["installed"] is True
' "$hooks" || die "hooks status --json does not report the Claude hooks installed"
    if grep -qi node "$HOME/.claude/settings.json"; then
        die "the Claude hook entries mention Node: $(grep -i node "$HOME/.claude/settings.json")"
    fi
}

# The fake agent: the terminal's own process, so its controlling tty is the
# terminal's. Each line the test writes to the FIFO is `<state>|<hook command>`:
# it prints that OSC 7501 report (`-` for none), as a real agent does when its
# state changes, then runs the hook command through `sh -c` with a JSON body on
# stdin and CLAUDECODE=1 (waycar-hook's `claude` requires it), as Claude Code
# runs hooks, then acks.
fake_agent_script='
fifo=$1 ack=$2 app=$3 n=0
# What the environment of this agent says about tmux (the test reads it back).
printf "%s" "${TMUX_PANE:-}" >"$fifo.pane"
while IFS= read -r line <"$fifo"; do
  [ "$line" = exit ] && exit 0
  state=${line%%|*}
  cmd=${line#*|}
  if [ "$state" != - ]; then
    printf "\033]7501;state=%s:app=%s\033\\" "$state" "$app"
    sleep 0.3
  fi
  if [ -n "$cmd" ]; then printf "{}" | CLAUDECODE=1 sh -c "$cmd"; fi
  n=$((n + 1))
  echo "$n" >"$ack"
done
'

# The stand-in relay (scripts/ci/relay-standin.py): it records every request
# and answers GET /requests with them, and writes its port to $1/port.
start_stand_in_relay() {
    local dir=$1 repo=$2 waited=0
    python3 "$repo/scripts/ci/relay-standin.py" --port-file "$dir/port" &
    relay_pid=$!
    until [ -s "$dir/port" ]; do
        sleep 0.1
        waited=$((waited + 1))
        [ "$waited" -lt 100 ] || die "the stand-in relay did not start"
    done
}

# Points the Host's push config at the stand-in relay.
configure_push() {
    local dir=$1
    mkdir -p "$HOME/.config/waycar"
    cat >"$HOME/.config/waycar/notify.json" <<JSON
{"relay_url":"http://127.0.0.1:$(cat "$dir/port")","debounce_ms":0,"activity_debounce_ms":0,"retry_delay_ms":0}
JSON
    cat >"$HOME/.config/waycar/notifications.json" <<'JSON'
{"v":1,"devices":[{"token":"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","env":"sandbox","notify":{"blocked":true,"done":true}}]}
JSON
}

# How many pushes the stand-in relay has received for a pane id: the push's
# collapse id is base64url(sha256(key + "HERDR-NOTIFY-COLLAPSE:" + pane)[:16])
# for the device's Notification Key (the counting key 0..31 above).
pushes_for() {
    python3 - "$1" "$2" <<'PY'
import base64, hashlib, json, sys, urllib.request
dir_, pane = sys.argv[1], sys.argv[2]
key = bytes(range(32))
want = base64.urlsafe_b64encode(hashlib.sha256(key + b"HERDR-NOTIFY-COLLAPSE:" + pane.encode()).digest()[:16]).rstrip(b"=").decode()
body = urllib.request.urlopen("http://127.0.0.1:%s/requests" % open(dir_ + "/port").read()).read().decode()
count = 0
for line in body.splitlines():
    record = json.loads(line)
    if record["url"] == "/push" and (record["body"] or {}).get("collapse") == want:
        count += 1
print(count)
PY
}

all_pushes() {
    python3 - "$1" <<'PY'
import sys, urllib.request
body = urllib.request.urlopen("http://127.0.0.1:%s/requests" % open(sys.argv[1] + "/port").read()).read().decode()
print(sum(1 for line in body.splitlines() if line.startswith('{"url":"/push"')))
PY
}

# One label of a core terminal ("" when unset).
core_label() {
    "$(core_bin)" get "$1" --json | python3 -c '
import json, sys
print(json.load(sys.stdin).get("labels", {}).get(sys.argv[1], ""))' "$2"
}

smoke() {
    local repo=$1 relay_pid="" sock=wc-ci core_addr
    local with_tmux=0
    [ -z "$WAYCAR_CI_TMUX_VERSION" ] || with_tmux=1
    step "core hook smoke (real herdr-core $WAYCAR_CI_CORE_VERSION$([ "$with_tmux" = 1 ] && echo ", real tmux $WAYCAR_CI_TMUX_VERSION, core started from a tmux pane"))"
    dir=$(mktemp -d /tmp/wc-ci-smoke.XXXXXX)
    printf '%s' "$fake_agent_script" >"$dir/agent.sh"
    mkfifo "$dir/fifo" "$dir/tfifo"
    : >"$dir/ack"
    : >"$dir/tack"
    t() { tmux -L "$sock" -f /dev/null "$@"; }
    # The servers, the stand-in relay and the scratch dir go on exit.
    trap '[ "$with_tmux" = 0 ] || t kill-server >/dev/null 2>&1 || true; "$(core_bin)" server stop >/dev/null 2>&1 || true; [ -z "${relay_pid:-}" ] || kill "$relay_pid" 2>/dev/null || true; rm -rf "$dir"' EXIT
    start_stand_in_relay "$dir" "$repo"
    configure_push "$dir"

    local start="$(core_bin) run --bg --name agent -- sh $dir/agent.sh $dir/fifo $dir/ack claude > $dir/run.json"
    local pane=""
    if [ "$with_tmux" = 1 ]; then
        # The pane starts the core (so its terminals inherit TMUX and
        # TMUX_PANE), then becomes a tmux agent. The foreground command must
        # not be a shell, so the second fake agent is named `claude`.
        pane=$(t new-session -d -P -F '#{pane_id}' -s smoke -x 120 -y 40 \
            "$start; exec -a claude sh $dir/agent.sh $dir/tfifo $dir/tack claude")
        [ -n "$pane" ] || die "no pane from new-session"
    else
        sh -c "$start"
    fi
    local waited=0
    until [ -s "$dir/run.json" ]; do
        sleep 0.1
        waited=$((waited + 1))
        [ "$waited" -lt 100 ] || die "core did not start the fake agent within 10 s"
    done
    core_addr=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["address"])' "$dir/run.json")
    [ -n "$core_addr" ] || die "no terminal address from herdr-core run"
    echo "core terminal: $core_addr"
    if [ "$with_tmux" = 1 ]; then
        # The core was first started from the tmux pane, so the core terminal
        # must have inherited that pane's TMUX_PANE: the stale environment the
        # hooks must see through.
        waited=0
        until [ -e "$dir/fifo.pane" ]; do
            sleep 0.1
            waited=$((waited + 1))
            [ "$waited" -lt 100 ] || die "the core fake agent did not start"
        done
        [ "$(cat "$dir/fifo.pane")" = "$pane" ] ||
            die "the core terminal's TMUX_PANE is '$(cat "$dir/fifo.pane")', want the stale '$pane'"
        echo "core terminal $core_addr inherited TMUX_PANE=$pane from the tmux pane that started core"
    fi

    local acked=0 tacked=0
    fire_core() {
        local state=$1 cmd waited=0
        shift
        cmd=$(hook_command "$@")
        echo "core hook $* (osc $state): $cmd"
        printf '%s|%s\n' "$state" "$cmd" >"$dir/fifo"
        acked=$((acked + 1))
        until [ "$(cat "$dir/ack")" = "$acked" ]; do
            sleep 0.1
            waited=$((waited + 1))
            [ "$waited" -lt 100 ] || die "the core fake agent did not run hook $* within 10 s"
        done
    }
    fire_tmux() {
        local state=$1 cmd waited=0
        shift
        cmd=$(hook_command "$@")
        echo "tmux hook $* (osc $state): $cmd"
        printf '%s|%s\n' "$state" "$cmd" >"$dir/tfifo"
        tacked=$((tacked + 1))
        until [ "$(cat "$dir/tack")" = "$tacked" ]; do
            sleep 0.1
            waited=$((waited + 1))
            [ "$waited" -lt 100 ] || die "the tmux fake agent did not run hook $* within 10 s"
        done
    }

    # `waycar notify` runs detached from the hook: wait for the push it sends.
    expect_pushes() {
        local pane_id=$1 want=$2 waited=0
        until [ "$(pushes_for "$dir" "$pane_id")" -ge "$want" ]; do
            sleep 0.1
            waited=$((waited + 1))
            [ "$waited" -lt 100 ] || die "the stand-in relay got $(pushes_for "$dir" "$pane_id") pushes for $pane_id, want $want"
        done
        # Nothing may arrive late and double it.
        sleep 1
        [ "$(pushes_for "$dir" "$pane_id")" = "$want" ] ||
            die "the stand-in relay got $(pushes_for "$dir" "$pane_id") pushes for $pane_id, want exactly $want"
        echo "  stand-in relay: $want push(es) for $pane_id"
    }
    expect_label() {
        local name=$1 want=$2 got
        got=$(core_label "$core_addr" "$name")
        echo "  $core_addr label $name=${got:-<unset>}"
        [ "$got" = "$want" ] || die "label $name is '$got', want '$want'"
    }

    fire_core working UserPromptSubmit
    expect_label waycar.kind claude
    expect_label waycar.turn 0
    fire_core blocked PermissionRequest
    expect_pushes "hc:$core_addr" 1
    fire_core working PostToolUse
    fire_core done Stop
    expect_pushes "hc:$core_addr" 2

    # Outside any terminal: no HC_TERMINAL_ID, no tty. And one that names the
    # terminal but runs on this shell's tty (or none): wrong tty, nothing.
    local outside out
    outside=$(hook_command UserPromptSubmit)
    out=$(printf '{}' | CLAUDECODE=1 sh -c "$outside" 2>&1) || die "a hook outside any terminal failed"
    [ -z "$out" ] || die "a hook outside any terminal printed: $out"
    out=$(printf '{}' | CLAUDECODE=1 HC_TERMINAL_ID="$core_addr" sh -c "$outside" 2>&1) ||
        die "a hook naming the terminal from another tty failed"
    [ -z "$out" ] || die "a hook naming the terminal from another tty printed: $out"
    sleep 1
    expect_pushes "hc:$core_addr" 2

    if [ "$with_tmux" = 1 ]; then
        fire_tmux working UserPromptSubmit
        fire_tmux blocked PermissionRequest
        expect_pushes "tmux:$pane" 1
        fire_tmux working PostToolUse
        fire_tmux done Stop
        expect_pushes "tmux:$pane" 2
        # The core terminal's pushes did not move.
        expect_pushes "hc:$core_addr" 2
        [ "$(all_pushes "$dir")" = 4 ] || die "the stand-in relay got $(all_pushes "$dir") pushes in all, want 4"
        fire_tmux - SessionEnd
        printf 'exit\n' >"$dir/tfifo"
    else
        [ "$(all_pushes "$dir")" = 2 ] || die "the stand-in relay got $(all_pushes "$dir") pushes in all, want 2"
    fi

    fire_core - SessionEnd
    for l in waycar.kind waycar.turn waycar.session waycar.transcript; do
        [ -z "$(core_label "$core_addr" "$l")" ] || die "label $l still set after SessionEnd (release)"
    done
    echo "  $core_addr: every waycar.* label removed"
    printf 'exit\n' >"$dir/fifo"
    [ "$with_tmux" = 0 ] || t kill-server >/dev/null 2>&1 || true
    "$(core_bin)" server stop >/dev/null 2>&1 || true
    [ -z "$relay_pid" ] || kill "$relay_pid" 2>/dev/null || true
    rm -rf "$dir"
    trap - EXIT
}

user_phase() {
    local repo=$1
    install_core
    check_install "$repo"
    smoke "$repo"
}

if [ "${1:-}" = --user-phase ]; then
    user_phase "$2"
else
    root_phase
fi
