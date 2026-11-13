#!/bin/sh
# Dispatch test of bin/waycar-hook: tmux first, then herdr-core, with a fake
# tmux, a fake ps and a stub `waycar` that only logs how it was started. The
# Rust halves (tty check on core, labels, notify) have unit tests in
# rust/hook_status.rs; this checks which half a hook reaches:
#
#   sh plugin/test/waycar-hook-dispatch.sh
#
# Needs only a POSIX sh, mktemp, sed and sleep.

set -u
here=$(cd "$(dirname "$0")" && pwd)
hook_src=$here/../bin/waycar-hook
[ -f "$hook_src" ] || { echo "no $hook_src" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/plugin/bin" "$tmp/fake" "$tmp/nofake" "$tmp/proc"
cp "$hook_src" "$tmp/plugin/bin/waycar-hook"
chmod 755 "$tmp/plugin/bin/waycar-hook"
hook=$tmp/plugin/bin/waycar-hook
log=$tmp/log

# `waycar`: one line per start, with the core variables it would see.
cat >"$tmp/plugin/bin/waycar" <<EOF
#!/bin/sh
echo "waycar \$* [HC_TERMINAL_ID=\${HC_TERMINAL_ID:-} HC_SESSION=\${HC_SESSION:-}]" >>"$log"
[ "\$1" != codex-daemon-hook ] || exit "\${FAKE_CODEX_RESULT:-0}"
EOF
# `tmux`: the pane's tty is \$FAKE_PANE_TTY, no options are set; writes logged.
cat >"$tmp/fake/tmux" <<EOF
#!/bin/sh
case "\$*" in
  display-message*) echo "\${FAKE_PANE_TTY:-/dev/pts/1}" ;;
  set-option*) echo "tmux \$*" >>"$log" ;;
esac
exit 0
EOF
# `ps -o tty= -p <pid>`: every process is on \$FAKE_AGENT_TTY.
cat >"$tmp/fake/ps" <<EOF
#!/bin/sh
case "\$*" in
  *tty=*) echo "\${FAKE_AGENT_TTY:-pts/1}" ;;
  *ppid=*) echo 1 ;;
esac
exit 0
EOF
chmod 755 "$tmp/plugin/bin/waycar" "$tmp/fake/tmux" "$tmp/fake/ps"
cp "$tmp/fake/ps" "$tmp/nofake/ps" # a Host without tmux

# The hook's parent is this inner shell, so a Muse /proc entry can be made
# for its pid before the hook runs.
inner='if [ -n "${MUSE_ENVIRON:-}" ]; then mkdir -p "$WAYCAR_HOOK_PROC/$$"; printf "%b" "$MUSE_ENVIRON" >"$WAYCAR_HOOK_PROC/$$/environ"; fi; sh $HOOK_CMD; :'

fails=0
# run <label> <expected log> [VAR=value ...]; the hook's command is $cmd.
run() {
  label=$1 expected=$2
  shift 2
  : >"$log"
  out=$(env -i PATH="${FAKE_PATH:-$tmp/fake:/usr/bin:/bin}" HOME="$tmp" \
    HOOK_CMD="$hook $cmd" WAYCAR_HOOK_PROC="$tmp/proc" "$@" sh -c "$inner" </dev/null 2>&1)
  code=$?
  sleep 0.3 # the detached `waycar notify` of the tmux path
  got=$(sed 's/@waycar_seq [0-9]*/@waycar_seq SEQ/' "$log")
  if [ "$code" != 0 ] || [ -n "$out" ] || [ "$got" != "$expected" ]; then
    fails=$((fails + 1))
    printf 'FAIL %s\n  exit %s, output [%s]\n  expected:\n%s\n  got:\n%s\n' "$label" "$code" "$out" "$expected" "$got"
  else
    printf 'ok   %s\n' "$label"
  fi
}

cmd="claude working"
core_line="waycar hook-status claude working [HC_TERMINAL_ID=t7 HC_SESSION=]"
tmux_write="tmux set-option -p -t %1 @waycar_status working ; set-option -p -t %1 @waycar_seq SEQ ; set-option -p -t %1 @waycar_agent claude"

run "tmux pane, no core: the tmux path, one notify" \
  "$tmux_write
waycar notify --pane tmux:%1 --status working [HC_TERMINAL_ID= HC_SESSION=]" \
  CLAUDECODE=1 TMUX_PANE=%1 TMUX=/x,1,0 FAKE_PANE_TTY=/dev/pts/1 FAKE_AGENT_TTY=pts/1
run "tmux pane on a Host with core: tmux still wins, one push" \
  "$tmux_write
waycar notify --pane tmux:%1 --status working [HC_TERMINAL_ID=t7 HC_SESSION=]" \
  CLAUDECODE=1 TMUX_PANE=%1 TMUX=/x,1,0 HC_TERMINAL_ID=t7 FAKE_PANE_TTY=/dev/pts/1 FAKE_AGENT_TTY=pts/1
run "stale TMUX_PANE with another tty, core terminal: core only" "$core_line" \
  CLAUDECODE=1 TMUX_PANE=%1 TMUX=/x,1,0 HC_TERMINAL_ID=t7 FAKE_PANE_TTY=/dev/pts/9 FAKE_AGENT_TTY=pts/1
run "stale HERDR_* and TMUX_PANE, core terminal: core only" "$core_line" \
  CLAUDECODE=1 HERDR_ENV=1 HERDR_PANE_ID=p_1 TMUX_PANE=%1 HC_TERMINAL_ID=t7 FAKE_PANE_TTY=/dev/pts/1 FAKE_AGENT_TTY=pts/1
