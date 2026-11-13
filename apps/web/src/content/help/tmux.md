---
title: Waycar with tmux
description: "Use Waycar with tmux 3.2 or later: your tmux sessions show up as Workspaces, and you start, open, message and close agents from your phone."
category: hosts
order: 60
keywords: [sessions, backend, show tmux sessions, start session, new agents start in, windows, panes]
related: [herdr-vs-tmux, tmux-hooks, take-over, install]
---

Waycar works with tmux 3.2 or later as well as herdr. A tmux Host works like a herdr Host: your tmux sessions show up as Workspaces, and you can start, open, message, rename and close agents and shells from your phone.

## Set up a tmux Host

Run the same install command you'd use for herdr on the machine:

```sh
curl -fsSL https://waycar.dev/install.sh | sh
```

It finds tmux, sets up Waycar and the [Waycar hooks](/help/tmux-hooks) for live status, and offers to show a Pairing Code right in your terminal. See [Install Waycar on your Host](/help/install).

## How tmux maps to Waycar

| tmux | Waycar |
| --- | --- |
| Session | Workspace |
| Window and pane | Agent or shell |

When tmux has no sessions running, tap **Start Session** in the Console to open one. Starting a [new agent on a worktree](/help/worktrees) opens it as a new tmux session, and needs git on your Host.

## Opening an agent shares the window

Opening an agent shares its tmux window with your desk instead of taking it over. The window fits whichever one opened it or typed in it last. See [Your desk and phone on one terminal](/help/take-over).

## A computer with herdr and tmux

On a computer with both, herdr agents and tmux sessions appear together in one list. To tell them apart, add the `runtime` field to a card row in [Agent card fields](/help/agent-card-fields); tmux entries in the Workspace menus end in "· tmux". The Host's page gets a **Backends** section:

- **Show tmux sessions** lists the Host's tmux sessions. It's on unless you turn it off. Hiding tmux sessions also stops their notifications from this Host.

Choose **Herdr TUI** or **tmux** in **New Agent** when creating a new Workspace; **Herdr Core** appears too when present. The single **Runtime** picker remembers your choice per Host. An existing Workspace always uses its own Backend.

If herdr or tmux runs into a problem, it shows its own issue with **Retry** while the other keeps working.

## Agent status on tmux

tmux doesn't know what an agent is doing, so Waycar gets Working, Blocked and Done from small hooks in Claude Code, Codex, Gemini CLI, opencode and the other agents listed in [Waycar hooks for tmux](/help/tmux-hooks). Agents without them show Unknown.

## Good to know

- Everything else, including [mosh](/help/mosh), AI Usage and dictation, works the same on tmux.
- For the full list of differences, see [herdr vs tmux](/help/herdr-vs-tmux).
