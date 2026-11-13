#!/bin/sh
# Install the packaged Host Tools the way a user does and check what the
# native `waycar` does, with no Node anywhere on the machine under test.
#
#   scripts/ci/native-install-check.sh [--host] <dist-dir> [image]
#
# <dist-dir> is scripts/package-plugin.sh's output (install.sh and plugin/); its
# binaries must be for this machine's CPU.
#
# Default: a bare container (image defaults to ubuntu:24.04). It gets the dist
# directory (docker cp, so it works where host bind mounts are not allowed),
# and tmux and curl from apt. The push stand-in runs in a second container
# (WAYCAR_CHECK_RELAY_IMAGE, default python:3-alpine) on the same network, so
# the container under test has neither Node nor Python. WAYCAR_CHECK_DOCKER_ARGS
# adds docker create arguments to both, for the devbox labels and limits.
#
# --host: no container, for runners without Docker (CI). Everything happens
# under a throwaway HOME that is deleted afterwards, with an `env -i` PATH of
# the tmux directory plus /usr/bin:/bin. The runner supplies curl, tar, a
# SHA-256 tool and python3 (for the stand-in relay only: scripts/ci/
# relay-standin.py, the test's own server, never the Host under test). When the
# machine has no tmux 3.2 or later, the checks that need the agent hooks run
# `waycar hooks install` by hand first.
#
# Checks, in order:
#   1. install.sh --tmux downloads the tarball for this CPU, verifies its
#      SHA-256 and installs; bin/waycar is a native ELF or Mach-O file and the
#      install holds no Node file.
#   2. `waycar version` answers with PATH pointing nowhere.
#   3. `status --json`, `hooks status --json` and `summaries refresh`, the
#      Claude hook entries (they call waycar and waycar-hook, not Node), the
#      usage errors of `pair`, `hooks`, `notify` and `watch-approval`, and
#      `chat-read` on a Claude transcript.
#   4. The hook runtime: a Blocked status change on a tmux pane sends the push
#      and the Live Activity update to the stand-in relay (a plain-http
#      `relay_url`), and Done pushes again; `watch-approval` on a pane showing
#      agy's permission dialog marks it blocked, sends both, and exits when the
#      pane closes. Needs a tmux 3.2 or later.
#   5. A Host with only herdr-core (a stub `herdr-core`, never a real core):
#      install.sh without --tmux installs the CLI and the agent hooks, and
#      `status --json` reports backends.core; a foreign `hc` (herbstclient) is
#      not core; a Host with no backend at all fails with the message that names
#      herdr-core. The stub answers `--version` and logs anything else, which
#      must stay empty: any other subcommand would start a core. Runs before 4
#      and in a second throwaway HOME whose PATH has no tmux.
set -eu

host=
if [ "${1:-}" = --host ]; then
  host=1
  shift
fi
dist=${1:?usage: scripts/ci/native-install-check.sh [--host] <dist-dir> [image]}
image=${2:-ubuntu:24.04}
dist=$(cd "$dist" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$here/../../plugin/herdr-plugin.toml")

# The checks, as a script for `sh -eu` on stdin. WAYCAR_CHECK_MODE is `docker`
# or `host`; the caller sets EXPECT_VERSION, and for `docker` WAYCAR_CHECK_RELAY
# (the stand-in's URL), for `host` HOME, WAYCAR_CHECK_DIST and
# WAYCAR_CHECK_RELAY_SCRIPT.
checks() {
  cat <<'INNER'
fail() { echo "native-install-check: FAIL: $*" >&2; exit 1; }
ok() { echo "native-install-check: ok: $*"; }
skip() { echo "native-install-check: skip: $*"; }
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

tmux_dir=
if [ "$WAYCAR_CHECK_MODE" = docker ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends tmux curl ca-certificates >/dev/null 2>&1
  export HOME=/home/tester
  dist=/dist
else
  dist=$WAYCAR_CHECK_DIST
  command -v curl >/dev/null 2>&1 || fail "curl not found on the host"
  command -v tar >/dev/null 2>&1 || fail "tar not found on the host"
  command -v python3 >/dev/null 2>&1 || fail "python3 not found on the host (the stand-in relay needs it)"
  if command -v tmux >/dev/null 2>&1; then tmux_dir=$(dirname "$(command -v tmux)"); fi
fi
mkdir -p "$HOME/.claude" "$HOME/check-work"
work=$HOME/check-work
base_path=${tmux_dir:+$tmux_dir:}/usr/bin:/bin
plugin=$HOME/.local/share/waycar/plugin
cli=$HOME/.local/bin/waycar

# tmux 3.2 or later on the PATH, as install.sh's own gate sees it.
tmux_ok=
if tmux_version=$(env -i PATH=$base_path tmux -V 2>/dev/null </dev/null); then
  case ${tmux_version#tmux } in
    3.[2-9]* | 3.[1-9][0-9]* | [4-9].* | [1-9][0-9].* | next-* | openbsd-* | master) tmux_ok=1 ;;
  esac
fi

run() { env -i HOME="$HOME" PATH=$base_path "$@"; }

# 1. Install.
env -i HOME="$HOME" PATH=$base_path WAYCAR_INSTALL_BASE_URL=file://$dist WAYCAR_NO_PAIR=1 \
  sh "$dist/install.sh" --tmux </dev/null >"$work/install.log" 2>&1 \
  || { cat "$work/install.log" >&2; fail "install.sh --tmux failed"; }
magic=$(head -c 4 "$plugin/bin/waycar" | od -An -tx1 | tr -d " ")
case $(uname -s) in
  Linux) want=7f454c46 ;;
  Darwin) want=cffaedfe ;;
  *) fail "unsupported OS $(uname -s)" ;;
