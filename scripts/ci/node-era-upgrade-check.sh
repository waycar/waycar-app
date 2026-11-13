#!/bin/sh
# The Node-era upgrade proof of WAY-443: a Host that installed the Node
# version of the Host Tools moves to the native ones with one run of the app's
# own update command, and nothing that is the user's changes.
#
#   scripts/ci/node-era-upgrade-check.sh <dist-dir> <old-version> [image]
#
# <dist-dir> is scripts/package-plugin.sh's output (install.sh and plugin/).
# <old-version> is a released plugin to start from: 1.6.0 is the last one that
# is only Node, 1.7.0 the first that also carries a native bin/waycar beside
# the JS tree. Its release assets come from `gh release download` in
# $WAYCAR_OLD_REPO (default waycar/waycar-app, whose releases start at the
# open-source cut, so the Node-era ones need the archive or the next
# option) or from $WAYCAR_OLD_DIR, a directory holding install.sh and the
# tarball. image
# defaults to ubuntu:24.04; alpine:3.20 works too. Needs Docker (the devbox
# daemon is fine); the container carries the labels the devbox rules ask for.
#
# What runs: one container with sshd, Node, tmux and python3. waycar.dev is a
# local HTTPS server (a throwaway certificate the container trusts) serving
# <dist-dir>, so the app's real update command, from
# scripts/ci/fixtures/waycar-update-command.*.txt (a Swift test pins them to
# WaycarPluginUpdate.command), runs over real sshd, unchanged.
#
# Before the update the Host is a Node-era one: the old release installed in
# tmux mode, hooks for claude and codex, the opencode Chat Prompt extension, a
# device paired through a real Enrollment, a notification registration, the
# leftovers install.sh must delete, the user's own Node marker files, and a
# Node process running from the old tree. The config, keys, authorized_keys
# and the @waycar_* pane options are hashed. After the update, Node is
# removed from the Host and the check asserts:
#   - the hashes are equal
#   - no node.sh, src/*.js, node_modules or package*.json; no .new or .old
#   - the leftovers are gone, the user's own Node files are not
#   - no agent hook entry names node.sh; Codex is told to review /hooks
#   - the old Node process is counted in the output and still alive
#   - status --json, a hook event, a push request and Live Activity update, a
#     chat read and a summary refresh work; the paired device logs in; a new
#     pairing enrolls through the new forced command (needs lib-pair.sh)
#   - a second update changes nothing
# The failure drills run first, while Node is still on the Host: a noexec
# install directory leaves the old install working, and SIGKILLs at different
# moments of an update never leave a Host without a working install.
set -eu

dist=${1:?usage: scripts/ci/node-era-upgrade-check.sh <dist-dir> <old-version> [image]}
old_version=${2:?old version needed}
image=${3:-ubuntu:24.04}
root=$(cd "$(dirname "$0")/../.." && pwd)
dist=$(cd "$dist" && pwd)
slug=${DEVBOX_AGENT:-cto}
expires=$(date -u -d '+4 hours' +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -v+4H +%Y-%m-%dT%H:%MZ)
name=waycar-upgrade-check-$$
new_version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$root/plugin/herdr-plugin.toml")

docker info >/dev/null 2>&1 || { echo "node-era-upgrade-check: docker is not available" >&2; exit 1; }

old=${WAYCAR_OLD_DIR:-}
if [ -z "$old" ]; then
  old=$(mktemp -d)
  gh release download "plugin-v$old_version" -R "${WAYCAR_OLD_REPO:-waycar/waycar-app}" --dir "$old" -p install.sh -p '*.tar.gz' -p '*.sha256' >/dev/null
fi
old=$(cd "$old" && pwd)

