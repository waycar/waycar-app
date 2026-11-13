---
title: iCloud Sync
description: Keep your Hosts, SSH keys, trusted fingerprints and settings in step across your iPhone and iPad through end-to-end encrypted iCloud Keychain.
category: account
order: 10
keywords: [keychain, ipad, apple account, replace key, devices, passwords]
related: [ssh-keys, host-keys, settings, privacy]
---

iCloud Sync keeps your Waycar setup the same on every iPhone and iPad signed in to your Apple Account. It stores your Hosts and keys in iCloud Keychain, which is end-to-end encrypted, so neither Waycar nor Apple can read them. There is no Waycar account. iCloud Sync is on by default.

## What syncs

With **Sync with iCloud** on, these go to your other devices:

- Hosts and their saved passwords
- Your SSH keys (one Device Key and one RSA Key, shared by all your devices)
- Trusted host fingerprints
- Snippets
- Closed Sessions (forget one, and it's forgotten on every device)
- Pins. See [Filter, search, and pin](/help/filter-search-pin).
- Disabled Hosts, and each Host's New Agent backend and **Show tmux sessions** choice
- Your answers to each Host's Waycar plugin rows in the Console (**Not now**, **✕**, and **Remind me to install Host Tools**). They also come back with your Hosts if you delete and reinstall Waycar.

These settings sync too:

- **Agent List Fields**
- **Toolbar**, kept separately for iPhone and iPad
- **Agent Footer**, kept separately for iPhone and iPad
- **Appearance** (System, Light or Dark)
- In **Terminal Appearance**: the terminal font, the Light and Dark terminal themes, and **Hide Back Button**
- **Custom Push Relay**, under **Notifications**
- **AI Summaries** on or off
- **Chat Mode**: **Chat Prompt**, each agent's model, **Quick thinking**, and the New Chat Host, Workspace and agent

## What stays on each device

- Notifications and Live Activities. Each device registers itself with each Host, and Live Activity choices stay on the device.
- Terminal zoom and the position of floating buttons.
- The Console's collapsed sections and grouped or flat view, recent choices, and unread marks.
- **CodexBar** display options, **Share usage analytics** and **CarPlay Voice**.
- Notification Keys. They never sync.

## What you need

1. Use the same Apple Account on each device.
2. Turn on two-factor authentication for that Apple Account.
3. Turn on iCloud Keychain: open iOS **Settings**, tap your name, then **iCloud** › **Passwords and Keychain** (**Passwords** on newer iOS).

Waycar can't see that iOS switch. If your Hosts don't appear on another device, check it there first.

## How fast does it sync?

Waycar checks when it opens, when you come back to it, and every 30 seconds while it's open. Changes from another device arrive once iCloud Keychain delivers them, usually within a minute. To check right away, go to **Settings** › **iCloud Sync** and tap **Check Now**. **Last Checked** shows when it last looked.

## Turn off iCloud Sync on one device

1. Open **Settings** › **iCloud Sync**.
2. Turn off **Sync with iCloud**.

This device keeps its Hosts, passwords and SSH keys and stops syncing them. The copies already in iCloud Keychain stay there for your other devices. Turn it back on later and this device publishes its Hosts again. If turning it off fails, Waycar offers **Turn Off Anyway**.

## Lost a device? Replace your key

Your devices share one SSH key of each kind. If a device is lost:

1. Remove it from your Apple Account.
2. In **Settings** › **iCloud Sync**, tap **Replace Device Key…** (or **Replace RSA Key…**) and confirm.
3. Tap **Copy New Public Key**. On every Host, replace the old public key line in `~/.ssh/authorized_keys` with the new one.

Every device switches to the new key. The old key keeps working on a Host until you remove its line there.

## A Host stopped accepting one device after sync

If you used Waycar on two devices before sync, each had its own Device Key. After sync, both use one shared key. A Host that trusted only the other device's old key won't let this one in. Add the shared public key to `~/.ssh/authorized_keys` on that Host (the Host form shows it), or pair again with a [Pairing Code](/help/pairing). See [SSH keys and passwords](/help/ssh-keys).

## Good to know

- Removing a Host removes it, and any saved password, from your other devices too.
- Before you give a device to someone else, turn off **Sync with iCloud** on it. A device that signs in to a different Apple Account copies what it still holds into that account's iCloud Keychain.
- Only the App Store and TestFlight versions of Waycar share synced items. A copy built from source with a different bundle ID doesn't.
- If two devices change the same item, one change wins.
