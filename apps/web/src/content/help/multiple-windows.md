---
title: Multiple windows and Stage Manager
description: Open Waycar in more than one iPad window, each on its own agent, and resize freely under Stage Manager.
category: devices
order: 30
keywords: [open in new window, take over here, live in another window, split screen, multitasking]
related: [ipad, take-over, keyboard-shortcuts]
---

On iPad, Waycar opens in more than one window and resizes freely under Stage Manager. Each window can show a different agent, so you can watch two at once.

## Open an agent in a new window

1. Touch and hold an agent in the Console.
2. Tap **Open in New Window**.

You can also drag the agent's row out of the list. Each window restores its own agent after a relaunch.

## Why does a window say Live in Another Window?

On herdr, a Host has one live terminal. Windows on the same herdr Host share it: it goes to the window you last touched or typed in, or to a window you just opened. The others show **Live in Another Window**. Windows on tmux Hosts, and windows on agents from different Hosts, are all live at once.

Tap **Take Over Here** to move the live terminal to that window. Returning to the app leaves the live terminal where it was.

## Good to know

- A notification for an agent that's already on screen brings that window forward instead of opening another.
- A narrow window drops the agent sidebar and shows one screen at a time, like on iPhone. See [Waycar on iPad](/help/ipad#narrow-windows).
- When you resize a window, Waycar tells the Host the new terminal size once the window settles.
- Each window remembers its own UI, such as whether the AI Usage row is open.
- Typing on a hardware keyboard goes to the window you're using. See [Keyboard shortcuts](/help/keyboard-shortcuts).
