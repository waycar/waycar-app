# Cline CLI (`cline`)

Version tested: **Cline CLI 3.0.70** (npm `cline`, SDK `@cline/core`/`@cline/shared` 0.0.92, native `linux-arm64` binary `.cline`), harness lab (Ubuntu 24.04 aarch64, tmux 3.4, herdr 0.9.3), **2026-10-12**.
Auth: `cline auth -p openai -k <dummy> -m mock-model -b http://mock:8080/v1` (lab `setup.sh`) → provider `openai-compatible` in `~/.cline/data/settings/`; no Cline account.
Raw captures: `/tmp/waycar-harness-captures/cline/` on the Mac: `hooks.jsonl` (stdin payload + env + hook/spawner pid, tty and argv for every hook call), `exec-tty.txt` (tty guard check with an `exec`ing hook), `sessions/<id>/` (a 3-turn local-mode session with tool call and image, and a hub-mode session), `probe-cline-*/`, `clblock/`, `clfirst/`, `clresume/`, `clskill/`, `coldhub/` (`timeline.txt` screen snapshots with `#{alternate_on}`/mouse flags, `*.ansi` from `capture-pane -e -p`, `raw.bin` from `pipe-pane`), `crdy*/` (input-ready runs), `mock-log.jsonl` (post-17:04 requests; earlier ones were lost in a lab VM crash).

Method key: **live** = lab; **help** = `cline --help` 3.0.70; **source** = the installed `@cline/core`/`@cline/shared` 0.0.92 JS and strings of the `.cline` binary.

## 0. The hub daemon (read first)
Cline runs agent sessions either **in the TUI process** ("local") or in a per-user **hub daemon** (`.cline --cline-hub-daemon --cwd <cwd> --host 127.0.0.1 --port <n> --pathname /hub`, parent pid 1, no tty; discovery/lock `~/.cline/data/locks/hub/production.json`). Tasks, tools **and hook scripts** run wherever the session runs.
- source (`.cline` strings): `cline -i` builds its runtime with `backendMode:"auto", forceLocalBackend: config.mode==="yolo" || config.sandbox===true`; `auto` attaches to a compatible running hub, else "Falling back to local runtime host" and starts a hub for later. `CLINE_SESSION_BACKEND_MODE` is read only when no explicit `backendMode` is passed, so it does nothing for `-i` (live: hooks still came from the hub).
- live, **first launch with no hub** (`coldhub`, 17:04): the session ran in the pane's `.cline` (hooks spawned by `.cline -i` on the pane tty) and a hub was started in the background.
- live, **every later `cline -i`** (hub running): hooks are spawned by the hub; no tty; env = the **hub's startup env**, e.g. `TMUX=/tmp/tmux-1000/default,8349,0`, `TMUX_PANE=%0` — the pane and server pid of whichever pane launched the first `cline`, for sessions in every other pane (after a tmux restart `%0` named an unrelated pane on `/dev/pts/1`). The session manifest's `pid` is the hub's.
- live, **`cline -i --data-dir ~/.cline/data`** (sandbox mode → `forceLocalBackend`): always local. Hooks spawned by `.cline -i --data-dir …` on the pane tty with the correct `TMUX_PANE`; manifest `pid` = that process. Passing the default data dir explicitly keeps settings, history and sessions shared with plain `cline`; global hooks in `~/.cline/hooks` still fire (live). `-y/--yolo` also forces local but changes approvals — not usable.