# WAYCAR_KEEP=1 leaves the container for a look at a failure (remove it by hand).
cleanup() { [ -n "${WAYCAR_KEEP:-}" ] || docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# The tmpfs is the noexec mount of the first failure drill.
docker run -d --rm --cpus 2 --memory 3g --pids-limit 2048 \
  --tmpfs /nx:rw,noexec,nosuid,mode=1777 \
  --label "agent=$slug" --label disposable=true --label "expires=$expires" \
  --name "$name" "$image" sleep 3000 >/dev/null
docker cp "$dist/." "$name:/dist"
docker cp "$old/." "$name:/old"
docker exec "$name" mkdir -p /fixtures /opt
docker cp "$root/scripts/ci/fixtures/." "$name:/fixtures"
if [ -f "$root/scripts/ci/lib-pair.sh" ]; then docker cp "$root/scripts/ci/lib-pair.sh" "$name:/fixtures/lib-pair.sh"; fi

# Root side: packages, Node, sshd, the local waycar.dev, the relay stand-in.
root_script() {
  cat <<'INNER'
set -eu
# `docker exec` on the devbox daemon starts with umask 0000; sshd refuses a
# world-writable /run/sshd.
umask 022
. /etc/os-release
arch=$(uname -m)
case $ID in
  alpine)
    apk add --no-cache openssh openssh-client tmux curl ca-certificates python3 openssl nodejs jq shadow >/dev/null
    adduser -D -s /bin/sh tester
    ;;
  *)
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -qq --no-install-recommends openssh-server openssh-client tmux curl ca-certificates \
      python3 openssl xz-utils procps jq >/dev/null 2>&1
    node_version=24.21.0
    case $arch in
      x86_64) node_arch=x64; node_sha=fd8e59d5a511510f6a298afb548f18c7d2b1be404d8b4a27d94fbe49f56cb2d6 ;;
      aarch64) node_arch=arm64; node_sha=6ad1325edbdb5649c379b75a237147a666c95d4f9ae8d340fef2d1575d289ad2 ;;
    esac
    curl -fsSL -o /tmp/node.tar.xz "https://nodejs.org/dist/v$node_version/node-v$node_version-linux-$node_arch.tar.xz"
    [ "$(sha256sum /tmp/node.tar.xz | cut -d' ' -f1)" = "$node_sha" ] || { echo "node checksum mismatch" >&2; exit 1; }
    mkdir -p /opt/node && tar -xJf /tmp/node.tar.xz -C /opt/node --strip-components=1
    for f in node npm npx; do ln -s /opt/node/bin/$f /usr/local/bin/$f; done
    useradd -m -s /bin/sh tester
    ;;
esac
# A password field of `!` makes sshd treat the account as locked.
sed -i 's/^tester:[^:]*:/tester:*:/' /etc/shadow
mkdir -p /run/sshd
ssh-keygen -A >/dev/null
/usr/sbin/sshd -p 2222 -o PasswordAuthentication=no -o UsePAM=no -o PermitRootLogin=no -E /tmp/sshd.log

# waycar.dev, locally, with a certificate this container trusts.
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=waycar.dev \
  -addext subjectAltName=DNS:waycar.dev -keyout /opt/site.key -out /opt/site.crt 2>/dev/null
mkdir -p /usr/local/share/ca-certificates
cp /opt/site.crt /usr/local/share/ca-certificates/waycar-test.crt
update-ca-certificates >/dev/null 2>&1
echo '127.0.0.1 waycar.dev' >>/etc/hosts
cat >/opt/site.py <<'PY'
import http.server, os, ssl, time
class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory="/dist", **k)
    def do_GET(self):
        # While /tmp/slow exists a package download stalls half way, so a test
        # can kill an update in the middle of it.
        if self.path.startswith("/plugin/") and os.path.exists("/tmp/slow"):
            path = self.translate_path(self.path.split("?")[0])
            data = open(path, "rb").read()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data[: len(data) // 2])
            self.wfile.flush()
            time.sleep(8)
            self.wfile.write(data[len(data) // 2 :])
            return
        super().do_GET()
    def log_message(self, *a):
        pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 443), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain("/opt/site.crt", "/opt/site.key")
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
PY
nohup python3 /opt/site.py >/tmp/site.log 2>&1 &
cat >/opt/relay.py <<'PY'
import http.server, json, sys
out = sys.argv[1]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        with open(out + "/requests.jsonl", "a") as f:
            f.write(json.dumps({"url": self.path, "body": json.loads(body)}) + "\n")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")
    def log_message(self, *a):
        pass
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
open(out + "/port", "w").write(str(server.server_address[1]))
server.serve_forever()
PY
# An OpenSSH private key from a Bootstrap seed (the Node-era beginPairing hands back the seed).
cat >/opt/seed-to-key.py <<'PY'
import base64, struct, sys
seed = base64.b64decode(sys.argv[1])
pub = base64.b64decode(sys.argv[2].split()[1])[-32:]
def s(b): return struct.pack(">I", len(b)) + b
keyblob = s(b"ssh-ed25519") + s(pub)
check = b"\x01\x02\x03\x04"
private = check + check + s(b"ssh-ed25519") + s(pub) + s(seed + pub) + s(b"")
private += bytes(range(1, (8 - len(private) % 8) % 8 + 1))
blob = b"openssh-key-v1\x00" + s(b"none") + s(b"none") + s(b"") + struct.pack(">I", 1) + s(keyblob) + s(private)
b64 = base64.b64encode(blob).decode()
print("-----BEGIN OPENSSH PRIVATE KEY-----")
for i in range(0, len(b64), 70): print(b64[i:i+70])
print("-----END OPENSSH PRIVATE KEY-----")
PY
waited=0
until curl -fsS -o /dev/null https://waycar.dev/install.sh; do
  waited=$((waited + 1)); [ "$waited" -lt 50 ] || { cat /tmp/site.log >&2; echo "local waycar.dev did not start" >&2; exit 1; }
  sleep 0.2
done
INNER
}

# Root step between the update and the checks that follow.
remove_node_script() {
  cat <<'INNER'
set -eu
. /etc/os-release
case $ID in
  alpine) apk del nodejs >/dev/null ;;
  *) rm -rf /opt/node /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx ;;
