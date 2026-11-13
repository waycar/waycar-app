---
title: Agent card fields
description: Choose which fields each Host's agent cards show in the Console, in up to three rows, from Settings › Agent List Fields.
category: console
order: 40
keywords: [agent list fields, row layout, sync from plugin, custom field, rows, card layout]
related: [console, agent-status, ai-summaries, live-activities]
---

Each agent card in the Console shows up to three rows of fields, such as the Workspace, the agent's name, or its working directory. You choose those fields per Host in **Settings › Agent List Fields**, and every agent on that Host shares them.

## Change the fields on a Host's cards

1. Open **Settings › Agent List Fields**.
2. Tap a Host.
3. Edit **Row 1**, **Row 2** or **Row 3**. The **Console Preview** at the top shows the result as you go.

Changes save right away. In each row:

- Tap **+** to add a field. The sheet lists **herdr fields**, **Waycar fields**, and **Custom field**.
- Tap a field for **Move Left**, **Move Right**, **Remove**, or **Secondary Style** (dimmed text). **Default Style** switches it back.

## Which fields can I add?

Each field shows its herdr name, with a short description beside it in the add sheet:

| Field | Shows |
| --- | --- |
| `state_text` | Status text, shown in the status column, not as a field in the row |
| `workspace` | Workspace or repo folder name |
| `tab` | Tab title |
| `pane` | Pane title |
| `agent` | Agent name |
| `terminal_title` | Current terminal window title |
| `terminal_title_stripped` | Terminal title without the agent prefix |
| `host` | Host name (Waycar field) |
| `status` | Agent status as text (Waycar field) |
| `directory` | Working directory (Waycar field) |
| `runtime` | Runtime the agent runs under — Herdr TUI, Herdr Core or tmux (Waycar field) |

A custom field shows a value that a herdr plugin provides, as plain text. Custom names start with `$` and use 1 to 32 letters, digits, underscores or hyphens.

## What are the three rows?

Row 1 and Row 2 start from herdr's own sidebar fields. Row 3 is Waycar's row. Rows are fixed: you can't add, move or delete a row, and an empty row shows nothing. Every row accepts both herdr and Waycar fields. Each row holds up to 16 fields; when a row is full, its **+** is turned off.

The status badge at the end of Row 1 and the pin mark are always there, whatever fields you pick. Adding `status` as a field repeats it as text.

A value that repeats one already shown earlier in the same row appears once. A herdr worktree's Workspace and tab both carry the branch name, for example, so the row shows it once.

## Start over from herdr's fields

Tap **Sync from plugin** and confirm **Replace Rows**. That Host's rows are replaced with its herdr fields and saved. Row 3 is only filled when herdr defines a third row.

Sync can also tell you "herdr reported a configuration problem, so its default fields were used." or "This Host has no plugin fields snapshot, so Waycar's fallback fields were used." If it can't reach the Host, it says "Couldn't reach <Host>. Rows unchanged." or "You're offline. Rows unchanged." Tap **Retry** once you're connected.

## herdr and tmux

Until you save your own rows, a herdr Host follows the fields its herdr plugin sets. On tmux Hosts the cards use Waycar's built-in layout, and **Sync from plugin** isn't offered for a tmux-only Host. On a Host with both, the editor notes that tmux rows have no plugin fields: they use Waycar's fields until you change the rows, then yours. To see at a glance which runtime owns each agent, add the `runtime` field to a row. See [Waycar with tmux](/help/tmux).

## Good to know

- Pull down on the screen to read the Hosts' herdr fields again.
- Your [Live Activities](/help/live-activities) show the first two rows of each agent's fields.
- The one-line AI summary under a card is separate from these fields. See [AI Summaries](/help/ai-summaries).

## Troubleshooting

If Agent List Fields says **Saved fields can't be read**, Waycar couldn't read your saved rows. Nothing was changed, every Host follows its herdr fields, and editing is paused. To start over:

1. Tap **Reset Saved Fields**.
2. Confirm **Reset Saved Fields** in "Reset saved Agent List Fields?".

The unreadable saved fields are deleted, and every Host returns to its herdr fields and can be edited again.
