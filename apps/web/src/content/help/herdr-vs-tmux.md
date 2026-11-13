---
title: herdr vs tmux
description: Waycar works with herdr and with tmux 3.2 or later. Here is what each one supports, side by side, so you can pick or run both.
category: hosts
order: 70
keywords: [compare, difference, backend, which one, terminal multiplexer, features]
related: [tmux, tmux-hooks, take-over, requirements]
---

Waycar works with herdr 0.7.5 or later and with tmux 3.2 or later, using the same app and the same install command. herdr still gives you the most, because it knows the status of more agents. Run both, and their agents show up together in one list.

Hosts that run herdr-core, the runtime under the Herdr app, work too, as a third option. This page's "herdr" means the Herdr TUI, the original `herdr`. See [Waycar with herdr-core](/help/herdr-core).

## Side by side

| Feature | herdr | tmux |
| --- | --- | --- |
| Agent list | Workspaces, tabs and panes | Sessions, windows and panes |
| Live terminal | Yes. Opening an agent takes over its terminal. | Yes. Your desk and phone can both watch the same window. It fits whichever one opened it or typed in it last. |
| Agent status | Yes, for every agent herdr knows. omp needs herdr's omp integration. GitHub Copilot CLI reads Idle until the model starts to answer. | Claude Code, Codex, omp, pi, opencode, GitHub Copilot CLI, Qwen Code, Gemini CLI, Grok Build, Antigravity, Hermes Agent, Kilo Code, Cline, Cursor Agent, Devin CLI, Kiro CLI and Muse, through Waycar hooks. Others show Unknown. |
| Blocked and Done alerts | Yes | Yes, through Waycar hooks |
| Chat Mode | Yes. Antigravity chats need herdr's Antigravity integration. | Yes. Allow and Cancel, and Antigravity chats, need Waycar hooks. |
| Chat Mode replies in alerts | Yes | Not yet |
| Live Activities | Yes | Yes, through Waycar hooks |
| New agent on a worktree | Yes | Yes. It opens as a new tmux session. Needs git on your Host. |
| Closed Sessions | Yes. Resume picks up the exact session when herdr's integration for the agent reports its session, or, for Claude Code, pi, GitHub Copilot CLI, Qwen Code and Grok Build, when Waycar started the agent. | Yes. Resume picks up the exact session when Waycar hooks are on. |
| Scrolling an agent's history | Yes, every agent (herdr 0.9.3 or later) | Yes, except Codex. Inline agents and shells scroll through tmux's copy mode, which desk windows on that pane see too. |
| mosh, AI Usage, dictation | Yes | Yes |

## Which should I use?

- **Already on tmux?** Keep it. Run the install command and add the [Waycar hooks](/help/tmux-hooks) for live status and alerts.
- **Want the most from Waycar?** herdr knows the status of every agent it supports and puts [Chat Mode](/help/chat-mode) replies in your notifications. See [herdr.dev](https://herdr.dev).
- **Use both?** That works. Pick which one new agents start in on the Host's page. See [Waycar with tmux](/help/tmux#a-computer-with-herdr-and-tmux).

## Do I need herdr?

No. Waycar works with tmux 3.2 or later, and the same install command sets it up:

```sh
curl -fsSL https://waycar.dev/install.sh | sh
```

## Good to know

- On herdr, opening an agent in Waycar disconnects the other client from it. On tmux, nothing is taken over. See [Your desk and phone on one terminal](/help/take-over).
