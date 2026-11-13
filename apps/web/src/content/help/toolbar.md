---
title: The Toolbar
description: The bar at the bottom of every agent holds your keys, combos, actions, Snippets, and Custom Keys, and you choose and order them in Settings.
category: terminal
order: 40
keywords: [keys, esc, ctrl, custom key, paste, more menu, review paste, multi-line, arrows, function keys]
related: [direct-input, snippets, composer, settings]
---

Every agent has one Toolbar at the bottom of its screen, the same whether you are typing or not. Your items scroll on the left: keys, combos, modifiers, actions, Snippets, and Custom Keys. Fixed buttons sit on the right.

## The fixed buttons

| Button | What it does |
| --- | --- |
| **Message Agent** | Opens the [Composer](/help/composer) to write a message. |
| **Terminal Keyboard** | Raises the keyboard to type straight into the terminal. See [Type straight into the terminal](/help/direct-input). |
| **Dictate to Agent** | Dictates straight to the agent and sends when you stop (iOS 26 and later). See [Dictation](/help/dictation). |

**Dictate to Agent** shows for agents, not shells. Opening the Composer closes the terminal keyboard, and the other way round. These buttons can't be removed or moved.

## What's on the Toolbar at first?

Until you change it, the Toolbar holds Esc, Tab, ⇧Tab, the four arrows, ⌫, ⇧Enter, **Paste**, Enter, **More**, and **Tools Keyboard**. **Reset** brings back this layout.

## What can go on the Toolbar?

- **Keys** such as Esc, Tab, arrows, Backspace, Enter, and F1 to F12. Backspace repeats while you hold it.
- **Combos** such as **⌃C Interrupt**, **⌃D End input**, **⌃Z Suspend**, **⌃L Clear screen**, **⌃R Search history**, **⌃T Transcript**, **⌃O Expand**, **⌃U Clear line**, **⌃W Delete word**, **⌃A Line start**, **⌃E Line end**, and **⌥↵ Option-Return**.
- **Sticky modifiers**: **Ctrl**, **Alt**, and **Shift**. Tap one and it applies to the next key you press; tap it again to cancel.
- **Actions**: **Paste**, **More**, **Tools Keyboard**, **Add Image**, **Add File**, **Skills**, **Snippets**, **Rename Agent**, and more.
- **Snippets**, which insert their text without sending.
- **Custom Keys** you build yourself.

## What's in the More menu?

| Item | What it does |
| --- | --- |
| **Add Image**, **Add File** | Attach to your message. See [Send photos and files](/help/send-files). |
| **Open Terminal** | Opens a shell in the same workspace. See [Shells](/help/shells). |
| **New Agent** | Starts another agent. See [Start a new agent](/help/new-agent). |
| **Skills** | Inserts a Skill into your draft. See [Agent Skills](/help/skills). |
| **Snippets** | Opens your Snippets list to add and edit them. See [Snippets](/help/snippets). |
| **Worktree Details** | Shows the worktree, only for an agent in a linked worktree. See [Worktrees](/help/worktrees). |
| **Mark as Unread** | Marks an Idle agent unread and takes you back to the Console. See [Rename, close, and mark agents](/help/manage-agents). |
| **Rename Agent**, **Rename Workspace**, **Close Agent** | See [Rename, close, and mark agents](/help/manage-agents). |

**Skills** shows only for agents that have Skills. In the Composer, **Add** holds the images and files and **More** holds the rest. Choosing **Add Image**, **Add File**, **Skills**, or **Snippets** from the Toolbar's **More** opens Message Agent first.

## Customize the Toolbar

1. Open **Settings › Toolbar**.
2. Tap **Add Item…** and search keys, combos, and actions, or pick from the lists.
3. Under **Your Items**, drag ≡ to reorder, or touch and hold a row for **Move Up** and **Move Down**. Tap ⊖ to take an item off.
4. Drag the **Spacing** slider between **Compact** and **Wide** to set how far apart the buttons sit.

**Reset** puts back the starting items and spacing. Your Custom Keys stay in the library but come off the bar.

If you remove Enter, Return on the iOS keyboard and Enter on the tools keyboard still send it.

## Build a Custom Key

1. In **Settings › Toolbar**, tap **New Custom Key…**.
2. Enter a **Label** to draw on the key, up to 12 characters, and an optional **Hint**.
3. Choose a **Kind**: a **Key Combo** (a sequence of up to 8 key steps, sent in order) or **Text** such as `/compact`.
4. For Text, turn on **Press Enter After** to send it the way the Send button does. Without it, the key inserts the text like a Snippet.
5. Leave **Add to bar** on to put the key at the end of the Toolbar.
6. Tap **Add**.

A Custom Key that presses Enter only inserts its text while the agent is Blocked.

## Edit or delete a Custom Key

Under **Custom Keys** in **Settings › Toolbar**, each key shows **On the Toolbar** or **Not on the Toolbar**. Tap a key to edit it, then tap **Save**. Swipe a key to delete it, which also removes it from the Toolbar. You can also touch and hold a Custom Key in **Your Items** and choose **Edit Custom Key**.

## Paste

The **Paste** key pastes your clipboard into the agent, or into your draft when Message Agent is open. If the system paste key can't draw, a plain Paste key takes its place, and iOS may ask you to allow each paste from it.

### Pasting more than one line

Text with more than one line doesn't go into the terminal right away. A **Review Paste** sheet shows how many lines and characters it has and a preview. Tap **Paste** to send it or **Cancel** to drop it. This applies to the **Paste** key, the system paste, and dropped text.

Text with terminal control characters is refused with **Paste Blocked**: "The clipboard contains unsafe terminal control characters."

## Good to know

- iPhone and iPad each keep their own Toolbar, with its own layout, spacing, and Custom Keys. A Custom Key built on iPhone does not appear on iPad.
- Each Toolbar syncs through [iCloud Sync](/help/icloud-sync), so a reinstall restores it.

## Troubleshooting

- **Saved toolbar can’t be read**: the Toolbar saved in iCloud came from a Waycar this device can't read, for example a newer version on another device. The default Toolbar shows and editing is paused. Update Waycar on this device. If that doesn't help, tap **Reset Saved Toolbar**, which deletes that saved Toolbar and its Custom Keys.
