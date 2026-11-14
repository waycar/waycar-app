---
title: What is Waycar?
description: Waycar is a native iPhone and iPad app for checking on and talking to the coding agents you run in herdr or tmux on your own machines.
category: get-started
order: 10
keywords: [overview, about, iphone, ipad, coding agents, herdr, ssh]
related: [requirements, install, pairing, console]
---

Waycar is a native iPhone and iPad app for checking on your coding agents in herdr or tmux. It connects straight to your own machine over SSH, shows every agent sorted by who needs you, and opens the agent's real terminal over mosh so it stays attached when your network changes. There is no account to make.

## What can you do with it?

- **See every agent at once.** The [Console](/help/console) lists agents from all your Hosts by status: Blocked, then Done, Working, Idle. Blocked agents come first, after any you've pinned.
- **Open the live terminal.** You see exactly what the agent draws, not a copy. See [The live terminal](/help/terminal).
- **Answer and start agents.** Draft a prompt in the [Composer](/help/composer) and send it once, or [start a new agent](/help/new-agent), on a fresh worktree if you like.
- **Talk instead of watch.** [Chat Mode](/help/chat-mode) shows Claude Code, Codex, Gemini CLI, opencode and ten more agents as a simple chat.
- **Get told when it matters.** A push arrives when an agent is Blocked or Done. See [Notifications](/help/notifications).

Waycar watches claude, codex, omp, gemini, opencode, pi and more. See [Supported agents](/help/supported-agents).

## How does it connect?

Waycar talks to herdr or tmux over a plain SSH connection to your computer. There is no cloud service in between, and SSH needs no extra port. Agent terminals run over mosh when your Host has `mosh-server` and UDP can reach it, and Waycar falls back to SSH when mosh can't get through. A [Jump Host](/help/jump-host) gets you to machines that aren't on the open internet.

Your SSH key is made on your iPhone or iPad, and the private half never leaves the Keychain.

## What is a Host?

A Host is a Mac or Linux machine you reach over SSH that runs herdr or tmux. You add each Host once, usually by running one install command on it and scanning its [Pairing Code](/help/pairing).

## How do I start?

1. Check the [requirements](/help/requirements).
2. [Install Waycar on your Host](/help/install).
3. [Pair with a Pairing Code](/help/pairing), or [add the Host by hand](/help/add-host-manually).

## Good to know

- Waycar is free.
- Waycar is an independent app from OTREVA, LLC. It is not affiliated with herdr, CodexBar, Anthropic, OpenAI, or Google. Learn about herdr at [herdr.dev](https://herdr.dev).
- Stuck? See [Get help and contact support](/help/get-help), or open **Settings** › **Support** in the app to email support or join r/waycar.
