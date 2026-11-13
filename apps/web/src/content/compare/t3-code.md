---
title: Waycar vs T3 Code
metaTitle: "Waycar vs T3 Code: remote coding agents on iPhone"
description: "T3 Code is an open source server with desktop, web and phone apps for coding agents. Waycar is an iPhone app for agents in tmux or herdr."
name: T3 Code
kind: agent-environment
summary: T3 Code is open source, with a server and desktop, web, iOS and Android apps for coding agents. Waycar is an iPhone and iPad console for coding agents in tmux or herdr.
checked: 2026-10-18
order: 7
keywords: [t3 code alternative, t3 code vs waycar, t3 code iphone, t3 connect, claude code iphone, remote coding agent app, check ai agent remotely]
rows:
  runs-where: { level: info, text: "Your own machine, on a T3 server you run" }
  account: { level: info, text: "None for direct pairing. T3 account for T3 Connect" }
  path: { level: info, text: "Direct (LAN, Tailscale, URL) or the T3 Connect tunnel" }
  mosh: { level: unknown, text: "Not documented" }
  persistent: { level: yes, text: "Yes. The T3 server on your machine keeps running" }
  host-setup: { level: info, text: "T3 server (t3 CLI or desktop app) plus agent CLIs" }
  agents: { level: info, text: "Codex, Claude, Cursor, Grok Build, OpenCode, Pi, more" }
  status: { level: yes, text: "Yes, per thread: working, waiting, limited, failed" }
  push: { level: yes, text: "Yes, but background push needs a T3 Connect account" }
  approve: { level: yes, text: "Yes, approve or reject in the thread" }
  chat: { level: yes, text: "Yes, a thread conversation view" }
  terminal: { level: yes, text: "Yes, a terminal on the T3 host" }
  live-activity: { level: yes, text: "Yes, Live Activities on iOS" }
  attach: { level: yes, text: "Yes, up to 100 files per message" }
  voice: { level: yes, text: "Yes, on-device, iPhone with iOS 26 or later" }
  usage: { level: yes, text: "Yes: phone has limits. Tokens and cost on desktop, web" }
  resume: { level: partial, text: "Partial: resumes after a restart. Quit agent: not documented" }
  ios: { level: yes, text: "Yes, iPhone and iPad, iOS 18 or later" }
  android: { level: yes, text: "Yes, on Google Play" }
  desktop: { level: yes, text: "Yes: macOS, Windows, Linux apps and a web app" }
  source: { level: info, text: "Open source, MIT license" }
  price: { level: info, text: "Free. T3 Connect caps linked environments" }
  general-ssh: { level: no, text: "No. The phone app connects to T3 servers only" }
pickWaycar:
  - Your agents already run in tmux or herdr, and you want to attach to those sessions, not start new ones in a server.
  - You want mosh or SSH straight from your phone to your machine, with no T3 server and no account.
  - You want a push when an agent is Blocked or Done without signing in to anything.
  - You want one Console of agents from all your machines, sorted by who needs you.
pickThem:
  - You want open source under the MIT license, with desktop, server and mobile code in one repository.
  - "You want one interface for many agents: Codex, Claude, Cursor, Grok Build, OpenCode, Pi and more."
  - You want the same tool on desktop, web, iPhone and Android.
  - You want subscription limits and a usage widget on the phone, plus tokens and cost on desktop and web.
faq:
  - q: Is there a T3 Code alternative that attaches to tmux?
    a: Waycar opens your herdr or tmux sessions over mosh or SSH, and can start agents in them. Nothing of ours runs as a server on your machine, other than small host tools. We did not find attaching to an existing tmux session in the T3 Code docs. T3 Code runs agents in its own server.
  - q: Do I need an account to use T3 Code on my phone?
    a: Not for direct pairing. T3 Code's privacy policy says you may use local or direct connections without a T3 account. T3 Connect, the tunnel for reaching a machine without router forwarding, needs a T3 account. Push notifications in the background also need T3 Connect.
  - q: Does T3 Code support mosh?
    a: We did not find mosh in the T3 Code docs. It lists LAN, Tailscale, another VPN, a public URL, SSH and T3 Connect as routes to a machine. Waycar runs agent terminals over mosh and falls back to SSH on its own.
  - q: Can I use T3 Code on Android?
    a: Yes. T3 Code Mobile is on Google Play as well as the App Store. Waycar is an iPhone and iPad app with no native desktop or web client. An Android app is coming soon.
  - q: Is T3 Code free, and is Waycar?
    a: T3 Code is free and MIT licensed, and you pay your own agent providers. Waycar is free, with every feature included and unlimited launches.
