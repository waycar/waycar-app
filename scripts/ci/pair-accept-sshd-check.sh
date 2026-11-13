#!/bin/sh
# The real-sshd Enrollment end to end of ADR 0007, against the Rust
# `waycar pair-accept` as the Bootstrap Key's forced command.
#
#   sh scripts/ci/pair-accept-sshd-check.sh [image]
#
# image defaults to ubuntu:24.04. Needs Docker (the devbox daemon is fine) and
# either a Rust toolchain with cargo-zigbuild or a built `waycar` (WAYCAR_BIN).
#
# What runs: a throwaway container with openssh-server, tmux, a non-root user
# and NO Node. The release-shaped `waycar` (static musl, for the container's
# CPU) is installed at <plugin>/bin/waycar. A pairing is started the way a
# person starts one: `waycar pair` runs in a tmux pane and `c` prints the
# Pairing Code, which carries the Bootstrap Key's seed; scripts/ci/lib-pair.sh
# writes that seed out as an OpenSSH key file (the pending state holds only the
# public half). Then real `ssh` connects with that
# key and writes a Device Key line to stdin, and the script checks:
#
#   - the answer `HERDR-ENROLL:OK:<fingerprint>` and exit 0
#   - the Device Key is in authorized_keys (mode 0600, the other lines kept),
#     the bootstrap line is gone, the pending state is consumed, the
#     Enrollment record is written, and the Device Key can then log in
#   - a second connect with the same Bootstrap Key is refused (single use),
#     and two connects at once enroll exactly once
#   - an invalid key and an oversized line are refused without consuming the
#     pairing, and a retry then works
#   - an expired pairing answers `HERDR-ENROLL:ERR:expired` and removes its line
#   - a pairing without pending state answers `ERR:unknown_pairing` and
#     self-heals its line
#   - a stalled stdin ends in `ERR:no_input` after the 30 s limit
#   - the restricted key cannot run a command of its choice, get a pty, or
#     forward a port
#
# Environment:
#   WAYCAR_BIN     a release `waycar` for the container's CPU to use instead of
#                  building one
#   DEVBOX_AGENT   agent slug for the container labels
#                  (default senior-software-engineer)
set -eu

image=${1:-ubuntu:24.04}
root=$(cd "$(dirname "$0")/../.." && pwd)
slug=${DEVBOX_AGENT:-senior-software-engineer}
expires=$(date -u -d '+4 hours' +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -v+4H +%Y-%m-%dT%H:%MZ)
name=waycar-sshd-check-$$

docker info >/dev/null 2>&1 || { echo "pair-accept-sshd-check: docker is not available" >&2; exit 1; }

if [ -z "${WAYCAR_BIN:-}" ]; then
  case $(docker info --format '{{.Architecture}}') in
    x86_64 | amd64) target=x86_64-unknown-linux-musl ;;
    aarch64 | arm64) target=aarch64-unknown-linux-musl ;;
    *) echo "pair-accept-sshd-check: unsupported container CPU" >&2; exit 1 ;;
  esac
  # Linux musl needs zig as the C compiler for `ring`.
  eval "$(sh "$root/scripts/ci/provision-plugin-build.sh")"
  (cd "$root/plugin" && cargo zigbuild --release --locked --target "$target") >&2
  WAYCAR_BIN=$root/plugin/target/$target/release/waycar
fi
[ -x "$WAYCAR_BIN" ] || { echo "pair-accept-sshd-check: missing binary $WAYCAR_BIN" >&2; exit 1; }

cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --rm --cpus 2 --memory 4g --name "$name" \
  --label "agent=$slug" --label disposable=true --label "expires=$expires" \
  "$image" sleep 900 >/dev/null

