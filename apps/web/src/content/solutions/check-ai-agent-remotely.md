---
title: Check on your AI coding agent remotely
metaTitle: "Check on an AI coding agent remotely"
description: "See which coding agents are working, blocked or done from your phone, get a push when one needs you, and answer it. For agents in tmux or herdr on your machine."
query: check ai agent remotely
summary: See every coding agent's status from your phone, get a push when one is Blocked or Done, and answer it, without going back to your desk.
answer: Install Waycar's host tools on the machine where your coding agents run, then pair your iPhone. The Console lists every agent by status. You get a push when one is Blocked or Done, and you can answer from the phone. The machine must be on and awake.
needs:
  - "An iPhone or iPad on iOS or iPadOS 18 or later."
  - "A Mac or Linux machine that is on, awake and reachable over SSH. On a Mac, turn on Remote Login."
  - "Your coding agents running in tmux 3.2+, herdr 0.7.5+ or herdr-core 0.1.10+. herdr also needs AllowTcpForwarding set to local or yes."
  - "`curl` and `tar` on that machine, for the install command that sets up the Waycar host tools. No Node needed."
  - "Notifications allowed for Waycar in iOS, and turned on for the machine in the app, to get a push when an agent needs you."
order: 4
updated: 2026-11-12
keywords: [check ai agent remotely, monitor coding agent from phone, ai agent notifications, unblock coding agent from phone, claude code notifications iphone, coding agent status iphone]
faq:
  - q: How do I know when my coding agent is done or stuck?
    a: Waycar sends a push when an agent is Blocked and waiting for you, or Done. Your machine holds each change for about 5 seconds first, so a quick flip does not buzz your phone. A Live Activity can also keep a machine on your Lock Screen.
  - q: Can I check agents on more than one machine?
    a: Yes. The Console lists agents from all your machines, sorted by status, with Blocked first after any you pinned. You can filter by machine, search by folder or title, and pin the ones you care about.
  - q: Does Waycar see my code or terminal output?
    a: Not on Waycar's servers. Your SSH credentials and terminal data never touch them. Your phone connects straight to your machine over mosh or SSH. Your machine encrypts notifications first, so Waycar's push relay cannot read what they say. For Live Activities it does see how many agents are in each status. AI Summaries are off until you turn them on. Then your machine sends up to the last 60 lines of an agent's screen to an AI provider you already use, such as Anthropic, OpenAI or OpenRouter. That text does not pass through Waycar.
  - q: What if my machine is not reachable from the internet?
    a: Put an SSH Jump Host in front of it, such as a small server that can reach your machine. Waycar checks host keys at both hops. mosh's UDP does not go through a Jump Host. Waycar sends it straight to your machine's address, so if your phone cannot reach that over UDP, the session runs over SSH.
  - q: Does it work if my computer is off?
    a: No. The agents run on your own machine and Waycar keeps no cloud copy. The machine has to be on, awake and reachable. If you need agents that run with your computer off, Waycar is not the right tool.
compare: [shellfish, claude-code-remote-control, happy]
help: [notifications, console, live-activities, agent-status]
---

## What "remotely" means here

Your coding agents run on a Mac or Linux machine, in tmux or herdr, not in the Waycar app, and Waycar keeps no running copy. Waycar reaches the machine, so you can start agents, look at them, hear from them and answer them while you are somewhere else.

Your phone connects straight to the machine over mosh, with SSH as the fallback. There is no Waycar account. Waycar has an optional push relay. Your machine encrypts each notification first, so the relay cannot read what it says. For Live Activities it does see how many agents are in each status.

## See every agent at a glance

The Console lists agents from all your machines by status: Blocked, then Done, Working, Idle. Agents you pin stay above that order. Filter by machine, search by folder or title, or long-press to pin an agent. Open one to see its real terminal, exactly as it draws it.

With AI Summaries on, Agent Progress estimates how far along an agent is from its plan steps or work phase.

## Hear about it when it matters

- **Push alerts.** You get a notification when an agent is Blocked or Done, even with Waycar closed. The title names the workspace and the agent, such as "my-app · Claude". The body says Blocked or Done. If you turn on AI Summaries, it adds a one-line summary. For a Chat Mode agent on herdr, a Done notification shows the agent's reply.
- **A short wait.** Your machine holds a change for about 5 seconds, then checks again. If the agent has already moved on, nothing is sent. The same status is not repeated until the agent has been in another one.
- **A badge.** The Waycar icon counts the agents that need you, across all your machines.
- **Lock Screen.** A Live Activity can keep a machine on your Lock Screen and in the Dynamic Island.
- **Apple Watch.** The watch app shows agent status and replies through a nearby paired iPhone.
- **CarPlay.** On an iPhone with iOS 26.4 or later, hear what needs you, ask an agent out loud and hear its answer in a sentence or two. Nothing an agent writes is shown on the car's screen. See [CarPlay](/help/carplay).

## Answer it from the phone

- **Chat Mode.** Start one of 14 supported agents in Waycar with Chat Mode on, and it opens as a chat. When one asks for permission, tap Allow or Cancel.
- **The terminal.** For any other agent, or one that was already running, open the real terminal and type with the toolbar keys, or write a prompt in the Composer and send it once.
- **Files and photos.** Attach up to 10 per message. Files can be up to 64 MiB each. Photos are resized to fit 16 MiB. Dictation runs on your phone on iOS 26 or later.
- **Queued messages.** Messages sent while the Host is disconnected wait on your phone and go out when it reconnects.

## What Waycar cannot do

- It cannot run agents when your machine is off or asleep. Keep it on and awake.
- Its agent terminals need tmux, herdr or herdr-core. On tmux, [Status Hooks for 17 agents](/help/tmux-hooks) provide status and alerts. Other agents show Unknown.
- It is an iPhone and iPad app with no native desktop or web client. An Android app is coming soon.
- The terminal session ends about 20 seconds after you leave the app and re-attaches on its own when you return. The agent keeps running.

## Set it up

Run this on the machine, then scan the pairing QR code in Waycar:

```sh
curl -fsSL https://waycar.dev/install.sh | sh
```

## Other ways to check on an agent

Some tools run the agent in a server, daemon or desktop app that you set up, and show it on your phone. Some SSH clients, such as [Secure ShellFish](/compare/shellfish), add alerts for agents you run in a terminal. Others are built into one agent. They fit different setups. See how [Claude Code Remote Control](/compare/claude-code-remote-control), [Happy](/compare/happy) and [T3 Code](/compare/t3-code) differ from Waycar, with sources, or see [all comparisons](/compare). If your agent is Claude Code, see [run Claude Code from your iPhone](/solutions/run-claude-code-from-iphone).
