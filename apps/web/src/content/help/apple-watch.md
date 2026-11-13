---
title: Apple Watch
description: See your agents on your wrist, read what one last said, send it a voice message, and approve plain Blocked commands from Apple Watch.
category: devices
order: 60
keywords: [wrist, voice message, allow, deny, blocked, smart stack, latest, watchos, progress]
related: [carplay-voice, live-activities, notifications, agent-progress]
---

The Waycar app on Apple Watch lists your agents with their status, shows what an agent last said, and lets you talk back with a voice message. It works through Waycar on your paired iPhone, so it never connects to your Hosts itself and needs your iPhone nearby.

## What the watch shows

Open Waycar on the watch to see your agents in the same order as in [CarPlay](/help/carplay), Blocked first. Counts at the top show how many are Blocked, Done, and Working, with Idle when there's room. Each row shows the agent's name and a status line, such as "Done · 4m · studio", with the Host name only when you have more than one Host. The watch never cuts text short: long names and status lines wrap onto more lines.

With [Agent Progress](/help/agent-progress) on, a Working agent also shows a thin bar, and its status line says how far it is, such as "Working · 3/7 · 4m". A dotted bar means no estimate yet. The bar dims when the estimate is out of date.

If your iPhone is out of reach, a banner shows "iPhone not reachable", and the footer shows how long ago the list last updated. A Host that is connecting or can't be reached gets its own banner, and its agents dim. Actions are off until your iPhone and the Host are back.

If the watch and iPhone apps are on different versions, the watch asks you to update. With no Host yet, it asks you to add one on your iPhone.

## Read what an agent last said

Tap an agent to open its detail. Under the status line and name, the watch shows **Latest**, always in full. Turn the Digital Crown to keep scrolling.

- When your iPhone can read the agent's chat history, you see its whole last reply. This works for every [Chat Mode](/help/chat-mode) agent and for most other supported agents.
- Otherwise you see the agent's summary from [AI Summaries](/help/ai-summaries).
- While an agent is working, its current summary comes first, with its last reply below under **LAST REPLY**.

A very long reply shows its end, starting with "Earlier text is on your iPhone." If the summary is out of date, the text dims and "Checking…" shows while your iPhone refreshes it. Your iPhone reads this text when you open the agent; the watch doesn't keep it or read it aloud.

## Send a voice message

1. Open an agent and tap the microphone at the bottom.
2. Speak. The watch shows a pulsing microphone but no text while you talk.
3. To send, tap the microphone, double tap with your thumb and finger, or stop talking. After about 3.5 seconds of silence a ring fills around the microphone and the message sends.

Your iPhone turns the recording into text on the device and sends it right away. The watch shows "Transcribing on iPhone…", then your words with "Sending…", "Sent", and "Waiting for reply". There is no review step, so check the sent text for a misheard word.

Nothing is sent if you tap the close button, say nothing in the first 8 seconds, lower your wrist, or leave the app. Recordings stop at 60 seconds and send.

If a message can't be sent, the watch shows "Not sent" with **Try again**, or "Couldn't confirm it was delivered" if Waycar can't tell. A message to an agent that is Blocked, or needs a sign-in or folder trust, stays a [Composer](/help/composer) draft on your iPhone.

## Approve a Blocked command

When an agent is Blocked, its detail shows the full command it wants to run; scroll with the Digital Crown to reach the buttons. The rules match [voice approvals in CarPlay](/help/carplay-voice):

- **Plain approvals**: a Claude Code or Codex command approval that isn't risky shows **Allow** and **Deny**.
- **Risky or partly readable commands**: **Deny** only.
- **Folder-trust prompts, questions, and other prompts**: "Answer this one on iPhone." and nothing is sent.

The buttons change to "Allowed" or "Denied" once your iPhone confirms. If the prompt changed, the watch shows "Prompt changed. Reload." and sends nothing. Waycar never types into a Blocked prompt, so a Blocked agent shows **Review prompt** instead of the microphone. You can't allow a command from a notification.

## Reply from a notification

Tap **Reply** on a Done notification to record a voice message. The watch shows whether it was sent.

Below iOS 26, **Reply** opens a typed reply instead, which needs your iPhone unlocked. If it isn't sent, your iPhone keeps it as a [Composer](/help/composer) draft.

## Live Activities on the watch

Your iPhone's [Live Activities](/help/live-activities) appear in the watch's Smart Stack, one per Host, with its lead count and up to three agents. Tap one to open the agent list.

## Requirements

- A paired iPhone with Waycar, nearby and reachable.
- iOS 26 or later on your iPhone for voice messages without live text. With an older iOS, the microphone opens the watch's standard text input, which may send your speech to Apple. See [Privacy](/privacy).

## Good to know

- Waycar on your iPhone starts in the background when the watch needs it, even if the app is closed or the phone is locked.
- Recordings are deleted from both devices once they're sent or abandoned.