# The checks, run inside the container as the non-root user.
checks() {
  cat <<'INNER'
set -eu
umask 022
PATH=/usr/local/bin:/usr/bin:/bin
home=$HOME
plugin=$home/.local/share/waycar/plugin
waycar=$plugin/bin/waycar
. "$home/lib-pair.sh"
trap wc_pair_end EXIT
state=$home/.local/state/waycar
keys=$home/.ssh/authorized_keys
work=$home/check-work
mkdir -p "$work" "$home/.ssh"
chmod 700 "$home/.ssh"

passed=0
fail() { echo "pair-accept-sshd-check: FAIL: $*" >&2; echo "--- sshd log:" >&2; cat /tmp/sshd.log >&2 || true; exit 1; }
ok() { passed=$((passed + 1)); echo "pair-accept-sshd-check: ok: $*"; }
expect() { # name expected actual
  [ "$2" = "$3" ] || fail "$1: expected [$2], got [$3]"
  ok "$1"
}

ssh_as() { # key, then ssh arguments
  key=$1; shift
  ssh -i "$key" -p 2222 -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 tester@127.0.0.1 "$@"
}

# begin: starts a pairing the way a person does (`waycar pair` in a tmux pane,
# the Pairing Code read off the screen, scripts/ci/lib-pair.sh); sets id,
# bootstrap_pub (the key sshd matches on, no comment) and bootstrap_key.
begin() {
  started=$(wc_pair_begin "$plugin" "$work") || fail "could not start a pairing with waycar pair"
  id=${started%% *}
  bootstrap_key=${started#* }
  bootstrap_pub=$(ssh-keygen -y -f "$bootstrap_key" | cut -d ' ' -f 1-2)
}

new_device() { # name -> $work/<name>, <name>.pub, device_line, device_fp
  rm -f "$work/$1" "$work/$1.pub"
  ssh-keygen -q -t ed25519 -N '' -C "waycar $1" -f "$work/$1"
  device_line=$(cat "$work/$1.pub")
  device_fp=$(ssh-keygen -lf "$work/$1.pub" | awk '{print $2}')
}

# enroll key [input-file]: runs the exchange; sets out, code, err.
enroll() {
  code=0
  out=$(ssh_as "$1" waycar-enroll <"${2:-$work/device.pub}" 2>"$work/stderr") || code=$?
  err=$(cat "$work/stderr")
}

line_count() { grep -c -F -- "$1" "$keys" || true; }

command -v node >/dev/null 2>&1 && fail "node is installed in this container"
ok "no Node in the container"

# A user key already authorized, which every step must leave alone.
ssh-keygen -q -t ed25519 -N '' -C laptop -f "$work/user"
user_line=$(cat "$work/user.pub")
printf '%s\n' "$user_line" >"$keys"
chmod 600 "$keys"

# --- Enrollment succeeds -------------------------------------------------
new_device device
begin
expect "authorized_keys has the user's line and the restricted bootstrap line" 2 "$(wc -l <"$keys" | tr -d ' ')"
case $(sed -n 2p "$keys") in
  "restrict,command=\"'$waycar' pair-accept --state-dir '$state' --pairing-id $id\" $bootstrap_pub herdr-pairing:$id:exp:"*) ok "the bootstrap line forces 'waycar pair-accept' by absolute path" ;;
  *) fail "unexpected bootstrap line: $(sed -n 2p "$keys")" ;;
esac
[ -f "$state/pending/$id.json" ] || fail "no pending state"
ok "pending state recorded"

enroll "$bootstrap_key"
expect "stdout is the OK line with the Device Key fingerprint" "HERDR-ENROLL:OK:$device_fp" "$out"
expect "exit code 0" 0 "$code"
expect "stderr is quiet" "" "$err"
expect "authorized_keys now holds the user's line and the Device Key" "$user_line
$device_line" "$(cat "$keys")"
expect "authorized_keys mode is kept" 600 "$(stat -c %a "$keys")"
expect "the bootstrap line is gone" 0 "$(line_count "herdr-pairing:$id")"
[ ! -e "$state/pending/$id.json" ] || fail "pending state still there"
ok "pending state consumed"
record=$state/enrolled/$id.json
expect "the Enrollment record has the fingerprint" "$device_fp" "$(jq -r .fingerprint "$record")"
expect "the Enrollment record has the line" "$device_line" "$(jq -r .line "$record")"
expect "the Enrollment record is mode 0600" 600 "$(stat -c %a "$record")"
[ ! -e "$keys.herdr-pairing.lock" ] || fail "lock file left behind"
ok "no lock file left behind"

