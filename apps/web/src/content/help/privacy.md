---
title: Privacy and analytics
description: What Waycar keeps on your device, what leaves it, and how to turn usage analytics and AI Summaries on or off.
category: account
order: 30
keywords: [data, tracking, posthog, ai summaries, delete, opt out, share usage]
related: [security, notifications, ai-summaries, icloud-sync]
---

The Waycar app has no accounts, ads or cross-app tracking. Your commands, status updates and live terminals go over SSH or mosh straight from your device to your Host. The only exceptions are optional push notifications, optional usage analytics, and AI Summaries if you turn them on. The waycar.dev website, not the app, measures our Reddit and X ads with their conversion pixels. They load only where the law allows: after you tap Allow in the EU, EEA, UK and Switzerland, never under Global Privacy Control, and not after you tap Decline. Use **Cookie settings** in the website footer to change your choice. The full policy is at [/privacy](/privacy).

## What goes through the cloud?

- **Your sessions don't.** Waycar talks to herdr or tmux on your Host directly. Your SSH credentials and terminal data never touch Waycar's servers.
- **Notifications.** Your Host encrypts each one before it leaves. Waycar's push relay forwards it to Apple and can't read it. See [Notifications](/help/notifications).
- **iCloud Sync.** Hosts and keys sync through end-to-end encrypted iCloud Keychain. See [iCloud Sync](/help/icloud-sync).

## Usage analytics

The first time you open Waycar on a device, it asks **Help make Waycar better?** Nothing is sent until you tap **Allow**. Tap **Don't Allow** and nothing is sent at all.

If you allow it, Waycar sends simple counts, such as "Host added" or "agent launched", tied to a random ID. They never include Host names, addresses, usernames, file paths, commands, prompts, agent names or terminal content. There is no session replay and no advertising identifier.

To change your choice, open **Settings** and turn **Share usage analytics** on or off. Turning it off also deletes this device's analytics ID.

## AI Summaries

AI Summaries are off until you turn them on. When they're on, your Host sends up to the last 60 lines of an agent's screen to an AI model it can already reach, and gets back one sentence about what the agent is doing.

- The request goes from your Host straight to the provider, under your account there. It never passes through Waycar.
- Before they start, Waycar shows what will be sent and to which providers, and asks for your permission.
- Turn them on or off anytime with **AI Summaries** in **Settings**.

Screens can contain secrets such as tokens or file contents, so think about that before turning them on. See [AI Summaries](/help/ai-summaries).

## What stays on your device?

- **Dictation** runs on your device. Audio is never saved or sent, not even to your Host. Text goes to your Host only when you send it.
- **Chat Mode** keeps a copy of each chat's latest messages so it opens right away. It's left out of backups, never synced, and deleted after the agent closes or after 30 days without use.
- **Closed Sessions** keep a record for 30 days, never terminal output. With [iCloud Sync](/help/icloud-sync) on, the records sync through your iCloud Keychain.

## Delete your data

- Removing a Host deletes it and any saved password from your device, and from your other devices while iCloud Sync is on.
- Deleting Waycar removes its files. Keychain items, such as your keys, can stay after the app is gone.
- For a privacy or deletion request, email privacy@waycar.dev. Don't include passwords, keys or Host details.

## Find the privacy policy and open-source notices in the app

Open **Settings** and scroll to **About**:

- **Version** shows your Waycar version and build.
- **Acknowledgements** lists the open-source components Waycar includes, each with its licence. Tap one to read the full notice.
- **Privacy Policy** opens the [privacy policy](/privacy).
