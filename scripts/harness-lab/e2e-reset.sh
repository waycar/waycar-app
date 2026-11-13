#!/bin/sh
# The lab reset between HarnessLabE2ETests cases. Runs on the lab host as
# waycar: kills every tmux session and closes every herdr workspace whose name
# starts with the prefix (default harnesse2e-, the suite's
# HarnessLabEnvironment.labelPrefix), which ends the harnesses in them.
# Nothing else is touched, so other lab users' sessions survive.
#
#   sh e2e-reset.sh [prefix]          on the host (run-e2e.sh copies it to
#                                     ~/.cache/harness-lab/e2e-reset.sh)
#   scripts/harness-lab/lab.sh e2e-reset   the same, from the Mac
set -u

prefix=${1:-harnesse2e-}
[ -n "$prefix" ] || { echo "e2e-reset: refusing an empty prefix" >&2; exit 2; }

if command -v tmux >/dev/null 2>&1; then
  tmux list-sessions -F '#{session_name}' 2>/dev/null | while IFS= read -r session; do
    case $session in
      "$prefix"*) tmux kill-session -t "=$session" 2>/dev/null && echo "killed tmux session $session" ;;
    esac
  done
fi

if command -v herdr >/dev/null 2>&1 && herdr status server >/dev/null 2>&1; then
  herdr workspace list 2>/dev/null | node -e '
    let text = "";
    process.stdin.on("data", (chunk) => (text += chunk)).on("end", () => {
      let workspaces = [];
      try { workspaces = JSON.parse(text).result.workspaces ?? []; } catch {}
      for (const workspace of workspaces) {
        if (typeof workspace.label === "string" && workspace.label.startsWith(process.argv[1])) {
          console.log(workspace.workspace_id);
        }
      }
    });' "$prefix" | while IFS= read -r id; do
    herdr workspace close "$id" >/dev/null 2>&1 && echo "closed herdr workspace $id"
  done
fi
exit 0
