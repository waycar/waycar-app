---
title: Waycar vs Secure ShellFish
metaTitle: "Waycar vs Secure ShellFish: SSH client for agents"
description: "Secure ShellFish is an SSH and SFTP client with Files app, tmux and agent hooks. Waycar is built for coding agents in tmux or herdr: status, push, chat and mosh."
name: Secure ShellFish
kind: ssh-client
summary: Secure ShellFish is an SSH and SFTP client for Apple devices with Files app, tmux and agent notification hooks. Waycar is an agent console for coding agents in tmux or herdr.
checked: 2026-10-18
order: 3
keywords: [secure shellfish alternative, secure shellfish vs waycar, secure shellfish mosh, secure shellfish claude code, ssh client for coding agents, tmux on iphone, claude code iphone]
rows:
  runs-where: { level: info, text: "Your own server or Mac, reached over SSH" }
  account: { level: info, text: "No account documented. iCloud Keychain syncs servers" }
  path: { level: info, text: "Direct SSH. Alerts and widgets relay via maker and Apple" }
  mosh: { level: unknown, text: "Not documented" }
  persistent: { level: yes, text: "Yes, with tmux turned on per server" }
  host-setup: { level: info, text: "SSH server. Optional Shell Integration and tmux" }
  agents: { level: info, text: "Claude Code, Codex CLI, OpenCode hooks; any CLI runs" }
  status: { level: unknown, text: "Not documented" }
  push: { level: yes, text: "Yes, alerts from Claude Code, Codex CLI, OpenCode hooks" }
  approve: { level: partial, text: "Partial: alert, then answer in the terminal" }
  chat: { level: unknown, text: "Not documented" }
  terminal: { level: yes, text: "Yes, a native SSH terminal" }
  live-activity: { level: yes, text: "Yes (Pro), follows active terminal, incl. agent questions" }
  attach: { level: yes, text: "Yes, paste uploads the file and can insert its path" }
  voice: { level: yes, text: "Yes, long-tap Paste to dictate prompts" }
  usage: { level: unknown, text: "Not documented" }
  resume: { level: partial, text: "Partial: pick tmux sessions. Agent resume not documented" }
  ios: { level: yes, text: "Yes, iPhone and iPad, iOS 17.4 or later" }
  android: { level: unknown, text: "Not documented. Only Apple platforms are listed" }
  desktop: { level: yes, text: "Yes, a Mac app. No web client documented" }
  source: { level: info, text: "No public source repo found" }
  price: { level: info, text: "Free with ads. Pro $2.99/mo, $14.99/yr or $29.99 (US)" }
  general-ssh: { level: yes, text: "Yes: SSH, SFTP, Files app, jump hosts" }
pickWaycar:
  - Your phone time goes to coding agents that run in tmux or herdr on your own machine.
  - You want one list of agents sorted by who needs you, and a push when one is Blocked or Done.
  - You want Chat Mode for 14 agents you start in Waycar, with Allow and Cancel for permission requests.
  - You want mosh, with SSH as the fallback, and no account.
pickThem:
  - You want a general SSH and SFTP client, and agents are one use among many.
  - You want your server's folders in the Files app and in Finder, with other apps editing files in place.
  - You want widgets, Shortcuts actions and a Mac app next to the iPhone app.
faq:
  - q: Does Secure ShellFish support mosh?
    a: We found no mention of mosh anywhere on its site, including the help pages and the privacy page, so we do not claim either way. Waycar runs agent terminals over mosh and falls back to SSH on its own. It needs mosh-server on your machine, and mosh has no predictive local echo in Waycar.
  - q: Does Secure ShellFish work with Claude Code?
    a: Yes. You can run claude in its terminal like any command. Its help pages also describe notification hooks for Claude Code, Codex CLI and OpenCode. You install them from Shell Integration, and the agent then alerts you when it needs input or finishes a task.
  - q: Can Secure ShellFish notify me when Claude Code or Codex finishes?
    a: Yes, after you install the hooks from Shell Integration on the server. Pro users can also turn on a Live Activity for questions from the agent. Waycar sends a push when an agent is Blocked or Done, and it adds a Console and Chat Mode.
  - q: Is Secure ShellFish a subscription or a one-time purchase?
    a: Both. The US App Store lists a Monthly subscription at $2.99, an Annual subscription at $14.99 and a Lifetime Pro Unlock at $29.99. The free version shows ads at the bottom of the terminal. Waycar is free, with every feature included and unlimited launches.
  - q: Does Secure ShellFish keep a session alive on iPhone?
    a: It has built-in tmux support, turned on per server. A Location Persistence setting keeps the SSH connection running in the background. It uses location access, which stays on the device. Waycar keeps its terminal for about 20 seconds after you leave, then re-attaches on its own while the agent keeps running in herdr or tmux.
