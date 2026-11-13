# Kilo Code CLI (`kilo`)

Version tested: **Kilo Code CLI 7.8.8** (npm `@kilocode/cli`, native `linux-arm64` binary, bun 1.4.2 runtime), harness lab (Ubuntu 24.04 aarch64, tmux 3.4, herdr 0.9.3), **2026-10-12**. Compared against opencode **1.19.0** in the same lab and Waycar's opencode extension (verified on opencode 1.18.33/1.18.34).
Auth: `~/.config/kilo/kilo.json` provider `mock` (`@ai-sdk/openai-compatible`, `http://mock:8080/v1`, dummy key), model `mock/mock-model`; no account, no `kilo auth login`.
Raw captures: `/tmp/waycar-harness-captures/kilo/` on the Mac (`events.jsonl` = every plugin hook/event, `export.json`, `probe-kilo-*/timeline.txt` + `*.ansi` screens + `raw.bin`, `rdy*/` input-ready runs, `mock-log.jsonl`).

Method key: **live** = lab; **help** = `kilo --help` / `kilo <cmd> --help` 7.8.8; **docs** = cited URL; **source** = Waycar repo file.

## Kilo vs opencode in one paragraph
Kilo 7.8.8 is opencode with a different name on every path and env var. The plugin API, the event names and payloads, `experimental.chat.system.transform`, the `┃` input box, `--prompt`, `-s/--session`, `-m provider/model`, `kilo export <id>` and its JSON shape are all the same as opencode's (live). What differs: config/data roots (`~/.config/kilo`, `~/.local/share/kilo`, `~/.local/state/kilo`), env prefix (`KILO_*`; `OPENCODE=1` is *also* set in the worker), process layout (Node wrapper `kilo` → native child `.kilo`), Kilo's default permission set (bash `echo *`, `cat *`, `ls *` … auto-allowed), and Kilo **does not read opencode's config dirs** (startup toast, live: "Kilo no longer falls back to opencode configuration. Found opencode config at /home/waycar/.config/opencode. Move it into a .kilo directory (project) or /home/waycar/.config/kilo (global)."). So Waycar's opencode plugins in `~/.config/opencode/plugins` never load under kilo, and need their own copies.

