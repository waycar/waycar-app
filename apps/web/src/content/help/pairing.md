---
title: Pair with a Pairing Code
description: Scan or paste the Pairing Code your Host shows to add it to Waycar, with your key made on the device and the host key already pinned.
category: get-started
order: 40
keywords: [qr code, scan to pair, paste pairing code, waycar pair, pair device, camera, add host]
related: [install, add-host-manually, host-keys, ssh-keys]
---

A Pairing Code is a QR code your Host shows so you can add it to Waycar in one scan. Waycar makes your SSH key on the device, adds it to the Host, and pins the Host's key from the code, so there is no "trust this host?" prompt.

## Show a Pairing Code on your Host

The [install command](/help/install) offers to show one when it finishes. Press Return to say yes: the code draws right in the terminal, on herdr and tmux Hosts alike. To pair another device later, run the install command again, or:

- Run `waycar pair`. The Pairing Code shows right in the terminal. On a herdr Host without tmux 3.2 or later there is no `waycar` link; run `~/.local/share/waycar/plugin/bin/waycar pair` instead.
- On herdr, you can also open herdr's actions and choose **Pair a mobile device** (or run `herdr plugin action invoke waycar.pair`). That route opens the code in a popup in the herdr window, not your terminal, and herdr must be running.

First the checklist, titled **Pair a Waycar device**, lists the Host's addresses. Your home network address is already checked, and so is the Host's Tailscale address if it has one (a Host on an older plugin checks one address). Return is often enough. Otherwise check the ones your phone can reach, then press Return.

| Key | Action |
| --- | --- |
| up/down or `j`/`k` | Move |
| space | Check or uncheck an address |
| `a` | Check all |
| Return | Confirm and show the code |
| `q`, Esc or Ctrl-C | Close the screen |

Closing the pairing screen cancels the code, so keep it open until Waycar finishes. On the full-size QR, any key except `c` closes it; on the compact QR, only `q`, Esc or Ctrl-C.

## Scan it in Waycar

1. In Waycar, tap **Scan to Pair**. With no Host yet, it's on the **Add Your First Host** screen.
2. Point the camera at the Pairing Code on your Host.
3. Waycar reads the code, reaches the Host, enrolls this device, and verifies the new key. Your agents appear.

Can't scan? Press `c` on the Host. On a Mac that copies the code; on Linux it shows the code so you can select and copy it. Then tap **Paste Pairing Code** in Waycar.

## What happens on the Host?

When your device enrolls, the Host shows **Device paired** with the key's fingerprint. If that wasn't you, press `r` to revoke the device.

## herdr and tmux

Pairing works the same on both: `waycar pair` draws the code in the terminal on a herdr Host and a tmux Host alike. On a Host set up for tmux, the install command also prints a line for `~/.tmux.conf` that binds a key to pairing. When `~/.local/bin` is on your PATH, it is:

```text
bind W display-popup -E "waycar pair"
```

Otherwise it uses the full path to `waycar`, so copy the printed line.

## Troubleshooting

- **"Pairing Code expired".** A code lasts two minutes. Press Return on the Host for a new one.
- **The QR doesn't fit.** The pairing screen draws a compact QR when it can. Otherwise zoom out, enlarge the window, or press `c` and paste the code.
- **Camera Access Needed.** Tap **Open Settings** and allow camera access, or tap **Add Manually**.
- **Scanning Unavailable.** This device can't scan QR codes. Tap **Paste Pairing Code**, or add the Host by hand.
- **My SSH server isn't on port 22.** A Pairing Code always uses port 22. [Add the Host by hand](/help/add-host-manually) and enter its **Port**.
- **Pairing still fails on herdr.** Check the Waycar plugin with `herdr plugin list --plugin waycar` and its errors with `herdr plugin log list --plugin waycar --limit 20`. See [Notifications don't arrive](/help/notifications-not-arriving#still-not-working).

### Messages in Waycar

**Try Again** reuses the same code. When Waycar offers only **Scan Again**, show a new code on the Host first.

| Message | What to do |
| --- | --- |
| "The Host did not answer at any of its addresses." | Join the Host's network or VPN, then try again with the same code. See [Can't connect to a Host](/help/cant-connect). |
| "The Host rejected this Pairing Code." | Codes work once and stop when they expire or the pairing screen closes. Show and scan a new code. |
| "The Host has no pairing in progress for this code." | Show a new code and scan it. |
| "That QR code is not a herdr Pairing Code." | Scan the code the Host's pairing screen shows. |
| "This Pairing Code uses version …, which this app does not understand." | Update the app and the Waycar host tools so they match. See [Update Waycar on your Host](/help/update-host-tools). |
| "The Pairing Code could not be read." | Show the code again on your Host and scan again. |
| "The Host did not accept this device's key." | Try again. If it keeps failing, update the app and the host tools. |
| "The Host refused Enrollment (…)." | Update the app and the host tools, then show a new code. |
| "This device's key never reached the Host." | Try again with the same code. |
| "Enrollment did not complete, likely a network hiccup." | Try again with the same code. |
| "This device was enrolled, but the verifying reconnect did not get through." | Try again to finish with the enrolled key. |
| "The Host did not accept the Device Key, so it is not authorized there yet." | Add this device's `authorized_keys` line on the Host, or show a Pairing Code on your Host instead. |

### Messages on the Host

| Message | What to do |
| --- | --- |
| **Pairing cannot start**: "No SSH host key found under /etc/ssh." | On a Mac, turn on Remote Login in **System Settings** › **General** › **Sharing**. On Linux, run `sudo ssh-keygen -A`. Then start pairing again. |
| **Pairing cannot start**: "No routable network address found." | Connect the Host to a LAN or VPN and retry. |
| "Select at least one address." | Check an address with space before you press Return. |
| **Could not revoke the Device Key** | Remove the enrolled line from `~/.ssh/authorized_keys` on the Host by hand. |
