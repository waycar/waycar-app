#!/bin/sh
# Fake agent for the core lab. No paid agent, no network. Reports status as OSC 7501.
# Usage: fake-agent.sh <name> [mode]
#   mode: idle (default) | loop (working forever, progress cycling) | blocked (starts blocked, waits for y/n) | done | error
# Reads lines on stdin:
#   work  -> working (progress 10..90 over 3 s, base64 msg) -> done -> idle
#   ask   -> blocked (kind=permission, msg "Allow rm -rf /tmp/x?"), waits for `y` or `n`, then working -> done
#   fail  -> error (b64 msg)
#   quit  -> exit 0
#   other -> echo it, idle
name=${1:-agent}
mode=${2:-idle}

r() { printf '\033]7501;%s\033\\' "$1"; }                  # OSC 7501 ... ST
b64() { printf %s "$1" | base64 -w0; }
title() { printf '\033]0;%s\007' "$name"; }                 # OSC 0

st() {  # st <state> [extra fields...]  -> state=<s>:app=<name>[:extra]
  s=$1; shift
  out="state=$s:app=$name"
  for f in "$@"; do out="$out:$f"; done
  r "$out"
}

wait_answer() {  # blocked on y/n: working -> done after the answer
  while IFS= read -r ans; do
    case "$ans" in y|n) break ;; esac
  done
  st working "msg=$(b64 "answer $ans")"; sleep 1
  st done "msg=$(b64 "answered $ans")"
  printf 'answered %s\n' "$ans"
}

title
loop_pid=
cleanup() { [ -n "$loop_pid" ] && kill "$loop_pid" 2>/dev/null; return 0; }
trap 'cleanup; exit 0' INT TERM HUP
trap cleanup EXIT

case "$mode" in
  idle)    st idle ;;
  blocked) st blocked kind=permission "msg=$(b64 'Allow rm -rf /tmp/x?')"; printf 'blocked: waiting for y/n\n'; wait_answer ;;
  done)    st done "msg=$(b64 'finished earlier')"; printf 'done\n' ;;
  error)   st error "msg=$(b64 'it broke')"; printf 'error\n' ;;
  loop)
    st idle
    ( while :; do
        for p in 10 30 50 70 90; do
          st working "progress=$p" "msg=$(b64 "$name step $p")"; sleep 1
        done
      done ) &
    loop_pid=$!
    ;;
  *) echo "fake-agent: unknown mode $mode" >&2; exit 2 ;;
esac

while IFS= read -r line; do
  case "$line" in
    work)
      title
      for p in 10 20 30 40 50 60 70 80 90; do
        st working "progress=$p" "msg=$(b64 "working $p%")"; sleep 0.333
      done
      st done "msg=$(b64 'work finished')"
      printf 'work finished\n'
      st idle
      ;;
    ask)
      st blocked kind=permission "msg=$(b64 'Allow rm -rf /tmp/x?')"
      printf 'Allow rm -rf /tmp/x? [y/n] '
      wait_answer
      ;;
    fail)
      st error "msg=$(b64 'it broke')"
      printf 'error\n'
      ;;
    quit) exit 0 ;;
    *)
      printf 'echo: %s\n' "$line"
      st idle
      ;;
  esac
done
exit 0
