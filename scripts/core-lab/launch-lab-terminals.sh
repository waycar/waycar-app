#!/bin/sh
# Start the core lab's terminals through `herdr-core run --bg` (fake agents only, no paid agent).
# Run it as user waycar INSIDE the lab (or over ssh):  sh /home/waycar/lab/launch-lab-terminals.sh [reset]
#   reset   kill and remove every terminal carrying label lab=core first
# Layout (all with --cwd /home/waycar/work/<dir>, all labelled lab=core):
#   alpha idle | bravo working loop | charlie blocked (permission, waits for y/n) | delta done | echo error
#   shell  plain login-less shell
#   sp1-tb1 / sp1-tb2 / sp2-tb1  fake agents labelled herdr.space=sp1|sp2 herdr.tab=tb1|tb2 (the Herdr app's topology labels)
set -eu
H=${HERDR_CORE:-}
[ -n "$H" ] || H=$(command -v herdr-core) || H=$HOME/.local/bin/herdr-core
[ -x "$H" ] || { echo "herdr-core is not installed here (run the official installer first)" >&2; exit 127; }
AGENT=${FAKE_AGENT:-$HOME/lab/fake-agent.sh}
[ -x "$AGENT" ] || AGENT=/opt/lab/fake-agent.sh
W=$HOME/work

if [ "${1:-}" = reset ]; then
  for t in $("$H" ls --json --label lab=core | python3 -c 'import json,sys; [print(x["address"]) for x in json.load(sys.stdin).get("terminals",[])]'); do
    "$H" kill "$t" >/dev/null 2>&1 || true
  done
  sleep 0.5
  for t in $("$H" ls --all --json --label lab=core | python3 -c 'import json,sys; [print(x["address"]) for x in json.load(sys.stdin).get("terminals",[])]'); do
    "$H" rm "$t" >/dev/null 2>&1 || true
  done
fi

start() {  # start <name> <dir> <fake-agent-name> <mode> [extra --label K=V ...]
  name=$1; dir=$2; agent=$3; mode=$4; shift 4
  mkdir -p "$W/$dir"
  "$H" run --bg --json --no-parent --name "$name" --cwd "$W/$dir" --label lab=core "$@" \
    -- sh "$AGENT" "$agent" "$mode" | python3 -c 'import json,sys; r=json.load(sys.stdin); print("%-8s %s  %s" % (r.get("name"), r.get("address"), r.get("cwd")))'
}

start alpha   alpha   alpha   idle
start bravo   bravo   bravo   loop
start charlie charlie charlie blocked
start delta   delta   delta   done
start echo    echo    echo    error

mkdir -p "$W/shell"
"$H" run --bg --json --no-parent --name shell --cwd "$W/shell" --label lab=core \
  | python3 -c 'import json,sys; r=json.load(sys.stdin); print("%-8s %s  %s" % (r.get("name"), r.get("address"), r.get("cwd")))'

start sp1-tb1 sp1-tb1 sp1tb1 idle --label herdr.space=sp1 --label herdr.tab=tb1
start sp1-tb2 sp1-tb2 sp1tb2 idle --label herdr.space=sp1 --label herdr.tab=tb2
start sp2-tb1 sp2-tb1 sp2tb1 idle --label herdr.space=sp2 --label herdr.tab=tb1
