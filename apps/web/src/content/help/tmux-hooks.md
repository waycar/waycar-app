---
title: Waycar hooks for tmux
description: Small Status Hooks in Claude Code, Codex, Gemini CLI, Copilot and 13 more agents tell Waycar when a tmux agent is working, blocked or done.
category: hosts
order: 80
keywords: [status hooks, waycar hooks install, waycar-hook, unknown, blocked, codex /hooks, no-hooks]
related: [tmux, status-unknown, waycar-command, remove-host-tools]
---

On tmux, Waycar learns what an agent is doing from small Status Hooks inside the agent. When an agent starts working, stops to ask you something, or finishes, its hook tells tmux, and Waycar reads it. That powers agent status, Blocked and Done notifications, and Live Activities on tmux Hosts. herdr Hosts don't need them.

## Which agents have hooks?

Claude Code, Codex, omp, pi, opencode, GitHub Copilot CLI, Qwen Code, Gemini CLI, Grok Build, Antigravity, Hermes Agent, Kilo Code, Cline, Cursor Agent, Devin CLI, Kiro CLI and Muse. Other agents show **Unknown** on tmux for now.

- **Antigravity and Cline** have no hook for an approval, so Waycar reads Blocked from their screen. Their tool hook also has the Host watch the screen, so their Blocked sends a notification too.
- **Cline** reports only when it runs on its own, as Waycar starts it (`cline -i --data-dir ~/.cline/data`), not through its background service.
- **Kiro CLI** runs Waycar's hooks only when started with `--v3`. Otherwise Waycar reads its status from the screen.
- **Cursor Agent, Devin CLI and Kiro CLI** need an account, so their hooks are untested.

See what else each agent supports in [Supported agents](/help/supported-agents).

## Install the hooks

The install command adds the hooks for every supported agent that's already installed:

```sh
curl -fsSL https://waycar.dev/install.sh | sh
```

Installed an agent later? Run the install command again.

You can also install them from the app. Tap **Hosts**, open the tmux Host, and look under **Status Hooks**. Each agent reads **Installed** or **Not installed**. Tap **Install Status Hooks** to add the missing ones.

If the Host page says Waycar's host tools aren't installed, tap **Copy Install Command** and run it on the Host.

## Codex asks you to review them once

Codex doesn't turn on new hooks by itself. Open Codex once on the Host and approve Waycar's hooks on its `/hooks` screen. Until then, the Host page reminds you: "Open Codex once and approve Waycar's hooks in /hooks."

## Manage the hooks from the terminal

The install command puts a `waycar` command on the Host:

```sh
waycar hooks status
waycar hooks install
waycar hooks uninstall
```

- `waycar hooks status` shows which agents have current hooks.
- `waycar hooks install` adds Waycar's entries to each agent's config and keeps every other hook you have.
- `waycar hooks uninstall` removes only Waycar's entries and files.

If you ran the installer with `--no-hooks`, it skipped the hooks. Add them later with `waycar hooks install`. Every subcommand is listed in [The waycar command on your Host](/help/waycar-command).

### What does `waycar hooks status` say?

Each agent gets one line ending with its config file:

| State | Meaning |
| --- | --- |
| `installed` | Current Waycar hooks are in place. |
| ``out of date, run `waycar hooks install` `` | Waycar's hooks are from an older version or another install folder. |
| `not installed` | The agent is on the Host but has no Waycar hooks. |
| `not installed (agent not found)` | Waycar didn't find the agent. |
| ``off (`[features] hooks = false`)`` | Codex's config turns hooks off. See [Codex hooks are turned off](/help/status-unknown#codex-hooks-are-turned-off). |
| `error: …` | Waycar couldn't read the agent's config, for example invalid JSON. The file is unchanged. |

For Codex, it can add a line asking you to open Codex and run `/hooks`.

## Which files do the hooks change?

| Agent | File |
| --- | --- |
| Claude Code | `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`) |
| Codex | `~/.codex/hooks.json`, plus `[features] hooks = true` in `~/.codex/config.toml` (or both under `$CODEX_HOME`) |
| omp | `~/.omp/agent/extensions/waycar-agent-state.ts` |
| pi | `~/.pi/agent/extensions/waycar-agent-state.ts` |
| opencode | `waycar-agent-state.js` and `waycar-chat-prompt.js` in `~/.config/opencode/plugins` (or under `$XDG_CONFIG_HOME`) |
| Kilo Code | `waycar-agent-state.js` and `waycar-chat-prompt.js` in `~/.config/kilo/plugins` (or under `$XDG_CONFIG_HOME`) |
| GitHub Copilot CLI | `~/.copilot/hooks/waycar.json` (or under `$COPILOT_HOME`) |
| Qwen Code | `~/.qwen/settings.json` |
| Gemini CLI | `~/.gemini/settings.json` |
| Grok Build | `~/.grok/hooks/waycar.json` (or under `$GROK_HOME`) |
| Antigravity | a `waycar` group in `~/.gemini/config/hooks.json` |
| Hermes Agent | a marked `hooks:` block at the end of `~/.hermes/config.yaml`, plus its commands in `~/.hermes/shell-hooks-allowlist.json` (or under `$HERMES_HOME`) |
| Cline | `TaskStart`, `TaskResume`, `PreToolUse`, `TaskComplete`, `TaskError`, `TaskCancel` and `SessionShutdown` in `~/.cline/hooks` |
| Cursor Agent | `~/.cursor/hooks.json` |
| Devin CLI | `~/.config/devin/config.json` |
| Kiro CLI | `~/.kiro/hooks/waycar.json` |
| Muse | `~/.config/muse/settings.json` (or under `$XDG_CONFIG_HOME`) |

For Claude Code, Codex, Qwen Code, Gemini CLI, Antigravity, Cursor Agent, Devin CLI and Muse, Waycar merges its entries into the file and keeps your other hooks. Codex's `notify` setting is never touched. The other files hold only Waycar's hooks or carry an `installed by waycar` line; Waycar leaves a same-named file without it alone. Hermes Agent asks before it runs a new hook, so Waycar adds its hooks to Hermes's allowlist; a `config.yaml` with its own `hooks:` section is left alone and reported as an error.

## What do the hooks do on my machine?

Each hook runs `waycar-hook`, a short shell script that sets a value on the agent's tmux pane, prints nothing, and starts `waycar notify` in the background. `waycar notify` sends the encrypted Blocked and Done notifications and Live Activity updates to Waycar's push relay. For Antigravity and Cline, the tool hook also starts `waycar watch-approval`, which reads the pane's screen for a few seconds, and for as long as an approval shows, so it can report Blocked. Hooks only act inside tmux, and stay out of the way in a herdr pane, where herdr tracks status itself.

## Troubleshooting

- **Agent shows Unknown.** Check **Status Hooks** on the Host page, install any missing hooks, and for Codex, approve them in `/hooks`. See [Agent status shows Unknown](/help/status-unknown).
- **No Blocked or Done notifications on tmux.** These come from the same hooks. See [Notifications don't arrive](/help/notifications-not-arriving).
