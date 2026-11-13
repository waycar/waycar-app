---
title: Security
description: How Waycar protects your Hosts with on-device SSH keys, pinned host keys, checks at both Jump Host hops, and encrypted notifications.
category: account
order: 40
keywords: [ssh, keychain, ed25519, fingerprint, encryption, post-quantum, host key changed]
related: [ssh-keys, host-keys, jump-host, privacy]
---

Waycar connects straight from your iPhone or iPad to your own machine over SSH, with keys made on your device. No Waycar server sits between you and your Host, and the push relay can't read what your notifications say.

## Your keys stay on your device

Waycar makes your Device Key (ed25519) on your iPhone or iPad, and an RSA Key too if a Host needs one. The private halves are kept in the Keychain and never leave it, except to sync to your own devices through end-to-end encrypted iCloud Keychain. You can turn that sync off on any device. See [SSH keys and passwords](/help/ssh-keys) and [iCloud Sync](/help/icloud-sync).

## Your first connection is already verified

A Pairing Code includes your Host's host key fingerprint. When you scan it, Waycar pins that key, so there's no blind "trust this host?" step. Add a Host by hand and Waycar asks **Trust this Host?** with its fingerprint before it connects.

If a Host later presents a different key, Waycar stops and shows **Host key changed**, with the key it trusted and the one it got. This can be a reinstalled server or an attack. Check with the Host's owner before you trust the new key. See [Host keys and fingerprints](/help/host-keys).

## Checked at both hops

With a [Jump Host](/help/jump-host), Waycar verifies the Jump Host's key and the key of the machine behind it separately. A changed key at either hop stops the connection.

## Post-quantum key exchange

Waycar uses post-quantum hybrid key exchange (`mlkem768x25519-sha256`) when your SSH server offers it.

## Notifications are encrypted on your Host

Waycar makes a separate Notification Key for each Host on your device and copies it to that Host over SSH. Your Host encrypts each notification with it before sending. The push relay forwards the encrypted notification to Apple and never gets the key, so it can't read project names, task titles, summaries or replies. It does see delivery details, and for Live Activities, how many agents are in each status. See [Notifications](/help/notifications).

## Good to know

- Dictation turns speech into text on your device. Nothing is sent, not even to your Host, until you send it.
- No extra port is needed for herdr. Waycar reaches it over your existing SSH connection.
- More on data handling: [Privacy and analytics](/help/privacy) and the [privacy policy](/privacy).
