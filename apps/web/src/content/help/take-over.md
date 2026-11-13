---
title: Your desk and phone on one terminal
description: What happens to your desktop terminal when you open the same agent in Waycar, on herdr and on tmux, and how Take Over Here works on iPad.
category: hosts
order: 50
keywords: [take over here, live in another window, takeover, disconnected, shared window, resize, desktop]
related: [herdr-vs-tmux, multiple-windows, terminal, tmux]
---

You can open an agent in Waycar while it's also open at your desk. What happens to the desktop side depends on the Backend: herdr hands the terminal to Waycar, and tmux lets both watch the same window.

## herdr and tmux

| | herdr | tmux |
| --- | --- | --- |
| Opening an agent in Waycar | Takes over its terminal. The other client is disconnected. | Nothing is taken over. Both can watch and type in the same window. |
| Window size | Waycar's size while it's attached | Fits whichever one opened it or typed in it last |

### On herdr

Opening an agent or a shell in Waycar takes over its terminal, and the other attached client gets disconnected. While Waycar is attached, the terminal is sized to Waycar's screen.

### On tmux

Opening an agent shares the window with your desk instead of taking it over. The window fits whichever one opened it or typed in it last, so when you sit back down and type, it fits your desktop again.

## herdr-core

Opening a terminal on a herdr-core Host takes nothing over, so there is no Take Over and no **Live in Another Window**. Several windows can attach and your desk keeps typing. The terminal follows the newest typing viewer's size. See [Waycar with herdr-core](/help/herdr-core#attach-and-your-desk).

## Two Waycar windows on one Host (iPad)

On herdr, a Host has one live terminal. When two [Waycar windows](/help/multiple-windows) show agents on the same herdr Host, the terminal goes to the window you last touched or typed in, or to a window you just opened. The others show **Live in Another Window**: "This Host's terminal is open in another Waycar window, and input continues there."

To move the terminal to the window in front of you, tap **Take Over Here**. It works for agents and shells.

On tmux, every window stays live, because tmux lets several clients attach at once. Windows on agents of different Hosts are also all live at once.

## Good to know

- Coming back to the app leaves the terminal in whichever window had it.
- To pick which Backend a new agent starts in on a computer with both, see [Waycar with tmux](/help/tmux).
- If the toolbar's connection icon says **Detached** with "Another terminal is already open on this Host.", a second view tried to read a terminal that's already open in Waycar. The live terminal keeps running. Close the other view, then tap the icon and **Reattach**. See [What connection messages mean](/help/connection-messages#what-does-detached-mean).