## 1. Hooks
- Mechanism (source `@cline/core` `oi()`/`MS()`; live): one **file per event**, named `<EventName>[.ext]` (case-insensitive), in each search dir. `resolveHooksConfigSearchPaths(cwd)` (called live) = `~/Documents/Cline/Hooks`, **`~/.cline/hooks`**, `<cwd>/.clinerules/hooks`, `<cwd>/.cline/hooks`. Extensions: none or `.sh .bash .zsh` → `bash <file>`; `.js .mjs .cjs` → `node`; `.ts .mts .cts` → `bun run`; `.py` → `python3`; `.ps1` → `pwsh`. No exec bit needed. stdin = JSON payload; env = the running process's env.
- **`--hooks-dir <path>` did not run its hooks** (live: `TaskStart`/`TaskComplete`/`PreToolUse` files in a `--hooks-dir` directory never ran, while `~/.cline/hooks` fired in the same session). Install into `~/.cline/hooks`.
- Event files → `hookName` (source): `TaskStart`→`agent_start`, `TaskResume`→`agent_resume`, `TaskCancel`→`agent_abort`, `TaskComplete`→`agent_end`, `TaskError`→`agent_error`, `PreToolUse`→`tool_call`, `PostToolUse`→`tool_result`, `UserPromptSubmit`→`prompt_submit`, `SessionShutdown`→`session_shutdown`, `PreCompact`→ unmapped (never runs). **No permission/approval event, no notification event.**
- Detached vs blocking (live): `TaskStart`, `TaskComplete`, `SessionShutdown` run **detached** (hook bash has no tty, output ignored — a `TaskStart` printing `{"context":…}` changed nothing in the request); `PreToolUse`/`PostToolUse` run **attached** (hook bash on the pane tty). source: stdout JSON `{cancel, context|contextModification, errorMessage, review, overrideInput}` is parsed for the blocking ones.
- Order (live, `-i`, auto-approve on), per user turn: `TaskStart` → (`PreToolUse` → `PostToolUse`)* → `TaskComplete`. Turns 2 and 3 of the same session fired **`TaskStart` again**; `UserPromptSubmit` never fired in `-i` (6 sessions). The first turn after `--id <id>` fired **`TaskResume`** (`taskResume:{taskMetadata:{}, previousState:{}}`) instead of `TaskStart`.
- With `--auto-approve false` (live): `PreToolUse` fired **before** the approval dialog, then nothing until `PostToolUse` after `y` → `TaskComplete`. Hooks cannot tell "waiting for approval" from "tool running".
- Esc during a `WAYCAR_SLOW` turn (live): `SessionShutdown` with no `reason` (not `TaskCancel`; source fires `TaskCancel` only when the abort reason contains cancel/abort/interrupt), although the TUI stayed open. `/exit` produced no hook (live).
- Payload (live `TaskStart`): `{clineVersion:"", hookName:"agent_start", timestamp, taskId:"conv_1791823635208_zqlcy0d", sessionContext:{rootSessionId:"1791823632626_6jtha"}, workspaceRoots:[cwd], workspaceInfo:{rootPath, hint, latestGitCommitHash, latestGitBranchName}, userId:"waycar", agent_id:"agent_<uuid>", parent_agent_id:null, taskStart:{taskMetadata:{}}}`. `TaskComplete` adds `iteration`, **`turn:{outputText:"<final reply>", status:"completed"}`**. `PreToolUse`: `tool_call:{id, name:"run_commands", input}`, `preToolUse:{toolName, parameters}`. `PostToolUse`: `tool_result`, `postToolUse:{toolName, parameters, result, success, executionTimeMs}`.
- **Session id** = `sessionContext.rootSessionId` (`<epoch ms>_<5 chars>`, = the session directory name, = `--id` value). `taskId` (`conv_…`) is per run: stable across the turns of one launch, new after `--id` resume. No transcript path in the payload (derive it, section 4).
- **TaskComplete vs idle**: `TaskComplete` fires at the end of **every** turn when the input box returns → Waycar `done` (then `idle` on focus). No separate idle event.

## 2. tmux pane identity
- Hub mode (default after the first launch): **broken** — stale `TMUX_PANE`, hook parent = hub with no tty. `waycar-hook`'s guard rejects every call (live `exec-tty.txt`: `ppid=527 ppid_tty=? ppid_cmd=.cline pane=%0 pane_tty=/dev/pts/1`) — no wrong attribution, but no status.
- Local mode (`--data-dir`): the detached hook bash has no tty, its parent `.cline` is on the pane tty. A hook file that **`exec`s** `waycar-hook` passes the guard (live: `exec /tmp/…/ttycheck.sh` → `ppid=.cline ppid_tty=pts/0`, pane `%0` on `/dev/pts/0`); running `waycar-hook` as a child of the hook bash would fail it.
- `#{pane_current_command}` = `node` (wrapper `node ~/.npm-global/bin/cline` → native `.cline`).

