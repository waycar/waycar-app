#!/bin/sh
# Waycar harness lab lifecycle (see README.md). Always targets the Colima
# context, never the default Docker context.
#
#   lab.sh up                 build and start mock + host, wait for SSH
#   lab.sh down               remove containers and network
#   lab.sh shell              SSH in as waycar
#   lab.sh ssh [cmd...]       run a command on the host as waycar
#   lab.sh reinstall-plugin   rerun plugin/install.sh from the mounted plugin/
#   lab.sh reconfigure        copy host/config into the running host, reapply it
#                             (setup-home.sh), then reinstall the plugin, whose
#                             hooks the copied harness configs may have dropped
#   lab.sh e2e-reset          close the e2e suite's harnesse2e-* tmux sessions
#                             and herdr workspaces (e2e-reset.sh)
#   lab.sh compose [args...]  any other docker compose command
set -eu

here=$(cd "$(dirname "$0")" && pwd)
context=${HARNESS_LAB_CONTEXT:-colima-waycar-harness}
key=$HOME/.ssh/waycar_harness_lab
known_hosts=$HOME/.ssh/waycar_harness_lab_known_hosts
port=22300

compose() {
  docker --context "$context" compose -f "$here/docker-compose.yml" --env-file "$here/VERSIONS" "$@"
}

ssh_host() {
  ssh -i "$key" -p "$port" -o IdentitiesOnly=yes -o UserKnownHostsFile="$known_hosts" \
    -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR waycar@127.0.0.1 "$@"
}

ensure_key() {
  [ -f "$key" ] && return 0
  echo "harness-lab: generating $key"
  ssh-keygen -q -t ed25519 -N '' -C waycar-harness-lab -f "$key"
}

cmd=${1:-}
[ $# -gt 0 ] && shift
case "$cmd" in
  up)
    ensure_key
    compose up -d --build "$@"
    # Host keys are regenerated whenever the container is recreated.
    ssh-keygen -R "[127.0.0.1]:$port" -f "$known_hosts" >/dev/null 2>&1 || true
    i=0
    until ssh_host -o ConnectTimeout=3 true 2>/dev/null; do
      i=$((i + 1))
      [ "$i" -lt 60 ] || { echo "harness-lab: SSH did not come up; see: $0 compose logs host" >&2; exit 1; }
      sleep 1
    done
    ssh_host 'herdr --version; tmux -V; waycar version'
    ;;
  down) compose down --remove-orphans "$@" ;;
  shell) ssh_host -t "$@" ;;
  ssh) ssh_host "$@" ;;
  reinstall-plugin) compose exec -T -u waycar host bash -lc 'sh /opt/harness-lab/install-plugin.sh' ;;
  compose) compose "$@" ;;
  reconfigure)
    COPYFILE_DISABLE=1 tar --no-mac-metadata --no-xattrs -C "$here/host" -cf - config setup-home.sh \
      | compose exec -T host sh -c 'rm -rf /opt/harness-lab/config && tar -C /opt/harness-lab --no-same-owner -xf - && chown -R waycar:waycar /opt/harness-lab'
    compose exec -T -u waycar host bash -lc 'sh /opt/harness-lab/setup-home.sh && sh /opt/harness-lab/install-plugin.sh'
    ;;
  e2e-reset) ssh_host 'sh -s' < "$here/e2e-reset.sh" ;;
  *) sed -n '2,15s/^# \{0,1\}//p' "$0" >&2; exit 2 ;;
esac
