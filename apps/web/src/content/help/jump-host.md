---
title: Jump Host
description: Reach a machine that isn't on the open internet by connecting through an SSH Jump Host, with host keys checked at both hops.
category: hosts
order: 40
keywords: [bastion, proxyjump, reverse tunnel, private network, relay, hop]
related: [add-host-manually, host-keys, ssh-keys, cant-connect]
---

A Jump Host lets Waycar reach a machine your phone can't reach directly. Waycar connects to the Jump Host first, a small server that can see your machine, and opens the connection to your Host from there. It checks the host key of each machine separately.

## Set up a Jump Host

1. Tap **Hosts**, then tap **Add Host**. To change an existing Host, open its page and tap **Edit**.
2. Fill in the Host's **Address**, **Port** and **User** as the Jump Host sees them.
3. Under **Jump Host**, enter the **Jump Host address (optional)**.
4. Fill in **Jump Host port** if the Jump Host's SSH doesn't listen on the usual port.
5. Fill in **Jump Host user (blank = same as Host)**, or leave it blank to use the Host's user.
6. Tap **Save**.

Leave the Jump Host address blank to connect to the Host directly.

## Where do the Address and Port point?

The Host's **Address** and **Port** are resolved from the Jump Host, not from your phone. A common setup is a loopback-only reverse tunnel from your machine to the Jump Host, so the Address is something like `127.0.0.1` and the Port is the tunnel's port.

## Signing in on both machines

Both hops use the authentication method you picked for the Host:

| Method | What both machines need |
| --- | --- |
| **Device Key** | Both must authorize the Device Key. |
| **RSA Key** | Both must authorize the RSA Key. |
| **Password** | Both must accept the same password. Separate passwords aren't supported. |

See [SSH keys and passwords](/help/ssh-keys) for how to add your key on each machine.

## Host keys at both hops

On first connect you confirm each machine's host key fingerprint on its own, so you may see **Trust this Host?** twice. If the Jump Host's key changes, Waycar tells you it's the Jump Host's key that changed. See [Host keys and fingerprints](/help/host-keys).

## Good to know

- [Duplicate a Host](/help/hosts#duplicate-a-host) copies its Jump Host settings too.
- With [iCloud Sync](/help/icloud-sync) on, Jump Host settings sync with your Hosts.
- If the Jump Host can't be reached, Waycar reports **Jump Host unavailable**. See [Troubleshooting](/help/jump-host#troubleshooting).

## Troubleshooting

Messages that name the Jump Host are about the first hop. Fix the Jump Host's address, port, user, authorized key, password or host key, not the Host behind it. Then tap **Run Checks Again** on the Host's page.

| Message | What to do |
| --- | --- |
| "Could not reach the Jump Host. Check its address and port." or **Jump Host unavailable** | Check the Jump Host is awake and reachable from your phone, and its address and **Jump Host port**. |
| "The Jump Host rejected the Device Key." | Add this Host's key line to `~/.ssh/authorized_keys` on the Jump Host. |
| "The Jump Host rejected the RSA Key." | Register the RSA Key's public key on the Jump Host. |
| "The Jump Host rejected the login." | The Jump Host must accept the same password as the Host. Separate passwords aren't supported. |
| "The Jump Host rejected authentication" | Update the Jump Host's credentials or authorized key. |
| "The Jump Host's key was not confirmed." or "The Jump Host's key is not trusted" | Run the checks again and confirm the Jump Host's fingerprint. |
| "Jump Host key changed: …" or "The Jump Host's key changed" | Verify the machine with its owner before you trust the new key. See [Host keys and fingerprints](/help/host-keys). |
| "The Jump Host does not offer RSA-SHA2-512 signatures" | RSA Key needs `rsa-sha2-512` on both hops. Turn it on at the Jump Host, or choose another way to sign in. |
| "The Jump Host refused TCP forwarding" or "SSH TCP forwarding is disabled on the Jump Host" | Set `AllowTcpForwarding` to `local` or `yes` in the Jump Host's SSH server configuration. |
| "The Jump Host did not answer in time." | Check the connection and try again. |
| "The Jump Host connection dropped" | Run the checks again. If it repeats, check the Jump Host's network. |
| "Could not connect through the Jump Host. …" | Read the reason after it, and fix it on the Jump Host. |

For other messages, see [Can't connect to a Host](/help/cant-connect).
