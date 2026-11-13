---
title: Update Waycar on your Host
description: Update the Waycar plugin and host tools on your Host from the app or with the install command, when Waycar says the plugin is out of date.
category: get-started
order: 80
keywords: [upgrade, reinstall, plugin version, out of date, waycar version, waycar status, hooks]
related: [install, waycar-command, remove-host-tools, pairing]
---

Waycar tells you when the Waycar plugin on a Host is too old for this version of the app, and can update it for you. You can also update from the Host's terminal with the install command. Either way, your pairing and notification keys stay as they are.

## When does Waycar ask?

Waycar reads the plugin version on each Host when it connects. If the Host's plugin is older than the app needs, you see it where you already are:

- **In the Console**, a row that names the Host, such as "<Host>: Waycar plugin 1.3.1 is out of date". Tap **Update**, or tap **✕** to hide the row for that Host. It comes back only when a later app needs a newer plugin.
- **In the Console, on a Host with no Waycar plugin**, a row that says "Install Waycar Host Tools on <Host>". Tap **Install** to open the same screen, or **Not now** to hide the row for that Host for 14 days. It comes back once; a second **Not now** stops it. To never see it for a Host, turn off **Remind me to install Host Tools** under **Waycar plugin** on the Host's page.
- **On an agent's card**, when AI Summaries is on but the agent shows no [Agent Progress](/help/agent-progress) because the plugin is too old: **Update plugin for progress**.
- **In Chat Mode**, when a chat needs a newer plugin to show replies: **Update Waycar on <Host>…**. The chat reloads by itself after the update.
- **On the Host's page**, under **Waycar plugin**: the installed version and whether it is up to date. If it is out of date, tap **Update Waycar on this Host…**. If the plugin still works with this app but a newer one is out, the status shows the newer version, such as "2.3.0 available", with the same button. Updating then is optional, and nothing else in the app asks.

After you update the plugin from a terminal yourself, Waycar checks again the next time you open the app, and the prompts go away.

## Update from the app

1. Tap **Update** on the Console row, or the update button on the agent's card, in the chat, or on the Host's page.
2. Read what the update does, then choose whether to turn off **Refresh agent status hooks** (it is on by default).
3. Tap **Update**.

Waycar runs the latest installer from waycar.dev on the Host over SSH and shows its progress. Keep Waycar open until it finishes. Then it shows the installed version and any warnings, and the Host reconnects with the new plugin. If waycar.dev still serves an older plugin than the app needs, Waycar says so; try again later. If the update fails, you see the last error with **Retry** and **Copy Command**, so you can run the install command on the Host yourself.

### What the update changes

- **The plugin and host tools** are replaced with the latest version.
- **Agent hooks**, only when **Refresh agent status hooks** is on. On Hosts with tmux 3.2 or later, Waycar rewrites its hooks in your agents' settings files (Claude Code, Codex and others). On every Host it also rewrites its Chat Prompt extensions for opencode and Kilo Code. Your other hooks and settings are left alone. Turn the switch off to leave every agent's settings untouched; the update screen then leaves out the two hook notes here.
- **Codex**, only when the hooks are refreshed, asks you to review the refreshed hooks once, on its `/hooks` screen, the next time you start it. Until you approve them, Codex agents show no status from Waycar's hooks.
- **herdr's sidebar** keeps running the old plugin version until you restart herdr. Everything else uses the new version at once.

Your pairing, notification keys and settings are kept, and no pairing QR code is shown.

## Update from the terminal

1. On the Host, run:

   ```sh
   curl -fsSL https://waycar.dev/install.sh | sh
   ```

2. If it offers to show a pairing QR code, you can say no. Your devices stay paired.

On herdr, the command updates the plugin already linked into herdr. On tmux, it replaces the files in `~/.local/share/waycar/plugin`, and `~/.local/bin/waycar` keeps pointing at them. On a herdr Host that also has tmux 3.2 or later, the command also points `~/.local/bin/waycar` at the plugin.

## When should I update?

- **When the app asks.** See above.
- **When the Host's page shows a newer version available.** You get the latest fixes; everything keeps working if you wait.
- **After installing an agent.** Run the command again so the new agent gets its Waycar hooks. Codex asks you to review new hooks once, on its `/hooks` screen.
- **When the Status hooks check fails.** On a tmux Host, if the **Status hooks** check says "Waycar's host tools are not installed, so Agents show Unknown," run the install command.
- **When release notes say to.** Some fixes, like the more compact Pairing Code QR, need the command run again on the Host.

## Check what's installed

On a Host with tmux 3.2 or later (on a herdr-only Host, use `~/.local/share/waycar/plugin/bin/waycar` in place of `waycar`):

```sh
waycar version
waycar status
waycar hooks status
```

`waycar status` shows the Backends, the hooks, and the config folder. Add `--json` for machine-readable output. See [The waycar command on your Host](/help/waycar-command) for every subcommand.

## Good to know

- Updating doesn't unpair anything. The plugin's config, with the pairing and notification keys, is kept.
- With [iCloud Sync](/help/icloud-sync) on, **Not now**, **✕** and **Remind me to install Host Tools** apply on all your devices, and they stay as you left them after you delete and reinstall Waycar.
- The app can also install Waycar on a Host that has none (see above). To install it from a terminal instead, see [Install Waycar on a Host](/help/install).
- Running the command again is also how you [pair another device](/help/pairing).
- herdr updates don't need a Waycar update. Waycar only checks for herdr 0.7.5 or later.
- If the update stops with an error, see [The install command fails](/help/install-fails).
- To uninstall instead, see [Remove Waycar from a Host](/help/remove-host-tools).