esac
[ "$magic" = "$want" ] || fail "bin/waycar is not a native binary (magic $magic, expected $want)"
[ -x "$plugin/bin/waycar" ] || fail "bin/waycar is not executable"
[ -L "$cli" ] || fail "$cli was not linked"
for leftover in bin/node.sh src node_modules package.json package-lock.json; do
  [ ! -e "$plugin/$leftover" ] || fail "the install has $leftover"
done
ok "installed; bin/waycar is a native binary and the tree has no Node files"

# 2. The version, with nothing on PATH.
out=$(env -i HOME="$HOME" PATH=/nonexistent "$cli" version) || fail "waycar version failed with an empty PATH"
[ "$out" = "waycar $EXPECT_VERSION" ] || fail "waycar version printed: $out"
ok "waycar version needs nothing on PATH: $out"

# 3. status, hooks, summaries, usage errors, chat-read.
if [ -z "$tmux_ok" ]; then
  # install.sh installs the hooks only next to a tmux it accepts.
  run "$cli" hooks install </dev/null >/dev/null 2>&1 || fail "hooks install"
  skip "no tmux 3.2 or later on this machine (${tmux_version:-no tmux}): ran hooks install by hand"
fi
status=$(run "$cli" status --json </dev/null) || fail "status --json"
case $status in "{\"version\":1,\"hostTools\":{\"version\":\"$EXPECT_VERSION\","*) ;; *) fail "status --json: $status" ;; esac
if [ -n "$tmux_version" ]; then
  case $(backends "$status") in 'herdr=false tmux="'?*'" core=null zellij=null') ;; *) fail "status --json should report tmux and no core or zellij: $status" ;; esac
else
  case $(backends "$status") in *' tmux=null core=null zellij=null') ;; *) fail "status --json should report no tmux, core or zellij: $status" ;; esac
fi
ok "status --json: version matches, tmux reported as ${tmux_version:-absent}"
hooks=$(run "$cli" hooks status --json </dev/null) || fail "hooks status --json"
case $hooks in *'"agent":"claude","detected":true,"installed":true,'*) ;; *) fail "hooks status --json should show claude installed: $hooks" ;; esac
! grep -qi node "$HOME/.claude/settings.json" || fail "the Claude hook entries mention Node: $(grep -i node "$HOME/.claude/settings.json")"
grep -q "'$plugin/bin/waycar' hook-session claude" "$HOME/.claude/settings.json" || fail "no SessionStart entry runs waycar hook-session"
grep -q "'$plugin/bin/waycar-hook' claude working" "$HOME/.claude/settings.json" || fail "no entry runs waycar-hook"
ok "hooks status --json: claude hooks installed, calling waycar and waycar-hook"
summary=$(run "$cli" summaries refresh </dev/null 2>&1) || fail "summaries refresh exited $?: $summary"
case $summary in '{"ran":'*) ;; *) fail "summaries refresh printed: $summary" ;; esac
ok "summaries refresh prints $summary"
for args in "pair extra" "hooks bogus" "notify --pane tmux:%1" "watch-approval --pane tmux:%1 --agent nobody"; do
  # shellcheck disable=SC2086 # splitting is the point
  set +e; run "$cli" $args </dev/null >/dev/null 2>"$work/err"; code=$?; set -e
  [ "$code" = 2 ] || fail "waycar $args exited $code, expected 2 ($(cat "$work/err"))"
  grep -q "^waycar: " "$work/err" || fail "waycar $args printed no waycar: error"
