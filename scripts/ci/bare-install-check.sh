#!/bin/sh
# The Host Tools on a bare Linux server with no Node, the way a user installs
# them: install.sh, `waycar status --json`, `waycar hooks status --json`, the
# Pairing Code screen in a terminal, the status hook writing pane options, a
# detached `waycar notify` that must exit 0, a Blocked and a Done status change
# that each send their push and Live Activity update to a stand-in for the push
# relay, `waycar chat-read` on a Claude transcript, and `waycar summaries
# refresh`.
#
#   scripts/ci/bare-install-check.sh <dist-dir> <image> [--herdr]
#
# <dist-dir> is scripts/package-plugin.sh's output (install.sh and plugin/); its
# musl binary must match this machine's CPU. <image> is a distribution image,
# for example ubuntu:24.04, debian:12-slim, alpine:3.20 or rockylinux:8. It
# runs in a disposable container: nothing from the host but the dist directory
# is copied in, and nothing but the distribution's tmux, curl and OpenSSH is
# installed there (no Node, no Python).
#
# Default: tmux from the distribution is the backend (install.sh --tmux is not
# needed; with no herdr it picks tmux mode). --herdr installs herdr with
# https://herdr.dev/install.sh first, so install.sh takes herdr mode (use it
# for Rocky 8, whose tmux 2.7 is too old for the tmux path). With herdr there
# is no tmux hook step; the push step runs `waycar herdr-event notify` as
# herdr's event hook does, against a stub `herdr` (HERDR_BIN_PATH) that answers
# the status re-check, because a real herdr event needs a herdr session.
#
# The container is started with the labels the shared devbox requires:
# WAYCAR_CHECK_DOCKER_ARGS adds them, for example
#   WAYCAR_CHECK_DOCKER_ARGS="--label agent=senior-software-engineer --label disposable=true --label expires=2026-10-30T12:00Z --cpus 2 --memory 4g"
# The stand-in relay (scripts/ci/relay-standin.py, plain http, Python standard
# library) runs in a second container (the WAYCAR_CHECK_RELAY_IMAGE image,
# default python:3-alpine) that shares the first one's network, so the
# container under test never has Python or Node: the hooks POST to
# 127.0.0.1:8099 and the checks read what it received from
# GET http://127.0.0.1:8099/requests.
# Without Docker on the host the check cannot run.
set -eu

herdr=
args=
for arg in "$@"; do
  if [ "$arg" = --herdr ]; then herdr=1; else args="$args $arg"; fi
done
# shellcheck disable=SC2086 # two positional words
set -- $args
dist=${1:?usage: scripts/ci/bare-install-check.sh <dist-dir> <image> [--herdr]}
image=${2:?usage: scripts/ci/bare-install-check.sh <dist-dir> <image> [--herdr]}
dist=$(cd "$dist" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$here/../../plugin/herdr-plugin.toml")
relay_url=http://127.0.0.1:8099

# The checks, as a script for `sh -eu` on stdin as the throwaway user.
user_checks() {
  cat <<'INNER'
fail() { echo "bare-install-check: FAIL: $*" >&2; exit 1; }
ok() { echo "bare-install-check: ok: $*"; }
# backends <status --json line>: its backends as `herdr=<v> tmux=<v> core=<v>
# zellij=<v>`, each <v> as JSON (false, true, null or a quoted version) or
# `missing`, whatever the key order and whatever other keys the object has.
backends() {
  case $1 in *'"backends":{'*) ;; *) echo "no backends object"; return 0 ;; esac
  b=${1#*'"backends":{'}
  b=,${b%%'}'*},
  out=
  for key in herdr tmux core zellij; do
    case $b in
      *,\""$key"\":*) v=${b#*,\""$key"\":}; v=${v%%,*} ;;
      *) v=missing ;;
    esac
    out="$out${out:+ }$key=$v"
  done
  printf '%s\n' "$out"
}

plugin=$HOME/.local/share/waycar/plugin
cli=$HOME/.local/bin/waycar
export PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID
mkdir -p "$HOME/.claude" "$HOME/.local/bin"
for tool in node nodejs npm python3 python; do
  ! command -v "$tool" >/dev/null 2>&1 || fail "this image has $tool on PATH: $(command -v "$tool")"
done
if command -v ps >/dev/null 2>&1 && ps -o tty= -p 1 >/dev/null 2>&1; then
  echo "bare-install-check: note: this image's ps answers -o tty= -p, so the hook's /proc fallback is not exercised here"
else
  echo "bare-install-check: note: ps cannot answer here (absent or no -p), so the hook runs on its /proc fallback"
