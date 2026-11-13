---
title: Waycar vs Orca
metaTitle: "Waycar vs Orca mobile app for coding agents"
description: "Orca runs coding agents in git worktrees on your desktop, with a phone app that controls it. Waycar steers agents in tmux or herdr."
name: Orca
kind: agent-environment
summary: Orca is a free, open source desktop app that runs agents in git worktrees, with a phone app that controls it. Waycar is an iPhone console for agents in tmux or herdr.
checked: 2026-10-18
order: 8
keywords: [orca mobile app, orca alternative, orca vs waycar, orca relay, orca companion app, claude code iphone, check ai agent remotely]
rows:
  runs-where: { level: info, text: "Your own machine, an SSH host or an Orca server" }
  account: { level: info, text: "None for LAN or Tailscale. Orca sign-in for Relay" }
  path: { level: info, text: "Relay, LAN or Tailscale. End-to-end encrypted per code" }
  mosh: { level: no, text: "No. The phone uses Orca's own pairing, not mosh" }
  persistent: { level: yes, text: "Yes, while the Orca desktop host stays on" }
  host-setup: { level: info, text: "Orca desktop app or orca serve running, plus agent CLIs" }
  agents: { level: info, text: "Any CLI agent in a terminal. Chat UI covers six" }
  status: { level: yes, text: "Yes: working, done, waiting on input" }
  push: { level: yes, text: "Yes, when an agent finishes, via the maker's gateway" }
  approve: { level: yes, text: "Yes, in Chat UI for six agents (experimental)" }
  chat: { level: yes, text: "Yes, Chat UI for six agents. Maker calls it experimental" }
  terminal: { level: yes, text: "Yes, a live mirror of the desktop terminal" }
  live-activity: { level: unknown, text: "Not documented. A feature request is open" }
  attach: { level: yes, text: "Yes, attach a photo or file to a reply" }
  voice: { level: yes, text: "Yes, microphone dictation" }
  carplay: { level: unknown, text: "Not documented" }
  usage: { level: yes, text: "Yes, usage, rate limits and reset countdowns" }
  resume: { level: partial, text: "Partial: phone can resume a chat in a new terminal tab" }
  ios: { level: yes, text: "Yes, iPhone and iPad, iOS 15.1 or later (App Store)" }
  android: { level: partial, text: "Partial: app file download, marked Pre-release" }
  desktop: { level: yes, text: "Yes: macOS, Windows and Linux desktop app" }
  source: { level: info, text: "Open source, MIT License" }
  price: { level: info, text: "Free and open source. Enterprise: email the maker" }
  general-ssh: { level: no, text: "No on phone. SSH worktrees are in the desktop app" }
pickWaycar:
  - You already run agents in tmux or herdr on a Mac or Linux machine and want to watch and steer them from an iPhone.
  - You want one list of agents sorted by who needs you, and a push when one is Blocked or Done.
  - You want no account, and nothing between your phone and your machine for your sessions except mosh or SSH.
  - You want your machine to encrypt each push notification before it leaves.
pickThem:
  - You want a desktop app that gives each task its own git worktree, agent terminal and browser tab.
  - You want diff review and usage and rate-limit countdowns next to the agents.
  - You want an Android app today, even as a downloaded app file, or a phone app for the same desktop host.
  - You want open source under the MIT License, including the relay server code.
faq:
  - q: Does Orca have a mobile app?
    a: Yes. The Orca phone app is on the App Store for iPhone and iPad. Android is a downloaded app file (APK) that GitHub marks Pre-release. It is a remote control for an Orca desktop host that must be running, not a standalone client.
  - q: Do I need an Orca account to pair my phone?
    a: Not for LAN or Tailscale pairing, which still needs an address your phone can reach. Orca's docs say sign-in is required for Relay only, and they recommend Relay when it is available. A troubleshooting line on the same page mentions signing in to the same account, so check the current docs.
  - q: Is Orca Relay end-to-end encrypted?
    a: We did not find this on the docs site. The App Store listing says pairing is end-to-end encrypted, and the phone's relay source code wraps relay traffic in an encrypted session. Push notification text goes through the maker's push gateway, and encrypting push content is an open feature request filed by a contributor.
  - q: Can I approve Claude Code permission prompts from Orca on iPhone?
    a: Yes, in Chat UI. It covers Claude, Codex, Grok, OpenCode, OMP and Pi, and the maker calls it experimental. Waycar has Chat Mode for 14 agents, with Allow and Cancel for permission requests.
  - q: Does Orca work with my existing tmux sessions?
    a: Orca's docs do not describe attaching to an existing tmux session. You can run tmux inside an Orca terminal, and the phone mirrors that terminal. Orca's terminals belong to its own background daemon. Waycar is built for agents in tmux or herdr.
