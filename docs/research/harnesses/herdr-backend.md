# herdr 0.9.3 backend sweep: all 16 harnesses

herdr **0.9.3** (release asset, aarch64) in the harness lab, 2026-10-12. Harness versions are from `/etc/harness-lab/versions.txt`: claude 2.1.296, codex 0.162.1, copilot 1.0.95, opencode 1.19.0, cursor-agent 2026.10.01-e373342, pi 1.1.0, agy 1.3.3, gemini 0.63.0, cline 3.0.70, omp 18.10.2, kilo 7.8.8, kiro-cli 2.29.1, devin 3000.11.3, hermes 7cc3fb8 (v0.21.7+158), qwen 0.25.1, grok 1.0.50. The model is the lab mock.

**Method: live in the lab** unless a line says otherwise. `probe.py` (copied with the captures) speaks the JSON API on `~/.config/herdr/herdr.sock`:

- It runs `tab.create` (cwd `~/work/demo`, label `probe-herdr-<kind>`) in a workspace `probe-herdr`, then `agent.start {name, kind, pane_id}`, retrying on `agent_pane_busy` every 500 ms.
- It subscribes to `pane.agent_status_changed` for the pane, plus global `pane.agent_detected` and `pane.exited`.
- It polls `agent.list` every 250 ms; `agent.list` does not reconcile.
- It settles the way `WaycarSSHTransport.scheduleLaunchSettle` does: one `agent.get` at ack + 3.5 s, then every 1 s while the launch is pending, up to + 20 s.
- Then it sends `agent.prompt "hello WAYCAR herdr-<kind>"`, followed by `"run WAYCAR_TOOL now herdr-<kind>"`. If the agent goes `blocked`, it answers with `pane.send_keys ["enter"]`.
- It calls `agent.explain` and `pane.read {source:"visible"}` before the prompt, while working, and after the tool turn.
- Delivery is checked against mock `/_log` entries whose `lastUser` contains the token.

A second pass, the `-ns` runs, repeats start + observe with **no `agent.get` at all**, to see whether promotion needs the reconcile.