## 1. Hooks (plugins)
- Mechanism (live): JS/TS plugin modules auto-loaded from **`~/.config/kilo/plugins/`** (verified: a file dropped there loaded; `plugin.added {id:"waycar.probe-capture"}` event). herdr 0.9.3's own `herdr integration install kilo` writes `~/.config/kilo/plugin/herdr-agent-state.js` (singular `plugin/`; reported live by the herdr probe), so both spellings load, as in opencode. Project dir `.kilo/plugins/` [INFERENCE from the opencode fork + the toast's ".kilo directory (project)"; not exercised]. Config `"plugin": [...]` npm list also exists (`kilo debug config` shows `@kilocode/kilo-indexing`, `@kilocode/plugin-atomic-chat` built in).
- Module shape (live): the exact export Waycar ships for opencode works unchanged: `export default { id, server: async (ctx) => hooks, setup() {} }`. `ctx` keys and the hook names are opencode's.
- Hooks seen live, in order for one plain turn: `chat.message` (`input.sessionID`, user parts) → events `message.updated`, `message.part.updated`, `session.updated`, `session.status {status:{type:"busy"}}` → `experimental.chat.system.transform` (`input {sessionID, model}`, `output.system` array) → `chat.params` → `message.part.delta` … → `session.status {type:"busy"}` → **`session.status {type:"idle"}` and `session.idle {sessionID}` in the same millisecond** → `session.updated`/`session.diff`. A new session first emits `session.created {sessionID, info:{id, slug, version:"7.8.8", projectID, directory, title, agent:"code", model:{id, providerID}}}`.
- Tool turn (live): `session.next.tool.input.delta` (new in kilo/opencode 1.19 — not in Waycar's switch, harmless) → `tool.execute.before {tool:"bash", sessionID, callID}, output.args.command` → `tool.execute.after`.
- **Approval (blocked)** (live, with `permission.bash = {"*":"ask","echo *":"ask"}`): event `permission.asked {id:"per_…", sessionID, permission:"bash", patterns:["echo waycar-tool-ok"], metadata:{command}, always:["echo *"], tool:{messageID, callID}}`; after "Allow once": `permission.replied {sessionID, requestID, reply:"once"}`. The plugin `permission.ask` hook did **not** fire (event only). Screen: `△ Permission required` / `# Shell command` / `Allow once   Allow always   Reject`.
- **Kilo's default permissions auto-allow the mock's `echo` tool call**: `kilo debug agent code` lists `bash echo * allow` (also `cat`, `head`, `tail`, `ls`, `pwd`, `wc`, `which`, …) and the global `"permission":{"bash":"allow"}`. `permission:{bash:"ask"}` alone did **not** block `echo` (live) — the per-command safe list wins; both `"*"` and `"echo *"` had to be `ask`.
- **A command that names a path outside the project asks first for `external_directory`** (live, fresh lab, 2026-10-12): the mock's `touch /tmp/waycar-tool-mutate && echo waycar-tool-ok` logged `evaluated permission=external_directory pattern=/tmp/* … action=ask` (kilo's default `external_directory "*" ask`; only `/tmp/kilo/*` and kilo's own dirs are allowed) and drew a `# Shell command` dialog; after "Allow once" the `bash` rules asked again in a second, identical-looking dialog. So one approval left the turn blocked. A long-lived lab had passed with one approval; a rebuilt one did not [INFERENCE: an earlier "Allow always", kept per project in `~/.local/share/kilo/kilo.db`'s `permission` table, which a rebuild drops]. The lab's `kilo.json` allows `external_directory` `/tmp/*` (the rule matches the evaluated pattern, a directory glob, not the file), so the mutate call asks once, for `bash`.
- Title generation: after the first turn kilo calls `system.transform`/`chat.params` again with **`sessionID:"title-ses_…"`** and agent `title`. Waycar's Chat Prompt extension matches the marker's session id, so it skips these; with a marker that has no session yet it would append the Chat Prompt to the title request too (same as opencode).
- Session id field: `properties.sessionID` (events) / `input.sessionID` (hooks), form `ses_<26 chars>` (live `ses_ecf088b69ffeFiAu1FQKHe4843`). No transcript path (no file; see 4).
- Lifecycle end: `dispose` fires when kilo exits via `/exit` (live: Waycar's extension released every `@waycar_*` option within 0.8 s). Ctrl+C twice on an idle prompt did **not** exit within 5 s (live).
- **Waycar's opencode Agent Status extension works verbatim under kilo** (live): `~/.config/opencode/plugins/waycar-agent-state.js` copied to `~/.config/kilo/plugins/` with only `const AGENT = "kilo"` changed → `@waycar_agent=kilo`, `@waycar_session=ses_…`, `@waycar_status` `working` → `done` per turn (plain and tool turns), `blocked` on `permission.asked`, `working` after the reply, release on `/exit`. No other edit needed: the extension's `HERDR_PANE_ID`/`HERDR_ENV` no-op and pane-tty check behaved the same.

## 2. tmux pane identity
live: plugins run in the native worker (`…/@kilocode/cli/bin/.kilo`, env `KILO_PROCESS_ROLE=worker`, `KILO_PID` = its own pid) whose parent is the Node wrapper `node ~/.npm-global/bin/kilo`; both on the pane's tty (`pts/6` = `#{pane_tty}` `/dev/pts/6`). `TMUX_PANE` and `TMUX` preserved. `waycar-hook` spawned from the plugin therefore sees `$PPID` = the worker on the pane tty → the tty guard passes. Worker env also carries `KILO=1`, `KILOCODE_VERSION`, `KILO_RUN_ID`, `OPENCODE=1`, and a per-run `KILO_SERVER_PASSWORD` (do not log it).
`#{pane_current_command}` = **`node`** (the wrapper is the foreground process group leader).

## 3. Executable
`kilo` (= kind id) on PATH, a Node script (`~/.npm-global/bin/kilo` → `@kilocode/cli/bin/kilo`) that spawns the native `.kilo` binary. `TmuxAgentDetection`'s `node` unwrapping resolves `kilo` from the script path (argv `node /home/waycar/.npm-global/bin/kilo`). `kilocode` is also shipped in `bin/` [help listing of the package dir; not on PATH in the lab].

## 4. Transcript
- No transcript file. Sessions live in SQLite **`~/.local/share/kilo/kilo.db`** (live; `kilo debug paths`: data `~/.local/share/kilo`, config `~/.config/kilo`, state `~/.local/state/kilo`, cache `~/.cache/kilo`, log `~/.local/share/kilo/log`).
- **`kilo export <sessionID>` exists and matches `opencode export`** (live): stdout = one JSON object `{info, messages:[{info, parts}]}`, stderr `Exporting session: ses_…`, exit 0. `info` keys: `agent cost directory id model path projectID slug summary time title tokens version`. Part types seen: `text`, `step-start`, `step-finish` (`reason:"stop"`), `tool` (`tool:"bash"`, `callID`, `state:{status:"completed", input:{command}, output, title, time}`), **`file`** (`mime:"image/png"`, `filename`, `url:"data:image/png;base64,…"`, `source.path`). User info: `{role:"user", agent, model:{providerID, modelID}, time.created}`; assistant info adds `parentID`, `mode`, `tokens`, `finish:"stop"`, `time.completed`. Extra flag `--sanitize` (help) redacts data.
- `kilo session list [--format json] [-n N] [-a]` (help, live table: id, title, status, updated).
- Images (live): pasting the path `/tmp/probe-kc/dot.png` into the input turned into `[Image 1]` and the export stored it as a base64 `file` part. With the lab's model lacking `modalities.input: ["image"]`, kilo replaced it in the request with `ERROR: Cannot read "dot.png" (this model does not support image input)`; with modalities set (via `KILO_CONFIG_CONTENT`) that text disappeared (the mock log does not record image parts, so the image bytes on the wire were not observed).

## 5. Chat Prompt injection route
- No system-prompt CLI flag (help). **`experimental.chat.system.transform` works** (live): a plugin pushing a marker into `output.system` made the mock's `system` end with `WAYCAR_KILO_SYS_MARKER injected by probe plugin`. Waycar's `waycar-chat-prompt.js` can be installed to `~/.config/kilo/plugins/` unchanged (it is kind-agnostic: pane id from `TMUX_PANE`/`HERDR_PANE_ID`, marker matched by `input.sessionID`).
- Alternative not used: `KILO_CONFIG_CONTENT` env (live: honoured; merged over the global config) could carry `instructions`, but herdr's `agent.start` passes no env (see opencode's ADR note), so the plugin route is the one that works on both backends.

