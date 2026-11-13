---
title: The live terminal
description: Open any agent or shell to see its real terminal on your iPhone or iPad, live from your Host, with taps for links, files, and keys.
category: terminal
order: 10
keywords: [attach, screen, session, reconnecting, output, shell, pane, latency, cost, context window]
related: [select-copy, scrolling, toolbar, files-and-links]
---

When you open an agent or a shell from the Console, Waycar shows its live terminal: the same screen the agent draws on your Host, streamed to your iPhone or iPad. You read its output, scroll back through its history, tap links and file paths, and type into it from the Toolbar at the bottom.

## What you see

- The agent's terminal fills the screen, in your chosen terminal theme.
- On iPhone, a ‹ Back button sits in its own row above the terminal, so it never covers the first line. You can hide it in **Settings › Terminal Appearance › Hide Back Button** and swipe from the left edge to go back instead.
- The Toolbar runs along the bottom, with your keys on the left and **Message Agent**, **Terminal Keyboard**, and, for agents, **Dictate to Agent** on the right. See [The Toolbar](/help/toolbar).
- For omp agents, a usage strip above the terminal shows the model and session figures. See [What's the strip above the terminal?](#whats-the-strip-above-the-terminal).
- The status row under the terminal shows the agent's status, a small strip of images, PDFs, Markdown files, and links the agent printed, and the Host's latency. See [Files and links](/help/files-and-links).

## What's the strip above the terminal?

For agents that keep a session file, a thin strip above the terminal shows the agent's own figures. Only omp writes such a file today, so other agents show no strip.

- The model the agent is using.
- How full the context window is, such as `11.0%`, once omp reports the window size. Before that it shows a size such as `248K`.
- The session's spend so far, such as `$1.50`.
- Tokens per second, such as `9.5 tok/s`, only while omp's own `tok/s` readout is on.

A figure Waycar can't read is left out rather than shown as zero. The strip uses your terminal theme.

## What's in the row under the terminal?

- The agent's live status in its color, with a moving orb while it is Working. See [Agent status](/help/agent-status).
- The files and links the agent printed, ready to preview.
- The Host's latest round trip in milliseconds, such as `24 ms`. It measures the connection to your Host (SSH plus herdr), not how fast the agent answers, so a high number points to a slow network rather than a busy agent. It shows only while the Host is connected, and updates when Waycar connects and when you come back to the app.

## What you can do in the terminal

- **Tap a web link** to open it, even one that wraps onto the next line.
- **Tap a file path** such as `~/shot.png` or `src/app.swift:12:3` to preview the file from your Host.
- **Touch and hold text** to select it and copy. See [Select and copy text](/help/select-copy).
- **Drag** to scroll back through the agent's history. See [Scrolling and jump buttons](/help/scrolling).
- **Pinch** to zoom the text. See [Terminal themes, fonts, and zoom](/help/terminal-appearance).
- **Tap the prompt line** to bring up the keyboard and type straight into the agent. See [Type straight into the terminal](/help/direct-input).

## What happens while it opens or reconnects?

The first time you open a terminal you haven't used recently, Waycar shows the agent's name and Host while it connects, then the first screen appears. If the Host has a problem, the message says what's wrong. For what each message means, see [What connection messages mean](/help/connection-messages).

When you open an agent you used recently, or come back to Waycar, the terminal shows its last screen under a light Reconnecting veil instead of a blank connecting screen, until the live terminal draws. Waycar keeps this picture on the device for the eight terminals you used most recently, for up to a day.

Over mosh, if the terminal stops hearing from its Host for a few seconds, a Reconnecting pill shows over the live screen instead of the terminal freezing silently.

## Good to know

- Opening an agent takes over its terminal from another attached client. See [Your desk and phone on one terminal](/help/take-over).
- On iPad with a hardware keyboard, the arrow keys go to the terminal while it has the keyboard. Return and ⌘Return submit, and Shift+Return inserts a new line.
