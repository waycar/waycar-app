---
title: Accessibility
description: How Waycar works with VoiceOver, Reduce Motion and larger text sizes, including the VoiceOver actions on cards, Hosts, the Toolbar and attachments.
category: account
order: 50
keywords: [voiceover, reduce motion, dynamic type, text size, screen reader, rotor, actions, a11y]
related: [settings, console, toolbar, terminal]
---

Waycar follows the accessibility settings you turn on in iOS. VoiceOver offers named actions for Waycar's swipes and drags, Reduce Motion replaces movement with fades, and text follows your text size. There are no separate accessibility switches in Waycar's Settings.

## VoiceOver actions

For the swipes and drags below, VoiceOver offers the same thing as an action. Swipe up or down on the item to pick one, then double-tap.

| Where | Actions |
| --- | --- |
| An agent card in the Console | **Close**. VoiceOver then announces the 5-second undo countdown, for example "Closing tab for my-agent in 5 seconds. Undo to cancel." |
| A Host in the Hosts sheet | **Disable** or **Enable** |
| An item in the Toolbar editor | **Move Up**, **Move Down**, **Remove** |
| A photo or file waiting in the Composer | **Retry** (after a failed upload), **Copy Path**, **Remove** |
| A link in Files and Links | **Copy Link** |
| The Earlier and Newer message buttons on the terminal | **Move up**, **Move down** |

See [Rename, close, and mark agents](/help/manage-agents), [The Hosts sheet](/help/hosts), [The Toolbar](/help/toolbar) and [Send photos and files](/help/send-files).

## Leave an agent with VoiceOver

Use the VoiceOver escape gesture (a two-finger scrub) to go back from an agent's terminal to the Console. This works even with **Hide Back Button** turned on in **Settings** › **Terminal Appearance**.

## What does VoiceOver announce while typing?

When you switch how you talk to an agent, VoiceOver says which mode you're in:

- "Message Agent." when the Composer opens.
- "Keyboard. Typing into the Agent." when your keystrokes go straight to the terminal.
- "Message Agent closed." when you close the Composer.

See [The Composer](/help/composer) and [Type straight into the terminal](/help/direct-input).

## Reduce Motion

With **Reduce Motion** on in iOS **Settings** › **Accessibility** › **Motion**, Waycar keeps animation to a minimum. For example:

- Closed agent cards fade out instead of lifting out of the list.
- Queued messages change with a plain crossfade. See [Queued messages](/help/queued-messages).
- A terminal that's opening or reconnecting stays still.

## Text size

Waycar's lists, sheets and Settings follow the text size you choose in iOS. The terminal has its own zoom. See [Terminal themes, fonts, and zoom](/help/terminal-appearance).

A Live Activity on the Lock Screen stops growing at the Large text size, because iOS gives it a fixed height.
