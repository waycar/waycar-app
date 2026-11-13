---
title: What connection messages mean
description: What each Host connection message in the Console and over an open agent means, from Connecting and Paused to Host Unavailable and Detached.
category: troubleshooting
order: 15
keywords: [paused, disabled, unavailable, connecting, reconnecting, loading agents, detached, session ended, reattach, connection dot]
related: [cant-connect, reconnecting, hosts, host-page]
---

Waycar tells you how each Host's connection is doing in three places: rows above your agents in the Console, a message over an agent you have open, and the connection dot in the toolbar when a terminal stops. This page explains each message and what to do about it.

## Paused, Disabled, or Unavailable?

These three look alike but mean different things:

- **Paused** means Waycar isn't the active app, so it has set the connection aside. Nothing is wrong. Come back to Waycar and it connects again on its own.
- **Disabled** means you switched the Host off in [Hosts](/help/hosts). Waycar never connects to a disabled Host. Turn its **Enabled** switch back on to see its agents.
- **Unavailable** means the connection failed in a way that retrying can't fix, so Waycar stopped retrying. Tap the row to open the Host's page, read the message under **Reconnect**, fix the problem, then tap **Reconnect**. See [Can't connect to a Host](/help/cant-connect).

## What are the rows above my agents?

The Console shows one row for each Host that isn't simply connected. Rows marked with a › open that Host's page when you tap them. If you picked one Host in the Host menu, only its rows show.

| Row | What it means | What to do |
| --- | --- | --- |
| "Connecting to <Host>…" | Waycar is opening the connection. | Wait. |
| "Reconnecting to <Host>: <reason>" | The connection dropped and Waycar is retrying on its own. | Wait, or tap the row to see the Host's page. |
| "Connection to <Host> is paused." | Waycar isn't active, so the connection is set aside. | Nothing. It resumes when you return. |
| "Loading Agents from <Host>…" | Connected, and fetching the agent list. | Wait. |
| "<Host>: <error>" | The connection failed and retries stopped. A shield icon means the host key changed. | Tap the row, fix the problem, tap **Reconnect**. For a changed key, see [Host keys and fingerprints](/help/host-keys). |
| "Waiting for you to trust <Host>'s host key" | The Host answered, and Waycar needs you to confirm its key. | Tap the row and confirm the fingerprint. |
| "Waiting for you to trust the Jump Host's host key for <Host>" | Same, for the [Jump Host](/help/jump-host). | Tap the row and confirm the Jump Host's fingerprint. |
| "<Host>: Could not sync this Host's Agents. Retrying…" | Waycar is connected but couldn't load this Host's agent list. It retries on its own. | Wait. If the row stays, tap it to open the Host's page. |

On a Host that runs both herdr and tmux, a row for one Backend (for example "herdr on <Host>: …") has its own **Retry** button.

## What do the messages over an open agent mean?

When you have an agent open and its Host isn't connected, the agent screen shows one of these:

| Title | What it means | What to do |
| --- | --- | --- |
| **Connecting…** | "Opening the connection." | Wait. |
| **Reconnecting…** | The connection dropped; the reason shows below. | Wait. Waycar retries on its own. |
| **Loading Agents…** | "Fetching the latest Agents." | Wait. |
| **Connection Paused** | "The connection is paused until Waycar becomes active." | Nothing. It resumes when Waycar is active. |
| **<Host> Is Disabled** | "Turn it on in Hosts to see its Agents." | Turn the Host on in [Hosts](/help/hosts). |
| **Host Unavailable** | Retries stopped; the reason shows below. | Open the Host's page, fix the problem, tap **Reconnect**. |
| **Please select an agent** | "This Agent's pane is no longer reported. Choose another Agent from the list." | The agent was closed. Pick another one. |

While a terminal is opening, it also shows a counter such as "Connecting to <Host> · 5s" or "Reconnecting to <Host> · 5s", so you can see it's still working.

## What does Detached mean?

The connection icon at the right end of the toolbar, just before the 💬 button, shows the terminal's connection: a green dot when it is live, amber circling arrows while it reconnects, and a red cable icon when the terminal stopped and can't come back by itself. The screen behind it stays readable. Tap the icon to see why. **Reattach** opens the terminal again. **Use SSH Instead** appears only after a mosh failure. While it is detached or reconnecting, keys that go straight to the terminal, like Esc and the arrows, are dimmed; sending a message still works. If a connection drops under a live terminal, Waycar reattaches once on its own first. If a terminal fails before it ever shows anything, there is nothing to read, so a **Detached** card with **Reattach** shows in its place.

| Message | What it means | What to do |
| --- | --- | --- |
| "The session ended." | The terminal closed on the Host. | Tap **Reattach**. |
| "The Host is not connected." | The Host's connection is down. | Wait for it to reconnect, then tap **Reattach**. |
| "Another terminal is already open on this Host." | A second view tried to read a terminal that's already open in Waycar. The live one keeps running. | Close the other view, then tap **Reattach**. |
| "The Host did not answer in time." | The Host was too slow to respond. | Check your network, then tap **Reattach**. |
| "The mosh session failed: …" | mosh couldn't carry the terminal. | Tap **Use SSH Instead**, or see [mosh isn't connecting](/help/mosh-not-connecting). |
| "The Host stopped answering over UDP for 65s." | A mosh terminal lost its Host. Waycar already reattached once on its own. | Check your network, then tap **Reattach** or **Use SSH Instead**. |
| "herdr is not on this Host's SSH PATH. …" | The SSH login can't find the `herdr` command. | See [Can't connect to a Host](/help/cant-connect#herdr-is-not-on-this-hosts-ssh-path). |

For how Waycar handles network changes on its own, see [Network changes and reconnecting](/help/reconnecting).
