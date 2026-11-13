---
title: Supported agents
description: The coding agents Waycar can find and start from New Agent, and what each one supports on herdr and tmux, from status to Chat Mode and resume.
category: agents
order: 30
keywords: [claude, codex, gemini, opencode, cursor, copilot, cli, detect, not found, sign in]
related: [new-agent, chat-mode, closed-sessions, tmux-hooks]
---

Waycar starts the coding agents you already have installed on your Host. When you pick a Host in New Agent, Waycar looks for each supported agent's command there and lists the ones it finds in the **Agent** picker, along with **Default Shell** for a plain terminal.

## Which agents can Waycar start?

| Agent | Command |
| --- | --- |
| Claude Code | `claude` |
| Codex | `codex` |
| omp | `omp` |
| pi | `pi` |
| opencode | `opencode` |
| Gemini CLI | `gemini` |
| Amp | `amp` |
| Antigravity | `agy` |
| Cline | `cline` |
| Cursor Agent | `cursor-agent` |
| Devin CLI | `devin` |
| Droid | `droid` |
| GitHub Copilot CLI | `copilot` |
| Grok Build | `grok` |
| Hermes Agent | `hermes` |
| Kilo Code | `kilo` |
| Kimi CLI | `kimi` |
| Kiro CLI | `kiro-cli` |
| Maki | `maki` |
| Mastra Code | `mastracode` |
| Muse | `muse` |
| Qoder CLI | `qodercli` |
| Qwen Code | `qwen` |

Muse needs herdr 0.9.0 or later on the Host.

## What works with each agent?

Status on tmux comes from the [Waycar hooks](/help/tmux-hooks). Resume means [Closed Sessions](/help/closed-sessions) reopen the exact session; "Latest" reopens the agent's most recent one, "Picker" opens its own list, "Fresh" starts a new one. On herdr, most agents report their session only with herdr's integration for them (`herdr integration install <agent>`). Claude Code, pi, GitHub Copilot CLI, Qwen Code and Grok Build don't need it: Waycar gives each one it starts a session id, unless your **Arguments** already pick or continue a session.

| Agent | Status herdr | Status tmux | Chat Mode | Resume herdr | Resume tmux | Scroll tmux | Skills |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Claude Code | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Codex | Yes | Yes | Yes | Picker | Yes | No | Yes |
| omp | Integration | Yes | Yes | Integration, else Picker | Yes | Yes | Yes |
| pi | Yes | Yes, no Blocked | Yes | Yes | Yes | Yes | Yes |
| opencode | Yes | Yes | Yes | Integration, else Fresh | Yes | Yes | Yes |
| GitHub Copilot CLI | Late | Yes | Yes | Yes | Yes | Yes | Yes |
| Qwen Code | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Gemini CLI | Yes | Yes | Yes | Latest | Yes | Yes | No |
| Grok Build | Yes | Yes | Yes, no images | Yes | Yes | Yes | Yes |
| Antigravity | Yes | Yes | Yes, herdr needs integration | Integration, else Latest | Yes | Yes | Yes |
| Hermes Agent | Yes | Yes | Yes, no images | Integration, else Latest | Yes | Yes | Yes |
| Kilo Code | Yes | Yes | Yes | Integration, else Latest | Yes | Yes | Yes |
| Cline | Yes | Yes | Yes, no Chat Prompt | Fresh | Yes | Yes | Yes |
| Cursor Agent | Sign-in only | Untested | No | Untested | Untested | Untested | Yes |
| Devin CLI | Sign-in only | Untested | No | Untested | Untested | Untested | Yes |
| Kiro CLI | Sign-in only | Screen only | No | Untested | Untested | Untested | Yes |
| Muse | Yes | Yes | Yes | Latest | Yes | Yes | Yes |

Waycar tested the first 13 and Muse against each agent's current release on herdr 0.9.3 and tmux 3.4. Cursor Agent, Devin CLI and Kiro CLI need an account, so only their sign-in screen was tested. The other agents start and show herdr's status, but have no Waycar hooks or Chat Mode.

### Why some cells say No

- **omp on herdr**: without herdr's omp integration, a working omp reads Idle.
- **GitHub Copilot CLI on herdr** ("Late") reads Idle until the model starts to answer: herdr doesn't recognize Copilot's waiting line (`esc edit prompt`). A reply that arrives all at once may never show Working or Done, or send a Done alert.
- **pi**: pi never asks for approval, so it never turns Blocked.
- **Resume on herdr**: herdr has no integration for Gemini CLI or Cline, and Codex and Muse report no session to herdr, so these fall back to Latest, Picker or Fresh.
- **Antigravity and Cline on tmux**: their hooks can't report Blocked, so Waycar reads it from the agent's screen, and the Host does too for notifications. Cline reports status only when Waycar starts it.
- **Antigravity chats on herdr need herdr's integration** (`herdr integration install antigravity-cli`): Antigravity's transcript doesn't record its folder, so Waycar finds the chat only through the session the integration reports.
- **Cline** can only replace its own system prompt, so Cline chats start without the Chat Prompt.
- **Grok Build and Hermes Agent** chats show no images: Grok can't take one over SSH, and Hermes's chat export holds text only.
- **Codex on tmux** can't be scrolled from Waycar: it uses its own full screen but doesn't take the mouse, and the arrow keys would recall its input history instead. On herdr 0.9.3 or later, every agent scrolls.
- **Kiro CLI on tmux**: its hooks run only with `--v3`, so tmux status comes from its screen.

## Sign-in screens

Cursor Agent, Devin CLI, Kiro CLI, Antigravity and Muse show a sign-in screen until you sign in on the Host. Typing into it would start the sign-in, so Waycar doesn't send your message and says **Sign in to … on the Host first.** Sign in from the Host's terminal, then send again.

## How does Waycar find them?

Waycar checks the Host for each agent's command, including tools installed with Homebrew, Linuxbrew, Bun, Cargo, mise, or in your user's own folders. While it looks, the sheet shows "Detecting installed Agents…".

## Troubleshooting

- **No agent CLI found**: the New Agent sheet preselects **Default Shell** so you can still start a terminal. Install a supported agent on the Host, then tap **Detect Again** to use it.
- **An agent is missing from the list**: make sure it is one of the agents above and is installed in one of the places Waycar checks.
- **Status shows Unknown on tmux**: install the agent before you run the install command. See [Agent status shows Unknown](/help/status-unknown).
- **"… is still starting"**: some agents ignore typing for a few seconds after they start, so Waycar waits. Send again in a moment.
