# Devin CLI (`devin`)

Version tested: **devin 3000.11.3 (9c803229faa4)**, linux aarch64. It is a single 175 MB ELF installed by `cli.devin.ai/install.sh` at `~/.local/share/devin/cli/_versions/3000.11.3/bin/devin`, with `~/.local/bin/devin` pointing to it. Tested in the harness lab (Ubuntu 24.04, tmux 3.4, herdr 0.9.3) on 2026-10-12.

**Account-only.** Devin has no BYOK or custom endpoint, so the lab never gets past sign-in. Everything after the login screen is **UNVERIFIED live**: it comes from docs, from `devin --help`, or from reviewing strings in the binary.

Method tags:
- **live**: observed in the lab.
- **docs**: `https://docs.devin.ai/cli/extensibility/hooks/overview.md`, `…/hooks/lifecycle-hooks.md`, `…/reference/configuration/read-config-from.md`.
- **source**: `strings` on the binary.

Captures are in `/tmp/waycar-harness-captures/devin/` on the Mac: first screen, token-flow screen and raw pty bytes.

## The Claude-hook bleed

### Devin runs Claude hooks (docs)

Devin reads hooks from these files, all in Claude's format:
- `~/.claude/settings.json`, `~/.claude/settings.local.json` and `~/.claude.json`
- project `.claude/settings*.json`

This happens while `read_config_from.claude` is true, which is the default. Turn it off in `~/.config/devin/config.json` with `{"read_config_from": {"claude": false}}`.

Devin's events are SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, **PermissionRequest**, Stop, PostCompaction and SessionEnd. It has no Notification event.

### Effect on Waycar [INFERENCE from the docs]

- **Status writes.** Waycar's claude entries would mark a devin pane:
  - `working` on UserPromptSubmit
  - `blocked` on PermissionRequest
  - `working-if-blocked` on PostToolUse
  - `done` on Stop
  - `release` on SessionEnd
- **Session.** `hook-session.js claude` would write `@waycar_agent claude` and `@waycar_session <devin session_id>`.
- **Wrong label.** The statuses would be roughly right, but the agent label and the resume command (`claude --resume <devin-id>`) would be wrong.
- **PreToolUse.** Devin's matchers are regexes; whether the look-ahead in Waycar's PreToolUse matcher compiles there is unknown.

### Pre-login and discriminators

- **No hooks fire before login (live).** I put capture hooks for all 8 devin events in `~/.config/devin/config.json` (under `"hooks"`) and for 11 events in `~/.claude/settings.json`. Then I launched `devin`, chose option 2 (paste a token), and quit. Nothing fired.
- **Discriminators.**
  - Docs: `DEVIN_PROJECT_DIR` is set for every hook.
  - Source: the binary also holds `CLAUDE_PROJECT_DIR` next to `CLAUDE_PLUGIN_ROOT`, so `CLAUDE_PROJECT_DIR` is not a discriminator.
  - The payload carries `session_id` and `prompt_id`. Claude 2.1.296 also sends `prompt_id`, so `prompt_id` is not a discriminator either.
  - The live hook env and process tree are UNVERIFIED, because they need a logged-in run.

## Probe answers

1. **Hook config and events (docs)**
   - **Hook files.**
     - Project: `.devin/hooks.v1.json` (the whole file is the hooks object), or the `"hooks"` key in `.devin/config.json` / `.devin/config.local.json`.
     - User: `~/.config/devin/config.json` `"hooks"`.
     - Claude files as above.
   - **Format.** Claude's: `{"<Event>": [{"matcher", "hooks": [{"type": "command"|"prompt", "command", "timeout"}]}]}`.
   - **Events.** The 8 listed above.
   - **Payload.**
     - Every event: `hook_event_name`, `session_id`, and `prompt_id` (absent before the first prompt).
     - PreToolUse, PostToolUse, PermissionRequest: `tool_name`, `tool_input`. PostToolUse also has `tool_response`.
     - Other events: SessionStart `source`, SessionEnd `reason`, Stop `stop_hook_active`, UserPromptSubmit `prompt`.
     - No `transcript_path` field is documented.
   - **Source.** The binary also mentions a `.windsurf/hooks.json` migration and cloud dashboard hooks.
2. **tmux pane identity.** UNVERIFIED (needs login).
3. **Executable (live).** `devin`. Both `ps` comm and `pane_current_command` read `devin`, which equals the kind id.
4. **Transcript.**
   - No transcript file location is documented. In the lab, `~/.local/share/devin/cli/` holds only `logs/` and `installation_id` before login (live).
   - **Export flag (docs, `devin --help`, live).** `--export [<PATH>]`: "Export conversation to a file. Exports after each turn. Uses a default path if no path is provided." This is an opencode-style substitute: Waycar could launch with `--export <known path>` and parse that file. Format UNVERIFIED.
   - **Session list (live).** `devin list --format json` works logged out and printed `[]`. herdr's devin integration uses it to look up the session id by `working_directory`.