run "no TMUX_PANE, core terminal: core" "$core_line" \
  CLAUDECODE=1 HC_TERMINAL_ID=t7
FAKE_PATH="$tmp/nofake:/usr/bin:/bin" run "no tmux binary, core terminal: core" "$core_line" \
  CLAUDECODE=1 TMUX_PANE=%1 HC_TERMINAL_ID=t7
run "a named core session is passed on (hook-status skips it)" \
  "waycar hook-status claude working [HC_TERMINAL_ID=t7 HC_SESSION=w1]" \
  CLAUDECODE=1 HC_TERMINAL_ID=t7 HC_SESSION=w1

run "herdr pane that is no core terminal: silent" "" \
  CLAUDECODE=1 HERDR_ENV=1 HERDR_PANE_ID=p_1 TMUX_PANE=%1
run "no terminal at all: silent" "" CLAUDECODE=1
run "tmux pane with another tty and no core: silent" "" \
  CLAUDECODE=1 TMUX_PANE=%1 TMUX=/x,1,0 FAKE_PANE_TTY=/dev/pts/9 FAKE_AGENT_TTY=pts/1
run "summary harness in a core terminal: silent" "" \
  CLAUDECODE=1 WAYCAR_SUMMARY=1 HC_TERMINAL_ID=t7
run "claude without CLAUDECODE in a core terminal: silent" "" HC_TERMINAL_ID=t7
run "another agent running claude's settings in a core terminal: silent" "" \
  CLAUDECODE=1 CURSOR_VERSION=1 HC_TERMINAL_ID=t7

cmd="agy watch-approval"
run "watch-approval in a core terminal: silent" "" HC_TERMINAL_ID=t7
cmd="claude bogus"
run "unknown status in a core terminal: silent" "" CLAUDECODE=1 HC_TERMINAL_ID=t7

cmd="codex done-if-active"
run "a conditional status goes to hook-status as it is" \
  "waycar hook-status codex done-if-active [HC_TERMINAL_ID=t7 HC_SESSION=]" HC_TERMINAL_ID=t7
cmd="codex blocked"
run "embedded Codex with a tty never starts the new helper" \
  "tmux set-option -p -t %1 @waycar_status blocked ; set-option -p -t %1 @waycar_seq SEQ ; set-option -p -t %1 @waycar_agent codex
waycar notify --pane tmux:%1 --status blocked [HC_TERMINAL_ID= HC_SESSION=]" \
  TMUX_PANE=%1 FAKE_AGENT_TTY=pts/1
run "daemon Codex bypasses stale runtime variables before any pane write" \
  "waycar codex-daemon-hook blocked [HC_TERMINAL_ID=t7 HC_SESSION=]" \
  FAKE_AGENT_TTY=? TMUX_PANE=%1 HERDR_ENV=1 HERDR_PANE_ID=p_1 HC_TERMINAL_ID=t7
run "non-daemon Codex helper returns to the original core path" \
  "waycar codex-daemon-hook blocked [HC_TERMINAL_ID=t7 HC_SESSION=]
waycar hook-status codex blocked [HC_TERMINAL_ID=t7 HC_SESSION=]" \
  FAKE_AGENT_TTY=? FAKE_CODEX_RESULT=125 HC_TERMINAL_ID=t7
run "Codex summary harness never starts the helper" "" \
  FAKE_AGENT_TTY=? WAYCAR_SUMMARY=1

cmd="claude release"
run "release goes to hook-status" \
  "waycar hook-status claude release [HC_TERMINAL_ID=t7 HC_SESSION=]" CLAUDECODE=1 HC_TERMINAL_ID=t7

cmd="muse working"
run "muse: core variables restored from the agent's environment" \
  "waycar hook-status muse working [HC_TERMINAL_ID=t9 HC_SESSION=default]" \
  MUSE_ENVIRON='HC_TERMINAL_ID=t9\0HC_SESSION=default\0PATH=/x\0'

cmd="claude working"
run "Zellij without tmux dispatches to native ownership check" \
  "waycar hook-status claude working [HC_TERMINAL_ID= HC_SESSION=]" \
  CLAUDECODE=1 ZELLIJ_PANE_ID=0 ZELLIJ_SESSION_NAME=work
run "Zellij inside tmux: outer tty declines" \
  "waycar hook-status claude working [HC_TERMINAL_ID= HC_SESSION=]" \
  CLAUDECODE=1 ZELLIJ_PANE_ID=0 ZELLIJ_SESSION_NAME=work TMUX_PANE=%1 FAKE_PANE_TTY=/dev/pts/9 FAKE_AGENT_TTY=pts/1
run "tmux inside Zellij: inner tmux tty wins" \
  "$tmux_write
waycar notify --pane tmux:%1 --status working [HC_TERMINAL_ID= HC_SESSION=]" \
  CLAUDECODE=1 ZELLIJ_PANE_ID=0 ZELLIJ_SESSION_NAME=work TMUX_PANE=%1 FAKE_PANE_TTY=/dev/pts/1 FAKE_AGENT_TTY=pts/1
cmd="agy watch-approval"
run "Zellij approval watch stays unsupported" "" ZELLIJ_PANE_ID=0 ZELLIJ_SESSION_NAME=work

rm "$tmp/plugin/bin/waycar"
cmd="claude working"
run "no waycar next to the hook, core terminal: silent" "" CLAUDECODE=1 HC_TERMINAL_ID=t7

[ "$fails" = 0 ] || { echo "$fails failed" >&2; exit 1; }
echo "all passed"
