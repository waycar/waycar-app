---
title: Install Waycar on your Host
description: One command on your Mac or Linux machine finds herdr or tmux, installs the Waycar host tools, and offers to show a Pairing Code.
category: get-started
order: 30
keywords: [install command, curl, plugin, host tools, setup, install.sh, no-hooks, no-pair, unattended, custom directory]
related: [pairing, requirements, install-fails, update-host-tools]
---

Run one command on each machine you want to use with Waycar. It finds herdr or tmux, installs the Waycar host tools, and offers to show a Pairing Code so you can add the machine in the app. The same command works for herdr, tmux, or both.

## Run the install command

1. Open a terminal on the Host. Make sure you have [what Waycar needs](/help/requirements): herdr or tmux, plus `curl` and `tar`. You don't need Node.js.
2. Run:

   ```sh
   curl -fsSL https://waycar.dev/install.sh | sh
   ```

3. The first time, it asks whether to install the host tools or pair this computer only. Press Return to install, or type `2` to pair without installing anything (see [Pair without installing](#pair-without-installing)). Invalid answers ask again; Ctrl-D cancels without installing.
4. When it asks to show a pairing QR code, press Return (or type `y`); the code draws right in the terminal. Then [pair with the Pairing Code](/help/pairing).

You can also copy the command from **Set up by hand** on the **Add Your First Host** screen in the app. Tap it to copy; a Mac signed in to the same Apple Account can paste it.

## What does it install?

The command downloads the Waycar package, checks its SHA-256 checksum, and unpacks it to `~/.local/share/waycar/plugin`. Then:

- **With herdr on your PATH**, it links the Waycar plugin into herdr.
- **Without herdr but with tmux 3.2 or later**, it sets Waycar up for tmux. With an older tmux and no herdr, it stops and asks you to install one of them.
- **With tmux 3.2 or later**, it links the `waycar` command at `~/.local/bin/waycar` and installs Waycar hooks for every supported agent already on the Host, so tmux agents report their status. See [Waycar hooks for tmux](/help/tmux-hooks).
- **With only herdr-core on the Host**, it installs the Host Tools on their own: the `waycar` command and the hooks, with no herdr plugin. See [Waycar with herdr-core](/help/herdr-core).
- **With opencode or Kilo Code on your PATH**, it installs a small extension for it that [Chat Mode](/help/chat-mode) uses.

If `~/.local/bin` isn't on your PATH, the command tells you to add it.

Before pairing, the command prints whether it found Tailscale on this computer. This check installs nothing and does not change your network. Tailscale is optional on the Host: a Tailscale subnet router on one other device at home can give your phone access to your home network.

## herdr and tmux

The pairing offer draws the Pairing Code right in the terminal, on herdr and tmux Hosts alike. To set Waycar up for tmux on a machine that also has herdr, add `--tmux`:

```sh
curl -fsSL https://waycar.dev/install.sh | sh -s -- --tmux
```

To skip the agent hooks and the Chat Mode extensions, add `--no-hooks`. You can add the hooks later with `waycar hooks install`. On a herdr Host without tmux 3.2 or later, there's no `waycar` link; see [The waycar command on your Host](/help/waycar-command#where-is-it).

## Pair without installing

On a machine where you may not install software, answer `2` at the question, or add `--pair-only`:

```sh
curl -fsSL https://waycar.dev/install.sh | sh -s -- --pair-only
```

The command downloads the Waycar package to a temporary folder, shows the Pairing Code from there, and deletes the folder again. Nothing is installed: no plugin, no `waycar` command, no hooks. Pairing itself still writes the Device Key line to `~/.ssh/authorized_keys`; that is how the Host accepts your device. Pairing works on a machine that already has herdr or tmux 3.2 or later: the phone attaches through the existing backend, though without the host tools there are no agent status hooks or notifications. On a machine with neither, pairing succeeds but the app can't open a console until one of them is installed. To add the host tools later, run the install command again and choose install.

The Pairing Code screen itself shows whether a device enrolled, with an option to revoke it before closing; the script only reports that the session closed and nothing was installed.

The question only appears on a fresh machine with a terminal. Without a terminal, when updating an existing install, with `WAYCAR_NO_PAIR` set, or with `WAYCAR_PLUGIN_SOURCE` set, the command installs as it always did.

## Install options

Flags go after `sh -s --`, as in the `--tmux` example above. Environment variables go right before `sh` in the install command, for example `WAYCAR_NO_PAIR=1 sh`.

| Option | What it does |
| --- | --- |
| `--tmux` | Sets Waycar up for tmux even when herdr is installed. |
| `--no-hooks` | Skips the agent status hooks and the opencode and Kilo Code Chat Prompt extensions. |
| `--pair-only` | Pairs without installing anything: shows the Pairing Code from a temporary download and never asks the install-or-pair question. |
| `WAYCAR_PAIR_ONLY` | Set to anything for the same as `--pair-only`. |
| `WAYCAR_NO_PAIR` | Set to anything to skip the pairing prompt and the install-or-pair question, for scripted or dotfiles installs. |
| `WAYCAR_PLUGIN_DIR` | Installs to this absolute folder instead of `~/.local/share/waycar/plugin`. It can't contain a double quote, backslash or newline, and Waycar won't replace a folder that holds something else. |
| `WAYCAR_INSTALL_BASE_URL` | Downloads the package from this address instead of `https://waycar.dev`. |
| `WAYCAR_PLUGIN_SOURCE` | Installs from a local plugin folder (a checkout's `plugin/` or an unpacked package) instead of downloading. For testing. |

## Good to know

- Install agents first. Installed one later? Run the install command again so it gets its hooks.
- Codex asks you to review new hooks once, on its `/hooks` screen, before they turn on.
- Running the command again updates Waycar and keeps your pairing and notification keys. See [Update Waycar on your Host](/help/update-host-tools).
- For mosh, also install `mosh-server` on the Host. See [mosh](/help/mosh).
- The command stopped with an error or printed a warning? See [The install command fails](/help/install-fails).
- To uninstall, see [Remove Waycar from a Host](/help/remove-host-tools).