fi

# What the stand-in relay (another container, same network) has received.
relay_requests() { curl -fsS "$WAYCAR_CHECK_RELAY/requests"; }
relay_count() { relay_requests | grep -c '^{' || true; }
# Waits until the relay has recorded $1 requests in all.
wait_for_requests() {
  i=0
  until [ "$(relay_count)" -ge "$1" ]; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || { relay_requests >&2; fail "the stand-in relay got $(relay_count) requests after 10 s, expected $1"; }
    sleep 0.1
  done
}
i=0
until relay_requests >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 100 ] || fail "the stand-in relay at $WAYCAR_CHECK_RELAY does not answer"
  sleep 0.1
done

if [ -n "$WAYCAR_CHECK_HERDR" ]; then
  curl -fsSL https://herdr.dev/install.sh | sh >"$HOME/herdr-install.log" 2>&1 || { cat "$HOME/herdr-install.log" >&2; fail "herdr install"; }
  command -v herdr >/dev/null 2>&1 || fail "herdr is not on PATH after its installer"
  ok "herdr $(herdr --version 2>&1 | head -n 1)"
fi

# 1. Install, as a user with a Claude Code home. Nothing in the run or the
# installed tree may involve Node.
WAYCAR_INSTALL_BASE_URL=file:///dist WAYCAR_NO_PAIR=1 sh /dist/install.sh </dev/null >"$HOME/install.log" 2>&1 \
  || { cat "$HOME/install.log" >&2; fail "install.sh failed"; }
! grep -qi node "$HOME/install.log" || { cat "$HOME/install.log" >&2; fail "install.sh mentioned Node"; }
magic=$(head -c 4 "$plugin/bin/waycar" | od -An -tx1 | tr -d ' ')
[ "$magic" = 7f454c46 ] || fail "bin/waycar is not a native ELF file (magic $magic)"
for leftover in bin/node.sh src node_modules package.json package-lock.json; do
  [ ! -e "$plugin/$leftover" ] || fail "the install has $leftover"
done
ok "install.sh finished; bin/waycar is a native binary and the tree has no Node files"

# The hooks install on a tmux 3.2+ box (install.sh gates them); by hand otherwise.
if ! grep -q 'installing agent status hooks' "$HOME/install.log"; then
  "$plugin/bin/waycar" hooks install </dev/null >/dev/null 2>&1 || fail "hooks install"
  ok "hooks installed by hand (install.sh installs them only next to tmux 3.2 or later)"
fi
# Whatever mode install.sh picked, run the binary by its full path.
cli=$plugin/bin/waycar

# 2. status --json and hooks status --json, and the hook entries themselves.
status=$("$cli" status --json </dev/null) || fail "status --json"
case $status in "{\"version\":1,\"hostTools\":{\"version\":\"$EXPECT_VERSION\","*) ;; *) fail "status --json: $status" ;; esac
if [ -n "$WAYCAR_CHECK_HERDR" ]; then
  case $(backends "$status") in 'herdr=true '*) ;; *) fail "status --json should report herdr: $status" ;; esac
else
  case $(backends "$status") in 'herdr=false tmux="'?*'" core=null zellij=null') ;; *) fail "status --json should report tmux and no core or zellij: $status" ;; esac
fi
hooks=$("$cli" hooks status --json </dev/null) || fail "hooks status --json"
case $hooks in *'"agent":"claude","detected":true,"installed":true,'*) ;; *) fail "hooks status --json: claude is not installed: $hooks" ;; esac
[ "$hooks" = "$status" ] || fail "hooks status --json differs from status --json"
printf '%s\n' "$status" | grep -c '^' | grep -qx 1 || fail "status --json is not one line"
! grep -qi node "$HOME/.claude/settings.json" || fail "the Claude hook entries mention Node: $(grep -i node "$HOME/.claude/settings.json")"
grep -q "'$plugin/bin/waycar' hook-session claude" "$HOME/.claude/settings.json" || fail "no SessionStart entry runs waycar hook-session"
grep -q "'$plugin/bin/waycar-hook' claude working" "$HOME/.claude/settings.json" || fail "no entry runs waycar-hook"
ok "status --json and hooks status --json agree; the Claude hook entries call waycar and waycar-hook, not Node"

# 3. The Pairing Code screen in a terminal (a tmux pane), then quit it.
t() { tmux -L wc-bare -f /dev/null "$@"; }
trap 't kill-server >/dev/null 2>&1 || true' EXIT
t new-session -d -x 120 -y 50 -s pair "$cli pair"
i=0
until t capture-pane -p -t pair | grep -qi 'enter'; do
  i=$((i + 1)); [ "$i" -lt 100 ] || { t capture-pane -p -t pair >&2; fail "waycar pair showed no address list"; }
  sleep 0.1