## 3. Executable
`cline` (= kind id): Node wrapper `~/.npm-global/bin/cline` spawning `…/cline/bin/.cline`. Waycar's `node` unwrapping resolves it.

## 4. Transcript
- File per session (live): **`~/.cline/data/sessions/<sessionId>/<sessionId>.messages.json`** — one JSON document `{version, sessionId, agent, origin, system_prompt, updated_at, messages:[…]}`, **rewritten in place** (not JSONL). Messages are Anthropic-shaped: `{id, role, content:[blocks], ts, modelInfo?:{id, provider}, metrics?:{inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens}}`; blocks `text`, `tool_use {id, name, input}`, `tool_result {tool_use_id, name, content:[{query, result, success, error?}]}` (inside a `user` message), `image {data:<base64>, mediaType:"image/png"}`. User text is wrapped `<user_input mode="act">…</user_input>`. Resume (`--id`) appended to the same file (live: request carried 9 messages).
- Manifest `<sessionId>.json`: `{version, session_id, source:"cli", pid, started_at, exit_code, status:"idle"|…, interactive:true, provider, model, cwd, workspace_root, prompt, metadata:{git, checkpoint}}`.
- Root: `--data-dir` (default `~/.cline/data`); config root `--config` (default `~/.cline`). Listing: `cline history --json [--limit N]` (live) = the manifests; `cline history export <id>` writes HTML (help).
- Images (live): a pasted PNG path became `[Image 1]` in the input; the transcript holds the base64 `image` block.

## 5. Chat Prompt injection route
- `-s, --system "<text>"` **replaces** the whole system prompt (live: mock `system` = exactly `WAYCAR_CLINE_SYS_MARKER custom system`, 37 chars, vs 4266 chars by default; the 25 native tools were still sent). No append flag (help).
- Rules are appended, but every rules root is global or per-workspace, never per-session (`resolveRulesConfigSearchPaths`, live call): `<cwd>/AGENTS.md`, `<cwd>/.clinerules`, `<cwd>/.cline/rules`, `~/.agents/AGENTS.md`, `~/.cline/rules`, `~/Cline/Rules`, `~/Documents/Cline/Rules`.
- Hook `context` from `TaskStart` was ignored (detached); `UserPromptSubmit` never fires in `-i`.
- **Cannot support a per-pane Chat Prompt append**: the only per-launch route throws away Cline's own system prompt.

## 6. First message
Positional `cline -i "<prompt>"` (live: submitted at launch, TUI stayed interactive). Without `-i` the positional runs headless (help: "Default to start in act mode with auto-approve enabled").

## 7. Resume
`--id <sessionId>` (live: `cline -i --data-dir ~/.cline/data --id 1791823632626_6jtha` redrew all three earlier turns, `TaskResume` fired on the next prompt, same `rootSessionId`). The exit summary prints `Continue  cline --id <sessionId>`. Id form only. `ClosedSession` currently returns `[]` for `.cline`.

## 8. Model / effort
`-m <model-id>` (with `-P/--provider`, default `cline`) and `--thinking <none|low|medium|high|xhigh>` (live: `-m mock-model --thinking high` → mock `model:"mock-model"`, `effort:"high"`; footer `mock-model (high)`).

## 9. Skills
live (fixtures, `/` menu, invocation): skills `<name>/SKILL.md` found in **`.cline/skills`, `.clinerules/skills`, `.agents/skills`, `~/.cline/skills`** (source adds `~/.agents/skills`); menu `/<name>`, and invoking `/name go` sends the literal text plus a `skills` tool the model calls (the body is not inlined). Workflows `.clinerules/workflows/<name>.md` show as **`/<name>` without `.md`** and expand inline (live: `/wcprobe-wf go` → `Reply with WORKFLOW-BODY go`). Workflow roots (source): `.clinerules/workflows`, `~/Documents/Cline/Workflows`, `~/.cline/workflows`, `.cline/workflows`.

