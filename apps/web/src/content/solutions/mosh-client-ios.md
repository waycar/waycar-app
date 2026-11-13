---
title: Mosh on iPhone and iPad for coding agents
metaTitle: "Mosh on iPhone and iPad for coding agents"
description: "Looking for a mosh client for iPhone or iPad? Blink Shell and Termius have one. Waycar uses mosh for coding agents in tmux or herdr, with an SSH fallback."
query: mosh client ios
summary: Waycar uses mosh for coding agents on iPhone and iPad. What your machine needs, what it does not do, and which clients suit general mosh.
answer: Waycar opens your coding agents' terminals over mosh on iPhone and iPad, and falls back to SSH when mosh cannot get through. It is not a general mosh client. For mosh, your machine must run tmux or herdr, plus mosh-server with UDP open. Without mosh-server or reachable UDP, Waycar stays on SSH. For general mosh, use Blink Shell or Termius.
needs:
  - "An iPhone or iPad on iOS or iPadOS 18 or later."
  - "A Mac or Linux machine you can reach over SSH, running tmux 3.2 or later or herdr 0.7.5 or later. herdr also needs AllowTcpForwarding set to local or yes."
  - "mosh-server installed on that machine, for mosh. Without it Waycar stays on SSH."
  - "UDP traffic that can reach the machine. mosh uses UDP ports 60000 through 61000 by default."
  - "`curl` and `tar` on the machine, for the install command that sets up the Waycar host tools. No Node needed."
order: 2
updated: 2026-11-12
keywords: [mosh client ios, mosh iphone, mosh ipad, mosh for coding agents, mosh ssh fallback, mosh tmux iphone]
faq:
  - q: Is there a mosh client for iPhone?
    a: Yes. Blink Shell and Termius both have mosh on iOS, and both connect to any server. Waycar runs agent terminals over mosh too, but only for machines that run tmux or herdr. It is built for coding agents, not for general server work.
  - q: What does my machine need for mosh?
    a: mosh-server installed, and UDP traffic able to reach it. mosh uses UDP ports 60000 through 61000 by default. Waycar starts mosh over its own SSH connection, so there is nothing else to set up. If either piece is missing, Waycar stays on SSH.
  - q: Does mosh work through a Jump Host in Waycar?
    a: mosh's UDP does not go through a Jump Host. Waycar sends it straight to your machine's address, so that address must be reachable over UDP from where you are. If it is not, the session runs over SSH. Waycar checks host keys at both hops either way.
  - q: What happens to my terminal when I lock my iPhone?
    a: Waycar keeps running for about 20 seconds after you leave the app. Then the terminal session ends, and it re-attaches on its own when you come back. The agent keeps running in tmux or herdr on your machine the whole time.
  - q: Does Waycar have predictive local echo?
    a: No. Typed characters appear when your machine echoes them back. Waycar does not guess ahead the way the desktop mosh client can. Blink Shell's docs describe predictive local echo, set for each host. Termius's docs describe mosh's local echo in general terms. The Composer in Waycar is a local draft, so a prompt you write there is not slowed by a weak signal.
  - q: What if my network blocks UDP?
    a: Waycar falls back to SSH on its own. It remembers, for each machine and each network, whether mosh gets through, so a network that blocks UDP goes straight to SSH. A MOSH or SSH badge shows which one you are on.
compare: [blink-shell, termius]
help: [mosh, mosh-not-connecting, reconnecting, requirements]
---

## What mosh does for a phone

SSH is one TCP connection tied to your phone's network address. Move from Wi-Fi to cellular and it drops. mosh runs over UDP and roams, so the session carries on across the change. `mosh-server` runs on your machine and holds the session there. Your phone gets mosh's redraw of the current screen, so after a dead zone you land on the live screen, not on a replay of everything you missed.

For a coding agent that is the useful part. You walk out of Wi-Fi range and the agent's terminal is still attached when you look again.

## Which mosh client to pick

Blink Shell and Termius both support mosh on iPhone and iPad, and both are general SSH clients that work with any server. Blink's docs describe predictive local echo, set for each host. Termius lists mosh on iOS, Android and desktop. Pick one of them if you want mosh for general server work.

Pick Waycar if what you want is to check on coding agents that run in tmux or herdr on your own machines. See [Waycar vs Blink Shell](/compare/blink-shell) and [Waycar vs Termius](/compare/termius), with sources.

## How Waycar uses mosh

- **It starts mosh for you.** Waycar launches mosh over its own SSH connection. You do not run `mosh` by hand.
- **It falls back to SSH.** If mosh-server is missing or UDP is blocked, the agent runs over SSH. Waycar remembers, for each machine and network, whether mosh gets through.
- **It shows which one you are on.** A MOSH or SSH badge sits beside each machine you added. Tap Test Mosh Support on that machine's page to check it.
- **It rides out gaps.** While the app is open, mosh carries on through network gaps of up to about a minute. After about six seconds of silence a Reconnecting pill appears so you know the screen is not frozen.

## What Waycar's mosh does not do

- **It is not a general mosh client.** Waycar's mosh attaches to tmux or herdr. herdr-core works over SSH only. Waycar's agent terminals need one of those three Backends, not an arbitrary SSH server.
- **No predictive local echo.** Typed characters show up once your machine echoes them.
- **iOS ends background sessions.** Waycar keeps running about 20 seconds after you leave. Then the terminal session ends, mosh and SSH alike, and it re-attaches on its own when you return. Back within about a minute is fast, because Waycar starts a fresh mosh server before it lets the old one go.
- **A Jump Host does not carry mosh.** A Jump Host is a server that forwards your connection to the machine. mosh's UDP goes straight to your machine's address. If your phone cannot reach it over UDP, the session runs over SSH.

## Set it up

1. Install `mosh-server` on the machine. [mosh.org](https://mosh.org) lists packages for most systems.
2. Make sure UDP traffic can reach the machine.
3. Run the Waycar install command on the machine and scan the pairing QR code in the app:

   ```sh
   curl -fsSL https://waycar.dev/install.sh | sh
   ```

4. Open the machine's page and tap Test Mosh Support. A pass reads "Mosh supported", and agent sessions ride mosh from then on.

Running agents in tmux? [tmux on your iPhone](/solutions/tmux-on-iphone) covers that setup.