done
t send-keys -t pair Enter
i=0
until t capture-pane -p -t pair | grep -q '[█▀▄]'; do
  i=$((i + 1)); [ "$i" -lt 100 ] || { t capture-pane -p -t pair >&2; fail "waycar pair drew no QR"; }
  sleep 0.1
done
screen=$(t capture-pane -p -t pair)
blocks=$(printf '%s\n' "$screen" | grep -c '[█▀▄]')
[ "$blocks" -ge 20 ] || { printf '%s\n' "$screen" >&2; fail "the QR is only $blocks lines tall"; }
t send-keys -t pair q
i=0
while t has-session -t pair 2>/dev/null; do
  i=$((i + 1)); [ "$i" -lt 50 ] || fail "waycar pair did not close on q"
  sleep 0.1
done
left=$(find "$HOME/.local/state" -path '*/pending/*' -type f 2>/dev/null || true)
[ -z "$left" ] || fail "quitting left a pending pairing behind: $left"
grep -q 'herdr-pairing' "$HOME/.ssh/authorized_keys" 2>/dev/null && fail "quitting left the Bootstrap Key line in authorized_keys"
ok "waycar pair draws a $blocks-line QR and removes its Bootstrap Key on q"

# 4. herdr mode: herdr has the plugin linked and enabled, and herdr runs the
# native binary straight from the manifest (the pair pane and action). The
# tmux status hook is not part of this path (herdr owns the status; Rocky 8's
# tmux 2.7 has no pane options anyway).
if [ -n "$WAYCAR_CHECK_HERDR" ]; then
  listing=$(herdr plugin list --plugin waycar </dev/null 2>&1) || fail "herdr plugin list: $listing"
  case $listing in *waycar*) ;; *) fail "herdr does not list the waycar plugin: $listing" ;; esac
  case $listing in *isabled*) fail "the waycar plugin is disabled: $listing" ;; esac
  grep -q '^command = \["./bin/waycar", "pair"\]' "$plugin/herdr-plugin.toml" || fail "the pair pane does not run the native binary"
  dir=$("$cli" status </dev/null | sed -n 's/^config dir: \(.*\) (herdr-plugin)$/\1/p')
  [ -n "$dir" ] || fail "waycar status does not take its config dir from herdr: $("$cli" status </dev/null)"
  ok "herdr lists the plugin and waycar status uses its config dir: $dir"
else
  # 4. The status hook writes the pane options, run the way an agent runs it
  # from inside a pane (its parent is the pane's shell, so its tty is the pane's).
  t new-session -d -x 120 -y 30 -s hook sh
  # Type once the shell has drawn its prompt and settled: busybox sh flushes the
  # terminal's input when it switches to line editing, so early keys are lost.
  i=0
  until t capture-pane -p -t hook | grep -q '[$#]'; do
    i=$((i + 1)); [ "$i" -lt 100 ] || fail "the shell in the hook pane drew no prompt"
    sleep 0.1
  done
  sleep 0.5
  t send-keys -t hook "CLAUDECODE=1 $plugin/bin/waycar-hook claude working </dev/null" Enter
  i=0
  until [ "$(t show -p -q -v -t hook @waycar_status 2>/dev/null)" = working ]; do
    i=$((i + 1)); [ "$i" -lt 100 ] || { t list-panes -a -F '#{session_name} #{pane_id} dead=#{pane_dead} #{pane_current_command} #{pane_tty}' >&2; t capture-pane -p -t hook >&2; fail "waycar-hook did not set @waycar_status"; }
    sleep 0.1
  done
  [ "$(t show -p -q -v -t hook @waycar_agent)" = claude ] || fail "waycar-hook did not set @waycar_agent"
  case $(t show -p -q -v -t hook @waycar_seq) in ''|*[!0-9]*) fail "@waycar_seq is not a number" ;; esac
  ok "waycar-hook writes @waycar_status, @waycar_agent and @waycar_seq"
fi

# 5. Detached hook commands exit 0 and say nothing when they have nothing to do.
out=$("$cli" notify --pane tmux:%1 --status working </dev/null 2>&1) || fail "notify exited $?"
[ -z "$out" ] || fail "notify printed: $out"
out=$("$cli" watch-approval --pane tmux:%1 --agent agy </dev/null 2>&1) || fail "watch-approval exited $?"
[ -z "$out" ] || fail "watch-approval printed: $out"
ok "notify and watch-approval exit 0 silently"