# --- Single use ----------------------------------------------------------
code=0
out=$(ssh_as "$bootstrap_key" waycar-enroll </dev/null 2>"$work/stderr") || code=$?
err=$(cat "$work/stderr")
expect "a second connect with the Bootstrap Key is refused by sshd" 255 "$code"
case $err in *"Permission denied"*) ok "the refusal is Permission denied" ;; *) fail "unexpected refusal: $err" ;; esac
expect "the second connect answered nothing" "" "$out"

# --- The enrolled Device Key works --------------------------------------
expect "the enrolled Device Key logs in" enrolled-ok "$(ssh_as "$work/device" echo enrolled-ok </dev/null)"

# --- Invalid submissions consume nothing ---------------------------------
new_device phone
begin
printf 'ssh-rsa AAAAB3nope\n' >"$work/bad.pub"
enroll "$bootstrap_key" "$work/bad.pub"
expect "an invalid key answers ERR:invalid_key" "HERDR-ENROLL:ERR:invalid_key" "$out"
expect "an invalid key exits 1" 1 "$code"
expect "the reason is on stderr" "rejected Device Key line: key type must be ssh-ed25519" "$err"
expect "the bootstrap line is still there" 1 "$(line_count "herdr-pairing:$id")"

head -c 6000 /dev/zero | tr '\0' x >"$work/long.pub"
enroll "$bootstrap_key" "$work/long.pub"
expect "an oversized line answers ERR:invalid_key" "HERDR-ENROLL:ERR:invalid_key" "$out"
expect "the pairing is still pending" 1 "$(line_count "herdr-pairing:$id")"

: >"$work/empty.pub"
enroll "$bootstrap_key" "$work/empty.pub"
expect "an empty submission answers ERR:no_input" "HERDR-ENROLL:ERR:no_input" "$out"
expect "an empty submission exits 1" 1 "$code"

enroll "$bootstrap_key" "$work/phone.pub"
expect "a retry with a valid key enrolls" "HERDR-ENROLL:OK:$device_fp" "$out"
expect "the retry added exactly the phone's key" 1 "$(line_count "$device_line")"

# --- Expired pairing -----------------------------------------------------
new_device late
begin
# No clock seam in a real `waycar pair`: age the pending state instead, which
# is what pair-accept reads the expiry from.
jq --argjson t "$(($(date +%s) - 600))" '.expiresAt = $t' "$state/pending/$id.json" >"$work/pending.aged"
cat "$work/pending.aged" >"$state/pending/$id.json"
enroll "$bootstrap_key" "$work/late.pub"
expect "an expired pairing answers ERR:expired" "HERDR-ENROLL:ERR:expired" "$out"
expect "an expired pairing exits 1" 1 "$code"
expect "the expired line removed itself" 0 "$(line_count "herdr-pairing:$id")"
expect "the expired pairing enrolled nothing" 0 "$(line_count "$device_line")"
[ ! -e "$state/pending/$id.json" ] || fail "expired pending state still there"
ok "expired pending state removed"

# --- Unknown pairing self-heals ------------------------------------------
begin
rm -f "$state/pending/$id.json"
enroll "$bootstrap_key" "$work/late.pub"
expect "no pending state answers ERR:unknown_pairing" "HERDR-ENROLL:ERR:unknown_pairing" "$out"
expect "the leftover line removed itself" 0 "$(line_count "herdr-pairing:$id")"

# --- The restricted key does nothing else --------------------------------
begin
expect "a command of the client's choice is not run" "HERDR-ENROLL:ERR:no_input" "$(ssh_as "$bootstrap_key" 'echo pwned; id' </dev/null 2>/dev/null)"
pty=$(ssh_as "$bootstrap_key" -tt 'echo pwned; id' </dev/null 2>"$work/stderr" | tr -d '\r') || true
case $pty in *pwned* | *uid=*) fail "a pty session ran the client's command: $pty" ;; esac
case $(cat "$work/stderr") in *"PTY allocation request failed"*) ok "a pty is refused and the client's command is not run" ;; *) fail "pty was not refused: $(cat "$work/stderr")" ;; esac
code=0
ssh_as "$bootstrap_key" -W 127.0.0.1:2222 </dev/null >"$work/forward.out" 2>"$work/stderr" || code=$?
[ "$code" -ne 0 ] || fail "a port forward through the Bootstrap Key succeeded"
case $(cat "$work/stderr") in *"administratively prohibited"* | *"forwarding failed"* | *"refused"*) ok "port forwarding is refused" ;; *) fail "forward not refused as expected: $(cat "$work/stderr")" ;; esac
expect "nothing came through the forward" "" "$(cat "$work/forward.out")"
expect "none of that consumed the pairing" 1 "$(line_count "herdr-pairing:$id")"

