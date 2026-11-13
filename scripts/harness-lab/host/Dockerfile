# Waycar harness lab host (scripts/harness-lab): Ubuntu 24.04 with sshd,
# the distro tmux, herdr, mosh-server, Node 22 and the 17 lab agent
# harnesses, each pointed at the lab's mock model server (http://mock:8080).
# Built by scripts/harness-lab/lab.sh, which passes VERSIONS as build args.
# Waycar Host Tools are not baked in: the entrypoint installs them from the
# worktree's plugin/ (mounted read-only) on every start.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      openssh-server tmux mosh git curl ca-certificates gnupg procps bash \
      less vim-tiny unzip xz-utils zstd rsync jq file sudo \
      python3 python3-venv build-essential \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd /etc/harness-lab \
 && rm -f /etc/ssh/ssh_host_*

ARG NODE_MAJOR
RUN curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && rm -rf /var/lib/apt/lists/* \
 && printf 'node %s nodesource-apt %s\n' "$(node -v)" "$(uname -m)" >>/etc/harness-lab/versions.txt

ARG HERDR_VERSION
ARG HERDR_SHA256_AARCH64
RUN curl -fsSL -o /usr/local/bin/herdr \
      "https://github.com/herdrdev/herdr/releases/download/v${HERDR_VERSION}/herdr-linux-aarch64" \
 && echo "${HERDR_SHA256_AARCH64}  /usr/local/bin/herdr" | sha256sum -c - \
 && chmod 755 /usr/local/bin/herdr \
 && printf '%s release-asset %s\n' "$(herdr --version)" "$(uname -m)" >>/etc/harness-lab/versions.txt

COPY sshd.conf /etc/ssh/sshd_config.d/00-harness-lab.conf
# Key-only login for `waycar`; the public key is mounted at start. Passwordless
# sudo: this is a throwaway lab, and harness debugging sometimes needs root.
RUN (userdel -r ubuntu 2>/dev/null || true) \
 && useradd -m -s /bin/bash waycar && usermod -p '*' waycar \
 && echo 'waycar ALL=(ALL) NOPASSWD: ALL' >/etc/sudoers.d/waycar && chmod 440 /etc/sudoers.d/waycar \
 && install -d -m 700 -o waycar -g waycar /home/waycar/.ssh \
 && chown waycar:waycar /etc/harness-lab/versions.txt

USER waycar
WORKDIR /home/waycar
ENV HOME=/home/waycar \
    PATH=/home/waycar/.local/bin:/home/waycar/.npm-global/bin:/home/waycar/.opencode/bin:/home/waycar/.grok/bin:/home/waycar/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# `rec <kind> <version> <method>` appends to /etc/harness-lab/versions.txt.
RUN mkdir -p .local/bin .npm-global && npm config set prefix "$HOME/.npm-global" \
 && printf '%s\n' '#!/bin/sh' 'printf "%s %s %s %s\n" "$1" "$2" "$3" "$(uname -m)" >>/etc/harness-lab/versions.txt' >.local/bin/harness-lab-rec \
 && chmod +x .local/bin/harness-lab-rec

# One layer per harness, npm installs first. Every installer runs as waycar.
ARG CODEX_VERSION
RUN npm i -g --no-fund --no-audit "@openai/codex@${CODEX_VERSION}" \
 && harness-lab-rec codex "$(codex --version)" "npm @openai/codex"
ARG COPILOT_VERSION
RUN npm i -g --no-fund --no-audit "@github/copilot@${COPILOT_VERSION}" \
 && harness-lab-rec copilot "$(copilot --version | head -n1)" "npm @github/copilot"
ARG PI_VERSION
RUN npm i -g --no-fund --no-audit "@earendil-works/pi-coding-agent@${PI_VERSION}" \
 && harness-lab-rec pi "$(pi --version)" "npm @earendil-works/pi-coding-agent"
ARG GEMINI_VERSION
RUN npm i -g --no-fund --no-audit "@google/gemini-cli@${GEMINI_VERSION}" \
 && harness-lab-rec gemini "$(gemini --version)" "npm @google/gemini-cli"
ARG CLINE_VERSION
RUN npm i -g --no-fund --no-audit "cline@${CLINE_VERSION}" \
 && harness-lab-rec cline "$(cline --version | head -n1)" "npm cline"
ARG KILO_VERSION
RUN npm i -g --no-fund --no-audit "@kilocode/cli@${KILO_VERSION}" \
 && harness-lab-rec kilo "$(kilo --version)" "npm @kilocode/cli"
ARG QWEN_VERSION
RUN npm i -g --no-fund --no-audit "@qwen-code/qwen-code@${QWEN_VERSION}" \
 && harness-lab-rec qwen "$(qwen --version)" "npm @qwen-code/qwen-code"

# curl installers.
ARG CLAUDE_VERSION
RUN curl -fsSL https://claude.ai/install.sh | bash -s "${CLAUDE_VERSION}" \
 && harness-lab-rec claude "$(claude --version)" "claude.ai/install.sh"
ARG OPENCODE_VERSION
RUN curl -fsSL https://opencode.ai/install | bash -s -- --version "${OPENCODE_VERSION}" \
 && harness-lab-rec opencode "$(opencode --version)" "opencode.ai/install"
ARG CURSOR_VERSION
RUN curl -fsSL https://cursor.com/install | bash \
 && harness-lab-rec cursor "$(cursor-agent --version) (VERSIONS records ${CURSOR_VERSION})" "cursor.com/install"
ARG AGY_VERSION
RUN curl -fsSL https://antigravity.google/cli/install.sh | bash \
 && harness-lab-rec agy "$(agy --version | head -n1) (VERSIONS records ${AGY_VERSION})" "antigravity.google/cli/install.sh"
ARG OMP_VERSION
RUN curl -fsSL https://omp.sh/install | sh -s -- --binary --ref "v${OMP_VERSION}" \
 && harness-lab-rec omp "$(omp --version)" "omp.sh/install --binary"
ARG KIRO_VERSION
RUN curl -fsSL https://cli.kiro.dev/install | bash \
 && harness-lab-rec kiro "$(kiro-cli --version) (VERSIONS records ${KIRO_VERSION})" "cli.kiro.dev/install"
# setup.sh ends with `devin setup`, an interactive login, which fails without a
# TTY after the binary is in place; the version check below gates the layer.
ARG DEVIN_VERSION
RUN curl -fsSL -o /tmp/devin-setup.sh "https://static.devin.ai/cli/${DEVIN_VERSION}/setup.sh" \
 && { bash /tmp/devin-setup.sh </dev/null || echo "harness-lab: devin setup (login) skipped"; } \
 && rm /tmp/devin-setup.sh \
 && harness-lab-rec devin "$(devin --version | head -n1)" "cli.devin.ai/install.sh (versioned setup.sh)"
ARG GROK_VERSION
RUN curl -fsSL https://x.ai/cli/install.sh | bash -s "${GROK_VERSION}" \
 && harness-lab-rec grok "$(grok --version)" "x.ai/cli/install.sh"
ARG HERMES_COMMIT
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
      | bash -s -- --non-interactive --skip-browser --skip-computer-use --commit "${HERMES_COMMIT}" \
 && harness-lab-rec hermes "$(hermes --version | head -n1)" "hermes install.sh --commit ${HERMES_COMMIT}"
# The installer takes only the channel's latest release. A far-future
# update stamp keeps the launcher's hourly self-update off even where
# MUSE_NO_AUTO_UPDATE (config/muse/env) is not in the environment.
ARG MUSE_VERSION
RUN curl -fsSL https://dev.meta.ai/install.sh | MUSE_LOGIN=0 bash \
 && echo 9999999999 > "$HOME/.local/bin/.muse-update-checked-at" \
 && harness-lab-rec muse "$(MUSE_NO_AUTO_UPDATE=1 muse --version) (VERSIONS records ${MUSE_VERSION})" "dev.meta.ai/install.sh"

# Per-harness mock configuration and the demo project. Changes here rebuild
# only this layer.
COPY --chown=waycar:waycar config /opt/harness-lab/config
COPY --chown=waycar:waycar setup-home.sh install-plugin.sh /opt/harness-lab/
RUN sh /opt/harness-lab/setup-home.sh

USER root
WORKDIR /
COPY entrypoint.sh /usr/local/sbin/harness-lab-entrypoint
EXPOSE 22
CMD ["/usr/local/sbin/harness-lab-entrypoint"]
