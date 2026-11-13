# Claude Code (`claude`): re-verification on 2.1.296

Version tested: **Claude Code 2.1.296** (`claude.ai/install.sh`, linux aarch64) in the harness lab: Ubuntu 24.04, tmux 3.4, herdr 0.9.3, and Waycar Host Tools installed from this worktree. Date: 2026-10-12. The model is the lab mock (`ANTHROPIC_BASE_URL=http://mock:8080`). This file records only what changed since the AGENTS.md facts (Claude Code 2.1.286), plus confirmation of what still holds. It does not restate those facts.

Method tags: **live** means observed in the lab on this version; **source** means review of this worktree. Raw captures are in `/tmp/waycar-harness-captures/claude/` on the Mac:

- `hooks/`: stdin, env and parent tty for every event.
- `a/`, `b/`: `opts.log` (a 0.1 s poll of `@waycar_*`, `alternate_on` and `pane_current_command`), `screen-*.ansi` (`capture-pane -e -p`) and `raw.bin` (`pipe-pane` bytes).
- `transcripts/`: the JSONL transcripts, the staged prompt files and `readchat.ndjson`.
- `mock-log.jsonl`.

The probe tools are in `../deep-five-tools/`.

## Drift (action needed)

1. **Waycar's tmux Status Hooks write nothing under claude 2.1.296 (live).**
   - **What happens.** Claude runs every hook as `/bin/sh -c …` in a new session. The hook's `$PPID` is that `sh`, and `ps -o tty= -p $PPID` returns `?` (`hooks/*-SessionStart.txt`: `ppid_comm=sh ppid_tty=?`). `waycar-hook` (`plugin/bin/waycar-hook`) and `hook-session.js` (`readTty(process.ppid)`) both treat `?` as a mismatch and exit 0.
   - **Effect.** Across 22 captured hook events (SessionStart, UserPromptSubmit, PreToolUse, PermissionRequest, Notification, PostToolUse, Stop, SessionEnd) in one session and its resume, no `@waycar_status`, `@waycar_agent`, `@waycar_session` or `@waycar_transcript` was ever set on the pane (`a/opts.log`). A second session launched with Waycar's own hooks only (`b/opts.log`) gave the same result. The hooks themselves fire on time, with the expected payloads.
   - **Knock-on effects (source).**
     - The tmux claude launch gate (`TmuxTransport.checkLaunchReadiness`) never sees `@waycar_session`. It opens only when `claudeLaunchReadyTimeout` (8 s) expires.
     - Status falls back to the screen watch (`TmuxScreenDetector.classifyClaude`).
     - Closed Sessions record no session, so a resume uses the bare `--resume` picker. The exception is a Chat Mode launch, which pins `--session-id`.
     - Chat transcripts are still found: by the pinned id, or by `findByLaunch` (live, below).
2. **Resume keeps the session's original appended system prompt (live).**
   - **What was run.** Session `5d930c96…`, launched with `--append-system-prompt-file chat-prompt.md` (marker `CHATMARKER-claude`), was resumed with `--append-system-prompt-file chat-prompt2.md` (`CHATMARKER2-claude`) `--resume <id>`.
   - **Result.** The resumed request's `system` contained `CHATMARKER-claude` and not `CHATMARKER2` (`mock-log.jsonl`, the 16:39 entry whose lastUser is `after resume WAYCAR_RESUMED`).
   - **Consequence.** A Chat Prompt survives a resume. A Chat Prompt edited between launch and resume does not apply to the resumed session.
3. **The default permission mode is `auto` in this lab (live).**
   - The footer reads `⏵⏵ auto mode on`. `echo` ran without a prompt in both auto and manual mode, because a read-only command is auto-allowed.
   - An approval dialog appeared only with `permissions.ask: ["Bash"]` (via `--settings`, `capture-settings-ask.json`).
   - There is no code impact. It matters only for anyone trying to reproduce blocked.

## Confirmed (still matches Waycar's code)

### Status Hooks
- **Events fire as `CLAUDE_ENTRIES` expects (live, `hooks/`).**
  - SessionStart (`source: startup|resume`, carrying `session_id` and `transcript_path`) fires at launch, before any prompt.
  - UserPromptSubmit, then PreToolUse.
  - PermissionRequest fires 0.3 s after the dialog draws.
  - `Notification` with `notification_type: "permission_prompt"` follows 6 s later.
  - Then PostToolUse and Stop.
  - SessionEnd carries `reason: "prompt_input_exit"`.
  - New payload fields seen: `prompt_id` and `effort: {level}`. On resume, SessionStart adds `seconds_since_last_response`, `context_tokens` and `prompt_cache_likely_expired`.
