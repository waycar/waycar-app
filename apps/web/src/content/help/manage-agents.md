---
title: Rename, close, and mark agents
description: Close, rename, move, pin, and mark agents from the Console, one at a time or several at once with Select.
category: console
order: 50
keywords: [mark as unread, mark as read, rename tab, close tab, undo, select, move to workspace, close agent, could not move, agent name]
related: [console, filter-search-pin, workspaces, closed-sessions]
---

You manage agents right from their cards in the Console. Touch and hold a card for its actions, swipe it to close it, or tap **Select** to act on several agents, across Hosts, at once.

## What's in the card's menu?

Touch and hold an agent card to see:

- **Select**: start picking several agents. See below.
- **Pin** or **Unpin**: keep it at the top of the list.
- **Mark as Unread** or **Mark as Read**: see below.
- **Move to Workspace…**: move its tab into another Workspace on the same Host. See [Workspaces](/help/workspaces).
- **Rename Tab…**: rename its herdr tab.
- **Open in New Window**: on iPad, open it in its own window.
- **Close**: close its tab.

## Close an agent

Swipe the card and tap the trash icon, or choose **Close** from its menu. The tab doesn't close right away: the icon turns into an undo arrow and a red circle drains for 5 seconds. Tap it, or the card, to undo. When the tab is the last one in its Workspace, the Workspace closes too.

A closed agent goes to [Closed Sessions](/help/closed-sessions), so you can resume it later.

### Close from the agent's screen

In an open agent, open the **More** menu and tap **Close Agent**. The pane closes on the Host right away, with no confirmation and no undo countdown, unlike a swipe or the card's **Close**. Closed it by mistake? Resume it from [Closed Sessions](/help/closed-sessions).

When Closed Sessions can't bring the conversation back, Waycar asks "Close <name>?" first: on a shell, which is never kept, and on an agent that didn't report a session it can resume. That includes an agent that could only resume its latest session in the folder (gemini, for example), since that may be another agent's. Tap **Close Shell** or **Close Agent** to close it, or **Cancel** to keep it.

If a close fails, Waycar shows **Couldn't Close Agent** with the reason.

## Rename an agent, shell, tab, or Workspace

| Item | Where | What it changes |
| --- | --- | --- |
| **Rename Tab…** | Touch and hold a card in the Console | The herdr tab's name. |
| **Rename Agent** | **More** menu on an agent's screen | The agent's name, the `agent` field on its card. Leave it empty to fall back to the detected kind, such as `claude`. |
| **Rename Agent** on a shell (the sheet reads **Rename Shell**) | **More** menu on a shell's screen | The shell's tab name. |
| **Rename Workspace** | **More** menu on any agent's screen | The name of the Workspace it's in. |

Tap **Save** to apply or **Cancel** to leave it.

### Agent name rules

Agent names are 1 to 32 characters: lowercase letters, digits, `-` or `_`, starting with a lowercase letter. The sheet shows this rule when a name doesn't fit.

## Mark an agent as unread

Touch and hold an Idle agent and tap **Mark as Unread**. Waycar lists it as Done again: green badge, the **Done** and **Needs Attention** pills, and Done's place in the sort. It stays that way until you open it, tap **Mark as Read**, or the agent starts doing something new.

The mark stays on this device. It never changes what herdr, notifications, or Live Activities report.

### Mark as unread from the agent's screen

In an open Idle agent, open the **More** menu and tap **Mark as Unread**. Waycar marks it and takes you back to the Console, where the agent now lists as Done. The entry is missing for an agent that is working, blocked, or already Done, and for a shell.

## Act on several agents at once

1. Touch and hold a card and tap **Select**.
2. Check the agents you want, or tap **Select All**. A selection can span Hosts.
3. Use the bottom bar: **Pin**, **Mark Read** or **Mark Unread**, **Move…**, or **Close**.
4. Tap **Done** to leave selection.

Each closed card gets its own undo countdown. **Move…** only works when every checked agent is on one Host; otherwise Waycar says "Move works within one Host."

## herdr and tmux

**Rename Tab…** appears for herdr agents. On tmux, **Rename Agent** renames the tmux window and **Rename Workspace** renames the tmux session. A shell is renamed by its tmux window.

## Troubleshooting

- If a close fails, Waycar shows **Could Not Close Tab** with the reason. When the Host is briefly reconnecting as the countdown ends, the close waits for it to come back and then goes out.
- If **Move to Workspace…** or **Move…** fails, Waycar shows **Could Not Move Agent** with the reason.
- A rename that fails says "The Host is not connected." or "herdr rejected the rename:" with herdr's reason. Reconnect or fix the name, then try again.
