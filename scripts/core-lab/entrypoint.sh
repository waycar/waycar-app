#!/bin/sh
# Core-lab entrypoint (runs as root): host keys, authorize the app's PUBLIC key, run sshd in the foreground.
# Env:
#   LAB_AUTHORIZED_KEY   public key line(s) for user `waycar` (REQUIRED for a usable lab; never a private key)
#   LAB_GENERATE_CLIENT_KEY=1  generate a throwaway ed25519 client key for waycar INSIDE the container
#                        (/home/waycar/.ssh/id_lab) and authorize it: for loopback tests (ssh waycar@127.0.0.1)
#   LAB_LOGIND_DIR=1     also create /run/user/<uid> (0700, waycar) like logind does on a real Linux host
#   LAB_SSHD_ARGS        extra sshd arguments, e.g. "-o LogLevel=DEBUG3"
# Deliberately does NOT install herdr-core.
set -eu

mkdir -p /run/sshd
ssh-keygen -A >/dev/null            # host keys at first start; never baked into the image

home=/home/waycar
install -d -m 700 -o waycar -g waycar "$home/.ssh"
if [ -n "${LAB_AUTHORIZED_KEY:-}" ]; then
  printf '%s\n' "$LAB_AUTHORIZED_KEY" > "$home/.ssh/authorized_keys"
else
  : > "$home/.ssh/authorized_keys"
  [ "${LAB_GENERATE_CLIENT_KEY:-0}" = 1 ] || echo "lab: LAB_AUTHORIZED_KEY is empty and LAB_GENERATE_CLIENT_KEY is not 1: nobody can log in" >&2
fi
chown waycar:waycar "$home/.ssh/authorized_keys"
chmod 600 "$home/.ssh/authorized_keys"

if [ "${LAB_GENERATE_CLIENT_KEY:-0}" = 1 ] && [ ! -f "$home/.ssh/id_lab" ]; then
  su waycar -c "ssh-keygen -q -t ed25519 -N '' -C core-lab-throwaway -f $home/.ssh/id_lab"
  cat "$home/.ssh/id_lab.pub" >> "$home/.ssh/authorized_keys"
  # a client config for the loopback tests: this key, no known_hosts pollution of anything outside the container
  printf 'Host *\n  IdentityFile ~/.ssh/id_lab\n  IdentitiesOnly yes\n' > "$home/.ssh/config"
  chown waycar:waycar "$home/.ssh/config"; chmod 600 "$home/.ssh/config"
fi

if [ "${LAB_LOGIND_DIR:-0}" = 1 ]; then
  uid=$(id -u waycar)
  install -d -m 700 -o waycar -g waycar "/run/user/$uid"
fi

echo "lab: sshd on :22 (user waycar, key auth only); host key fingerprints:" >&2
for k in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$k" >&2; done
# shellcheck disable=SC2086
exec /usr/sbin/sshd -D -e ${LAB_SSHD_ARGS:-}
