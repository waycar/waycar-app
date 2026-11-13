#!/bin/sh
# Run the Waycar host-tools checks against a freshly deployed test box and
# print everything for the report:
#
#   scripts/testboxes/check.sh <distro> <ssh-port>
#
# 1. box facts (tmux -V, distro Node, packages file, waycar-e2e TMUX_TMPDIR)
# 2. plugin/ copied to ~/waycar-plugin-src, install.sh with the distro Node only
# 3. provision-user.sh (nvm Node LTS, pi, opencode), install.sh from an
#    interactive login shell, `waycar status --json` over a plain exec
# 4. the exact HostBackendDetection.command(socket: .defaultSession) exec
# 5. OpenRouter key (from ~/.env `openrouter_testbox_key`, the dedicated
#    `waycar-testboxes` key capped at $2 a month, sent over stdin into a
#    0600 file sourced by ~/.bashrc) and opencode/pi configs for $MODEL
# 6. opencode, then pi, launched the app's way in session `main`, one tiny
#    prompt each through set-buffer/paste-buffer/send-keys, @waycar_* options
#    sampled every second, then the agent quit (the window stays, idle).
set -eu
[ $# -eq 2 ] || { echo "usage: $0 <distro> <ssh-port>" >&2; exit 2; }
distro=$1
port=$2
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
host=${TESTBOX_HOST:?set TESTBOX_HOST to the Docker host that publishes the box}
key="$HOME/.ssh/waycar_testbox"
e2e_key="$HOME/.ssh/waycar_testbox_e2e"
kh="$HOME/.ssh/waycar_testbox_known_hosts"
MODEL=${MODEL:-apodex/apodex-1.1-mini:free}
common="-p $port -o UserKnownHostsFile=$kh -o StrictHostKeyChecking=accept-new -o SendEnv=-LANG -o SendEnv=-LC_*"
opts="-i $key -o IdentitiesOnly=yes $common"
box() { ssh $opts "waycar@$host" "$@"; }
section() { printf '\n===== %s: %s\n' "$distro" "$*"; }

# ONLY_AGENTS=1 reruns just the agent launches (steps 1-5 already done).
if [ "${ONLY_AGENTS:-}" != 1 ]; then
section "box facts"
box 'tmux -V; echo "node: $(node -v 2>&1)"; grep PRETTY /etc/os-release; echo "LANG=${LANG-unset}"; cat /etc/waycar-testbox-packages.txt'
ssh -i "$e2e_key" -o IdentitiesOnly=yes $common "waycar-e2e@$host" 'echo "e2e TMUX_TMPDIR=$TMUX_TMPDIR"; ls -ld "$TMUX_TMPDIR"'

section "install.sh with the distro Node only"
rsync -a --delete --exclude node_modules -e "ssh $opts" "$repo/plugin/" "waycar@$host:waycar-plugin-src/"
box 'WAYCAR_NO_PAIR=1 WAYCAR_PLUGIN_SOURCE=$HOME/waycar-plugin-src sh $HOME/waycar-plugin-src/install.sh 2>&1; echo "exit=$?"'

section "provision-user.sh"
box 'sh -s' <"$here/provision-user.sh"

section "install.sh from an interactive login shell"
box 'bash -lic "echo node=\$(command -v node) \$(node -v); WAYCAR_NO_PAIR=1 WAYCAR_PLUGIN_SOURCE=\$HOME/waycar-plugin-src sh \$HOME/waycar-plugin-src/install.sh; echo exit=\$?" 2>&1' \
  | grep -v 'no job control\|terminal process group'

section "waycar status --json over a plain exec"
box 'export PATH="$PATH:$HOME/.local/bin"; echo "node.sh picks: $(sh ~/.local/share/waycar/plugin/bin/node.sh -v)"; waycar status --json; echo "exit=$?"; waycar hooks status --json >/dev/null; echo "hooks status exit=$?"'

section "backend detection exec"
# HostBackendDetection.command(socket: .defaultSession), verbatim.
box "$(cat <<'EOF'
LC_ALL=C /bin/sh -c 'export PATH="$PATH:$HOME/.local/bin:${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims:$HOME/.linuxbrew/bin:$HOME/.cargo/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin"; printf "__WAYCAR_BACKENDS__\n"; if command -v herdr >/dev/null 2>&1; then printf "herdr=path\n"; fi; case "$1" in home) s="$HOME$2";; abs) s="$2";; *) s=;; esac; if [ -n "$s" ] && [ -S "$s" ]; then printf "herdr=socket\n"; fi; if v=$(tmux -V 2>/dev/null); then printf "tmux=%s\n" "$v"; fi; printf "__WAYCAR_BACKENDS_END__\n"; exit 0' waycar-detect home '/.config/herdr/herdr.sock'
EOF
)"