# --- Two connects at once enroll exactly once ----------------------------
new_device race
begin
( ssh_as "$bootstrap_key" waycar-enroll <"$work/race.pub" >"$work/race1.out" 2>/dev/null || true ) &
( ssh_as "$bootstrap_key" waycar-enroll <"$work/race.pub" >"$work/race2.out" 2>/dev/null || true ) &
wait
oks=$(cat "$work/race1.out" "$work/race2.out" | grep -c "^HERDR-ENROLL:OK:$device_fp\$" || true)
expect "exactly one of two simultaneous connects enrolled" 1 "$oks"
expect "the Device Key is in authorized_keys once" 1 "$(line_count "$device_line")"
expect "no bootstrap line is left" 0 "$(line_count "herdr-pairing:$id")"
expect "the user's line is still there" 1 "$(line_count "$user_line")"

# --- A stalled stdin ends at the 30 s limit ------------------------------
begin
mkfifo "$work/stall"
( exec 3>"$work/stall"; sleep 60 ) &
holder=$!
start=$(date +%s)
out=$(ssh_as "$bootstrap_key" waycar-enroll <"$work/stall" 2>/dev/null) || true
elapsed=$(($(date +%s) - start))
kill "$holder" 2>/dev/null || true
expect "a stalled stdin answers ERR:no_input" "HERDR-ENROLL:ERR:no_input" "$out"
[ "$elapsed" -ge 29 ] && [ "$elapsed" -le 45 ] || fail "stalled stdin took ${elapsed}s, expected about 30"
ok "the wait ended after ${elapsed}s"
expect "the stalled pairing is still pending" 1 "$(line_count "herdr-pairing:$id")"

echo "pair-accept-sshd-check: all $passed checks passed"
INNER
}

# Setup, as root: sshd, a non-root user, the binaries.
docker exec "$name" sh -c '
  set -eu
  umask 022
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends openssh-server openssh-client jq tmux python3 >/dev/null 2>&1
  useradd -m -s /bin/bash tester
  usermod -p "*" tester
  mkdir -p /run/sshd /home/tester/.local/share/waycar/plugin/bin
  chmod 755 /run/sshd
  ssh-keygen -A >/dev/null
  cat >/etc/ssh/sshd_check.conf <<CONF
Port 2222
ListenAddress 127.0.0.1
HostKey /etc/ssh/ssh_host_ed25519_key
PidFile /run/sshd_check.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes yes
AuthorizedKeysFile .ssh/authorized_keys
LogLevel VERBOSE
CONF
'
docker cp "$WAYCAR_BIN" "$name:/home/tester/.local/share/waycar/plugin/bin/waycar"
docker cp "$root/scripts/ci/lib-pair.sh" "$name:/home/tester/lib-pair.sh"
checks | docker exec -i "$name" sh -c 'cat >/home/tester/checks.sh'
docker exec "$name" bash -c '
  set -eu
  chown -R tester:tester /home/tester
  chmod 755 /home/tester/.local/share/waycar/plugin/bin/waycar
  /usr/sbin/sshd -D -e -f /etc/ssh/sshd_check.conf >/tmp/sshd.log 2>&1 &
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    (exec 3<>/dev/tcp/127.0.0.1/2222) 2>/dev/null && exit 0
    sleep 0.5
  done
  echo "sshd did not start" >&2
  cat /tmp/sshd.log >&2
  exit 1
' || { echo "pair-accept-sshd-check: sshd did not start" >&2; exit 1; }

docker exec -u tester -e HOME=/home/tester "$name" bash /home/tester/checks.sh