sources:
  - { label: Orca site, url: "https://www.onorca.dev" }
  - { label: "Orca docs: mobile", url: "https://www.onorca.dev/docs/mobile" }
  - { label: "Orca docs: Chat UI", url: "https://www.onorca.dev/docs/agents/native-chat" }
  - { label: Orca on the App Store, url: "https://apps.apple.com/us/app/orca-ide/id6766130217" }
  - { label: Orca Android APK release on GitHub, url: "https://github.com/stablyai/orca/releases/tag/mobile-android-v0.0.57" }
  - { label: Orca Relay and push gateway readme, url: "https://raw.githubusercontent.com/stablyai/orca/main/cloud/README.md" }
  - { label: Orca phone relay link source, url: "https://raw.githubusercontent.com/stablyai/orca/main/mobile/src/transport/mobile-relay-e2ee-link.ts" }
  - { label: "Orca v1.4.229 release notes", url: "https://github.com/stablyai/orca/releases/tag/v1.4.229" }
  - { label: "Orca issue: encrypt push notification content", url: "https://github.com/stablyai/orca/issues/25462" }
  - { label: Orca enterprise page, url: "https://www.onorca.dev/enterprise" }
  - { label: "Orca issue: Live Activity support", url: "https://github.com/stablyai/orca/issues/8127" }
  - { label: "Orca docs: Agents feed", url: "https://www.onorca.dev/docs/activity" }
related: [t3-code, paseo, happy, kittylitter]
solutions: [check-ai-agent-remotely, tmux-on-iphone]
---

## What Orca is

Orca is a desktop app for running coding agents side by side. It runs on macOS, Windows and Linux. Each task gets its own git worktree, its own agent terminal and its own browser tab. It works with Claude Code, Codex, OpenCode, Grok and other agent CLIs. Orca is open source under the MIT License. Its site names Stably, Inc. The iPhone app's App Store seller is Lovecast LLC.

Orca also has a phone app for iPhone and iPad, and an Android app file (APK). The phone app is a remote control for a desktop Orca host. It shows each worktree with its agent and a status: working, done or waiting on input. It can mirror the desktop terminal, and it has a Chat UI with approval cards.

## Where the agent runs and how your phone reaches it

The agent runs on your own machine, inside the Orca desktop app or a headless `orca serve` host. That host must be running and reachable. The docs say closing the desktop app drops a direct or LAN session until you reopen it. Nothing runs on the phone.

You pair the phone in one of three ways: over your LAN, over Tailscale, or through Orca Relay. LAN and Tailscale need no account but need an address the phone can reach. Relay needs an Orca sign-in. We did not find Relay encryption described on the docs site. The App Store listing says pairing is end-to-end encrypted, and the phone's relay source code wraps relay traffic in an encrypted session. We say only what those two show.

Push notifications go through the maker's push gateway, then Apple or Google. A contributor's open feature request in its repository asks to encrypt push content end to end. The maker's push README says it does not log notification titles or bodies.

Chat UI covers Claude, Codex, Grok, OpenCode, OMP and Pi. The maker calls it experimental. The terminal view is the default.

## What Waycar adds to Orca

In Waycar the agent runs on your machine in herdr or tmux, not in the app. Waycar can start an agent on a fresh git worktree, and it opens agents that already run there.

- **One list, sorted by who needs you.** The Console shows agents from all your machines as Blocked, Done, Working or Idle. Orca's desktop Agents feed groups agent threads by status. We did not find the same list on the phone.
- **Push that your machine encrypts first.** You get a notification when an agent is Blocked or Done. Waycar has an optional push relay. Your machine encrypts each notification first, so the relay cannot read what it says. For Live Activities it does see how many agents are in each status.
- **Agents in the tools you already use.** The agent keeps running in herdr or tmux when the phone drops off, with no Waycar desktop app to keep open. Closed Sessions bring back an agent you quit by mistake, for 30 days. Orca's v1.4.229 release notes describe a phone action that resumes a chat in a new terminal tab.
- **No account.** Sessions go from your phone to your machine over mosh or SSH, with no Waycar server in the path of your sessions.

## Where Orca is better

- **A full desktop environment.** Parallel git worktrees, a built-in browser and diff review are part of the app. Waycar is an iPhone and iPad app with no native desktop or web client.
- **Any CLI agent.** The maker says Orca works with any CLI agent.
- **Usage at a glance.** Orca shows usage, rate limits and reset countdowns, and can switch agent accounts, on desktop and on the phone.
- **Always-on hosts.** A background daemon keeps agents running when the Orca window closes. `orca serve` runs without the desktop window, and the desktop app can open SSH worktrees.
- **Android.** Orca has an Android app you download today. Waycar's Android app is coming soon.

## What each costs

Orca's desktop app is free, and the maker says you bring your own agent subscriptions. The iOS app lists as Free on the App Store. The Android download shows no price. Enterprise teams are asked to email the maker. We found no pricing page.

Waycar is free.

## Can you use both?

Yes, if your agents run in tmux or herdr on one machine and in Orca on another. Use Orca for worktrees and review at your desk, and Waycar for the tmux and herdr agents. Orca's phone app only reaches an Orca host, and Waycar's agent terminals need herdr, tmux or herdr-core on the machine.
