# Kiro CLI (`kiro-cli`)

Version tested: **kiro-cli 2.29.1**, linux aarch64 (`cli.kiro.dev/install`: `~/.local/bin/kiro-cli` 40 MB launcher, `kiro-cli-chat` 204 MB, `kiro-cli-term` 31 MB), in the harness lab (Ubuntu 24.04, tmux 3.4, herdr 0.9.3). Date: 2026-10-12.

**Account-only.** Kiro has no custom-endpoint or BYOK mode; `KIRO_API_KEY` needs a paid plan and works non-interactively only (docs). The lab has no account, so everything after the sign-in screen is UNVERIFIED and marked so. Method tags: **live** = observed in the lab; **docs** = `https://kiro.dev/docs/hooks.md`, `…/hooks/types.md`, `…/cli/v3/hooks-migration.md`, `…/custom-agents/configuration-reference.md`, `…/cli/chat/session-management.md`, `…/skills.md`, `…/steering.md` (read 2026-10-12); **help** = `kiro-cli chat --help` / `--help-all` on 2.29.1. Captures (login screen, raw pty bytes): `/tmp/waycar-harness-captures/kiro/` on the Mac.

## Probe answers

1. **Hook config and events (docs; UNVERIFIED live — no hook fires before sign-in)**
   - **Engine matters.** 2.29.1's `chat` defaults to the **V2 engine** (`--agent-engine v1|v2|v3`, "v2 (default)"; `--v3` opts in) (help).
   - **CLI V3:** standalone files `.kiro/hooks/*.json` (workspace) and **`~/.kiro/hooks/*.json` (global, V3 only)**: `{"version": "v1", "hooks": [{"name", "trigger", "matcher"?, "action": {"type": "command", "command"} | {"type": "agent", "prompt"}, "timeout"? (60), "enabled"?}]}`. Triggers: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, plus file/task triggers.
   - **CLI 2.x / V2 engine:** hooks live inside an agent profile (`.kiro/agents/<name>.json` or `~/.kiro/agents/<name>.json`, selected with `--agent`), legacy object form `{"hooks": {"agentSpawn": [{"command"}], "userPromptSubmit": […], "preToolUse": [{"command", "matcher"}], "postToolUse": […], "stop": […]}}`. Whether 2.29.1's V2 engine also reads `~/.kiro/hooks/` is UNVERIFIED.
   - **No permission/approval or notification event**, and no session-end on V2 (`SessionEnd` is V3 only).
   - **stdin (docs):** `{"hook_event_name", "cwd", "session_id", …}`; tool events add `tool_name`, `tool_input` (V2 engine also `tool_tags`), PostToolUse `tool_response`; UserPromptSubmit sets env `USER_PROMPT`. No transcript path. Exit 2 on PreToolUse blocks; Stop exit 1 / `decision: "block"` continues the turn.
