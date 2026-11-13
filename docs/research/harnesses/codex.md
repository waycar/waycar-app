# Codex CLI (`codex`): re-verification on 0.162.1

Version tested: **codex-cli 0.162.1** (npm `@openai/codex`, linux aarch64) in the harness lab: Ubuntu 24.04, tmux 3.4, herdr 0.9.3, and Waycar Host Tools installed from this worktree. Date: 2026-10-12. The model is the lab mock: OpenAI Responses at `http://mock:8080/v1`, provider `mock` in `~/.codex/config.toml`. This file records only what changed since the AGENTS.md facts (Codex 0.159.2 and older), plus confirmation of what still holds.

Method tags: **live** means observed in the lab on this version; **source** means review of this worktree. Raw captures are in `/tmp/waycar-harness-captures/codex/` on the Mac:

- `hooks/`: stdin, env and parent tty for every event.
- `a/`: a capture run with a copied `CODEX_HOME` (Waycar's hooks plus capture hooks, `--dangerously-bypass-hook-trust`). `home-config/` holds that home's `hooks.json` and `config.toml`.
- `b/`: a Chat Mode run against the real `~/.codex`.
- `transcripts/`: the rollouts and `readchat.ndjson`.
- `mock-log.jsonl`.

## Drift (action needed)

1. **No mouse tracking any more (live, `a/raw.bin` and `b/raw.bin`).**
   - Codex 0.162.1 sets `?1049h` (alternate screen), `?1007h` (alternate scroll: the terminal turns the wheel into arrow keys), `?2004h`, `?1004h` and `?2026h`. It sets **none of `?1000/1002/1003/1006h`**.
   - AGENTS.md ("Claude Code, codex, and grok all set `?1049h` plus `?1000/1002/1003/1006h`") is stale for codex.
   - **Consequence (source).** `TerminalScrollControl.canScrollRemoteContent` gates on mouse reporting, so the scroll and message-jump chrome stay hidden on a codex attach. SGR wheel reports would not scroll it anyway. Under `?1007` a wheel becomes Up/Down keys, which in codex move through the composer history, not the transcript (not tested).
2. **Codex's blocked state could not be produced (live; UNVERIFIED as a whole).**
   - **The flag no longer offers it.** `-a/--ask-for-approval` accepts only `on-request|never`. `-c approval_policy="untrusted"` fails at startup: `approval_policy = "untrusted" is no longer supported; remove this setting`.
   - **The tool runs unapproved.** With `on-request` (the default) and `on-failure`, the mock's `exec_command {"cmd":"echo waycar-tool-ok"}` ran inside the sandbox without an approval. In this container the bundled bubblewrap cannot create namespaces, the tool failed (`bwrap: No permissions…`), and codex did not offer to escalate.
   - **The mock cannot ask either.** It fills only `cmd`, never a `sandbox_permissions`/`justification` escalation request, so a model-requested approval cannot be scripted.
   - **Result.** PermissionRequest → `blocked` and the `classifyCodex` blocked strings stay unverified on 0.162.1. To verify, the mock would need to send an escalation argument, or the lab would need a working bubblewrap.
3. **A resumed session does not take a new Codex profile's `developer_instructions` (live).**
   - **What was run.** `codex --no-daemon -p <new profile> … resume <id>`, where the new profile holds `CHATMARKER2-codex`.
   - **Result.** The resumed request carried the **original** developer message (`CHATMARKER-codex`, from the session history) and not the new one.
   - **Consequence.** The Chat Prompt survives a resume, but an edited one does not apply. This matches claude.

## Confirmed (still matches Waycar's code)

### Status Hooks
Live; `~/.codex/hooks.json` is trusted, and `a/opts.log` and `b/opts.log` record the pane options.

- **SessionStart fires at the first turn**, not at launch (T19 still holds). Its `source` is `startup`, or `resume` after `codex resume`.
  - It sets `@waycar_agent codex`, `@waycar_session <uuid>` and `@waycar_transcript <rollout path>`.
  - So a codex closed before its first prompt has no session.
- **Status writes.**
  - UserPromptSubmit sets working.
  - PreToolUse and PostToolUse fire as expected (`tool_name: "Bash"`, `tool_input.command`).
  - Stop sets done; it carries `last_assistant_message` and `stop_hook_active`.
  - SessionEnd (`reason: "other"`) releases the pane. All `@waycar_*` options were cleared.
- **Pane identity.** With `--no-daemon`, every hook's parent is `codex` on the pane's tty (`ppid_comm=codex ppid_tty=pts/7`, pane `/dev/pts/7`), so the tty guard passes. `TMUX_PANE` is correct.
- **Payload fields.** `session_id`, `turn_id` (turn events), `transcript_path`, `cwd`, `hook_event_name`, `model`, `permission_mode`, plus per-event fields.
- **`--no-daemon`.** It is still listed in `codex --help` ("Run without the shared background server"). It also works before a subcommand: `codex --no-daemon … resume <id>`.
- **Hook trust.** `--dangerously-bypass-hook-trust` exists. Waycar does not use it; the lab pre-trusts the hooks in `config.toml` `[hooks.state]`.

### Chat Mode launch line
The launch argv is built by `LaunchPromptStager` (route `.codexProfile`) plus `ChatModeLaunch`, with `--no-daemon` from `TmuxTransport.agentCommandLine` (live):

```
codex --no-daemon -p waycar-<uuid> -m probe-model-codex -c 'model_reasoning_effort="low"' -- 'Read and follow <stage>/first-message.md'
```

- **Capability probe.** `codex --help` still contains `.config.toml on top of the base user config` (the `-p, --profile <CONFIG_PROFILE_V2>` help).
- **Profile file.** The profile is `~/.codex/waycar-<uuid>.config.toml` holding `developer_instructions = "…"`.
- **Result (mock log, 16:35:46).**
  - The marker reaches the request. The mock folds the developer message into `system`, after the base instructions.
  - `model: probe-model-codex`, `effort: low`, `reasoning: {effort: low, summary: auto}`.
  - The first user message is the pointer.
  - The footer shows `probe-model-codex low`.
- **Resume.** `codex --no-daemon -p … -m … -c … resume <id>` reopened the full history (live).

### Transcript
- **Location.** Still `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`.
- **New record kinds (live).** Rollouts now also carry `ordinal`, `metadata`, `event_msg/thread_settings_applied`, `token_usage_record`, `world_state` and `event_msg/item_completed` (`UserMessage` and `AgentMessage` items).
- **Parser (live).** `chat-transcript.js` `readChat` returned `status: ok`:
  - **By id**, for both a capture-home rollout (`CODEX_HOME` override) and a real-home rollout: 4 turns plus a resumed turn, all user and assistant messages, no duplicates.
  - **By `findByLaunch`** (cwd `~/work/demo`, launched 16:35:45Z): found the Chat Mode rollout `rollout-2026-10-12T16-35-46-01a130f8-….jsonl`.
- **User-attached images.** A pasted image path becomes `[Image #1]`, and the user `response_item` carries an `input_image` data URL. The parser shows only the prompt text: user-attached images are not media, by design (`codexImages` covers tool output and view_image only).

### TUI and input
- **Input-ready (live).** Pastes typed from 0.1 s after the login shell spawned were all kept, typed ahead in the tty: `r0.1 … r7.8` arrived intact. The generic 1.5 s-after-detection gate is safe.
- **Process name.** `pane_current_command` is `node` (the npm wrapper). AGENTS.md T11 says "the name for codex"; with the npm install it is `node`. `TmuxAgentDetection` unwraps interpreters (source), and the `@waycar_agent` hook covers the rest.

### Skills
`~/.codex/skills/<name>/SKILL.md` and `~/.agents/skills/<name>/SKILL.md` are both loaded, and `$name` expands the body: `codex exec '$wprobe-codex $wprobe-agents go'` (mock log). This matches `SkillSourceCatalog` (live).

## Recommended implementation per layer
- **Status Hooks:** no change. The blocked mapping (PermissionRequest) is unverified on 0.162.1; see drift 2.
- **App: message jump and scroll:** treat codex 0.162.1 as alternate screen without mouse (`?1007`). The current gating already hides the scroll chrome; just don't promise wheel scroll for codex in docs or UI copy.
- **Chat Mode:** no change. An edited Chat Prompt does not reach a resumed session (drift 3).
- **Transcripts and parser:** no change; tolerate the new record kinds (it already does).
- **Lab (HarnessLab):** add an escalation-requesting tool call to the mock (for example `sandbox_permissions: "require_escalated"` for codex's `exec_command`) so codex's blocked state can be verified.
- **herdr backend:** see `herdr-backend.md`.
