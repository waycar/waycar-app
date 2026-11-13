#!/bin/sh
# One mock turn for a harness on the lab host: start it in a fresh tmux
# session in ~/work/demo, type a prompt, press Enter, then print the pane and
# the mock's request log for that turn.
#
#   smoke.sh <kind> [prompt]
#
# Env: SMOKE_CMD overrides the launch command, SMOKE_BOOT (s) the wait before
# typing (default per kind: long enough for a first launch on a fresh host,
# where opencode/kilo fetch packages and cline/hermes start slowly; typing
# earlier is lost), SMOKE_WAIT (s, default 15) the wait for the reply,
# SMOKE_KEEP=1 leaves the tmux session running.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
kind=${1:?usage: smoke.sh <kind> [prompt]}
prompt=${2:-hello WAYCAR}
mock=http://127.0.0.1:18080

boot=15
case "$kind" in
  claude | codex | copilot | pi | gemini | devin | qwen | grok | omp) cmd=$kind ;;
  opencode | kilo) cmd=$kind boot=40 ;;
  hermes) cmd=hermes boot=60 ;;
  cursor) cmd=cursor-agent ;;
  agy) cmd=agy ;;
  cline) cmd='cline -i' boot=40 ;;
  kiro) cmd='kiro-cli chat' ;;
  *) echo "unknown kind: $kind" >&2; exit 2 ;;
esac
cmd=${SMOKE_CMD:-$cmd}
boot=${SMOKE_BOOT:-$boot}
session=smoke-$kind

# The mock is shared (its selftest and other runs log there too), so read
# back only this run's entries instead of clearing the log.
start=$(date -u +%Y-%m-%dT%H:%M:%S)
"$here/lab.sh" ssh "set -e
tmux kill-session -t '$session' 2>/dev/null || true
tmux new-session -d -s '$session' -x 160 -y 48 -c ~/work/demo
sleep 1
tmux send-keys -t '$session' -l '$cmd'; tmux send-keys -t '$session' Enter
sleep $boot
tmux send-keys -t '$session' -l '$prompt'; sleep 0.5; tmux send-keys -t '$session' Enter
sleep ${SMOKE_WAIT:-15}
echo '----- pane ($kind: $cmd) -----'
tmux capture-pane -p -t '$session' | grep -v '^[[:space:]]*\$' || true
[ -n '${SMOKE_KEEP:-}' ] || tmux kill-session -t '$session'"
echo "----- mock /_log since $start (api path model lastUser -> reply) -----"
curl -fsS "$mock/_log" | jq -c --arg start "$start" \
  'select(.time >= $start and .userAgent != "waycar-mock-selftest")
   | {api, path, model, ua: (.userAgent // "" | .[0:30]), lastUser: (.lastUser // "" | tostring | .[0:60]), reply: (.replyText // .toolCall)}'
