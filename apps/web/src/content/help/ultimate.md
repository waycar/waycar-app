---
title: Waycar with Ultimate
description: See the conversations of an Ultimate agent server running on your Host, check whether each one is working, and chat with them from your phone.
category: hosts
order: 77
keywords: [ultimate, conversations, chat, pi, backend, web ui, coding agent]
related: [chat-mode, composer, herdr-vs-tmux, cant-connect]
---

Ultimate is a coding agent built on pi that runs as a server with a web UI and keeps durable conversations. When Ultimate runs on a Host, Waycar shows its conversations in the Console and lets you chat with them. Ultimate has no terminal, so every Ultimate conversation opens in [Chat Mode](/help/chat-mode).

Waycar isn't affiliated with Ultimate.

## What you need

- Ultimate running on the Host under your SSH user, started the usual way (`ultimate` in a project, or `pnpm start` in its folder). Waycar finds every running project: each one becomes a Workspace.
- SSH forwarding allowed on the Host. Waycar reaches Ultimate's local port through the SSH connection, so `AllowTcpForwarding no` in `sshd_config` blocks it. Set it to `local` or `yes` and restart the SSH server. macOS allows it by default.

Ultimate only listens on the Host itself. Waycar never exposes it to the network and needs no token or extra setup on the Host.

## What works

- **The Console.** Each conversation you started shows as an agent, under its project's Workspace. Ultimate's own helpers, such as subagents and its lander, stay hidden.
- **Status.** A conversation reads **Working** while Ultimate is running a turn and **Idle** otherwise.
- **Chat Mode.** Your messages stay in bubbles; assistant replies use the full width. Question cards show numbered questions and lettered options, including recommended choices. Tap an option to send its answer. Tool steps collapse into a summary line; compaction and reset appear as dividers.
- **Branches and failures.** Tap a branch card to open that conversation. Failure cards show what went wrong and let you open the affected conversation. On iPad, the left rail keeps the lead and branches within reach.
- **The Composer.** Send a message to steer or answer. A working indicator shows elapsed time during a turn, and **Stop** replaces Send so you can interrupt it.

## What is still missing

- Starting a new conversation from Waycar. Start it in Ultimate, then it appears in the Console.
- Closing, renaming or moving conversations.
- Notifications and Live Activities for Ultimate conversations.
- Ultimate running inside a container without its own SSH server.

## Good to know

- Waycar finds Ultimate through the files it keeps in `~/.ultimate/projects`. A server started with a different `ULTIMATE_HOME` is not found.
- If the Host also runs herdr or tmux, their agents show next to the Ultimate conversations in the same Console.
