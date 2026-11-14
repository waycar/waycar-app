---
title: Waycar vs Paseo
metaTitle: "Waycar vs Paseo: coding agents from your phone"
description: "Paseo runs coding agents through a daemon on your machine, with phone, desktop, web and CLI apps. Waycar steers agents in tmux or herdr."
name: Paseo
kind: agent-environment
summary: Paseo is an open source environment that runs coding agents through a daemon on your machine. Waycar is an iPhone and iPad console for agents in tmux or herdr.
checked: 2026-10-18
order: 9
keywords: [paseo alternative, paseo vs waycar, paseo vs tmux, paseo mobile app, check ai agent remotely, tmux on iphone, claude code from phone]
rows:
  runs-where: { level: info, text: "Your own machine, through the Paseo daemon" }
  account: { level: info, text: "None required" }
  path: { level: info, text: "Optional end-to-end encrypted relay, or direct address" }
  mosh: { level: unknown, text: "Not documented" }
  persistent: { level: yes, text: "Yes, the daemon keeps agents running" }
  host-setup: { level: info, text: "The Paseo daemon, plus the agent CLIs you use" }
  agents: { level: info, text: "Claude, Codex, OpenCode, Pi, OMP and 25+ more" }
  status: { level: yes, text: "Yes, agent state streams to every client" }
  push: { level: yes, text: "Yes, push notifications on mobile" }
  approve: { level: yes, text: "Yes, approvals and question cards" }
  chat: { level: yes, text: "Yes, a chat view of each agent" }
  terminal: { level: yes, text: "Yes, terminals on the daemon machine" }
  live-activity: { level: unknown, text: "Not documented" }
  attach: { level: yes, text: "Yes, image attachments in the composer" }
  voice: { level: yes, text: "Yes, dictation and voice mode" }
  carplay: { level: unknown, text: "Not documented" }
  usage: { level: yes, text: "Yes, subscription quota windows and a context meter" }
  resume: { level: yes, text: "Yes, History, restore and Import session" }
  ios: { level: yes, text: "Yes, iPhone and iPad, iOS 15.1 or later" }
  desktop: { level: yes, text: "Yes: macOS, Windows, Linux apps, web and CLI" }
  source: { level: info, text: "Open source, Apache License 2.0" }
  price: { level: info, text: "Free. Optional hosted Hub: $0 or $15/seat/mo" }
  general-ssh: { level: no, text: "No. SSH only reaches a Paseo daemon" }
pickWaycar:
  - You already run agents in tmux or herdr on your Mac or Linux machine, and you want to open those same sessions from your iPhone.
  - You want agent terminals over mosh, with SSH as a fallback, and no Waycar server in the path of your sessions.
  - You want one Console of agents sorted by who needs you, and a Lock Screen Live Activity.
  - You do not want to install a daemon that starts your agents for you.
pickThem:
  - You want one open source app on iPhone, Android, Mac, Windows, Linux, the web and the command line.
  - You want agents started and managed for you, many at once, each in its own git worktree if you choose.
  - You use agents beyond the 14 that Waycar's Chat Mode covers, including any agent that speaks the Agent Client Protocol.
  - You use an older iPhone (iOS 15.1 or later) or an Android phone.
faq:
  - q: Does Paseo work with tmux?
    a: We did not find attaching to a live tmux pane in its docs. Paseo starts agents itself, as programs run by its daemon. Its changelog lists an Import session screen for bringing in past sessions, including Claude Code and Codex, so you can pick up a conversation from the app. Its terminals are shells on the daemon machine. We did not find tmux sessions listed as agents in its docs. Waycar opens agents that run in tmux or herdr, and can start new ones there.
  - q: Does Paseo support mosh?
    a: We did not find mosh in the Paseo docs. Phones connect through an optional end-to-end encrypted relay, or directly through an address such as Tailscale. Paseo Desktop and the CLI can also tunnel over SSH. Waycar runs agent terminals over mosh and falls back to SSH.
  - q: Does Paseo need an account or a cloud service?
    a: Paseo says it has no required account and no telemetry. The relay is off by default and asks before you enable it. Its docs say traffic between phone and daemon is end-to-end encrypted. Paseo Hub is a separate optional service, hosted or self-hosted, and is not needed for phone access.
  - q: Is Paseo free and open source?
    a: Yes. Paseo is Apache License 2.0, and its site says it is free. You bring your own agent CLIs and logins. It is an independent project. Waycar's app is open source under Apache-2.0 and free.
  - q: Which one should I use to check on an agent from my phone?
    a: If your agents run in tmux or herdr today, Waycar opens them as they are. If you want a managed workspace with apps for every platform, Paseo fits better. Both have push alerts, approvals and a chat view, so the choice is about how agents start and where you use them.