# 6. A Blocked and a Done status change each send the push and the Live
# Activity update to the stand-in relay (127.0.0.1:8099, another container's).
mkdir -p "$HOME/.config/waycar" "$HOME/tmuxdir"
cat >"$HOME/.config/waycar/notify.json" <<JSON
{"relay_url":"$WAYCAR_CHECK_RELAY","debounce_ms":0,"activity_debounce_ms":0,"activity_start_grace_ms":0,"retry_delay_ms":0}
JSON
cat >"$HOME/.config/waycar/notifications.json" <<'JSON'
{"v":1,"devices":[{"token":"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","env":"sandbox","notify":{"blocked":true,"done":true},"live_activity":{"token":"c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3"}}]}
JSON
before=$(relay_count)
if [ -z "$WAYCAR_CHECK_HERDR" ]; then
  export TMUX_TMPDIR=$HOME/tmuxdir
  # `exec`: the pane's command is `sleep`, not the shell tmux runs it through.
  tmux -f /dev/null new-session -d -s push -x 100 -y 30 'exec sleep 600' || fail "tmux would not start"
  pane=$(tmux list-panes -a -F '#{pane_id}' | sed -n 1p)
  tmux set-option -p -t "$pane" @waycar_agent claude
  tmux set-option -p -t "$pane" @waycar_status blocked
  "$cli" notify --pane "tmux:$pane" --status blocked </dev/null >"$HOME/notify.out" 2>&1 || { cat "$HOME/notify.out" >&2; fail "notify (blocked) failed"; }
  tmux set-option -p -t "$pane" @waycar_status done
  "$cli" notify --pane "tmux:$pane" --status done </dev/null >"$HOME/notify.out" 2>&1 || { cat "$HOME/notify.out" >&2; fail "notify (done) failed"; }
  tmux kill-server >/dev/null 2>&1 || true
else
  # herdr mode: herdr's pane.agent_status_changed event hook, with a stub
  # `herdr` for the status re-check and the Blocked/Done count.
  stub=$HOME/herdr-stub
  cat >"$stub" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "agent get") echo '{"result":{"agent":{"agent_status":"blocked","agent":"claude","pane_id":"w1:p1","workspace_id":"w1","cwd":"/work/demo"}}}' ;;
  "agent list") echo '{"result":{"agents":[{"pane_id":"w1:p1","agent_status":"blocked","agent":"claude","workspace_id":"w1"}]}}' ;;
  *) echo '{"result":{}}' ;;
esac
STUB
  chmod +x "$stub"
  mkdir -p "$HOME/herdr-state"
  HERDR_PLUGIN_CONFIG_DIR=$HOME/.config/waycar HERDR_PLUGIN_STATE_DIR=$HOME/herdr-state HERDR_BIN_PATH=$stub \
    HERDR_PLUGIN_EVENT_JSON='{"event":"pane_agent_status_changed","data":{"type":"pane_agent_status_changed","pane_id":"w1:p1","workspace_id":"w1","agent_status":"blocked","agent":"claude"}}' \
    "$cli" herdr-event notify </dev/null >"$HOME/notify.out" 2>&1 || { cat "$HOME/notify.out" >&2; fail "herdr-event notify failed"; }
fi
if [ -z "$WAYCAR_CHECK_HERDR" ]; then
  wait_for_requests $((before + 4))
  requests=$(relay_requests)
  count=$(printf '%s\n' "$requests" | grep -c '"url":"/push"' || true)
  pushes=$(printf '%s\n' "$requests" | grep -c '"kind":"push"' || true)
  activities=$(printf '%s\n' "$requests" | grep -c '"kind":"liveactivity"' || true)
  [ "$count" = 4 ] && [ "$pushes" = 2 ] && [ "$activities" = 2 ] \
    || { printf '%s\n' "$requests" >&2; fail "the stand-in relay got $count requests ($pushes pushes, $activities Live Activity updates), expected 4 (2 and 2)"; }
  ok "a Blocked and a Done change sent 2 pushes and 2 Live Activity updates to the stand-in relay"
else
  wait_for_requests $((before + 1))
  requests=$(relay_requests)
  printf '%s\n' "$requests" | grep -q '"url":"/push","kind":"push"' || { printf '%s\n' "$requests" >&2; fail "no push reached the stand-in relay"; }
  ok "herdr-event notify sent a push to the stand-in relay"
fi

