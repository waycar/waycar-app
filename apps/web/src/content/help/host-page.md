---
title: A Host's page and checks
description: What each section of a Host's page does, how the Preflight checklist reads, and how to pick a herdr session or run the checks again.
category: hosts
order: 15
keywords: [preflight, run checks again, reconnect, available sessions, status hooks, backends, enabled, herdr version, protocol]
related: [hosts, cant-connect, host-keys, mosh]
---

A Host's page shows how Waycar reaches that Host and checks that everything it needs is working. Open it by tapping the Host's card in the [Hosts sheet](/help/hosts). Waycar runs the checks when the page opens and again whenever you turn the Host back on.

## What's on the page?

From top to bottom:

- **Enabled switch.** "Waycar never connects to a disabled Host. Its settings stay saved." A disabled Host's page shows only the switch and the rows below it.
- **Address**, **Session** and **Auth.** How Waycar reaches the Host. **Session** shows the herdr session name, or "default". Tap **Edit** at the top to change any of them.
- **Reconnect.** Connects the Host again. It reads **Connecting…** while it works, and the connection error shows in red underneath.
- **Preflight.** The checklist, described below.
- **Status Hooks.** On a tmux Host, whether each agent's status hooks are **Installed** or **Not installed**, with **Install Status Hooks** when some are missing. See [Waycar hooks for tmux](/help/tmux-hooks).
- **Backends.** On a Host with multiple Backends, visibility toggles are labelled **Show Herdr TUI sessions**, **Show Herdr Core sessions** and **Show tmux sessions**, for the Backends present. Hiding Herdr Core or tmux also stops that Backend's notifications; hiding Herdr TUI does not. Choose the runtime in **New Agent**, not here. **Session** is for Herdr TUI only. See [Waycar with herdr-core](/help/herdr-core).
- **Codex.** **Codex server running** or **Codex server not running**, with **Start Codex server** when it is stopped. Checking starts nothing. **Show Codex threads** controls visibility on this Host. See [Waycar with Codex](/help/codex).
- **OpenCode.** **OpenCode server running** or **OpenCode server not running**, with **Start OpenCode server** when it is stopped. Checking starts nothing. **Show OpenCode sessions** controls visibility on this Host. See [Waycar with OpenCode](/help/opencode).
- **Mosh.** **Current Connection** with its MOSH or SSH badge, **Retest and Upgrade Sessions**, and **Test Mosh Support**. See [mosh](/help/mosh).
- **AI Usage.** Per-Host settings for [AI Usage with CodexBar](/help/ai-usage).
- **Available Sessions.** herdr sessions you can switch to (below).
- **Run Checks Again.**
- **Trust New Host Key.** Only when the Host presented a changed key. See [Host keys and fingerprints](/help/host-keys).

## Read the Preflight checklist

Checks run in this order:

| herdr Host | tmux Host |
| --- | --- |
| SSH connection | SSH connection |
| remote environment | remote environment |
| herdr installed | tmux installed |
| herdr server running | Status hooks |
| protocol compatible | |

A Host that runs both herdr and tmux runs the herdr list.

A run stops at the first failure:

- A green check means the row passed.
- A red X marks the row that failed, with a line underneath saying what to fix.
- A grey minus means the row wasn't reached because an earlier one failed.

**Status hooks** never fails a run. When hooks are missing it shows a yellow warning triangle instead.

## Fix a failed check

1. Read the line under the red X.
2. Fix the problem on the Host or in **Edit**.
3. Tap **Run Checks Again**.

Each message is explained in [Can't connect to a Host](/help/cant-connect) and [What connection messages mean](/help/connection-messages). If the SSH connection row says "The host key was not confirmed. Run the checks again and confirm the fingerprint.", tap **Run Checks Again** and tap **Trust** in the prompt.

## The version line under Preflight

Under the checklist, a line shows what the Host runs: `herdr <version> · protocol <n>` on a herdr Host, `tmux <version>` on a tmux Host, and both lines on a Host with both.

If herdr is newer than your Waycar app, the line adds "newer than this app was built against, so features added after protocol N may be unavailable." This is a notice, not an error. The checks still pass and the Host works. Update the Waycar app to get the newer herdr features.

## Pick a herdr session

On a herdr Host, **Available Sessions** lists the Host's herdr sessions. Each row reads **Running** or **Stopped**, and the current one has a checkmark.

- Tap a session to switch the Host to it. Waycar saves it and runs the checks against it.
- A stopped named session can't be picked. Start it on the Host first.
- If the page says "Could not discover herdr sessions. You can still enter a session name manually.", tap **Edit** and type the name under **herdr Session**.
- If saving fails, you see **Could Not Select Session**. Try again.

The Host's card then shows `· session <name>` after its address.