sources:
  - { label: Paseo docs, url: "https://paseo.sh/docs" }
  - { label: "Paseo docs: connectivity and relay", url: "https://paseo.sh/docs/connectivity" }
  - { label: "Paseo docs: security", url: "https://paseo.sh/docs/security" }
  - { label: "Paseo docs: providers and agents", url: "https://paseo.sh/docs/providers" }
  - { label: Paseo changelog, url: "https://paseo.sh/changelog" }
  - { label: Paseo Hub pricing, url: "https://paseo.sh/hub" }
  - { label: "Paseo release 0.11.4 on GitHub", url: "https://github.com/getpaseo/paseo/releases/tag/v0.11.4" }
  - { label: "Paseo design note: agent lifecycle", url: "https://github.com/getpaseo/paseo/blob/main/docs/agent-lifecycle.md" }
  - { label: "Paseo docs: workspaces", url: "https://paseo.sh/docs/workspaces" }
  - { label: Paseo terms, url: "https://paseo.sh/terms" }
  - { label: "Paseo docs: why Paseo", url: "https://paseo.sh/docs/why" }
  - { label: Paseo on the App Store, url: "https://apps.apple.com/us/app/paseo-remote-coding-agents/id6758887924" }
related: [t3-code, orca, happy]
solutions: [check-ai-agent-remotely, tmux-on-iphone]
---

## What Paseo is

Paseo is an open source environment for running coding agents. It is an independent project. It has apps for macOS, Windows, Linux, iPhone, iPad and Android, plus a web app and a command line tool. The license is Apache 2.0.

Paseo does not ship an agent. It manages the agent CLIs you already use, such as Claude, Codex, OpenCode, Pi and OMP, and it can add other agents that speak the Agent Client Protocol (ACP). You can run many agents at once, and give each its own git worktree. As of 2026-10-18, its latest stable release is 0.11.4, dated 2026-10-15.

## Where the agent runs and how your phone reaches it

You install the Paseo daemon on your own machine. The desktop app bundles one and starts it for you. The daemon runs your agent CLIs as ordinary programs on that machine and owns the running agents and workspaces. Idle agents stay resident. Design notes in Paseo's repository say a provider process can die from a crash, an out-of-memory kill or a host suspend. Work running inside it dies too. Any agent process can fail this way, including one in tmux. The notes describe a closed agent as a saved record that can resume.

Your phone does not run the agent. It connects to the daemon in one of two ways. The first is the Paseo relay, which is optional, off by default, and end-to-end encrypted. The second is a direct address, such as one on your Tailscale network. There is no Paseo account. Paseo Desktop and the CLI can also tunnel over SSH, but that only reaches a Paseo daemon. It is not a general SSH client.

For past sessions, its changelog lists an Import session screen.

## What Waycar adds to Paseo

In Waycar the agent runs on your machine in herdr or tmux, not in the app. Waycar can start an agent on a fresh git worktree, and it opens agents that already run there.

- **Your own sessions, as they are.** You start an agent in tmux or herdr, from your desk or from Waycar, and Waycar opens it from your phone. We did not find attaching to a live tmux pane in Paseo's docs. Waycar's agent terminals need herdr 0.7.5 or later, tmux 3.2 or later, or herdr-core 0.1.10 or later on that machine.
- **mosh with an SSH fallback.** The terminal keeps going while the app is open and catches up after dead zones. We did not find mosh in Paseo's docs. The terminal ends about 20 seconds after you leave the app and re-attaches on its own when you return.
- **A Console sorted by who needs you.** Agents from all your machines show as Blocked, Done, Working or Idle, and a Live Activity can keep a machine on your Lock Screen. We did not find a Live Activity in Paseo's docs.
- **No account, and no Waycar server in the path of your sessions.** Waycar has an optional push relay. Your machine encrypts each notification first, so the relay cannot read what it says. For Live Activities it does see how many agents are in each status.

## Where Paseo is better

- **Every platform.** Paseo has desktop apps, a web app, a CLI and an Android app. Waycar is an iPhone and iPad app with no native desktop or web client.
- **More agents.** Paseo has native adapters for several agents and a catalog of agents that use the Agent Client Protocol. Waycar launches 23 agents, and Chat Mode covers 14.
- **Managed workspaces.** Paseo runs many agents at once and can give each its own git worktree. It also shows subscription quota windows. Waycar can start an agent in a Workspace or on a fresh git worktree. Its usage view is partial.
- **Older phones.** The Paseo iOS app needs iOS 15.1 or later. Waycar needs iOS 18 or later.
- **Voice mode.** Paseo has dictation and a voice mode for talking with your agents. Waycar's dictation needs iOS 26 or later.

## What each costs

Paseo is free, including the apps, the daemon and the CLI. The official relay is optional and has no listed price, and its terms say it is subject to reasonable and fair use. Paseo Hub is a separate, optional service for GitHub, Slack and Discord triggers, and you do not need it for phone access. You can self-host Hub for $0. Hosted Hub has a $0 plan with 50 agent runs a month and one seat, and a Pro plan at $15 per seat per month.

Waycar is free.

## Can you use both?

Yes. Run Paseo where you want a managed workspace on its apps, and keep tmux or herdr for agents you start by hand. Waycar opens the second group from your iPhone. See [tmux on iPhone](/solutions/tmux-on-iphone) for that setup.