# 7. Chat Mode: `waycar chat-read` over a Claude transcript, the way the app
# runs it (one JSON request on stdin).
mkdir -p "$HOME/.claude/projects/-work-demo"
cat >"$HOME/.claude/projects/-work-demo/s-demo.jsonl" <<'JSONL'
{"type":"user","uuid":"u1","parentUuid":null,"isSidechain":false,"timestamp":"2026-09-30T12:00:00.000Z","cwd":"/work/demo","sessionId":"s-demo","message":{"role":"user","content":"Why does the build fail?"}}
{"type":"assistant","uuid":"a1","parentUuid":null,"isSidechain":false,"timestamp":"2026-09-30T12:00:03.000Z","cwd":"/work/demo","sessionId":"s-demo","message":{"id":"msg-a1","role":"assistant","content":[{"type":"text","text":"The linker cannot find libssl."}],"stop_reason":"end_turn"}}
JSONL
chat=$(printf '%s' '{"kind":"claude","session_kind":"id","session_value":"s-demo","cwd":"/work/demo","status":"done"}' | "$cli" chat-read --request -) || fail "chat-read exited $?"
case $chat in '{"type":"header","v":1,"kind":"claude","status":"ok",'*) ;; *) fail "chat-read header: $chat" ;; esac
printf '%s\n' "$chat" | grep -q '"role":"user","text":"Why does the build fail?"' || fail "chat-read lost the user message: $chat"
printf '%s\n' "$chat" | grep -q '"role":"assistant","text":"The linker cannot find libssl."' || fail "chat-read lost the assistant reply: $chat"
ok "chat-read answers a Claude transcript: header ok, the user message and the reply"

# 8. Agent Summaries: the refresh runs without an agent CLI and prints its JSON.
summary=$("$cli" summaries refresh </dev/null 2>&1) || fail "summaries refresh exited $?: $summary"
case $summary in '{"ran":'*) ;; *) fail "summaries refresh printed: $summary" ;; esac
ok "summaries refresh prints $summary"
INNER
}

# Root prepares the image: the distribution's tmux, curl, host keys for the
# Pairing Code (it pins the SSH host key fingerprint; ssh-keygen -A makes them,
# no sshd is installed, which on Debian would pull in procps and its ps), and
# a user.
root_prepare() {
  cat <<'INNER'
set -eu
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends tmux curl ca-certificates openssh-client >/dev/null 2>&1
  useradd -m -s /bin/sh tester
elif command -v apk >/dev/null 2>&1; then
  apk add --no-cache tmux curl openssh-keygen >/dev/null 2>&1
  adduser -D -s /bin/sh tester
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q tmux curl openssh >/dev/null 2>&1
  useradd -m -s /bin/sh tester
else
  echo "bare-install-check: no apt-get, apk or dnf in this image" >&2
  exit 1
fi
mkdir -p /etc/ssh
ssh-keygen -A >/dev/null 2>&1
for tool in node nodejs npm python3 python; do
  command -v "$tool" >/dev/null 2>&1 && { echo "bare-install-check: $tool is installed in $(command -v "$tool")" >&2; exit 1; }
done
echo "bare-install-check: $(. /etc/os-release && echo "$PRETTY_NAME"), tmux $(tmux -V | cut -d ' ' -f 2), arch $(uname -m)"
INNER
}

# The stand-in relay container: Python, outside the container under test.
# shellcheck disable=SC2086 # the docker arguments are words
relay=$(docker create ${WAYCAR_CHECK_DOCKER_ARGS:-} "${WAYCAR_CHECK_RELAY_IMAGE:-python:3-alpine}" python3 /relay-standin.py --port 8099)
trap 'docker rm -f "$relay" ${container:-} >/dev/null 2>&1' EXIT
docker cp "$here/relay-standin.py" "$relay:/relay-standin.py"
docker start "$relay" >/dev/null
# shellcheck disable=SC2086 # the docker arguments are words
container=$(docker create ${WAYCAR_CHECK_DOCKER_ARGS:-} --network "container:$relay" "$image" sleep 3600)
trap 'docker rm -f "$container" $relay >/dev/null 2>&1' EXIT
docker start "$container" >/dev/null
docker cp "$dist/." "$container:/dist"
root_prepare | docker exec -i "$container" sh
docker exec "$container" chmod -R a+rX /dist
user_checks | docker exec -i -u tester -e HOME=/home/tester -e "EXPECT_VERSION=$version" \
  -e "WAYCAR_CHECK_HERDR=$herdr" -e "WAYCAR_CHECK_RELAY=$relay_url" "$container" sh -eu
