# Grok Build (`grok`)

Version tested: **Grok Build 1.0.50 (c58f321264ba)**, linux aarch64 (installed by `x.ai/cli/install.sh`), in the harness lab (Ubuntu 24.04, tmux 3.4, herdr 0.9.3 server running, Waycar Host Tools installed from this worktree). Date: 2026-10-12. The model is the lab mock, configured as a custom model in `~/.grok/config.toml` (`[model.mock]`, `api_backend = "chat_completions"`, `base_url = "http://mock:8080/v1"`). No xAI account is needed.

Method tags: **live** = observed in the lab on this version; **docs** = the user guide that ships with the binary (`~/.grok/docs/user-guide/*.md`, the same text as `https://raw.githubusercontent.com/xai-org/grok-build/main/crates/codegen/xai-grok-pager/docs/user-guide/`); **source** = source or binary review. Raw captures are in `/tmp/waycar-harness-captures/grok/` on the Mac (hook stdin, env and process chain for each event, session directory, screens, raw pty bytes, mock log).

## The Claude-hook bleed (primary finding)

- **Grok runs Waycar's Claude Status Hooks (live).** By default grok loads `~/.claude/settings.json` hooks. `grok inspect --json` lists 9 of Waycar's 12 claude entries with `"vendor": "claude", "compatibilityStatus": "enabled"`: SessionStart (hook-session.js), UserPromptSubmit, PostToolUse, PostToolUseFailure, Stop, StopFailure, both Notification groups, and SessionEnd. PermissionRequest and ElicitationResult are skipped because grok has no such events. The PreToolUse entry with matcher `^(?!(AskUserQuestion|ExitPlanMode)$)` is not listed either. My guess is that grok's Rust regex has no look-ahead, so it drops the entry silently ([INFERENCE]; no load error appears in `~/.grok/logs/unified.jsonl`). `updates.jsonl` records the Waycar hooks running on every event (`hook_execution` → `global/settings:session_start[1].hooks[0]` … `status: success`).
- **Today they write nothing, but only by accident (live).** Grok runs every hook as `sh -c '<command>'` in a **new session**: the `sh` is the session leader (pid == sid) and has no controlling tty (`ps -o tty=` → `?`). Its parent is the grok process on the pane's tty. `waycar-hook`'s guard reads `ps -o tty= -p $PPID`, gets `?`, and exits; the `sh -x` trace ends in `agent_tty=? … exit 0` (`hooks/trace-waycar-hook-claude-under-grok.txt`). `hook-session.js` exits the same way because `readTty(process.ppid)` is null. No `@waycar_*` option was ever set on the grok panes (a 0.2 s poll across 3 sessions).
- **What it would write without that accident (live simulation).** I fed grok's real SessionStart payload to `hook-session.js claude`, and called `waycar-hook claude working`, from a shell whose tty matches the pane. The result was `@waycar_agent claude`, `@waycar_session 01a130f5-…` (grok's id, read from the `session_id` alias grok adds) and `@waycar_status working`. The pane would be mislabelled claude, and Closed Sessions would offer `claude --resume <grok-uuid>`. Grok also sends a session-end `Stop` (`reason: "shutdown"`) about 50 ms **after** `SessionEnd`, so `Stop → done` would set `done` again right after `release` cleared the pane.
- **The same tty guard also blocks Claude Code 2.1.296's own hooks (live).** In this lab, claude also runs hooks as `/bin/sh -c` in a new session with tty `?`. Four `sh -x` traces of `waycar-hook claude working` from a real claude in tmux pane `%28` (`/dev/pts/18`) all end in `agent_tty=? → exit 0` (`/tmp/waycar-harness-captures/claude-compat/waycar-hook-traces/`). The claude process itself (`CLAUDE_PID=108570`) is on `pts/18`, the pane tty. So the guard is not a working defence against the bleed. It currently disables Waycar's tmux Status Hooks for both claude 2.1.296 and grok 1.0.50. This contradicts AGENTS.md T18/T10 (verified on 2.1.286), and the claude dossier should re-verify it.
- **Discriminators observed in the hook environment (live).** Each was checked on every captured event:

