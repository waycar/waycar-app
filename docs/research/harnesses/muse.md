# Muse Code (`muse`)

Version tested: **Muse Code 1.4.6 (1.4.6-R6000.1)**, Meta's closed-source, auto-updating native binary (https://dev.meta.ai/docs/muse-code.md). Tested in the harness lab (Ubuntu 24.04 aarch64, tmux 3.4, herdr 0.9.3) on **2026-10-12**.
Install: `curl -fsSL https://dev.meta.ai/install.sh | bash` puts a launcher at `~/.local/bin/muse`. The launcher downloads `muse-bin-<version>` (323 MB) from the `muse-stable` channel with no login, and on later runs it updates itself hourly. `MUSE_NO_AUTO_UPDATE=1` turns that off (launcher source, live).
Auth: a Meta API key (`META_API_KEY`, or `muse auth set --provider meta --api-key-stdin` → `~/.config/muse/auth.json`) or a browser device login. A custom endpoint needs no Meta account. The settings pin `endpoint_transport: {base_url, auth:"bearer"}` in `~/.config/muse/settings.json` sends the stored key to that URL (https://github.com/evangit2/muse-code-custom-provider; live: `http://mock:8080/v1`, OpenAI Responses plus `GET /muse-code/models`).
Raw captures are in `/tmp/waycar-harness-captures/muse/` on the Mac: `help*.txt`, `hooks/*.json`, `screen-*.txt|ans`, `raw-session1.bin`, `transcript/<id>/`, `herdr/run1|run2/`.

Method key: **live** = the lab; **docs** = the cited URL; **help** = `muse --help` on 1.4.6; **binary** = strings embedded in the binary.

## Lab notes
- Muse sends its tools as one Responses `{type:"namespace", name:"muse", tools:[…]}` item. Before the mock flattened namespace items, it saw one tool named `muse` (`scripts/harness-lab/mock/server.js`).
- Background "observer" agents send 3–10 extra requests per turn. They also carry tools, so a `WAYCAR_TOOL` prompt could make an observer call the shell tool. The lab sets `run.reminder_roster: {}` to turn them off. Muse rewrites `[]` to `{}`, and it also rewrites `settings.json` itself (it added `tui.foreign_context_notice_shown`).
- In herdr panes, the herdr server's environment, not the env file, decides which variables a pane gets. `META_API_KEY` was missing there, and Muse started a browser device login. Use `auth.json` instead (config/muse).

## 1. Hooks
- Config (docs https://dev.meta.ai/docs/muse-code/extending.md; live): Claude format under `hooks` in `~/.config/muse/settings.json` (`$XDG_CONFIG_HOME`). The file must set `"schema_version": 1`. Project hooks live in `.muse/hooks.json` (trusted workspaces only), and `managed_hooks_path` points to managed hooks. Handler fields: `type`, `command`, `timeout`, `async`. An unknown field such as `env` skips the handler with a startup warning.
- Events (docs + live): `SessionStart` (fires **lazily at the first prompt** and **never on resume**), `UserPromptSubmit`, `PreToolUse`, `PermissionRequest` (as the approval dialog opens), `PostToolUse`, `PostToolUseFailure`, `PostToolBatch`, `PreLLMCall`, `PostLLMCall`, `Notification` (`permission_prompt`, about 6 s after the dialog opens), `Stop`, `StopFailure`, `SessionEnd` (`reason:"other"` on `/exit`), `PreCompact`, `PostCompact`, `SubagentStart`, `SubagentStop`. Two more events are undocumented: `Interrupt` (Esc; **Stop does not fire**) and `ToolUseStart`. Both need `"async": true`, or Muse skips them with a warning (live).
- Payload (live): `session_id`, `cwd`, `hook_event_name`, `model`, `model_provider`, `permission_mode`, `turn_id`. `transcript_path` is always `null`. Event extras: `prompt`; `tool_name`/`tool_input`/`tool_use_id`/`tool_response`; `last_assistant_message`; `notification_type`/`title`/`message`.
- **Cleared environment (live):** hooks get only HOME, PATH, LANG, LC_ALL, LOGNAME, SHELL, USER, PWD, MUSE_SESSION_ID and MUSE_THREAD_ID. There is **no TMUX, TMUX_PANE or HERDR_\***, and `managed_hooks_env_vars` did not pass them to user hooks.
- Claude compat: Muse does not run `~/.claude/settings.json` hooks; only Muse's own sources fired (binary: Claude settings are read for `autoMemoryDirectory` and skills only). So the claude Status Hook does not bleed into Muse.
- Built-in herdr plugin (binary + live): when `HERDR_ENV=1`, Muse loads a bundled `herdr` plugin. Its hooks send `pane.report_agent` (working/blocked/idle/unknown, source `muse:herdr`) with `resume_argv ["muse","resume",<id>]`, and **never send `agent_session_id`**.

## 2. tmux pane identity
Live: the hook's PPID is `muse-bin-1.4.6-R6000.1`, on the pane's own tty (`pts/0`). Each pane runs its own Muse process, about 230 MB RSS. The session log also records `tmux_pane` and `tmux_socket_path` (`runtime.session.route_facts`). Waycar recovers TMUX, TMUX_PANE, HERDR_* and WAYCAR_SUMMARY from `/proc/$PPID/environ`. Where there is no /proc, it finds the pane on the default tmux server whose tty is the agent's.

## 3. Executable
`muse` is a bash launcher that `exec`s `~/.local/bin/muse-bin-<version>`. tmux shows `pane_current_command` = `muse-bin-1.4.6-R6000.1`, which `TmuxAgentDetection` already handles.

## 4. Transcript
Live: `$XDG_DATA_HOME/muse` (default `~/.local/share/muse`) `/sessions/<YYYY>/<MM>/<DD>/<session uuidv7>/session.jsonl`. It is an append-only event log. Resume appends to the same file.
- Record shape: `{schema_version, id, stream, sequence, recorded_at (µs), payload_type, payload}`. A `retained_frame` line wraps child records as `record_json` strings.
- Prompt: `runtime.user_intent.accepted` with `surface:"main"`. Its `model_messages[].content` holds `text` blocks and `asset` blocks (`{sha256 digest, media_type, source_path}`), and its `intent_id` is the run id.
- Run events: `runtime.session` records with `kind:"run"`: `started`, `assistant_message_committed{text}`, `assistant_tool_calls_committed{tool_calls[{name,args}]}`, `tool_result_batch_committed`, `terminal{terminal:"completed"|…, reason}`.
- Images: a pasted path becomes `[Image #1]`, and Muse stores a copy at `<session>/input-assets/v1/sha256/<2>/<digest>`.
- `runtime.session.metadata.workspace_root` is the cwd. A subagent's session has a different `root_session_id`.
- `muse export --session <id>` writes a versioned JSON export (help). It is not used.

## 5. Chat Prompt route
Live: `-c 'run.developer_prompt="<JSON string>"'` appends a developer prompt; the marker was in the mock's system text, and the full base instructions were kept. `run.system_prompt` replaces the base instructions instead. The route is inline only: `-c` accepts no `${VAR}` except for secret settings. The setting is **not persisted**, so resume must pass it again. Root options work on either side of `resume` (live).

## 6. First message
Live: a bare positional (`muse "<text>"`) submits the text and stays interactive. `muse exec` is the headless form.

## 7. Resume
Live: `muse resume <uuid|Session Name>`, `muse resume --last` (the most recent session in this workspace), and bare `muse resume` (picker). On exit Muse prints `To continue this session, run muse resume <id>`. The TUI has no session pin; only `muse exec` has `--session-id`.

## 8. Model / effort
Help + live: `--model <id>` and `--reasoning-effort none|minimal|low|medium|high|xhigh|max|ultra` (alias `--effort`). On the wire this is `reasoning.effort` (live: `low`). The footer shows `model · effort · cwd · profile`.

## 9. Skills
Live (`muse skills list --json`, `/proj-agents` loaded the body): project `.agents/skills`, `.claude/skills` and `.codex/skills` (docs); user `$XDG_CONFIG_HOME/muse/skills`, `~/.agents/skills`, `~/.claude/skills` and `$CODEX_HOME/skills`. `.muse/skills` is **not** read. Layout is `<name>/SKILL.md`, invoked as `/name`.

## 10. Alt screen / mouse / input readiness
- Live raw bytes: **no alternate screen, no mouse** (`#{alternate_on}=0`, `#{mouse_any_flag}=0`); `?2004h` and `?1004h` are on. The TUI is inline, so message jump uses the copy-mode path, as for omp.
- Readiness (live): with the workspace trusted, the footer drew 0.4–1.0 s after launch. Pastes at 0.3, 0.8, 1.5 and 3 s all landed. The first-ever launch took 39 s to reach input-ready (13.7 s runtime init).
- Idle: a `❯` row between `────` rules, with footer `mock-model · high · ~/work/demo · Auto-review`. Working: `◇ Thinking (1s · esc to interrupt)` or `◈ Calling tools (8s · esc to interrupt)`, and the empty `❯` row stays visible. Blocked: `Would you like to run the following command?` / `› 1. Yes, proceed (y)` / `2. No, and tell Muse Code what to do differently (esc)` / `Change approval defaults in /permissions`, with `esc to interrupt` still showing above. Trust dialog: `Do you trust this workspace?` / `> 1  Trust and continue` / `2  Quit` / `Use Up/Down or 1/2, then Enter. Esc quits.`
- herdr's `muse.toml` (2026.08.26.1, written for 0.2.1) is stale for 1.4.6. Its `idle_prompt` expects `⟩` (1.4.6 draws `❯`), and its `blocked_approval` pairs miss 1.4.6's dialog (live `agent.explain`: `idle_status_fallback` matched during the approval).
- Trust dialog on herdr 0.9.3 (live, 2026-10-12, untrusted git dir with `AGENTS.md`): the same `muse.toml` reads it **blocked** (`agent.explain`: rule `workspace_trust_blocked`), `agent.start` answers `agent_not_ready` ("blocked during startup"), and `agent.prompt` is refused with `agent_blocked`; `~/.config/muse/trust.json` stayed unchanged. Waycar still reads the screen on both backends (`AgentScreen.trustDialogShown`, matched on the live `pane.read` and `capture-pane` text) and refuses with `AgentFolderTrustRequiredError`, since the manifest is remote and stale elsewhere.

## 11. herdr tier
herdr 0.9.3 (live, `herdr/run2`): `agent.start kind muse` launches `muse`, and the prompt was delivered. Statuses went idle → working → done → working → **blocked** → working → done. The blocked status came from Muse's built-in herdr plugin, not herdr's manifest. That gives Muse **full lifecycle hook authority without a session**: no `agent_session`, and herdr has no `muse` integration.

## 12. Login / first run
Live: with no credentials, Muse first shows the trust dialog, then `Log in with browser · Enter to choose` / `Set an API key` / `↓↑ to select · Esc to quit`. Choosing the browser shows `Sign in at this page:` with an `auth.meta.com/oauth/device` URL and `Waiting for approval…`. Esc prints `Not logged in. Run muse again to log in.` and exits.

## 13. Isolation flag
None needed: one process per pane on the pane's tty. Each session has an in-process session-messaging socket under `~/.local/share/muse/runtime/muse/`.

## Agent Summary
Live: `muse exec --no-session-log -c run.toolset=[] …` sent a request with `tools: []` and only one model call, and recorded nothing.
