---
title: Install tmux or herdr on your Host
description: How to install the Herdr TUI, herdr-core or tmux 3.2 on your Host, why Waycar needs one of them, and what to do when the install from the app fails.
category: get-started
order: 25
keywords: [install herdr, install herdr-core, install tmux, no backend, needs admin rights, sudo, no package manager, curl not found, releases.herdr.dev, unsupported system]
related: [requirements, new-agent, herdr-vs-tmux, install-fails]
---

Waycar starts and shows agents inside the Herdr TUI, herdr-core or tmux, so your Host needs one of them. If it has none, install the Herdr TUI (one command, no admin rights), herdr-core (one command, no admin rights) or tmux 3.2 or later, then tap **Check Again** in Waycar. The Install buttons in Waycar come in that order: **Install Herdr TUI**, **Install tmux**, **Install Herdr Core**. Everywhere else in this help, "herdr" means the Herdr TUI.

herdr-core is the runtime under the Herdr app. It also works as a Backend (0.1.10 or later). See [Waycar with herdr-core](/help/herdr-core) for what Waycar does on it. Waycar isn't affiliated with herdr.

## Install the Herdr TUI

herdr's installer is the quickest way. It needs no admin rights and works on Linux and macOS, on x86_64 and aarch64. Run this on the Host:

```sh
curl -fsSL https://herdr.dev/install.sh | sh
```

What it does:

- Downloads the latest herdr release for your system from herdr.dev.
- Checks the download against the SHA-256 checksum in herdr.dev's release manifest, and stops if it doesn't match.
- Writes one file, `~/.local/bin/herdr`, and creates the folder if it's missing. It doesn't edit your shell files and never uses `sudo`.
- Needs `curl`, `awk`, and one of `sha256sum`, `shasum` or `openssl`.

If it prints that `~/.local/bin` isn't in your PATH, add it to your shell profile:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

Waycar already looks in `~/.local/bin` when it checks for herdr, so you can skip that step for Waycar alone.

herdr is a separate project. Waycar isn't affiliated with herdr, and its installer is herdr's own script. Read it first at [herdr.dev/install.sh](https://herdr.dev/install.sh) if you like. For herdr's own install notes, see [herdr.dev](https://herdr.dev).

## Install herdr-core

herdr-core's installer needs no admin rights and works on Linux and macOS, on x86_64 and aarch64. Run this on the Host:

```sh
curl -fsSL https://releases.herdr.dev/core/install.sh | sh
```

What it does:

- Downloads the latest herdr-core release for your system from releases.herdr.dev.
- Checks the download against Herdr's published checksum, and stops if it doesn't match.
- Writes `~/.local/bin/herdr-core`, and creates the folder if it's missing. It also adds an `hc` shortcut there, unless an `hc` already exists. It doesn't edit your shell files and never uses `sudo`.
- Needs `curl` and `tar`, and one of `sha256sum` or `shasum`.
- On a Host that already has herdr-core, it updates it and restarts the core. Waycar reconnects by itself.

Waycar looks in `~/.local/bin` when it checks for herdr-core, so you don't need to change your PATH for Waycar.

Read the installer first at [releases.herdr.dev/core/install.sh](https://releases.herdr.dev/core/install.sh) if you like. Waycar isn't affiliated with herdr, and its installer is Herdr's own script.

## Install tmux

Waycar needs tmux 3.2 or later. Run the line for your system on the Host, then check the version with `tmux -V`.

| System | Command |
| --- | --- |
| Ubuntu, Debian | `sudo apt install tmux` |
| Fedora, RHEL 9 or later, Alma 9 or later, Rocky 9 or later | `sudo dnf install tmux` |
| Arch Linux | `sudo pacman -S tmux` |
| openSUSE | `sudo zypper install tmux` |
| Alpine Linux | `sudo apk add tmux` |
| macOS with Homebrew | `brew install tmux` |

### Old tmux versions

Some releases ship a tmux older than 3.2. Waycar can't use these, so install the Herdr TUI or herdr-core instead:

| System | tmux it ships | What to do |
| --- | --- | --- |
| RHEL, Alma Linux, Rocky Linux 8 | 2.7 | Install the Herdr TUI or herdr-core |
| Ubuntu 20.04 | 3.0a | Install the Herdr TUI or herdr-core, or upgrade Ubuntu |
| Debian 11 | 3.1c | Install the Herdr TUI or herdr-core, or upgrade Debian |
| Ubuntu 22.04 or later | 3.2a or later | Works |
| Debian 12 or later | 3.3a or later | Works |

## When the install from Waycar fails

Waycar can run these installs for you over SSH after you confirm. If one fails, it names the reason. Find it below, fix it, and tap **Check Again**. You can also run the command yourself on the Host with **Copy command**.

### Needs admin rights

tmux comes from your system's package manager, which usually needs `sudo`. Waycar runs `sudo` only when it doesn't ask for a password, and it never asks for one. If your account has no passwordless `sudo`:

- Run the tmux command from the table above yourself, in a terminal on the Host, and type your password there.
- Or install the Herdr TUI or herdr-core. They need no admin rights.

### Can't reach herdr.dev or releases.herdr.dev

The Host couldn't download an installer or its release files. The Herdr TUI's comes from `herdr.dev` and herdr-core's from `releases.herdr.dev`. Check that the Host has internet access and can open both. A firewall, proxy or DNS problem on the Host is the usual cause. Try again once it's fixed, or install tmux instead.

### No curl or no tar

Both installers download with `curl`, and herdr-core's unpacks its download with `tar`. Install what's missing with your package manager, for example `sudo apt install curl tar` or `sudo dnf install curl tar`, then try again.

### No supported package manager

Waycar couldn't find a package manager it can run for tmux. Install tmux yourself using your system's own tools, or install the Herdr TUI or herdr-core. They don't use a package manager.

### Unsupported system

The Herdr TUI's and herdr-core's installers support Linux and macOS on x86_64 and aarch64. They stop on other systems, including Android with Termux. Use tmux 3.2 or later if your system packages it, or point Waycar at a supported machine.

## After the install

- In Waycar, tap **Check Again**. Waycar says the tool is installed only after it finds it on the Host.
- herdr Hosts also need SSH stream-local forwarding. See [Requirements](/help/requirements#ssh-settings).
- To get agent status, alerts and Chat Mode working, run the [Waycar install command](/help/install) on the Host.
- Not sure which to pick? See [herdr vs tmux](/help/herdr-vs-tmux).
