# Cursor CLI (`cursor-agent` / `agent`)

Version tested: **cursor-agent 2026.10.01-e373342**, linux aarch64 (installed by `cursor.com/install`), in the harness lab (Ubuntu 24.04, tmux 3.4, herdr 0.9.3). Date: 2026-10-12.

**This harness needs an account.** The lab has none: there is no BYOK or custom endpoint, and `CURSOR_API_KEY` needs a real Cursor key. Everything past the sign-in screen is therefore **UNVERIFIED live** and comes from the docs or a review of the shipped JS bundle (`~/.local/share/cursor-agent/versions/2026.10.01-e373342/*.js`).

Method tags:
- **live**: observed in the lab.
- **docs**: `https://cursor.com/docs/hooks.md`, `https://cursor.com/docs/reference/third-party-hooks.md`, or `cursor-agent --help` on this version.
- **source**: bundle review.

Captures are in `/tmp/waycar-harness-captures/cursor/` on the Mac: first screen, login screen, and raw pty bytes.

## The Claude-hook bleed

- **Cursor runs Claude hooks (docs).** Cursor loads `~/.claude/settings.json`, `.claude/settings.json` and `.claude/settings.local.json` hooks when *Include Third-Party Plugins, Skills, and Other Configs* is on, which is the default. It maps Claude event names to its own:

| Claude event | Cursor event |
|---|---|
| `PreToolUse` | `preToolUse` |
| `PostToolUse` | `postToolUse` |
| `UserPromptSubmit` | `beforeSubmitPrompt` |
| `Stop` | `stop` |
| `SubagentStop` | `subagentStop` |
| `SessionStart` | `sessionStart` |
| `SessionEnd` | `sessionEnd` |
| `PreCompact` | `preCompact` |

  `Notification`, `PermissionRequest` and the elicitation events have no Cursor equivalent.
- **Effect on Waycar [INFERENCE from the mapping above].** Once logged in, Waycar's claude entries would mark a cursor pane `working` (UserPromptSubmit, PreToolUse), `done` (Stop) and `release` (SessionEnd). `hook-session.js claude` would write `@waycar_agent claude` and `@waycar_session <cursor session_id>`. The pane would never go `blocked`.
- **No hooks fire before login (live).** I installed capture hooks for 11 events in `~/.cursor/hooks.json` and 11 events in `~/.claude/settings.json`, then launched `cursor-agent`, opened the browser-login screen and the QR screen, and quit. None fired.
- **Discriminator (docs + source).** The hook environment always has `CURSOR_VERSION` and `CURSOR_PROJECT_DIR`. It may also have `CURSOR_USER_EMAIL`, `CURSOR_TRANSCRIPT_PATH` and `CURSOR_CODE_REMOTE`. It also sets `CLAUDE_PROJECT_DIR`, so that variable is **not** a discriminator. Source: `buildHookEnvironment` in `190.index.js` returns `{CURSOR_PROJECT_DIR, CURSOR_VERSION, CURSOR_USER_EMAIL?, CURSOR_TRANSCRIPT_PATH?, CLAUDE_PROJECT_DIR, …sessionEnv}`.
- **Payload discriminator (docs).** Every payload carries `cursor_version`.
- **herdr precedent (source review of `~/src/herdr/src/integration/assets/claude/herdr-agent-state.sh`).** herdr's own claude hook skips when `CURSOR_VERSION` is in the env or `cursor_version` is in the payload (herdr preview-2026-09-29-9dc3a1df2b56-29-gf0c193cc).
- **Process model (source).** Cursor runs hooks through its internal `shellExecutor` (`executeCommandHook` in `190.index.js`). Whether the hook's `$PPID` has the pane tty is UNVERIFIED: it needs a logged-in run.

## Probe answers

1. **Hook config and events (docs)**
   - **Config files.**
     - `~/.cursor/hooks.json`, shaped `{"version": 1, "hooks": {"<event>": [{"command": "…", "matcher"?, "timeout"?, "loop_limit"?, "failClosed"?}]}}`.
     - Project `.cursor/hooks.json`.
     - Enterprise `/etc/cursor/hooks.json`.
     - Claude settings files, mapped as above.
   - **Events.**
     - Session: sessionStart, sessionEnd, workspaceOpen.
     - Prompt and response: beforeSubmitPrompt, afterAgentResponse, afterAgentThought, stop.
     - Tools: preToolUse, postToolUse, postToolUseFailure.
     - Shell and MCP: beforeShellExecution, afterShellExecution, beforeMCPExecution, afterMCPExecution.
     - Files: beforeReadFile, afterFileEdit, beforeTabFileRead, afterTabFileEdit.
     - Subagents and compaction: subagentStart, subagentStop, preCompact.
   - **No approval-pending event.** `beforeShellExecution` can *answer* `permission: "ask"`, but nothing reports that a prompt is showing.
   - **Common payload fields.** `conversation_id`, `generation_id`, `model`, `model_id`, `model_params`, `hook_event_name`, `cursor_version`, `workspace_roots`, `user_email`, `transcript_path`.
   - **Session events.** `sessionStart` and `sessionEnd` add `session_id` (the same value as `conversation_id`); `sessionEnd` also adds `reason`.
   - **Transcript path.** `transcript_path` in the payload and `CURSOR_TRANSCRIPT_PATH` in the env; both are null when transcripts are disabled.
