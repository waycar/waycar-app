---
title: Waycar vs Blink Shell
metaTitle: "Waycar vs Blink Shell: mosh for coding agents"
description: "Blink Shell is an open source iOS terminal with mosh built in. Waycar is built for coding agents in tmux or herdr: status, push alerts and chat."
name: Blink Shell
kind: ssh-client
summary: Blink Shell is an open source terminal for iPhone and iPad with mosh built in. Waycar is an agent console for coding agents in tmux or herdr.
checked: 2026-10-18
order: 2
keywords: [blink shell mosh, blink shell alternative, blink shell vs waycar, mosh client ios, ssh client for coding agents, claude code iphone]
rows:
  runs-where: { level: info, text: "Your own server or Mac. Optional Blink Build cloud VM" }
  account: { level: info, text: "None for SSH or mosh. Blink Build needs a sign-up" }
  path: { level: info, text: "Direct SSH or mosh to your machine" }
  mosh: { level: yes, text: "Yes, built in, with predictive local echo" }
  persistent: { level: partial, text: "Partial: mosh keeps the session; tmux to reattach" }
  host-setup: { level: info, text: "SSH server. mosh-server and UDP (60000-61000 default)" }
  agents: { level: info, text: "Any CLI. Prompt Mode for AI prompts; no status or chat" }
  status: { level: unknown, text: "Not documented" }
  push: { level: partial, text: "Partial: terminal bell and escape codes, not agent-aware" }
  approve: { level: partial, text: "Partial: type the answer into the terminal" }
  chat: { level: unknown, text: "Not documented" }
  terminal: { level: yes, text: "Yes, a full terminal with tabs and windows" }
  live-activity: { level: unknown, text: "Not documented" }
  attach: { level: partial, text: "Partial: files via SFTP and the Files app" }
  voice: { level: yes, text: "Yes, voice input in Prompt Mode" }
  carplay: { level: unknown, text: "Not documented" }
  usage: { level: unknown, text: "Not documented" }
  resume: { level: unknown, text: "Not documented" }
  ios: { level: yes, text: "Yes, iPhone and iPad, iOS 17.6 or later" }
  desktop: { level: no, text: "No. Blink's FAQ says a macOS version is planned" }
  source: { level: info, text: "Open source, GPL v3 with extra terms" }
  price: { level: info, text: "14-day trial, then $19.99 a year (US)" }
  general-ssh: { level: yes, text: "Yes: SSH, SFTP, tunnels, jump hosts, SSH config" }
pickWaycar:
  - You run coding agents in tmux or herdr and want one list sorted by who needs you, and a push when one is Blocked or Done.
  - You want Chat Mode for 14 agents you start in Waycar, with Allow and Cancel for permission requests.
  - You want the agent to outlive your phone, and a way to bring back one you quit by mistake. Closed Sessions keep it for 30 days.
  - You want a free app.
pickThem:
  - You want mosh with predictive local echo that you can set for each host.
  - "You need a general SSH toolkit: any server, SFTP in the Files app and port forwarding."
  - You want an open source app and deep hardware keyboard remapping.
  - You work on machines that do not run tmux, herdr or herdr-core.
faq:
  - q: Does Blink Shell support mosh?
    a: Yes. Mosh is built in. Blink's docs describe predictive local echo, which you can set to Adaptive, Always or Never for each host, and roaming across networks. Your machine needs mosh-server, and UDP ports must be open, 60000 through 61000 by default.
  - q: Is Waycar a Blink Shell alternative?
    a: For coding agents, yes. For general SSH, no. Waycar runs agent terminals over mosh and falls back to SSH, but its agent terminals need herdr, tmux or herdr-core, and it has no SFTP file browser or port forwarding.
  - q: Does Blink Shell send a notification when a coding agent needs me?
    a: Blink's notifications are the terminal bell and escape-code alerts, and its docs say some of them are not supported in mosh. We did not find agent-aware alerts in its docs. Waycar sends a push when an agent is Blocked or Done.
  - q: Can I run Claude Code in Blink Shell?
    a: Yes, as a terminal. Blink runs any command line tool, and its 18.5 release added a Prompt Mode for writing AI prompts with voice input. We did not find an agent status list or approve and deny buttons in its docs. Waycar adds a status list and push alerts, with Status Hooks for 17 tmux agents. It adds Allow and Cancel buttons in Chat Mode.
  - q: How does the price compare?
    a: Blink has a 14-day trial, then $19.99 a year (US), with no one-time purchase. Blink Build cloud machines cost extra, from $7.99 a month. Waycar is free.
