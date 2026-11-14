---
title: Requirements
description: What your iPhone or iPad and your Host need for Waycar, from iOS 18 to herdr 0.7.5 or tmux 3.2, OpenSSH and optional mosh.
category: get-started
order: 20
keywords: [system requirements, ios 18, openssh, version, minimum, compatibility]
related: [install, install-tmux-or-herdr, mac-host, linux-host]
---

Waycar needs an iPhone or iPad on iOS or iPadOS 18 or later, and a Host you can reach over SSH that runs herdr 0.7.5 or later, or tmux 3.2 or later. Nothing else is required on the Host: the Waycar tools are a native program, with no Node.js. Your agents may be Node programs; that is up to them.

## On your iPhone or iPad

- iOS or iPadOS 18 or later.
- Dictation needs iOS 26 or later. [CarPlay](/help/carplay) needs an iPhone on iOS 26.4 or later.

## On your Host

| What | Version | Why |
| --- | --- | --- |
| herdr | 0.7.5 or later | One of the two Backends Waycar works with |
| tmux | 3.2 or later | The other Backend. You need herdr, tmux, or both |
| herdr-core | 0.1.10 or later | A third Backend, under the Herdr app. Update it with `herdr-core update`. See [Waycar with herdr-core](/help/herdr-core) |
| `curl` and `tar` | Any | Only for the install command. The Waycar tools themselves are one static program for Linux and macOS, with no Node.js, npm or certificate bundle to install |
| OpenSSH server | Stock config | Waycar connects over SSH |
| `mosh-server` | Any | Optional, for mosh terminals. UDP traffic must reach it |

Waycar only checks for a minimum herdr version, so newer herdr releases keep working.

## SSH settings

- **On a Mac**, turn on Remote Login. See [Set up a Mac as a Host](/help/mac-host).
- **On Linux**, install and start the OpenSSH server. See [Set up a Linux Host](/help/linux-host).
- **For herdr**, the SSH server must allow stream-local forwarding. Waycar reaches herdr's socket through it. `AllowTcpForwarding no` blocks it too, so set `AllowTcpForwarding` to `local` or `yes` in `sshd_config`.

## Which agents?

Waycar watches claude, codex, omp, gemini, opencode, pi and more. Install the ones you use on the Host. See [Supported agents](/help/supported-agents).

## Troubleshooting

- **Still running the older, Node-based tools?** Run the install command again, or let Waycar do it when it asks. The new tools need no Node.js, and the update leaves your own Node, npm and nvm alone.
- **The install command says tmux is too old.** Install tmux 3.2 or later, or herdr. See [Install tmux or herdr on your Host](/help/install-tmux-or-herdr).
- **The Host's checks say "Neither herdr nor tmux was found on the Host."** Install tmux 3.2 or later, or herdr, on that machine. See [Install tmux or herdr on your Host](/help/install-tmux-or-herdr).
- **Another install error or warning?** See [The install command fails](/help/install-fails).