- **Valid hook events.** 2.1.296 lists PreToolUse, PostToolUse, PostToolUseFailure, PostToolBatch, Notification, UserPromptSubmit, UserPromptExpansion, SessionStart, SessionEnd, Stop, StopFailure, SubagentStart, SubagentStop, PreCompact, PostCompact, PreModelSwitch, PostModelSwitch, PermissionRequest, PermissionDenied, Setup, TeammateIdle, TaskCreated, TaskCompleted, Elicitation, ElicitationResult, ConfigChange, WorktreeCreate, WorktreeRemove, InstructionsLoaded, CwdChanged, FileChanged, DirectoryAdded and MessageDisplay (live; quoted from the "Settings Warning" dialog).
  - An unknown event in `~/.claude/settings.json` (for example `StopCancelled`) opens a **blocking** Settings Warning dialog at launch.
  - Every event Waycar installs is valid.

### Chat Mode launch line
The launch argv is built by `LaunchPromptStager` (route `.claudeFile`) plus `ChatModeLaunch` (live):

```
claude --append-system-prompt-file <stage>/chat-prompt.md --model probe-model-claude --effort low --session-id <uuid> -- 'Read and follow <stage>/first-message.md'
```

- **Capability probe.** `claude --help` still matches the probe's `append-system-prompt[-file]` pattern.
- **Result (mock log, the 16:38:56 entries).**
  - The marker is in `system`.
  - `model: probe-model-claude`, `effort: low`.
  - The first user message is the pointer.
  - The transcript is `~/.claude/projects/-home-waycar-work-demo/<pinned uuid>.jsonl`.
  - The banner reads `probe-model-claude with low effort`.
  - Claude's title-generation side request uses `effort: high`; this is harmless.
- **Resume.** `--resume <id>` reopens the full history, and the next request carries the earlier turns.

### Transcript
- **Format.** Claude's transcript is still `~/.claude/projects/<cwd-dashed>/<session_id>.jsonl`.
- **Parser (live).** `plugin/src/chat-transcript.js` `readChat`, run with `node` on the host, returned `status: ok`:
  - **By id:** a 3-turn session plus a resumed 4th turn gave 10 messages.
  - **By `findByLaunch`** (cwd plus launch time): it found the same file.
- **User-attached images.** An image pasted by path (`[Image #1]`) reached the model as an image block. The parser shows only its text. Media come only from tool results, by design (`claudeToolResultImages`).

### TUI and input
- **Alternate screen and mouse (live, `a/raw.bin`).** `?1049h` plus `?1000h ?1002h ?1003h ?1006h`; also `?2004h`, `?1004h` and `?2031h`.
  - With tmux mouse off, the TUI hints `tmux detected · scroll with PgUp/PgDn`.
  - `pane_current_command` is `claude`.
- **Input-ready (live).** Bracketed pastes every 0.4 s from 0.1 s after the login shell spawned were all kept, typed ahead in the tty. The first paste lost its trailing space (`r0.1r0.5`). There is no early-drop window, so the 8 s gate is conservative but safe.
- **Screen fallback (manual check of `classifyClaude` rules against `a/screen-*.ansi`).**
  - **working:** the footer below the last rule has `· esc to interrupt ·`.
  - **idle:** the head line is `✻ Brewed for 1s · done 4:37 PM` (glyph, verb, `for`, duration).
  - **welcome:** shows `Claude Code v2.1.296` and no turns.
  - **blocked:** the footer after the dialog's full-width rule has `Do you want to proceed?` and `Esc to cancel · Tab to amend`.
  - All four still match.

### Skills
`~/.claude/skills/<name>/SKILL.md`, invoked as `/name`: `claude -p '/wprobe-claude go'` expanded the skill body (mock log). This matches `SkillSourceCatalog` (live).

## Recommended implementation per layer
- **tmux Status Hooks (PluginHooks):**
  - Fix the tty guard rather than drop it. The candidates, both untested:
    - read the tty of `$CLAUDE_PID` when `CLAUDECODE=1`;
    - walk one more parent when `$PPID` is a session leader with no tty.
  - Keep `TMUX_PANE` matching.
  - Make sure grok/cursor/devin cannot pass the new check as "claude" (grok sets `GROK_*` env and runs as `grok`; see `grok.md`).
- **hook-session.js:** apply the same guard change, or `@waycar_session` stays empty.
- **App (AppHarness):** nothing is needed once hooks work again. Until then the 8 s gate and the screen fallback carry claude on tmux.
- **Chat Mode:** no change. Optionally note in the UI copy that an edited Chat Prompt does not reach a resumed claude session.
- **Transcripts and parser:** no change.
- **herdr backend:** see `herdr-backend.md`.
