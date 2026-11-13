---
title: Waycar vs Termius
metaTitle: "Waycar vs Termius: mosh and coding agents on iPhone"
description: "Looking for a Termius alternative with mosh? Termius has mosh. Waycar adds status, push and chat for coding agents in tmux or herdr."
name: Termius
kind: ssh-client
summary: Termius is a cross-platform SSH client with SFTP, port forwarding and mosh. Waycar is an agent console for coding agents in tmux or herdr.
checked: 2026-10-18
order: 1
keywords: [termius alternative, termius alternative with mosh, termius vs waycar, mosh client ios, ssh client for coding agents, claude code iphone]
rows:
  runs-where: { level: info, text: "Your own server or machine. Termius is only the client" }
  account: { level: info, text: "Optional. First run asks you to sign in. Sync needs Pro" }
  path: { level: info, text: "SSH or mosh from the app. Cloud vault is for sync" }
  mosh: { level: yes, text: "Yes, on iOS, Android and desktop" }
  persistent: { level: partial, text: "Partial: mosh keeps the session; tmux to reattach" }
  host-setup: { level: info, text: "SSH server. mosh-server 1.3.0+ for mosh. tmux optional" }
  agents: { level: info, text: "Any CLI. Per-host auto-start for Gemini, Claude Code, more" }
  status: { level: unknown, text: "Not documented" }
  push: { level: unknown, text: "Not documented" }
  approve: { level: partial, text: "Partial: type the answer. Shift+Tab key, voice input" }
  chat: { level: unknown, text: "Not documented" }
  terminal: { level: yes, text: "Yes, a full terminal with a special-keys keyboard" }
  live-activity: { level: partial, text: "Partial: shows active connections, not agent state" }
  attach: { level: yes, text: "Yes, paste uploads over SFTP and inserts the path" }
  voice: { level: yes, text: "Yes, a speech-to-text input field" }
  carplay: { level: unknown, text: "Not documented" }
  usage: { level: unknown, text: "Not documented" }
  resume: { level: unknown, text: "Not documented" }
  ios: { level: yes, text: "Yes, iPhone and iPad, iOS 17 or later" }
  android: { level: yes, text: "Yes, on Google Play" }
  desktop: { level: yes, text: "Yes: macOS, Windows and Linux apps" }
  source: { level: info, text: "Closed source. No public app repo found" }
  price: { level: info, text: "Free Starter. Pro from $10/mo billed yearly" }
  general-ssh: { level: yes, text: "Yes: SSH, SFTP, port forwarding, jump hosts" }
pickWaycar:
  - Your phone time goes to coding agents that run in tmux or herdr on your own machine.
  - You want one list of agents sorted by who needs you, and a push when one is Blocked or Done.
  - You want Chat Mode for 14 agents you start in Waycar, with Allow and Cancel for permission requests, not a wall of terminal text.
  - You want no account, and no Waycar server in the path of your sessions, which go over mosh or SSH.
pickThem:
  - You need one SSH client for any server, with SFTP and port forwarding.
  - You want the same app on Android, Mac, Windows and Linux, with hosts and keys synced.
  - You work on machines that do not run tmux, herdr or herdr-core.
  - You want shared vaults and one bill for a team.
faq:
  - q: Does Termius support mosh on iPhone?
    a: Yes. Termius has mosh on iOS, Android and desktop, and both store listings place it in the free Starter plan. Your machine needs mosh-server 1.3.0 or newer. Termius notes that mosh sessions are not recorded in its session logs.
  - q: Is there a Termius alternative with mosh for coding agents?
    a: Waycar runs agent terminals over mosh and falls back to SSH on its own. Its agent terminals need herdr, tmux or herdr-core, and it is built around coding agents rather than general server work.
  - q: Does Termius work with Claude Code?
    a: Yes, as a terminal. You can run claude in Termius like any command, and its iOS release notes describe a per-host setting that starts an agent when you connect. We did not find an agent status list, push alerts for agents, or approve and deny buttons in its docs. Waycar adds a status list and push alerts, with Status Hooks for 17 tmux agents. It adds Allow and Cancel buttons in Chat Mode.
  - q: Can Termius keep a session alive in the background on iPhone?
    a: Partly. Termius says recent versions stop background activity within about 20 to 30 seconds. Its help article lists location tracking as a way to make background connections less likely to drop. Its blog suggests turning on Live Activities and running the agent in tmux. Waycar works inside the same iOS limit. Its terminal ends about 20 seconds after you leave the app and re-attaches when you come back, while the agent keeps running in herdr or tmux.
  - q: How does the price compare?
    a: Termius Starter is free, and its pricing page lists Pro at $10 a month billed yearly. The US App Store lists Pro Monthly at $15.00 and Pro Annual at $119.00. Waycar is free.