| Signal | grok 1.0.50 | claude 2.1.296 |
|---|---|---|
| `GROK_HOOK_EVENT`, `GROK_HOOK_NAME`, `GROK_SESSION_ID`, `GROK_WORKSPACE_ROOT` | always set | absent |
| `CLAUDECODE=1`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID` | absent | always set |
| `CLAUDE_PROJECT_DIR` | **set** (grok sets this compat alias) | set, so not a discriminator |
| payload `hookEventName` (camelCase, snake_case value) and `sessionId` | always present | absent |
| `$PPID` | `sh -c` (dash), new session, tty `?` | `/bin/sh -c`, new session, tty `?` |
| grandparent (`ps -o ppid= -p $PPID`) | `grok` (exe `~/.grok/downloads/grok-linux-aarch64`), pane tty | `claude` (= `$CLAUDE_PID`), pane tty |
| `TMUX`, `TMUX_PANE` | inherited, correct pane | inherited, correct pane |

## Bleed fix (recommendation for PluginHooks)

A positive identity check plus a foreign-marker deny list, in both entry points. The markers are live for grok 1.0.50 and claude 2.1.296, and from docs and source for cursor 2026.10.01 and devin 3000.11.3:

- **`plugin/bin/waycar-hook`**, right after the `HERDR_PANE_ID`/`HERDR_ENV` check (line 38):
  ```sh
  # Grok, Cursor and Devin also run ~/.claude/settings.json hooks.
  if [ "$agent" = claude ]; then
    [ -z "${GROK_HOOK_EVENT:-}${GROK_SESSION_ID:-}${CURSOR_VERSION:-}${DEVIN_PROJECT_DIR:-}" ] || exit 0
    [ "${CLAUDECODE:-}" = 1 ] || exit 0
  fi
  ```
  The deny list catches a foreign harness that was started from inside a claude session and so inherits `CLAUDECODE=1`.
- **`plugin/src/hook-session.js` `sessionUpdate()`**, next to the `agent_id` check (line 52). Return null when `agent === "claude"` and any of these hold: `env.GROK_HOOK_EVENT`, `env.GROK_SESSION_ID`, `env.CURSOR_VERSION` or `env.DEVIN_PROJECT_DIR` is set; `env.CLAUDECODE !== "1"`; or the payload has `hookEventName` or `cursor_version`. The payload checks are a second, env-independent signal. A stronger claude-only check is `env.CLAUDE_CODE_SESSION_ID === input.session_id` (live on 2.1.296).
- **Tty guard, in both files.** It must stop reading `$PPID`'s tty: claude 2.1.296 and grok 1.0.50 run hooks from a tty-less `sh -c` session leader. Use the agent's pid instead:
  - claude: `$CLAUDE_PID` (live: its tty is the pane tty).
  - every other kind: one hop up, accepted only when `$PPID` has no tty, i.e. `ps -o ppid= -p $PPID`, then that process's tty.
  - Codex's shared app-server still fails this check, because the daemon has no tty. Re-verify codex in the lab.
  - In `waycar-hook` the change is at line 79 (`agent_tty=$(ps -o tty= -p "$PPID")`); in `hook-session.js` it is `readTty(process.ppid)` at line 133.
- **Don't disable the compat loaders instead.** `[compat.claude] hooks = false` (grok), `read_config_from.claude = false` (devin) and Cursor's third-party toggle would also switch off the user's own Claude hooks in those harnesses. Waycar should not change them.

## Probe answers

1. **Hook config and events**
   - **Config.** JSON hook files (claude schema: `{"hooks": {"<Event>": [{"matcher"?, "hooks": [{"type":"command","command","timeout","env"}]}]}}`) are read from `~/.grok/hooks/*.json` (always trusted) or from `[[hooks.<Event>]]` tables in `~/.grok/config.toml`. Project `.grok/hooks/*.json` needs folder trust. Grok also reads the compat files `~/.claude/settings.json` (+`.local`) and `~/.cursor/hooks.json`, which `[compat.claude|cursor] hooks = false` or `GROK_CLAUDE_HOOKS_ENABLED` / `GROK_CURSOR_HOOKS_ENABLED=false` turn off (docs 10-hooks, 26-config-reference).
   - **Events** (docs): SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, PostToolUseFailure, PermissionDenied, Stop, StopFailure, StopCancelled, Notification, SubagentStart/Stop, PreCompact/PostCompact, SessionEnd. There is **no PermissionRequest**: approval shows up as `Notification` with `notificationType: "permission_prompt"`.
   - **Live sequence for the 3-turn session.**
     - At launch: SessionStart (`source: "new"`) at +0.4 s, before any prompt.
     - Turn 1: UserPromptSubmit, then Stop (`reason: "end_turn"`) 1.6 s later.
     - Turn 2 (tool with approval): UserPromptSubmit, PreToolUse, then `Notification permission_prompt` 85 ms after PreToolUse, while the approval dialog is on screen. After approval: PostToolUse, then Stop.
     - About 60 s after a turn settles: `Notification idle_prompt`.
     - On `/quit`: SessionEnd (`reason: "shutdown"`), then Stop (`reason: "shutdown"`) about 50 ms later.
     - On `--resume`: SessionStart (`source: "load"`).
   - **Payload (live).** Every event carries camelCase fields plus snake_case aliases: `hookEventName` (`session_start`…) and `hook_event_name` (`SessionStart`…); `sessionId` and `session_id`; `permissionMode` and `permission_mode`; `cwd`, `workspaceRoot`, `timestamp`. Turn events carry `promptId`.
   - **Transcript path in the payload (live).** `transcriptPath`/`transcript_path` is the session's `updates.jsonl`. It is **absent from SessionStart `source:"new"`**, but present on every later event and on SessionStart `source:"load"`.
   - **Hook environment (live).** Grok sets `GROK_HOOK_EVENT`, `GROK_HOOK_NAME`, `GROK_SESSION_ID`, `GROK_WORKSPACE_ROOT` and `CLAUDE_PROJECT_DIR` on every hook.
   - **`$` expansion (live).** Grok expands `$VAR` in hook commands: `$$` reached the shell as a literal `$`. Waycar's hook commands must not contain `$`.
   - **Timeouts (docs).** Default 5 s; Stop and PostToolUse 600 s.
2. **tmux pane identity (live)**
   - `TMUX_PANE` is preserved and correct.
   - `ps -o tty= -p $PPID` gives `?`: the hook's parent is a session-leader `sh` with no tty. The grandparent is the pane's `grok` process, whose tty matches `#{pane_tty}`.
   - This is not a shared daemon: each pane's grok runs its own hooks.
3. **Executable (live).** The executable is `grok` (`~/.grok/bin/grok`, a symlink to `~/.grok/downloads/grok-linux-aarch64`). `ps` comm and `pane_current_command` both read `grok`, which equals the kind id.
4. **Transcript (live)**
   - **Location.** `~/.grok/sessions/<percent-encoded cwd>/<session-id>/updates.jsonl`, for example `~/.grok/sessions/%2Fhome%2Fwaycar%2Fwork%2Fdemo/01a130f5-82fd-79c3-b63d-a2aa609ea70e/updates.jsonl`. `$GROK_HOME` replaces `~/.grok` (docs). Session ids are UUIDv7.
   - **`updates.jsonl` format.** JSONL of ACP notifications: `{timestamp: <epoch s>, method: "session/update" | "_x.ai/session/update", params: {sessionId, update: {sessionUpdate, …}}}`.
   - **Update types seen.**
     - `user_message_chunk` (`content.text` = raw prompt, `_meta.promptIndex`)
     - `agent_message_chunk` (`content.text`)
     - `tool_call` (`toolCallId`, `title`, `rawInput`)
     - `tool_call_update` (status `completed`, `rawOutput.output_for_prompt`)
     - `turn_completed` (`prompt_id`, `stop_reason`, `usage`, `elapsed_ms`)
     - `hook_execution`
     - `background_tasks`
   - **Flat records.** There is no parentId tree. Each mock reply was stored as one `agent_message_chunk`. Whether long streamed replies are coalesced or stored as many chunks is UNVERIFIED: the mock's replies are short.
   - **Other files in the session directory.** `chat_history.jsonl` (the model-facing history, `{type: system|user|assistant|tool_result, …}`, with user text wrapped in `<user_query>`), `summary.json` (title, `created_at`/`updated_at`, `current_model_id`), `system_prompt.txt`, `prompt_context.json`, `events.jsonl`, `signals.json`, `usage.json`, `terminal/<call>.log`.
   - **Resume.** Appends to the same directory.
5. **Chat Prompt route (live).** `--rules "<text>"` (alias `--append-system-prompt`) appends the text to the system prompt. The mock log shows the marker `WAYCAR_RULES_MARKER_7731` in the `system` of every main-turn request, and `system_prompt.txt` holds it.
   - **Persists across resume.** After `grok --resume <id>` **without** `--rules`, the next request still carried the marker.
   - **No file form.** `--prompt-file` is a headless single-turn prompt, not a rules file. A `GROK_CONFIG='{"paths":{"extra_rule_dirs":[…]}}'` overlay did **not** inject a rules file (tested headless).
   - **Replacement.** `--system-prompt-override` replaces the system prompt instead of appending.
   - **Length.** The text travels inline in argv, so the launch command's typed-line budget applies.
6. **First message (live).** A positional `[PROMPT]` (`grok … "text"`) is submitted at once in the TUI: UserPromptSubmit at +0.4 s, and the reply rendered.
7. **Resume (live)**
   - `grok --resume <session-id>` (`-r`) reopens the session: same id, SessionStart `source:"load"`, history redrawn.
   - On exit grok prints `Resume this session with:` / `grok --resume <id>`.
   - `-c` (most recent session in the cwd) and `-r` with no value were not run (docs).
   - `-s/--session-id <uuid>` pre-assigns the id of a **new** session. Live (headless): the JSON `sessionId` and the directory name equal the given UUID.
   - Waycar's `ClosedSession` `.grok → ["--resume", id]` is correct.
8. **Model and effort**
   - **Model (live).** `-m <key>` takes a `[model.<key>]` config key; `-m mock` sent `"model": "mock-model"`.
   - **Effort.** `--effort` / `--reasoning-effort <none|minimal|low|medium|high|xhigh|max>` is accepted without error, but **no effort field reached the mock**, even with a `reasoning_efforts` or `supports_reasoning_effort` overlay on the custom model. Wire behaviour is UNVERIFIED: the docs say a model only accepts the levels its menu advertises, and the menu comes from config or `/v1/models`.
   - **Extra requests (live).** Grok also sends a model-id `grok-4.6` request to the configured endpoint at the first prompt, and two extra requests after each turn: prompt-suggestion (system ≈1 KB) and title (≈0.6 KB). Mock-log assertions must select the main request by `tools.length > 0` and the marker.
     - **The `grok-4.6` request is the session title (live, 2026-10-12 e2e run).** It goes out about 10 ms before the main request, whatever `-m` says, with the system prompt `You are tasked with generating the session title…`, the first prompt as its only user message (in `<user_query>`), and exactly one tool, `session_title`. `tools.length > 0` therefore does not tell it from the main request; the main one carries ~25 tools, the shell among them. The lab mock answers it as bookkeeping by calling `session_title` (`scripts/harness-lab/mock/server.js`).
9. **Skills**
   - **Live.** `~/.grok/skills/<name>/SKILL.md` was discovered: `grok inspect --json` → `skills[].source.path`, `userInvocable: true`.
   - **Docs (08-skills).**
     - Directories: `./.grok/skills/`, `./.grok/commands/*.md` (flat legacy commands), `<repo_root>/.grok/skills/`, `~/.grok/skills/`, `~/.grok/commands/`, `~/.claude/skills|commands/`, `./.claude/skills|commands/`, `~/.cursor/skills/`, `./.cursor/skills/`, and `.agents/skills/` at each tier.
     - Precedence and dedupe: CWD > repo > user; skills are deduplicated by name.
     - Invocation: `/<name>`, or `/<scope>:<name>` on a clash. A skill needs `user-invocable: true` to be offered as a slash command.
   - **Waycar today.** `AgentSkill.swift` probes `.grok/skills`, `~/.grok/skills` and `~/.agents/skills`.
10. **Alt screen, mouse and input readiness (live, `tmux pipe-pane`)**
    - **Default.** `?1049h` (alternate screen), `?1000h ?1002h ?1003h ?1006h` (mouse, any-motion, SGR), `?2004h` (bracketed paste) and `?1004h` (focus).
    - **`--no-alt-screen`.** Inline, but mouse stays on (`?1000/1002/1003/1006h`).
    - **`--minimal`.** No alt screen and no mouse.
    - **Input readiness.** A bracketed paste 0.2–0.8 s after `grok⏎` landed in the composer, and paste+Enter at +0.3 s submitted. At +0.05 s, before grok took the tty, the text arrived through the shell's typeahead but the Enter was lost.
    - **Ready marker.** A rounded box row `│ ❯ … │` whose bottom border ends with the model label, for example `── mock-model (Waycar harness lab mock) ─╯`. It is drawn within 0.5 s of launch.
    - **Working screen.** A status row `⠼ Waiting for response… 0.6s … [stop]` and the footer `Ctrl+c:cancel`.
    - **Blocked screen.** An `┃`-bordered approval panel with the tool title and command, then the options `1 (●) Yes, and don't ask again for anything (always-approve mode)`, `2 (○) Always allow: echo`, `3 (○) Yes, proceed`, `4 (○) No, reject`, `5 (○) Never allow: echo`, and the footer `1/5:select │ Tab:next option │ … Ctrl+o:always-approve`. Option 1 (always-approve) is preselected, so **Enter on a blocked grok pane switches the session to always-approve**. Pressing `3` approved once.
    - **Done screen.** `Worked for 1.7s` under the reply.
    - **Prompt suggestion.** After each turn the composer shows a model-generated suggestion (`❯ waycar-mock-reply: …`, footer `Tab/→:accept suggestion`). A screen reader must not treat it as a user draft.
    - **Escape handling.** A double `Esc` (≥ 0.25 s apart) clears the draft and stashes it (`Stashed` badge), and the stash is restored after the next send.
11. **herdr tier**
    - **Integration exists (live).** herdr 0.9.3 `herdr integration status` lists `grok: not installed (~/.grok/hooks/herdr-agent-state.sh)`, so a herdr integration exists.
    - **Behaviour (source review of `~/src/herdr/src/integration/assets/grok/herdr-agent-state.sh`).** It reports `pane.report_agent_session` on SessionStart using `GROK_SESSION_ID` (id form).
    - **Correction.** The HarnessFeatureMap's "screen-manifest only" line is out of date for 0.9.3. Detection manifest: present.
12. **Login (live).** No login is needed with a custom model: the footer reads `Logged in with API key`.
    - **First screen.** A box with `Grok Build  1.0.50`, `Changelog`, and the menu `New worktree ctrl+w`, `Resume session ctrl+r`, `Changelog`, `Quit ctrl+q`. Above it: `Clipboard may be unreachable. Run /doctor for details and fixes.`
    - **Folder trust (live, 2026-10-12).** grok first shows `Do you trust the contents of this directory?` with `Yes, proceed  y` / `No, quit  n`, but only in a folder missing from `~/.grok/trusted_folders.toml` that has project config. A dialog appeared with `AGENTS.md`, `.claude/settings.json` or `.grok/hooks/*.json`, in a git checkout or not; none appeared in an empty folder or a bare git checkout (tmux sweep). The docs tie it to project hooks, MCP, LSP, instructions and skills (docs 10-hooks).
      - **Before the answer.** No hook fires (`@waycar_*` unset at +3 s and +10 s). herdr 0.9.3 reads the screen as `idle` (`rule: osc_title_idle`, `interactive_ready: true`). A positional first message waits behind the dialog and is submitted once the folder is trusted.
      - **What a typed prompt did.** In the e2e run, Waycar's herdr prompt was typed into the dialog. The `Y` of `hello WAYCAR_…` trusted the folder (`[folders."<cwd>"] trusted = true, decided_at = <epoch s>` was written) and the rest of the text was lost. A prompt with an `n` before any `y` would presumably quit grok [INFERENCE].
      - **Waycar.** Every prompt to a grok Agent reads the screen first on both backends and fails `AgentFolderTrustRequiredError`, with nothing typed, while the dialog shows (`AgentScreen.trustDialogShown`). tmux also shows the dialog as Blocked (`TmuxScreenDetector`).
      - **Lab.** The lab pre-trusts `~/work/demo` (`host/config/grok/home/.grok/trusted_folders.toml`).
    - **Real accounts.** Not tested: browser OAuth, `grok login --device-auth`, `XAI_API_KEY` (docs 02-authentication).
13. **No daemon (live).** Hooks and model calls come from the grok process in the pane. No shared server was seen and no isolation flag is needed.

**Images: no supported route (live).**
- Waycar cannot send an image to grok through tmux. A bracketed paste of a PNG path (`/home/waycar/probe/red.png`, also quoted and as `file://…`) stays plain text, and `@/abs/path.png` is sent as text: the mock got only `<user_query>…@/home/waycar/probe/red.png</user_query>`, with no image part.
- Docs (03-keyboard-shortcuts) attach images only from the clipboard (Ctrl+V/Cmd+V) or by drag-and-drop from a local file manager. Over SSH/tmux the clipboard is unreachable, as `/doctor` warns.
- The transcript shape of an image turn is therefore UNVERIFIED.

## Recommended implementation per layer

- **tmux Status Hooks**
  - **Where.** Add `grok` to `HOOK_AGENTS` and install `~/.grok/hooks/waycar.json`: global, always trusted, and does not touch the user's claude or cursor files.
  - **Event mapping.**
    - SessionStart → `hook-session.js grok`.
    - UserPromptSubmit → `working`.
    - PreToolUse → `working-if-active`.
    - Notification `permission_prompt` → `blocked`.
    - PostToolUse and PostToolUseFailure → `working-if-blocked`.
    - Stop and StopFailure → a new `done-if-active` status (only from working or blocked), so the session-end `Stop` after `SessionEnd` cannot set `done` on a released pane.
    - StopCancelled → `idle`.
    - Notification `idle_prompt` → `idle-if-working`.
    - SessionEnd → `release`.
  - **Tty guard.** The guard must compare the **grandparent's** tty, because the parent `sh` has none.
  - **Subagents.** A subagent's own `SessionEnd` carries `subagentType` (docs, not exercised) and would release the parent pane, so the grok SessionEnd entry needs a JSON-aware filter. Run it through a node entry, as `hook-session.js` does.
  - **Avoid `$`.** Hook commands must not contain `$`.
- **Claude-hook bleed fix.** See [Bleed fix](#bleed-fix-recommendation-for-pluginhooks) above.
- **hook-session (grok).**
  - **Session id.** Take it from `GROK_SESSION_ID` (or the payload's `sessionId`).
  - **Transcript.** On `source:"new"` there is no transcript path in the payload. Derive `${GROK_HOME:-~/.grok}/sessions/<encoded cwd>/<id>/updates.jsonl`, or record it on the first UserPromptSubmit, which carries `transcriptPath`. The encoding matched `encodeURIComponent` for `/home/waycar/work/demo`; other characters are [INFERENCE].
  - **Status.** Treat `new` and `load` as idle.
- **Notifications.** No kind-specific work: blocked and done come from the status mapping above.
- **Chat Mode.**
  - **Prompt route.** Add a `grokRules` Chat Prompt route passing `--rules <text>` inline. There is no file form, so a long Chat Prompt must fit the typed budget or be launched via the new-window command.
  - **First message.** Positional `[PROMPT]`.
  - **Model and effort.** `-m <key>`, plus `--effort <level>` (accepted; wire unverified against custom models).
  - **Images.** Not supportable: there is no text route for attaching an image in the TUI.
- **Transcript.** Add a parser for `updates.jsonl`.
  - **Messages.** User text comes from `user_message_chunk`, assistant text from `agent_message_chunk`, grouped by `turn_completed`.
  - **Activity.** Tool lines come from `tool_call` and `tool_call_update`.
  - **Timestamps.** Use the top-level `timestamp` (epoch seconds).
  - **Discovery.** Find the file through `@waycar_transcript` or the encoded-cwd glob.
- **Resume / Closed Sessions.** Keep `--resume <id>`. Waycar could also pin the id up front with `-s <uuid>`, as for claude and pi.
- **Message jump.** Default is alt screen + mouse. Keep the existing `.grok` `stickyPromptOvershoot` profile, or launch with `--no-alt-screen` if the transcript-jump path is preferred; mouse stays on.
- **Skills.** Add `.agents/skills` (project), `.grok/commands` and `~/.grok/commands` (`.markdownFiles`), and the Claude compat roots `.claude/skills` and `~/.claude/skills` (on by default in grok).
- **Prompt gate.** The generic `launch_pending` gate is enough: the input box is up within 0.5 s and early pastes land. The one exception is a send-before-exec race, already covered by the gate. No `OpencodeScreen`-style gate is needed.
- **Blocked-screen input.** Never send a bare Enter to a blocked grok pane: the default choice is always-approve.
- **tmux launch.** `executable = "grok"` (the default raw value). No `--no-daemon` equivalent is needed.
- **Agent Summaries.** Possible headless: `grok -p "<instruction>" --output-format json` returns `{text, sessionId, …}` (live).
