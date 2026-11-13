---
title: Notifications
description: Get a notification when an agent is Blocked or Done, encrypted on your Host so Waycar's push relay can't read what it says.
category: alerts
order: 10
keywords: [push, alerts, blocked, done, badge, relay, notification key, enable notifications]
related: [live-activities, notifications-not-arriving, ai-summaries, privacy]
---

Agent Notifications tell you when an agent is Blocked and waiting for your input, or when it finishes, while Waycar is in the background or closed. Your Host encrypts each notification before it leaves, so the push relay that hands it to Apple can't read it.

On a herdr-core Host, notifications need Waycar Host Tools and an agent that reports its status to herdr-core. See [Waycar with herdr-core](/help/herdr-core).

For Codex server threads, Host Tools 2.4.0 sends "needs your OK" and Done notifications, including the final reply. The installed Codex hook commands do not change. Set `codex_enabled` to `false` in the Host's `notify.json` to silence them. See [Waycar with Codex](/help/codex).

## Turn on notifications

The first time you come back to the Console after spending time on an agent, Waycar asks once whether to turn on Agent Notifications and Live Activities.

1. Tap **Continue** if iOS hasn't asked about notifications yet, then allow them in iOS's own question. If you already allow notifications, tap **Turn On**.
2. Waycar turns on notifications and Live Activities for every Host on this device, and for Hosts you add later.

Tap **Not Now** and Waycar won't ask again. You can still turn them on later in Settings.

## Choose what each Host sends

Open **Settings**, then **Notifications**. If notifications aren't set up yet, tap **Enable Notifications**. Waycar first shows **Before you turn on notifications**, a short summary of what the push relay can and can't see. Tap **Continue** to get iOS's own notification question.

Each Host has its own section:

- **Notifications** registers this device with the Host.
- **Done Notifications** controls alerts when an agent finishes.
- **Live Activity** shows the Host on your Lock Screen. See [Live Activities](/help/live-activities).

If iOS has notifications turned off for Waycar, the page says so and offers **Open Waycar Settings**.

## What a notification says

The title names the workspace and the kind of agent, such as "my-app · Claude". It doesn't use a custom agent name or the terminal title. The body says Blocked or Done. With [AI Summaries](/help/ai-summaries) on, it carries a one-line summary of what the agent finished or what it needs from you. When a [Chat Mode](/help/chat-mode) agent finishes, its Done notification can carry the agent's final reply. Tap a notification to open that agent.

While Waycar is open, an in-app banner shows instead, with the system alert sound. It follows the Ring/Silent switch. No banner shows for the agent you're already looking at, or for a Host that doesn't have notifications turned on for this device.

## When does a notification arrive?

A few seconds after the status change. Your Host holds each Blocked or Done change for about 5 seconds, then checks again. If the agent has already moved on, nothing is sent, so quick flips are skipped on purpose.

The same status isn't repeated for an agent until it has been in another status. With AI Summaries on, the Host waits for the summary, which can add up to about 15 seconds.

## The app icon badge

The badge on Waycar's icon counts the agents that need your attention, Blocked or Done, across all your Hosts. Plain shells never count. In the background, each Agent Notification brings its Host's current count along, so the badge updates without opening the app. Opening a Done agent lowers it.

## How notifications stay private

Waycar makes a separate Notification Key on your device for each Host. Your Host uses it to encrypt the notification details: project name, task title, Agent Summary, Chat Mode reply, agent type and name, and Host name. The relay never receives the key.

The relay sees your device's Apple push token, the encrypted notification, your Host's IP address, and when your Host sends requests. It keeps no accounts or message history. Tap **How notifications stay private** in Settings, or read the [privacy policy](/privacy).

## herdr and tmux

Both Backends send Blocked and Done notifications. On tmux they come through Waycar hooks. Chat Mode replies in notifications work on herdr only.

## Custom Push Relay

The **Custom Push Relay** field in **Settings** › **Notifications** is for people who build and sign Waycar themselves with their own Apple push credentials. Leave it blank for the App Store app: only Waycar's relay can deliver to it.

Waycar checks the address. An invalid one shows **Enter a valid HTTP or HTTPS URL.** An `http` address shows a warning that it exposes the device token and notification metadata, so use HTTPS except for local development. The address syncs to your other devices with [iCloud Sync](/help/icloud-sync).

## Good to know

- Update Waycar on each Host to get background badge counts. An older plugin still notifies and leaves the badge as it was. See [Update Waycar on your Host](/help/update-host-tools).
- Each device turns on notifications, **Done Notifications** and **Live Activity** per Host by itself, because each device registers with each Host. A **Custom Push Relay** address syncs through iCloud Sync.
- Not getting anything? See [Notifications don't arrive](/help/notifications-not-arriving).
