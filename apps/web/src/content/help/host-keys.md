---
title: Host keys and fingerprints
description: How Waycar checks that it's talking to your real machine, with the host key pinned by the Pairing Code or confirmed on first connect.
category: hosts
order: 100
keywords: [trust this host, sha256, known hosts, key changed, trust new key, verify, post-quantum]
related: [ssh-keys, pairing, jump-host, security]
---

Every SSH server has a host key that proves which machine it is. Waycar checks that key on every connection, so it only talks to the machine you trusted. A Pairing Code already carries the key's fingerprint, so a paired Host is verified from the first connection.

## Paired with a Pairing Code

The [Pairing Code](/help/pairing) includes the Host's host key fingerprint, and Waycar pins it when you scan. There's no blind "trust this host?" prompt.

## Added by hand: Trust this Host?

When you [add a Host by hand](/help/add-host-manually), Waycar asks **Trust this Host?** as soon as its page opens. The prompt shows the address and the key fingerprint, in the form `SHA256:...`.

1. On the Host, print its fingerprint, for example:

   ```sh
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```

2. Check that it matches the one in the prompt.
3. Tap **Trust**. If it doesn't match, tap **Don't Trust**.

The prompt waits for your answer as long as you need. Tapping **Trust** late still connects.

## Skipped the prompt or tapped Don't Trust?

Until you trust the key, the Host doesn't connect. The Console shows "Waiting for you to trust <Host>'s host key", or "Waiting for you to trust the Jump Host's host key for <Host>". On the Host's page, the **SSH connection** check reads "The host key was not confirmed. Run the checks again and confirm the fingerprint." Leaving the page while the prompt is open counts as **Don't Trust**.

1. Tap the waiting row in the Console, or open the Host from **Hosts**.
2. Tap **Run Checks Again** or **Reconnect**. **Reconnect** reruns the checks first, so **Trust this Host?** appears again. For a changed key, **Trust New Host Key** appears instead.
3. Verify the fingerprint and tap **Trust**.

Once the checks pass, the Host connects on its own. You don't need to tap anything else. See [A Host's page and checks](/help/host-page).

## What if the host key changes?

If a Host presents a different key from the one you trusted, Waycar won't connect. You see both fingerprints, the trusted one and the presented one, and **Trust New Host Key**. Confirming it asks **Replace the trusted Host key?** with **Trust New Key**.

A changed key can mean you reinstalled the Host, or it can mean an attack. Only trust the new key when you know why it changed.

## Jump Host

Through a [Jump Host](/help/jump-host), Waycar checks the Jump Host and the machine behind it separately. You confirm each one's fingerprint on first connect, and a changed key on either one stops the connection.

## Good to know

- With [iCloud Sync](/help/icloud-sync) on, trusted host key fingerprints sync to your other devices.
- Waycar uses post-quantum key exchange when your server supports it.
- More on how Waycar protects your connection: [Security](/help/security).
