---
title: mosh
description: Waycar runs agent terminals over mosh so they stay attached when you change networks, and falls back to SSH when mosh can't get through.
category: hosts
order: 20
keywords: [udp, mosh-server, roaming, test mosh, ssh fallback, badge, use ssh instead]
related: [reconnecting, mosh-not-connecting, hosts, ssh-keys]
---

mosh keeps your agent terminals attached when your phone changes networks. Waycar starts mosh for you over SSH and runs agent terminals on it once it knows mosh works for that Host. When mosh can't get through, Waycar uses SSH instead, so you still get your terminal.

## Why mosh instead of plain SSH?

SSH is one TCP connection tied to your phone's network address. Move from Wi-Fi to cellular and it drops, so Waycar has to reconnect and re-attach the terminal. mosh runs over UDP and roams: the session carries on across the network change. `mosh-server` runs on your Host and holds the session there.

| Situation | Plain SSH | Waycar over mosh |
| --- | --- | --- |
| You switch networks | The connection drops. Waycar reconnects and brings the terminal back. | Nothing drops. Your agent stays attached. |
| mosh can't connect | No change. | Waycar notices and uses SSH instead. |

## Set up mosh on your Host

1. Install `mosh-server` on the Host. See [mosh.org](https://mosh.org) for packages.
2. Make sure UDP traffic can reach the Host.

That's all. Waycar starts mosh over its SSH connection, so there's nothing else to configure. Missing either one? Waycar stays on SSH.

## Test mosh

1. Tap **Hosts**, then tap the Host.
2. Under **Mosh**, tap **Test Mosh Support**.

Waycar runs a real mosh handshake against the Host. A pass reads **Mosh supported**, and agent sessions ride mosh from then on. A failure reads **Mosh handshake failed** and sessions use SSH. While a Host is connected over SSH, **Retest and Upgrade Sessions** tests mosh again on the live connection.

When you edit a Host, **Test Mosh on this Host** runs a check with the details in the form. It only works once Waycar already trusts the Host's key, so for a Host you just typed in, save it, trust its key on its page, and use **Test Mosh Support** instead. A failed test doesn't stop you from saving.

## How do I know which one I'm on?

A **MOSH** or **SSH** badge sits beside the Host's name in the Host menu, on its card in the [Hosts sheet](/help/hosts), and on its page.

## Good to know

- Waycar remembers, per Host and per network, whether mosh gets through. An agent you open later rides mosh from its first attach, and a network that blocks UDP goes straight to SSH.
- If a mosh session ends, the toolbar's connection icon can offer **Use SSH Instead**. That choice lasts across network changes.
- Typed characters appear once the Host echoes them. Waycar doesn't guess ahead the way the desktop mosh client can.
- Your phone gets mosh's redraw of the current screen, not the agent's raw output.

## Troubleshooting

Badge stuck on SSH? See [mosh isn't connecting](/help/mosh-not-connecting).
