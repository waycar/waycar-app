---
title: Workspaces
description: A Workspace groups the tabs on a Host, like a herdr workspace or a tmux session. Filter, move, and rename them from Waycar.
category: console
order: 80
keywords: [workspace menu, move to workspace, rename workspace, tmux session, all workspaces, project, folder]
related: [console, filter-search-pin, manage-agents, worktrees]
---

A Workspace is a group of tabs on one Host, usually one project folder. On herdr it's a herdr workspace; on tmux it's a tmux session. Waycar lets you narrow the Console to one Workspace, move agents between Workspaces, rename them, and start new agents in them.

On a herdr-core Host, Waycar builds Workspaces from the terminals: one per folder, or per `herdr.space` label the Herdr app sets. New Workspaces, renaming and **Move to Workspace** aren't available there yet. See [Waycar with herdr-core](/help/herdr-core).

## Show only one Workspace

1. Tap the Workspace menu in the Console's bottom bar. It reads **Workspaces** while every Workspace is shown.
2. Pick a Workspace. Pick **All Workspaces** to see everything again.

The menu lists the Workspaces of the Host you chose in the Host menu, or of every Host with **All Hosts**. A Workspace stays in the menu whatever its agents are doing, and when two Hosts have a Workspace with the same name, the entry adds the Host name.

The Workspace menu only filters. Agents keep their status order. See [Filter, search, and pin](/help/filter-search-pin).

## Move an agent to another Workspace

Touch and hold its card, tap **Move to Workspace…**, and pick a Workspace on the same Host. To move several at once, tap **Select**, check them, and tap **Move…** in the bottom bar. Every checked agent has to be on the same Host. If a move fails, Waycar shows **Could Not Move Agent** with the reason. See [Rename, close, and mark agents](/help/manage-agents).

## Rename a Workspace

Open an agent in the Workspace, open the **More** menu, and tap **Rename Workspace**.

## What happens when I close the last tab?

Closing a Workspace's last tab closes the Workspace too, after the same 5-second undo countdown.

## Start something in a Workspace

The New Agent sheet starts an agent or a Default Shell in an existing Workspace, in a new worktree of one, or in a new Workspace at a folder on the Host. See [Start a new agent](/help/new-agent) and [Start on a new worktree](/help/worktrees).

## How do worktrees show up?

A linked git worktree's agents count under the Workspace of the repository's main checkout. Picking that Workspace in the menu shows its worktrees' agents too. To see a worktree's branch and path, or remove it, see [Start on a new worktree](/help/worktrees).

## herdr and tmux

- On herdr, Workspaces are herdr's own workspaces.
- On tmux, each tmux session is a Workspace and each agent or shell gets its own window. When tmux has no sessions running, tap **Start Session** in the Console to open one.
- On a Host with both, herdr Workspaces and tmux sessions appear together, and tmux entries in the Workspace menu end in "· tmux".