esac
! command -v node >/dev/null 2>&1 || { echo "node is still on PATH: $(command -v node)" >&2; exit 1; }
INNER
}

# Tester side: one script, run once per phase (`sh /opt/check.sh <phase>`).
check_script() {
  cat <<'INNER'
set -eu
umask 022
phase=${1:?phase}
H=$HOME
work=$H/check-work
plugin=$H/.local/share/waycar/plugin
export PATH="$H/.local/bin:/usr/local/bin:/usr/bin:/bin"
keys=$H/.ssh/authorized_keys
mkdir -p "$work" "$H/.ssh"
chmod 700 "$H/.ssh"

fail() { echo "node-era-upgrade-check: FAIL: $*" >&2; exit 1; }
ok() { echo "node-era-upgrade-check: ok: $*"; }
expect() { [ "$2" = "$3" ] || fail "$1: expected [$2], got [$3]"; ok "$1"; }
ssh_opts="-p 2222 -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
# shellcheck disable=SC2086 # the options are words
ssh_as() { key=$1; shift; ssh -i "$key" $ssh_opts tester@127.0.0.1 "$@"; }
app_ssh() { ssh_as "$work/app" "$@"; }

installed_version() { sed -n 's/^version = "\(.*\)"$/\1/p' "$plugin/herdr-plugin.toml" | head -n 1; }

install_old() {
  rm -rf "$plugin" "$plugin.old" "$plugin.new" "$H/.local/bin/waycar"
  WAYCAR_NO_PAIR=1 WAYCAR_PLUGIN_SOURCE="$work/oldpkg/waycar" sh /old/install.sh --tmux </dev/null >"$work/old-install.log" 2>&1 \
    || { cat "$work/old-install.log" >&2; fail "installing plugin $WAYCAR_OLD_VERSION failed"; }
}

snapshot() {
  {
    find "$H/.config/waycar" "$H/.local/state/waycar" -type f ! -path '*/bridge-off/*' ! -path '*/update.lock/*' 2>/dev/null | sort \
      | while IFS= read -r f; do printf '%s %s\n' "$(sha256sum <"$f" | cut -d' ' -f1)" "$f"; done
    printf 'authorized_keys %s\n' "$(sha256sum <"$keys" | cut -d' ' -f1)"
    tmux list-panes -a -F '#{pane_id} #{@waycar_agent} #{@waycar_status}'
  } | sha256sum | cut -d' ' -f1
}
# Everything an update must leave as it is on a second run.
tree_state() {
  { cat "$H/.claude/settings.json" "$H/.codex/hooks.json" "$H/.codex/config.toml" \
      "$H/.config/opencode/plugins/waycar-chat-prompt.js" 2>/dev/null
    find "$plugin" -type f | sort | xargs sha256sum
    ls -A "$H/.local/share/waycar"
    readlink "$H/.local/bin/waycar"; } | sha256sum | cut -d' ' -f1
}

start_relay() {
  mkdir -p "$work/relay"
  rm -f "$work/relay/port"
  nohup setsid python3 /opt/relay.py "$work/relay" >/dev/null 2>&1 &
  waited=0
  until [ -s "$work/relay/port" ]; do waited=$((waited + 1)); [ "$waited" -lt 100 ] || fail "the stand-in relay did not start"; sleep 0.1; done
  cat >"$H/.config/waycar/notify.json" <<JSON
{"relay_url":"http://127.0.0.1:$(cat "$work/relay/port")","debounce_ms":0,"activity_debounce_ms":0,"activity_start_grace_ms":0,"retry_delay_ms":0}
JSON
}
relay_requests() { [ -s "$work/relay/requests.jsonl" ] && wc -l <"$work/relay/requests.jsonl" | tr -d ' ' || echo 0; }

case $phase in
prep)
  ssh-keygen -q -t ed25519 -N '' -C laptop -f "$work/app"
  cat "$work/app.pub" >"$keys"
  chmod 600 "$keys"
  mkdir -p "$H/.claude" "$H/.codex" "$H/.local/bin"
  printf '#!/bin/sh\nexit 0\n' >"$H/.local/bin/opencode"
  chmod 755 "$H/.local/bin/opencode"
  # The user's own Node, which nothing may touch.
  mkdir -p "$H/.nvm/versions/node/v20.0.0/bin" "$H/.npm/_cacache"
  echo mine >"$H/.nvm/versions/node/v20.0.0/bin/node"
  echo mine >"$H/.npm/_cacache/index"

  arch_target=$(uname -m | sed 's/x86_64/x86_64-unknown-linux-musl/;s/aarch64/aarch64-unknown-linux-musl/')
  old_tar=$(ls /old/waycar-"$WAYCAR_OLD_VERSION"-*"$arch_target"*.tar.gz 2>/dev/null | sed -n 1p || true)
  [ -n "$old_tar" ] || old_tar=$(ls /old/waycar-"$WAYCAR_OLD_VERSION"-*.tar.gz | sed -n 1p)
  mkdir -p "$work/oldpkg"
  tar -xzf "$old_tar" -C "$work/oldpkg"
  ;;