**Hosts.** The first runs (16:32–16:48 UTC) used the original Colima VM, shared with 5 other probe agents. That VM crashed at 16:50. Runs from 17:04 used the restarted VM (8 CPU / 16 GB, Main's reconfiguration). Run names in the notes say which run is which.

Raw captures are in `/tmp/waycar-harness-captures/herdr-backend/probe-herdr/` on the Mac:

- `out/<run>/` per run: `summary.json`, `events.jsonl`, `list_changes.jsonl`, `gets.jsonl`, `rpc.jsonl`, `explain.jsonl`, `screen-*.txt` and `mock.jsonl`.
- `integ*-<kind>.txt`: integration install/uninstall output with file-hash diffs.
- `probe-herdr-backup/<target>/`: sha lists and herdr output per integration.

## Matrix (no herdr integration installed)

Times are seconds after the `agent.start` ack. "Clear" is the first time `launch_pending` was observed gone, from either `agent.list` or `agent.get`.

| kind | herdr kind id → argv | start (busy retries) | detected | launch_pending clear (needs agent.get?) | statuses, plain prompt | WAYCAR_TOOL → blocked? | agent_session | prompt delivered (mock) | integration | integration effect |
|---|---|---|---|---|---|---|---|---|---|---|
| claude | `claude` → `claude` | ok (0) | 0.25 | 3.78 (no: `-ns` 3.78) | unknown→idle 3.63→working→done | no (lab runs auto mode); working→done | none | yes, anthropic `claude-cli/2.1.296` | yes | session `{kind:"id", UUID}` at 0.25; status still screen-detected |
| codex | `codex` → `codex` | ok (0) | 0.27 | ≤5.36 old VM; 3.79 `-ns` (no) | idle→working→done | no (ran in sandbox, failed in bwrap) | none | yes, responses `codex-tui/0.162.1` | yes | **hooks-review screen wedges the launch** (pending forever, then unnamed). After "Trust all": no change, still **no session** |
| copilot | `copilot` → `copilot` | ok (0) | 0.25 | 3.79 (no: `-ns` 3.76) | idle→working→done | no (echo ran under "Manual Approval") | none | yes, chat `OpenAI/JS 5.20.1` | yes | session `{kind:"id", UUID}` at 5.0 (first turn) |
| opencode | `opencode` → `opencode` | ok (0) | 0.25 | 3.81 (no: `-ns` 3.76) | idle→working→done | no | none | yes, `opencode/1.19.0`, prompt at 4.8 s; not lost on these runs | yes | session `{kind:"id", "ses_…"}` at 5.0; hook authority once working |
| cursor | `cursor` → `cursor-agent` | ok (0) | 0.25 | 3.62 (no: `-ns` 3.77) | login screen: idle only | n/a (login) | none | n/a; prompt acked, its Enter starts browser sign-in | yes | none visible at login |
| pi | `pi` → `pi` | ok (0) | 3.81 old VM / 0.50 | 6.67 old VM via get; `-ns` 3.77 (no) | idle→working→done | no (no approvals) | none | yes, chat `pi (linux …)` | yes | session `{kind:"path"}` at 0.5. **Hook idle at 0.4–0.65 s: pending never clears without agent.get** |
| agy | `agy`, `antigravity`, `antigravity-cli` → all `agy`, agent `agy` | ok (0) | 0.26 | 3.77 (no: `-ns` 3.77) | idle→working→done | **yes**: blocked (`permission_prompt`), then Enter → working → done | none | yes, gemini `google-genai-sdk/1.73.0` | yes (`antigravity-cli`) | session `{source:"herdr:antigravity_cli", kind:"id", UUID}` at 5.2 |
| gemini | `gemini` → `gemini` | ok (0) | 2.24 old VM / 0.50 | ~3.8 (no: `-ns` 3.77) | idle→working→done | no | none | yes, gemini `GeminiCLI-tui/0.63.0` | **none** | n/a |
| cline | `cline` → `cline`; args `["-i"]` → `cline -i` | ok (0) | 0.25 | 3.50 / 3.77 (no: `-ns` 3.79) | idle→working→done | no ("Auto-approve all") | none | yes, both forms, `ai-sdk/openai-compatible` | **none** | n/a |
| omp | `omp` → `omp` | ok (0) | 0.25 | 3.78 (no: `-ns` 3.79) | **idle only**, never working | no | none | yes, chat `omp/18.10.2` | yes | session `{kind:"path"}` at 0.5–0.76; working/done reported. **Pending never clears without agent.get** |
| kilo | `kilo` → `kilo` | ok (0) | 0.25 | 3.78 (no: `-ns` 3.78) | idle→working→done | no | none | **sometimes lost**: the prompt at ~4.8 s reached the mock in 1 of 2 plain runs and 0 of 2 integration runs (acked `agent_prompted`) | yes | session `ses_…` at the first executed turn; hook authority; 1 of 2 runs stuck `working` |
| kiro | `kiro` → `kiro-cli` (not `kiro-cli chat`) | ok (0) | 0.25 | 3.77 (no: `-ns` 3.78) | login screen: idle; exits on Enter | n/a (login) | none | n/a; prompt acked, Enter → browser fails → kiro-cli exits | **none** | n/a |
| devin | `devin` → `devin` | ok (0) | 0.25 | 3.77 (no: `-ns` 3.79) | login screen: idle only | n/a (login) | none | n/a; prompt acked, Enter picks "Log in with browser" | yes | none visible at login |
| hermes | `hermes` → `hermes` | ok (0) | 2.77 / 2.27 | 6.29 old VM; `-ns` 5.81 (no) | idle→working→done | no | none | yes, chat `OpenAI/Python 2.24.0` | yes | session `{kind:"id", "20261012_164728_8be4bf"}` at 7.5 (first turn) |
| qwen | `qwen` → `qwen` | ok (0) | 0.26 | 3.79 (no: `-ns` 3.78) | idle→working→done | no (Auto mode) | none | yes, chat `QwenCode/0.25.1` | yes | session `{kind:"id", UUID}` at 2.9 (before the first prompt) |
| grok | `grok` → `grok` | ok (0) | 0.25 | 3.77 (no: `-ns` 3.78) | idle→working→done | no with the lab config; yes (`osc_title_blocked`) under `[permission] ask`, Enter → working → done | none | yes, chat `grok-pager/1.0.50` | yes | session `{kind:"id", UUID}` at 0.88 |

`agent_session` values always carry `{source:"herdr:<kind>", agent, kind:"id"|"path", value}`.

`herdr integration status` on 0.9.3 lists 18 targets: pi, omp, claude, codex, copilot, devin, droid, kimi, opencode, kilo, hermes, qodercli, qwen, cursor, mastracode, antigravity-cli, grok and letta (experimental). Of the 16 lab kinds, **gemini, cline and kiro have no integration**. `herdr agent start --kind` accepts 24 kinds: pi, claude, codex, gemini, cursor, devin, agy, cline, omp, mastracode, opencode, copilot, kimi, kiro, droid, amp, grok, hermes, kilo, qodercli, qwen, letta, maki and muse. The API also accepts `antigravity` and `antigravity-cli`, both normalized to `agy`.

## Cross-kind findings

1. **Out of the box, 0.9.3 promotes a launch by itself.**
   - Source of these facts: live, 16 of 16 `-ns` runs at 17:06–17:08, plus every settle run.
   - The status stays `unknown` until about +3.6 s. Then `pane.agent_status_changed → idle` arrives and `launch_pending` disappears from `agent.list` at 3.76–3.79 s (hermes: 5.8 s), with no `agent.get` sent.
   - The cleared field is **absent**, not `false`. `interactive_ready: true` appears at the same time.
   - Waycar's 3.5 s `agent.get` usually still sees `launch_pending: true` with status `unknown`, and the next one sees it cleared.
   - **[INFERENCE]** 0.9.3 publishes the first screen status only after its 3 s settle, so the first status mutation is itself the promoting reconcile. Not checked against source.
2. **Hook-authority integrations still need the reconcile (live, 17:08–17:10).**
   - With the pi or omp integration installed, the hook reports `idle` at 0.4–0.72 s, before the settle.
   - Without `agent.get`, `launch_pending` was still `true` at +20 s in both `-ns` runs (`pi-integns`, `omp-integns`).
   - With Waycar's settle, the first `agent.get` at 3.50 s cleared it at once.
   - This is the #17 shape, still present on 0.9.3. Keep `scheduleLaunchSettle`.
3. **Startup dialogs wedge `launch_pending`.**
   - **claude Settings Warning (run `claude`, 16:32).** Another probe's temporary `hooks.StopCancelled` entry in `~/.claude/settings.json` made claude open "Settings Warning … 1. Continue". herdr reported `blocked` from 3.62 s with `launch_pending: true` through every settle `agent.get`. The 30 s deadline does not apply to a blocked launch. `agent.prompt` answered `agent_blocked`. A `pane.send_keys ["enter"]` at 64.3 s gave `idle` and cleared pending at 64.6 s.
   - **codex hooks review (run `codex-integ`).** Status `unknown` with `launch_pending: true`. After 30 s the agent lost its name: `agent.prompt` gave `agent_not_ready` ("agent w1:pR is not an active named agent"), and `agent.get` at 130 s had no `name` and no `launch_pending`.
4. **`agent_pane_busy` never occurred** (0 retries in about 60 starts on fresh tabs). `tab.create` → `agent.start` came about 0.3 s apart.
5. **No kind reports `agent_session` without its integration.** That includes claude and omp; AGENTS.md's 0.9.1 note says they report "out of the box", which presumably meant with the integration installed. Every session shown in the matrix appeared only with the integration.
6. **Login-only kinds look ready to herdr.** For cursor, kiro and devin:
   - herdr reports `idle`, `interactive_ready: true` and a cleared `launch_pending` at about 3.6–3.8 s, and the state never changes (observed for 45 s; `agent.explain` gives `default_known_agent_idle_fallback`).
   - `agent.prompt` answers `agent_prompted`, and its typed text plus Enter drives the login UI.
   - Waycar cannot tell a login screen from an idle agent through herdr status.

## Per-kind notes

- **claude.**
  - `explain`: idle comes from `live_prompt_box` and working from `osc_title_working`.
  - With the integration (`claude-integ`), the session id appears at 0.25 s, and status is still screen-derived (same rules).
  - Install writes `~/.claude/hooks/herdr-agent-state.sh` and merges hooks into `~/.claude/settings.json`. After uninstall, settings.json was byte-identical to the pre-install copy.
  - ProbeDeepFiveAndHerdr found that claude runs hooks with no tty. With herdr's hook installed, the session was still reported, so the hook does report under herdr.
- **codex.**
  - Install writes `~/.codex/herdr-agent-state.sh` and edits `~/.codex/hooks.json`. It reports `config.toml` as "ensured", but the file stayed unchanged.
  - Codex 0.162.1 then shows "Hooks need review" (1. Review / 2. Trust all / 3. Continue without trusting) on every launch until the hooks are trusted; see finding 3.
  - `pane.send_keys ["down","enter"]` at 3 s ("Trust all") let the launch promote normally (`codex-integ2`). Codex then wrote `[hooks.state."…hooks.json:session_start:1:0"] trusted_hash` into `config.toml`. Still **no `agent_session`**.
  - Uninstall rewrites `hooks.json` with sorted keys and no trailing newline, so the content matches but the bytes do not. Both `hooks.json` and `config.toml` were restored byte-exact from the backup.
  - Status rules: `osc_title_idle` / `osc_title_working`.
- **copilot.**
  - The footer says "Manual Approval", yet the mock's `echo waycar-tool-ok` ran without a prompt.
  - Install writes `~/.copilot/hooks/herdr-agent-state.sh` and **creates** `~/.copilot/settings.json`. Uninstall leaves `{"hooks":{}}`; I deleted it. (The lab now ships `settings.json` with `"autoUpdate": false`, copilot.md §14; after an uninstall, keep that key.)
  - **Text-only turns go unreported** (live re-test 2026-10-12, copilot 1.0.95 and 1.0.96, 100 ms sampling). Until the model's first output, copilot's footer reads `◉ Working esc edit prompt`, and the copilot manifest (`2026.08.29.1`) has no rule for it, so herdr reads idle. 10 of 12 mock text turns stayed idle → idle, with no working and no done, a 15 s turn among them; on the other 2 herdr caught the ≤ 200 ms `esc interrupt` frame at the end. Tool turns read working → done. The matrix's `idle→working→done` for copilot fits one such caught frame [INFERENCE: that sweep turn was not re-examined]. Adding `esc edit prompt` to `working_cancel_hint` fixes it (`agent explain` with a local override). Details and Waycar's decision: copilot.md §11.
- **opencode.**
  - Run `opencode-r2` (16:47, loaded old VM; prompt at 4.8 s) and run `opencode-integ2` (17:04, 8-CPU VM; prompt at 4.8 s) both delivered. The input-box loss from AGENTS.md (11–42 s on a 2-vCPU host) did not reproduce here.
  - Install writes `plugins/herdr-agent-state.js`, `herdr-tui-session.js` and `tui.jsonc` (plugin entry). `cli.json` and `herdr-opencode/tui.js` also changed during the install window, but herdr's output names neither.
  - After the 16:50 VM crash interrupted a window, uninstall left `tui.jsonc` and `cli.json` as `{}`. Neither existed before (ProbeDeepFiveAndHerdr confirmed), so both were deleted.
  - With the integration, `explain` gives `full_lifecycle_hook_authority` while working.
- **cursor.**
  - herdr types `cursor-agent`. The screen shows "Cursor Agent v2026.10.01-e373342 / Press any key to log in...".
  - After the prompt: "Signing in / If your browser didn't open, click this link …" with a `cursor.com/loginDeepControl` URL.
  - Install writes `~/.cursor/herdr-agent-state.sh` and **creates** `~/.cursor/hooks.json`. Uninstall leaves `{"hooks":{},"version":1}`; I deleted it.
- **pi.**
  - Late detection (3.8 s) and a late clear (6.7 s, via `agent.get`) happened on the loaded old VM. On the 8-CPU VM the numbers were 0.5 s and 3.77 s.
  - Install writes only `~/.pi/agent/extensions/herdr-agent-state.ts`, and uninstall removes it cleanly.
  - With the integration: session path `~/.pi/agent/sessions/--home-waycar-work-demo--/<ts>_<uuid>.jsonl`.
- **agy.**
  - Every launch reached `blocked` on the tool call through screen rule `permission_prompt`. Enter approved it.
  - Install writes `~/.gemini/config/hooks/herdr-agent-state.sh` and merges into `~/.gemini/config/hooks.json`. After uninstall, `hooks.json` was byte-identical; the empty `hooks/` directory was left behind.
- **gemini.** Detection at 2.24 s on the old VM (0.5 s on the new one). Status is screen-detected: `esc_cancel_working`, idle by fallback.
- **cline.**
  - `kind: "cline"` with `args: ["-i"]` types `cline -i`. Plain `cline` also worked: it opens the same interactive UI.
  - Rules: `composer_idle` / `active_turn`. No integration exists.
- **omp.**
  - Without the integration, omp reads `idle` for whole turns (`default_known_agent_idle_fallback`, matching AGENTS.md on 0.9.1), and prompts are still delivered.
  - With it: `working` and `done` are hook-driven (`full_lifecycle_hook_authority`), the session is a path, and the pending wedge from finding 2 applies.
  - Install writes only `~/.omp/agent/extensions/herdr-omp-agent-state.ts`, and uninstall is clean.
- **kilo.**
  - **Input loss.** `agent.prompt` at about 4.8 s after start (≈1 s after promotion) was acked and lost in runs `kilo-r2`, `kilo-integ` and `kilo-integ2`: the mock got no `hello` entry. It was delivered in run `kilo`. In all four runs `pane.read` at prompt time was still blank, so a blank screen does not predict the loss.
  - Same class as opencode's input-box gate; Waycar's gate covers opencode only.
  - **Stuck status (`kilo-integ`).** With the integration, status stayed `working` after the turn finished (screen idle, final `agent.get` `working`), with `explain` `full_lifecycle_hook_authority`. `kilo-integ2` reported done correctly.
  - Install writes `~/.config/kilo/plugin/herdr-agent-state.js`; uninstall is clean.
- **kiro.**
  - herdr launches `kiro-cli`, not `kiro-cli chat`; both open the sign-in prompt.
  - The prompt's Enter starts "Opening browser… Failed to open browser … error: No such file or directory". kiro-cli exits, then `pane_agent_detected {released:true, final_status:"idle"}` arrives and status turns `unknown` with no agent.
- **devin.**
  - The screen shows the "How would you like to log in?" menu. The prompt's Enter chose "Log in with browser" and gave "Waiting for login in browser…".
  - Install writes `~/.config/devin/herdr-agent-state.sh` and merges hooks into `config.json`. Uninstall leaves `"hooks": {}`, so `config.json` was restored byte-exact.
- **hermes.**
  - Slowest detection, 2.3–2.8 s, and clear at 5.8–6.3 s.
  - Install writes `~/.hermes/plugins/herdr-agent-state/` and sets `plugins.enabled` in `~/.hermes/config.yaml`. Uninstall leaves a stray `enabled:` key, so the file was restored byte-exact; `plugins/` stays as an empty directory.
  - The `blocked` in `hermes-integ` (`dangerous_command_approval`) came from another probe's temporary approval rule, not from herdr.
- **qwen.**
  - Install writes `~/.qwen/hooks/herdr-agent-session.sh` (session only) and merges into `~/.qwen/settings.json`. Uninstall re-serializes the whole file, so it was restored byte-exact.
- **grok.**
  - Run `grok` (16:36) had another probe's `[permission] ask` in `~/.grok/config.toml`, which produced `blocked` through `osc_title_blocked`. Enter approved it.
  - Install writes `~/.grok/hooks/herdr-agent-state.sh` and `~/.grok/hooks/herdr.json`. Uninstall leaves the empty `hooks/` directory; I removed it.

## State at the end

- **Integrations.** `herdr integration status` is back to all 18 `not installed`.
- **Files.** Every file the installs touched was diffed against a pre-install hash list and is byte-exact again. Two cases had no pre-install snapshot:
  - omp and opencode's first windows lost theirs in the crash; omp was redone at 17:05/17:08 with clean diffs.
  - opencode's leftover `{}` files were deleted on the owner's word.
- **Tabs.** Workspace `probe-herdr` (w1) and all its tabs are closed.