done
ok "usage errors exit 2 with the usage text"
mkdir -p "$HOME/.claude/projects/-work-demo"
cat >"$HOME/.claude/projects/-work-demo/s-demo.jsonl" <<'JSONL'
{"type":"user","uuid":"u1","parentUuid":null,"isSidechain":false,"timestamp":"2026-09-30T12:00:00.000Z","cwd":"/work/demo","sessionId":"s-demo","message":{"role":"user","content":"Why does the build fail?"}}
{"type":"assistant","uuid":"a1","parentUuid":null,"isSidechain":false,"timestamp":"2026-09-30T12:00:03.000Z","cwd":"/work/demo","sessionId":"s-demo","message":{"id":"msg-a1","role":"assistant","content":[{"type":"text","text":"The linker cannot find libssl."}],"stop_reason":"end_turn"}}
JSONL
chat=$(printf '%s' '{"kind":"claude","session_kind":"id","session_value":"s-demo","cwd":"/work/demo","status":"done"}' | run "$cli" chat-read --request -) || fail "chat-read exited $?"
case $chat in '{"type":"header","v":1,"kind":"claude","status":"ok",'*) ;; *) fail "chat-read header: $chat" ;; esac
printf '%s\n' "$chat" | grep -q '"role":"assistant","text":"The linker cannot find libssl."' || fail "chat-read lost the reply: $chat"
ok "chat-read answers a Claude transcript"

# 5. A Host with only herdr-core. PATH is every /usr/bin and /bin program but
# the backends, so the machine's own tmux cannot make this Host a tmux Host.
nobackend=$work/nobackend
mkdir -p "$nobackend"
for tool in /usr/bin/* /bin/*; do
  case ${tool##*/} in tmux | herdr | herdr-core | hc | zellij) continue ;; esac
  [ -e "$tool" ] && [ ! -e "$nobackend/${tool##*/}" ] && ln -s "$tool" "$nobackend/${tool##*/}"
done
core_home=$work/core-home
mkdir -p "$core_home/.claude" "$core_home/.local/bin"
core_log=$work/core-calls
: >"$core_log"
# Off PATH, in ~/.local/bin: where core's installer puts it and an SSH exec's
# PATH does not look.
cat >"$core_home/.local/bin/herdr-core" <<STUB
#!/bin/sh
[ "\$1" = --version ] && { echo 'hc 0.1.14'; exit 0; }
echo "\$*" >>'$core_log'
exit 1
STUB
chmod +x "$core_home/.local/bin/herdr-core"
core_plugin=$core_home/.local/share/waycar/plugin
core_cli=$core_home/.local/bin/waycar
env -i HOME="$core_home" PATH="$nobackend" WAYCAR_INSTALL_BASE_URL=file://$dist WAYCAR_NO_PAIR=1 \
  sh "$dist/install.sh" </dev/null >"$work/core-install.log" 2>&1 \
  || { cat "$work/core-install.log" >&2; fail "install.sh on a core-only Host failed"; }
grep -q "setting Waycar up for herdr-core 0.1.14" "$work/core-install.log" || fail "install.sh did not name herdr-core: $(cat "$work/core-install.log")"
grep -q "^waycar: installed Waycar $EXPECT_VERSION in $core_plugin\$" "$work/core-install.log" || fail "the install line changed: $(cat "$work/core-install.log")"
[ -L "$core_cli" ] || fail "a core-only Host got no $core_cli"
core_status=$(env -i HOME="$core_home" PATH="$nobackend" "$core_cli" status --json </dev/null) || fail "core-only status --json"
[ "$(backends "$core_status")" = 'herdr=false tmux=null core="0.1.14" zellij=null' ] || fail "status --json should report only core 0.1.14: $core_status"
core_hooks=$(env -i HOME="$core_home" PATH="$nobackend" "$core_cli" hooks status --json </dev/null) || fail "core-only hooks status --json"
case $core_hooks in *'"agent":"claude","detected":true,"installed":true,'*) ;; *) fail "install.sh left no Claude hooks on a core-only Host: $core_hooks" ;; esac
grep -q "'$core_plugin/bin/waycar-hook' claude working" "$core_home/.claude/settings.json" || fail "no entry runs waycar-hook on a core-only Host"
[ ! -s "$core_log" ] || fail "something ran herdr-core beyond --version: $(cat "$core_log")"
ok "a core-only Host: install.sh linked the CLI and installed the hooks, status --json reports core 0.1.14, only --version ran"

