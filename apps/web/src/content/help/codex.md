---
title: Waycar with Codex
description: Start Codex server threads from your phone, read replies, approve commands and file changes, and resume chats alongside your desk.
category: hosts
order: 76
keywords: [server, threads, approvals, questions, not running, forwarding, resume, desk, host tools]
related: [new-agent, host-page, closed-sessions, notifications]
---

Codex is a chat-first runtime in Waycar. Threads loaded in your Host's shared Codex server appear as agents in the Console. You can send messages, read replies and answer approvals without opening a terminal.

## Start the server

1. Open the Host's page. It shows **Codex server running** or **Codex server not running**.
2. If it is stopped, tap **Start Codex server**. You can also start it from **New Agent** when you choose **Codex**.
3. If Waycar says **Update Codex to use it here**, update Codex on the Host. You need Codex 0.167 or later.

Checking a Host never starts the server. On a Mac, a start runs in your logged-in session so commands keep Keychain access. If you start the server elsewhere, it appears on the next connection or when you return to Waycar. There is no stopped-server banner in the Console.

To hide its agents on this Host, turn off **Show Codex threads** on the Host's page.

## Start an agent

1. Open **New Agent**, pick the **Host** and choose **Codex** as the runtime.
2. Pick a folder and enter a **Name** if you want one.
3. Add a **First Message**, or leave it empty.
4. Turn on **Chat Mode** to use the **Chat Prompt**, Codex model and **Quick thinking** from **Settings** › **Chat Mode**.
5. Tap **Start**.

The thread always opens as a chat, even with the toggle off. On a Host with Herdr TUI, Herdr Core or tmux, Waycar also opens `codex resume <thread>` in a new Workspace there. Your desk and phone use the same session. On a Host with none of those runtimes, it stays chat-only.

You see one card for the session. Its linked terminal stays out of the Console list. Open it with **Show Terminal** in the chat.

Choosing Codex as the agent inside Herdr TUI, Herdr Core or tmux is different: those launches run on their own, outside the shared Codex server.

## Send a message or stop a turn

Chat shows your prompts, final replies and failures. **Send** starts a turn, or steers the current turn while Codex is working. **Stop** interrupts that turn.

Agents show Working, Blocked, Done or Idle. Blocked means Codex needs approval or an answer.

## Answer an approval or question

- A **Needs your OK** card shows a command or file change. Tap **Allow** to approve it or **Cancel** to decline.
- A **Needs your answer** card shows Codex's questions. Answer them in the card.
- If you answer an approval at your desk, its card disappears from Waycar.

Answers need a connection to the Host.

## Resume an unloaded thread

A thread that nobody has open unloads about a minute after it goes idle. It leaves the live list and becomes a [Closed Session](/help/closed-sessions). Tap **Closed**, then the session, to reopen it. On a Host with a terminal runtime, resume opens its terminal there too.

## Get notifications

[Waycar Host Tools](/help/update-host-tools) 2.4.0 sends notifications when a Codex server thread needs your OK and when it is Done, including its final reply. Updating does not change Codex's installed hook commands. Set `codex_enabled` to `false` in the Host's `notify.json` to silence these notifications.

Codex threads also appear in [Live Activities](/help/live-activities) and on [Apple Watch](/help/apple-watch).

## Troubleshooting

### The server is not running

Tap **Start Codex server** on the Host's page or in **New Agent** › **Codex**. Reconnecting alone never starts it.

### SSH connects but Codex does not

The Host must allow SSH local forwarding, like Herdr TUI. Ask its administrator to allow `AllowTcpForwarding local` or `AllowTcpForwarding yes` in the SSH server configuration.

### A desk session does not appear, or appears twice

Desk Codex sessions started before the server was running stay on their own. Restart them after starting the server to see them in Waycar.

A desk `codex` started while the server runs can show as both a thread and a terminal. Waycar combines them when it finds `codex resume <id>` in the terminal's command line, or there is only one Codex terminal and one thread in that folder. Otherwise both cards can stay visible.
