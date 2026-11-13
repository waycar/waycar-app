#!/bin/bash
#
# Checks Waycar's tmux Host Tools (plugin/) against one Linux distribution's
# own tmux, the way a user on that distribution installs them.
#
#   WAYCAR_NATIVE_BIN=<waycar> scripts/ci/tmux-distro-check.sh
#
# Run it as root inside a throwaway container of the distribution
# (.github/workflows/tmux-distros.yml runs it in ubuntu:24.04, ubuntu:22.04,
# debian:12, fedora:latest and rockylinux:9). It changes the machine: it
# installs packages and a user, so never run it on a real host.
#
# WAYCAR_NATIVE_BIN is a static `waycar` for this machine's CPU (a musl build
# from scripts/build-plugin-binaries.sh). The Host Tools need nothing else:
# no Node anywhere. As root the script installs the distribution's tmux
# (asserting 3.2 or later), procps (the hook asks `ps` for a tty when it can),
# and Python 3 for the test's own tools: the stand-in relay
# (scripts/ci/relay-standin.py) and reading the hook entries out of
# ~/.claude/settings.json. The Host Tools never use it. Then, as a fresh
# non-root user with a clean, non-interactive environment (no TMUX, TMUX_PANE,
# HERDR_ENV or HERDR_PANE_ID, no version manager on PATH), it:
#
#   1. assembles the package the way scripts/package-plugin.sh does (bin/waycar
#      is the native binary; bin/waycar-hook, hooks/, herdr-plugin.toml and the
#      docs come from plugin/) and runs `sh install.sh --tmux` from it as a
#      Claude Code user (~/.claude exists); checks the install holds no Node
#      file, `waycar status --json` reports this tmux and `waycar hooks status
#      --json` reports the Claude hooks;
#   2. starts a private tmux server (-L wc-ci -f /dev/null) whose pane runs a
#      fake agent; the agent runs the installed Claude hook commands from
#      ~/.claude/settings.json through `sh -c` with CLAUDECODE=1, the way
#      Claude Code does, and each step checks @waycar_status, @waycar_agent
#      and @waycar_seq on the pane with `tmux show -p`. A hook run from
#      outside the pane (wrong tty, otherwise claude's env) must change
#      nothing. A Blocked and a Done step must each send the push to a local
#      stand-in for the relay (a plain-http `relay_url`).
#
# The checkout is the repository holding this script. It is only read.

set -euo pipefail

ci_user=wc
step() { printf '\n==> %s\n' "$*"; }
die() { printf 'tmux-distro-check: error: %s\n' "$*" >&2; exit 1; }