## 6. First message
`--prompt "<text>"` (live: submitted on launch, TUI stays open; status went working → done with no typing). Same as opencode's existing `firstMessageArguments` entry.

## 7. Resume
`-s/--session <id>` (live: `kilo -s ses_ecf088b69ffeFiAu1FQKHe4843` reopened the session with its full history; the exit banner prints `kilo -s <id>`). `-c/--continue` (last session), `--fork`, `--cloud-fork` (help). Id form only (no path). On resume the status extension reports `@waycar_session` only once the session is touched (first `session.updated`/`chat.message`), as in opencode. Existing `ClosedSession` `["--session", id]` for `.kilo` matches.

## 8. Model / effort
- `-m provider/model` (live: `-m mock/mock-model`; mock `model:"mock-model"`).
- **No effort flag on the TUI** (live: `kilo --variant high` → yargs prints help and exits). `--variant` exists only on `kilo run` (help). In the TUI, variants are picked with `ctrl+t` (footer "ctrl+t variants" when the model defines variants) and persisted per model in `~/.local/state/kilo/model.json` (`"variant":{"mock/mock-model":"default"}`). Config `agent.code.variant:"high"` did not change the request (live: `effort:null`). Same limitation Waycar already documents for opencode.

## 9. Skills / commands
live (fixtures in `~/work/demo` and `~/.config/kilo`, checked with `kilo debug skill` and the TUI `/` menu, then invoked and read back from the screen):
- Skills (`<name>/SKILL.md` with `name`/`description` front matter): **`.kilo/skills/` ✓, `.kilocode/skills/` ✓, `.agents/skills/` ✓, `~/.config/kilo/skills/` ✓; `.opencode/skills/` ✗**. Menu shows `/<name>:skill`; typing the bare `/<name> go` expanded the body plus `Base directory for this skill: …` into the user message.
- Commands (flat `<name>.md`): **`.kilo/commands/` ✓, `~/.config/kilo/commands/` ✓** (`/wckp-cmd go` → body + `go`); legacy **`.kilocode/workflows/` ✓** (menu `Workflow: <name>`). `~/.kilocode/workflows` not exercised.
- Built-in skill `/kilo-config:skill` exists. Precedence on a name clash not exercised.
- `AgentSkill.swift`'s `.kilo` entry (commands/workflows only, "skill directories are not documented") is missing the four skill roots above.

