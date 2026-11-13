# oh-my-pi (`omp`): re-verification on 18.10.2

Version tested: **omp 18.10.2** (`omp.sh/install --binary`, linux aarch64) in the harness lab: Ubuntu 24.04, tmux 3.4, herdr 0.9.3, and Waycar Host Tools installed from this worktree. Date: 2026-10-12. The model is the lab mock: OpenAI Chat Completions, provider `mock`, model `mock-model` in `~/.omp/agent/models.yml` with `reasoning: false` and `input: [text]`. This file records only the deltas and confirmations against Waycar's code and AGENTS.md.

Method tags: **live** means observed in the lab on this version; **source** means review of this worktree. Raw captures are in `/tmp/waycar-harness-captures/omp/` on the Mac:

- `hooks/events.jsonl`: every extension event, with `ctx.mode`, the session file and id, `TMUX_PANE` and the process tty, logged by a temporary `-e` capture extension, `cap-ext.ts`.
- `a/` and `b/`: `opts.log`, `screen-*.ansi` and `raw.bin`.
- `transcripts/` and `mock-log.jsonl`.

## Drift and risks
1. **An unknown `--model` loses the launch (live).**
   - **What happens.** `omp --model=mock/probe-model-omp …` printed `Warning: Model "mock/probe-model-omp" not found`, then `Error: No model selected.`
   - **Effect.** The TUI came up with `no-model`, and the positional first message was **never sent** (no mock request). The extension still reported `idle` and the session.
   - **Consequence.** A Chat Mode model typed in Waycar Settings that omp's registry doesn't know leaves the TUI with no model and drops the first message. pi falls back to a custom id instead.
   - **A known model is fine (live, 2026-10-12 17:5x UTC, AppChatLaunch).** `omp --append-system-prompt=<stage>/chat-prompt.md --model=mock/mock-model --thinking=low 'Read and follow <stage>/first-message.md'` (the `provider/id` registered in `~/.omp/agent/models.yml`) sent the first message at once: mock request `model: mock-model`, Chat Prompt marker in `system`, `lastUser` = the pointer. Only an unknown model loses the message.
   - **Waycar's handling.** The launch always passes the configured model (dropping it would discard a valid setting); Settings › Chat Mode's footnote says OMP starts with no model when it doesn't know the one set there. omp shows `Error: No model selected.` on screen.
2. **`--thinking=low` reaches the request only for a reasoning-capable model (live).**
   - With the lab's `mock-model` (`reasoning: false`), the request had no effort field.
   - With a temporary model `probe-reasoning` (`reasoning: true`; added to `models.yml` and then restored byte-exact), it sent `effort: low`.
   - The flag form `--thinking=<level>` is still right.
3. **omp also loads home `~/.agents/skills` (live).**
   - A skill placed only in `~/.agents/skills/wprobe-agents/` was listed in omp's system prompt.
   - `SkillSourceCatalog` for omp lists the project `.agents/skills` and the home `.omp/agent/managed-skills`, but not the home `.agents/skills`. That is a catalog gap.
   - In the same run, a skill in `~/.claude/skills` was **not** listed.

## Confirmed (still matches Waycar's code)

### Status Hooks
The `waycar-agent-state.ts` extension in `~/.omp/agent/extensions` (live, `a/opts.log`):

| When | Pane options |
|---|---|
| `session_start` (`ctx.mode: "tui"`), about 0.3 s after omp starts | `@waycar_status idle`, `@waycar_agent omp`, `@waycar_session` and `@waycar_transcript` set to the session file |
| `agent_start` | `working` |
| `tool_approval_requested` | `blocked`, 1.5 s into the turn, with the Approve/Deny dialog on screen |
| `tool_approval_resolved` (`approved: true`) | `working` |
| `agent_end` | `done` |
| exit | every `@waycar_*` cleared |

- The approval events' payloads are `{type, sessionId, toolName: "bash", toolCallId, approvalMode: "always-ask"}` and `{…, approved}`.
- The default approval mode is yolo, so the WAYCAR_TOOL turn ran without a prompt. `--approval-mode=always-ask` produced the dialog.
- The extension runs in omp's process, on the pane tty (`selfTty pts/22`), so the tty guard passes.

### Chat Mode launch line
The launch argv is built by `LaunchPromptStager` (route `.ompFile`) plus `ChatModeLaunch` (live):

```
omp --append-system-prompt=<stage>/chat-prompt.md --model=mock/mock-model --thinking=low 'Read and follow <stage>/first-message.md'
```

- The file contents are appended to `system` (marker present).
- The first message was sent at once.
- `--thinking` behaves as in drift 2.
- `omp --help` still lists `--append-system-prompt=<value>`, `--model=<value>`, `--thinking=<value>` (adds `auto`), `-r, --resume=<value>` ("by ID prefix, path, or picker if omitted") and `--approval-mode=<always-ask|write|yolo>`.

### Resume
`ClosedSession.resumeArguments` builds `--resume=<session path>` (live). It reopened the session, the extension re-reported idle and the session, and the next turn continued. omp's exit hint is `omp --resume <uuid>`.

### Transcript
- **Location.** `~/.omp/agent/sessions/-work-demo/<ISO>_<uuid>.jsonl`. The directory is the cwd **relative to home**, single-dashed, unlike pi's `--home-…--` form.
- **Parser (live).** `readChat` returned `status: ok`:
  - **By path:** 8 messages, including the tool and approval turn.
  - **By `findByLaunch`** (cwd plus launch time): found.
- **Images.** `@/path.png` in the TUI attaches the image ("Read … (image)"). It is recorded as a `message` with `role: "fileMention"`, `files[].image {type, mimeType: "image/webp", data}`. The parser skips this role: user attachments are not media, by design.

### TUI and input
- **Inline renderer, no mouse (live, `a/raw.bin`).** No `?1049h` was seen, and `alternate_on` stayed 0 throughout, including in the approval dialog. The only mouse modes are resets: `?1000l ?1003l ?1006l`. omp also emits `?2004h`, `?2026`, `?2031h`, `?5522h` and `?9001l`.
- **Input-ready (live).** Pastes from 0.1 s after the login shell spawned were all kept. The generic gate is safe.
- **Process name.** `pane_current_command` is `omp`.

### Skills
`/skill:<name>` expands in the TUI: the request carried `[IMPORTANT: User invoked the "wprobe-omp" skill …]` with the body. `omp -p '/skill:…'` did **not** expand it, which matters only for headless use. A skill under `~/.omp/agent/managed-skills/` is listed.

## Recommended implementation per layer
- **Status Hooks, resume and transcripts:** no change.
- **Chat Mode (AppHarness):** don't pass `--model=` to omp for a model omp doesn't know, or warn: drift 1 loses the first message. `--thinking` is fine.
- **Skills (AppHarness):** add a home `.agents/skills` source for omp (`/skill:` prefix).
- **herdr backend:** see `herdr-backend.md`. Without herdr's omp integration, herdr has no omp screen manifest (AGENTS.md).