old)
  # --- A Node-era Host -----------------------------------------------------
  tmux -f /dev/null new-session -d -s main -x 100 -y 30 'exec sleep 3000'
  install_old
  { [ -f "$plugin/bin/node.sh" ] && [ -d "$plugin/node_modules" ] && [ -f "$plugin/src/waycar-cli.js" ]; } || fail "the old package is not a Node-era install"
  expect "plugin $WAYCAR_OLD_VERSION is installed" "$WAYCAR_OLD_VERSION" "$(installed_version)"
  grep -q 'node.sh' "$H/.claude/settings.json" || fail "claude hooks do not call node.sh in the old install"
  grep -q 'node.sh' "$H/.codex/hooks.json" || fail "codex hooks do not call node.sh in the old install"
  grep -q 'host-config.js' "$H/.config/opencode/plugins/waycar-chat-prompt.js" || fail "no Node-era opencode extension"
  ok "a Node-era Host: node.sh, src, node_modules, claude and codex hooks, the opencode extension"

  # Pair: a real Enrollment over sshd, the old accept script as the forced command.
  node --input-type=module -e '
import { beginPairing } from "'"$plugin"'/src/pairing-session.js";
const r = await beginPairing({ home: process.env.HOME, stateDir: process.env.HOME + "/.local/state/waycar" });
console.log(JSON.stringify({ id: r.pairingId, seed: r.seed.toString("base64"), publicLine: r.publicLine }));
' >"$work/begin.json" || fail "the old pairing session did not start"
  python3 /opt/seed-to-key.py "$(jq -r .seed "$work/begin.json")" "$(jq -r .publicLine "$work/begin.json")" >"$work/bootstrap"
  chmod 600 "$work/bootstrap"
  ssh-keygen -q -t ed25519 -N '' -C "waycar device" -f "$work/device"
  out=$(ssh_as "$work/bootstrap" waycar-enroll <"$work/device.pub") || fail "Enrollment failed: $out"
  case $out in HERDR-ENROLL:OK:*) ok "paired a device through the Node-era forced command ($out)" ;; *) fail "Enrollment said: $out" ;; esac
  expect "the paired device logs in" device-ok "$(ssh_as "$work/device" echo device-ok </dev/null)"

  # Notification registration and the leftovers install.sh must delete.
  cat >"$H/.config/waycar/notifications.json" <<'JSON'
{"v":1,"devices":[{"token":"a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8","env":"sandbox","notify":{"blocked":true,"done":true},"live_activity":{"token":"c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3"}}]}
JSON
  # bin/node.sh keeps the nodes it probed in the file ~/.cache/waycar/node-versions.
  mkdir -p "$H/.cache/waycar" "$H/.local/state/waycar/bridge-off"
  echo "22.0.0 v22.0.0 /usr/bin/node" >"$H/.cache/waycar/node-versions"
  echo 1700000000 >"$H/.local/state/waycar/bridge-off/notify"
  # A Node process of the old version that keeps running after the update.
  (cd "$plugin" && exec nohup setsid sh -c 'exec node -e "setTimeout(() => {}, 600000)" src/sidebar-hook.js' </dev/null >/dev/null 2>&1) &
  sleep 0.5
  pgrep -f 'src/sidebar-hook.js' >"$work/old-node.pid" || fail "the old Node process did not start"
  pane=$(tmux list-panes -a -F '#{pane_id}' | sed -n 1p)
  tmux set-option -p -t "$pane" @waycar_agent claude
  tmux set-option -p -t "$pane" @waycar_status idle
  echo "$pane" >"$work/pane"
  snapshot >"$work/before"
  tree_state >"$work/tree-old"
  ok "hashed config, keys, authorized_keys and @waycar_* options: $(cat "$work/before")"
  ;;

update)
  fixture=${2:?fixture}
  started=$(date +%s%N)
  app_ssh "$(cat "/fixtures/$fixture")" </dev/null >"$work/update.out" 2>&1 && code=0 || code=$?
  echo "node-era-upgrade-check: the update took $((($(date +%s%N) - started) / 1000000)) ms"
  cat "$work/update.out"
  expect "the update exits 0" 0 "$code"
  grep -q "waycar: installed Waycar $WAYCAR_NEW_VERSION in " "$work/update.out" || fail "no 'installed Waycar $WAYCAR_NEW_VERSION' line (what the app reads)"
  ;;

