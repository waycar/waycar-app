---
title: Approve commands by voice
description: In CarPlay, allow or deny a Claude Code or Codex command approval out loud, and leave risky or long commands for later.
category: devices
order: 50
keywords: [allow, deny, hold, approval, blocked, risky, driving, yes/no, trust, correction]
related: [carplay, carplay-voice-not-working, agent-status, notifications]
---

When a Claude Code or Codex agent is waiting on a plain yes or no command approval, Waycar in [CarPlay](/help/carplay) on your iPhone can read the command to you and let you allow or deny it by voice. Waycar won't allow commands that look risky, or are too long to read out, from the car. You can deny them or tap **Hold** to leave them for later.

## Answer an approval

1. Tap a Blocked agent in CarPlay.
2. Waycar names the agent and reads the command: "*agent* is waiting on approval to run *command*. Allow or deny?"
3. Say "allow" or "deny", or tap **Allow** or **Deny**.

Waycar confirms with "Allowed." or "Denied." If it didn't hear you, it asks again.

With no connection to the Host, Waycar says "No connection. Allow is queued and will go out if the prompt is still the same." (or Deny). It sends the answer once the Host is back, only if the agent still shows the same prompt, and posts a notification saying how it went. A queued answer is kept for 10 minutes and is lost if Waycar quits. The Apple Watch doesn't queue.

## Tell the agent what to do instead

Instead of "allow" or "deny", say what the agent should do instead, in more than one word. Waycar reads it back as "Tell *agent*: … Send?". Say "send" or tap **Send** to deny the command and send your instructions. Tap **Cancel** to keep them as a draft instead.

Waycar always denies the command first, then sends your instructions once the agent is no longer Blocked. If that doesn't happen within about 8 seconds, Waycar says "Denied. I couldn't send the correction; it's in the draft." Open the agent on your phone to send it later. If Waycar can't tell whether the instructions arrived, it says "Denied. Couldn't confirm the correction was delivered. Not resending." Check the agent before you send them again.

## Which approvals wait?

- **Risky commands**: Waycar says why the command looks risky and "I'll hold it until you're stopped." You get **Deny** and **Hold**, but not **Allow**. **Hold** leaves the approval waiting; Waycar doesn't bring it back on its own.
- **Long commands**: if a command is too long to read out, Waycar offers **Deny** and **Hold** the same way.
- **Folder-trust and other questions**: Waycar says what kind of question the agent is asking, such as a folder-trust or multiple-choice question, but doesn't read the question and won't answer it from the car.
- **Yes/no questions**: for a Codex `[y/n]` question, Waycar says "*agent* is asking a yes/no question I can't answer from the car."
- **Unreadable prompts**: if Waycar can't read the prompt, it says "*agent* is blocked, but I couldn't read its prompt. I'll leave it for later."

Shell symbols are spoken as words, such as "pipe" and "semicolon", so you hear exactly what would run.

## Which agents?

Voice approvals work for Claude Code and Codex agents. For other agents, Waycar only says that the agent is waiting on a prompt it can't answer from the car.

## Good to know

- If the prompt changes while you're answering, Waycar tells you and reads the new one.
- Nothing the agent writes is shown on the car's screen.