sources:
  - { label: Blink Shell, url: "https://blink.sh/" }
  - { label: "Blink docs: mosh", url: "https://docs.blink.sh/advanced/advanced-mosh" }
  - { label: "Blink docs: hosts and mosh prediction", url: "https://docs.blink.sh/basics/hosts" }
  - { label: "Blink docs: notifications", url: "https://docs.blink.sh/basics/notifications" }
  - { label: "Blink docs: SSH, tunnels and jump hosts", url: "https://docs.blink.sh/advanced/advanced-ssh" }
  - { label: "Blink docs: Files app", url: "https://docs.blink.sh/advanced/files-app" }
  - { label: "Blink docs: Blink Build", url: "https://docs.blink.sh/build/start" }
  - { label: "Blink docs: FAQ", url: "https://docs.blink.sh/faq" }
  - { label: "Blink 18.5 release notes: Prompt Mode", url: "https://github.com/blinksh/blink/discussions/2220" }
  - { label: Blink Shell on the App Store, url: "https://apps.apple.com/us/app/blink-shell-build-code/id1594898306" }
  - { label: Blink Shell source, url: "https://github.com/blinksh/blink" }
  - { label: Blink Shell license terms, url: "https://blink.sh/blink-gpl" }
related: [termius, shellfish, claude-code-remote-control]
solutions: [mosh-client-ios, tmux-on-iphone]
---

## What Blink Shell is

Blink Shell is a terminal for iPhone and iPad. Its App Store name is "Blink Shell, Build & Code". Mosh is built in, next to SSH, SFTP through the Files app, port forwarding, jump hosts and full SSH config support. You can remap a hardware keyboard in detail. The source is public under the GNU GPL v3, with additional terms.

It has a 14-day trial, then $19.99 a year (US). Blink also includes Blink Code, which opens VS Code on local, remote or Codespaces projects. It sells Blink Build, a cloud machine you reach over mosh, as a separate subscription. This page is about using Blink as a client for your own machine.

## Mosh: Blink goes further than Waycar

If you searched for Blink Shell and mosh, you want to know how its mosh compares. It is built in, and its docs describe more settings than Waycar has.

Its docs describe predictive local echo. Blink guesses what a key press will show and underlines the guess on slow links. You can set it to Adaptive, Always or Never for each host. Waycar has no local echo prediction. Typed characters appear when your machine echoes them. The Waycar Composer is a local draft, so a prompt you write there is not slowed by a weak signal.

Both apps need mosh-server on your machine and open UDP. Blink's docs name UDP ports 60000 through 61000 as the default. Waycar starts mosh over its own SSH connection and falls back to SSH when mosh cannot get through.

On sleep, the two differ. Blink's site says your connections will be intact when you wake your device. Its notifications page also says the system can end an SSH connection after Blink goes to the background. It describes a command called `geo` that keeps the connection alive for notifications. Mosh sessions resume after a gap. Waycar keeps its terminal for about 20 seconds after you leave the app. Then the session ends, and Waycar re-attaches on its own when you come back. With either app, an agent keeps running if it lives in tmux or herdr on your machine.

## What Waycar adds to Blink Shell

Blink is a terminal. Waycar is a console for coding agents that run in tmux or herdr on your own machines.

- **One list, sorted by who needs you.** The Console shows agents from all your machines as Blocked, Done, Working or Idle. Blocked agents come first, after any you pinned. We did not find an agent status list in Blink's docs.
- **A push that knows about agents.** You get a notification when an agent is Blocked or Done, with [Status Hooks for 17 agents](/help/tmux-hooks) on tmux. Your machine encrypts it first, so Waycar's push relay cannot read it. Blink's alerts come from the terminal bell and escape codes.
- **Chat Mode for 14 agents.** Start a supported agent in Waycar with Chat Mode on, and it opens as a chat. When one asks for permission, you tap Allow or Cancel.
- **Agents that outlive your phone.** Waycar starts agents inside herdr or tmux, so they keep going when your phone drops off. Closed Sessions bring back an agent you quit by mistake, for 30 days.

Waycar has no account. Your sessions go straight from your phone to your machine over mosh or SSH, with no cloud server in that path.

## Where Blink Shell is better

Blink wins on these:

- **Predictive local echo.** Blink guesses what a key press will show and lets you set that for each host. Waycar has no local echo prediction.
- **Any server.** Blink connects to any SSH server. Waycar's agent terminals need herdr, tmux or herdr-core; it cannot open an arbitrary SSH server.
- **Files and tunnels.** Remote files show up in the iOS Files app, and Blink supports local, remote and dynamic port forwarding. Waycar has no SFTP file browser and no port forwarding. It uses SFTP to upload the files you attach and to preview files an agent mentions.
- **A deep keyboard.** Blink lets you remap shortcuts, modifiers and single key presses on a hardware keyboard.

## What each costs

Blink has a 14-day trial, then $19.99 a year (US). Its FAQ says the earlier freemium model ended in 2023 and that Blink is no longer sold as a one-time purchase. Blink Build starts at $7.99 a month on top.

Waycar is free.

## Can you use both?

Yes. Use Blink for general SSH and for its mosh features. Use Waycar for the agents on your machine. They reach the same machine over the same SSH.
