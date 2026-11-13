---
title: Agent status
description: What Blocked, Done, Working, Idle, and Unknown mean on an agent card, and how status decides the Console's order.
category: console
order: 20
keywords: [blocked, done, working, idle, unknown, badge, sort order, needs attention]
related: [console, filter-search-pin, status-unknown, notifications]
---

Every agent card in the Console carries a status badge that tells you what the agent is doing right now: Blocked, Done, Working, Idle, or Unknown. The status comes from your Host, and it decides where the card sits in the list.

On a herdr-core Host, only agents that report their status to herdr-core show one: Claude Code and Pi. Others read Unknown. See [Waycar with herdr-core](/help/herdr-core#status-shows-unknown).

## What does each status mean?

| Status | Color | Meaning |
| --- | --- | --- |
| Blocked | Blue | The agent is waiting for you, for example to approve a command or answer a question. |
| Done | Green | The agent finished and you haven't looked at it yet. |
| Working | Yellow | The agent is busy. Its card shows a moving orb. |
| Idle | Gray | The agent is waiting with nothing new to show you. |
| Unknown | Red | Waycar can't read this agent's status. |

On a herdr Host the status is what herdr detects. On a tmux Host it comes from the Waycar Status Hooks that the install command adds to the agents in [Supported agents](/help/supported-agents#what-works-with-each-agent).

## Why do blocked agents come first?

The Console sorts by who needs you first: Blocked, then Done, then Working, then Idle, then everything else (Unknown agents and plain shells). Pinned agents stay above all of them. Inside one status, cards are grouped by Host, newest change first.

## When does Done turn into Idle?

Opening a Done agent turns it Idle once you have stayed on it for three seconds. Backing out sooner, say after a mis-tap, leaves it Done. To put an Idle agent back on your to-do list, touch and hold its card and choose **Mark as Unread**. See [Rename, close, and mark agents](/help/manage-agents).

## Where else does status show up?

- The **Needs Attention** pill lists Blocked and Done agents together; **Blocked**, **Done** and **Working** each list one status. Idle has no pill of its own and shows under **All**.
- The app icon badge counts the agents that are Blocked or Done across all your Hosts. Plain shells never count. Opening a Done agent lowers it.
- Blocked and Done also drive [Notifications](/help/notifications) and [Live Activities](/help/live-activities).

## herdr and tmux

On tmux, an agent shows Unknown when its Status Hooks are missing, or when Codex's hooks are not yet reviewed in its `/hooks` screen. See [Agent status shows Unknown](/help/status-unknown).

## Good to know

Plain shells have no status. Their card reads **Shell**, or **Running** while a command runs. See [Shells and busy shells](/help/shells).