2. **tmux pane identity.** UNVERIFIED, because hooks never fire logged out. [INFERENCE] `TMUX_PANE` should be inherited, since `buildHookEnvironment` spreads extra vars over the inherited env.
3. **Executable (live)**
   - `cursor-agent` and `agent` are both in `~/.local/bin`.
   - The process `args` are `/home/waycar/.local/bin/cursor-agent --use-system-ca …/index.js`, while `ps` comm reads **`MainThread`** because Node renames the thread.
   - `pane_current_command` reads `cursor-agent`.
   - Waycar's `SupportedAgentKind.executable` (`cursor-agent`) matches. TmuxAgentDetection must match on `pane_current_command` or args, not on comm.
4. **Transcript.**
   - **Docs.** `transcript_path` / `CURSOR_TRANSCRIPT_PATH`, described as "the main conversation transcript file".
   - **Source.** The string `agent-transcripts` appears in `index.js`, but the path layout and record format are UNVERIFIED.
   - **Live.** `~/.cursor/projects/home-waycar-work-demo/` exists but stays empty until login.
5. **Chat Prompt route.** No system-prompt flag exists (`--help`, live). Candidate routes (docs, unverified):
   - A `sessionStart` hook returning `{"additional_context": "<text>"}`, which is added to the conversation's initial system context. A Waycar-installed sessionStart hook could read the Chat Prompt from an env var or file that Waycar sets at launch.
   - Rules files (`.cursor/rules/*.mdc`, `AGENTS.md`).
6. **First message (docs `--help`, live).** `agent [options] [prompt...]`: a positional "Initial prompt for the agent".
7. **Resume (docs `--help`, live).**
   - Flags and commands: `--resume [chatId]`, `--continue`, `agent ls`, `agent resume`.
   - **`cursor-agent create-chat` works logged out (live):** it printed `1871a527-7c04-4423-8fe0-3cf5f874ad23` and exited 0, so an id can be pre-created and then used with `--resume <id>`. No local file was written for it.
   - Waycar's `ClosedSession` `.cursor → ["--resume", id]` matches the flag.
8. **Model and effort (docs `--help`).**
   - Model: `--model <model>`.
   - Effort: no separate flag. It goes in the model's bracket parameters, for example `--model 'claude-opus-4-8[context=1m,effort=high,fast=false]'`.
   - `--list-models` needs login.
9. **Skills.**
   - Waycar's existing `AgentSkill.swift` entry: `.cursor/skills`, `.agents/skills`, and the `~` equivalents, invoked with `/`.
   - Grok also reads `~/.cursor/skills` (grok docs).
   - Not verified live, because the CLI cannot be used without login.
10. **Alt screen and mouse (live, login screens only).**
    - The login and QR screens draw inline: no `?1049h`, no mouse modes, `?2004h` on; `alternate_on=0`, `mouse_any_flag=0`.
    - The chat UI is UNVERIFIED. Market research found `?1049h` only in a few components [INFERENCE: mostly inline].
    - The input-ready marker is UNVERIFIED.
11. **herdr tier.**
    - **Live.** herdr 0.9.3 `integration status` lists `cursor: … (~/.cursor/herdr-agent-state.sh)`.
    - **Source review.** That script reports a session id from `session_id`, `sessionId`, `conversation_id` or `conversationId` on `sessionStart` (id form).
12. **Login (live).**
    - **First screen.** Centred text: `Cursor Agent` / `v2026.10.01-e373342` / `Press any key to log in...`.
    - **After a key.** `Signing in` / `If your browser didn't open, click this link to log in:` / `https://cursor.com/loginDeepControl?challenge=…&mode=login&redirectTarget=cli…` / `Press q to show a QR code to log in from another device`.
    - **After `q`.** `Scan this QR code to log in from another device:`.
    - `cursor-agent status` prints `Not logged in`.
    - **Detection markers.** `Press any key to log in` and `cursor.com/loginDeepControl`.
13. **No daemon.** [INFERENCE] Each launch is its own node process; a `persist` subcommand exists for sessions that survive disconnects (docs `--help`). Not verified live.

## Recommended implementation per layer

- **tmux Status Hooks.** The native events are sessionStart, beforeSubmitPrompt, preToolUse, postToolUse, stop and sessionEnd. Cursor has **no blocked event**, so Waycar cannot report `blocked` from hooks and must rely on the screen fallback, whose approval-dialog pattern is not captured yet. Fix the claude bleed first (`CURSOR_VERSION` discriminator).
- **Chat Mode / transcript.** Defer until someone with a Cursor account can capture `transcript_path` contents. The one Chat Prompt route is the sessionStart `additional_context` hook (docs only).
- **Resume.** Keep `--resume <id>`. Optionally pre-pin the id with `create-chat`.
- **Skills.** Keep the existing entry.
- **Prompt gate, alt screen, message jump.** Unverifiable without login; keep the generic gate.
- **Screen detection.** Classify `Press any key to log in` and `cursor.com/loginDeepControl` as a sign-in state, so the app does not report it as idle or working.
