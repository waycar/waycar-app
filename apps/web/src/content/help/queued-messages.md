---
title: Queued messages
description: A message you send while your Host is offline waits on your phone as Queued and goes out by itself when the Host is back.
category: agents
order: 90
keywords: [offline, queue, pending, waiting, not connected, cancel, edit, send anyway]
related: [composer, reconnecting, send-files, chat-mode]
---

When you send a message to an agent while its Host isn't connected, Waycar keeps it on your phone as Queued instead of failing. It goes out on its own as soon as the Host is back. You can cancel or edit it while it waits.

## What happens to a queued message?

- It shows **Queued** and its age under the [Composer](/help/composer), and in [Chat Mode](/help/chat-mode), with **Cancel** and **Edit**.
- The agent's row in the Console shows how many messages are waiting.
- Photos and files stay with it, copied onto the phone. They upload before the message is sent.
- It survives closing Waycar.
- Queued messages go out oldest first when the Host is back: after a reconnect, a network change, a return to Waycar, or a launch.

A message that fails before it leaves the phone is queued the same way.

## Cancel or change a queued message

- Tap **Cancel** to delete it.
- Tap **Edit** to take it back into your draft, change it, and send it again. In Chat Mode this button reads **Edit Draft**.

## Why is a message held?

If a different agent now runs in that pane, or no agent was listed when you sent it, Waycar holds the message and offers **Send Anyway**, **Edit**, or **Delete**. If the agent it was for is no longer listed and nothing runs there, you can only edit or delete it. This keeps a message meant for one agent from reaching another one, or a shell.

## Why did a message fail instead of queueing?

If a send may already have reached the Host before the connection dropped, Waycar doesn't queue it. It fails with **Retry** instead, so the same message is never sent twice.

## Good to know

- Changing a Host's address or user deletes its queued messages.
- Queued text is stored on your phone with complete file protection, so it can't be read while the device is locked.
- A queued message shows a dashed outline and a pulsing clock. As it goes out, the clock turns into an arrow and then a check. With Reduce Motion on, these changes are a plain crossfade.