## 10. Alt screen / mouse / input readiness
- live raw bytes: `?1049h` (alt screen), mouse `?1000h ?1002h ?1003h ?1006h`, `?2004h` bracketed paste, `?2026h`/`?2027h`/`?2031h`. `#{alternate_on}=1`, `#{mouse_any_flag}=1` from ~1.4–2.4 s after launch.
- Startup: blank alt screen from ~1.4 s, then the logo + **`┃` input box** at **4.3–5.5 s** (6 warm launches). Ready screen: `┃  Ask anything... "What is the tech stack of this project?"`, `┃  Code  · mock-model <provider name>`, `╹▀▀▀…`, `tab agents  ctrl+p commands`, `~/work/demo:main … 7.8.8`.
- **Input-ready gate needed — identical to opencode** (live, `set-buffer` + `paste-buffer -p` then Enter 0.4 s later, prompt checked in the mock log): pastes at 1.0, 2.5, 3.5 and **4.0 s (box at 4.29 s)** were all lost; 4.5 s (box at 4.26 s) landed. `OpencodeScreen.inputIsOnScreen` (`┃` row) is the right predicate for kilo.
- Working marker: footer `■■■⬝⬝  esc interrupt` spinner; done: footer shows the token count (`17.7K  ctrl+p commands`), no `esc interrupt`.

## 11. herdr integration tier
herdr 0.9.3 (reported live by the herdr-backend probe, 2026-10-12): `herdr integration install kilo` writes `~/.config/kilo/plugin/herdr-agent-state.js`; with it herdr reports `agent_session {source:"herdr:kilo", kind:"id", value:"ses_…"}` once the first turn starts (not at launch) and screen detection is skipped (`full_lifecycle_hook_authority`). A prompt typed ~4 s after launch (after herdr cleared `launch_pending`) was lost on the blank screen in 2/2 runs — herdr's own gate does not cover kilo's slow start.

## 12. Login / auth
None needed: custom provider in `kilo.json` (live). Startup toasts seen: the opencode-config migration notice (only because `~/.config/opencode` exists) and tips. Kilo writes `~/.local/share/kilo/telemetry-id`; the Kilo Gateway provider defaults to `kilocodeToken:"anonymous"`.

