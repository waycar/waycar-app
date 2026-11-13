#!/bin/sh
# Harness lab host start (runs as root): host keys, the mounted public key,
# the herdr server for `waycar` (detached), Waycar Host Tools from the mounted
# plugin/, then sshd in the foreground.
set -eu

ssh-keygen -A >/dev/null
if [ -s /run/harness-lab/authorized_keys ]; then
  install -m 600 -o waycar -g waycar /run/harness-lab/authorized_keys /home/waycar/.ssh/authorized_keys
else
  echo "harness-lab: no public key mounted at /run/harness-lab/authorized_keys; ssh login will fail" >&2
fi

# A login shell, so the server and every pane it spawns get ~/.bashrc's lab
# environment (PATH and the harness mock settings). A container start never
# has a server running; a stale socket from the last run is removed first.
runuser -u waycar -- bash -lc '
  mkdir -p ~/.cache/harness-lab
  rm -f ~/.config/herdr/herdr.sock
  cd ~ && setsid -f herdr server >>~/.cache/harness-lab/herdr-server.log 2>&1 </dev/null
  for _ in $(seq 50); do [ -S ~/.config/herdr/herdr.sock ] && break; sleep 0.2; done
  [ -S ~/.config/herdr/herdr.sock ] || echo "harness-lab: herdr server did not create its socket; see ~/.cache/harness-lab/herdr-server.log" >&2
'

if [ -f /opt/waycar-plugin/herdr-plugin.toml ]; then
  runuser -u waycar -- bash -lc 'sh /opt/harness-lab/install-plugin.sh' \
    || echo "harness-lab: Waycar Host Tools install failed; rerun: make harness-lab-reinstall-plugin" >&2
else
  echo "harness-lab: plugin/ is not mounted at /opt/waycar-plugin; Waycar Host Tools not installed" >&2
fi

exec /usr/sbin/sshd -D -e
