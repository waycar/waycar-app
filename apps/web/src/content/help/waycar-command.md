---
title: The waycar command on your Host
description: Every waycar subcommand on your Host, from pair and status to hooks, notify and watch-approval, plus the herdr plugin actions Waycar adds.
category: hosts
order: 85
keywords: [cli, terminal, waycar pair, waycar status, waycar version, hooks, herdr plugin action, waycar.pair]
related: [tmux-hooks, update-host-tools, pairing, install]
---

The install command puts a `waycar` command on your Host. You use it to pair a device, check what's installed, and manage the Status Hooks. Some subcommands are run by Waycar itself and its hooks, so you rarely need them.

## Where is it?

On a Host with tmux 3.2 or later, the install command links it at `~/.local/bin/waycar`, so `waycar` works once `~/.local/bin` is on your PATH. On a herdr Host without tmux 3.2 or later, there's no link. Run the full path instead:

```sh
~/.local/share/waycar/plugin/bin/waycar status
```

## Commands

| Command | What it does |
| --- | --- |
| `waycar pair` | Shows a Pairing Code QR in this terminal. See [Pair with a Pairing Code](/help/pairing). |
| `waycar status` | Shows the version, which Backends it found (herdr, tmux and its version), the config and state folders, and each agent's hooks. |
| `waycar version` | Prints the host tools version. `waycar --version` works too. |
| `waycar hooks status` | Shows whether each agent has current Status Hooks. |
| `waycar hooks install` | Adds or updates the Status Hooks for every supported agent it finds. |
| `waycar hooks uninstall` | Removes only Waycar's hooks and extension files. |
| `waycar summaries refresh` | Refreshes [AI Summaries](/help/ai-summaries). The app runs this over SSH. |
| `waycar notify --pane tmux:%N --status …` | Updates the Live Activity and sends Blocked and Done notifications for a tmux pane. The Status Hooks run this; status is `working`, `idle`, `blocked`, `done` or `release`. |
| `waycar watch-approval --pane tmux:%N --agent agy\|cline` | Watches a tmux pane's screen for an approval and reports Blocked. The tool hooks of Antigravity and Cline run this, since those agents have no approval hook. |
| `waycar help` | Lists the commands. `--help` and `-h` work too. |

Add `--json` to `waycar status`, `waycar hooks status` or `waycar hooks install` for one line of machine-readable output. The app uses it to fill the Host page.

More on the hooks and what `hooks status` reports: [Waycar hooks for tmux](/help/tmux-hooks).

## herdr plugin actions

On herdr, the Waycar plugin adds actions you can run from herdr:

- **Pair a mobile device** shows a Pairing Code QR in a herdr popup. From a terminal, run:

  ```sh
  herdr plugin action invoke waycar.pair
  ```

- **Refresh Agent Summaries** refreshes AI Summaries. The app runs it about once a minute. Running it by hand is harmless.

herdr needs to be running for these actions to work.

## Good to know

- A wrong subcommand prints the list of commands and exits with an error.
- Running the install command again updates `waycar` too. See [Update Waycar on your Host](/help/update-host-tools).
