---
title: The install command fails
description: What each error and warning from the Waycar install command means, and how to fix it so the host tools install on your Host.
category: troubleshooting
order: 5
keywords: [install.sh, error, warning, checksum mismatch, download failed, curl not found, too old]
related: [install, install-tmux-or-herdr, requirements, waycar-command]
---

When the install command can't finish, it stops with a line that starts with `waycar: error:`. Warnings start with `waycar:` and let the install continue. Find the message below to see what it means and how to fix it, then run the install command again:

```sh
curl -fsSL https://waycar.dev/install.sh | sh
```

## Errors that stop the install

| Message | What it means | Fix |
| --- | --- | --- |
| `cancelled; nothing was installed` | Ctrl-D or the end of terminal input cancelled the install-or-pair question. | Run the command again when ready, then choose `1` to install or `2` to pair only. |
| `neither herdr, herdr-core nor tmux found on PATH; install herdr (https://herdr.dev), herdr-core or tmux 3.2 or later` | The Host has no Backend Waycar can use. | Install herdr or tmux 3.2 or later. The installer also accepts herdr-core. See [Install tmux or herdr on your Host](/help/install-tmux-or-herdr). |
| `herdr not found, and tmux … is too old; install herdr (https://herdr.dev), herdr-core or tmux 3.2 or later` | tmux is there but older than 3.2, and neither herdr nor herdr-core is. | Update tmux to 3.2 or later, or install herdr. See [Install tmux or herdr on your Host](/help/install-tmux-or-herdr). |
| A line saying the new tools won't run on this Host | The install command tried the native Waycar program before it replaced anything, and it didn't start. Your old install is still in place. | Run the command again. If it keeps failing, see [Get help and contact support](/help/get-help) and include the full output. |
| `curl not found` or `tar not found` | The command needs both to download and unpack the package. | Install curl and tar with your package manager. |
| `sha256sum or shasum required to verify the download` | Waycar can't check the package's checksum. | Install `sha256sum` (coreutils) or `shasum`. |
| `download failed: …` | The package didn't download. | Check the Host's internet connection and try again. |
| `checksum mismatch for …` | The downloaded package isn't the one published with the script. | Run the command again. If it keeps failing, something between the Host and waycar.dev is changing the download. |
| `… exists and is not the Waycar plugin; move it or set WAYCAR_PLUGIN_DIR` | Something else lives in the install folder. Waycar never overwrites it. | Move that folder, or pick another one with `WAYCAR_PLUGIN_DIR`. See [Install options](/help/install#install-options). |
| `WAYCAR_PLUGIN_DIR must be an absolute path` | The custom install folder is relative. | Use a full path starting with `/`. |
| `WAYCAR_PLUGIN_DIR must not contain a double quote, backslash or newline …` | The folder name has a character Waycar can't use. | Choose a folder without those characters. |
| `pair-only needs an interactive terminal (it shows a Pairing Code QR); run it in a terminal` | `--pair-only` shows the Pairing Code in the terminal, so it needs one. | Run the command in a terminal, not from a script. |
| `--pair-only installs nothing; --tmux and --no-hooks do not apply` | `--pair-only` was combined with `--tmux` or `--no-hooks`. | Use `--pair-only` on its own. |
| `unknown option: … (expected --tmux, --no-hooks or --pair-only)` | The command got a flag it doesn't know. | Use only `--tmux`, `--no-hooks` or `--pair-only`. |
| `herdr plugin link failed` or `could not remove the existing waycar plugin` | herdr refused to link or replace the Waycar plugin. | Run `herdr plugin list` to see what's installed, remove the old `waycar` plugin by hand, then run the command again. |
| `package is missing herdr-plugin.toml` | The unpacked package is incomplete. | Run the command again. |
| `WAYCAR_PLUGIN_SOURCE is not a directory: …` or `… is not the Waycar plugin (no herdr-plugin.toml with id "waycar")` | Only with `WAYCAR_PLUGIN_SOURCE`: the local folder isn't a usable Waycar plugin. | Point it at an unpacked package. |

## Warnings

| Message | What it means | Fix |
| --- | --- | --- |
| `warning: agent status hooks were not installed; retry: … hooks install` | The plugin installed, but adding the Status Hooks failed. | Run the `hooks install` command it prints. See [Waycar hooks for tmux](/help/tmux-hooks). |
| `…/.local/bin/waycar exists and is not a link; leaving it (run … instead)` | Another file already uses the name `waycar`. | Run the full path it prints, or move the other file and run the install command again. |
| `add …/.local/bin to your PATH to run waycar` | The `waycar` command is installed but your shell can't find it. | Add `~/.local/bin` to your PATH in your shell profile. |
| `tmux 3.2 or later not found (found …); agent status hooks not installed` | You used `--tmux` and `--no-hooks` on a Host whose tmux is older than 3.2. | Update tmux to 3.2 or later and run the command again. |
| `… exists and was not installed by Waycar; left unchanged` | An omp, pi or opencode extension file with Waycar's name already exists, and Waycar didn't write it. From the hooks, the line starts with the agent's name and `error:`. | If you don't need that file, move it away, then run the command again. |
| `pairing did not finish; run: … pair` | `waycar pair` stopped with an error, for example **Pairing cannot start** because the Host has no SSH host key or no network address. Closing the Pairing Code yourself doesn't print this. | Fix what the pairing screen reported (see [Messages on the Host](/help/pairing#messages-on-the-host)), then run the command it prints. |
| `pairing did not finish; run the install command again and choose pair only` | Pairing without installing stopped with an error, for example **Pairing cannot start** because the Host has no SSH host key or no network address. Closing the Pairing Code yourself doesn't print this. | Fix what the pairing screen reported (see [Messages on the Host](/help/pairing#messages-on-the-host)), then run the install command again and choose pair only. |

## Still stuck?

Run the command again and keep the full output. See [Get help and contact support](/help/get-help).
