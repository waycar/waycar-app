---
title: Waycar vs Kittylitter
metaTitle: "Waycar vs Kittylitter: Codex and Claude on iPhone"
description: "Kittylitter is a free, open source phone client for Codex and other agents. Waycar is an iPhone console for agents in tmux or herdr."
name: Kittylitter
kind: agent-client
summary: Kittylitter is a free, open source iOS and Android client for Codex, Claude, OpenCode, Pi and Droid. Waycar is an iPhone and iPad console for agents in tmux or herdr.
checked: 2026-10-18
order: 6
keywords: [kittylitter alternative, kittylitter vs waycar, litter app codex ios, codex client for iphone, claude code iphone, ai coding agent phone client]
rows:
  runs-where: { level: info, text: "Your machine, or Codex on the phone itself" }
  account: { level: info, text: "No Kittylitter account" }
  path: { level: info, text: "Local network, SSH, or its Alleycat peer to peer link" }
  mosh: { level: unknown, text: "Not documented" }
  persistent: { level: partial, text: "Partial: Alleycat keeps the agent 10 min, per its code" }
  host-setup: { level: info, text: "SSH server plus agent CLI, or the kittylitter daemon" }
  agents: { level: info, text: "Codex, Claude, OpenCode, Pi, Droid, and more" }
  status: { level: partial, text: "Partial: sessions list shows working state (its code)" }
  push: { level: partial, text: "Partial: Turn completed alert via relay (its code)" }
  approve: { level: yes, text: "Yes, approval overlay for Codex (per its code)" }
  chat: { level: yes, text: "Yes, a chat view of the conversation" }
  terminal: { level: partial, text: "Partial: Ghostty terminal, off by default (its code)" }
  live-activity: { level: yes, text: "Yes, Live Activity for a turn (per its code)" }
  attach: { level: yes, text: "Yes, up to 4 images per message; files per its code" }
  voice: { level: yes, text: "Yes, real-time voice (App Store says OpenAI)" }
  carplay: { level: unknown, text: "Not documented" }
  usage: { level: partial, text: "Partial: Codex rate limits and context % (its code)" }
  resume: { level: yes, text: "Yes, resume threads" }
  ios: { level: yes, text: "Yes, iPhone and iPad, iOS 18.0 or later" }
  android: { level: yes, text: "Yes, on Google Play (README labels it Beta)" }
  desktop: { level: no, text: "No native app or web client found. iPad app on Macs" }
  source: { level: info, text: "Open source: GPL-3.0 plus a store permission" }
  price: { level: info, text: "Free. Optional tips $9.99 to $99.99" }
  general-ssh: { level: partial, text: "Partial: SSH to a machine for agents and a terminal" }
pickWaycar:
  - You run agents in tmux or herdr on your own Mac or Linux machine, and want them kept running when your phone drops off.
  - You want mosh with an SSH fallback, so the terminal catches up after a dead zone.
  - You want one Console of agents from all your machines, with Blocked agents first.
  - You want a push when an agent is Blocked as well as Done, and Chat Mode for 14 agents.
pickThem:
  - You want to run Codex on the phone itself, with no machine involved.
  - You want to reach your machine over a peer to peer link, with no VPN, public IP or port forwarding.
  - You use Android, or run your agents on a Windows machine.
  - You want real-time voice with the agent.
faq:
  - q: Does Kittylitter support mosh?
    a: We did not find mosh in its site, store listings, README, docs or release notes. It connects over your local network, SSH or Alleycat, its own peer to peer link. Waycar runs agent terminals over mosh with an SSH fallback, for free.
  - q: Is Kittylitter free and open source?
    a: Yes. The app is free to download, and its site says it is open source and always free. The license is GPL-3.0 with an added permission for App Store and Google Play distribution. In-app purchases on iOS are optional tips.
  - q: Does Kittylitter work with Claude Code?
    a: It lists Claude among its agents, with Codex, OpenCode, Pi and Droid. Its release notes label Claude Code support beta, and we did not see a later note that removes the label. By default its Alleycat daemon starts Claude with permissions bypassed, so Claude asks nothing until that is changed. The app has a permission picker for Claude.
  - q: Does Kittylitter run Codex on the phone?
    a: Its architecture notes say so. iOS embeds a small Linux environment (Alpine), and Android embeds one too. Waycar does not do this. Nothing runs on your phone in Waycar. The agent runs on your own machine.
  - q: Does Kittylitter send a push when an agent finishes?
    a: Yes, for a finished turn, per its source code. A push relay wakes the app, which posts a Turn completed notification when the app is not open. We found no alert for a blocked agent. Waycar sends a push when an agent is Blocked or Done, encrypted on your machine first.