# A foreign `hc` is not core, for the status probe and for install.sh.
foreign=$work/foreign
mkdir -p "$foreign"
printf '#!/bin/sh\necho "hc: herbstclient 0.9"\n' >"$foreign/hc"
chmod +x "$foreign/hc"
foreign_status=$(env -i HOME="$HOME" PATH="$foreign:$base_path" "$cli" status --json </dev/null) || fail "status --json with a foreign hc"
case $(backends "$foreign_status") in *' core=null '*) ;; *) fail "a foreign hc was reported as core: $foreign_status" ;; esac
nothing_home=$work/nothing-home
mkdir -p "$nothing_home"
want_error="waycar: error: neither herdr, herdr-core, tmux 3.2+ nor Zellij 0.46+ found; install a supported runtime"
set +e
env -i HOME="$nothing_home" PATH="$foreign:$nobackend" WAYCAR_INSTALL_BASE_URL=file://$dist WAYCAR_NO_PAIR=1 \
  sh "$dist/install.sh" </dev/null >"$work/nothing.out" 2>&1
code=$?
set -e
[ "$code" != 0 ] || fail "install.sh succeeded on a Host with no backend and a foreign hc"
grep -qF "$want_error" "$work/nothing.out" || fail "the no-backend error changed: $(cat "$work/nothing.out")"
[ ! -e "$nothing_home/.local/share/waycar/plugin" ] || fail "a failed install left the plugin behind"
ok "a foreign hc is not core; a Host with no backend fails naming herdr-core"

# 4. The hook runtime sends the push and the Live Activity update.
mkdir -p "$work/tmux" "$HOME/.config/waycar"
relay_pid=
tmux_env() { env -i HOME="$HOME" PATH="$base_path" TMUX_TMPDIR="$work/tmux" "$@"; }
cleanup() {
  [ -z "$relay_pid" ] || kill "$relay_pid" 2>/dev/null || true
  tmux_env tmux kill-server 2>/dev/null || true
}
trap cleanup EXIT

if [ -z "$tmux_ok" ]; then
  skip "no tmux 3.2 or later on this machine (${tmux_version:-no tmux}): the hook runtime was not run"
  exit 0
fi

if [ "$WAYCAR_CHECK_MODE" = docker ]; then
  relay_url=$WAYCAR_CHECK_RELAY
else
  python3 "$WAYCAR_CHECK_RELAY_SCRIPT" --port-file "$work/port" &
  relay_pid=$!
  waited=0
  until [ -s "$work/port" ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 100 ] || fail "the stand-in relay did not start"
    sleep 0.1
  done
  relay_url=http://127.0.0.1:$(cat "$work/port")
fi
relay_requests() { curl -fsS "$relay_url/requests"; }
relay_count() { relay_requests | grep -c '^{' || true; }
waited=0
until relay_requests >/dev/null 2>&1; do
  waited=$((waited + 1))
  [ "$waited" -lt 100 ] || fail "the stand-in relay at $relay_url does not answer"
  sleep 0.1
done
cat >"$HOME/.config/waycar/notify.json" <<JSON
{"relay_url":"$relay_url","debounce_ms":0,"activity_debounce_ms":0,"activity_start_grace_ms":0,"retry_delay_ms":0}
JSON
cat >"$HOME/.config/waycar/notifications.json" <<'JSON'
{"v":1,"devices":[{"token":"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","env":"sandbox","notify":{"blocked":true,"done":true},"live_activity":{"token":"c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3"}}]}
JSON
# `exec`: the pane's command is `sleep`, not the login shell tmux runs it
# through (dash stays the foreground process, and a pane at a shell is no Agent).
tmux_env tmux -f /dev/null new-session -d -s wc -x 100 -y 30 'exec sleep 600' || fail "could not start a tmux server"
pane=$(tmux_env tmux list-panes -a -F '#{pane_id}' | sed -n 1p)
[ -n "$pane" ] || fail "tmux has no pane"
tmux_env tmux set-option -p -t "$pane" @waycar_agent claude
tmux_env tmux set-option -p -t "$pane" @waycar_status blocked
native() { env -i HOME="$HOME" PATH="$base_path" TMUX_TMPDIR="$work/tmux" "$cli" "$@" </dev/null; }
native notify --pane "tmux:$pane" --status blocked >"$work/native.out" 2>&1 \
  || { cat "$work/native.out" >&2; fail "notify (blocked) failed"; }
