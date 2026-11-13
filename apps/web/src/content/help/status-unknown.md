---
title: Agent status shows Unknown
description: Why an agent shows Unknown instead of Working, Blocked or Done, and how to fix it with Waycar hooks on tmux or herdr's integrations.
category: troubleshooting
order: 30
keywords: [status hooks, idle, wrong status, codex hooks, integration, tmux, no status]
related: [agent-status, tmux-hooks, update-host-tools, herdr-vs-tmux]
---

Unknown means Waycar can't tell what an agent is doing. On tmux, that almost always means Waycar's status hooks are missing for that agent. On herdr, it means herdr itself reports no status for the agent. Status also drives Blocked and Done notifications, so fixing it fixes those too.

## On tmux

Waycar reads tmux status from small hooks the install command adds to the agents listed in [Waycar hooks for tmux](/help/tmux-hooks#which-agents-have-hooks). Open the Host's page to see what's missing. Its checks say one of these:

- **Waycar's host tools are not installed, so tmux Agents show Unknown.**
- **Status hooks are missing for …, so those Agents show Unknown.**

### 1. Run the install command

Run this on the Host:

```sh
curl -fsSL https://waycar.dev/install.sh | sh
```

### 2. Installed an agent after the hooks?

The install command only adds hooks to agents that are already installed. If you installed an agent later, run the install command again.

### 3. Codex: approve the hooks

Codex keeps new hooks off until you review them. Open Codex once on the Host and approve Waycar's hooks on its `/hooks` screen. The Host's checks remind you with **Open Codex once and approve Waycar's hooks in /hooks.**

### Codex hooks are turned off

If `~/.codex/config.toml` sets `hooks = false` under `[features]`, Codex runs no hooks, so Codex agents show Unknown and the Host page lists Codex as **Not installed**. **Install Status Hooks** can't fix this, because Waycar never overrides your `false`. `waycar hooks install` and `waycar hooks status` say so:

```text
codex: hooks stay off because ~/.codex/config.toml sets `[features] hooks = false`; change it to `hooks = true` to turn them on
```

Change it to `hooks = true` in `config.toml`, run `waycar hooks install`, then approve the hooks on Codex's `/hooks` screen.

### 4. Other agents

Agents without a Waycar hook, such as Amp and Droid, show Unknown on tmux for now. Their terminals still work. herdr knows the status of more agents. See [herdr vs tmux](/help/herdr-vs-tmux).

## On herdr

herdr reports status for every agent it detects. A program herdr doesn't recognize as an agent appears as a shell row, which shows **Running** and never Unknown. If a detected agent shows Unknown on herdr, herdr is reporting no status for it, as happens right after an agent exits (see Good to know below). Check [herdr.dev](https://herdr.dev) for the agents herdr supports.

### omp shows Idle while it's working

Without herdr's omp integration, a working omp reports Idle for its whole turn. Check which integrations a Host has, then install the omp one:

```sh
herdr integration status
herdr integration install omp
```

## On herdr-core

herdr-core only knows an agent's status when the agent reports it to herdr-core. Claude Code and Pi do. Every other agent reads Unknown there, while its terminal works as usual. That is how herdr-core works, not a Waycar fault, and Waycar's hooks don't change it. See [Waycar with herdr-core](/help/herdr-core#status-shows-unknown).

## Good to know

Right after an agent exits, its pane can briefly show Unknown before the shell or the next agent takes over. That clears up on its own. More on what each status means: [Agent status](/help/agent-status).