sources:
  - { label: T3 Code, url: "https://t3.codes" }
  - { label: T3 Code repository and README, url: "https://github.com/pingdotgg/t3code" }
  - { label: "T3 Code docs: remote access", url: "https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md" }
  - { label: "T3 Code docs: mobile notifications", url: "https://github.com/pingdotgg/t3code/blob/main/docs/user/mobile-notifications.md" }
  - { label: "T3 Code docs: install", url: "https://github.com/pingdotgg/t3code/blob/main/docs/user/install.md" }
  - { label: "T3 Code docs: composer", url: "https://github.com/pingdotgg/t3code/blob/main/docs/user/composer.md" }
  - { label: "T3 Code docs: usage", url: "https://github.com/pingdotgg/t3code/blob/main/docs/user/usage.md" }
  - { label: "T3 Code docs: updating and resuming threads", url: "https://github.com/pingdotgg/t3code/blob/main/docs/user/updating.md" }
  - { label: "T3 Code docs: welcome wizard", url: "https://github.com/pingdotgg/t3code/blob/main/docs/user/welcome-wizard.md" }
  - { label: T3 Code v0.1.0 release notes, url: "https://github.com/pingdotgg/t3code/releases/tag/v0.1.0" }
  - { label: T3 Code privacy policy, url: "https://t3.codes/privacy-policy" }
  - { label: T3 Code Mobile on the App Store, url: "https://apps.apple.com/us/app/t3-code-remote-claude-more/id6787819824" }
related: [orca, paseo, happy, kittylitter]
solutions: [check-ai-agent-remotely, run-claude-code-from-iphone]
---

## What T3 Code is

T3 Code is an open source app for running and steering coding agents, made by T3 Tools, Inc. It has a server, a desktop app for macOS, Windows and Linux, a web app, and phone apps for iOS and Android. It works with Codex, Claude, Cursor, Grok Build, OpenCode, Antigravity, Pi and agents from the official ACP Registry (ACP is the Agent Client Protocol). The code is MIT licensed.

The phone app is a companion for your T3 environments. Per its App Store listing, you can start agent runs, browse files, review diffs, take version control actions and use a terminal.

Its README says the project is very early and to expect bugs. Desktop and server are at v0.1.0, the first stable release of its V2 line, and the App Store lists the mobile app at 2.0.0. T3 Code does not resell tokens, so you pay your own agent providers.

## Where the agent runs and how your phone reaches it

The agent runs on your machine, under a T3 server. You install the server with the `t3` command or the desktop app, and sign in to your agent CLIs there first. The phone then connects to that server. It does not connect to a plain shell.

There are two ways in from the phone. With direct pairing, the phone reaches the machine over a LAN, Tailscale or a URL. That needs no T3 account. With T3 Connect, you sign in to a T3 account on both devices, and it reaches the machine without router forwarding. T3 says it uses Cloudflare for this networking. Background push notifications need T3 Connect. A direct or Tailscale connection alone does not deliver them.

The desktop app can also reach a remote Linux or Apple Silicon Mac over SSH and start a T3 server there. That is documented for the desktop app, not the phone.

Waycar works differently. Nothing of ours runs as a server on your machine, other than small host tools. The agent keeps running in herdr (0.7.5 or newer) or tmux (3.2 or newer), and the phone attaches over mosh or SSH. We did not find attaching to an existing tmux session in the T3 Code docs. T3 Code can import recent Claude Code and Codex conversations and continue them, but we did not find a way to take over a process still running in tmux.

## What Waycar adds to T3 Code

- **Your sessions, not a new server.** Waycar opens your herdr or tmux sessions and starts new agents in them. Mosh keeps going while the app is open and catches up after dead zones. There is no account, and no Waycar server in the path of your sessions. Waycar has an optional push relay. Your machine encrypts each notification first, so the relay cannot read what it says. For Live Activities it does see how many agents are in each status.
- **One list, sorted by who needs you.** The Console shows agents from all your machines as Blocked, Done, Working or Idle.
- **Chat Mode for 14 agents.** Start a supported agent in Waycar with Chat Mode on, and it opens as a chat, with Allow and Cancel for permission requests.
- **Closed Sessions.** An agent you quit by mistake can come back, for 30 days.

## Where T3 Code is better

- **Many agents in one place.** T3 Code lists Codex, Claude, Cursor, Grok Build, OpenCode, Antigravity and Pi, plus agents from its Agent Client Protocol (ACP) registry.
- **Every platform.** It has desktop, web, iOS and Android. Waycar is an iPhone and iPad app with no native desktop or web client. An Android app is coming soon.
- **More in the phone app.** It has push, Live Activities, on-device voice (iOS 26 or later), attachments, a terminal, subscription limits and home screen widgets, plus file browsing and diff review.
- **Usage in full.** Its Usage page on desktop and web covers tokens, cost and limits across several agents. Waycar shows plan limits through CodexBar. For Claude on a Mac, its Fix AI Usage flow sets up a helper on your Mac so those limits can be read too.

## What each costs

T3 Code is free, and no paid tier is documented. T3 Connect limits how many environments you can link (its docs name the error but not the number), and we did not find T3 Connect pricing. The App Store lists the app as Free.

Waycar is free, with every feature included and unlimited agent and shell launches. No account or subscription.

## Can you use both?

Yes. They do not share a server or a session, so they do not clash. Use T3 Code for its server, its desktop app or Android. Use Waycar for the herdr or tmux sessions you already run. See [how to check an agent remotely](/solutions/check-ai-agent-remotely).