sources:
  - { label: Termius pricing, url: "https://termius.com/pricing" }
  - { label: "Termius docs: connecting to a server (mosh)", url: "https://docs.termius.com/organize-and-connect-to-hosts/connecting-to-a-server" }
  - { label: "Termius docs: keeping sessions alive on iOS", url: "https://docs.termius.com/help-center/faq/how-can-i-keep-termius-sessions-alive-in-the-background-on-ios-ipados" }
  - { label: "Termius docs: mobile terminal and pasting files", url: "https://docs.termius.com/terminal/mobile-terminal" }
  - { label: "Termius docs: session logs", url: "https://docs.termius.com/organize-and-connect-to-hosts/session-logs" }
  - { label: "Termius docs: using Termius without an account", url: "https://docs.termius.com/help-center/faq/why-am-i-required-to-create-an-account" }
  - { label: "Termius docs: download", url: "https://docs.termius.com/getting-started/download-termius" }
  - { label: Termius iOS release notes, url: "https://docs.termius.com/changelog/ios" }
  - { label: "Termius blog: AI agents on mobile", url: "https://termius.com/blog/8-tips-for-using-ai-agents-on-mobile-in-termius" }
  - { label: Termius on the App Store, url: "https://apps.apple.com/us/app/termius-modern-ssh-client/id549039908" }
  - { label: Termius on Google Play, url: "https://play.google.com/store/apps/details?id=com.server.auditor.ssh.client" }
related: [blink-shell, shellfish, claude-code-remote-control]
solutions: [mosh-client-ios, tmux-on-iphone]
---

## What Termius is

Termius is a cross-platform SSH client. It runs on iPhone, iPad, Android, macOS, Windows and Linux. It has SFTP, port forwarding, jump hosts, snippets and mosh. An encrypted cloud vault syncs your hosts and keys between devices. You can use it without an account. Sync needs an account and a Pro plan.

Termius has added several helpers for coding agents on iOS. Its release notes describe a per-host setting that starts an agent when you connect, a Shift+Tab key, a speech-to-text field for prompts, and pasting images and files into the terminal. It also has a Live Activity that shows your active connections and port forwarding.

These are terminal aids. We did not find an agent status list, push alerts for agent events, an approve and deny screen, or a chat view in its docs.

## Mosh is not the difference

If you searched for a Termius alternative with mosh, know this first: Termius has mosh. The store listings put it in the free Starter plan. The docs say Termius uses its own mosh library, with mosh 1.3.0 and newer on your machine.

Waycar also runs agent terminals over mosh, and it falls back to SSH when mosh cannot get through. So choose between them on what sits around the terminal.

Both apps work inside the same iOS limit. iOS stops background network activity soon after you leave an app. Termius says that is usually within 20 to 30 seconds. Its help article lists location tracking as a way to make background connections less likely to drop. Its blog suggests turning on Live Activities and running the agent in tmux. Waycar keeps its terminal for about 20 seconds, then ends the session and re-attaches on its own when you come back. If the agent lives in tmux or herdr on your machine, it keeps running either way.

## What Waycar adds to Termius

Waycar is not a general terminal. It is a console for coding agents that run in tmux or herdr on your own machines.

- **One list, sorted by who needs you.** The Console shows agents from all your machines as Blocked, Done, Working or Idle. Blocked agents come first, after any you pinned. We did not find an agent status list in Termius's docs.
- **A push when it matters.** You get a notification when an agent is Blocked or Done, with [Status Hooks for 17 agents](/help/tmux-hooks) on tmux. Your machine encrypts it first, so Waycar's push relay cannot read it. Termius's Live Activity shows your connections. Waycar's shows how many agents are working, blocked, done or idle.
- **Chat Mode for 14 agents.** Start a supported agent in Waycar with Chat Mode on, and it opens as a chat. When one asks for permission, you tap Allow or Cancel.
- **Agents that outlive your phone.** Waycar starts agents inside herdr or tmux, so they keep going when your phone drops off. Closed Sessions bring back an agent you quit by mistake, for 30 days.

Waycar has no account. Your sessions go straight from your phone to your machine over mosh or SSH. Waycar has no cloud server in that path.

## Where Termius is better

Termius wins on these:

- **Any server.** Termius connects to any SSH server. Waycar's agent terminals need herdr, tmux or herdr-core; it cannot open an arbitrary SSH server.
- **Files and tunnels.** Termius has a full SFTP browser and local, remote and dynamic port forwarding. Waycar has no SFTP file browser and no port forwarding. It uses SFTP to upload the files you attach and to preview files an agent mentions.
- **Every platform.** Termius runs on Android and on desktop, and it syncs hosts across them. Waycar is an iPhone and iPad app with no native desktop or web client. An Android app is coming soon.
- **Teams.** Termius sells Team and Business plans with shared vaults.

## What each costs

Termius Starter is free and covers SSH, SFTP and port forwarding. Pro adds the cloud vault and sync. Termius lists Pro at $10 a month billed yearly on its site. The US App Store lists Pro Monthly at $15.00 and Pro Annual at $119.00.

Waycar is free.

## Can you use both?

Yes. Keep Termius for servers and files. Use Waycar for the agents on your machine. They do not get in each other's way.