sources:
  - { label: Secure ShellFish home page, url: "https://secureshellfish.app/" }
  - { label: "Secure ShellFish help: agentic coding", url: "https://secureshellfish.app/help/agentic-coding" }
  - { label: "Secure ShellFish help: tmux", url: "https://secureshellfish.app/help/tmux" }
  - { label: "Secure ShellFish help: Files app and Finder", url: "https://secureshellfish.app/help/files-app" }
  - { label: "Secure ShellFish help: terminal", url: "https://secureshellfish.app/help/terminal" }
  - { label: "Secure ShellFish help: widgets", url: "https://secureshellfish.app/help/widgets" }
  - { label: Secure ShellFish privacy policy, url: "https://secureshellfish.app/privacy.html" }
  - { label: "Secure ShellFish on the App Store (listing and version history)", url: "https://apps.apple.com/us/app/ssh-client-secure-shellfish/id1336634154" }
  - { label: "Secure ShellFish help: adding servers", url: "https://secureshellfish.app/help/add-server" }
  - { label: "Secure ShellFish help: Shortcuts", url: "https://secureshellfish.app/help/shortcuts-automation" }
  - { label: "Secure ShellFish help: offline folders", url: "https://secureshellfish.app/help/offline-folders" }
related: [termius, blink-shell, claude-code-remote-control]
solutions: [tmux-on-iphone, check-ai-agent-remotely]
---

## What Secure ShellFish is

Secure ShellFish is an SSH and SFTP client for iPhone, iPad, Mac and Apple Vision, with a watch app too. One developer makes it. It works with any OpenSSH-compatible server. You open shell sessions from your phone, and your server's folders show up in the Files app and in Finder.

It also has help for coding agents. Its help pages describe notification hooks for Claude Code, Codex CLI and OpenCode. A Live Activity can show questions from the agent, on Pro. It is free to download with ads, and Pro is a subscription or a one-time unlock.

## How it reaches your agent

Your phone connects straight to your server over SSH. The agent runs on that server, not on the phone. We did not find a Secure ShellFish account in its docs. Your servers sync between your devices through iCloud Keychain.

Two features use the maker's server. The notify and widget commands send a payload through it and through Apple push. Its privacy page says that payload is encrypted with a key known only to the command and your app.

On the machine, SSH is enough to open a terminal. Shell Integration is an optional install. It adds the agent hooks and the widget command. tmux is optional and is turned on per server.

We found no mention of mosh in its docs, so we make no claim about it.

## What Waycar adds to Secure ShellFish

Waycar is not a general SSH client. It is a console for coding agents that run in tmux or herdr on your own machines. Secure ShellFish also sends alerts and has a Live Activity, so the gap is not there. The real differences:

- **One list, sorted by who needs you.** The Console shows agents from all your machines as Blocked, Done, Working or Idle. We did not find an agent status list in Secure ShellFish's docs.
- **Chat Mode for 14 agents.** Start a supported agent in Waycar with Chat Mode on, and it opens as a chat. When one asks for permission, you tap Allow or Cancel. We did not find a chat view or approve buttons in Secure ShellFish's docs. Its docs do not say how you answer; the terminal is the way we know of.
- **mosh, with SSH as the fallback.** Waycar's mosh keeps going while the app is open and catches up after dead zones. We found no mention of mosh in Secure ShellFish's docs.
- **Closed Sessions.** Bring back an agent you quit by mistake, for 30 days. We did not find the same in Secure ShellFish's docs.

Waycar has no account. Your sessions go straight from your phone to your machine over mosh or SSH, with no Waycar server in the path of your sessions. Waycar has an optional push relay. Your machine encrypts each notification first, so the relay cannot read what it says. For Live Activities it does see how many agents are in each status.

## Where Secure ShellFish is better

Secure ShellFish wins on these:

- **Any server.** It opens any SSH or SFTP server. Waycar's agent terminals need herdr, tmux or herdr-core; it cannot open an arbitrary SSH server.
- **Files.** Server folders appear in the Files app and in Finder, and other apps can edit files in place. Waycar has no SFTP file browser and no port forwarding. It uses SFTP to upload the files you attach and to preview files an agent mentions.
- **A Mac app and more.** It runs on Mac, Apple Vision and a watch, and its widgets can be driven from any server with one shell command. Waycar has no desktop or web client.
- **tmux built in.** It has a session picker with thumbnails, and Handoff of a tmux session between your Apple devices.
- **Automation.** Shortcuts actions include Run Command, Upload and Download.

On the rows we share, it matches Waycar: full terminal, alerts, Live Activity, voice input and pasted files.

## What each costs

Secure ShellFish is free to download, and the free version shows ads at the bottom of the terminal. Pro features such as upload through the Files app, unlimited servers, offline folders and Live Activity need Pro. On the US App Store listing (checked 2026-10-18) Pro is $2.99 a month, $14.99 a year or $29.99 once. The one-time unlock covers iPhone, iPad and Mac.

Waycar is free, with every feature included and unlimited agent and shell launches. No account or subscription.

## Can you use both?

Yes. Keep Secure ShellFish for files, widgets and general servers. Use Waycar for the agents on your machine. Both can open SSH sessions to the same machine, and tmux is the common ground (see [tmux on iPhone](/solutions/tmux-on-iphone) and [checking an agent remotely](/solutions/check-ai-agent-remotely)).
