---
title: Network changes and reconnecting
description: What Waycar does when you switch networks, lose signal, or leave the app, and how your terminal comes back on its own.
category: hosts
order: 30
keywords: [wifi, cellular, offline, background, sleep, lock screen, frozen, reconnecting pill, session ended, read offline]
related: [mosh, cant-connect, connection-messages, terminal]
---

Waycar keeps your agent terminals going through network changes and brings them back on its own after a dropout or a trip away from the app. You don't tap anything: the terminal re-attaches and keeps its last screen up while it does.

## What happens when I switch networks?

When you move between Wi-Fi and cellular, Waycar re-checks every Host at once. Terminals running over [mosh](/help/mosh) move to the new network right away and stay attached. Terminals on plain SSH lose their connection, and Waycar reconnects them and re-attaches the terminal.

A connection that died in the switch is noticed within seconds. Otherwise Waycar notices a dead connection within about 35 seconds.

## What happens when the signal stalls?

If a mosh terminal stops hearing from its Host for about six seconds, a **Reconnecting** pill appears over the live screen, so you know it isn't frozen. If the Host stays silent for 65 seconds, Waycar reconnects the terminal over mosh. When the Host answers again after an outage, Waycar reconnects right away instead of waiting for its next retry.

## What happens when I leave the app or lock my phone?

Waycar keeps running for about 20 seconds after you leave. After that the terminal session ends, and it re-attaches on its own when you come back.

- **Back within about 70 seconds of leaving?** That is 50 seconds after the session ends. For a mosh terminal, Waycar starts a fresh mosh server before it lets the old one go, so the terminal re-attaches without any SSH work.
- **Back later?** Waycar checks each Host's saved SSH connection with one quick request and only dials a new one if that's slow to answer.

## Last screen while reconnecting

When you open an agent or shell, or the app relaunches straight into one, you see its last screen under a **Reconnecting** veil instead of a blank screen, until the live terminal draws. Waycar keeps this picture on your device for the eight terminals you used most recently, for up to a day. See [Privacy](/privacy).

## Read the conversation with no signal

A terminal can't scroll while it is disconnected: its history lives on the Host. So when a terminal can't connect, a card appears over it that says what is wrong, with **Read saved copy** and how old the copy is. It says **You're offline** only when your device has no network. With a network it shows the Host's own status (such as **Host Unavailable**), **Can't reach your Host**, **Terminal disconnected**, or **Still connecting…** after about eight seconds of connecting, so a session that is just slow to load shows no card. The connection icon's popover also offers **Read saved conversation**. Tap it to read the conversation Waycar saved on this device, as text you can scroll, newest message at the bottom. A banner at the top says it is a saved copy and how old it is. The [Composer](/help/composer) stays under it, so you can write a reply: with the Host unreachable it waits as a [queued message](/help/queued-messages) and goes out when the Host is back. If the terminal reconnects while you read, the banner says you are back online and the reader stays open until you tap **Done**.

What to expect:

- **It's text, not the terminal's drawing.** You see your messages and the agent's replies, not tool output, colours, or the screen as it looked.
- **Only conversations this device has seen while online.** Waycar saves the agents you open, and keeps the eight that finished most recently up to date while the app is open with a connection. An agent you never opened, and that isn't among those, has nothing to read, so no offline card offers a copy.
- **The agent has to report its session to Waycar.** Waycar only keeps a conversation for an agent it can tell apart from whatever else runs in that terminal later, which is the session the agent reports (Chat Mode agents are told apart by their launch). On herdr most agent kinds report a session only with herdr's integration for them installed (`herdr integration status` shows which); on tmux they do with the Waycar Status Hooks. An agent that reports none has no saved conversation, so no offline card offers one.
- **It needs the Waycar plugin on the Host.** Waycar reads the conversation through the plugin's transcript reader, so a Host without the plugin, or with an old one, has no saved conversations. Some agents don't write a transcript the reader understands.
- **Long conversations are trimmed.** Waycar keeps the newest 300 messages of each, within about 2 MB.
- **A reply to an agent that is waiting on a question isn't queued.** It has to be typed into the agent's terminal, so while the Host is out of reach Waycar says it couldn't send it and keeps your draft.

Saved conversations stay on this device, are left out of backups, and are deleted when the agent closes, when you remove its Host, and after 30 days without use. See [Privacy](/privacy).

## herdr and tmux

Reconnecting works the same on herdr and tmux Hosts. On herdr, re-attaching takes the terminal back from another client, as opening it does. See [Your desk and phone on one terminal](/help/take-over).

## Troubleshooting

- **Detached.** If a terminal can't be brought back, a red icon appears in the toolbar and the screen stays readable. Tap it to see why and to **Reattach**. When mosh was the problem it can also offer **Use SSH Instead**. Each message is explained in [What connection messages mean](/help/connection-messages#what-does-detached-mean).
- **Paused, Unavailable, or another message?** See [What connection messages mean](/help/connection-messages). When a Host shows as Unavailable, Waycar has stopped retrying: open the Host's page, fix the problem, and tap **Reconnect**.
- **Still not connecting?** See [Can't connect to a Host](/help/cant-connect) or [mosh isn't connecting](/help/mosh-not-connecting).
