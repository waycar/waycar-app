---
title: The Agent Footer
description: A line of details under the Toolbar on an agent's terminal, such as its name and directory, and you choose what it shows in Settings.
category: terminal
order: 90
keywords: [show agent footer, home indicator, metadata, branch, git, model, context, cost, tokens, progress]
related: [toolbar, terminal, agent-card-fields, agent-progress]
---

The Agent Footer shows details about the agent in the empty band below the [Toolbar](/help/toolbar) on its terminal screen. At first it shows one line: the agent's name, its directory, and its progress. You choose the fields, up to three lines, and the text size in **Settings** › **Agent Footer**.

## What does it show at first?

One line with the agent's name, directory, and **Progress**, joined by `·`, at Medium size. The footer sits over the band by the home indicator, so the terminal keeps its full size. Fields with no value are skipped, and a line with no values is left out. The footer is on the terminal screen only, not in [Chat Mode](/help/chat-mode).

## Change the footer

1. Open **Settings** › **Agent Footer**.
2. Turn **Show Agent Footer** on or off.
3. Pick **Lines**: **1**, **2**, or **3**.
4. Pick **Text Size**: **Small**, **Medium**, or **Large**. Fewer lines use larger text, and text shrinks if it would not fit the band.
5. Use **Add Field** to add fields to each line. Drag a row to reorder it, or use **Move Up** or **Move Down** in the row's menu. Remove a field with **Remove** in its menu or a swipe.

**Reset** brings back the first layout: one line with the agent's name, directory, and progress.

## Which fields can it show?

| Field | What it shows |
| --- | --- |
| **Agent**, **Directory**, **Workspace**, **Tab**, **Pane**, **Host**, **Status**, **Terminal Title**, **Terminal Title (Raw)** | The same values as the [agent card fields](/help/agent-card-fields). |
| Custom fields | Fields a plugin sets for the agent, shown as `$name`. |
| **Branch** | The git branch checked out in the agent's directory, or a short commit when detached. |
| **Model**, **Context**, **Cost**, **Tokens/s** | The agent's usage figures, for agents that report them. |
| **Backend** | herdr or tmux. |
| **Connection** | SSH or mosh. |
| **Progress** | The [Agent Progress](/help/agent-progress) label, such as **3/7** or **Verifying**, while a Working or Blocked agent has a current estimate. |

## Good to know

- The footer hides while a keyboard is up, either the system keyboard or the Tools keyboard, and comes back when it goes down.
- On iPhone in landscape, only the first line shows.
- On an iPhone or iPad with a Home button there's no room below the Toolbar, so the footer doesn't show.
- On iPad, the footer stops short of the system keyboard and microphone icons at the bottom right.
- A usage figure you put in the footer leaves the [strip above the terminal](/help/terminal#whats-the-strip-above-the-terminal). If you put all four (**Model**, **Context**, **Cost** and **Tokens/s**) in the footer, the strip goes away.
- Waycar reads **Branch** from the Host with git every 30 seconds while an Agent screen with **Branch** on a shown footer line is open. Outside a git repository, the field is left out.
- The layout is kept per device type, so iPhone and iPad each have their own, and it syncs through [iCloud](/help/icloud-sync).