# `tmux -V` version word (3.2a, 3.5a, next-3.6) >= 3.2.
tmux_at_least_3_2() {
    local v=${1#next-} major minor
    major=$(printf '%s' "$v" | sed -n 's/^\([0-9][0-9]*\)\..*/\1/p')
    minor=$(printf '%s' "$v" | sed -n 's/^[0-9][0-9]*\.\([0-9][0-9]*\).*/\1/p')
    [ -n "$major" ] && [ -n "$minor" ] || return 1
    [ "$major" -gt 3 ] || { [ "$major" -eq 3 ] && [ "$minor" -ge 2 ]; }
}

# ---------------------------------------------------------------- root phase

install_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends tmux procps python3 >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q tmux procps-ng python3 util-linux shadow-utils >/dev/null
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

    step "installing tmux, procps and python3 on $distro"
    install_packages
    command -v ps >/dev/null || die "ps not installed"
    for tool in node nodejs npm; do
        if command -v "$tool" >/dev/null 2>&1; then die "$tool is installed ($(command -v "$tool")); the Host Tools run without Node"; fi
    done

    local tmux_version
    tmux_version=$(tmux -V | sed -n 's/^tmux \([^ ]*\).*/\1/p')
    tmux_at_least_3_2 "$tmux_version" || die "$distro ships tmux ${tmux_version:-?}, older than 3.2"

    local summary="$distro: tmux $tmux_version, no Node"
    echo "$summary"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "- $summary" >>"$GITHUB_STEP_SUMMARY"
    fi

    # bash, as most users have (and adduser gives). tmux runs a string command
    # through the default shell (the login shell when SHELL is unset): bash
    # execs `sleep 60`, but Debian's dash stays the pane's process-group
    # leader, so pane_current_command reads `sh` and the adapter rightly calls
    # the pane stale.
    id "$ci_user" >/dev/null 2>&1 || useradd -m -s /bin/bash "$ci_user"
    # The user phase cannot read the job's workspace in every container.
    install -D -m 755 "$WAYCAR_NATIVE_BIN" /opt/waycar-native/waycar
    local home
    home=$(getent passwd "$ci_user" | cut -d : -f 6)

    # A clean login-like environment: nothing from the job (TMUX, TMUX_PANE,
    # HERDR_ENV, HERDR_PANE_ID, CI variables) reaches the user phase.
    runuser -u "$ci_user" -- env -i \
        HOME="$home" USER="$ci_user" LOGNAME="$ci_user" SHELL=/bin/bash \
        PATH="$home/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        WAYCAR_CI_TMUX_VERSION="$tmux_version" WAYCAR_NATIVE_BIN=/opt/waycar-native/waycar \
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

check_install() {
    local repo=$1 source="$HOME/waycar-package" status hooks leftover
    step "assembling the package in $source"
    assemble_package "$repo" "$source"
    step "install.sh --tmux from $source"
    # A Claude Code user: hooks install only into agents it finds.
    mkdir -p "$HOME/.claude"
    WAYCAR_PLUGIN_SOURCE="$source" WAYCAR_NO_PAIR=1 sh "$repo/plugin/install.sh" --tmux </dev/null
    [ -L "$HOME/.local/bin/waycar" ] || die "~/.local/bin/waycar was not linked"
    for leftover in bin/node.sh src node_modules package.json package-lock.json; do
        [ ! -e "$HOME/.local/share/waycar/plugin/$leftover" ] || die "the install has $leftover"
    done

    status=$("$HOME/.local/bin/waycar" status --json </dev/null)
    echo "status --json: $status"
    python3 -c '
import json, sys
j = json.loads(sys.argv[1])
assert j["backends"]["tmux"] == sys.argv[2], j["backends"]
assert j["backends"]["herdr"] is False, j["backends"]
assert j["backends"]["core"] is None, j["backends"]
' "$status" "$WAYCAR_CI_TMUX_VERSION" || die "status --json does not report tmux $WAYCAR_CI_TMUX_VERSION and no herdr"

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

# The fake agent: the pane's own process, so its controlling tty is the
# pane's. For every hook command written to the FIFO it runs it through
# `sh -c` with a JSON body on stdin and CLAUDECODE=1 (waycar-hook's `claude`
# requires it), as Claude Code runs hooks, then acks.
fake_agent_script='
fifo=$1 ack=$2 n=0
while IFS= read -r cmd <"$fifo"; do
  [ "$cmd" = exit ] && exit 0
  printf "{}" | CLAUDECODE=1 sh -c "$cmd"
  n=$((n + 1))
  echo "$n" >"$ack"
done
'

# The stand-in relay of the smoke (scripts/ci/relay-standin.py): it records
# every request and answers GET /requests with them, and writes its port to
# $1/port.
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

# The pushes the stand-in relay has received so far.
pushes_received() {
    python3 - "$1" <<'PY'
import sys, urllib.request
body = urllib.request.urlopen("http://127.0.0.1:%s/requests" % open(sys.argv[1] + "/port").read()).read().decode()
print(sum(1 for line in body.splitlines() if line.startswith('{"url":"/push"')))
PY
}

smoke() {
    local repo=$1 pane sock=wc-ci relay_pid=""
    step "real tmux hook smoke (-L $sock, native hooks)"
    dir=$(mktemp -d /tmp/wc-ci-smoke.XXXXXX)
    printf '%s' "$fake_agent_script" >"$dir/agent.sh"
    mkfifo "$dir/fifo"
    : >"$dir/ack"
    t() { tmux -L "$sock" -f /dev/null "$@"; }
    # The servers, the stand-in relay and the scratch dir go on exit.
    trap 't kill-server >/dev/null 2>&1 || true; [ -z "${relay_pid:-}" ] || kill "$relay_pid" 2>/dev/null || true; rm -rf "$dir"' EXIT
    start_stand_in_relay "$dir" "$repo"
    configure_push "$dir"
    # The notify flow only counts a pane whose foreground command is not a
    # shell (a pane at a prompt is no Agent), so the fake agent's process is
    # named `claude`.
    local agent_command="exec -a claude sh $dir/agent.sh $dir/fifo $dir/ack"
    pane=$(t new-session -d -P -F '#{pane_id}' -s smoke -x 120 -y 40 "$agent_command")
    [ -n "$pane" ] || die "no pane from new-session"

    opt() { t show -p -q -v -t "$pane" "$1" 2>/dev/null || true; }

    local acked=0
    fire() {
        local cmd waited=0
        cmd=$(hook_command "$@")
        echo "hook $*: $cmd"
        printf '%s\n' "$cmd" >"$dir/fifo"
        acked=$((acked + 1))
        until [ "$(cat "$dir/ack")" = "$acked" ]; do
            sleep 0.1
            waited=$((waited + 1))
            [ "$waited" -lt 100 ] || die "the fake agent did not run hook $* within 10 s"
        done
    }

    local seq=0 new
    expect() {
        local want=$1 changed=$2 got agent
        got=$(opt @waycar_status)
        agent=$(opt @waycar_agent)
        new=$(opt @waycar_seq)
        echo "  pane $pane: @waycar_status=${got:-<unset>} @waycar_agent=${agent:-<unset>} @waycar_seq=${new:-<unset>}"
        [ "$got" = "$want" ] || die "@waycar_status is '${got}', want '$want'"
        [ "$agent" = claude ] || die "@waycar_agent is '${agent}', want claude"
        case $new in ''|*[!0-9]*) die "@waycar_seq '$new' is not a number" ;; esac
        if [ "$changed" = changed ]; then
            [ "$new" -gt "$seq" ] || die "@waycar_seq $new did not rise past $seq"
        else
            [ "$new" = "$seq" ] || die "@waycar_seq changed to $new on a no-op"
        fi
        seq=$new
    }

    # `waycar notify` runs detached from the hook: wait for the push it sends.
    expect_pushes() {
        local want=$1 waited=0
        until [ "$(pushes_received "$dir")" -ge "$want" ]; do
            sleep 0.1
            waited=$((waited + 1))
            [ "$waited" -lt 100 ] || die "the stand-in relay got $(pushes_received "$dir") pushes, want $want"
        done
        echo "  stand-in relay: $(pushes_received "$dir") push(es)"
    }

    fire UserPromptSubmit;      expect working changed
    fire PermissionRequest;     expect blocked changed
    expect_pushes 1
    fire PostToolUse;           expect working changed
    fire Stop;                  expect done changed
    expect_pushes 2
    fire Notification idle_prompt; expect done unchanged

    # Outside the pane: right TMUX_PANE, but this process has no tty there.
    local outside
    outside=$(hook_command UserPromptSubmit)
    printf '{}' | CLAUDECODE=1 TMUX_PANE=$pane TMUX="$(t display -p '#{socket_path},0,0')" sh -c "$outside"
    expect done unchanged

    fire SessionEnd
    for o in @waycar_status @waycar_agent @waycar_seq; do
        [ -z "$(opt "$o")" ] || die "$o still set after SessionEnd (release)"
    done
    echo "  pane $pane: every @waycar_* option unset"
    printf 'exit\n' >"$dir/fifo"
    t kill-server >/dev/null 2>&1 || true
    [ -z "$relay_pid" ] || kill "$relay_pid" 2>/dev/null || true
    rm -rf "$dir"
    trap - EXIT
}

user_phase() {
    local repo=$1
    check_install "$repo"
    smoke "$repo"
}

if [ "${1:-}" = --user-phase ]; then
    user_phase "$2"
else
    root_phase
fi
