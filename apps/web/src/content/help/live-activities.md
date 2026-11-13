---
title: Live Activities
description: Follow each Host's agents on your Lock Screen and in the Dynamic Island, with counts of Blocked, Done, Working and Idle agents.
category: alerts
order: 20
keywords: [lock screen, dynamic island, status, counts, widget, push-to-start, apple watch, smart stack, carplay dashboard, progress]
related: [notifications, agent-status, agent-progress, live-activities-not-updating]
---

A Live Activity keeps one Host on your Lock Screen and in the Dynamic Island. It shows how many agents are Blocked, Done, Working and Idle, and a line for each agent, so you can check on them without opening Waycar.

On a herdr-core Host, Live Activities need Waycar Host Tools and an agent that reports its status to herdr-core. See [Waycar with herdr-core](/help/herdr-core).

## Turn on Live Activities

Live Activities turn on with notifications. When Waycar asks, tap **Turn On** (or **Continue**, then allow notifications), and both are set up for every Host.

To change one Host:

1. Open **Settings**, then **Notifications**.
2. In the Host's section, turn **Live Activity** on or off. It appears once **Notifications** is on for that Host.

If Live Activities are off for Waycar in iOS Settings, the Host's section tells you to enable them there.

## What it shows

- **Lock Screen**: a big status line such as "1 Blocked", with the other counts beside it, then up to four agents with their status in words and colors. Each agent shows the first two rows of its Agent List Fields on one line, and a value repeated across them, such as a worktree's branch name in both the Workspace and the tab, shows once. Pinned agents come first.
- **Dynamic Island**: a status symbol and count. Expand it to see agents.
- **Apple Watch Smart Stack and CarPlay Dashboard**: the Host's name and lead count, then the top three agents by short name, each with its status or progress label. Tap it to open the Console.

When more agents qualify than fit, the Live Activity shows three of them and a **+N more** footer. The expanded Dynamic Island shows **+N more** too.

**May be out of date** means the Host hasn't updated the Live Activity recently. Open Waycar with that Host connected to refresh it.

Counts read in attention order: Blocked, Done, Working, then Idle. Idle agents never start or keep a Live Activity open and don't count in the Dynamic Island total. Shells never raise Live Activities.

Tap an agent's row to open that agent. Tap anywhere else on the Live Activity to open the Console.

## Progress

With [Agent Progress](/help/agent-progress) on, a Working or Blocked agent's row has a thin bar under its name. A Working agent's status word becomes its progress label, such as **3/7** or **Verifying**. A Blocked agent's bar stays where it stopped. The bar dims when the Live Activity is out of date. When Working leads and one of the top three agents has an estimate, the compact Dynamic Island shows up to three thin bars, one per agent, instead of the count. The Watch and Dashboard view puts a small bar between each agent's name and its label, or under the name when the tile is narrow.

With Waycar closed, your Host keeps plan steps current on the Live Activity without any AI calls. Phases update when Waycar or CarPlay is open.

## Does it work when Waycar is closed?

Yes, in two ways:

- **Started while Waycar was open**: it keeps updating in the background after you leave Waycar. Your Host sends each change, and the end, straight to it.
- **Started by the Host**: when an agent starts working, gets blocked, or finishes while Waycar is closed, your Host can start the Live Activity itself, with a brief "Agents active" alert. It shows the Host's status as of that moment and is marked **May be out of date** after a while. Live updates resume the next time you open Waycar with that Host connected.

If you dismiss it, it stays away until that Host's agents go quiet.

This needs the current Waycar plugin on your Host. See [Update Waycar on your Host](/help/update-host-tools).

## Why isn't a Live Activity showing?

In **Settings** › **Notifications**, the Host's section shows a **Live Activity:** line saying whether it is active or idle, and why. Idle with no working, blocked, or done agents is normal. The other reasons point to what to fix: the iOS setting, push registration, or the Waycar plugin. See [Live Activities aren't updating](/help/live-activities-not-updating).

## What stays private

Apple needs to read a few values to show a Live Activity: the status counts, the start, update or end event, and timing. Agent, Host and task details stay encrypted with your Host's Notification Key. See [Notifications](/help/notifications#how-notifications-stay-private).

## herdr and tmux

Live Activities work on both Backends. On tmux they come through Waycar hooks.