2. **tmux pane identity.** UNVERIFIED (no hook can fire without sign-in). The login screen runs as one `kiro-cli chat` process on the pane tty (live).
3. **Executable (live).** `kiro-cli` (subcommand `chat`); Waycar's `.kiro → "kiro-cli"` override is right. At the login screen ps showed only `kiro-cli chat`; whether chat proper runs as `kiro-cli-chat` (which would change `pane_current_command`) is UNVERIFIED.
4. **Transcript (docs).** Sessions are auto-saved per directory in a local database (`~/.local/share/kiro-cli/data.sqlite3` exists after first launch, live; the docs say "`~/.kiro/`"; `--session-source v1|v2` implies two stores). No documented JSONL file. Export routes: `/chat save <path>` (JSON) in-session, `--list-sessions -f json`, and `--output-format stream-json` (ACP events) for headless runs. Record format UNVERIFIED.
5. **Chat Prompt route (docs, UNVERIFIED).** No system-prompt flag. Candidates: a custom agent (`--agent <name>`) whose `prompt` field is inline text or `file://<abs path>` ("similar to a system prompt"; replace vs append unknown), or steering files (`.kiro/steering/*.md`, `~/.kiro/steering/`, `AGENTS.md`) which are persistent. An agent profile is the only per-launch route; it may replace the default agent's prompt and tool set.
6. **First message (help).** Positional `kiro-cli chat [INPUT]` ("The first question to ask").
7. **Resume (help, docs).** `--resume-id <SESSION_ID>` (UUID), `-r/--resume` (most recent in this directory), `--resume-picker`. Exit prints the id and `kiro-cli chat --resume-id <ID>`; `/session-id` prints it mid-session. `ClosedSession` currently returns `[]` for `.kiro`; `["--resume-id", id]` (and `["--resume"]` without one) are the documented forms. herdr reports no session for kiro (below), so on herdr only the no-id form applies.
8. **Model and effort (help).** `--model <MODEL>`, `--effort <low|medium|high|xhigh|max>`; `--list-models` lists ids (needs login). Wire format UNVERIFIED.
9. **Skills (docs).** `.kiro/skills/<name>/SKILL.md` and `~/.kiro/skills/<name>/SKILL.md`, invoked `/<name>`; workspace wins over global for steering (skills precedence not stated). Matches `AgentSkill.swift`.
10. **Alt screen, mouse, input readiness.**
    - **Login screen (live):** inline, only `?2004h`/`l` — no `?1049h`, no mouse.
    - Chat: inline by default; `/fullscreen` switches to alt screen + mouse (docs); `--tui` ("new terminal UI") and `--classic` exist (help). UNVERIFIED live.
    - Input-ready marker (herdr manifest, not live): idle line `> ask a question or describe a task`.
11. **herdr tier (live, 0.9.3).** `herdr integration status` lists **no kiro integration** → screen-manifest only, no `agent_session`. Manifest `kiro.toml` 2026.09.19.1: idle = `> ask a question or describe a task`; working = footer `kiro is working` / `type to steer` / `ctrl+s to queue`, OSC title `◐ kiro:`, OSC progress `4;3`; blocked = tool-approval menus ending `esc to close … to navigate` with `allow / always allow / deny`, `yes, single permission`, `trust … / entire tool`, crew approval, question panel.
12. **Login (live).**
    - `kiro-cli chat` without credentials: `Welcome to Kiro CLI, let's get you signed in!` / `Press enter to continue to the browser or esc to cancel` (inline).
    - `kiro-cli whoami` → `Not logged in`.
    - `kiro-cli chat --no-interactive "…"` and `--list-models` start an **AWS device-code flow** on stdout: `Confirm the following code in the browser` / `Code: XXXX-XXXX` / `Open this URL: https://view.awsapps.com/start/#/device?user_code=XXXX-XXXX` (not completed).
13. **Daemon.** Not observable without sign-in. `kiro-cli launch/quit/restart` manage a desktop app; the CLI chat is not documented to share a server. UNVERIFIED.

## Recommended implementation per layer

- **tmux Status Hooks.** Not implementable to a verified contract without an account. If built from docs: install `~/.kiro/hooks/waycar.json` (V3 format) **and** launch with `--v3`, or add object-form hooks to a Waycar-owned agent profile for the V2 default. Mapping: `UserPromptSubmit` → working, `Stop` → done, `SessionStart`/`agentSpawn` → session id (`session_id`); **blocked cannot come from hooks** (no permission event) → screen fallback from herdr's `kiro.toml`.
- **Notifications.** blocked only via screen detection.
- **Chat Mode.** Cannot support today: no live transcript format, no verified prompt route. First message would be the positional `[INPUT]`; model `--model`, effort `--effort`.
- **Resume.** Change `.kiro` to `["--resume-id", id]` when an id is known, `["--resume"]` otherwise (docs; unverified live).
- **Message jump.** Default inline (login screen verified inline; chat per docs).
- **Skills.** Catalog matches the docs.
- **Prompt gate.** Generic gate; plus treat the sign-in screen as "needs login" (`let's get you signed in`) so Waycar never types a prompt into it (Enter opens the browser flow).
- **tmux launch.** `kiro-cli chat` (executable `kiro-cli` + `chat`).
- **Blocker.** Everything past sign-in needs a Kiro account (Builder ID/Google/GitHub/IAM Identity Center); never sign up per the plan.
