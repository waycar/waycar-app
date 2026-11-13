---
title: Set up a Linux Host
description: Install the OpenSSH server and herdr or tmux 3.2 on your Linux machine, then run the Waycar install command and pair.
category: get-started
order: 70
keywords: [ubuntu, debian, fedora, rocky, alpine, openssh, sshd, server]
related: [install, requirements, pairing, mac-host]
---

To use a Linux machine as a Host, install and start the OpenSSH server, install herdr or tmux 3.2 or later, then run the Waycar install command and scan its Pairing Code.

A machine that runs herdr-core works too. See [Waycar with herdr-core](/help/herdr-core).

## Set up your Linux machine

1. **Install and start the OpenSSH server.**
2. **Install herdr or tmux.** Get herdr at [herdr.dev](https://herdr.dev), or use tmux 3.2 or later.
3. **Check for `curl` and `tar`.** The install command uses both. Nothing else is needed.
4. **Install mosh (optional).** Install `mosh-server` and let UDP traffic reach it. See [mosh.org](https://mosh.org/#getting).
5. **Run the install command**:

   ```sh
   curl -fsSL https://waycar.dev/install.sh | sh
   ```

6. **Pair.** Say yes when it offers a pairing QR code, then tap **Scan to Pair** in Waycar. See [Pair with a Pairing Code](/help/pairing).

## What does my distribution need?

Only herdr or tmux 3.2 or later. Waycar's tools are one static program with nothing else to install: no Node.js, no npm, no version manager, no certificate bundle. They run on Linux x86_64 and ARM64 with any libc, Alpine included.

| Distribution | tmux by default |
| --- | --- |
| Ubuntu 24.04 | 3.4 |
| Ubuntu 22.04 | 3.2a |
| Debian 12 | 3.3a |
| Rocky Linux 9 | 3.2a |
| Fedora 44 | 3.7c |

Enterprise Linux 8 ships tmux 2.7, which is too old. The install command also needs `curl` and `tar`.

## Allow forwarding for herdr

Waycar reaches herdr's socket through SSH stream-local forwarding. `AllowTcpForwarding no` in `sshd_config` blocks it, so set `AllowTcpForwarding` to `local` or `yes` and restart sshd. tmux Hosts don't need this.

## Copy the Pairing Code on Linux

If you can't scan the QR, press `c`. On Linux the code is shown on screen so you can select and copy it, then tap **Paste Pairing Code** in Waycar.

## Troubleshooting

- **"Could not open the herdr socket"**: start herdr on the Host, or enable SSH stream-local forwarding, then run the checks again.
- **Already ran the older, Node-based install?** Run the install command again. It replaces the old tools with the native ones and leaves your own Node, npm and nvm alone. Codex asks you to review its hooks once with `/hooks`.
- **`waycar` isn't found**: add `~/.local/bin` to your PATH.
