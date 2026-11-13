# Qwen Code (`qwen`)

Version tested: **Qwen Code 0.25.1** (npm `@qwen-code/qwen-code`), harness lab (Ubuntu 24.04, tmux 3.4, herdr 0.9.3), **2026-10-12**.
Auth: `~/.qwen/settings.json` `modelProviders.openai` → `http://mock:8080/v1`, dummy key, `security.auth.selectedType: "openai"`; no account.
Raw captures: `/tmp/waycar-harness-captures/qwen/` on the Mac (hook stdin/env, `screen-*.ans`, `raw-*.bin`, `transcript/5f3ac653-….jsonl`, `mock-log.jsonl`).

Method key: **live** = lab; **docs** = cited URL; **help** = `qwen --help` 0.25.1.

## Shared with Gemini CLI (fork) vs diverged
- Shared: `-i/--prompt-interactive`, `-m`, `--approval-mode`, `--include-directories`, `@path` attachments (same `--- Content from referenced files ---` + `inlineData` parts), Gemini `parts` message bodies in transcripts, `run_shell_command` tool name, the inline `> Type your message or @path/to/file` input box, `GEMINI_PROJECT_DIR` env in hooks.
- Diverged (live): hooks use **Claude event names and Claude-shaped payloads** (not Gemini's BeforeAgent/AfterAgent); transcript is a Claude-style `uuid/parentUuid` JSONL under `~/.qwen/projects/`; `--append-system-prompt`/`--system-prompt` flags exist; **bare positional is one-shot** (exits), unlike gemini; uses the **alt screen + mouse**; `--resume <id>`; `--session-id` pin; default approval mode in this config is `auto`.

## 1. Hooks
- Config (docs https://raw.githubusercontent.com/QwenLM/qwen-code/main/docs/users/features/hooks.md; **live**): Claude format in `settings.json` → `hooks: {<Event>: [{matcher, hooks:[{type:"command", command, timeout}]}]}`; project `.qwen/settings.json` loaded live; user `~/.qwen/settings.json`. `qwen hooks` subcommand / `/hooks` (help).
- Event enum (bundle, live): `SessionStart`, `SessionEnd`, `SessionDelete`, `UserPromptSubmit`, `UserPromptExpansion`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PostToolBatch`, `PermissionRequest`, `PermissionDenied`, `Notification`, `Stop`, `StopFailure`, `SubagentStart`, `SubagentStop`, `PreCompact`, `PostCompact`, `InstructionsLoaded`, `MessageDisplay`, `TodoCreated`, `TodoCompleted`.
- Payload (live): every event carries `session_id`, **`transcript_path`** (incl. `SessionStart`), `cwd`, `hook_event_name`, `timestamp`, `permission_mode` (`auto`|`default`), `prompt_id` (`<session>########<n>`). Extras: `SessionStart.{source:"startup"|"resume", model}`, `UserPromptSubmit.{prompt, submitted_prompt}`, `PreToolUse/PostToolUse.{tool_name:"run_shell_command", tool_input, tool_use_id, tool_call_id, tool_response}`, `PermissionRequest.{tool_name, tool_input}`, `Notification.{notification_type, message, title}`, `Stop.{last_assistant_message, stop_hook_active, context_usage, …}`, `SessionEnd.reason:"prompt_input_exit"`.
- Order per prompt (live): `UserPromptSubmit` → `PreToolUse` → **`Notification{idle_prompt}`** → (`PermissionRequest` → `Notification{permission_prompt, "Qwen Code needs your permission to use run_shell_command"}` only when a dialog shows) → `PostToolUse` → **`UserPromptSubmit{prompt:""}`** (tool-result continuation) → `Stop` → `Notification{idle_prompt, "Qwen Code is waiting for your input"}`.
- **Hazards (live):** (a) `idle_prompt` fires ~15 ms after every `PreToolUse`, mid-turn, in both `auto` and `default` modes — do not map it to idle; (b) a second `UserPromptSubmit` with empty `prompt` fires after each tool result; (c) unlike Copilot, `PermissionRequest` fired **only** when the dialog was shown (read-only `echo` auto-allowed with no `PermissionRequest`).
- Blocked was forced live with a `PreToolUse` hook returning `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask"}}` (Claude semantics honoured).
- After a tool result, the continuation request ends with an extra `role:"user"` message holding only a `<system-reminder>` (the auto-memory catalog, `~/.qwen/memories/MEMORY.md` + `~/.qwen/projects/<slug>/memory/MEMORY.md`), so the last message is not the tool result (live, mock log, 0.25.1, 2026-10-12). Each finished turn also sends a `[SUGGESTION MODE …]` request (the input-row suggestion, §10) and a "managed memory extraction subagent" request.
- Env in hooks (live): `QWEN_CODE_SESSION_ID`, `QWEN_PROJECT_DIR`, `QWEN_CODE_PROJECT_DIR` (= `~/.qwen/projects/<slug>`), `QWEN_CODE_MODEL`, `QWEN_CODE_CLI`, **`CLAUDE_PROJECT_DIR`**, **`GEMINI_PROJECT_DIR`**.

### Claude-compat
- live: project `.claude/settings.json` capture hooks did **not** fire; Waycar's `~/.claude/settings.json` claude Status Hook did not fire in `~/work/probe-qwen` or with cwd `$HOME` (`@waycar_agent` unset). Source grep: Qwen reads `~/.claude/settings.json` and `.claude/settings.json` only to import **MCP servers**, and converts `.claude-plugin` extensions (rewriting `~/.claude/` → `~/.qwen/` in their scripts) — not hooks. Qwen accepts Claude-format hooks only from its own settings.

## 2. tmux pane identity
live: `TMUX_PANE` preserved; hook PPID = `node …/bin/qwen …` on `pts/10` = `#{pane_tty}`. Single process per pane (no relaunch child observed). `#{pane_current_command}` = `node`.

## 3. Executable
`qwen` (= kind id), Node script.

## 4. Transcript
- live: `~/.qwen/projects/<cwd with "/" → "-">/chats/<sessionId>.jsonl` (e.g. `-home-waycar-work-probe-qwen/chats/5f3ac653-….jsonl`); `transcript_path` given on every hook. Home override env `QWEN_HOME` exists in the bundle [UNVERIFIED]. Resume appends to the same file (same id).
- Format: JSONL, Claude-like envelope `{uuid, parentUuid, sessionId, timestamp, type, provenance, cwd, version, …}` with Gemini-style `message:{role:"user"|"model", parts:[…]}`:
  - `type:"user"` (`provenance:"real_user"`, `executionContext.{modelId, approvalMode}`, `promptId`, parts `{text}`; `@`-attachments add `{text:"\n--- Content from referenced files ---"}` + `{inlineData:{data,mimeType}}` parts),
  - `type:"assistant"` (`model`, parts `{text}` or `{functionCall:{id,name,args}}`, `usageMetadata`),
  - `type:"tool_result"` (parts `{functionResponse}`, `toolCallResult`),
  - `type:"system"` subtypes `ui_telemetry`, `file_history_snapshot`, `attribution_snapshot`, `at_command` (`systemPayload.{filesRead, userText}`).
- Images (live): `describe @probe.png` → `system/at_command` + user record with base64 `inlineData` part.

## 5. Chat Prompt injection route
- `--append-system-prompt "<text>"` (help; **live**: mock `system` contained `WAYCARMARK-QWEN-APPEND`). Also `--system-prompt` (replace). Inline text only — no file form, so the 1000-byte typed-line budget applies. `--include-directories <dir>` + `QWEN.md` is the file-based alternative [INFERENCE from the Gemini fork; not exercised].

## 6. First message
`-i "<prompt>"` (live: submitted, stayed interactive). **Bare positional is one-shot** (live: `qwen "positional POSQWEN"` printed the reply and exited; help "Defaults to one-shot"). `-p` deprecated.
- A pointer outside the workspace (`-i "Read and follow <stage>/…md"`): `read_file` runs at once in the default Auto mode, but `--approval-mode default` (Ask permissions) stops on "Do you want to proceed?" for the external path. `--include-directories <stage>` reads it at once in both modes (live, qwen 0.25.1, 2026-10-12).

## 7. Resume
`-r/--resume <id>`, bare `--resume` = picker, `-c/--continue` = most recent for the project, `--session-id <id>` = pin, `--fork-session` (help). **live**: `--resume 5f3ac653-…` and `--continue` resumed (`SessionStart.source:"resume"`, same id and file); `--session-id 22222222-3333-4444-8555-666666666666 -i …` produced that `session_id`. Exit prints `qwen --resume <id>`. Existing `["--resume", id]` matches.

## 8. Model / effort
`-m <model>` (live: mock `model:"mock-model"`; must match a configured `modelProviders` id). **No effort flag** (help); reasoning is settings-only [UNVERIFIED]. `--auth-type`, `--openai-base-url`, `--openai-api-key` exist.

## 9. Skills
live (headless `qwen "/<name>"` expanded the body): `.qwen/skills/<name>/SKILL.md` ✓, **`.agents/skills/<name>/SKILL.md` ✓**, `.qwen/commands/<name>.md` ✓ (flat markdown), `.claude/skills` ✗. Prefix `/`. `AgentSkill.swift` lacks `.agents/skills`. Home dirs (`~/.qwen/skills`, `~/.qwen/commands`) [docs, not exercised].

## 10. Alt screen / mouse / input readiness
- live raw bytes: `?1049h` (alt screen), `?1002h` + `?1003h` + `?1006h` (mouse), `?2004h`, `?1004h`, heavy `?2026h` synchronized output. `#{alternate_on}=1`, `#{mouse_any_flag}=1`.
- Input readiness (live): paste 0.8 s after launch **lost**; 1.5 s and 3 s accepted. Paste + immediate Enter submits (unlike gemini).
- After each turn Qwen pre-fills a **prompt suggestion** in the input row (`> waycar-mock-reply: explanation.` — generated by an extra model call); typing/pasting replaced it (live), Esc clears it. A bare Enter may accept the suggestion [INFERENCE].
- Ready marker: `>   Type your message or @path/to/file` between `────` rules, footer `➜ <dir> · git:(…) · <model>` and mode line (`Auto mode` / `⏸ Ask permissions`). Working: `.. <witty text> (Ns · esc to cancel)` + `Enter to steer · Ctrl+Q to queue`. Blocked: `? Shell <cmd> ←`, `Allow execution of: 'echo'?`, `› 1. Yes, allow once / 2. No, suggest changes (esc)`, `⠏ Waiting for user confirmation...`. Enter takes the highlighted `1. Yes, allow once` (live: harness lab e2e, `--approval-mode default` + a `touch` command, tmux and herdr, 2026-10-12).

## 11. herdr tier
herdr 0.9.3 (`herdr integration status`, live): `qwen: … ~/.qwen/hooks/herdr-agent-session.sh` → **session-identity only** (id form) once installed; status by screen [INFERENCE].

## 12. Login / first run
Runs on any OpenAI-compatible endpoint with no account (live). Qwen OAuth free tier ended 2026-04-15 (research report). Unconfigured first-run auth screen: UNVERIFIED (lab is pre-configured).

**Folder trust (live, 2026-10-12).** In 0.25.1, `security.folderTrust.enabled` defaults to false (bundled settings schema). The lab also sets it to false.
- **The dialog.** With trust on, an untrusted checkout opens on `Do you trust this folder?`, then `› 1. Trust folder (<name>)` / `2. Trust parent folder (<parent>)` / `3. Don't trust (esc)`.
- **Before the answer.** herdr 0.9.3 reports it `blocked` (`folder_trust_dialog` rule). On tmux, qwen's `SessionStart` hook sets `@waycar_status idle` under the dialog (+8 s).
- **Waycar.** Every prompt to a qwen Agent reads the screen first on both backends and fails `AgentFolderTrustRequiredError`, with nothing typed, while the dialog shows (`AgentScreen.trustDialogShown`).
- **Method.** Captured with a scratch `HOME` whose settings turned trust on.

## 13. Isolation flag
None; per-pane process on the pane tty (live). `qwen serve` daemon mode exists but is not used by the TUI.

## Recommended implementation per layer
- **tmux Status Hooks**: reuse the claude JSON-hook installer shape against `~/.qwen/settings.json` (`hooks` key, merge): `UserPromptSubmit`→working (ignore empty `prompt`? it is mid-turn, so still working — harmless), `PreToolUse`→working-if-active, `PermissionRequest` and `Notification` matcher `permission_prompt`→blocked, `Stop`→done, `SessionStart`→hook-session (session_id + transcript_path both present), `SessionEnd`→idle. **Do not** map `idle_prompt`. Add `qwen` to waycar-hook's case.
- **Chat transcripts**: new parser (Claude envelope + Gemini parts); skip `system` records except `at_command`; images from `inlineData`.
- **Chat Prompt**: `--append-system-prompt <text>` (inline, budget-limited) — new `.qwenAppend` route.
- **First message**: `-i <text>` (never bare positional).
- **Resume / pin**: `--resume <id>` (existing); `sessionPin` can use `--session-id <uuid>`.
- **Model/effort**: `-m <model>`; effort: cannot support via CLI.
- **Skills**: add project/home `.agents/skills`.
- **Prompt gate**: wait ≥1.5 s or for the `Type your message` row; Enter right after paste is fine.
- **Message jump**: alt screen + mouse → standard alt-screen handling.
- **Agent Summaries**: `qwen "<instruction>"` one-shot (positional) or `-p` [one-shot observed live].