## 13. Daemon / isolation
- No daemon by default (live: `kilo daemon status` → "kilo daemon not running"; each TUI runs its own worker on the pane tty, section 2).
- **`kilo daemon` breaks per-pane status** (live): with `kilo daemon start` running (`.kilo serve --hostname 127.0.0.1 --port 4097`, parent pid 1, no tty, state file `~/.local/state/kilo/daemon.json`), a TUI launched in tmux **attached to the daemon**: plugins were initialised only in the daemon process (no tty, no `TMUX_PANE`, `KILO_PROCESS_ROLE=main`), the turn's `chat.message`/`session.idle` fired there, and the TUI's own process loaded no plugin. Waycar's extension therefore stayed silent (`@waycar_status` unset) — safe (its `TMUX_PANE` check no-ops), but no status. No TUI flag to opt out was found (`kilo --help` has none; the binary's JS is not greppable). This is opt-in by the user; Waycar should not start a daemon, and can report "daemon running → screen fallback" from `kilo daemon status --json` (`running: true`).
- `--pure` disables external plugins (help) — never pass it.
- Other TUI modes: `KILO_DISABLE_MOUSE=1` (live: alt screen kept, no mouse modes emitted); `--mini` (live: inline, no alt screen, no mouse — prompt `Ask anything... "Fix a TODO in the codebase"` and a `BUILD` footer, no `┃` box, so `OpencodeScreen` does not apply to it).

## Recommended implementation per layer
- **tmux Status Hooks**: add `kilo` to `HOOK_AGENTS`/`EXTENSIONS` with files `["waycar-agent-state.js", "waycar-chat-prompt.js"]`, dir `${XDG_CONFIG_HOME:-~/.config}/kilo/plugins`, sourced from the opencode files with `AGENT` parameterised (one template, two kinds) — no logic change. Add `kilo` to `waycar-hook`'s `case $agent` arm and `hook-session.js` `AGENTS`. Detection: `~/.config/kilo` or `kilo` on PATH.
- **Notifications**: nothing kind-specific.
- **Chat Mode (app)**: `supportsChatMode` += `.kilo`; `ChatModeLaunch.arguments` same as `.opencode` (`-m <model>`, ignore effort); `LaunchPromptStager` route = plugin (no flag), first message `["--prompt", pointer]`.
- **Chat transcripts/media**: generalise `opencode-export.js` to take the binary name (`kilo export <ses_…>`, same id regex `^ses_[A-Za-z0-9_-]+$`, same JSON); binary lookup `kilo` on PATH then `~/.npm-global/bin`, `/usr/local/bin`. Reuse the opencode parser for parts (`text`, `tool`, `file` data URLs).
- **Resume**: keep `["--session", id]`; id from `@waycar_session` (tmux) or herdr `agent_session` kind `id`.
- **Message jump**: alt screen + mouse like opencode — standard handling.
- **Skills**: replace the `.kilo` `SkillSourceCatalog` entry with the live-verified roots (section 9): `.kilo/skills`, `.kilocode/skills`, `.agents/skills`, `~/.config/kilo/skills` (`<name>/SKILL.md`), plus `.kilo/commands`, `~/.config/kilo/commands`, `.kilocode/workflows` (flat `.md`); prefix `/` with the bare name.
- **Prompt delivery gate**: reuse `OpencodeScreen` for `.kilo` on both backends (tmux `checkLaunchReadiness`, herdr `promptAgent`); herdr's `launch_pending` alone loses prompts.
- **tmux launch**: executable `kilo`; no isolation flag exists or is needed while no `kilo daemon` runs (13).
- **Agent Summaries**: `kilo run --format json -m <model> "<instruction>"` is the one-shot path [help; not exercised].

## Not verified live (and why)
- Project plugin dir `.kilo/plugins/` — only the global `~/.config/kilo/plugins/` was exercised (the toast and the opencode fork imply it).
- Image bytes on the wire — the mock's request log keeps only text parts; the export's `file` part and the absence of kilo's "model does not support image input" substitution are the evidence.
- A TUI effort/variant at launch — none exists (help + live `--variant` rejection); only `kilo run --variant`.
- Mock request log before 17:04 UTC was lost when the lab VM crashed and the mock restarted; `mock-log.jsonl` holds the post-restart re-capture (`-m mock/mock-model --prompt …` with the system-transform marker, UA `Kilo-Code/7.8.8 ai-sdk/provider-utils/4.0.27 runtime/bun/1.4.2`). Earlier mock facts in this file (first `--prompt`, image turn, `effort:null` with `agent.code.variant`) were read live before the crash and are recorded here only.
- herdr facts (section 11) come from the parallel herdr-backend probe on the same lab, not from this probe's own runs.