## 10. Alt screen / mouse / input readiness
- live raw bytes: `?1049h`, mouse `?1000h ?1002h ?1003h ?1006h`, `?2004h`, `?2026h ?2027h ?2031h`. `#{alternate_on}=1`, `#{mouse_any_flag}=1` from ~0.8–1.0 s.
- Ready screen (1.0–1.8 s, cold or warm): logo, `What can I do for you?`, `❯ What can I do for you?` input row between `────` rules, footer `mock-model (0) $0.00   ○ Plan ● Act (Tab)`, `demo (main)`, `▶▶ Auto-approve all enabled (Shift+Tab)` (or `Auto-approve all disabled`).
- **Input-ready gate needed** (live, paste + Enter 0.4 s later, checked in the mock log): every paste **before the input row was drawn was lost** (hub mode 0.3/0.6/0.9 s with the row at 1.0–1.2 s; local mode 0.3–1.2 s with the row at 1.2–1.8 s); 1.2 s with the row drawn at 1.23 s and 2.0 s on a cold start (row at 1.24 s) landed. The lab smoke's "first two launches drop the prompt" is this race.
- **Enter on the paste's own tmux line is swallowed** (live, 2026-10-12, tmux 3.4, `set-buffer ; paste-buffer -p -d ; send-keys Enter` in one command): the text stayed in the composer unsubmitted. The next paste+Enter then submitted the **earlier** text while the composer kept both texts run together (`❯ hello …P1run WAYCAR_TOOL now …`). A raw CR (`send-keys -H 0d`) 0.5 s after the paste submitted each time (2/2), so Waycar uses a 500 ms `submitDelay` on tmux. herdr's `agent.prompt` submits fine.
- Working: `⠋ Thinking... (esc to cancel)`. Idle/done: `❯ Ask anything...`; replies prefixed `* `, prompts `❯ `.
- **Blocked (screen only)**: `Cline needs permission` / `Approve tool call?` / tool + commands / `[y] Approve   [n] Deny` (live, `--auto-approve false`). Default `-i` has **auto-approve all enabled** (Shift+Tab toggles), so with default flags nothing ever blocks. **A raw `y` approves, a pasted one does not** (live, 2026-10-12, one run each): tmux `send-keys y`, herdr `agent.send_keys ["y"]`, `herdr pane send-keys … y` and `herdr pane send-text … y` ran the tool. A bracketed paste of `y` (tmux `paste-buffer -p`, herdr `pane.send_input {text:"y"}`, which honors the pane's bracketed-paste mode) left the dialog up.
- **One-time notices** (live, rebuilt lab, 2026-10-12, 3.0.70): a fresh data dir showed an `Introducing Cline Desktop` modal over the chat (`Get Cline Desktop` / `Press Enter to open, any other key to close`) in the e2e's tmux case, after the herdr case's launches, and it covered the approval dialog, so neither the screen rules nor the approval watch saw `blocked`. Seen notices are kept in `<data-dir>/settings/cli-notices.json` (`{"shown": {"cline-cli-cline-pass-intro": true, "cline-cli-desktop-launch": true}}` after that run); the lab ships that file (`host/config/cline/home/`) so a rebuilt Host shows neither. Which notice shows when follows remote feature flags (`cache/feature-flags.json`: `ext-cline-pass`) [INFERENCE].

## 11. herdr integration tier
herdr 0.9.3 has **no cline integration** (reported live by the herdr-backend probe): screen detection only, no `agent_session`; herdr launches `cline`, appending `-i` when given.

## 12. Login / auth
No account with `cline auth -p openai … -b <url>` (live). The default provider id is `cline` (account login).

## 13. Daemon / isolation
The hub (section 0) is Cline's shared-daemon problem, worse than Codex's because its env is frozen at its first launch. Isolation flag: **`--data-dir ~/.cline/data`** (live-verified above).

## Recommended implementation per layer
- **tmux Status Hooks**: add `cline` to `HOOK_AGENTS` with a new hook-file kind: write `~/.cline/hooks/{TaskStart,TaskResume,PreToolUse,PostToolUse,TaskComplete,TaskError,SessionShutdown}` (extension-less bash, marked "managed by waycar"), each `exec <plugin>/bin/waycar-hook cline <status>` (`TaskStart`/`TaskResume`/`PreToolUse`/`PostToolUse` → working, `TaskComplete` → idle (done after a turn), `TaskError` → blocked or idle). Add `cline` to `waycar-hook`'s case arm. Session id: a small hook (or `hook-session.js` path) writes `@waycar_session` from `sessionContext.rootSessionId`. Works **only in local mode** — launch with `--data-dir ~/.cline/data` (below); in hub mode the tty guard drops everything (safe).
- **Blocked status**: no hook exists. On tmux the `PreToolUse` file runs `waycar-hook cline watch-approval`, whose Host-side screen watch (`plugin/src/approval-watch.js`) sets blocked while `Cline needs permission`/`[y] Approve   [n] Deny` shows and pushes for it; the app's tmux screen fallback reads the same rule. On herdr, herdr's own cline screen rules report it. Default auto-approve never blocks. Approve with a `y` key, never a paste (§10).
- **Prompt delivery on tmux**: paste, then a raw CR on its own line 0.5 s later (`AgentScreen.readiness(kind:)` `submitDelay`, §10).
- **Notifications**: nothing kind-specific.
- **Chat Mode (app)**: **cannot support the Chat Prompt** without replacing Cline's system prompt (`-s` replaces; rules dirs are global; hook context ignored). If Chat Mode is enabled anyway: `-m <model>`, `--thinking <level>`, first message as a positional after `-i`.
- **Chat transcripts/media**: feasible: read `~/.cline/data/sessions/<id>/<id>.messages.json` (whole-file JSON, re-read on change; strip `<user_input mode="…">` wrappers; `tool_use`/`tool_result` → activity; `image` blocks base64 → media). Session id from `@waycar_session` or the newest manifest whose `pid` = the pane's `.cline` pid (local mode).
- **Resume**: `ClosedSession.resumeArguments(.cline)` → `["--id", id]` (plus `-i` and `--data-dir ~/.cline/data` from the launch).
- **Message jump**: alt screen + mouse — standard handling.
- **Skills**: `.cline/skills`, `.clinerules/skills`, `~/.cline/skills` are right; add `.agents/skills` (and `~/.agents/skills`); workflows can now be listed as `/name` (no `.md`), contrary to the current comment.
- **Prompt delivery gate**: needed on both backends: wait for the `❯ ` input row under the `────` rule (or `What can I do for you?`/`Ask anything...`) before pasting; herdr's `launch_pending` is not enough.
- **tmux launch**: `cline -i --data-dir ~/.cline/data` (the `--no-daemon` equivalent), skipped when the user's arguments already set `--data-dir`.
- **Agent Summaries**: headless `cline --json "<instruction>"` [help; not exercised].

## Not verified live (and why)
- Project hook dirs (`.clinerules/hooks`, `.cline/hooks`) and `~/Documents/Cline/Hooks` — from the live `resolveHooksConfigSearchPaths` call only; only `~/.cline/hooks` had files.
- `TaskError`, `PreCompact` — no error/compaction was provoked by the mock.
- Why `--hooks-dir` hooks did not run — observed, not explained.
- Image bytes on the wire — the mock log keeps only text parts; the transcript's `image` block is the evidence.
- Mock requests before 17:04 UTC (turns of the 3-turn session, `UA ai-sdk/openai-compatible/3.0.58`) were read live but lost from the mock log in the lab VM crash; later runs (`clfirst`, `clresume`, `clskill`, `coldhub`) are in `mock-log.jsonl`.
