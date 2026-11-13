---
title: Can't connect to a Host
description: Fix a Host that won't connect, matched to the message Waycar shows in the Host's checks, from SSH errors to herdr and tmux setup.
category: troubleshooting
order: 10
keywords: [error, offline, ssh, rejected, socket, remote login, timeout, preflight]
related: [hosts, away-from-home, mac-host, linux-host]
---

When a Host won't connect, Waycar runs its checks on the Host's page and shows a message under the one that failed. Find that message below. After a fix, tap **Run Checks Again**.

## "Could not reach the Host over SSH" or "did not answer in time"

Waycar can't open an SSH connection.

1. Check the address and port in the Host's settings.
2. Make sure your phone can reach that network. A machine at home on a private address isn't reachable from cellular. Use a VPN such as Tailscale (see [Use Waycar away from home](/help/away-from-home)) or a [Jump Host](/help/jump-host).
3. On a Mac, turn on Remote Login in **System Settings** › **General** › **Sharing**. See [Set up a Mac as a Host](/help/mac-host).
4. On Linux, make sure the SSH server is running. If it has no host keys yet, run:

```sh
sudo ssh-keygen -A
```

## "The Host rejected the device key" or "rejected the login"

- **Device Key:** copy this Host's key line into `~/.ssh/authorized_keys` on the Host, then run the checks again. Pairing with a Pairing Code does this for you.
- **Password:** check the username and password.
- **RSA Key:** copy its public key from **Edit Host** and add it wherever the Host accepts SSH keys.

See [SSH keys and passwords](/help/ssh-keys).

## "Host key changed"

The Host showed a different key from the one Waycar trusts. A reinstalled server does this, but so can an attack. Check with the Host's owner before you trust the new key. See [Host keys and fingerprints](/help/host-keys).

## "No herdr socket" or "Could not open the herdr socket"

herdr isn't running, or Waycar is looking in the wrong place.

1. Start herdr on the Host.
2. If you use a named herdr session, check the session name in the Host's settings.
3. If herdr is running, check that SSH stream-local forwarding is allowed. Waycar reaches herdr's socket through it. In the Host's `sshd_config`, `AllowTcpForwarding no` blocks it. Set `AllowTcpForwarding local` or `yes`, restart the SSH server, and run the checks again.

## "The Jump Host refused TCP forwarding"

Set `AllowTcpForwarding` to `local` or `yes` in the Jump Host's SSH server configuration. Any message that names the Jump Host is about the first hop; see [Jump Host troubleshooting](/help/jump-host#troubleshooting).

## "The Host speaks herdr protocol …; this app needs at least …"

Your herdr is too old. Waycar needs herdr 0.7.5 or later. Update herdr on the Host. Newer herdr releases keep working.

## "Neither herdr nor tmux was found" or "Waycar needs tmux 3.2 or later"

Install herdr, or install or update tmux to 3.2 or later. Then run the install command again:

```sh
curl -fsSL https://waycar.dev/install.sh | sh
```

## "The Host does not offer RSA-SHA2-512 signatures"

Registering the RSA Key again won't help. Turn on `rsa-sha2-512` on the Host, or choose another way to sign in.

## "The Device Key is corrupted"

Edit the Host and choose **Replace Device Key**. Then add the new public key to `~/.ssh/authorized_keys` on every Host that uses it.

## "No password is saved for this Host" or "Could not load this Host's credentials"

Waycar has no password for this Host on this device, or couldn't read it. Open the Host's page, tap **Edit**, type the password, and save.

## "Could not resolve the remote home directory"

Waycar signed in but couldn't read your account's home folder over SSH, so it doesn't know where herdr's socket is. Check that the account has a working login shell and a home folder, then run the checks again.

## "herdr is not on this Host's SSH PATH"

Your agents show up, but they won't open. The Console reaches herdr through its socket, while opening an agent runs the `herdr` command, and the SSH login can't find it. Waycar already looks in `~/.local/bin`, `/opt/homebrew/bin` and `/home/linuxbrew/.linuxbrew/bin`.

On the Host, in a terminal where `herdr` runs, link it into `~/.local/bin`. Waycar adds that folder to the PATH of its own SSH commands, so the link works even though a plain SSH login doesn't include it:

```sh
mkdir -p ~/.local/bin
ln -s "$(command -v herdr)" ~/.local/bin/herdr
```

Then open the agent again.

## "did not parse" or "answered but rejected the check"

These come from "The server's reply did not parse as herdr protocol.", "herdr answered but rejected the check: …", "tmux's reply did not parse." or "tmux answered but rejected the check: …". herdr or tmux replied in a way this app didn't expect. Update herdr or tmux and the Waycar host tools (see [Update Waycar on your Host](/help/update-host-tools)), then tap **Run Checks Again**.

## "The connection failed unexpectedly" or "The check was cancelled before it finished"

The SSH connection broke during the checks, or they were stopped before they ended. Tap **Run Checks Again**. If it keeps failing, check your network.

## Other messages

For the rows in the Console, the messages over an open agent, and **Detached**, see [What connection messages mean](/help/connection-messages).

## Still stuck?

See [Get help and contact support](/help/get-help), or reach out from [/support](/support).
