---
title: Set up a Mac as a Host
description: Turn on Remote Login, install herdr or tmux, then run the Waycar install command to use your Mac as a Waycar Host.
category: get-started
order: 60
keywords: [macos, remote login, ssh, homebrew, mac setup, sharing]
related: [install, pairing, requirements, linux-host]
---

To use a Mac as a Host, turn on Remote Login so Waycar can reach it over SSH, install herdr or tmux 3.2 or later, and run the Waycar install command. Then scan the Pairing Code it shows.

A Mac that runs herdr-core works too. See [Waycar with herdr-core](/help/herdr-core).

## Set up your Mac

1. **Install herdr or tmux.** Get herdr at [herdr.dev](https://herdr.dev), or use tmux 3.2 or later.
2. **Nothing else to install.** Waycar's tools are one native program for Apple Silicon and Intel Macs, so you don't need Node.js or Homebrew for them. The install command checks the download against its SHA-256 before it installs anything.
3. **Turn on Remote Login.** This is macOS's SSH server. Waycar links to Apple's Remote Login help from the **Turn on SSH** step in the app.
4. **Install mosh (optional).** For steadier terminals on spotty networks, install `mosh-server` and let UDP traffic reach it. See [mosh.org](https://mosh.org/#getting).
5. **Run the install command** in a terminal on the Mac:

   ```sh
   curl -fsSL https://waycar.dev/install.sh | sh
   ```

6. **Pair.** Say yes when it offers a pairing QR code, then tap **Scan to Pair** in Waycar. See [Pair with a Pairing Code](/help/pairing).

## Copy the Pairing Code on a Mac

If you can't scan the QR, press `c` on the Mac. The code goes to the clipboard. Get it to your iPhone or iPad and tap **Paste Pairing Code** in Waycar.

## herdr and tmux

With herdr installed, the install command links the Waycar plugin into herdr. In both modes the Pairing Code draws right in the terminal where you ran the command. With tmux 3.2 or later, the command also links `~/.local/bin/waycar`. See [herdr vs tmux](/help/herdr-vs-tmux).

## Troubleshooting

- **"Could not reach the Host over SSH."** Check that Remote Login is on and that you're using the Mac's address and your macOS user name.
- **The herdr checks say herdr isn't running.** Start herdr on the Mac, then tap **Reconnect** on the Host's page.
- **`waycar` isn't found.** Add `~/.local/bin` to your PATH. The install command tells you when it isn't.
