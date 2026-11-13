# opencode (`opencode`): re-verification on 1.19.0

Version tested: **opencode 1.19.0** (`opencode.ai/install --version`, linux aarch64, bun 1.3.14 runtime) in the harness lab: Ubuntu 24.04, tmux 3.4, herdr 0.9.3, and Waycar Host Tools installed from this worktree. Date: 2026-10-12. The model is the lab mock: `@ai-sdk/openai-compatible` at `http://mock:8080/v1`, `mock/mock-model` in `~/.config/opencode/opencode.json`. This file records only the deltas and confirmations against Waycar's code and AGENTS.md (whose facts are from 1.18.33 and 1.18.34).

Method tags: **live** means observed in the lab on this version; **source** means review of this worktree. Raw captures are in `/tmp/waycar-harness-captures/opencode/` on the Mac:

- `hooks/events.jsonl`: every plugin `event`, `tool.execute.*` and `permission.ask`, with the plugin process's `TMUX_PANE` and tty, logged by a temporary plugin `probe-capture.js`, since removed.
- `a/`: a 3-turn session with readiness tokens.
- `b/`: the Chat Mode launch.
- `c1/`, `c2/`: readiness timing.
- `transcripts/` (the `opencode export` JSON and `readchat.ndjson`) and `mock-log.jsonl`.

## Drift
None that needs a code change. New on 1.19.0, unused by Waycar: top-level `--mini` ("start the minimal interactive interface"), plus `--no-replay` and `--replay-limit` (`opencode --help`).

## Confirmed (still matches Waycar's code)

### Input-ready gate
`OpencodeScreen.inputIsOnScreen` (a `┃` row) still holds. Live: pastes every 0.25 s, with a parallel 0.1 s `capture-pane` poll for `┃`.

| run | alternate screen on | `┃` box first drawn | first paste that landed |
|---|---|---|---|
| c1 (warm) | +0.72 s | +3.03 s | `r3.0` |
| c2 (warm) | +1.11 s | +4.41 s | `r4.5` |
| a (first launch, 0.5 s pastes) | +2.5 s | not polled | `r5.9` |
| b (Chat Mode) | — | +3.05 s after opencode exec | the `--prompt` first message, sent by opencode itself |
| resume (`--session`) | — | +3.2 s | — |

- Every paste before the box was dropped, and the first paste after it landed: the 1.18.34 behaviour is unchanged.
- The home-screen box is centred, so the `┃` row has leading spaces. The pattern strips leading whitespace, so it matches.

### Status Hooks
The `waycar-agent-state.js` plugin (live, `a/opts.log`):

| When | Pane options |
|---|---|
| launch, before the first prompt | no `@waycar_*` option set |
| first prompt | `@waycar_agent opencode`, `@waycar_session ses_…`, then `working` |
| `session.idle` after a turn | `done` |
| `permission.asked` | `blocked`, 2.2 s into the turn, with the "Permission required" dialog on screen |
| `permission.replied` | `working`, then `done` |
| Ctrl+C exit | every `@waycar_*` cleared |

- The `permission.asked` payload is `{id, sessionID, permission: "bash", patterns, metadata.command, always, tool{messageID, callID}}`.
- The default permissions allowed `bash`. The approval came from `OPENCODE_CONFIG_CONTENT='{"permission":{"bash":"ask"}}'`.
- The plugin process carries the pane's `TMUX_PANE`, and its tty matched the pane, so status writes went through.
- At the first prompt, opencode emits a burst of `plugin.added`, `catalog.updated` and `integration.updated` events. The first turn took 6.9 s against the mock's 1.5 s (later turns about 1.7 s).

### Chat Prompt route and first message
`ChatModeLaunch` gives `-m`; `LaunchPromptStager.firstMessageArguments` gives `--prompt` (live):

```
opencode -m mock/mock-model --prompt 'Read and follow <stage>/first-message.md'
```

- The Chat Marker was written to `~/.config/herdr/plugins/config/waycar/chat/<base64url("tmux:%93")>.json`, with `prompt` set and `session` null.
- `waycar-chat-prompt.js` (`experimental.chat.system.transform`) appended the marker's prompt to `system` on both the session request and the title-generator request (mock log, 16:46:51–52). The hook still exists on 1.19.0.
- `--prompt` sent the first message on its own as soon as the TUI was up.
- Quick thinking stays ignored, correctly: the top-level help has no effort or variant flag.

### Resume
`opencode --session <id>` (`ClosedSession.resumeArguments`) reopened the session with its history (live). opencode's own exit hint is `opencode -s <id>`.

### Transcript
- **Source.** There is still no transcript file. `opencode export <id>` drives the parser.
- **Parser (live).** `readChat` by id returned `status: ok`, 8 messages.
- **Pasted image.**
  - A pasted image path becomes `[Image 1]`, a `file` part with a data URL.
  - It surfaces as `media` (`kind: image`, `mime: image/png`) on the reply. opencode is the one deep kind whose user attachments the parser shows.
  - The mock model has no image input, so opencode sent an `ERROR: Cannot read "probe-red.png" (this model does not support image input)` text instead of the image.

### TUI
- **Alternate screen and mouse (live, `a/raw.bin`).** `?1049h`, `?1000h ?1002h ?1003h ?1006h`, `?2004h`, `?2027h` and `?2031h`.
- **Process name.** `pane_current_command` is `opencode`.

### Skills
- `~/.config/opencode/commands/<name>.md` works: `opencode run --command wprobe-oc go` sent the command body (live).
- opencode also lists `~/.claude/skills` and `~/.agents/skills` skills to the model, through its skill tool, not as slash commands. That matches the catalog's "commands only" choice.

## Recommended implementation per layer
- **Gate, Status Hooks, Chat Marker route, resume, transcript and skills:** no change. Keep the `┃` gate and its 30 s fallback.
- **herdr backend:** see `herdr-backend.md`. herdr's `agent.prompt` acks while the box is not drawn yet; the existing herdr-side gate in `WaycarSSHTransport.promptAgent` covers it.