sources:
  - { label: Kittylitter site, url: "https://kittylitter.app/" }
  - { label: Kittylitter support, url: "https://kittylitter.app/support" }
  - { label: Kittylitter privacy policy, url: "https://kittylitter.app/privacy" }
  - { label: Kittylitter on the App Store, url: "https://apps.apple.com/us/app/kittylitter/id6759521788" }
  - { label: Litter on Google Play, url: "https://play.google.com/store/apps/details?id=com.sigkitten.litter.android" }
  - { label: Litter repository and README on GitHub, url: "https://github.com/0xSero/litter" }
  - { label: Litter architecture notes, url: "https://github.com/0xSero/litter/blob/main/docs/ARCHITECTURE.md" }
  - { label: Alleycat README, url: "https://github.com/dnakov/alleycat/blob/main/README.md" }
  - { label: "Source: Alleycat sessions outlive a client", url: "https://github.com/dnakov/alleycat/blob/main/crates/bridge-core/src/session/mod.rs" }
  - { label: "Source: app lifecycle and Turn completed alert", url: "https://github.com/0xSero/litter/blob/main/apps/ios/Sources/Litter/Models/AppLifecycleController.swift" }
  - { label: "Source: rate limit and context badges", url: "https://github.com/0xSero/litter/blob/main/apps/ios/Sources/Litter/Views/ConversationComposerContextBarView.swift" }
  - { label: "Source: Experimental Features (terminal off by default)", url: "https://github.com/0xSero/litter/blob/main/apps/ios/Sources/Litter/Models/ExperimentalFeatures.swift" }
related: [happy, paseo, t3-code, orca]
solutions: [run-claude-code-from-iphone, check-ai-agent-remotely]
---

## What Kittylitter is

Kittylitter is a phone client for coding agents. It runs on iPhone and iPad, and on Android through Google Play. Its site names Codex, Claude, OpenCode, Pi and Droid, and the app and its Alleycat link list a few more. Its App Store text leads with Codex. It has a chat view, real-time voice, a Live Activity for a running turn, and an embedded terminal that you switch on in Experimental Features.

The name is mixed across its sources. The domain and the App Store say Kittylitter. Its own app copy, the Play listing and the repository say Litter. The sources also name the maker in different ways, so we do not name one. This page says Kittylitter.

It is free and open source. The code is GPL-3.0 with an added permission for App Store and Google Play distribution.

## Where the agent runs

Kittylitter has two modes, and this is its main difference from Waycar.

In the first, the agent runs on a machine of yours. The app connects over your local network, over SSH, or over Alleycat, a peer to peer link. The machine needs an SSH server and the agent CLI, or the kittylitter daemon, which runs on macOS, Windows and Linux. Its App Store release notes say connections go straight to your computer instead of through a relay after the first launch. The listing also mentions optional Alleycat relay pairing.

In the second, Codex runs on the phone itself. Its architecture notes say iOS embeds a small Linux environment (Alpine) and Android embeds one too. Nothing in Waycar works this way. In Waycar the agent always runs on your own machine, and nothing runs on the phone.

Kittylitter does not create accounts. Its privacy policy says a push relay exists if you turn on push notifications.

## What Waycar adds to Kittylitter

Waycar's agent terminals need herdr (0.7.5 or newer), tmux (3.2 or newer) or herdr-core (0.1.10 or newer) on your machine, and the machine must be on and awake. The agent lives in herdr or tmux, not in the app.

- **Agents kept running.** The terminal session ends about 20 seconds after you leave the app and re-attaches on its own when you return. The agent keeps running in herdr or tmux. Kittylitter's Alleycat link also keeps the agent after the phone drops, for 10 minutes by default, per its source code. We found nothing for its SSH mode.
- **One list, sorted by who needs you.** The Console shows agents from all your machines as Blocked, Done, Working or Idle. Kittylitter's session list shows a working state. We did not find a Blocked or Done grouping.
- **A push for Blocked as well as Done.** Waycar has an optional push relay. Your machine encrypts each notification first, so the relay cannot read what it says. For Live Activities it does see how many agents are in each status. Kittylitter pushes a Turn completed alert. We found no alert for a blocked agent.
- **mosh with SSH as the fallback.** mosh keeps going while the app is open and catches up after dead zones. It has no predictive local echo.

## Where Kittylitter is better

- **Codex on the phone.** Its architecture notes say Codex can run on the device itself, with no machine. Waycar cannot.
- **No VPN needed.** Pairing by QR code works through home routers and firewalls with no VPN, public IP or port forwarding, according to its site.
- **More platforms.** It is on Android (labelled Beta in the README), and its daemon runs on Windows. Waycar is an iPhone and iPad app with no native desktop or web client, and an Android app is coming soon. Both iPad apps can be installed on Apple silicon Macs.
- **Voice.** It has real-time voice with the agent. Its App Store listing says it uses OpenAI voice processing. Waycar has on-device dictation, which needs iOS 26 or later.
- **No herdr or tmux needed.** You do not need either on the machine.

## What each costs

Kittylitter is free. The site says it is always free, and we found no paid plan or subscription. The App Store lists optional in-app tips at $9.99, $24.99, $49.99 and $99.99.

Waycar is free.

## Can you use both?

Yes. Use Kittylitter when you want a free client, Android, or Codex on the phone. Use Waycar for agents in tmux or herdr that you want to watch and answer from your iPhone. See [Run Claude Code from iPhone](/solutions/run-claude-code-from-iphone).
