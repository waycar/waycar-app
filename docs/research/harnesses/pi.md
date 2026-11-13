# pi (`pi`): re-verification on 1.1.0

Version tested: **pi 1.1.0** (npm `@earendil-works/pi-coding-agent`, linux aarch64) in the harness lab: Ubuntu 24.04, tmux 3.4, herdr 0.9.3, and Waycar Host Tools installed from this worktree. Date: 2026-10-12. The model is the lab mock: OpenAI Chat Completions at `http://mock:8080/v1`, provider `mock`, model `mock-model` in `~/.pi/agent/models.json`. This file records only the deltas and confirmations against Waycar's code and AGENTS.md.

Method tags: **live** means observed in the lab on this version; **source** means review of this worktree. Raw captures are in `/tmp/waycar-harness-captures/pi/` on the Mac:

- `hooks/events.jsonl`: every extension event, with `ctx.mode`, the session file and id, `TMUX_PANE` and the process tty, logged by a temporary `-e` capture extension, `cap-ext.ts`.
- `a/` and `b/`: `opts.log` (a 0.1 s poll of `@waycar_*`), `screen-*.ansi` and `raw.bin`.
- `transcripts/`: the sessions, the staged prompt files and `readchat.ndjson`.
- `mock-log.jsonl`.

## Drift
None that needs a code change. Two small differences from the other deep kinds:

- **A resume applies the *current* Chat Prompt (live).** `pi --append-system-prompt chat-prompt2.md … --session <path>` sent `CHATMARKER2-pi` on the resumed turn. pi rebuilds its system prompt on every launch; claude and codex keep the original.
- **An unknown `--model` is accepted (live).** `--model mock/probe-model-pi` printed `Model "probe-model-pi" not found for provider "mock". Using custom model id.` and the request went out with `model: probe-model-pi`. omp refuses the same case (see `omp.md`).

## Confirmed (still matches Waycar's code)

### Status Hooks
The `waycar-agent-state.ts` extension in `~/.pi/agent/extensions` (live, `a/opts.log`):

| When | Pane options |
|---|---|
| `session_start` (`ctx.mode: "tui"`), about 0.3 s after pi starts | `@waycar_status idle`, `@waycar_agent pi`, `@waycar_session` and `@waycar_transcript` set to the session file |
| `agent_start` | `working` |
| `agent_settled` (`aborted: false`) | `done` |
| `session_shutdown` (`reason: "quit"`, Ctrl+D) | every `@waycar_*` cleared |

- A launch with a first message goes straight to `working`.
- pi has no approvals, so it has no blocked state. Confirmed: the WAYCAR_TOOL turn ran `bash` with no prompt.
- The extension runs in pi's own process, which owns the pane tty (`selfTty pts/25`), so `waycar-hook`'s tty guard passes.
- Event payloads are in `hooks/events.jsonl`. Among them: `input {text, source:"interactive", images?}`, `tool_call`/`tool_result` (`toolName: "bash"`), and `turn_end` (`message.stopReason`).

### Chat Mode launch line
The launch argv is built by `LaunchPromptStager` (route `.piFile`) plus `ChatModeLaunch` (live):

```
pi --append-system-prompt <stage>/chat-prompt.md --model mock/probe-model-pi --thinking low --session-id <uuid> 'Read and follow <stage>/first-message.md'
```

- **Result (mock log, 16:41:02).**
  - The file contents are appended to `system` (marker present).
  - `model: probe-model-pi`, `effort: low`.
  - The positional first message is sent at once.
  - The session file is `~/.pi/agent/sessions/--home-waycar-work-demo--/<ISO>_<pinned uuid>.jsonl`.
- **Help text.** `pi --help` still documents `--append-system-prompt <text>` ("text or file contents"), `--session <path|id>`, `--session-id <id>`, `--thinking off|minimal|low|medium|high|xhigh|max` and `--model provider/id[:thinking]`.

### Resume
`ClosedSession.resumeArguments` builds `--session <path>` (live). The resumed session continued, and the extension re-reported idle and the session, then working and done. pi's exit line suggests `pi --session <uuid>`; the id form works too (`findById`).

### Transcript
- **Location.** Still `~/.pi/agent/sessions/--<cwd dashed>--/<ISO>_<uuid>.jsonl`.
- **Parser (live).** `chat-transcript.js` `readChat` returned `status: ok`, 8 messages over 4 turns, by `path` and by `id`.
- **Images.**
  - In the TUI, `@/path.png` stays plain text: no attachment.
  - As a launch argument, `pi … @/path.png 'msg'` attaches the image. The `input` event and the transcript's user message carry an `image` block.
  - The lab's `mock-model` declares no image input, so pi sent `(image omitted: model does not support images)`.
  - The parser shows the user text only: user images are not media, by design.

### TUI and input
- **Alternate screen and mouse (live, `a/raw.bin`).** The default `--tui-mode fullscreen` sets `?1049h`, `?1000h ?1002h ?1006h` (no `?1003h`), `?2004h`, `?1004h`, `?2026h` and `?2031h`.
- **tmux warning.** pi warns `tmux extended-keys is off. Modified Enter keys may not work.` It is cosmetic for Waycar, whose paste plus Enter worked.
- **Input-ready (live).** Pastes from 0.1 s after the login shell spawned were all kept (`r0.1 … r7.8`). The generic gate is safe.
- **Process name.** `pane_current_command` is `node` for about 0.1 s, then `pi`.

### Skills
`~/.pi/agent/skills/<name>/SKILL.md` and `~/.agents/skills/<name>/SKILL.md` are both loaded. `/skill:<name>` expanded the body in `pi -p` (mock log). This matches `SkillSourceCatalog` (live).

## Recommended implementation per layer
- **Status Hooks, Chat Mode, resume, transcripts and skills:** no change.
- **Lab (optional):** give the lab's pi model `input: ["text","image"]` if image round trips should be tested end to end.
- **herdr backend:** see `herdr-backend.md`.