section "OpenRouter key and agent configs ($MODEL)"
if [ -z "${openrouter_testbox_key:-}" ] && [ -f "$HOME/.env" ]; then
  set -a; . "$HOME/.env"; set +a
fi
: "${openrouter_testbox_key:?openrouter_testbox_key not set}"
printf 'export OPENROUTER_API_KEY=%s\n' "$openrouter_testbox_key" | box 'umask 077; mkdir -p ~/.config/waycar-testbox && cat >~/.config/waycar-testbox/openrouter.env
grep -q openrouter.env ~/.bashrc || printf "\n# OpenRouter key for agent tests (0600)\n[ -r \"\$HOME/.config/waycar-testbox/openrouter.env\" ] && . \"\$HOME/.config/waycar-testbox/openrouter.env\"\n" >>~/.bashrc
ls -l ~/.config/waycar-testbox/openrouter.env'
box "mkdir -p ~/.pi/agent ~/.config/opencode ~/proj && cd ~/proj && git init -q
cat >~/.pi/agent/models.json <<'EOF'
{\"providers\":{\"openrouter-free\":{\"baseUrl\":\"https://openrouter.ai/api/v1\",\"apiKey\":\"\$OPENROUTER_API_KEY\",\"api\":\"openai-completions\",
 \"models\":[{\"id\":\"$MODEL\",\"name\":\"$MODEL\",\"contextWindow\":262144,\"maxTokens\":8192}]}}}
EOF
cat >~/.pi/agent/settings.json <<'EOF'
{\"defaultProvider\":\"openrouter-free\",\"defaultModel\":\"$MODEL\"}
EOF
cat >~/.config/opencode/opencode.json <<'EOF'
{\"\$schema\":\"https://opencode.ai/config.json\",\"model\":\"openrouter/$MODEL\",\"autoupdate\":false,
 \"provider\":{\"openrouter\":{\"models\":{\"$MODEL\":{\"name\":\"$MODEL\",\"tool_call\":true}}}}}
EOF
echo configs written"
fi

for agent in opencode pi; do
  section "$agent launched the app's way"
  box "AGENT=$agent MODEL=$MODEL sh -s" <<'EOF'
T="tmux -u"; export LC_ALL=C
$T has-session -t main 2>/dev/null || $T new-session -d -s main -c "$HOME/proj" -e WAYCAR_SHELL=1
$T kill-window -t "main:$AGENT" 2>/dev/null || true
p=$($T new-window -d -t main: -c "$HOME/proj" -n "$AGENT" -e WAYCAR_SHELL=1 -P -F '#{pane_id}' -- "exec \"\$SHELL\" -lic '$AGENT; exec \"\$SHELL\" -l'")
F='status=#{@waycar_status} agent=#{@waycar_agent} seq=#{@waycar_seq} session=#{@waycar_session}'
echo "pane $p"
# Wait for the TUI to show the model (it is ready for input then), sampling
# the options meanwhile; a paste before that is lost.
i=0; while [ $i -lt 90 ]; do
  echo "pre t=${i}s $($T display -p -t "$p" "$F")"
  if $T capture-pane -p -t "$p" | grep -qF "$MODEL"; then echo "ready t=${i}s"; break; fi
  i=$((i+1)); sleep 1
done | uniq -f2 -c
sleep 2
$T set-buffer -b waycar-x -- "Create file $AGENT.txt containing ok, then reply done" \; paste-buffer -p -d -b waycar-x -t "$p" \; send-keys -t "$p" Enter
i=0; while [ $i -lt 45 ]; do echo "t=${i}s $($T display -p -t "$p" "$F")"; i=$((i+1)); sleep 1; done | uniq -f1 -c
echo "--- screen"; $T capture-pane -p -t "$p" | grep -v '^[[:space:]]*$' | tail -8
echo "--- $AGENT.txt: $(cat "$HOME/proj/$AGENT.txt" 2>&1)"
# Quit: opencode exits on one ctrl+c, pi on two in quick succession.
$T send-keys -t "$p" C-c; sleep 0.3; $T send-keys -t "$p" C-c; sleep 3
echo "after quit: cmd=$($T display -p -t "$p" '#{pane_current_command}') $($T display -p -t "$p" "$F")"
EOF
done
