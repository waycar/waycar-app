---
title: Scrolling and jump buttons
description: Drag to scroll an agent's history, jump to the start or back to live output, and step between the messages you sent.
category: terminal
order: 30
keywords: [scroll back, history, live output, beginning, end, previous message, skip]
related: [terminal, select-copy, mosh, supported-agents]
---

Drag an agent's terminal to scroll back through its history. After a long scroll, a jump button takes you the rest of the way to the beginning or back to live output, and a pair of message-jump buttons steps between the messages you sent.

## Jump to the beginning or end

Keep scrolling an agent's terminal and a small up or down tab appears against the right edge, a tenth of the way up from the bottom:

- Scrolling up, the up tab (VoiceOver reads **Scroll to beginning**) takes you back to the start of the conversation.
- Scrolling down, the down tab (**Scroll to end**) takes you down to live output.

The button follows what you are doing, so a short nudge to re-read a few lines does not bring it up. Drag the terminal while it scrolls to stop it partway.

## Jump between your messages

When an agent's history can be scrolled, up and down buttons on the terminal's edge move between the messages you sent:

- Up (**Earlier message**) scrolls to the previous message you sent.
- Down (**Newer message**) scrolls to the next one, then back to live output when there are no more.

Each button shows only when there is somewhere to go in its direction. While a jump runs, its button shows progress.

The buttons stop at every message you sent, including ones typed on the Host. For opencode, pi and omp, Waycar finds them in the agent's own transcript. Kimi CLI, Maki, Hermes Agent and Mastra Code are recognized by their own markers. They skip error panels, input placeholders and drafts, and selection menus.

## Move the message-jump buttons

If the buttons sit where your thumb or the text needs to be, move them:

1. Touch and hold either button until it lifts.
2. Drag it up or down along the terminal's right edge.
3. Let go. Waycar keeps the buttons there on this device.

With VoiceOver, use the **Move up** and **Move down** actions on the buttons. The beginning and end tab stays where it is.

## Good to know

- The message-jump buttons don't appear over [mosh](/help/mosh). mosh sends Waycar its own copy of the screen rather than the agent's, so Waycar can't step through the agent's history that way.
- On herdr, they don't appear in a plain shell either. On tmux, a plain shell that scrolls through copy mode shows them too.
- The buttons work while an agent is still Working, so you can read earlier messages as it goes.
- On herdr 0.9.3 or later, every agent's terminal scrolls. On tmux, an agent that draws inline, such as omp, Gemini CLI or Hermes Agent, and a plain shell scroll through tmux's copy mode. Desk windows on the same pane scroll along until you scroll back to the bottom, type, or send. Codex can't be scrolled from Waycar on tmux. See [Supported agents](/help/supported-agents#what-works-with-each-agent).
