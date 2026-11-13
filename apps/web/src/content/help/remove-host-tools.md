---
title: Remove Waycar from a Host
description: Uninstall the Waycar host tools from a Mac or Linux Host, remove its Status Hooks and SSH key, and delete the Host in the app.
category: get-started
order: 90
keywords: [uninstall, remove, delete, unlink, hooks uninstall, authorized_keys, clean up]
related: [update-host-tools, waycar-command, tmux-hooks, hosts]
---

To remove Waycar from a Host, take out its Status Hooks, unlink the herdr plugin, delete the installed files, and remove your device's SSH key. Then delete the Host in the app. Your agents, herdr and tmux keep working as before.

## 1. Remove the Status Hooks

Run this first, while the `waycar` command is still there:

```sh
waycar hooks uninstall
```

It removes only Waycar's entries from the agents' config files and deletes the Waycar hook and extension files, including the opencode and Kilo Code Chat Prompt extensions. Every other hook stays. For each agent it prints `removed Waycar hooks from …` or `no Waycar hooks`.

If `waycar` isn't on your PATH, run `~/.local/share/waycar/plugin/bin/waycar hooks uninstall` instead. The files it touches are listed in [Waycar hooks for tmux](/help/tmux-hooks#which-files-do-the-hooks-change).

## 2. Unlink the herdr plugin

On a Host with herdr, first run `herdr plugin config-dir waycar` and note the folder it prints. You need it in step 4. Then run:

```sh
herdr plugin unlink waycar
```

If herdr says the plugin isn't linked, use `herdr plugin uninstall waycar`. Run `herdr plugin list` to check that `waycar` is gone. Skip this step on a tmux-only Host.

## 3. Delete the installed files

```sh
rm -rf ~/.local/share/waycar/plugin
[ -L ~/.local/bin/waycar ] && rm ~/.local/bin/waycar
```

The second line removes `~/.local/bin/waycar` only if it's a link, which is all the install command ever puts there.

If you installed with `WAYCAR_PLUGIN_DIR`, delete that folder instead.

## 4. Delete the pairing and notification keys (optional)

Waycar keeps its config, with the pairing and notification keys, so a reinstall picks up where you left off. To remove it too:

- **On tmux**, delete `~/.config/waycar` (or `$XDG_CONFIG_HOME/waycar`) and `~/.local/state/waycar`.
- **On herdr**, herdr keeps the plugin's config folder after you unlink it. Delete the folder you noted in step 2.

## 5. Remove your device's SSH key

Open `~/.ssh/authorized_keys` on the Host and delete the line for your Waycar device key. It's the line you added by hand or that pairing added. See [SSH keys and passwords](/help/ssh-keys). If several devices share it through [iCloud Sync](/help/icloud-sync), removing it signs them all out of this Host.

## 6. Delete the Host in the app

In Waycar, tap **Hosts**, swipe left on the Host's card (or touch and hold it), tap **Delete**, and confirm with **Remove Host**. See [Remove a Host](/help/hosts#remove-a-host).

## Good to know

- To only take a break from a Host, turn off its switch in the Hosts sheet instead.
- To put Waycar back later, run the install command again. See [Install Waycar on your Host](/help/install).
