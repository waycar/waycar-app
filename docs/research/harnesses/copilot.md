# GitHub Copilot CLI (`copilot`)

Version tested: **GitHub Copilot CLI 1.0.95** (npm `@github/copilot`, linux-arm64 native binary), harness lab (Ubuntu 24.04, tmux 3.4, herdr 0.9.3), **2026-10-12**.
Auth: BYOK only (`COPILOT_PROVIDER_TYPE=openai`, `COPILOT_PROVIDER_BASE_URL=http://mock:8080/v1`, `COPILOT_PROVIDER_API_KEY`, `COPILOT_MODEL=mock-model`); no GitHub account.
Raw captures: `/tmp/waycar-harness-captures/copilot/` on the Mac (hook stdin + env per event, `screen-*.ans`, `raw-*.bin` pipe-pane bytes, `transcript/events.jsonl`, `mock-log.jsonl`; the mock log also contains other agents' `herdr-copilot` turns, which share the `OpenAI/JS` user agent).

Method key: **live** = observed in the lab; **docs** = cited URL; **help** = `copilot --help` / `copilot help <topic>` output of 1.0.95.

## 1. Hooks: config path, events, payload fields

- Config (docs, https://docs.github.com/en/copilot/reference/hooks-reference): `{"version":1,"hooks":{<event>:[{type:"command", bash|command|exec+args, cwd?, env?, timeoutSec?(default 30), matcher?}]}}`. Sources merged in order: policy `/etc/github-copilot/policy.d/*.json`, repo `.github/hooks/*.json`, user `~/.copilot/hooks/*.json` (`$COPILOT_HOME/hooks`), inline `hooks` in `.github/copilot/settings{,.local}.json` **and the repo's `.claude/settings{,.local}.json`**, inline `hooks` in `~/.copilot/settings.json`, plugins. **live**: `.github/hooks/*.json` in a trusted repo loaded; every file's entries run (two files for the same event both fired).
- Two payload dialects, chosen by the event-name spelling in config (docs; **live** confirmed):
  - camelCase events (`sessionStart`, `userPromptSubmitted`, `preToolUse`, `postToolUse`, `permissionRequest`, `notification`, `agentStop`, `sessionEnd`, `errorOccurred`, …) → camelCase fields: `sessionId`, `timestamp` (epoch ms), `cwd`, `transcriptPath` (agentStop only).
  - PascalCase (VS Code / Claude-compatible) events (`SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Notification`, `Stop`, `SessionEnd`) → snake_case Claude-shaped fields: `hook_event_name`, `session_id`, `timestamp` (ISO), `cwd`, `transcript_path` (on `Stop` only), `prompt`, `tool_name` (`Bash`), `tool_input`, `source`, `reason`, `notification_type`, `stop_reason`.
  - **Quirk (live):** a PascalCase `PermissionRequest` entry still receives the camelCase body `{"hookName":"permissionRequest","sessionId",…,"toolName":"bash","toolInput"}`. Parse both spellings.
- Lifecycle order observed (live), per prompt: `UserPromptSubmit` → (`SessionStart` **lazily, on the first prompt of a launch**, `source: "new"|"resume"`, with `initial_prompt`) → `PreToolUse` → `PermissionRequest` → (`Notification{notification_type:"permission_prompt"}` only if a dialog actually shows) → `PostToolUse` → `Stop{stop_reason:"end_turn", transcript_path}`. Exit: `SessionEnd{reason:"user_exit"}`.
- **`PermissionRequest` is NOT a blocked signal (live):** it fired for `echo waycar-tool-ok`, which Copilot auto-allows as read-only with no dialog. Only `Notification` with `notification_type == "permission_prompt"` (`title:"Permission needed"`, `message:"Run command: …"`) coincided with the on-screen approval dialog.
- **No `SessionStart` until the first prompt (live):** an idle freshly-launched Copilot fires no hook at all; the session id is unknown to hooks until the first submit.
- **Phantom `SessionEnd` on resume (live):** `copilot --continue`/`--resume=<id>` fired `SessionEnd{reason:"user_exit"}` for a *different*, never-used session id ~2 s after launch, before the resumed `SessionStart{source:"resume"}`. Only clear pane session state when the `SessionEnd` id matches the stored id.
- Session id field: `session_id` (Pascal) / `sessionId` (camel), present on every event. Transcript path: `transcript_path`/`transcriptPath` on `Stop`/`agentStop` (and `preCompact`, `subagentStop`) only — `~/.copilot/session-state/<sessionId>/events.jsonl`.
- Env in hooks (live): `COPILOT_CLI=1`, `COPILOT_CLI_BINARY_VERSION=1.0.95`, `COPILOT_PROJECT_DIR`, **`CLAUDE_PROJECT_DIR`** (Copilot sets it for Claude-compat hooks), `COPILOT_LOADER_PID`.

### Claude-compat (`~/.claude/settings.json`)
- **live**: a repo-level `<repo>/.claude/settings.json` with `UserPromptSubmit`/`Stop` command hooks **was executed** by Copilot (capture files `*-claudecompat-*`).
- **live**: Waycar's installed claude Status Hook in `~/.claude/settings.json` did **not** fire under Copilot in `~/work/probe-copilot`, `~/work/demo`, or with cwd `$HOME` (not a git repo; after accepting the folder-trust dialog): `@waycar_agent`/`@waycar_status` stayed unset throughout.
- Risk: a repo whose committed `.claude/settings.json` carries Claude hooks, or a `$HOME` that is itself a git root, would run them under Copilot [INFERENCE from the docs' "repository" wording; not reproduced]. The hook's PPID is Copilot's native binary on the pane tty, so waycar-hook's tty-match guard would **not** reject it — only the `CLAUDE_PROJECT_DIR`+`COPILOT_CLI=1` env could.

## 2. tmux pane identity
- live: `TMUX_PANE` preserved (`%2`); hook PPID = native `copilot` binary (`comm` `MainThread`), `ps -o tty= -p $PPID` = `pts/2` = `#{pane_tty}`. No shared daemon.
- Process tree (live): `bash` → `node ~/.npm-global/bin/copilot …` (npm-loader.js) → `…/copilot-linux-arm64/copilot …` (comm `MainThread`). `#{pane_current_command}` = `node`.

## 3. Executable
`copilot` (= kind id). npm install is a Node loader spawning a native binary; interpreter-unwrapping of `node <path>/bin/copilot` yields `copilot` (live process args above).

## 4. Transcript
- live: `~/.copilot/session-state/<sessionId>/events.jsonl` (`$COPILOT_HOME` overrides `~/.copilot`, help). Sibling `workspace.yaml` (`id`, `cwd`, `git_root`, `branch`, `name` = first prompt, `created_at`). Resume appends to the same file (same id).
- Format: JSONL, one event per line: `{type, data, id, timestamp, parentId}` — a linear `parentId` chain. Types seen: `session.start` (data.sessionId, copilotVersion, selectedModel, reasoningEffort, context.cwd), `session.model_change`, `session.resume`, `session.shutdown`, `system.message`, `user.message` (data.content = raw prompt, data.transformedContent = prompt wrapped with `<current_datetime>`, data.attachments[]), `assistant.turn_start`/`assistant.turn_end` (data.turnId), `assistant.message` (data.content text, data.toolRequests[] {toolCallId,name,arguments}), `tool.execution_start`/`tool.execution_complete` (data.success, data.result.content), `permission.requested`/`permission.completed` (data.result.kind `approved`, `decisionSource:"human_response"`), `hook.start`/`hook.end`, `session.usage_record`, `session.binary_asset`.
- Images (live): `@probe.png` in the prompt → a `session.binary_asset` line `{assetId:"sha256:…", type:"image", mimeType:"image/png", byteLength, data:<base64>}` immediately before the `user.message`, whose `attachments[]` references it by `assetId` + `path`.
- One user turn yields several `assistant.message`/`turn_end` pairs (tool round-trips; turnId restarts at "0" each user message). Reply text = `assistant.message.data.content` where non-empty.

## 5. Chat Prompt injection route
- No system-prompt flag (help). **live route:** env `COPILOT_CUSTOM_INSTRUCTIONS_DIRS=<dir>` with `<dir>/.github/instructions/<name>.instructions.md` (front matter `applyTo: "**"`). Mock log: marker `WAYCARMARK-COPILOT-CI4` present in the request's **system** prompt on every turn (incl. after resume when the env is set again). `copilot instruction list` shows it as `[external]`.
- live negatives: `<dir>/AGENTS.md`, `<dir>/copilot-instructions.md`, `<dir>/.github/copilot-instructions.md` were **not** picked up from that env dir (`copilot instruction list`).
- The env var applies per launch (`VAR=… copilot` prefix on the typed command line); no CLI length concern since the content lives in a file.

## 6. First message
`-i "<prompt>"` / `--interactive=<prompt>` (help; **live**: `copilot -i "first message FIRSTMSG-COPILOT"` submitted it and stayed interactive). `-p` is non-interactive (exits).
- A first-message pointer outside the workspace (`-i "Read and follow <stage>/first-message.md"`) stops on an "Allow path access" dialog before `view` reads it; `COPILOT_CUSTOM_INSTRUCTIONS_DIRS=<stage>` does not grant access. `--add-dir <stage>` reads it at once and does not load the instructions file a second time (live, copilot 1.0.95, 2026-10-12).
- Waycar does not use `-i` (2026-10-12): on copilot 1.0.96 (self-updated in the lab) a first message given as `-i` made every later hook end in `HookTimeoutError` (10 s each), and the `-i` process outlived `kill-pane`, so `--resume=<id>` stopped on a "session already in use" dialog and the resumed prompt was lost; without `-i` neither happened. On the pinned 1.0.95 the same probe was clean either way (hooks succeed, no process left after `kill-pane`), and a first message typed into the pane after launch reached the mock with all hooks succeeding. So copilot takes no first-message flag: a preset's first message (Ask an Agent) becomes a Queued Message its Composer sends once input is ready (`AgentComposerStore.queueLaunchMessage`, behind the `AgentScreen` minimum delay), not a Launch Prompt File.

## 7. Resume
- `--resume=<id>` (also ID prefix ≥7 hex or exact name), bare `--resume` = picker, `--continue` = most recent, `--session-id <uuid>` = resume or **pin a new session id** (help). **live**: `--resume=f18f4b89-…` and `--continue` resumed (same id/transcript, `SessionStart.source:"resume"`); `--session-id=11111111-2222-4333-8444-555555555555` created that id (Stop `session_id` and `session-state/1111…` dir). Exit banner prints `Resume copilot --resume=<id>`.
- Existing `ClosedSession.resumeArguments` (`--resume=<id>`) matches.

## 8. Model / effort
- `--model <m>`, `--reasoning-effort <none|minimal|low|medium|high|xhigh|max>` (help). **live**: mock logged `model:"mock-model"`, `effort:"high"` then `"low"`; footer shows `mock-model · High`. Env `COPILOT_MODEL` also sets the model. BYOK warns `Model "mock-model" is not in the built-in catalog`.

## 9. Skills
- `copilot skill --help` (help) + **live** `copilot skill list`: project `.github/skills/`, `.agents/skills/`, **`.claude/skills/`**; personal `~/.copilot/skills/`, `~/.agents/skills/`; `<name>/SKILL.md` layout. All three project dirs were listed live.
- Invocation: `/name` per docs/catalog; in `-p` mode `/ghskill` was sent to the model literally (mock echoed `/ghskill`) — interactive `/`-menu behaviour UNVERIFIED (not exercised).
- Existing `AgentSkill.swift` entry lacks `.claude/skills` (project).

## 10. Alt screen / mouse / input readiness
- live raw bytes: `?1049h` (alt screen), `?1003h` + `?1006h` (any-motion mouse, SGR), `?2004h`, `?1004h`. `#{alternate_on}=1`, `#{mouse_any_flag}=1`. `--no-mouse` / `--mouse off` disables mouse (help).
- Input readiness (live, cold-ish start): paste typed 0.3 s after Enter on the launch line was **lost**; 0.8 s and 1.5 s were accepted and submitted. Paste+Enter with no gap submits fine. Ready screen: `❯` input row between two `─` rules and footer `Interactive · Manual Approval · / commands`.
- Screens: `screen-firstrun.ans`, `screen-idle-after-first.ans`, `screen-working.ans` (`◉ Working esc …` footer), `screen-blocked.ans` (bordered `Do you want to run this command?` with `1. Yes / 2. Yes, and don't ask again… / 3. No`), `screen-done*.ans`, `screen-exited.ans`, `screen-home-cwd.ans` (folder-trust dialog `Do you trust the files in this folder?`).

## 11. herdr tier
- Integration: herdr 0.9.3 `herdr integration status` (live): `copilot: … ~/.copilot/hooks/herdr-agent-state.sh`; the script reports `pane.report_agent_session` with `session_id`/`sessionId` on SessionStart (live file read) → **session-identity (id form)** once installed. It reports no state: herdr dropped copilot's lifecycle hooks on purpose (source review: v0.9.3 `COPILOT_HOOK_EVENTS = ["SessionStart"]`; herdr `df7880c5` changelog "Copilot state still comes from Herdr's PTY/screen detection because Copilot hooks do not provide complete lifecycle coverage"), and `full_lifecycle_hook_authority` lists no copilot source. So the status is herdr's screen detection, with or without the integration.
- Screen rules (source review): herdr's copilot manifest `2026.08.29.1` is the v0.9.3 built-in, the lab's remote cache and herdr.dev's catalog copy (fetched 2026-10-12). Working = `esc to cancel` / `esc cancel` / `esc again to cancel` / `esc interrupt` anywhere recent; blocked = one of the first two plus `enter to select|confirm|submit|accept`.
- copilot 1.0.95 and 1.0.96 footer while a turn runs (live, plus source review of 1.0.95's `cli-main.js`): `◉ Working esc edit prompt` from submit until the model's first output (the hint reads `edit prompt` while `pendingPrompts.recallsTurn()`, i.e. the prompt can still be withdrawn), then `◉ Working esc interrupt` (`· N B` while it streams). The manifest has no rule for the first: `herdr agent explain` on that screen gives `matched_rule: null`, `fallback_reason: default_known_agent_idle_fallback`, `state: idle`.
- **herdr misses copilot's text-only turns** (live, lab, herdr 0.9.3, `agent.get` + `pane.read` sampled every 100 ms, 2026-10-12): every text turn read `idle` for its whole `esc edit prompt` phase, a 15 s `WAYCAR_SLOW` turn and a Chat Mode first turn (`COPILOT_CUSTOM_INSTRUCTIONS_DIRS`, `--session-id`) included. `esc interrupt` lasted ≤ 200 ms at the end, when the mock's reply arrived in one burst. herdr caught that frame (working → done) on 2 of 12 text turns and read idle → idle on the other 10, with no done either; 1.0.95 and 1.0.96 behaved the same. A tool turn reads working → done: once the tool call arrives, the footer stays `esc interrupt` through the tool and the follow-up request. Earlier suite runs were flaky the same way: the plain turn failed in 2 of 5 runs and the resumed turn in 3 of 4. The launch turn read working in all 7 runs, the last one only after its reply was on screen. Three sent the first message with `-i`, whose turn shows `esc interrupt` from the start (`raw-probe-copilot-b.bin`), and four queued it. The probes caught none of 4 first turns, so the suite does not rely on it [cause for the queued launches not established].
- The fix is one rule. The same screen, with `{ contains = ["esc edit prompt"] }` added to `working_cancel_hint` as a local override (`herdr agent explain --file <screen> --agent copilot` with `XDG_CONFIG_HOME` on a throwaway `herdr/agent-detection/copilot.toml`), matches `working_cancel_hint`: `state: working` (live).
- On herdr, a copilot turn shows idle until the model's first output. A turn whose reply arrives in one piece may show no working and no done, and so gets no done push, since the plugin pushes on herdr's status. Real models stream, so working shows from the first token.
- **What Waycar does: nothing in the product.** The rule belongs in herdr's copilot manifest, which herdr ships through its remote manifest catalog with no release needed. Waycar does not install a local override, which would shadow herdr's remote updates for copilot for good (`local_override_shadowing_remote`). It does not report copilot's state to herdr from its hooks either: herdr rejected those hooks as incomplete, and the Status Hook leaves herdr panes to herdr by design. Nor does it lay its own screen reading over herdr's status, which would leave desk and phone disagreeing while pushes still follow herdr. The lab suite records the gap as `HarnessLabProfile.herdrTextTurnsUnreported` (copilot): on herdr it asserts no working → done for text-only turns and waits for the reply on screen instead. Copilot's tool turn is still asserted blocked → working → done.

## 12. Login / first run
Runs fully on BYOK with no account (live). Untrusted cwd → folder-trust dialog (live). Without BYOK it needs `copilot login` (device code) [docs, UNVERIFIED: lab has no account].

## 13. Isolation flag
None needed: one native process per pane, hooks run as its children on the pane tty (live).

## 14. Self-update
- Two switches (source review of 1.0.95's `sea-loader.js` and `cli-main.js`). The npm loader's native binary runs the newest version under `~/.cache/copilot/pkg/<platform>/` unless `--no-auto-update`, `--prefer-version` or `COPILOT_AUTO_UPDATE=false` is set. The background download runs unless `COPILOT_OFFLINE`, `COPILOT_AUTO_UPDATE=false`, `--prefer-version` or the setting `autoUpdate: false` (`~/.copilot/settings.json`) stops it; it defaults to on outside CI. The download takes effect at the next launch ("restart to update").
- Live (lab, 2026-10-12): herdr panes ran 1.0.96 though `env.sh` had `COPILOT_AUTO_UPDATE=false`. herdr panes inherit the herdr server's environment, which predated the variable, so a 1.0.95 launch re-downloaded 1.0.96 (log: "Successfully downloaded package, restart to update to version 1.0.96") and later herdr launches ran it ("Starting Copilot CLI: 1.0.96"). With `{"autoUpdate": false}` in `~/.copilot/settings.json` and the 1.0.96 cache removed, a herdr launch without the variable ran 1.0.95 and made no update check (no log line, no new cache entry after 35 s). The lab sets both (`scripts/harness-lab/host/config/copilot/`).

## Recommended implementation per layer
- **tmux Status Hooks**: add a `copilot` entry writing `~/.copilot/hooks/waycar.json` (`version:1`, PascalCase events so Claude-shaped payloads arrive): `UserPromptSubmit`→working, `PreToolUse`→working-if-active, `Notification` matcher `permission_prompt`→blocked, `Stop`→done, `SessionStart`→hook-session (store `session_id`; `transcript_path` is absent here — derive `~/.copilot/session-state/<id>/events.jsonl` or take it from `Stop`), `SessionEnd`→idle only when id matches. Do **not** map `PermissionRequest`→blocked. Add `copilot` to waycar-hook's agent case.
- **Claude-hook bleed**: guard claude hooks with `[ -n "$COPILOT_CLI" ] && exit 0` (tty match won't catch it).
- **Chat transcripts**: new parser for `events.jsonl` (`user.message.content`, non-empty `assistant.message.content`, `tool.execution_*` activity, `assistant.turn_end`; images via `session.binary_asset` keyed by `assetId`).
- **Chat Prompt**: new route `.copilotInstructionsDir`: write `<stage>/.github/instructions/waycar.instructions.md` (`applyTo: "**"`) and prefix `COPILOT_CUSTOM_INSTRUCTIONS_DIRS=<stage>`.
- **First message**: none at launch (see §6: `-i` hangs hooks on 1.0.96); a Queued Message the Composer sends after input readiness.
- **Resume / session pin**: `--resume=<id>` (existing); `sessionPin` may use `--session-id=<uuid>` (verified).
- **Model/effort**: `--model <m>`, `--reasoning-effort <level>`.
- **Skills**: add project `.claude/skills`.
- **Prompt gate**: generic launch gate suffices if it waits ≥1 s; or gate on the `❯` input row.
- **Message jump**: alt screen + mouse → standard alt-screen handling.
- **Agent Summaries**: `copilot -p … -s --allow-all-tools` is available (help) [not exercised].