5. **Chat Prompt route.**
   - No system-prompt flag exists (`--help`, live).
   - Candidate routes:
     - **Rules.** `devin rules paths` (live) lists `.windsurf/rules/*.md` (always-on) and `.cursor/rules/*.md` (conditional). The docs also list `AGENTS.md`.
     - **SessionStart hook output** `hookSpecificOutput.additionalContext` (docs).
     - **`--config <PATH>`** (live `--help`) overrides the user config file, which carries hooks. A per-launch config could add a SessionStart hook that injects the Chat Prompt.
   - All UNVERIFIED.
6. **First message (live `--help`).** `devin [OPTIONS] [PATH]... [-- <PROMPT>...]`: the prompt goes after `--`. `--prompt-file <FILE>` loads the initial prompt from a file and also starts an interactive session.
7. **Resume (live `--help`).**
   - `-r, --resume [<SESSION_ID>]`: omit the id to pick interactively.
   - `-c, --continue`.
   - Waycar's `ClosedSession` `.devin → ["--resume", id]` matches.
8. **Model and effort (live `--help`).**
   - `--model <MODEL>` (env `DEVIN_MODEL`). Combined with `-r`/`-c`, it switches the resumed conversation's model.
   - No effort flag; per the market research, reasoning level is Alt+T inside a session.
   - `--permission-mode` (env `DEVIN_PERMISSION_MODE`, default `auto`).
9. **Skills (live `devin skills paths`).**
   - User: `~/.config/devin/skills/<name>/SKILL.md`, `~/.config/cognition/skills/<name>/SKILL.md`, `~/.agents/skills/<name>/SKILL.md`.
   - Project: `.devin/skills/`, `.cognition/skills/`, `.agents/skills/`.
   - Imported when the matching config import is on (docs): `.windsurf/skills/`, `.claude/skills/**/SKILL.md`, `.claude/commands/**/*.md`, `.github/skills/`, `~/.copilot/skills/`.
   - Waycar's `AgentSkill.swift` entry lacks the `.cognition` roots.
10. **Alt screen and mouse (live, login screens only).**
    - Inline: no `?1049h`, no mouse modes.
    - Sets `?2004h` (bracketed paste) and `?2026h` (synchronized output); tmux reported `alternate_on=0`, `mouse_any_flag=0`.
    - The chat UI is UNVERIFIED. Per the market research, `/mouse` toggles mouse capture.
11. **herdr tier.**
    - Live: herdr 0.9.3 `integration status` lists `devin: … (~/.config/devin/herdr-agent-state.sh)`.
    - Source review: the script reports the session id from `session_id`. It falls back to `devin list --format json` matched by `DEVIN_PROJECT_DIR`, except on UserPromptSubmit and SessionStart `source=startup`.
12. **Login (live).** The first screen reads:
    ```
    Welcome to Devin CLI!
    Devin CLI v3000.11.3
    How would you like to log in?
    ❭ 1 Log in with browser
      2 Paste a token manually
      3 Log in with Windsurf for Enterprise
    ↑↓ select · ↵ confirm · esc cancel
    ```
    Option 2 shows `Visit https://app.devin.ai/auth/cli/continue?… to sign in, then copy the code and paste it below.`, then `Code:` / `❭ Paste the code from the sign-in page` / `↵ submit · esc cancel`.
    Detection markers (lab E2E capture 2026-10-12): the full menu has 13 non-empty rows (four logo rows, three option descriptions), so `Welcome to Devin CLI!` falls outside a 12-row bottom region; the menu is known by `How would you like to log in?` plus `For SSH or remote sessions without browser access` (option rows start with `❭` when selected). After "Log in with browser" the screen is `Welcome to Devin CLI!` / `⠀⠇ Waiting for login in browser... · 2s` (braille-blank spinner) / `Press Enter to paste a token manually instead`.
13. **No daemon.** [INFERENCE] A single local process; `devin acp` and `--cloud` are separate modes. Not verified live.

## Recommended implementation per layer

- **tmux Status Hooks.** Add `devin` with a hook file in `~/.config/devin/config.json` `"hooks"` (a JSON merge like the claude one) using the same event map as claude:
  - SessionStart → session
  - UserPromptSubmit → `working`
  - PreToolUse → `working-if-active`
  - PermissionRequest → `blocked`
  - PostToolUse → `working-if-blocked`
  - Stop → `done`
  - SessionEnd → `release`

  Before shipping, verify these live with an account: the tty and process tree, the SessionStart `source` values, and whether Stop also fires at session end.
- **Claude-hook bleed.** Skip the claude hook when `DEVIN_PROJECT_DIR` is set (see [grok.md, Bleed fix](grok.md#bleed-fix-recommendation-for-pluginhooks)). With that in place, Waycar's own devin entries own the pane.
- **Chat Mode / transcript.** The `--export <path>` flag is the most promising transcript route (format unknown). For the Chat Prompt, try a per-launch `--config` that adds a SessionStart `additionalContext` hook. Both need an account to verify.
- **Resume.** Keep `--resume <id>`.
- **Skills.** Add `.cognition/skills` and `~/.config/cognition/skills`.
- **Screen detection.** Classify the menu (`How would you like to log in?` + `For SSH or remote sessions without browser access`), the browser wait (`Welcome to Devin CLI!` + `Press Enter to paste a token manually instead`) and the token prompt as sign-in.
- **Prompt gate, alt screen, message jump.** Unverifiable without login; keep the generic gate.
