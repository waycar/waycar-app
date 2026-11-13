---
title: Waycar with OpenCode
description: See every OpenCode 2 session on a Host as a chat, start new ones from your phone, approve commands, answer questions and archive finished work.
category: hosts
order: 78
keywords: [opencode 2, server, sessions, archive, approvals, questions, not running, forwarding, desk, host tools]
related: [new-agent, host-page, closed-sessions, notifications]
---

OpenCode 2 is a chat-first runtime in Waycar. Every session that isn't archived on your Host's shared OpenCode server appears as an agent in the Console, whether you started it at your desk or from your phone. You can send messages, read replies, approve commands and answer questions without opening a terminal.

OpenCode 1 has no shared server. On a Host with OpenCode 1, opencode stays a terminal agent in Herdr TUI, Herdr Core or tmux, as before.

## Start the server

OpenCode starts its server itself the first time you run it on the Host, so it is usually running already.

1. Open the Host's page. It shows **OpenCode server running** or **OpenCode server not running**.
2. If it is stopped, tap **Start OpenCode server**. You can also start it from **New Agent** when you choose **OpenCode**.
3. If Waycar says **Update OpenCode to use it here**, update OpenCode on the Host. You need OpenCode 2.2 or later.

Checking a Host never starts the server. On a Mac, a start runs in your logged-in session so commands keep Keychain access. There is no stopped-server banner in the Console.

To hide its agents on this Host, turn off **Show OpenCode sessions** on the Host's page.

## Start an agent

1. Open **New Agent**, pick the **Host** and choose **OpenCode** as the runtime.
2. Pick a folder and enter a **Name** if you want one.
3. Add a **First Message**, or leave it empty.
4. Turn on **Chat Mode** to use the **Chat Prompt** and the OpenCode model from **Settings** › **Chat Mode**.
5. Tap **Start**.

The session always opens as a chat. On a Host with Herdr TUI, Herdr Core or tmux, Waycar also opens `opencode --session <id>` in a new Workspace there, so your desk and phone use the same session. You see one card for it: open its terminal with **Show Terminal** in the chat.

If a start can't reach the Host, it waits and tries again later with the same session, so you never get a second copy or a repeated first message.

Choosing opencode as the agent inside Herdr TUI, Herdr Core or tmux on an OpenCode 2 Host also joins the shared server, with its own session, and shows as one card.

## Send a message or stop a turn

Chat shows your prompts, replies, tool steps and failures. **Send** starts a turn, or adds your message to the current turn while OpenCode is working. **Stop** interrupts that turn.

Agents show Working, Blocked, Done or Idle. Blocked means OpenCode needs approval or an answer. Done means a turn finished since anyone last looked at the session; opening it in Waycar or at your desk marks it read.

## Answer an approval or question

- A **Needs your OK** card shows a command or a file change. Tap **Allow** to run it once or **Cancel** to decline.
- A **Needs your answer** card shows OpenCode's questions. Pick an option, several where the question allows it, or type your own answer, then submit.
- Requests from a subagent show on the card of the session that started it.
- If you answer at your desk, the card disappears from Waycar.

Answers need a connection to the Host.

## Archive and resume

OpenCode keeps every session, so the list only gets shorter when you archive. Swipe an OpenCode agent and tap **Archive**, or use **Archive** in its menu. Archiving also hides the session from OpenCode's own lists at your desk.

Archived sessions are listed in [Closed Sessions](/help/closed-sessions). Tap one to resume it: Waycar unarchives it and opens its chat, and its terminal too on a Host with a terminal runtime.

## Get notifications

[Waycar Host Tools](/help/update-host-tools) 2.5.0 sends notifications when an OpenCode 2 session needs your OK, asks you a question, or finishes, with its final reply. Several events of one session within a few seconds arrive as one notification with the latest state. Set `opencode_enabled` to `false` in the Host's `notify.json` to silence them.

OpenCode sessions also appear in [Live Activities](/help/live-activities) and on [Apple Watch](/help/apple-watch).

## Troubleshooting

### The server is not running

Tap **Start OpenCode server** on the Host's page or in **New Agent** › **OpenCode**. Reconnecting alone never starts it.

### SSH connects but OpenCode does not

The Host must allow SSH local forwarding to OpenCode's port. Ask its administrator to allow `AllowTcpForwarding local` or `AllowTcpForwarding yes` in the SSH server configuration.

### A desk session appears twice

Waycar combines a desk terminal with its session when the terminal's command line names the session (`opencode --session <id>`), or when there is only one OpenCode terminal and one desk session in that folder. Otherwise both cards can stay visible.
