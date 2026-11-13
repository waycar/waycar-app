---
status: accepted
---

# Chat Mode reads harness transcripts through the Waycar plugin

Chat Mode (issue #52) is a New Agent toggle for claude, codex, omp, pi and
opencode.
Its Agent detail is a chat: the user's prompts and the Agent's final reply of
each turn, a live status line, and a Blocked card. The conversation comes from
each harness's own session transcript on the Host, read by the Waycar plugin
(`waycar chat-read`; `src/chat-read.js` before plugin 2.0.0, one SSH exec per read, NDJSON out). Waycar never scrapes
the TUI for it.

ADR 0012 rejected a "chat-style structured view" because herdr has no
conversation API, so message boundaries would have to be reverse-engineered
from TUI repaints and would break with every upstream TUI change. Transcripts
avoid that failure: each harness already writes every user prompt, assistant
message, tool call and turn end to a JSONL file, with explicit records and ids.
Turn boundaries come from those records (a later user prompt, the Agent Status
herdr reports, or the harness's own end-of-turn marker), not from pixels.

The decision:

- **The Chat Prompt rides the harness's launch flag, by file.** It is
  injected at launch, prepended before the user's Arguments and any resume
  args. herdr `agent.start` types the quoted command line into the new pane,
  and a line over the tty's 1,024-byte canonical limit hangs the shell, so
  the prompt is not passed inline: the app first writes it as a Launch Prompt
  File on the Host (one exec, a fresh `0700` `waycar.*` directory in a
  per-user private directory: `$TMPDIR` when it is `0700`, else
  `$XDG_RUNTIME_DIR`, else `~/.cache/waycar/launch-prompts`) and passes its
  absolute path. A first user message, which comes only from the Keychain
  Fix ("Fix it for me…", launched outside Chat Mode), goes the same way, as
  `Read and follow <path>`:

  | kind | Chat Prompt | first user message |
  |---|---|---|
  | claude | `--append-system-prompt-file <path>` (2.1.69+), plus `--session-id <uuid>` when nothing in the user's args picks a session | `-- "Read and follow <path>"` |
  | codex | `-p waycar-<uuid>` (a profile name, not a path): a profile `waycar-<uuid>.config.toml` in the Codex home the Host's panes resolve (`CODEX_HOME` as the user's interactive login shell sets it, else `~/.codex`; read once per connection), holding `developer_instructions = "<prompt>"` (TOML basic string), layered on the user's config and appended as a developer message. Never `model_instructions_file`, which replaces the base instructions. Profiles of that exact name shape older than 10 minutes are removed by the next codex launch that writes one. | `-- "Read and follow <path>"` |
  | omp | `--append-system-prompt=<path>` | positional `Read and follow <path>` |
  | pi | `--append-system-prompt <path>`, plus `--session-id <uuid>` as for claude | positional `Read and follow <path>` |
  | opencode | none for the prompt: `-m <provider/model>` when Settings › Chat Mode sets a model and the user's args set none. Quick thinking is ignored: the opencode TUI has no reasoning-effort flag (`--variant` exists only on `opencode run`). opencode never pins a session: on 1.18.x `--session` only continues an existing session, and nothing can create one by a caller-chosen id (v2.0.22 grows that; revisit when Hosts move to v2). | `--prompt "Read and follow <path>"` |

  The files are `chat-prompt.md` and `first-message.md`, one directory per
  launch. claude and codex support is detected per Host from `--help`.
  Without it (or for codex when the user's args already pick a profile with
  `-p`/`--profile`, or set one with `-c profile=`/`--config profile=`, since
  only one profile applies), the inline flags
  (`--append-system-prompt <prompt>`, `-c developer_instructions="<prompt>"`)
  are used if the typed line fits in 1,000 bytes including Enter; otherwise
  the Chat Prompt file is handed over as the first message (`Read and follow
  <chat> as standing instructions for this session, then read and follow
  <first>`). A resume never sends a pointer: its Chat Prompt rides inline if
  it fits, else the resume goes without it, since the transcript already
  carries it. A launch line that would still exceed the budget fails with an
  error rather than hang. omp and pi silently treat a missing file's path as
  prompt text, so the file is always written before `agent.start`. tmux types
  nothing but uses the same arguments.

  The pinned session id lets the plugin find the transcript by id. codex, omp
  and opencode never pin, and neither does a resume.

  OpenCode has no launch-time system-prompt flag at all, and herdr's
  `agent.start` takes arguments only (no env), so the Chat Prompt cannot ride
  the launch. It rides the plugin instead: `waycar hooks install` puts a
  second opencode plugin, `waycar-chat-prompt.js`, next to the Status Hook
  extension in `~/.config/opencode/plugins/`. It hooks opencode's
  `experimental.chat.system.transform` (per model request) and appends the
  Chat Prompt to the system messages. It finds the prompt in the Chat Marker
  of its own pane: herdr sets `HERDR_PANE_ID` for the Agent processes it
  starts and tmux sets `TMUX_PANE`, so the extension takes the pane from its
  process env. The marker's directory is the plugin config dir, which the
  extension resolves exactly like the app and the hooks, through the
  plugin's host config resolver (`waycar config-dir`; `src/host-config.js` before plugin 2.0.0, loaded from the plugin
  root): herdr passes no `HERDR_PLUGIN_CONFIG_DIR` to the Agents it starts,
  so in a herdr pane that means `herdr plugin config-dir`, once per opencode
  process. Injection is scoped to the marker's pane (no marker,
  no prompt), matches the marker's session once the app has recorded it, and
  survives a herdr server restart — markers keep the pane id, while launch
  flags would be dropped by the resume. The prompt is written into the
  marker as an optional `prompt` field (a normal marker write over SSH, so
  herdr's argument-encoding limits do not apply).
- **A Chat Marker on the Host records Chat Mode.** Right after `agent.start`
  succeeds, the app writes `chat/<pane file name>.json` in the plugin config
  dir with the pane id, terminal id, kind, cwd, session and launch time. Every
  device reads the markers, so an Agent started on the iPhone opens as a chat
  on the iPad; the plugin reads them to put the final reply in Done pushes.
  A marker applies to the Agent in its pane of the same kind in the terminal
  it records, or, after herdr restores the pane in a new terminal (#69),
  under the session it records. The app keeps each marker's terminal and
  session current with the chat Agent it sees.
  When a chat Agent closes, the app drops its entry and deletes its marker
  (best effort). As a backstop, the plugin's notify hook deletes markers whose
  pane is gone, at most hourly and after a 10-minute grace, and skips that
  entirely when named herdr sessions exist on the Host: the chat dir is shared
  by every session and pane ids collide across them.
- **The transcript is bound once and kept.** The plugin reads, in order, the
  session herdr reports live for the Agent (`agent_session`), else the
  session pinned in the marker, else the transcript for the Agent's cwd
  created closest to launch. When that last match succeeds, the app writes
  its path into the marker, so later reads and pushes stay on the same
  transcript. A restarted harness or a changed path makes the app replace the
  chat instead of appending to it (the reader's `after_found` header).

  OpenCode writes no JSONL: sessions live in its SQLite database
  (`~/.local/share/opencode/opencode.db`). Its reader branch runs
  `opencode export <session id>` (JSON on stdout; a progress line on stderr)
  per read and parses `info` / `messages` / `parts`. There is no cwd
  fallback to find, so an opencode chat needs a session from herdr's opencode
  integration (`agent_session`) or, on tmux Hosts, the Status Hook
  extension's `@waycar_session`; the marker keeps it sticky once recorded.
  The header's transcript path is null for opencode, and `export` reports
  only the requested session — subagent work appears inside it as `subtask`
  and tool parts, never as child-session messages.
- **The app sends each read request as JSON on stdin** (`chat-read.js
  --request -`), so no Host-derived value (cwd, session id, message id) is
  ever shell-quoted into the command line.
- **Harness errors surface as the reply.** A turn that ends in an error with
  no final text (codex `task_complete` error, omp/pi `errorMessage`, claude
  API error records) shows the error as its reply, in the chat and in the
  Done push; a retry that then succeeds shows only its own reply.
- **Chat Mode Agents skip Attach until Show Terminal.** The chat needs no PTY
  stream, so Agent detail opens none; Show Terminal starts Attach and going
  back to chat releases it.
- **The device keeps a copy of each chat** (#57). The last messages read for
  a chat are kept on the device: under Application Support, excluded from
  backups, with complete file protection. The copy is capped at 300 messages
  and 2 MB and keyed by Host, pane, terminal and launch time. A chat opens
  from it at once, and the full read that follows reconciles it in place. Only
  a read that found the transcript changes what is shown. A read that fails
  or finds nothing is retried with backoff while the chat is on screen, so a
  chat never sits on the greeting until it is reopened. The copy is deleted
  when the Agent closes, when its Host is removed or retargeted, and after 30
  days unused.
- **Media rides the transcript too** (#60). A turn's final reply carries the
  images the Agent viewed with its tools during that turn, which its TUI shows
  inline: up to 12, in order. omp/pi blob files are named by path; base64 kept
  inline (claude `tool_result`, codex `input_image`, pi) is named by the
  line's byte offset and a JSON Pointer. Replies can also name media:
  Markdown images, and lines holding only a Host path or https URL to an
  image or video. Host files and blobs come over SFTP. Inline images come
  from the plugin's `chat-media.js`, raw bytes on stdout, so base64 never
  rides every transcript read. The phone fetches https links itself. Caps are
  25 MiB per image and 100 MiB per video. Fetched files live in a device cache
  (300 MB LRU, 30 days), and Quick Look is the viewer and the video player.
  The Chat Prompt can't contain `!`, which rules out Markdown image syntax
  there, so it tells Agents to put a media path or URL on its own line.

## Considered Options

- **TUI scraping via `agent.read`**: rejected. The ADR 0012 failure: turn
  boundaries guessed from repaints, and an alternate-screen agent returns only
  its viewport (see AGENTS.md), so earlier turns are gone.
- **Headless per-message runs** (`claude -p` and the equivalents): rejected.
  Each message becomes a separate process, so the Agent is no longer a live
  herdr pane: no Agent Status, no Blocked dialogs, no Show Terminal, and no
  handing the same session to the desk.
- **Harness hooks that write replies**: rejected. Installing them edits the
  user's global harness config on the Host, which Waycar does not own, and
  each harness has its own hook model.
- **Swift-side transcript parsing** (ship the JSONL to the app and parse
  there): rejected. The plugin could not put the reply in a push, since it
  would have no parser, and every parser fix would wait on App Review.

For opencode specifically, several prompt-injection paths were measured
against 1.18.33/1.18.34 and rejected:

- **The TUI's `--prompt` flag**: it is the first user message, auto-submitted
  (`packages/tui/src/routes/home.tsx` submits it once the TUI is ready), not
  a system prompt — it would burn a turn and leave later turns unshaped.
- **`OPENCODE_CONFIG` / `OPENCODE_CONFIG_CONTENT` env vars**: they can inject
  a whole config (agent definitions, `instructions`) without touching user
  files, but herdr's `agent.start` takes no `env` (protocol-22 schema:
  `name`, `kind`, `pane_id`, `args`, `timeout_ms`), and herdr shell-encodes
  every argument, so nothing can set the child's environment.
- **A config-defined agent with a `prompt` key** (`--agent <name>`): the
  agent prompt *replaces* opencode's base system prompt
  (`packages/opencode/src/session/llm/request.ts`), which would strip the
  built-in persona, and a per-launch prompt would need a per-launch agent
  file in the user's global config.
- **Config `instructions`** (paths/URLs appended to the system messages):
  configuration-sourced only, applies to every opencode session on the Host,
  and needs a config file or env to reach.
- **Project-level config** (`opencode.json`, `.opencode/`, `AGENTS.md` in the
  Agent's cwd): writes into the user's project checkout. Never.

## Consequences

- Transcript formats are undocumented and can drift. The parsers live in the
  plugin (`plugin/rust/chat/`; `src/chat-transcript.js` before plugin 2.0.0) and are fixed there, with shared vectors
  in `test-vectors/chat-transcript-v1.json`; an outdated plugin shows an
  "Update the Waycar plugin" notice instead of a chat.
- codex and omp never pin a session, so their transcript is found through
  herdr's integration for the kind when it reports the Agent's session or,
  failing that, the cwd heuristic: among transcripts for the Agent's cwd
  created at or after launch minus 10 s, the one created closest to launch
  (ties to the earlier), made sticky in the marker as above. Their headers
  record process start, not the lazily written file, so one that records a
  start more than 2 minutes after launch belongs to a later Agent in the same
  cwd and never matches; otherwise it could be pinned before this Agent's own
  file exists.
- Blocked dialogs are not parsed. The Blocked card shows the last lines of the
  screen and answers with Enter (Allow) or Esc (Cancel); anything else is
  answered in the terminal through Show Terminal.
- herdr rejects `agent.start` args containing a newline or tab, so the Chat
  Prompt is normalized to one line (whitespace collapsed, control characters
  removed, capped at 8,000 characters) before launch.
- opencode's `export` output and its plugin hooks are internal surfaces, like
  the JSONL formats: the parser and the `waycar-chat-prompt` extension are
  fixed in the plugin, with shared vectors, and an opencode or plugin
  mismatch degrades the same way (chat keeps retrying; the prompt is simply
  missing when the extension is absent). The reader runs one `opencode
  export` per read and parses the whole session, so very long sessions cost
  one big JSON parse per read — the message cap bounds only what is emitted.
- The `experimental.chat.system.transform` hook name carries opencode's
  `experimental.` prefix: a rename there breaks injection (not the chat
  itself) and is caught by the same redeploy-and-verify path as a parser
  drift. Plugin README pins the opencode version the extension was verified
  against.
