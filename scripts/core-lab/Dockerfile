# herdr-core "core lab": a real OpenSSH server in a throwaway Ubuntu 24.04 container.
# herdr-core is NOT installed in the image: the official online installer is part of what the lab proves.
# No credentials are baked in: host keys are generated at first start, the client's PUBLIC key arrives in
# $LAB_AUTHORIZED_KEY at run time.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server openssh-client curl ca-certificates tar python3 procps less vim-tiny \
      iproute2 \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/ssh/ssh_host_* \
 && mkdir -p /run/sshd   # the package postinst made host keys: delete them, the entrypoint generates fresh ones

# user without sudo, locked password (key auth only), stock Ubuntu skeleton (.profile, .bashrc, .bash_logout)
RUN useradd --create-home --shell /bin/bash waycar \
 && usermod -p '*' waycar \
 && mkdir -p /home/waycar/.ssh /home/waycar/work \
 && chmod 700 /home/waycar/.ssh \
 && chown -R waycar:waycar /home/waycar

# sshd policy. Drop-in is read first (first value wins in sshd_config).
RUN printf '%s\n' \
      'PasswordAuthentication no' \
      'KbdInteractiveAuthentication no' \
      'PubkeyAuthentication yes' \
      'PermitRootLogin no' \
      'AllowTcpForwarding no' \
      'PrintMotd yes' \
      'UsePAM yes' \
      'AllowUsers waycar' \
      > /etc/ssh/sshd_config.d/00-core-lab.conf \
 && printf '%s\n' \
      '' \
      '  +--------------------------------------------------+' \
      '  |  core lab: a throwaway herdr-core test host       |' \
      '  |  this MOTD is real text for PrintMotd yes         |' \
      '  +--------------------------------------------------+' \
      '' \
      > /etc/motd

COPY entrypoint.sh /usr/local/sbin/lab-entrypoint
COPY agents/fake-agent.sh /opt/lab/fake-agent.sh
COPY launch-lab-terminals.sh /opt/lab/launch-lab-terminals.sh
RUN chmod 0755 /usr/local/sbin/lab-entrypoint /opt/lab/fake-agent.sh /opt/lab/launch-lab-terminals.sh \
 && mkdir -p /home/waycar/lab && cp /opt/lab/fake-agent.sh /opt/lab/launch-lab-terminals.sh /home/waycar/lab/ \
 && chown -R waycar:waycar /home/waycar/lab

EXPOSE 22
ENTRYPOINT ["/usr/local/sbin/lab-entrypoint"]