[ "$(relay_count)" = 2 ] || { relay_requests >&2; fail "notify (blocked) sent $(relay_count) relay requests, expected 2"; }
relay_requests | grep -q '"url":"/push","kind":"push","body":{"token":"a1b2' || fail "no push request reached the stand-in relay"
relay_requests | grep -q '"kind":"liveactivity"' || fail "no Live Activity request reached the stand-in relay"
ok "notify: a Blocked change sent the push and the Live Activity update"
tmux_env tmux set-option -p -t "$pane" @waycar_status done
native notify --pane "tmux:$pane" --status done >"$work/native.out" 2>&1 \
  || { cat "$work/native.out" >&2; fail "notify (done) failed"; }
[ "$(relay_count)" = 4 ] || { relay_requests >&2; fail "notify (done) left $(relay_count) relay requests, expected 4"; }
ok "notify: a Done change sent them again"
# The watch's notifications come from threads that write to stderr while the
# main thread waits for them; this runs that path for real (a pane showing
# agy's permission dialog), which the unit tests' closure notifier does not.
agy_pane=$(tmux_env tmux new-window -d -P -F '#{pane_id}' \
  "printf '\n  Allow this command?\n  ↑/↓ Navigate · tab Amend · esc Skip\n  esc to cancel\n'; exec sleep 600") \
  || fail "could not start the agy dialog pane"
tmux_env tmux set-option -p -t "$agy_pane" @waycar_agent agy
tmux_env tmux set-option -p -t "$agy_pane" @waycar_status working
tmux_env tmux set-option -p -t "$agy_pane" @waycar_seq 1
native watch-approval --pane "tmux:$agy_pane" --agent agy >"$work/watch.out" 2>&1 &
watch_pid=$!
waited=0
until [ "$(relay_count)" = 6 ]; do
  waited=$((waited + 1))
  [ "$waited" -lt 100 ] || { cat "$work/watch.out" >&2; relay_requests >&2; kill "$watch_pid" 2>/dev/null || true; fail "watch-approval sent $(relay_count) relay requests after 10 s, expected 6 (the Blocked push and Live Activity update)"; }
  sleep 0.1
done
[ "$(tmux_env tmux display-message -p -t "$agy_pane" '#{@waycar_status}')" = blocked ] || fail "watch-approval did not mark the agy pane blocked"
tmux_env tmux kill-pane -t "$agy_pane"
waited=0
while kill -0 "$watch_pid" 2>/dev/null; do
  waited=$((waited + 1))
  [ "$waited" -lt 100 ] || { kill "$watch_pid" 2>/dev/null || true; fail "watch-approval did not exit within 10 s of its pane closing"; }
  sleep 0.1
done
wait "$watch_pid" || fail "watch-approval exited $?: $(cat "$work/watch.out")"
ok "watch-approval: an agy dialog marked the pane blocked, sent the push and the Live Activity update, and exited with the pane"
INNER
}

if [ -n "$host" ]; then
  home=$(mktemp -d)
  trap 'rm -rf "$home"' EXIT
  checks | env -i PATH=/usr/bin:/bin HOME="$home" WAYCAR_CHECK_MODE=host WAYCAR_CHECK_DIST="$dist" \
    WAYCAR_CHECK_RELAY_SCRIPT="$here/relay-standin.py" EXPECT_VERSION="$version" sh -eu
else
  # The stand-in relay's container: Python, outside the container under test.
  # shellcheck disable=SC2086 # the docker arguments are words
  relay=$(docker create ${WAYCAR_CHECK_DOCKER_ARGS:-} "${WAYCAR_CHECK_RELAY_IMAGE:-python:3-alpine}" python3 /relay-standin.py --port 8099)
  trap 'docker rm -f "$relay" ${container:-} >/dev/null 2>&1' EXIT
  docker cp "$here/relay-standin.py" "$relay:/relay-standin.py"
  docker start "$relay" >/dev/null
  # shellcheck disable=SC2086 # the docker arguments are words
  container=$(docker create ${WAYCAR_CHECK_DOCKER_ARGS:-} --network "container:$relay" "$image" sleep 3600)
  docker start "$container" >/dev/null
  docker cp "$dist/." "$container:/dist"
  checks | docker exec -i -e WAYCAR_CHECK_MODE=docker -e "EXPECT_VERSION=$version" \
    -e WAYCAR_CHECK_RELAY=http://127.0.0.1:8099 "$container" sh -eu
fi
