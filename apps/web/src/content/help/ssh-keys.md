---
title: SSH keys and passwords
description: "Choose how Waycar signs in to a Host over SSH: a Device Key made on your phone, an RSA Key, or a password, and how to add the key on your Host."
category: hosts
order: 90
keywords: [authentication, device key, rsa key, authorized_keys, ed25519, public key, keychain, login]
related: [host-keys, pairing, add-host-manually, jump-host]
---

Waycar signs in to each Host over SSH with one of three methods: **Device Key**, **RSA Key** or **Password**. Keys are made on your device and the private key stays in the Keychain. When you pair with a [Pairing Code](/help/pairing), Waycar sets up the key for you.

## Pick a method

Open a Host's page, tap **Edit**, and choose a **Method** under **Authentication**.

| Method | What it is | Use it when |
| --- | --- | --- |
| **Device Key** | An ed25519 key made on your device | Most Hosts. It's the usual choice. |
| **RSA Key** | An RSA key made on your device, signing with RSA-SHA2-512 | The Host only accepts RSA keys. |
| **Password** | Your SSH password for the Host | You can't add a key to the Host. |

## Add your Device Key to a Host

1. In the Host's settings, choose **Device Key**.
2. Tap **Copy authorized_keys Line**.
3. On the Host, add that line to `~/.ssh/authorized_keys`.
4. Tap **Save**.

Every Host using **Device Key** shares the same key, so you add the same line on each one.

## Add your RSA Key to a Host

1. Choose **RSA Key**.
2. Tap **Copy RSA Public Key**.
3. Register the public key wherever the Host accepts SSH identities, usually `~/.ssh/authorized_keys`.
4. Tap **Save**.

## Use a password

Choose **Password** and type it in. When you edit a Host later, leave **Password (blank keeps current)** empty to keep the saved one. Waycar keeps the password in the Keychain.

## Where do my keys live?

The private key stays in the Keychain on your device. With [iCloud Sync](/help/icloud-sync) on, it syncs only to your own devices through iCloud Keychain, along with saved Host passwords.

## Replace a damaged key

If Waycar finds the key is corrupted, the Host's settings show **Device key is corrupted** or **RSA Key is corrupted** with **Replace Device Key** or **Replace RSA Key**. Every Host using that key rejects the new one until you add its new public key on that Host, so plan to update each Host.

## Remove a device's access to your Host

Removing a Host in Waycar only deletes the settings and password on your device. The Host still accepts the key. To cut a lost or sold device off:

1. On each Host, open `~/.ssh/authorized_keys`.
2. Delete the line that ends with `waycar` (the Device Key) or `waycar rsa` (the RSA Key).

With [iCloud Sync](/help/icloud-sync) on, your devices share one key of each kind, so deleting that line locks out all of them. On a device you keep:

1. In iCloud Sync settings, under **SSH Keys**, tap **Replace Device Key…** or **Replace RSA Key…**.
2. Waycar shows the old line under **Remove this line from every Host:** and the new one under **Add this line:**. Tap **Copy New Public Key**.
3. On every Host, replace the old line with the new one.

Also remove the lost device from your Apple Account. The old key keeps working on a Host until its line is removed. Hosts that sign in with **Password** need a password change on the Host instead.

## Jump Host

Through a [Jump Host](/help/jump-host), both machines must accept the same method: both authorize the Device Key or RSA Key, or both accept the same password.

## Troubleshooting

- **Device key unavailable** or **RSA Key unavailable.** Tap **Try Again**.
