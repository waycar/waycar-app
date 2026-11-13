# Source this file (`. scripts/ci/lib-pair.sh`) from a POSIX sh script.
#
# wc_pair_begin <plugin-dir> <work-dir>
#   Starts a pairing the way a person does and prints "<pairing-id> <key-file>"
#   on stdout, one line (everything else goes to stderr). It runs
#   `<plugin-dir>/bin/waycar pair` in a pane of a private tmux server
#   (-L wc-pair), confirms the address list, presses `c` (on Linux there is no
#   clipboard, so the Pairing Code is printed on the screen), reads the code
#   off the pane, takes the Bootstrap Key's seed out of it and writes the key
#   as an OpenSSH private key file, <work-dir>/bootstrap-<pairing-id> (mode
#   0600). The popup keeps running, so the Bootstrap Key's restricted
#   authorized_keys line stays valid until the popup ends or its 2-minute TTL
#   runs out. Call it once per pairing; it can be called again for another.
#
#   The key is checked against the authorized_keys line the popup wrote
#   (`ssh-keygen -y` of the file must be the line's key), and that line is
#   where the pairing id comes from.
#
# wc_pair_end
#   Stops the popups (kills the private tmux server).
#
# Needs: tmux, python3 (standard library only; it decodes the code and writes
# the key file, because OpenSSH has no import for a raw Ed25519 seed), ssh-keygen,
# an SSH host key in /etc/ssh (`ssh-keygen -A`), and $HOME with .ssh. The
# Host Tools under test never use python3. It runs as the test's own tool.

wc_pair_t() { tmux -L wc-pair -f /dev/null "$@"; }

wc_pair_end() { wc_pair_t kill-server >/dev/null 2>&1 || true; }

wc_pair_begin() {
  _wp_plugin=${1:?wc_pair_begin <plugin-dir> <work-dir>}
  _wp_work=${2:?wc_pair_begin <plugin-dir> <work-dir>}
  mkdir -p "$_wp_work"
  _wp_session=pair-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
  unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID
  wc_pair_t new-session -d -x 250 -y 60 -s "$_wp_session" "'$_wp_plugin/bin/waycar' pair" >&2 \
    || { echo "lib-pair: tmux would not start waycar pair" >&2; return 1; }

  # The address list first.
  _wp_i=0
  until wc_pair_t capture-pane -p -t "$_wp_session" 2>/dev/null | grep -q 'enter confirm'; do
    _wp_i=$((_wp_i + 1))
    [ "$_wp_i" -lt 100 ] || { wc_pair_t capture-pane -p -t "$_wp_session" >&2; echo "lib-pair: waycar pair showed no address list" >&2; return 1; }
    sleep 0.1
  done
  wc_pair_t send-keys -t "$_wp_session" Enter

  # The QR screen, then `c`: the code is printed in the pane.
  _wp_i=0
  until wc_pair_t capture-pane -p -t "$_wp_session" 2>/dev/null | grep -q '[█▀▄]'; do
    _wp_i=$((_wp_i + 1))
    [ "$_wp_i" -lt 100 ] || { wc_pair_t capture-pane -p -t "$_wp_session" >&2; echo "lib-pair: waycar pair drew no QR" >&2; return 1; }
    sleep 0.1
  done
  wc_pair_t send-keys -t "$_wp_session" c
  _wp_i=0
  _wp_code=
  while [ -z "$_wp_code" ]; do
    _wp_code=$(wc_pair_t capture-pane -J -p -t "$_wp_session" 2>/dev/null | grep -o 'HERDR-PAIR:1:[A-Za-z0-9_-]*' | sed -n 1p)
    [ -n "$_wp_code" ] && break
    _wp_i=$((_wp_i + 1))
    [ "$_wp_i" -lt 100 ] || { wc_pair_t capture-pane -J -p -t "$_wp_session" >&2; echo "lib-pair: pressing c did not print the Pairing Code" >&2; return 1; }
    sleep 0.1
  done

  _wp_tmp=$_wp_work/bootstrap-new.$$
  python3 - "$_wp_code" "$_wp_tmp" <<'PY' || { echo "lib-pair: could not turn the Pairing Code into a key" >&2; return 1; }
import base64, hashlib, json, os, struct, sys

code, out = sys.argv[1:3]
prefix = "HERDR-PAIR:1:"
assert code.startswith(prefix), "not a v1 Pairing Code"
body = code[len(prefix):]
payload = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)))
seed = base64.urlsafe_b64decode(payload["seed"] + "=" * (-len(payload["seed"]) % 4))
assert len(seed) == 32, "seed is %d bytes" % len(seed)

# Ed25519 public key of the seed (RFC 8032 section 5.1.5, the plain version).
P = 2**255 - 19
D = -121665 * pow(121666, P - 2, P) % P
SQRT_M1 = pow(2, (P - 1) // 4, P)

def recover_x(y):
    xx = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P:
        x = x * SQRT_M1 % P
    return P - x if x % 2 else x

BY = 4 * pow(5, P - 2, P) % P
BASE = (recover_x(BY), BY)

def add(a, b):
    (x1, y1), (x2, y2) = a, b
    t = D * x1 * x2 * y1 * y2 % P
    return ((x1 * y2 + x2 * y1) * pow(1 + t, P - 2, P) % P,
            (y1 * y2 + x1 * x2) * pow(1 - t, P - 2, P) % P)

def mul(scalar, point):
    result = (0, 1)
    while scalar:
        if scalar & 1:
            result = add(result, point)
        point = add(point, point)
        scalar >>= 1
    return result

digest = hashlib.sha512(seed).digest()
a = int.from_bytes(digest[:32], "little")
a &= (1 << 254) - 8
a |= 1 << 254
x, y = mul(a, BASE)
public = (y | ((x & 1) << 255)).to_bytes(32, "little")

# openssh-key-v1, no passphrase.
def s(data):
    return struct.pack(">I", len(data)) + data

blob = s(b"ssh-ed25519") + s(public)
check = os.urandom(4)
private = check + check + s(b"ssh-ed25519") + s(public) + s(seed + public) + s(b"waycar-bootstrap")
pad = 1
while len(private) % 8:
    private += bytes([pad])
    pad += 1
raw = b"openssh-key-v1\0" + s(b"none") + s(b"none") + s(b"") + struct.pack(">I", 1) + s(blob) + s(private)
b64 = base64.b64encode(raw).decode()
lines = [b64[i:i + 70] for i in range(0, len(b64), 70)]
fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as handle:
    handle.write("-----BEGIN OPENSSH PRIVATE KEY-----\n" + "\n".join(lines) + "\n-----END OPENSSH PRIVATE KEY-----\n")
PY

  _wp_blob=$(ssh-keygen -y -f "$_wp_tmp" | cut -d ' ' -f 2)
  [ -n "$_wp_blob" ] || { echo "lib-pair: ssh-keygen cannot read the key made from the Pairing Code" >&2; return 1; }
  _wp_id=$(grep -F -- "$_wp_blob" "$HOME/.ssh/authorized_keys" | sed -n 's/.*herdr-pairing:\([0-9a-f]*\):exp:.*/\1/p' | sed -n 1p)
  [ -n "$_wp_id" ] || { echo "lib-pair: no Bootstrap Key line in authorized_keys matches the Pairing Code's key" >&2; return 1; }
  mv "$_wp_tmp" "$_wp_work/bootstrap-$_wp_id"
  printf '%s %s\n' "$_wp_id" "$_wp_work/bootstrap-$_wp_id"
}
