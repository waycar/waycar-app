---
title: Notifications don't arrive
description: Fix missing Blocked and Done notifications by checking iOS permission, the Host's Notifications switch, the Waycar plugin, and the push relay.
category: troubleshooting
order: 50
keywords: [push, alerts, blocked, done, permission, relay, notification key, missing]
related: [notifications, live-activities, status-unknown, tmux-hooks]
---

Blocked and Done notifications need three things: iOS lets Waycar notify you, each Host has notifications turned on for this device, and the Host has the Waycar plugin (herdr) or Waycar's host tools (tmux) to send them. Go to Waycar's **Settings** › **Notifications** and work down this list.

## 1. iOS permission

If you see **Notifications are turned off for Waycar.**, tap **Open Waycar Settings** and allow notifications there. If you see **Enable Notifications**, tap it and allow them when iOS asks.

If you see **Could not register for push notifications**, tap **Try Again**. Registration needs a network connection.

## 2. Turn on notifications for each Host

Each Host has its own section. Make sure **Notifications** is on. For finished agents, also turn on **Done Notifications**. Each device registers itself with each Host, so a new iPhone or iPad needs this too, even with iCloud Sync on.

If a Host's section says **Waiting for push registration on this device.**, finish step 1 first.

## 3. Install the Waycar plugin or host tools

If a Host's section says **Install the Waycar plugin on this Host, then check again.**, or asks you to install Waycar's host tools, run this on the Host:

```sh
curl -fsSL https://waycar.dev/install.sh | sh
```

Then tap **Check Again**.

## 4. On tmux: is the agent's status working?

On tmux, Blocked and Done alerts come from Waycar hooks. An agent that shows Unknown in the Console won't send them. See [Agent status shows Unknown](/help/status-unknown).

## 5. Can the Host reach the push relay?

Your Host sends each encrypted notification to Waycar's push relay at `https://waycar-apns.otreva.com`, which forwards it to Apple. If the Host can't make outgoing HTTPS connections to that address, nothing arrives.

Under **Custom Push Relay**, leave the field blank. A custom relay only works with an app you build and sign yourself. Only Waycar's relay can deliver to the App Store app.

## 6. Host can't be reached

Messages like **The Host is not connected.** or **The Host did not answer in time.** mean Waycar couldn't read or change that Host's settings. Fix the connection first. See [Can't connect to a Host](/help/cant-connect).

## Still not working?

On herdr, check on the Host that the Waycar plugin is listed and enabled:

```sh
herdr plugin list --plugin waycar
```

Then read its recent errors:

```sh
herdr plugin log list --plugin waycar --limit 20
```

If you still need help, contact [support](/support).

## Good to know

- Notifications arrive a few seconds after the status change, and quick flips are skipped on purpose. See [When does a notification arrive?](/help/notifications#when-does-a-notification-arrive)
- Live Activity missing or stuck? See [Live Activities aren't updating](/help/live-activities-not-updating).
- If a notification can't be decrypted, Waycar shows a generic message instead of its details.
- Chat Mode replies inside notifications work with herdr only for now.
- To learn what the relay can and can't see, tap **How notifications stay private**, or read [Notifications](/help/notifications).