first-update-output)
  grep -q 'moved this Host from the Node version' "$work/update.out" || fail "the update did not say it moved a Node-era Host"
  grep -q 'rewrote the Node-era agent hooks' "$work/update.out" || fail "the update did not print that it rewrote Node-era hooks"
  grep -q 'run /hooks to review' "$work/update.out" || fail "no Codex /hooks review line (the app reads codexHooksNeedReview)"
  grep -q 'Node process(es) from the old version are still running' "$work/update.out" || fail "the update did not count the old Node process"
  for pid in $(cat "$work/old-node.pid"); do kill -0 "$pid" 2>/dev/null || fail "the update killed the old Node process $pid"; done
  ok "the update says what it did, counts the old Node process and kills nothing"
  ;;

after)
  expect "the installed version" "$WAYCAR_NEW_VERSION" "$(installed_version)"
  expect "the hashes of config, keys, authorized_keys and @waycar_* options are equal" "$(cat "$work/before")" "$(snapshot)"
  for gone in bin/node.sh node_modules package.json package-lock.json; do
    [ ! -e "$plugin/$gone" ] || fail "$plugin/$gone is still there"
  done
  [ ! -e "$plugin/src" ] || fail "$plugin/src is still there: $(ls "$plugin/src" | head -3)"
  [ -z "$(find "$plugin" -name '*.js' ! -path "$plugin/hooks/*" | head -1)" ] || fail "JavaScript outside hooks/ in the plugin"
  [ ! -e "$plugin.old" ] && [ ! -e "$plugin.new" ] || fail "$plugin.old or $plugin.new was left behind"
  [ -z "$(ls -A "$H/.local/share/waycar" | grep -v '^plugin$\|^update.lock$' || true)" ] || fail "stray files in ~/.local/share/waycar: $(ls -A "$H/.local/share/waycar")"
  ok "no node.sh, src/*.js, node_modules, package*.json, .new or .old"
  [ ! -e "$H/.cache/waycar/node-versions" ] && [ ! -e "$H/.local/state/waycar/bridge-off" ] || fail "the Node leftovers are still there"
  expect "the user's own Node file is untouched" mine "$(cat "$H/.nvm/versions/node/v20.0.0/bin/node")"
  expect "the user's own npm cache is untouched" mine "$(cat "$H/.npm/_cacache/index")"
  ok "Waycar's Node leftovers are gone and the user's own Node files are not"
  if grep -rn 'node\.sh\|hook-session\.js' "$H/.claude" "$H/.codex" "$H/.gemini" "$H/.hermes" "$H/.config/opencode" 2>/dev/null; then
    fail "an agent config still names node.sh or hook-session.js"
  fi
  grep -q "$plugin/bin/waycar' hook-session" "$H/.claude/settings.json" || fail "claude has no 'waycar hook-session' entry"
  grep -q "$plugin/bin/waycar' hook-session" "$H/.codex/hooks.json" || fail "codex has no 'waycar hook-session' entry"
  ok "no hook entry names node.sh; claude and codex call waycar hook-session"
  ! grep -q 'host-config.js' "$H/.config/opencode/plugins/waycar-chat-prompt.js" || fail "the opencode extension still loads host-config.js"
  ok "the opencode extension no longer loads a JS file of the plugin"
  [ "$(app_ssh 'command -v node || true' </dev/null)" = "" ] || fail "node is still reachable over sshd"
  ;;

functional)
  pane=$(cat "$work/pane")
  waycar=$plugin/bin/waycar
  # status --json
  "$waycar" status --json </dev/null >"$work/status.json" || fail "status --json failed"
  expect "status --json reports the version" "$WAYCAR_NEW_VERSION" "$(jq -r .hostTools.version "$work/status.json")"
  expect "waycar version answers" "waycar $WAYCAR_NEW_VERSION" "$("$waycar" version)"
  "$waycar" hooks status --json </dev/null | jq -e '.agents[] | select(.agent=="claude") | .installed' >/dev/null || fail "claude hooks are not installed per hooks status"
  ok "status --json and hooks status work"

  # The stand-in relay first: a hook event may notify, and no run of this
  # check may reach the real relay.
  start_relay
  # A hook event, run the way the agent runs it: from a command in its config, inside a pane.
  session_cmd=$(jq -r '[.hooks.SessionStart[].hooks[].command | select(contains("hook-session"))][0]' "$H/.claude/settings.json")
  [ -n "$session_cmd" ] && [ "$session_cmd" != null ] || fail "no hook-session command in claude's settings"
  printf '%s' '{"session_id":"sess-upgrade","transcript_path":"/tmp/upgrade.jsonl","hook_event_name":"SessionStart"}' >"$work/payload.json"
  cat >"$work/run-hook.sh" <<SH
#!/bin/sh
CLAUDECODE=1 CLAUDE_PID=\$\$ TMUX_PANE=\$1 sh -c '$session_cmd' <"$work/payload.json"
touch "$work/hook-done"
SH
  rm -f "$work/hook-done"
  hook_pane=$(tmux new-window -d -P -F '#{pane_id}' "sh $work/run-hook.sh \$TMUX_PANE; sleep 60")
  waited=0
  until [ -e "$work/hook-done" ]; do waited=$((waited + 1)); [ "$waited" -lt 100 ] || fail "the hook command did not finish"; sleep 0.1; done
  waited=0
  until [ "$(tmux display-message -p -t "$hook_pane" '#{@waycar_session}')" = sess-upgrade ]; do
    waited=$((waited + 1)); [ "$waited" -lt 50 ] || fail "the hook event did not record the session on its pane"; sleep 0.1
  done
  ok "a claude SessionStart hook event ran from the agent's config and recorded its session"

  # A push request and a Live Activity update, from a pane of its own (`exec`: a
  # pane whose foreground command is a shell counts as no agent).
  notify_pane=$(tmux new-window -d -P -F '#{pane_id}' 'exec sleep 600')
  tmux set-option -p -t "$notify_pane" @waycar_agent claude
  tmux set-option -p -t "$notify_pane" @waycar_status blocked
  : >"$work/relay/requests.jsonl"
  "$waycar" notify --pane "tmux:$notify_pane" --status blocked </dev/null >"$work/notify.out" 2>&1 || { cat "$work/notify.out" >&2; fail "notify failed"; }
  [ "$(relay_requests)" = 2 ] || { cat "$work/notify.out" "$work/relay/requests.jsonl" >&2; fail "notify sent $(relay_requests) relay requests, expected the push and the Live Activity update"; }
  ok "notify sent the push and the Live Activity update"
  grep -q '"url": *"/push"' "$work/relay/requests.jsonl" || fail "no push request reached the stand-in relay"
  grep -q 'liveactivity' "$work/relay/requests.jsonl" || fail "no Live Activity request reached the stand-in relay"

  # A chat read and a summary refresh.
  cat >"$work/chat.jsonl" <<'JSONL'
{"type":"user","uuid":"u1","sessionId":"sess-upgrade","timestamp":"2026-10-29T10:00:00.000Z","message":{"role":"user","content":"add retries"}}
{"type":"assistant","uuid":"a1","parentUuid":"u1","sessionId":"sess-upgrade","timestamp":"2026-10-29T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Adding backoff to the upload client."}]}}
JSONL
  "$waycar" chat-read --kind claude --session-kind path --session-value "$work/chat.jsonl" </dev/null >"$work/chat.out" || fail "chat-read failed"
  head -n 1 "$work/chat.out" | jq -e '.type=="header" and .error==null' >/dev/null || fail "chat-read header: $(head -n 1 "$work/chat.out")"
  grep -q 'add retries' "$work/chat.out" && grep -q 'Adding backoff' "$work/chat.out" || fail "chat-read lost the messages: $(cat "$work/chat.out")"
  ok "chat-read returns the header and both messages"
  "$waycar" summaries refresh </dev/null | jq -e 'has("ran")' >/dev/null || fail "summaries refresh did not print its JSON"
  ok "summaries refresh prints its JSON"

  # The paired device still logs in, and a new pairing enrolls through the new forced command.
  expect "the paired device logs in after the update" device-ok "$(ssh_as "$work/device" echo device-ok </dev/null)"
  if [ -f /fixtures/lib-pair.sh ]; then
    # shellcheck disable=SC1091
    . /fixtures/lib-pair.sh
    set -- $(wc_pair_begin "$plugin" "$work")
    pair_id=$1 pair_key=$2
    grep -q "restrict,command=\"'$plugin/bin/waycar' pair-accept" "$keys" || fail "the new bootstrap line does not force waycar pair-accept"
    ssh-keygen -q -t ed25519 -N '' -C "second device" -f "$work/device2"
    out=$(ssh_as "$pair_key" waycar-enroll <"$work/device2.pub") || fail "the new Enrollment failed: $out"
    case $out in HERDR-ENROLL:OK:*) ok "a new pairing enrolled through the native forced command ($out)" ;; *) fail "new Enrollment said: $out" ;; esac
    wc_pair_end
    expect "the second device logs in" device-ok "$(ssh_as "$work/device2" echo device-ok </dev/null)"
  else
    echo "node-era-upgrade-check: skip: no lib-pair.sh, so no new pairing"
  fi
  ;;

second)
  # A second update: the tree, hooks, extension and links stay as the first one left them.
  snapshot >"$work/config-before-second"
  tree_state >"$work/tree-before-second"
  ;;
second-after)
  expect "a second update changes no file of the install, hooks or extension" "$(cat "$work/tree-before-second")" "$(tree_state)"
  expect "a second update changes no config, key or option" "$(cat "$work/config-before-second")" "$(snapshot)"
  grep -q 'moved this Host from the Node version' "$work/update.out" && fail "the second update claims to have moved a Node-era Host"
  grep -q 'rewrote the Node-era agent hook' "$work/update.out" && fail "the second update rewrote hooks again"
  ok "the second update printed no migration"
  ;;

drill-noexec)
  # The install directory is on a noexec mount: the new package cannot run
  # there, so the update must stop and leave the old install working.
  nx=/nx/plugin
  rm -rf "$nx" /nx/home
  mkdir -p /nx/home
  # Its own HOME, so the links and hook files of the main run are not touched.
  HOME=/nx/home WAYCAR_NO_PAIR=1 WAYCAR_PLUGIN_DIR=$nx WAYCAR_PLUGIN_SOURCE="$work/oldpkg/waycar" sh /old/install.sh --tmux </dev/null >"$work/nx-old.log" 2>&1 \
    || { cat "$work/nx-old.log" >&2; fail "installing the old plugin on the noexec mount failed"; }
  before=$(find "$nx" -type f | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
  HOME=/nx/home WAYCAR_NO_PAIR=1 WAYCAR_PLUGIN_DIR=$nx WAYCAR_INSTALL_BASE_URL=file:///dist sh /dist/install.sh --tmux </dev/null >"$work/nx-new.log" 2>&1 && code=0 || code=$?
  cat "$work/nx-new.log"
  [ "$code" != 0 ] || fail "the update on a noexec install directory succeeded"
  grep -qi 'noexec' "$work/nx-new.log" || fail "the failure does not mention noexec"
  grep -q 'untouched' "$work/nx-new.log" || fail "the failure does not say the old install is untouched"
  expect "the old install directory is byte for byte as it was" "$before" "$(find "$nx" -type f | sort | xargs sha256sum | sha256sum | cut -d' ' -f1)"
  [ ! -e "$nx.new" ] && [ ! -e "$nx.old" ] || fail "$nx.new or $nx.old was left behind"
  expect "the old install still works" 1 "$(cd "$nx" && sh bin/node.sh -e 'console.log(1)')"
  ok "a noexec install directory stops the update and leaves the old install working"
  ;;

drill-kill)
  # SIGKILL an update at 40 moments, from before the download to after the swap.
  # Each time the Host must end with a working install: the old one or the new one.
  install_old
  i=0
  new_seen=0
  unmigrated=0
  old_seen=0
  # A local update takes about 100 ms, so the kills are dense at the start; every
  # 4th run stalls the download, which puts the kill at that stage whatever the delay.
  for delay in 0.01 0.02 0.03 0.04 0.05 0.06 0.07 0.08 0.09 0.10 0.11 0.12 0.13 0.14 0.15 0.16 0.18 0.20 0.22 0.25 \
               0.30 0.35 0.40 0.50 0.01 0.02 0.03 0.04 0.05 0.06 0.07 0.08 0.09 0.10 0.11 0.12 0.13 0.14 0.15 0.20; do
    i=$((i + 1))
    install_old
    # A SIGKILL leaves the app's update lock behind; it is taken over once its owner
    # is dead or after 10 minutes, which is the app's own rule. Clear it so each
    # round exercises the installer, not the lock.
    rm -rf "$H/.local/share/waycar/update.lock"
    rm -f /tmp/slow
    # Every 4th run stalls the download, so the kill lands inside it.
    [ $((i % 4)) != 0 ] || touch /tmp/slow
    app_cmd=$(cat /fixtures/waycar-update-command.tmux-no-hooks.txt)
    setsid sh -c "$app_cmd" >"$work/kill.out" 2>&1 &
    leader=$!
    sleep "$delay"
    kill -9 -- "-$leader" 2>/dev/null || kill -9 "$leader" 2>/dev/null || true
    # Anything the killed run left running (install.sh, curl) goes too, as a dropped ssh channel's would not.
    pkill -9 -f 'waycar-update' 2>/dev/null || true
    pkill -9 -f '/tmp/tmp\.' 2>/dev/null || true
    sleep 0.3
    rm -f /tmp/slow
    echo "node-era-upgrade-check: kill at ${delay}s: version=$(installed_version 2>/dev/null || echo none) staged=$(ls -d "$plugin.new" "$H"/.local/share/waycar/.waycar-install.* 2>/dev/null | wc -l | tr -d ' ') old=$([ -e "$plugin.old" ] && echo yes || echo no)"
    if [ ! -f "$plugin/herdr-plugin.toml" ]; then
      echo "node-era-upgrade-check: note: the kill at ${delay}s landed in the swap window (no install directory); the next run must repair it" >&2
      [ -d "$plugin.old" ] || fail "kill at ${delay}s: no install and no $plugin.old"
      # The next update repairs it before doing anything else.
      rm -rf "$H/.local/share/waycar/update.lock"
      app_ssh "$(cat /fixtures/waycar-update-command.tmux-no-hooks.txt)" </dev/null >"$work/repair.out" 2>&1 || fail "the repair run failed: $(cat "$work/repair.out")"
      [ -f "$plugin/herdr-plugin.toml" ] || fail "the repair run left no install"
    fi
    case $(installed_version) in
      "$WAYCAR_NEW_VERSION")
        new_seen=$((new_seen + 1))
        "$plugin/bin/waycar" version </dev/null | grep -q "^waycar $WAYCAR_NEW_VERSION\$" || fail "kill at ${delay}s: the new install does not run"
        "$plugin/bin/waycar" status --json </dev/null >/dev/null || fail "kill at ${delay}s: the new install fails status"
        # The hook migration runs right after the swap check. A kill between the
        # two leaves Node-era entries; the next update must rewrite them. A kill
        # after the migration must have left none.
        if grep -q 'node.sh' "$H/.claude/settings.json" "$H/.codex/hooks.json"; then
          unmigrated=$((unmigrated + 1))
          rm -rf "$H/.local/share/waycar/update.lock"
          app_ssh "$(cat /fixtures/waycar-update-command.tmux-no-hooks.txt)" </dev/null >"$work/rehook.out" 2>&1 || fail "kill at ${delay}s: the update that repairs the hooks failed: $(cat "$work/rehook.out")"
          ! grep -q 'node.sh' "$H/.claude/settings.json" "$H/.codex/hooks.json" || fail "kill at ${delay}s: an update left hook entries that name node.sh"
        fi
        ;;
      "$WAYCAR_OLD_VERSION")
        old_seen=$((old_seen + 1))
        [ "$(cd "$plugin" && sh bin/node.sh -e 'console.log(1)')" = 1 ] || fail "kill at ${delay}s: the old install does not run"
        ;;
      *) fail "kill at ${delay}s: unknown installed version $(installed_version)" ;;
    esac
  done
  ok "$i kills: $old_seen left the old install working, $new_seen had already swapped to a working new one ($unmigrated before the hook migration, repaired by the next update)"
  # The one moment the kills may miss: between the two renames of the swap, the
  # install directory is gone and the old install sits beside it. Made by hand,
  # the next run must put the old install back before it does anything else.
  install_old
  rm -rf "$H/.local/share/waycar/update.lock"
  mv "$plugin" "$plugin.old"
  [ ! -e "$plugin" ] || fail "could not set up the swap window"
  app_ssh "$(cat /fixtures/waycar-update-command.tmux-no-hooks.txt)" </dev/null >"$work/window.out" 2>&1 || fail "the update after a swap-window kill failed: $(cat "$work/window.out")"
  grep -q 'restored .*an interrupted update had set aside' "$work/window.out" || fail "the update did not say it restored the old install: $(cat "$work/window.out")"
  expect "an update after a kill inside the swap ends on the new version" "$WAYCAR_NEW_VERSION" "$(installed_version)"
  [ ! -e "$plugin.old" ] || fail "$plugin.old was left behind"
  ok "a kill between the two renames is repaired by the next update"
  # And a clean update still goes through afterwards, over whatever the kills left.
  install_old
  rm -rf "$H/.local/share/waycar/update.lock"
  app_ssh "$(cat /fixtures/waycar-update-command.tmux-no-hooks.txt)" </dev/null >"$work/after-kills.out" 2>&1 || fail "the update after the kills failed: $(cat "$work/after-kills.out")"
  expect "an update after the kills works" "$WAYCAR_NEW_VERSION" "$(installed_version)"
  [ -z "$(ls -A "$H/.local/share/waycar" | grep -v '^plugin$\|^update.lock$' || true)" ] || fail "stray files after the kills: $(ls -A "$H/.local/share/waycar")"
  ;;
*) fail "unknown phase $phase" ;;
esac
INNER
}

echo "node-era-upgrade-check: $image, plugin $old_version -> $new_version"
# The scripts go in as files: an installer that reads stdin would eat a script piped to sh.
put() { docker exec -u 0 -i "$name" sh -c "cat >$1 && chmod 644 $1"; }
root_script | put /opt/root.sh
remove_node_script | put /opt/remove-node.sh
check_script | put /opt/check.sh
docker exec -u 0 "$name" sh -eu /opt/root.sh
phase() { docker exec -u tester -e "WAYCAR_OLD_VERSION=$old_version" -e "WAYCAR_NEW_VERSION=$new_version" -w /home/tester "$name" sh /opt/check.sh "$@"; }

phase prep
phase drill-noexec
phase drill-kill
phase old
phase update waycar-update-command.tmux-no-hooks.txt
phase first-update-output
docker exec -u 0 "$name" sh -eu /opt/remove-node.sh
phase after
phase functional
phase second
phase update waycar-update-command.tmux-no-hooks.txt
phase second-after
echo "node-era-upgrade-check: all checks passed ($image, $old_version -> $new_version)"
