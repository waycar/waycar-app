# Waycar tmux test box: stock Ubuntu 22.04 with the distro's own tmux.
# Built by the maintainers' deploy, or by `docker build` on any Docker host. No locale is configured on purpose:
# the box keeps the distro default (LANG=C.UTF-8 on all five via pam_env or
# /etc/locale.conf; no other locales generated).
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
# nodejs/npm are the distro's (12.x on jammy), so the "distro Node only"
# install.sh path is reproducible.
RUN apt-get update \
 && apt-get upgrade -y \
 && apt-get install -y --no-install-recommends \
      tmux openssh-server git curl ca-certificates procps bash nodejs npm \
      less vim-tiny unzip xz-utils rsync \
 && apt-cache policy nodejs tmux > /etc/waycar-testbox-packages.txt \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd \
 && rm -f /etc/ssh/ssh_host_*

# Key-only SSH for two users, no passwords, no sudo: `waycar` for manual
# tests and `waycar-e2e` for the automated suite, whose sessions all get a
# private TMUX_TMPDIR (created at container start, mode 700).
COPY authorized_keys.waycar authorized_keys.waycar-e2e /tmp/
RUN printf '%s\n' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PermitRootLogin no' \
      'AllowUsers waycar waycar-e2e' \
      'AllowTcpForwarding no' \
      'AllowAgentForwarding no' \
      'X11Forwarding no' \
      'PermitTunnel no' \
      'AllowStreamLocalForwarding local' \
      'Match User waycar-e2e' \
      '    SetEnv TMUX_TMPDIR=/tmp/waycar-e2e-tmux' \
      '    AllowTcpForwarding local' \
      '    AllowStreamLocalForwarding local' \
      > /etc/ssh/sshd_config.d/00-waycar-testbox.conf \
 && (userdel -r ubuntu 2>/dev/null || true) \
 && for u in waycar waycar-e2e; do \
      useradd -m -s /bin/bash "$u" && usermod -p '*' "$u" \
      && install -d -m 700 -o "$u" -g "$u" "/home/$u/.ssh" \
      && install -m 600 -o "$u" -g "$u" "/tmp/authorized_keys.$u" "/home/$u/.ssh/authorized_keys"; \
    done \
 && rm /tmp/authorized_keys.*

# A staged user toolchain, installed the way a user would (nvm + Node LTS,
# pi via npm -g, opencode via its official installer) but into a stand-in
# home outside node.sh's search paths, so the box first presents only the
# distro Node. scripts/testboxes/provision-user.sh moves it into ~waycar.
ARG NVM_VERSION=v0.40.8
RUN install -d -o waycar -g waycar /opt/waycar-stage
USER waycar
ENV HOME=/opt/waycar-stage NVM_DIR=/opt/waycar-stage/.nvm
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN cd "$HOME" && touch .bashrc \
 && curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" | PROFILE="$HOME/.bashrc" bash \
 && . "$HOME/.nvm/nvm.sh" && nvm install --lts && nvm alias default 'lts/*' \
 && npm i -g @earendil-works/pi-coding-agent \
 && curl -fsSL https://opencode.ai/install | bash \
 && ls -la "$HOME" "$HOME/.opencode/bin"
USER root
ENV HOME=/root NVM_DIR=
SHELL ["/bin/sh", "-c"]

EXPOSE 22
# Host keys and the e2e TMUX_TMPDIR are made at start; sshd is PID 1 in the foreground.
CMD ["/bin/sh", "-c", "ssh-keygen -A >/dev/null && install -d -m 700 -o waycar-e2e -g waycar-e2e /tmp/waycar-e2e-tmux && exec /usr/sbin/sshd -D -e"]
