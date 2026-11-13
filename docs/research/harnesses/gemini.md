# Gemini CLI (`gemini`)

Version tested: **Gemini CLI 0.63.0** (npm `@google/gemini-cli`), harness lab (Ubuntu 24.04, tmux 3.4, herdr 0.9.3), **2026-10-12**.
Auth: `GEMINI_API_KEY` dummy + `GOOGLE_GEMINI_BASE_URL=http://mock:8080`; no Google account.
Raw captures: `/tmp/waycar-harness-captures/gemini/` on the Mac (hook stdin/env, `screen-*.ans`, `raw-*.bin`, `transcript/session-…-01ccc475.jsonl`, `mock-log.jsonl`).

Method key: **live** = lab; **docs** = cited URL; **help** = `gemini --help` 0.63.0.

Qwen Code shares: the `-i/--prompt-interactive` flag, `-m`, `--approval-mode`, the `@path` attachment mechanism (`--- Content from referenced files ---` + `inlineData` parts), the Gemini `parts` message shape inside transcripts, the inline input box (`> Type your message or @path/to/file`). It does **not** share Gemini's hook event names, transcript container, resume flag, alt-screen behaviour or system-prompt route — see qwen.md.

## 1. Hooks
- Config (docs, https://raw.githubusercontent.com/google-gemini/gemini-cli/main/docs/hooks/reference.md): `settings.json` `hooks: {<Event>: [{matcher, sequential?, hooks:[{type:"command", command, name?, timeout(ms)}]}]}`; user `~/.gemini/settings.json`, project `.gemini/settings.json` (**live**: project file loaded; Gemini prints a "project-level hooks have been detected … These hooks will be executed" warning listing hook `name`s on every launch).
- Events (bundle enum, live): `SessionStart`, `SessionEnd`, `BeforeAgent`, `AfterAgent`, `BeforeTool`, `AfterTool`, `BeforeModel`, `AfterModel`, `BeforeToolSelection`, `Notification`, `PreCompress`. No prompt-submit/permission-request/stop names; no Claude names.
- Base payload (live, every event): `{session_id, transcript_path, cwd, hook_event_name, timestamp}` + event fields: `SessionStart.source` (`startup`|`resume`), `BeforeAgent.prompt`, `AfterAgent.{prompt, prompt_response, stop_hook_active}`, `BeforeTool/AfterTool.{tool_name:"run_shell_command", tool_input, tool_response}`, `Notification.{notification_type:"ToolPermission", message, details{type:"exec", command, rootCommand}}`, `SessionEnd.reason:"exit"`, `PreCompress.trigger:"auto"`.
- Order per prompt (live): `BeforeAgent` → `PreCompress{trigger:auto}` (**fires every turn**, not only on compaction) → `BeforeTool` → `Notification{ToolPermission}` (only when the dialog shows) → `AfterTool` → `PreCompress` → `AfterAgent`. `SessionStart` fires at launch (before any prompt). Exit fired `SessionEnd` **three times** (live, after a resumed session; identical payloads).
- `echo waycar-tool-ok` ran without a dialog (read-only auto-allow, live); a real dialog was produced by rewriting the command via `hookSpecificOutput.tool_input` to `rm -f … && echo …`, and only then did `Notification{ToolPermission}` fire.
- **Resume quirk (live):** `SessionStart{source:"resume"}` carried a *new* `transcript_path` (`session-2026-10-12T16-37-01ccc475.jsonl`) that was never created; all later events and the actual writes used the original file (`…T16-35-01ccc475.jsonl`). Prefer the `transcript_path` from `BeforeAgent`/`AfterAgent`, or glob `chats/session-*-<first 8 of id>.jsonl`.
- Env in hooks (live): `GEMINI_SESSION_ID`, `GEMINI_PROJECT_DIR`, `GEMINI_CWD`, `GEMINI_PLANS_DIR`, `GEMINI_CLI_NO_RELAUNCH=true`, and **`CLAUDE_PROJECT_DIR`** (Gemini exports it for Claude-style hook scripts).
- Hook stdout must be JSON-or-nothing (docs).

### Claude-compat
- live: a project `.claude/settings.json` with capture hooks did **not** fire; Waycar's `~/.claude/settings.json` claude Status Hook did not fire in `~/work/probe-gemini` or with cwd `$HOME` (`@waycar_agent` unset). The bundle has no `.claude` references (source grep). Gemini does not execute Claude hooks.

## 2. tmux pane identity
live: `TMUX_PANE` preserved; hook PPID = the relaunched child `node --max-old-space-size=… …/bin/gemini`, tty `pts/13` = `#{pane_tty}`. Process tree: `bash` → `node …/bin/gemini` → `node --max-old-space-size=5967 …/bin/gemini` (self-relaunch). `#{pane_current_command}` = `node`.

## 3. Executable
`gemini` (= kind id), Node script.

## 4. Transcript
- live: `~/.gemini/tmp/<project-slug>/chats/session-<YYYY-MM-DDTHH-MM>-<first 8 hex of sessionId>.jsonl`. The slug is the **cwd basename** (`probe-gemini`), mapped in `~/.gemini/projects.json` (`{"projects":{"/home/waycar/work/probe-gemini":"probe-gemini"}}`), dir also holds `.project_root`. (Docs and older versions describe a hash dir; 0.63.0 uses the slug.)
- Format (live): JSONL. Line 1 header `{sessionId, projectHash, startTime, lastUpdated, kind:"main"}`; then records `{id, timestamp, type:"user"|"gemini", content, …}` interleaved with patch lines `{"$set":{…}}` (`lastUpdated`, full `messages` replays after resume, `sessionId`).
  - `user.content` = array of parts (`{text}`, `{functionResponse}`, `{inlineData:{data,mimeType}}`); `displayContent` holds what the user typed when `@` expansion added parts.
  - `gemini` records: `content` (string), `thoughts[]`, `tokens`, `model`, optional `toolCalls[]` `{id, name, args, result[]…}`. **The same `id` appears twice** (first without `toolCalls`, then with) — upsert by `id`, last wins.
  - Tool results also appear as a `user` record whose content is a `functionResponse`.
- Images (live): `describe @probe.png` → user record content `[{text}, {text:"\n--- Content from referenced files ---"}, {inlineData:{data:<base64>, mimeType:"image/png"}}, {text:"\n--- End of content ---"}]`, `displayContent:[{text:"describe @probe.png IMAGETURN"}]`.
- Resume appends to the original file (live).

## 5. Chat Prompt injection route
- No append flag (help). Two live routes:
  - `GEMINI_SYSTEM_MD=<file>` env: **replaces** the whole system prompt (mock `system` = file content exactly: `You are a probe. WAYCARMARK-GEMINI-SYSMD`). `GEMINI_WRITE_SYSTEM_MD=<file>` dumps the built-in prompt (live; 32 KB), but the dump from `-p` says "autonomous CLI agent" while the interactive prompt says "interactive CLI agent", so a dump+append file would not reproduce the interactive default exactly.
  - `--include-directories <dir>` with `<dir>/GEMINI.md`: marker delivered inside the **first user message**'s `<loaded_context><project_context>--- Context from: <dir>/GEMINI.md ---` block (live; footer "1 GEMINI.md file"). Side effect: `<dir>` joins the workspace (tools may read/write it).
- Recommended: `--include-directories <stage>` with `GEMINI.md` (keeps the default system prompt). Path-only on the command line.

## 6. First message
`-i "<prompt>"` (live: `GEMINI_SYSTEM_MD=… gemini -i "first FIRSTMSG-GEM"` submitted and stayed interactive) **or** bare positional (live: `gemini "positional POSGEM"` submitted and stayed interactive; help: "Runs in interactive mode by default"). Use `-i` (same as qwen, where positional is one-shot).

## 7. Resume
`-r/--resume latest|<index>|<uuid>` (help). **live**: `gemini -r latest` resumed (SessionStart `source:"resume"`, same session id); `gemini --resume 01ccc475-d9df-4b1a-8b1e-ebddc21cd237 -p …` resumed by full UUID (appended to the original file). Exit banner prints `To resume this session: gemini --resume <uuid>`. `--session-id <uuid>` starts a new session with that id (help; UNVERIFIED live). `--list-sessions` lists per project (live).
→ `ClosedSession.resumeArguments(.gemini)` currently returns `[]` ("gemini never reports a session"); with Waycar's own hooks the id **is** available on tmux, so `["--resume", id]` works. herdr still reports null.

## 8. Model / effort
- `-m <model>` (live: mock path `/v1beta/models/mock-gem-model:streamGenerateContent`; footer shows the model). Without `-m` the default is Auto routing: a `gemini-3.5-flash-lite` router call then `gemini-3.8-flash` (live mock log).
- **No effort flag** (help). Auto routing sent `thinkingLevel: HIGH`; with `-m mock-gem-model` only `includeThoughts:true` was sent (live). Effort is settings-only (`modelConfigs`/thinking config) [docs-level, UNVERIFIED].

## 9. Skills
- live `gemini skills list`: `.gemini/skills/<name>/SKILL.md` and `.agents/skills/<name>/SKILL.md` (project) discovered; `.claude/skills` **not**. Home equivalents `~/.gemini/skills`, `~/.agents/skills` [docs, not exercised].
- live: `gemini -p "/gmskill"` was sent literally (skills are model-invoked, no slash command) — matches `AgentSkill.swift`'s deliberate omission.
- Custom commands: `.gemini/commands/<name>.toml` (`prompt = "…"`) → `/gmcmd` expanded (live). TOML, so not a markdown-files source.

## 10. Alt screen / mouse / input readiness
- live raw bytes: **no** `?1049h`, **no** mouse modes; `?2004h` (bracketed paste) and `?1004h` only. Inline renderer (`#{alternate_on}=0`, `#{mouse_any_flag}=0`); scrollback is real tmux history.
- Input readiness (live): paste 0.8 s after launch was **lost**; 2 s and 3.5 s accepted.
- **Enter swallowed right after input (live):** `paste-buffer -p` followed immediately by `send-keys Enter` left the text in the box unsubmitted; the same happened with `send-keys -l text` + immediate Enter. A second Enter (or ~0.3 s gap before Enter) submits. Waycar must delay the submit key after paste for gemini.
- **Verified delivery (AppScreenInput, live, 2026-10-12, gemini 0.63.0, tmux 3.4):** Waycar's control-mode sequence (`set-buffer ; paste-buffer -p -d`, then a raw CR `send-keys -H 0d` on its own line 0.5 s later) submitted 3/3; the same text with `send-keys Enter` on the paste's own line stayed in the box (1/1).
- Ready marker: box row `>   Type your message or @path/to/file` between `▄▄▄` / `▀▀▀` rules, footer `workspace (/directory) … /model`. Working: `⠏ … (esc to cancel, Ns)` spinner line. Blocked: bordered `? Shell <cmd>` box with `Allow execution of [Shell]?` and `1. Allow once / 2. Allow for this session / 3. No, suggest changes (esc)`.
- Screens: `screen-firstrun.ans`, `-working`, `-done`, `-blocked`, `-done-after-approve`, `-image-done`, `-first-msg`, `-positional`, `-nodelay*`, `-typed`.

## 11. herdr tier
herdr 0.9.3 has no gemini integration (`herdr integration status`, live: only `antigravity-cli` under `~/.gemini/config/hooks`). `agent_session` null (AGENTS.md, 0.9.1). Screen-manifest only.

## 12. Login / first run
API key + base URL works with no account (live). The lab pre-sets `security.auth.selectedType` and disables folder trust. The auth dialog of a fresh home is [UNVERIFIED here]. Consumer Google login ended 2026-06-18 (research report).

**Folder trust (live, 2026-10-12).** In 0.63.0, `security.folderTrust.enabled` defaults to **true** (bundled settings schema).
- **The dialog.** With trust on, an untrusted checkout opens on a box: `Do you trust the files in this folder?`, then `● 1. Trust folder (<name>)` / `2. Trust parent folder (<parent>)` / `3. Don't trust`. Enter picks the marked option, which trusts the folder [INFERENCE: not pressed].
- **Before the answer.** No hook fires (`@waycar_*` unset at +8 s and +20 s). herdr 0.9.3 reads the box as `idle` with `interactive_ready: true` (`default_known_agent_idle_fallback`), so a typed prompt's Enter would trust the folder.
- **Waycar.** Every prompt to a gemini Agent reads the screen first on both backends and fails `AgentFolderTrustRequiredError`, with nothing typed, while the box shows (`AgentScreen.trustDialogShown`). tmux also shows the box as Blocked.
- **Method.** Captured with a scratch `HOME` whose settings turned trust on.

## 13. Isolation flag
None: per-pane process (self-relaunching child) on the pane tty (live).

## Recommended implementation per layer
- **tmux Status Hooks**: JSON-hooks entry in `~/.gemini/settings.json` (`hooks` key; merge, don't clobber — the file is shared with other config): `BeforeAgent`→working, `BeforeTool`→working-if-active, `Notification` (`ToolPermission`)→blocked, `AfterAgent`→done, `SessionStart`→hook-session (store `session_id`; fix up `transcript_path` on later events), `SessionEnd`→idle (dedupe; fires up to 3×). Ignore `PreCompress`. Hooks need `name` fields (shown in Gemini's warning). Add `gemini` to waycar-hook's case.
- **Chat transcripts**: new parser for the `$set`/upsert JSONL (user `displayContent` ?? text parts, `gemini.content`, `toolCalls` activity, `inlineData` images).
- **Chat Prompt**: `--include-directories <stage>` + `<stage>/GEMINI.md` (new route); `GEMINI_SYSTEM_MD` only if full replacement is acceptable.
- **First message**: `-i <text>`.
- **Resume**: `["--resume", id]` when the tmux hook stored an id; `["--resume", "latest"]`/picker otherwise; herdr stays `[]`.
- **Model/effort**: `-m <model>`; effort: cannot support via CLI (settings-only).
- **Skills**: keep omitted (model-invoked); `.gemini/commands/*.toml` are slash commands but TOML.
- **Prompt delivery**: needs a gemini-specific gate: wait ≥2 s / the `Type your message` box, and insert ≥0.3 s between paste and Enter.
- **Message jump**: inline (no alt screen) → standard tmux scrollback.
- **Agent Summaries**: `gemini -p … -m …` one-shot is available (live).
