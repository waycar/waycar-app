# waycar

A [herdr plugin](https://herdr.dev/docs/plugins/) that renders a **Pairing Code**
QR so the Waycar app can add this machine as a Host by scanning it
(ADR 0007). The `pair` action opens a popup pane: confirm which of the
machine's addresses go into the code, then scan the QR with the app.

The Pairing Code carries a single-use **Bootstrap Key**: the app connects with
it once, submits its Device Key public line, and the plugin's Enrollment
entrypoint appends that key to `authorized_keys` automatically. See
[Bootstrap Key lifecycle](#bootstrap-key-lifecycle).

The plugin also delivers **Agent Notifications** (ADR 0008) and per-Host
**Live Activity** updates: two independent `[[events]]` entries on
`pane.agent_status_changed`. herdr runs every matching hook for the same
event (verified on 0.8.0). The notify hook pushes encrypted Blocked/Done
alerts; the activity hook pushes the Host's eligible-agent snapshot to any
device that has registered a Live Activity token, and starts the activity
through push-to-start when the app is not running one. See
[Notify hook](#notify-hook) and [Activity hook](#activity-hook).

Starting with plugin 0.4.0, a startup hook also exports the Host's herdr
sidebar layout for Waycar. Both event hooks refresh it before their notification
gates. See [Sidebar layout snapshot (v1)](#sidebar-layout-snapshot-v1).

## Requirements

- herdr >= 0.7.5, tmux >= 3.2, Zellij >= 0.46.0, or herdr-core (`herdr-core --version` prints `hc <version>`)
- An OpenSSH server on this machine (the code pins its host key fingerprint)
- `curl` and `tar`, for `install.sh`

That is all. The Host Tools are a static native binary (Linux x86_64 and
ARM64, macOS Apple Silicon and Intel; no libc floor, Alpine works). A Host
needs no Node.js, npm, nvm, Homebrew or CA bundle. The agents on the Host may
themselves be Node programs; that is theirs, not Waycar's.

## Install

On a new machine, first install the requirements above and make sure the
OpenSSH server is running. On macOS, enable **System Settings > General >
Sharing > Remote Login**. If `/etc/ssh` still has no `ssh_host_*_key.pub`
files, generate them:

```bash
sudo ssh-keygen -A
```

Confirm the command-line requirements:

```bash
herdr --version   # 0.7.5 or newer, or: tmux -V (3.2 or newer), or: herdr-core --version
curl --version   # and tar: the installer needs both
```

Install the plugin (rerun to update):

```bash
curl -fsSL https://waycar.dev/install.sh | sh
```

The script downloads the package every waycar.dev deploy builds from this
directory for this computer's platform (`scripts/package-plugin.sh` writes one
tarball per target: Linux and macOS, x86_64 and arm64; `bin/waycar` in it is
the native Rust binary built by `scripts/build-plugin-binaries.sh`, with no
`[[build]]` step), verifies its SHA-256, unpacks it to
`~/.local/share/waycar/plugin`, and `herdr plugin link`s it, replacing any other
`waycar` install. Each new plugin version is also
published as a `plugin-v<version>` GitHub release
(`.github/workflows/plugin-release.yml`). Verify that the plugin is installed and
enabled:

```bash
herdr plugin list --plugin waycar
herdr plugin config-dir waycar
```

Open the Pairing Code popup:

```bash
herdr plugin action invoke waycar.pair
```

The QR, and any reason pairing cannot start, appear in a Herdr popup window,
not in the terminal that ran invoke. When the popup is too small for the QR
(for example with a zoomed-in terminal font), it switches to a denser QR
drawn with sextant characters. When even that does not fit, it shows no QR
and asks you to zoom out or enlarge the window. It redraws on resize with the
same code. To draw the same QR in a plain terminal instead, run `bin/waycar
pair` — that is the route the install script's pairing offer takes, and it
works on a herdr Host too: `waycar pair` resolves the plugin's config and
state dirs from herdr.

Scan the code in Waycar to add this machine as a Host, or press `c` on the
QR screen to copy the Pairing Code and paste it in the app (macOS uses
`pbcopy`; elsewhere the code is printed for manual selection). Then open the
Waycar settings, enable Agent Notifications, grant the iOS notification
permission, and enable Notifications for this Host. Leave **Custom Push
Relay** empty to use the production endpoint at
`https://waycar-apns.otreva.com`.

To update, run the same install command again. To inspect notification or pairing failures:

```bash
herdr plugin log list --plugin waycar --limit 20
```

For local development, link the working tree instead. Build it first because
`plugin link` does not run build commands:

```bash
cd plugin && cargo build --release
cp target/release/waycar bin/waycar     # the package ships the same binary here; do not commit it
herdr plugin link "$(pwd)"
herdr plugin action invoke waycar.pair   # popup in the herdr window
bin/waycar pair                          # QR in this terminal
```

The checklist: arrows or `j`/`k` move, space toggles, `a` toggles all,
enter mints a Bootstrap Key and renders the QR, `q`/escape closes (revoking
the key). On the QR screen, `c` copies the Pairing Code. On the full-size QR
any other key closes; on the compact (sextant) QR and on screens without a
QR only `q`, escape or Ctrl-C close, so a zoom shortcut cannot end pairing.
When the code expires, enter generates a fresh one. Once a device
enrolls, the QR is replaced by a success screen showing the enrolled Device
Key's fingerprint and label; press `r` there to revoke that key (removing its
`authorized_keys` line), or any other key to close.

The checklist starts with two addresses checked: the home network address (the
private IPv4 on the primary interface, `en0` or `eth0`, else the first private
IPv4) and the Tailscale IPv4 (`100.64.0.0/10`) when the Host has one, so the
code carries an address for home and one for the tailnet; which of them the
app saves and dials is the app's call. Other IPv6 addresses stay unchecked to
keep the QR small, and a Host with neither a private nor a Tailscale IPv4
starts with its best-ranked likely address (an IPv6 ULA) checked.

Known limitation: the advertised SSH port is currently fixed at 22.

### Versioning

The Waycar app reads the installed plugin's version on each Host (herdr's
plugin list, or the Host Tools package for tmux) and asks for an update when
it is older than the app's `WaycarPluginRequirement.minimumVersion`
(`Sources/Waycar/Transport/WaycarPlugin.swift`). A version must therefore name
exactly one set of shipped files:

- Every change to a file the package ships (`bin/`, `hooks/`,
  `herdr-plugin.toml`, `install.sh`, `test-vectors/tmux-pane-options-v1.json`,
  `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `rust/`,
  `scripts/package-plugin.sh` and `scripts/build-plugin-binaries.sh` (at the
  repo root)) bumps `version` in `herdr-plugin.toml` and `Cargo.toml`
  (+ `Cargo.lock`) together: edit both files, then
  `cargo update -p waycar --offline` here refreshes the lock. Set the app's
  `WaycarPluginRequirement.currentVersion` to the same version: Host detail
  offers it to Hosts on an older plugin ("2.3.0 available"), never as a gate.
  Patch for fixes, minor for new behavior. `README.md`, `LICENSE`, `NOTICE`
  and dev-only dependency churn need no bump.
- An app change that relies on new plugin behavior raises
  `minimumVersion` in the same PR, never above the plugin version.
- `scripts/check-plugin-version.sh` (CI, and before `web.yml` deploys
  and `plugin-release.yml` tags) checks that the version fields and
  `currentVersion` agree, the minimum is not above the plugin version, and shipped files are unchanged
  since the released version: the `plugin-v<version>` tag, or, before that
  tag exists, the baseline commit (`PLUGIN_BASE`: the PR base or the
  previous push; `origin/main` locally) when it already has this version.
- On merge to `main`, `.github/workflows/plugin-release.yml` cuts
  `plugin-v<version>` when that version is new, and waycar.dev/install.sh
  (rebuilt from `main`) serves the new plugin.

### Moving from the Node version (1.x)

Plugin 1.x ran on Node. A Host that installed it moves with one rerun of
`install.sh`; the app runs it for the user. The update removes what Waycar put
there: `src/*.js`, `bin/node.sh`, `node_modules`, `package*.json`,
`~/.cache/waycar/node-versions` and `~/.local/state/waycar/bridge-off/`. It
rewrites Node-era agent hook entries to call `bin/waycar hook-session`. It
never touches the user's own Node, npm, nvm or Homebrew, the config, the
keys, `authorized_keys` or the `@waycar_*` options.

Codex asks for one `/hooks` review afterward, because its trust hash changes
with the command.

`install.sh` stages the package next to the install directory and runs
`bin/waycar version` first. If the binary will not run, the old install stays.
After the swap it runs `waycar status --json` and moves the old install back
if that fails. Node processes started by the old install (herdr's hooks)
keep running until herdr restarts; `install.sh` prints how many and does not
kill them.

The app keeps working against both eras. For `chat-read` and `chat-media` it
runs the old Node script when `src/<script>.js` exists, and
`bin/waycar <subcommand>` otherwise.

## Host Tools (tmux)

The same package serves Hosts that run tmux 3.2 or later instead of, or next
to, herdr (ADR 0026, `docs/design/tmux-backend.md` §4.5–4.6). Without herdr's
plugin actions and `[[events]]` hooks, a tmux Host gets the `waycar` command
(`bin/waycar`) and the agent Status Hooks.

### install.sh modes

```bash
curl -fsSL https://waycar.dev/install.sh | sh
curl -fsSL https://waycar.dev/install.sh | sh -s -- --tmux --no-hooks
```

- **herdr mode**: herdr on `PATH`; links the package into herdr as before.
- **tmux mode**: no herdr but tmux, or `--tmux` (forces it even when herdr is
  installed). A Host with only herdr-core (no herdr, no tmux 3.2+) gets the same
  shape, see [Host Tools (herdr-core)](#host-tools-herdr-core).
- In either mode, with tmux 3.2+ or herdr-core present it links `~/.local/bin/waycar` and
  runs `waycar hooks install` in the same run, prints the files it changed and
  Codex's one-time `/hooks` review, then offers Pairing (`WAYCAR_NO_PAIR`
  skips the prompt).
- In either mode, with `opencode` or `kilo` on `PATH`, it also installs that
  agent's Chat Prompt extension (`waycar-chat-prompt.js`, ADR 0025) directly
  — it does not wait for the tmux gate. `waycar hooks install` installs the
  same file on tmux hosts, so a current copy is left as it is; a file in the
  user's `opencode/plugins/` or `kilo/plugins/` that Waycar did not install
  is left alone.
- `--no-hooks` skips the Status Hooks and the opencode and kilo Chat Prompt
  extensions (add them later with `waycar hooks install`).
- `WAYCAR_PLUGIN_SOURCE=<dir>` installs from a local plugin directory (a
  checkout's `plugin/` or an unpacked package) instead of downloading, for
  testing before a deploy. `WAYCAR_INSTALL_BASE_URL` and `WAYCAR_PLUGIN_DIR`
  override the download base and install directory.
- Before pairing (including `--pair-only`), `waycar reach-status` prints
  whether a Tailscale address or command was found. Address detection uses
  `is_tailscale_address` in `rust/addresses.rs`: IPv4 `100.64.0.0/10` or IPv6
  `fd7a:115c:a1e0::/48`. It installs nothing and does not change networking.
  Without a local Tailscale address, it links to the subnet-router guide:
  one device on the home network can provide access without Tailscale on
  this Host. This checks the Host only; it does not detect the phone's VPN.
- The package download request carries `?via=install&kind=install|update`
  (`via=pair` for a pair-only run) so waycar.dev can count installs apart
  from updates and pair-only runs (`plugin_package_downloaded`; see
  `apps/web/README.md`). Only those fixed values are sent, and not at all to
  a `WAYCAR_INSTALL_BASE_URL` that is not `http(s)`. Waycar's own automation
  sets `WAYCAR_INTERNAL=1`, which adds `internal=1` so its runs stay out of
  the customer counts.

### `waycar` commands

| Command | Does |
|---|---|
| `waycar pair` | Pairing Code in the current terminal (same envelope and Enrollment as the herdr action). In tmux: `bind W display-popup -E waycar pair` |
| `waycar hooks install` | Idempotent, order-preserving merge of our entries into each agent's config; keeps every other hook, in place, also another tool's handlers inside our groups (agent-deck adds its own there); never touches Codex `notify` |
| `waycar hooks uninstall` | Removes only our entries and extension files |
| `waycar hooks status [--json]` | Which agents are found on the Host (`detected`) and have current hooks (`installed`); other tools' handlers in our groups do not count |
| `waycar notify --pane tmux:%N\|hc:<address>\|zellij:<session>/terminal_<n> --status working\|idle\|blocked\|done\|release` | Run by the hooks: Live Activity on every change; after the hold and recheck, an encrypted push on Blocked or Done. `hc:<address>` is a herdr-core terminal, see [Host Tools (herdr-core)](#host-tools-herdr-core) |
| `waycar hook-status <agent> <status>` | The Zellij/herdr-core fallback of `waycar-hook`, with its own ownership check; prints nothing and exits 0. `waycar hook-status <agent> session <id> [<transcript>]` records the session of agents with no hook payload |
| `waycar watch-approval --pane tmux:%N --agent agy\|cline` | Run by an agent's tool hook (`waycar-hook <agent> watch-approval`) for kinds whose hooks report no approval: Blocked while its approval dialog is on the pane, see [Approval watch](#approval-watch) |
| `waycar summaries refresh` | Refresh Agent Summaries |
| `waycar status [--json]` | Backends (herdr, tmux, herdr-core, Zellij), hooks and config dir; `--json` prints one object (version 1) the app decodes over SSH: `backends` is `{"herdr":bool,"tmux":str\|null,"core":str\|null,"zellij":str\|null}` |
| `waycar version` | Package version |

### Native `waycar` (Rust)

From plugin 2.0.0 the Host Tools are one static native binary, so a Host needs
no Node.js, npm or version manager. The crate is `Cargo.toml` here and the
sources are in `rust/`. `bin/waycar` in a package is the binary for the Host's
OS and CPU: Linux x86_64 and ARM64 (musl, static, no libc version floor, so
Alpine works) and macOS Apple Silicon and Intel (deployment target 11.0).
`install.sh` picks the file from `uname` and checks its SHA-256 before it
installs anything. `bin/waycar-hook` stays POSIX sh, and the agent extension
files in `hooks/` run inside the agents.

- **Commands:** `waycar version`, `help`, `pair` (the Pairing Code screen),
  `hooks install|uninstall|status [--json]`, `status [--json]`,
  `summaries refresh` (also the herdr action `refresh-summaries`), the
  two readers the app runs over SSH, `chat-read` and `chat-media`. The commands
  that are not in the usage text are `pair-accept` (the sshd forced command of
  a Bootstrap Key), `pair-action` (herdr's "Pair a mobile device" action) and
  `reach-status` (what `install.sh` prints about Tailscale).
- **Hook runtime:** push notifications and the Live Activity are native too
  (`notify`, `watch-approval`, the herdr event and startup hooks,
  `hook-session`, the plan-step tick). The internal commands are `waycar
  hook-session <agent> [<event>]` (the event on stdin), `waycar herdr-event
  notify|activity` and `waycar herdr-startup` (what the herdr manifest runs)
  and `waycar activity-tick '<json>'` (what the Live Activity hook starts,
  detached).
- **Modules:** the Chat Mode transcript reader (`chat/`, one file per harness
  in `chat/readers/`), Agent Summaries (`summary/`), the popup, hook merge
  and enrollment code (`pair.rs`, `pairing_qr.rs`, `hooks/`,
  `pair_accept.rs`), and the hook runtime (`hook_runtime.rs`, `notify_*.rs`,
  `activity_*.rs`, `approval_watch.rs`, `hook_session.rs`, `hook_status.rs`,
  `sidebar_config.rs`). Shared pieces: XDG paths and the herdr config/state
  directory (`paths.rs`), atomic file writes and locked edits (`atomic.rs`),
  the tmux, herdr and herdr-core command runners (`exec.rs`, `tmux.rs`,
  `herdr.rs`, `core.rs`),
  HTTPS with built-in root certificates (`http.rs`, so no CA bundle is
  needed), and the exit-code conventions (`error.rs`).
- **Build:** `cargo build` in this directory builds for the local platform. The
  four release targets (Linux and macOS, x86_64 and arm64) are cross-built
  from Linux with zig and cargo-zigbuild: `scripts/build-plugin-binaries.sh
  <dir>` installs the pinned toolchain on demand and writes
  `<dir>/<target>/waycar`. Linux builds are static (musl); macOS builds
  target 11.0. The decision is ADR 0031.
- **Tests:** `cargo test --locked` in this directory. CI also runs
  `cargo fmt --check` and `cargo clippy --locked --all-targets --all-features
  -- -D warnings`.
- **herdr runs a native `bin/waycar` straight from the manifest.** Checked
  against herdr 0.7.5, 0.8.2 and 0.9.5 on Linux: `command = ["bin/waycar",
  "<subcommand>"]` runs with no shell, in the plugin directory, with the
  `HERDR_*` variables, and needs the exec bit. 0.7.5 and 0.8.2 fail a bare
  `bin/waycar` in a `[[panes]]` entry (they look it up on PATH), so write
  `command = ["./bin/waycar", ...]` there.

### Status Hooks

`bin/waycar-hook <agent> <status>` (POSIX sh) writes the pane options for
events whose status the event decides; `bin/waycar hook-session <agent>
[<event>]` handles the events whose payload matters (sessions, transcript
paths, notification types, stray session ids). Both exit at once when
`HERDR_PANE_ID` or `HERDR_ENV` is set (herdr owns that pane's status) or
`WAYCAR_SUMMARY` is set (an Agent Summary's harness run, see
[Hardening](#hardening)), and unless `TMUX_PANE` is set and the agent's tty
is that pane's `#{pane_tty}`. The agent's tty is `$CLAUDE_PID`'s for
claude, else the hook's parent's, else, when the parent has none (claude
2.1.296 and grok run hooks from a tty-less `sh -c`), its grandparent's.
Never for codex or cline: codex's shared app-server and cline's hub run
hooks without a tty and with the `TMUX_PANE` of whichever pane started them
(cline's hook files `exec` the hook, so its parent is the pane's own
`.cline`). Claude's hooks also need `CLAUDECODE=1` and none
of the markers of grok, cursor, devin and copilot, which run
`~/.claude/settings.json` hooks too; cursor's need `CURSOR_VERSION` and no
grok marker. Statuses `working-if-active`, `working-if-blocked`,
`idle-if-working` and `done-if-active` are guarded; tool events never revive
Idle or Done (herdr #198). Every hook exits 0 and prints nothing.

Shared-daemon Codex threads are the exception to pane routing: when the
hook's parent has no tty, `waycar-hook` asks the native helper to identify a
shared `codex app-server` ancestor. PermissionRequest notifies Blocked and
Stop notifies Done with `last_assistant_message`, addressed to
`codex:<session_id>`; inherited tmux/herdr/core variables never cause pane
writes. The usual per-device preferences apply; `codex_enabled: false` in
`notify.json` silences these threads (default on). Embedded TUIs and the
installed hook commands stay unchanged, preserving existing Codex trust.

OpenCode 2 sessions notify the same way, without a pane. OpenCode 2 runs
the opencode extension's V2 `setup` inside its one shared server, whose
environment is that of whichever client started it, so V2 writes no Agent
Status. Instead `setup` subscribes to the server's events and runs `bin/waycar
opencode-push blocked|done` (the event as JSON on stdin) for `permission.asked`
and question `form.created` (Blocked) and `session.execution.succeeded` and
`failed` (Done, with the turn's last assistant text as the reply), addressed
to `opencode:<sessionID>`. A subagent session's (one with a `parentID`)
permission or question holds up its top-level session, so it pushes as that
root, found by following `parentID`; a subagent's finished turn pushes
nothing, and neither do interrupted turns (a rejected permission included).
Events of one session within the debounce (`debounce_ms`) coalesce into the
latest status and reply, as for Codex's threads: a Blocked push is dropped
when the session moved on meanwhile, and only the newest event pushes. The
server loads the extension once per loaded folder and every instance sees
every event, so the instances share one registry of claimed event ids on the server's
`globalThis` (which also survives the extension's hot reload), and
`opencode-push` records each session's last event id under a lock and skips
one already recorded. The Host Tools never start OpenCode's server.
`opencode_enabled: false` in `notify.json` silences these sessions (default
on). OpenCode 1 and kilo are unaffected.

| Agent | Where | Entries |
|---|---|---|
| Claude Code | `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json` | `SessionStart` session; `UserPromptSubmit` working; `PreToolUse` (not `AskUserQuestion`/`ExitPlanMode`) working-if-active; `PermissionRequest` blocked; `Notification` `permission_prompt\|elicitation_dialog\|elicitation_url_dialog\|agent_needs_input` blocked; `Notification` `idle_prompt` idle-if-working; `PostToolUse`, `PostToolUseFailure`, `ElicitationResult` working-if-blocked; `Stop`, `StopFailure` done; `SessionEnd` release |
| Codex | `${CODEX_HOME:-~/.codex}/hooks.json`, plus `[features] hooks = true` in `config.toml` (added when the key is absent; an explicit `hooks = false` is left alone, and `waycar hooks install`/`status` report that Codex hooks stay off until you set it to `true`) | `SessionStart` session; `UserPromptSubmit` working; `PreToolUse` working-if-active; `PermissionRequest` blocked; `PostToolUse` working-if-blocked; `Stop` done; `Interrupt` idle; `SessionEnd` release. Inactive until reviewed once in `/hooks` |
| Qwen Code | `~/.qwen/settings.json` | `SessionStart` session (idle); `UserPromptSubmit` working; `PreToolUse` working-if-active; `PermissionRequest` blocked; `PostToolUse`, `PostToolUseFailure` working-if-blocked; `Stop`, `StopFailure` done; `SessionEnd` release. No `Notification`: its `idle_prompt` fires mid-turn |
| Gemini CLI | `~/.gemini/settings.json` (named handlers, ms timeouts) | `SessionStart` session (idle); `BeforeAgent` session + working; `BeforeTool` working-if-active; `Notification` `ToolPermission` blocked; `AfterTool` working-if-blocked; `AfterAgent` done; `SessionEnd` release |
| Devin CLI | `~/.config/devin/config.json` | Claude's events: `SessionStart` session; `UserPromptSubmit` working; `PreToolUse` working-if-active; `PermissionRequest` blocked; `PostToolUse` working-if-blocked; `Stop` done; `SessionEnd` release |
| Grok Build | `${GROK_HOME:-~/.grok}/hooks/waycar.json` | `SessionStart` session (idle); `UserPromptSubmit` session + working; `PreToolUse` working-if-active; `Notification` `permission_prompt` blocked (a subagent's too), `idle_prompt` idle-if-working; `PostToolUse`, `PostToolUseFailure` working-if-blocked; `Stop`, `StopFailure` done-if-active (a `Stop` follows `SessionEnd`); `StopCancelled` idle; `SessionStart`, `UserPromptSubmit`, `SessionEnd` release and `idle_prompt` only for the root session, never a subagent's |
| Copilot CLI | `${COPILOT_HOME:-~/.copilot}/hooks/waycar.json` | `UserPromptSubmit` working; `SessionStart` session; `PreToolUse` working-if-active; `Notification` `permission_prompt` blocked; `PostToolUse` working-if-blocked; `Stop` done; `SessionEnd` release of its own session only. No `PermissionRequest`: it fires for auto-approved tools |
| Cursor CLI | `~/.cursor/hooks.json` | `sessionStart` session; `beforeSubmitPrompt` working; `preToolUse` working-if-active; `stop` done-if-active; `sessionEnd` release. No approval event |
| Kiro CLI | `~/.kiro/hooks/waycar.json` (V3 engine only) | `SessionStart` session; `UserPromptSubmit` working; `PreToolUse` working-if-active; `Stop` done; `SessionEnd` release. No approval event |
| Antigravity (`agy`) | `"waycar"` group in `~/.gemini/config/hooks.json` | `PreInvocation` session + working; `PreToolUse` (`*`) [approval watch](#approval-watch) for blocked; `Stop` (`fullyIdle`) done. No session, approval or exit events: a denied or cancelled turn ends only on the app's screen detection |
| Hermes Agent | marked `hooks:` block at the end of `${HERMES_HOME:-~/.hermes}/config.yaml`, plus its commands in `shell-hooks-allowlist.json` (Hermes's first-use consent) | `pre_llm_call` session + working; `on_human_input_request` blocked; `on_human_input_resolved` working-if-blocked; `on_session_end` done, idle when interrupted; `on_session_finalize` release. A `config.yaml` with its own top-level `hooks:` is left alone (error) |
| Cline CLI | `~/.cline/hooks/{TaskStart,TaskResume,PreToolUse,TaskComplete,TaskError,TaskCancel,SessionShutdown}`, bash files that `exec` our command | `TaskStart`, `TaskResume` session + working; `PreToolUse` [approval watch](#approval-watch) for blocked (cline has no approval event); `TaskComplete`, `TaskError` done; `TaskCancel`, `SessionShutdown` (Esc) idle. Hooks reach the pane only when cline runs locally (`--data-dir ~/.cline/data`), not in its hub daemon |
| Muse | `${XDG_CONFIG_HOME:-~/.config}/muse/settings.json` | `UserPromptSubmit` session + working (no `SessionStart`: Muse fires none on resume); `PreToolUse` working-if-active; `PermissionRequest` blocked; `PostToolUse`, `PostToolUseFailure` working-if-blocked; `Stop`, `StopFailure` done; `Interrupt` (Esc, async) idle; `SessionEnd` release. Muse strips `TMUX`, `TMUX_PANE` and `HERDR_*` from its hooks, so `waycar-hook` reads them from the Muse process's `/proc/<ppid>/environ` (else finds the pane by its tty). Its payloads carry no transcript path |
| omp | `~/.omp/agent/extensions/waycar-agent-state.ts` | extension file |
| pi | `~/.pi/agent/extensions/waycar-agent-state.ts` | extension file. `@earendil-works/pi-coding-agent` 1.0+; the deprecated `@mariozechner/pi-coding-agent` 0.73 also works (TUI detected from a UI on a terminal, `agent_end` settles). Upgrade with `npm uninstall -g @mariozechner/pi-coding-agent && npm install -g @earendil-works/pi-coding-agent` |
| opencode | `${XDG_CONFIG_HOME:-~/.config}/opencode/plugins/waycar-agent-state.js` | extension file |
| opencode | `${XDG_CONFIG_HOME:-~/.config}/opencode/plugins/waycar-chat-prompt.js` | extension file (Chat Prompt injection, ADR 0025): appends the Chat Prompt from the pane's Chat Marker to every model request's system messages. Installed by `install.sh` on herdr and tmux hosts alike when `opencode` is on `PATH`, and by `waycar hooks install` on tmux hosts |
| Kilo Code | `${XDG_CONFIG_HOME:-~/.config}/kilo/plugins/waycar-agent-state.js` and `waycar-chat-prompt.js` | opencode's two extension files, labelled `kilo` |

Hook timeouts are 10 s (Codex clamps `SessionEnd` and `Interrupt` to 3 s).
Files Waycar owns outright carry the marker line `installed by waycar`, or,
for JSON, hold only Waycar's commands.

#### Approval watch

agy and cline have no approval event: `PreToolUse` fires before every tool,
auto-allowed or not, just before the approval dialog draws, and nothing fires
while the dialog shows (agy: nor after a denial). The app sees the dialog on
the screen, but only while it is connected, and pushes come from statuses
hooks write. So their `PreToolUse` runs `waycar-hook <agent> watch-approval`,
which writes no status and, while the pane is `working`, starts `waycar
watch-approval` detached, one per pane. It reads
the pane's visible screen every 250 ms until 5 s after the latest
`PreToolUse`; the kind's dialog (agy:
`navigate` plus `tab amend` or `esc skip` in the bottom two rows, herdr's
rules; cline: `Cline needs permission`, `Approve tool call?`, `[y] Approve`,
`[n] Deny` in the bottom 16 rows, or its question prompt) sets `blocked`,
then it reads every second until the dialog is gone (approved, denied or
cancelled) and sets `working`, and waits again when a `PreToolUse` came
meanwhile. Each status it writes raises `@waycar_seq` and goes through
`waycar notify` like a hook's; a hook's own write (a new seq) or a pane that
is gone ends the watch. Every write is a compare-and-set inside the tmux
server (`if-shell -F` on the seq the watch read), so a hook's write in
between wins.

One watch per pane: the watch holds `@waycar_approval_watch` (`<pid>-<hex>`)
while it runs, and every `PreToolUse` (while `working` or `blocked`) sets
`@waycar_approval_poke` and reads that token in the same tmux call. A token
whose pid is running this pane's watch (`watch-approval --pane tmux:%N` in
its argv, so a reused pid running a hook or another pane's watch does not
count) takes the poke as a new tool and restarts its wait; with no token, or
a dead one, the hook starts a watch. The
watch clears its token only while the poke is the one it last saw, so a poke
either reaches it or finds the pane free. These two options are the watch's
own, outside the contract below.

### Pane-option contract (v1)

Pane-level user options, written with `tmux set-option -p -t "$TMUX_PANE"`
and read by the app's TmuxTransport:

| Option | Value |
|---|---|
| `@waycar_status` | `working`, `blocked`, `done` or `idle`; anything else reads as Unknown |
| `@waycar_agent` | the agent kind: `claude`, `codex`, `omp`, `pi`, `opencode`, `copilot`, `qwen`, `gemini`, `grok`, `agy`, `hermes`, `kilo`, `cline`, `cursor`, `devin`, `kiro` or `muse` |
| `@waycar_session` | the agent's session id or session file path |
| `@waycar_transcript` | transcript path, percent-encoded (UTF-8; unreserved `A-Z a-z 0-9 - . _ ~ /`; uppercase hex) |
| `@waycar_seq` | decimal nanoseconds since the epoch, raised on every status write, never at or below the previous value |

`release` unsets every option above. Pane ids crossing the host tools
and the app carry a `tmux:` prefix (`tmux:%12`) so they never collide with
herdr's. `test-vectors/tmux-pane-options-v1.json` pins the option names,
values, `seq` and transcript encoding, the hook status guards
(`hookTransitions`) and what the app derives from each pane (`paneCases`);
the Rust and Swift suites both consume it.

### One registration file per Host

A Host keeps one Notification Registration file whatever its backends: in
the herdr plugin's config directory when the plugin is installed, else in
`${XDG_CONFIG_HOME:-~/.config}/waycar`. The app and the host tools resolve it
the same way (`waycar config-dir`), so registering, Live Activity tokens and
removal stay one read-merge-write. One notifier per Host reads both backends
(`herdr agent list`, and tmux's panes) for the Attention Badge count, so a
dual Host still has a single producer.

## Host Tools (Zellij)

Zellij 0.46.0 or later uses the same standalone Host Tools and Status Hooks
as tmux. Run `install.sh` with no flag: a Zellij-only Host needs neither tmux
nor herdr. Detection runs `zellij --version` only, never starting or
resurrecting a session. `waycar status --json` reports `backends.zellij`
after `core`, without changing the report's version (1).

Hooks try tmux first, then Zellij, then herdr-core. Zellij takes a hook only
when the agent has a controlling tty and its own process environment matches
both `ZELLIJ_PANE_ID` and `ZELLIJ_SESSION_NAME`. From that agent it walks at
most 16 parents to the first process whose parent is a Zellij server
(`zellij --server <socket>`). That pane root must have the same controlling
tty and the same two values in its own environment. No server ancestor, no
tty, or a different tty rejects the Zellij branch, even with an inherited
pair. Claude uses `CLAUDE_PID`; Codex and cline never hop past a tty-less
parent. Muse's cleared environment is restored from its agent. tmux keeps
priority; a nested pty cannot write the outer Zellij pane's document.

Each pane writes one locked, atomically replaced JSON file under
`$HOME/.local/state/waycar/zellij/`, deliberately ignoring `XDG_STATE_HOME`
so a bare SSH reader sees the same files. The file name is unpadded
base64url of `zellij:<session>/terminal_<n>` plus `.json`. Version 1 records
kind, status, monotonic sequence, session, decoded transcript path, launch
tag, agent pid and update time. SessionEnd deletes it; periodic hook GC
removes documents for sessions no longer live. Unknown document versions
and fields are tolerated. No hook writes into a pane's tty.

The root OSC 7501 `program_status` record takes precedence over hook status;
`Error` means Blocked. Blocked/Done pushes and Live Activity rows use the
same pane id. A failed pane listing never trusts a stale document.
`zellij_enabled: false` in `notify.json` silences Zellij pushes and rows
(default on). Recording a session sets Zellij's resurrection command to
that agent's resume argv, best effort. Renaming a running Zellij session
leaves its agent environment stale: restart those agents afterwards.

The omp, pi, opencode 1 and kilo extensions record sessions through
`waycar hook-status <agent> session <id> [<transcript>]`. The read-only
`waycar hook-status <agent> owns-zellij` query exits 0 only for an owned
Zellij pane, 125 otherwise, and writes nothing. Chat Prompt extensions use
it so inherited Zellij variables do not suppress Chat Mode inside herdr or
herdr-core. Process argv/environment come from NUL-delimited `/proc` on
Linux and `KERN_PROCARGS2` on macOS, preserving spaces and `=` in values.
Codex resurrection keeps `--no-daemon` when the running agent has that flag;
no Codex probe runs. OpenCode 2 remains server-based. Chat Mode, Summaries
and approval watch are not supported on Zellij in this version.

## Host Tools (herdr-core)

From plugin 2.2.0 the same package serves Hosts that run herdr-core (`herdr-core`,
alias `hc`, the runtime under the Herdr app) with no herdr TUI and no tmux
(ADR 0031, `docs/design/herdr-core-backend.md` §11). Like a tmux Host it gets
the `waycar` command and the agent Status Hooks, and no herdr plugin link.

- **Finding core.** `install.sh`, `waycar status` and the hooks look for
  `herdr-core`, then `hc`, on `PATH` and in `~/.local/bin`, `/opt/homebrew/bin`,
  `/usr/local/bin`, mise's shims, `~/.nix-profile/bin`,
  `/run/current-system/sw/bin` and `~/.cargo/bin` (an SSH exec or a hook rarely has
  `~/.local/bin` on `PATH`). A binary counts only when `--version` prints
  `hc <digits>`: some window managers ship an unrelated `hc`. `--version` is the
  only command run to detect it, because every other `hc` subcommand starts a
  core with the caller's environment frozen into it.
- **install.sh.** With no herdr on `PATH`, tmux older than 3.2 or absent, and core
  found, it runs in tmux mode's shape: `~/.local/bin/waycar`, the Status Hooks, no
  herdr link. With herdr and core, herdr mode installs the hooks too. The success
  line is `installed Waycar <version> in <dir>` (the app parses it; plugins before 2.2.1 print `... for tmux in <dir>`, and the app reads both).
- **`waycar status --json`** reports `backends.core` after `tmux`: the core's
  version, or `null` (version 1, additive; a core below the app's 0.1.10 floor
  is still reported).
- **Terminal identity.** A program in a core terminal has `HC_TERMINAL_ID` (the
  terminal's address, `t7`), `HC_TERMINAL_SOCKET` and `HC_SESSION`. Waycar's pane
  id for it is `hc:<address>`. Only the default session is handled (a hook in a
  named session does nothing, since addresses repeat across sessions). Core hands
  every terminal the environment of whoever started it first, so a core started
  in a tmux or herdr pane gives all of its terminals that pane's `TMUX_PANE` or
  `HERDR_*`. `bin/waycar-hook` therefore tries tmux first, with its own tty check,
  and when tmux does not take the hook (no `TMUX_PANE`, no tmux, another pane's
  tty) and `HC_TERMINAL_ID` is set, runs `waycar hook-status <agent> <status>`.
  That command takes the terminal only when the agent's controlling tty is the tty
  of the terminal's own process (core's `pid`), with the same rules as the tmux
  guard (`CLAUDE_PID` for claude, one hop to the grandparent, none for codex and
  cline). A hook from outside any terminal, in a finished terminal, with
  `herdr-core` missing or its socket not listening (a process that merely
  inherited `HC_TERMINAL_ID` from a core that is gone must not start another
  one), or with `core_enabled` false exits 0 and prints nothing.
- **Status.** The agent's own OSC 7501 report is the status; no hook writes one.
  Core's `error` shows as `blocked`. Hooks write labels on the terminal
  (`herdr-core label <address> k=v`, an empty value removes one):

  | Label | Written | Holds |
  | --- | --- | --- |
  | `waycar.kind` | on a status hook | the agent kind (`claude`, `codex`, ...) |
  | `waycar.turn` | on `working` | core's `turn` of the terminal then |
  | `waycar.status` | only while the terminal has reported no status | the last status the hook wrote, so the conditional statuses (`done-if-active`, ...) work for an agent that never reports OSC 7501 |
  | `waycar.session`, `waycar.transcript` | by `waycar hook-session` and the omp, pi, opencode and kilo extensions (`waycar hook-status <agent> session <id> [<transcript>]`) | the agent's session id and transcript path (the path itself, not percent-encoded) |

  `release` (SessionEnd) removes all of them. There is no `@waycar_seq` and no
  approval watch on core: core keeps its own `status_ms` and `turn`.
- **Notifications.** `waycar notify --pane hc:<address> --status
  working|idle|blocked|done|release` is the tmux flow with core as the backend:
  after the hold it asks `herdr-core get <address> --json`. A terminal that is gone
  or finished sends nothing, and an answer that fails sends nothing (fail closed).
  A core that is not listening is never asked (every `hc` subcommand would start
  one): the trigger fails with `no herdr-core is running on this Host`. A terminal
  that has never reported (`reported: false`) has only what the hooks wrote: its
  `waycar.status` label must still be the event's status (a later hook that moved
  it on during the hold drops the event, as for tmux), and with no label the hook
  is trusted. One that has reported must show the hook's status, with core `error`
  read as `blocked` and one more rule: core `idle` counts as `done` when its
  `turn` is higher than `waycar.turn` (a turn end some agents report as `idle`),
  or `turn >= 1` when the label is missing. The push's `pane` is `hc:<address>`,
  its project the terminal's folder name and its title the terminal's name. The
  Attention Badge counts live terminals that are blocked or done. `notify.json`
  `core_enabled: false` sends nothing and never calls `herdr-core`.
- **Live Activity** includes core terminals that report OSC 7501 (from
  `herdr-core ls --json`, plus `get` for those working, blocked or done), and
  `activity-tick` keeps and prunes their plan steps in its own bucket. An agent
  that never reports OSC 7501 has no row. A herdr or tmux event on a Host that
  merely has core installed only asks a core that already listens (the socket is
  probed with a plain connect), so it never starts one.
- **Chat Markers, summaries.** `hc:` Chat Markers are kept while core lists the
  terminal and deleted when it is gone (never because the herdr TUI does not list
  them); a core that cannot answer keeps them. The core trigger collects them in an
  hourly slot of its own, so it never takes the slot of the herdr hook's collection.
  Agent Summaries read a core terminal's screen with `herdr-core read`. Chat
  Mode's final-reply push is not available on core: it needs a core identity
  (`core.id`) the CLI does not print.

Not covered: starting `herdr-core events` as a watcher (agents without hooks and
without OSC 7501 never notify), screen-based status, Chat Mode replies, named
core sessions.

## Pairing Code envelope (v1)

The Pairing Code is a single-line string; the QR image is just its rendering.

```
HERDR-PAIR:<version>:<base64url(JSON, no padding)>
```

- `HERDR-PAIR` is a literal prefix; anything else is rejected (`bad_prefix`).
- `<version>` is a decimal integer. This document specifies version `1`;
  any other value is rejected (`unsupported_version`).
- The body is the payload JSON, UTF-8, encoded as unpadded base64url
  (RFC 4648 `-`/`_` alphabet). Invalid base64url or JSON is rejected
  (`bad_encoding`).

### Payload fields

| Wire key | Type    | Required | Meaning |
| -------- | ------- | -------- | ------- |
| `addrs`  | string[]| yes      | Candidate addresses in the order the app should try them. Non-empty; each entry a non-empty string without whitespace. IPv6 literals carry no brackets and no zone id. |
| `port`   | integer | yes      | SSH port, `1..65535`. |
| `user`   | string  | yes      | SSH username. Non-empty, no whitespace. |
| `fp`     | string  | yes      | Host key fingerprint exactly as OpenSSH prints it: `SHA256:` + 43 chars of unpadded standard base64. The app pins this instead of showing a TOFU prompt. |
| `seed`   | string  | no       | Raw 32-byte Ed25519 seed of the Bootstrap Key, unpadded base64url. Present together with `exp` or not at all. |
| `exp`    | integer | no       | Unix-seconds expiry of the Bootstrap Key. Present together with `seed` or not at all. |

A payload violating these rules is rejected (`bad_payload`). A code without
`seed`/`exp` is a config-only Pairing Code: same ceremony minus the bootstrap
connection.

### Canonical encoding

Encoders emit the keys in the order of the table above with no JSON
whitespace, so a given payload has exactly one canonical code. Decoders do not
depend on key order.

### Compatibility rules

- Decoders ignore unknown payload fields; additive metadata may appear within
  v1.
- Any breaking change (removing, renaming, or re-typing a field, or changing
  the envelope framing) bumps `<version>`, and both implementations must be
  updated together.

## Bootstrap Key lifecycle

Confirming the address checklist mints an ephemeral Ed25519 **Bootstrap Key**.
Its raw 32-byte seed rides in the Pairing Code (`seed`/`exp`); its public half
is written to `~/.ssh/authorized_keys` as a restricted line:

```
restrict,command="'<plugin>/bin/waycar' pair-accept --state-dir '<state>' --pairing-id <id>" ssh-ed25519 <blob> herdr-pairing:<id>:exp:<unix-seconds>
```

- `restrict` plus the forced command mean the key can do exactly one thing:
  run the Enrollment accept entrypoint. The command embeds absolute paths
  because sshd provides no plugin environment.
- The trailing `herdr-pairing:<id>:exp:<unix-seconds>` comment marks the line
  so cleanup and the sweep can find it with no state beyond the file.
- All edits to `authorized_keys` are atomic (exclusive lock, temp file +
  rename) and preserve the file mode, so sshd `StrictModes` keeps accepting
  the file.

The line is removed on successful Enrollment (self-revoke), when the 2-minute
TTL expires, when the popup exits (including SIGTERM/SIGHUP), and by a sweep
of expired lines every time the popup starts — so a killed popup leaves at
worst a line that dies with its TTL and is swept at the next start. Pending
ceremony state lives under `$HERDR_PLUGIN_STATE_DIR/pending/<id>.json`, never
in the plugin checkout. On successful Enrollment the accept entrypoint writes
`$HERDR_PLUGIN_STATE_DIR/enrolled/<id>.json` (the enrolled fingerprint and
line); the popup polls for it to show the success screen and drive the revoke,
and clears it on exit. An invalid submission does not consume the line; the
app may retry until the TTL runs out.

### Enrollment accept protocol

The app connects with the Bootstrap Key and writes its Device Key public line
(`ssh-ed25519 <blob> [comment]`, printable-ASCII comment) followed by a
newline to stdin. The forced command answers with one line on stdout:

| Response | Meaning |
| -------- | ------- |
| `HERDR-ENROLL:OK:<SHA256:fingerprint>` | Device Key appended (or already authorized); bootstrap line revoked. Exit 0. |
| `HERDR-ENROLL:ERR:invalid_key` | Submission is not a bare Ed25519 public line. Line not consumed; retry allowed. Exit 1. |
| `HERDR-ENROLL:ERR:no_input` | Nothing arrived on stdin. Line not consumed. Exit 1. |
| `HERDR-ENROLL:ERR:expired` | TTL passed; the bootstrap line was removed. Regenerate the code. Exit 1. |
| `HERDR-ENROLL:ERR:unknown_pairing` | No pending ceremony (already used, cleaned up, or never existed). Exit 1. |

Human-readable detail goes to stderr. Manual demo from another machine:

```bash
# On the phone side stand-in: seed.key holds the Bootstrap Key in any format
# ssh accepts; the app itself uses the raw seed from the Pairing Code.
ssh -i seed.key <user>@<host> < device_key.pub
```

### Shared test vectors

`test-vectors/pairing-code-v1.json` is the single source of truth for the
envelope, consumed by the Rust tests here and the Swift tests in the app.
Valid vectors must decode to the given payload and (unless `decodeOnly`)
re-encode to the exact code; invalid vectors must fail with the given error
code (`bad_prefix`, `unsupported_version`, `bad_encoding`, `bad_payload` —
these map to the "parse" step of the pairing failure taxonomy).

## Notification envelope (v1)

The encrypted Agent Notification payload (ADR 0008): the notify hook
encrypts it on the Host, the Push Relay and APNs carry it opaquely, and the
app's service extension decrypts it. One compact JSON object:

```json
{"v": 1, "kid": "<key id>", "n": "<nonce>", "ct": "<ciphertext>"}
```

### Cleartext fields

| Wire key | Type    | Meaning |
| -------- | ------- | ------- |
| `v`      | integer | Envelope version. This document specifies version `1`; any other integer is rejected (`unsupported_version`). |
| `kid`    | string  | Key id: the first 8 bytes of SHA-256 over the raw 32-byte Notification Key, unpadded base64url. Derived on both ends, never stored. The app uses it to select the right Notification Key (and thus Host) when several Hosts are registered. |
| `n`      | string  | 12-byte AES-GCM nonce, unpadded base64url. Freshly random per envelope. |
| `ct`     | string  | AES-256-GCM ciphertext followed by the 16-byte tag, unpadded base64url. |

A missing or mistyped field, invalid base64url, or wrong nonce/tag length is
rejected (`bad_envelope`).

### Ciphertext

AES-256-GCM under the per-host Notification Key, with the UTF-8 bytes of
`HERDR-NOTIFY:1` as additional authenticated data so a ciphertext re-framed
under another version fails authentication. Tampered material or the wrong
key is rejected (`decrypt_failed`) — GCM cannot tell those apart. The
plaintext is compact JSON:

| Wire key | Type    | Meaning |
| -------- | ------- | ------- |
| `pane`   | string  | herdr pane id the Agent lives in. Non-empty. |
| `kind`   | string  | Agent kind as herdr reports it (`claude`, `codex`, ...). Non-empty. |
| `status` | string  | The new Agent Status. An open set: decoders pass unrecognized values through. Non-empty. |
| `ts`     | integer | Unix-seconds of the status transition. Positive. |
| `project`| string  | Optional, display only: the workspace label the Agent runs in — the project name the app's alert leads with. Omitted when the Host cannot resolve it. At most 256 characters (the hook trims to 80 before encrypting). |
| `title`  | string  | Optional, display only: the Agent's terminal title with status glyphs stripped — what it is working on. Same absence and length rules as `project`. |
| `summary`| string  | Optional, display only: the Agent Summary — one sentence on what a Done Agent finished or what a Blocked Agent is asking the user for (see [Agent Summary](#agent-summary)). Same absence rules as `project`, but up to 100 graphemes. |
| `reply`  | string  | Optional, display only: the Chat Mode Agent's final reply, sent only on `done` for a pane with a Chat Marker (see [Reply push](#reply-push)). Line breaks and tabs allowed, no other C0 controls; at most 1,000 bytes of JSON-escaped UTF-8, and shorter or omitted when the envelope would not fit APNs. The app shows it as the alert body. |
| `attention` | integer | Optional: how many of this Host's agents are Blocked or Done (from `herdr agent list`, which lists no plain shells) when the push was built — the Host's share of the app's Attention Badge. Any non-negative integer; `0` is a real count and is sent. The app caps each Host's count at 999 and ignores a count older (by `ts`) than the one it holds for the Host. Omitted when the Host could not list its agents, and the app then leaves its badge alone. |

A plaintext that is not JSON or violates these rules is rejected
(`bad_payload`). Every rejection is a typed error on the app side; the
service extension answers any of them with a generic fallback banner, never
a crash.

### Canonical encoding

Encoders emit both JSON objects with the keys in table order and no
whitespace, so given inputs yield exactly one envelope; the shared vectors
assert on the exact string. An optional field with no value is omitted
entirely rather than sent empty, so absent, null, and `""` all encode
identically; `attention` is omitted only when absent or null, since `0` is a
value. Decoders do not depend on key order and ignore unknown fields at
either layer (additive v1 metadata). Any breaking change bumps `v`, and both
implementations must be updated together.

### Shared test vectors

`test-vectors/notification-payload-v1.json` is the single source of truth,
consumed by the Rust tests here (encrypt direction: non-`decodeOnly` valid
vectors must be reproduced byte-for-byte) and the Swift tests in the app
(decrypt direction: valid vectors must yield the payload, invalid vectors —
including tampered-ciphertext and wrong-key cases — must fail with the given
error code: `bad_envelope`, `unsupported_version`, `decrypt_failed`,
`bad_payload`).

Reply vectors carry two more fields. `expectedReply` is the plaintext `reply`
after normalization (the vector's `payload.reply` is the raw text handed to
the encrypt side); the Swift tests expect it as the decoded reply, and the
Rust tests prove it through the byte-exact envelope. `expectedBody` is the
alert body the app must render for that payload: the reply on `done`, the
usual wording on any other status. Vectors without a reply omit both, and an
absent `expectedBody` is not checked.

## Notification Registration file (v1)

Where a Host learns which devices to notify: the app writes this file over
SSH during Notification Registration; the notify hook reads it and POSTs one
push per device entry. It lives at `notifications.json` inside this plugin's
config directory (the app resolves that directory via
`herdr plugin config-dir`). Writers replace the whole file atomically
(temp file + rename), keyed one entry per device token; removing an entry
revokes that device.

```json
{
  "v": 1,
  "devices": [
    {
      "token": "a1b2c3...",
      "key": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8",
      "env": "production",
      "notify": { "blocked": true, "done": true },
      "live_activity": { "token": "c4d5e6...", "started_at": "2026-01-01T00:00:00Z" },
      "live_activity_start": { "token": "f7a8b9...", "host_id": "6F9619FF-8B86-D011-B42D-00C04FC964FF" }
    }
  ]
}
```

| Field            | Type    | Meaning |
| ---------------- | ------- | ------- |
| `v`              | integer | File format version. This document specifies version `1`; a reader finding any other value must treat the file as absent (send nothing) rather than guess. |
| `devices`        | array   | One entry per registered device. Empty means no notifications. |
| `provider`       | string  | Optional (plugin 2.1.0+ on the native plugin). `apns` (default when absent) or `fcm` (Android). An entry with any other provider is skipped. FCM entries have no APNs semantics: `token` is the FCM registration token (`[A-Za-z0-9_:.-]`, 50–512 chars), no `collapse` id is sent, and `env` stays for older plugins but the relay ignores it (a missing `env` is sent as `production`). A plugin without FCM support would post an FCM token as an APNs token, so apps must not write an `fcm` entry to a Host below 2.1.0. |
| `token`          | string  | The device's APNs device token (lowercase hex), or its FCM registration token when `provider` is `fcm`. Unique within the file. |
| `key`            | string  | Raw 32-byte Notification Key, unpadded base64url. Generated on the device, per Host. |
| `env`            | string  | `production` or `sandbox`: which APNs environment the token belongs to, following the app build that registered it. |
| `notify.blocked` | boolean | Send a push when an Agent becomes Blocked. |
| `notify.done`    | boolean | Send a push when an Agent reaches Done. A missing flag means do not send (fail closed). |
| `live_activity`  | object  | Optional per-device Live Activity registration. Present while the app is showing this Host's activity. See [Activity hook](#activity-hook). |
| `live_activity.enabled` | boolean | FCM entries only: `true` opts the entry in to Live Updates sent to its own `token` (no per-activity token, no push-to-start; the relay body carries no counts or timestamp). Other `live_activity` fields on an FCM entry (`pinned_pane_ids`, `row_layout`, `host_name`) work as for APNs. An FCM entry whose push the relay reports dead (410) is removed whole. |
| `live_activity.token` | string | The per-activity APNs push token, lowercase hex. Distinct from the alert `token`. |
| `live_activity.started_at` | string | ISO 8601 timestamp the app wrote when it started (or rotated) the activity. Ignored by the hook; preserved on rewrite. |
| `live_activity.pinned_pane_ids` | string[] | Optional. Pane ids the device has pinned, most-recently-pinned first. Reorders Live Activity rows; does not change eligibility or counts. Missing, null, non-array, or any non-string entry is ignored (treated as empty). |
| `live_activity_start` | object | Optional push-to-start registration. Present while this device wants this Host's Live Activity; independent of `live_activity`. See [Activity hook](#activity-hook). |
| `live_activity_start.token` | string | The app install's push-to-start token for its activity type, lowercase hex. |
| `live_activity_start.host_id` | string | The app's random identifier for this Host (canonical UUID string), sent verbatim as the activity's `hostID` attribute. |

Readers ignore unknown fields (additive v1 metadata); breaking changes bump
`v`, honored by plugin and app together.

## Chat transcript reader (v1)

`waycar chat-read` reads a Chat Mode Agent's conversation from its harness's
own session transcript (ADR 0025) — or, for opencode, from the JSON its
`opencode export` prints, since opencode keeps no transcript file. The app
runs it over SSH with the plugin root as cwd:

```bash
bin/waycar chat-read --kind <kind> \
  [--session-kind id|path --session-value <v>] [--cwd <dir>] \
  [--launched-at <ISO8601>] [--status <agent_status>] \
  [--after <message id>] [--max-messages <n>]
bin/waycar chat-read --request -
```

`waycar chat-read` is the reader in the native binary, so a Host needs no
Node.js: the flags and `--request -` request above, NDJSON on stdout.

The app always uses `--request -`: it writes one JSON object to stdin with
the keys `kind`, `session_kind`, `session_value`, `cwd`, `launched_at`,
`status`, `after` and `max_messages` (each null or absent except `kind`), so
no Host-derived value is ever shell-quoted. `--request -` takes no other
flag. The flags stay for manual use.

It exits 0 whenever it can answer, including when no transcript is found
(the header says so), and 2 on bad arguments, a bad request or, for
`--request -`, a terminal on stdin, with usage on stderr. The module API is
the `chat/` module of the Rust crate (`rust/chat/`), which the plan-step
progress code reuses ([Agent Progress](#agent-progress)).

Output is NDJSON: a header first, then messages oldest to newest.

```json
{"type":"header","v":1,"kind":"claude","status":"ok","transcript":"/abs/path.jsonl","activity":"Running npm test","turn_open":true,"truncated":false,"after_found":true,"error":null}
{"type":"message","id":"<stable id>","role":"user","text":"why is CI red?","ts":"2026-09-30T12:00:01.123Z"}
{"type":"message","id":"<stable id>","role":"assistant","text":"The iPad suite times out ...","ts":"2026-09-30T12:00:40.000Z"}
```

| Field | Meaning |
| ----- | ------- |
| `status` | `ok`, `not_found` (no transcript located yet), `unsupported` (a kind without a reader: cursor, devin, kiro and any other) or `error` (unreadable; `error` carries the message). |
| `activity` | Short status line for the open turn, at most 100 characters, else null. |
| `turn_open` | The last user prompt has no final reply yet. |
| `truncated` | Older messages were dropped by `--max-messages` (default 200, newest kept). |
| `after_found` | `false` only when `--after` named an id the transcript no longer holds (the harness restarted or rewrote it): the messages are then the whole chat, and the app replaces what it shows. Otherwise `true`. The app also replaces its list when `transcript` changes. |
| `id` | Stable message id: claude record `uuid`; codex `u:`/`a:` plus the turn id or line; omp/pi message record `id`; opencode and kilo message `msg_…` id (a prompt is its user message's id, a reply its first text part's message's id); copilot event `id`; qwen record `uuid`; gemini message `id`; grok `_meta.eventId` of the message's first chunk; agy `step:<step_index>`; cline message `id`; hermes `message_uid`. |
| `media` | Only on a turn's final reply, omitted when empty: the images the Agent viewed with its tools during the turn (see [Turn images](#turn-images)). |

`--after <id>` emits only messages after that id, or all of them if the id is
unknown. Each text is capped at 20,000 characters.

### Turn images

A final reply carries the images its turn's tool results hold, as the
harness's own TUI shows them: omp/pi `toolResult` message `image` blocks,
claude `tool_result` image blocks with a base64 `source`, codex
`input_image` `data:` URLs (`view_image`'s synthesized user message made only
of images, or a `function_call_output`/`custom_tool_call_output` array), and
opencode and kilo `file` parts — the user's attachments (a TUI-attached file is
`data:<mime>;base64,<bytes>`, an @-mention or `run --attach` of a local file
is a `file://` URL) and a completed tool call's `state.attachments`. For the
other harnesses the only images in a transcript are the user's attachments,
and they ride the reply the same way: copilot `session.binary_asset` lines
named by the prompt's `attachments[].assetId`, gemini and qwen `inlineData`
prompt parts, cline `image` blocks (an item at offset 0 with a pointer into
its one-document transcript), and agy `media[].uri` files in the
conversation's own `brain/<id>/` directory (`path` items, only when they
exist there). grok and hermes record no image.
At most 12 per reply, in transcript order, deduped by blob id or, inline, by
the image's bytes (opencode: by the Host path or the attachment's bytes). An
open turn shows none until its reply. A tool-result or image-only user record
never starts a turn or shows as a prompt.

```json
{"type":"message","id":"…","role":"assistant","text":"…","ts":"…","media":[
 {"id":"blob:sha256:<hex>","kind":"image","mime":"image/webp","path":"/Users/x/.omp/agent/blobs/<hex>"},
 {"id":"inline:<offset>:<pointer>","kind":"image","mime":"image/png","inline":{"transcript":"/abs/session.jsonl","offset":123456,"pointer":"/message/content/1/content/0/source/data"}},
 {"id":"file:/Users/me/shot.png","kind":"file","mime":"image/png","path":"/Users/me/shot.png"},
 {"id":"inline:/messages/0/parts/1/url#prt_…","kind":"image","mime":"image/png","inline":{"session":"ses_…","pointer":"/messages/0/parts/1/url"}}]}
```

Each item has exactly one source. `path` is an omp/pi blob file
(`blob:sha256:<hex>` under the kind's root, `<root>/blobs/<hex>`), emitted
only when the file exists; the app reads it over SFTP. An opencode `file://`
attachment is also a `path` item, `kind: "file"`, with the URL's scheme
stripped to the Host path — but only when the file lives inside the
session's directory or the Agent's cwd; anything else is dropped, since
transcript content is agent-controlled and must not surface arbitrary Host
files as tappable attachments. `inline` names a base64 string: `offset` is
the byte offset where its JSONL line starts and `pointer` an RFC 6901 JSON
Pointer into that line's JSON (claude, codex, omp/pi); an opencode item
carries the `session` id instead and a pointer into that session's export
JSON, with the part's `prt_…` id riding in the item id after `#` — a
`/revert` can shift index pointers, so `waycar chat-media` re-checks that the
part under the pointer still has that id before decoding and refuses
(65) when it does not. `kind` is `image` (or `file` for a Host-path
attachment of any type;
`video` for a data: video). `mime` is the recorded type, else the `data:`
URL's, else sniffed from the base64 (png, jpeg, gif, webp), else null. An
opencode data: attachment of another type shows nothing.

The app reads an inline item with `waycar chat-media`:

```bash
bin/waycar chat-media --request -
```

with `{"transcript":"/abs/path.jsonl","offset":N,"pointer":"/…","max_bytes":N}`
on stdin (a transcript that is one pretty-printed JSON document, cline's,
is named at offset 0 and the pointer resolves into the whole file) — or, for
an opencode or kilo item,
`{"session":"ses_…","kind":"kilo","id":"<media item id>","pointer":"/…","max_bytes":N}`
(`kind` is the item's `inline.kind`; absent, it is opencode).
With a transcript it
reads the line at `offset` (refusing one over 64 MiB) and resolves the
pointer; with a session it re-runs `opencode export <session>`, checks the
part id carried in the item id against the part under the pointer, and
resolves the pointer into that JSON. Either way it decodes the base64 (a
`data:`
prefix stripped) and writes the raw bytes to stdout, exiting 0. It exits 65
when the transcript path is relative or not a regular file, the offset is not
a line start in the file, the pointer does not name a string, the string is
not base64, the part under the pointer is no longer the item's part, or the
export could not be produced (no `opencode` binary, a failed export); 66
when the decoded size is over `max_bytes`; 2 on bad arguments or a malformed
request. Errors and usage go to stderr.

`waycar chat-media` is the same reader in the native binary: same request,
same bytes on stdout, same exit codes (`waycar chat-media --request -`).

### Turn rules

- Messages are only real user prompts and the final assistant reply of each
  completed turn: the assistant text after the turn's last tool call, text
  blocks joined by a blank line. A completed turn with no final text emits
  the harness's error when it recorded one (codex `task_complete`'s
  `error.message`; omp/pi the turn's last `errorMessage`; claude an
  `isApiErrorMessage` record's text; opencode message info `error`'s
  `data.message`), else `"text":""`; an open turn emits
  its user message only. An omp/pi or opencode error is kept apart from the
  reply: an
  automatic retry reopens the turn and clears it, and it is never prepended
  to a retry's reply.
- A turn completes on, in order of precedence: a later real user prompt;
  `--status` idle or done; the harness's end marker (claude `stop_reason`
  `end_turn`/`stop_sequence`; codex `event_msg` `task_complete` or
  `turn_aborted`; omp/pi `stopReason` `stop`/`length`/`error`/`aborted`).
  `blocked`, `working` and `unknown` never complete a turn alone. For omp/pi
  an idle or done status does not complete a turn whose trailing branch item
  shows the run is still going (a trailing user prompt, a `toolResult`, or an
  assistant with `stopReason` `toolUse`); the end marker or a later prompt
  still does. opencode has no end-of-turn record at all: its turn completes
  on the reported status or a later prompt, with the same trailing rule (a
  trailing user prompt or an assistant message whose last step has not
  finished keeps the turn open), and message info `error` ends it like omp's
  error — a user abort (`MessageAbortedError`) quietly, any other recorded
  error as the reply until a retry replies. A codex turn that ends with no
  final text or error takes `task_complete`'s `last_agent_message`. Codex
  assistant messages with `phase` `commentary` are activity only, never the
  reply (`final_answer` or no phase counts).
- Prompts: claude user records; codex `event_msg` `user_message` and
  `item_completed` items of type `UserMessage` (a copy of the prompt just
  recorded for the same turn is dropped); omp/pi user messages whose
  `attribution`, when present, is `user`; and opencode user messages (their
  `text` parts joined, minus `synthetic` and `ignored` ones, which are
  opencode's own injections). A claude slash command
  (`<command-name>`/`<command-args>` user records) is the prompt
  `/name args`, trimmed, and starts a turn. A slash command the model never
  answered (a local command such as `/model`, `/compact` or `/clear`) emits
  no assistant message at all, not even `"text":""`.
- Steering: a prompt sent while a turn runs joins that turn instead of
  starting one, so the turn still ends in one reply. That is an omp/pi user
  message with `steering: true`, or whose branch parent is a `toolResult` or
  an assistant with `stopReason` `toolUse`; a claude `attachment` record of
  type `queued_command` (command mode `prompt`); and a codex prompt carrying
  the running turn's `turn_id`.
- Hidden prompts: a claude `<task-notification>` user message, or a
  `queued_command` in `task-notification` mode, is never shown. It starts a
  new turn only when the last one had ended, so that turn keeps its reply,
  and a turn nobody prompted shows only a non-empty reply.
- Filtering drops sidechain, meta, compact-summary, tool-result,
  `<local-command-stdout>` and `<local-command-caveat>` records,
  `<system-reminder>` text, and synthetic assistant records (`model`
  `<synthetic>` without `isApiErrorMessage`, e.g. "No response requested.")
  (claude); injected `<environment_context>`, `<user_instructions>`,
  `<INSTRUCTIONS>`, `<codex_internal…`, `<turn_aborted>` and AGENTS.md
  messages (codex); records off the current `parentId` branch plus
  `custom` records (omp/pi); and `synthetic`/`ignored` text parts, `agent`,
  `step-start`/`step-finish`, `snapshot`, `patch`, `retry`, `compaction` and
  any unknown part type (opencode, which instead turns a `subtask` part into
  tool activity, and drops an auto-compaction summary assistant message
  (`agent: "compaction"`, `summary: true`); the replayed prompt compaction
  writes after it is indistinguishable from a real prompt and shows as a
  duplicate bubble). A claude
  `[Request interrupted by user…` ends
  the open turn and is not emitted.
- Transcript location: `--session-kind path` is the file itself. By id:
  claude `$CLAUDE_CONFIG_DIR` (default `~/.claude`) `/projects/*/<id>.jsonl`;
  codex `$CODEX_HOME` (default `~/.codex`) `/sessions/**/rollout-*-<id>.jsonl`;
  pi `~/.pi/agent/sessions/*/*_<id>.jsonl` (or `PI_CODING_AGENT_DIR`); omp
  `~/.omp/agent/sessions/*/*_<id>.jsonl`. With no session, among the
  transcripts of the kind whose cwd equals `--cwd` and that were created at
  or after `--launched-at` minus 10 s, the one created closest to
  `--launched-at` (a tie goes to the earlier); otherwise `not_found`. codex
  and omp creation is the start their header records (`session_meta`, the
  omp `session` record), which is process start rather than the lazily
  written file, so a codex or omp transcript recording a start more than
  2 minutes after `--launched-at` belongs to a later Agent and never
  matches. claude's is its first record, which can come any time after the
  launch. The app then pins the path it was given into the pane's Chat
  Marker, so later reads and the reply push stay on that transcript; a live
  herdr `agent_session` still wins.

  The other harnesses' readers live in `rust/chat/readers/` (shared pieces in
  `rust/chat_shared.rs`), each verified against the lab captures in
  `docs/research/harnesses/<kind>.md`. By id, and with no session where the
  file records a cwd (closest start to `--launched-at`, as above):
  copilot `$COPILOT_HOME` (default `~/.copilot`)
  `/session-state/<id>/events.jsonl` (cwd and start from `session.start`);
  qwen `~/.qwen/projects/*/chats/<id>.jsonl` (cwd on every record); gemini
  `~/.gemini/tmp/*/chats/session-*-<first 8 hex of id>.jsonl` whose header
  names the id (no session: the header's `projectHash`, the sha256 of the
  cwd, and its `startTime`, a process start, so the 2-minute window applies;
  a `path` that gemini never wrote — its resume quirk — reads the newest
  file with the same 8 hex digits beside it); grok `$GROK_HOME` (default
  `~/.grok`) `/sessions/<percent-encoded cwd>/<id>/updates.jsonl`; agy
  `~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript_full.jsonl`
  (no cwd recorded: id or path only); cline
  `~/.cline/data/sessions/<id>/<id>.messages.json` (the `--data-dir` Waycar
  launches with; no session: the `<id>.json` manifest's `cwd` and
  `started_at`, with the 2-minute window); muse `${XDG_DATA_HOME:-~/.local/share}/muse`
  `/sessions/<YYYY>/<MM>/<DD>/<id>/session.jsonl` (no session: sessions
  from the days around the launch, the `runtime.session.metadata`
  workspace root and the first record's time; a subagent's session is
  skipped; attached images are its `asset` blocks). copilot, grok and qwen
  record their first prompt's time, so no window applies to them.

  None of them has an end-of-turn record except copilot (an
  `assistant.turn_end` whose round asked for no tool), grok
  (`turn_completed`), hermes (`finish_reason` `stop`/`length`; a
  `failed_turn` message ends an interrupted turn quietly), agy (a step
  with `status: "ERROR"`, a denied tool, ends the turn with its `error`)
  and muse (a run's `terminal` event, `completed` or an interrupted or
  failed turn); the others' turns complete on the status or a later prompt.

  opencode, kilo and hermes keep no transcript files: `--session-kind path`
  is `not_found`, and a session id — herdr's integration, the Status Hook's
  `@waycar_session`, or the marker's — names a chat. With no session the
  harness lists the sessions a launch could have started, and the launch
  match above picks one (closest creation to `--launched-at`, never before
  it minus 10 s, `cwd` equal to `--cwd`, no window): `opencode session list
  --format json --pure` / `kilo session list --format json --pure`, run in
  `--cwd` (they list that directory's project; `directory` and `created`
  per session), and hermes's `sessions list --limit 50` table (ids, whose
  `YYYYMMDD_HHMMSS` is the start in the Host's local time), each candidate
  then exported for its `cwd` and `started_at` (sessions with a
  `parent_session_id` or the `tool` source, an Agent Summary run, are left
  out; at most the 6 starting closest to the launch are exported per read).
  Since these kinds start a session at the first prompt, another Agent of
  the kind in the same cwd could have started any later one, so the match
  reads the Host's other Chat Markers: a session id another Agent names
  (its marker's pinned id, or its live pane's `@waycar_session` or herdr
  `agent_session`) is never taken, and the launches of the other live
  Agents that name none are matched oldest first, each taking its session
  only when it was created before the next launch minus 10 s; otherwise the
  chat is `not_found` (ambiguous) rather than another Agent's. A marker
  whose pane cannot be checked (tmux or herdr unreachable, named herdr
  sessions) counts as live. This is how a herdr pane without herdr's
  integration for the kind gets its chat; the app pins nothing for these
  kinds, so every read matches again. agy records no cwd its reader could match (only its SQLite
  conversation database does), so an agy chat needs a session: on herdr,
  herdr's agy integration. The opencode, kilo and hermes branch runs
  `opencode export <id>`, `kilo export <id>` (kilo 7.8.8: an opencode fork
  with the same export) or `hermes sessions export --format jsonl
  --session-id <id> -` (JSON on stdout, a progress line on stderr for
  opencode and kilo) once per read and parses its messages; the header's
  `transcript` is null. Only a well-formed id is exported (`ses_…` for
  opencode and kilo, `YYYYMMDD_HHMMSS_<6 hex>` for hermes) — anything else
  in the request or marker reads as `not_found`. The binary is resolved
  from `PATH`, then its install roots (`~/.opencode/bin`,
  `~/.npm-global/bin` for kilo, `~/.local/bin` for hermes, then
  `/usr/local/bin`); a failed
  export (no binary, an unknown session) is `not_found`, an export that
  prints no JSON is `error`. The opencode parser was verified against opencode
  **1.18.33** export output (`packages/opencode/src/cli/cmd/export.ts`,
  `packages/schema/src/v1/session.ts` at that tag), which is the version
  floor; a newer opencode that changes the shape degrades like any other
  drift — the chat keeps retrying until the plugin is updated. opencode
  names its models `provider/model` (its messages record `providerID` and
  `modelID`; Settings › Chat Mode passes `<provider>/<model>` on `-m`), and
  `export` reports only the requested session — subagent work appears inside
  it as `subtask` and tool parts, never as child-session messages.
- Activity is the open turn's newest item: a tool call as `Running <cmd>`,
  `Reading <file>`, `Editing <file>`, `Searching`, `Searching the web`,
  `Running a subagent` or `Using <tool>`; interim assistant text as its first
  line; otherwise `Thinking`.

### Shared test vectors

`test-vectors/chat-transcript-v1.json` holds synthetic transcripts and the
expected NDJSON, with the header's `transcript` nulled. The Rust tests read
each case through the chat reader with `sessionKind: "path"` — except opencode,
which has no transcript file: its cases hold the whole `opencode export`
answer as the single transcript line, and the tests feed it through a stub
`opencode` binary that is the only `PATH` entry, reading by the session id
the export carries. The Swift tests decode the expected lines. Media paths
depend on the test's temp dir, so
expected lines write the transcript path as `$TRANSCRIPT` and the kind's
root as `$ROOT`, substituted by the Rust tests (an opencode `file://`
attachment names a fixed stand-in path instead); a case's `blobs` lists the
blob files (`$ROOT/blobs/<hex>`) to create first.

## Chat Markers (v1)

A Chat Marker records that a pane was launched in Chat Mode, or, with
`"chat_mode":false`, a plain launch that pinned a session id. It lives at
`chat/<name>` inside this plugin's config directory, where `<name>` is the
unpadded base64url of the UTF-8 pane id plus `.json` (the `paneFileName`
rule in `rust/atomic.rs`).

```json
{"v":1,"pane_id":"w1:p1","terminal_id":"term_65cb...","kind":"claude","cwd":"/Users/me/proj","session":{"kind":"id","value":"0f4c..."},"launched_at":"2026-09-30T12:00:00Z","prompt":"Reply like a text."}
```

`prompt`, when present, is the Chat Prompt recorded at launch; the opencode
chat-prompt extension (`waycar-chat-prompt.js`, ADR 0025) reads it and
appends it to opencode's system messages. The extension finds this config
directory exactly as the app and the hooks do, through the plugin's
`waycar config-dir` command (herdr does not pass `HERDR_PLUGIN_CONFIG_DIR` to the
Agents it starts, so in a herdr pane that is `herdr plugin config-dir`),
once per opencode process; a failed resolution is retried at most every
30 s. It names the marker by its pane's app-side id: `HERDR_PANE_ID`, else
`tmux:` plus `TMUX_PANE`.

`terminal_id`, `cwd`, `session` and `prompt` may be null; `session.kind` is
`id` or `path`; `launched_at` is ISO 8601 UTC, with or without fractional
seconds. `chat_mode` is optional: absent or not a boolean reads as `true`
(a Chat Mode marker). A `chat_mode: false` marker records only the plain
launch's pinned `session` (`{"kind":"id","value":"<uuid>"}`, `prompt` null);
the notify hook treats it as no marker (the push carries a summary, never a
reply), and garbage collection removes it like any other.

- **Writes**: the app, atomically with mode 0600, right after `agent.start`
  succeeds for a Chat Mode New Agent or a Closed Session resume of one (or,
  with `chat_mode: false`, for a plain launch that pins a session id), and
  again with `session` set to `{"kind":"path","value":"<transcript>"}` once
  a read without a session located the transcript (the binding is sticky
  from then on).
- **Reads**: every device, so Chat Mode follows the Agent across devices (a
  marker applies only while its pane id and kind match a live Agent and
  either its `terminal_id` is null or matches, or its `session` has the same
  kind and value as the Agent's live `agent_session`, which is how a chat
  that herdr restored in a new terminal is recognized), and the notify hook
  for reply pushes.
- **Deletes**: the app retires a marker when its chat Agent closes. The
  notify hook also collects leftovers on every run, before any early return,
  at most once an hour per Host (the last run's time is kept in
  `chat-marker-gc.json` in the plugin state dir) and only when markers
  exist: it fetches `herdr agent list` and deletes markers whose `pane_id`
  the list does not show. A marker launched in the last 10 minutes is kept,
  since a list fetched just before the launch cannot show its pane, and so
  is any file this version cannot read. A `tmux:%N` marker (the tmux
  transport writes its markers into the same `chat/` dir) is live while its
  tmux pane exists: with `tmux_enabled` on, the hook lists every tmux pane
  (`tmux -u list-panes -a`, not only panes with Waycar's hook options, so a
  screen-detected Agent keeps its marker) and deletes `tmux:` markers whose
  pane is gone. While tmux is disabled or cannot be listed, no `tmux:`
  marker is deleted. A failed collection never affects the hook.
- **Named sessions**: markers are keyed by pane id in a config dir that
  every herdr session on the machine shares, and pane ids collide across
  sessions. So while any named session exists (a
  `$XDG_CONFIG_HOME/herdr/sessions/*/herdr.sock`, default
  `~/.config/herdr/sessions`), the hook deletes nothing and logs that once
  per run, and a marker from one session can make Chat Mode apply to the
  same pane id in another when its kind and `terminal_id` also match.

## Reply push

When a Done push goes to a pane with a Chat Marker, the notify hook skips
the Agent Summary and sends the Agent's final reply as the plaintext `reply`
field instead:

1. A marker whose `kind` differs from the event's agent changes nothing.
   Otherwise the summary is not generated alongside the debounce.
2. After the re-check, the marker must apply to the Agent on the pane: the
   `herdr agent get <pane>` answer has the same `agent` kind, and either the
   marker's `terminal_id` is null or equals the Agent's `terminal_id`, or the
   marker's `session` has the same kind and value as the Agent's live
   `agent_session` (a chat restored or resumed in a new terminal).
3. The reader runs in-process (`readChat` with `status: "done"`). The session
   is the live `agent_session` (it follows `/clear`), else the marker's; cwd
   is the Agent's, else the marker's; `launched_at` comes from the marker.
   `lastReply` is the reply.
4. The text is normalized: CRLF to LF, C0 controls other than `\n` and `\t`
   stripped, lone surrogates replaced with U+FFFD, and trimmed. It is capped
   at 1,000 bytes on a grapheme boundary, ending in `…` when cut, where each
   grapheme costs its JSON-escaped UTF-8 size (a `"` costs 2).
5. If the sealed envelope's `ct` would exceed 2,800 bytes (the activity
   hook's budget, leaving room under the relay's 4,096-byte APNs payload
   cap), it is re-sealed with the reply capped at 500 bytes, and if that is
   still too big, without the reply.

With summaries on, a reply push still stores a tombstone in the summary
store, retiring the previous turn's summary. If the marker does not apply,
or the reader finds no transcript, fails, returns an empty reply, or the
turn is still open (`turn_open`: its newest reply answers an earlier
prompt), the push is built as for any other Agent. With summaries on, the
summary is generated then within what is left of `summary_timeout_ms` from
the event, and the status is re-checked once more before pushing.

## Sidebar layout snapshot (v1)

`waycar herdr-startup` runs through `[[startup]]` at server start and live
handoff. It needs only `HERDR_PLUGIN_CONFIG_DIR`; startup has no
`HERDR_PLUGIN_EVENT_JSON`. Startup hooks are supported by herdr 0.7.5, so the
minimum herdr version stays 0.7.5.

The hook reads the config using the server environment inherited by plugin
processes, in this order:

1. `HERDR_CONFIG_PATH`, when set, is the exact source path.
2. Otherwise, `XDG_CONFIG_HOME/herdr/config.toml`, when `XDG_CONFIG_HOME` is set.
3. Otherwise, `HOME/.config/herdr/config.toml` (the system temporary directory
   replaces `HOME/.config` when `HOME` is unset).

Named sessions share this source; they do not add a session directory to its
path. The plugin parses TOML with `smol-toml`, validates the sidebar agent
layout and sort, then writes **`HERDR_PLUGIN_CONFIG_DIR/sidebar.json`**, next
to `notify.json`. It never writes this snapshot to `HERDR_PLUGIN_STATE_DIR`.
Writes use an exclusive mode **0600** temporary file followed by atomic rename;
a newly created plugin config directory has mode **0700**.

```json
{
  "v": 1,
  "generated_at": 1757040000,
  "source": {
    "path": "/home/u/.config/herdr/config.toml",
    "found": true,
    "mtime_ms": 1757039000123
  },
  "agent_panel_sort": "priority",
  "sidebar": {"agents": {
    "row_gap": 0,
    "rows": [
      [{"token":"state_icon"},{"token":"terminal_title_stripped","fg":"#6c7086","dim":false}],
      [{"token":"$pin_icon"},{"token":"workspace","dim":true},{"token":"agent"}]
    ],
    "rows_by_agent": {"claude":[[{"token":"terminal_title_stripped"}]]}
  }},
  "diagnostics": []
}
```

| Field | Type | Meaning |
| ----- | ---- | ------- |
| `v` | integer | Snapshot version, currently `1`. Swift treats any other version as absent. |
| `generated_at` | integer | Unix seconds when the snapshot was written. Unchanged sources retain their previous snapshot and timestamp. |
| `source.path` | string | Resolved herdr config path. |
| `source.found` | boolean | Whether the source was found. Missing source is `false`; a source that can be statted but cannot be read is `true` with a diagnostic. |
| `source.mtime_ms` | number or null | Source `mtimeMs`, including fractional milliseconds; `null` when the source cannot be statted. |
| `agent_panel_sort` | string | `spaces` (default) or `priority`; the input alias `workspaces` normalizes to `spaces`. Waycar ignores it and always lists Agents by Agent Status; older app builds read it. |
| `sidebar.agents.row_gap` | integer | `0..65535`, default `0`. herdr's blank terminal rows between Agent entries, not between lines of one entry. |
| `sidebar.agents.rows` | token[][] | Whole default layout, at most 16 rows and 16 tokens per row. Empty layouts and rows are valid. |
| `sidebar.agents.rows_by_agent` | object | Canonical Agent id to whole replacement rows; default `{}`. Unlisted Agents use `rows`. |
| `diagnostics` | string[] | Empty on success or a missing source. Otherwise `parse_error`, `invalid_token`, `invalid_schema`, or `read_error`. Raw config values and parser excerpts are never included. |

Every token is an object, including TOML string tokens. Builtins are
`state_icon`, `state_text`, `workspace`, `tab`, `pane`, `agent`,
`terminal_title`, and `terminal_title_stripped`. Custom names must match
`^\$[A-Za-z0-9_-]{1,32}$` and retain their `$` in the snapshot. A styled TOML
table accepts only `token`, `fg`, `bold`, and `dim`: `fg` must be `#RGB` or
`#RRGGBB`; `bold` and `dim` must be booleans. Optional style fields appear
only when explicitly provided, preserving `false` and the original hex case.
Other config fields are ignored. This is validation of the exported subset,
not a substitute for `herdr config check` for unrelated herdr settings.

`rows_by_agent` accepts the canonical ids verified against herdr v0.9.0:
`pi`, `claude`, `codex`, `gemini`, `cursor`, `devin`, `agy`, `cline`, `omp`,
`mastracode`, `opencode`, `copilot`, `kimi`, `kiro`, `droid`, `amp`, `grok`,
`hermes`, `kilo`, `qodercli`, `qwen`, `maki`, and `muse`. Aliases, case
variations, and unknown ids are invalid. A future herdr release adding
canonical ids requires updating this validation list and the shared vectors.

Missing files or fields use herdr defaults: sort `spaces`, `row_gap: 0`,
`rows: [[{"token":"state_icon"},{"token":"workspace"},{"token":"tab"}],
[{"token":"agent"}]]`, and `rows_by_agent: {}`. TOML parse errors, invalid
tokens, or invalid schema revert the **entire layout and sort** to those
defaults with a diagnostic. Read errors also produce defaults with a
diagnostic and are retried at the next invocation.

Both `waycar herdr-event notify` and `activity` refresh at the beginning of
`main()`, before debounce, dedupe, or no-device exits. An unchanged source
path, existence, and `mtimeMs` reuses the snapshot without reparsing or
rewriting. A missing/corrupt snapshot is rebuilt. Changes that preserve the
source mtime are not detected. Snapshot write failures are logged but do not
prevent the event hooks from delivering notifications.

There is no watcher and config reload does not run startup hooks. A config
edit with no Agent Status transition is picked up at the next transition or
server start. The snapshot reflects the file on disk, not any live TUI
`agent.view.set` sort override. Waycar never installs or updates this plugin;
older installations have no `sidebar.json`, which the app treats as nil
without a version gate.

Swift readers ignore unknown fields and drop individual unknown token names.
The app resolves whole layouts in this order: the Host's saved user layout,
the Host's plugin snapshot, Waycar default. There is no global user layout,
and the default is never offered as a choice. Rows are never merged across
sources. Its renderer skips `state_icon` and `state_text` because the status
column already shows Agent Status; `$name` resolves as plain text from
`AgentInfo.tokens["name"]`. Waycar's Pin is independent. Styles are retained
in the Swift model; rendering may ignore them (color is ignored by default).

### Shared test vectors

`test-vectors/sidebar-layout-v1.json` is shared by the Rust parser tests and
the Swift snapshot decoder tests, and registered as a `WaycarTests` resource.
Its `valid` and `invalid` arrays contain `name`, `toml`, and a full expected
`snapshot`; invalid entries also contain the expected `error` diagnostic.
The Rust test asserts normalized layout equality and whole-layout fallback. Swift
consumes the structured snapshots to assert decoded layout, defaults, and
diagnostics; it does not parse TOML. Change the contract and vectors together.

## Notify hook

The manifest `[[events]]` hook on `pane.agent_status_changed` runs
`waycar herdr-event notify` as one short-lived process per Agent Status transition;
there is no long-running watcher. Only **Blocked** and **Done** notify, and
only for devices whose registration entry sets the matching `notify` flag.

Anti-noise, in order:

1. **Debounce**: the script sleeps ~5 s, re-checks the pane's current status
   through `HERDR_BIN_PATH` (`herdr agent get <pane>`), and aborts if the
   status moved on (or the agent is gone). With [Agent Summaries](#agent-summary)
   on, a Blocked or Done event first also waits for its summary (at most
   `summary_timeout_ms` from the event), so the re-check happens after both
   and a notification can arrive up to that long after the transition.
   A push that goes out also carries the Host's `attention` count from a
   fresh `herdr agent list`; a list that fails only omits the count. Every
   run, push or not, may first fetch the list for hourly
   [Chat Marker](#chat-markers-v1) garbage collection. A Done push for a
   Chat Mode pane carries the [reply](#reply-push) instead of a summary.
2. **Dedupe**: the last notified status is recorded per pane under
   `HERDR_PLUGIN_STATE_DIR/notify/`; a same-status repeat sends nothing. A
   *different* status that survives its own debounce re-arms the pane.

Each eligible device gets one `POST https://waycar-apns.otreva.com/push` by
default (see `relay/README.md`), carrying the encrypted envelope and an opaque
per-pane `collapse` key (derived from the device's Notification Key and the
pane id, so the relay cannot guess the pane while newer statuses still replace
older notifications). Transient failures (network errors, 429, 5xx) are
retried up to 3 attempts; a `410 Unregistered` verdict prunes that token from
`notifications.json` (preserving any fields this plugin does not understand);
other 4xx verdicts are final.

Plugin-side settings live in `notify.json` next to the registration file in
the plugin config dir:

| Field            | Type    | Meaning |
| ---------------- | ------- | ------- |
| `relay_url`      | string  | Optional Push Relay base URL override for a self-built app. Defaults to `https://waycar-apns.otreva.com`; the app writes the resolved value during Notification Registration. |
| `debounce_ms`    | integer | Debounce sleep override for the alert notify hook. Default 5000. |
| `activity_debounce_ms` | integer | Latest-wins debounce sleep for the Live Activity hook. Default 1500. |
| `activity_start_grace_ms` | integer | How long the Live Activity hook waits before a push-to-start, so an open app can start and register its own activity first. Default 8000. |
| `retry_delay_ms` | integer | Delay between retry attempts. Default 1000. |
| `summary_enabled` | boolean | Whether Agents get an [Agent Summary](#agent-summary) (the refresh action and Blocked/Done events). Only a JSON `true` turns it on; absent means off. The app writes it explicitly (preserving the other fields) from its **AI Summaries** setting in Settings, which is off until the user turns it on and confirms the providers. |
| `summary_command` | array of strings | Optional argv that replaces provider auto-detection (see [Agent Summary](#agent-summary)). A value that is not an array of strings with a non-empty program is ignored. |
| `summary_timeout_ms` | integer | Total budget for one Agent Summary: counted from the status event in the notify hook (it runs alongside the debounce), and per Agent in the refresh action. The harness is killed (or the request aborted) when it expires; the push then goes out without a summary, and until then it waits for it. Default 15000. |
| `tmux_enabled` | boolean | Whether tmux panes count and notify on this Host. Only a JSON `false` turns it off; absent means on. The app writes it from the Host's tmux toggle. |
| `core_enabled` | boolean | Whether herdr-core terminals count and notify on this Host. Only a JSON `false` turns it off; absent means on. For a Host that has the herdr TUI and herdr-core together and uses the TUI; the Host Tools only read it. |
| `codex_enabled` | boolean | Whether shared-daemon Codex threads notify. Only a JSON `false` turns it off; absent means on. Embedded Codex pane hooks are unaffected. |
| `opencode_enabled` | boolean | Whether OpenCode 2 server sessions notify (`opencode:<sessionID>`). Only a JSON `false` turns it off; absent means on. OpenCode 1 pane hooks are unaffected. |

### Hook event JSON (verified against herdr 0.7.5)

`HERDR_PLUGIN_EVENT_JSON` as captured empirically from a live herdr 0.7.5
event hook invocation — note the `event` value is snake_case on the wire even
though the manifest subscribes to the dot name:

```json
{"event":"pane_agent_status_changed",
 "data":{"type":"pane_agent_status_changed","pane_id":"wV:p1",
         "workspace_id":"wV","agent_status":"blocked","agent":"claude"}}
```

`agent` (plus `title`, `display_agent`, `state_labels` per herdr source) is
optional. herdr's wire shapes carry no stability guarantee, so the hook parses
leniently: it requires only `data.pane_id` and `data.agent_status` and ignores
everything it does not recognize.

## Agent Summary

With `summary_enabled` on, each Agent gets an **Agent Summary**: one plain
sentence of at most 100 characters on what it is doing (Working, e.g.
`Adding backoff to webhook retries; writing 5xx tests`) or where it ended up
(Idle: its last result and that it waits; Done: what it finished; Blocked:
what the user must decide or do). The app's agent cards show it, and a
Blocked or Done push carries it (`summary` in the notification plaintext).
Working and Blocked entries may also carry the Agent's **Agent Progress**
(see [Agent Progress](#agent-progress)).

Two things write summaries, with the same generator, prompt, and cap:

- **The `refresh-summaries` action**, which the app invokes about once a
  minute while it is open (see below).
- **The notify hook**, on each Blocked or Done event (see
  [Notify hook](#notify-hook) and the numbered steps below).

### Refresh action

The app runs, over its SSH exec channel, for each connected Host:

```sh
herdr plugin action invoke refresh-summaries --plugin waycar
```

The action id comes **before** `--plugin` (herdr 0.9.1 rejects
`--plugin waycar refresh-summaries` with exit 2, `unknown option`);
`herdr plugin action invoke waycar.refresh-summaries` is equivalent.
Verified on herdr 0.9.1, the call is fire-and-forget: it exits 0 about as
soon as herdr has spawned the action (JSON `plugin_action_invoked` on stdout)
and does not report the action's own exit status (see `herdr plugin log list
--plugin waycar`). It exits 1 with `plugin_action_not_found` on stderr when
the installed plugin predates the action, and `plugin_not_found` without the
plugin. herdr 0.9.1 treats an action's `contexts` as metadata only, so the
action also shows in herdr's action list; running it by hand is a harmless
refresh. The action runs `waycar summaries refresh` (`./bin/waycar`: herdr
0.7.5 and 0.8.2 fail an action command with a bare `bin/waycar`). One run:

1. Exits (deleting the store) when `summary_enabled` is off.
2. Takes a single-flight lock, `HERDR_PLUGIN_CONFIG_DIR/refresh-summaries.lock`
   (`{"pid":…,"ts":…}`; taken over only when its process is gone or it is
   older than 240 s, beyond the 180 s deadline that bounds every run; a run
   removes the lock only while it still holds its pid), and exits when the
   previous run finished less than 10 s ago (`refresh-summaries-last.json`):
   several devices, and each device's ticks, share one Host.
3. Lists Agents with `herdr agent list` (plus tmux Agents), skipping entries
   without an agent kind. For a Working Agent it first reads its plan steps
   from its transcript (see [Agent Progress](#agent-progress)), within their
   own 10 s budget, then reads each screen as below.
4. Hashes the normalized screen (sha256) with spinner glyphs dropped and
   every digit run collapsed, so ticking timers and token/cost counters do
   not change it; the model still gets the real screen. An Agent whose
   stored entry has the same hash and status, and a summary, is skipped:
   **no model call**. A skipped Working Agent gets its entry's `progress`
   refreshed from the steps just read (a `3/7` → `4/7` change alone keeps
   the hash), keeping its summary, `ts`, hash, and phase; `progress_ts`
   moves to now when steps are involved (an Agent with only a phase keeps
   the age of the answer that named it). A plan that could not be read (a
   timeout, an unreadable transcript, a failed `opencode export`) changes
   nothing.
5. Summarizes the rest, at most 3 at a time, each within
   `summary_timeout_ms` (and the run's 180 s deadline), and writes
   `{status, summary, ts, hash, progress}`. No
   answer leaves the entry alone, so the next run tries again.

It prints its outcome as one JSON line, e.g.
`{"ran":true,"agents":28,"summarized":6,"skipped":22}` or
`{"ran":false,"reason":"too-soon"}`.

### Generating a summary

1. The screen is read with
   `herdr pane read <pane> --source recent --lines 60` (an alternate-screen
   TUI yields its visible screen), stripped of escape sequences and trimmed.
   The Agent's own pane is only read, never typed into or prompted.
2. `summary_command`, when set, wins outright: your argv gets the
   status-specific instruction as its **last argument** and the screen on
   **stdin** (e.g. `["llm", "-m", "gpt-4o-mini"]`); nothing else is tried
   when it fails. The Working instruction also asks for a second line,
   `Phase: exploring|implementing|verifying|wrapping_up`; a command that
   answers without it just gives no phase. Otherwise the first available
   provider answers, falling through to the next one on any failure:
   1. **Anthropic, cheapest model.**
      - `claude -p --model haiku` — `claude` on PATH, and `claude auth status`
        reports `"loggedIn": true` (or `ANTHROPIC_API_KEY` is set);
      - `omp -p --model anthropic/claude-haiku-4-5 --thinking=off` — `omp` on
        PATH, and `omp token anthropic --list` exits 0 (or
        `ANTHROPIC_API_KEY`/`ANTHROPIC_OAUTH_TOKEN` is set).
   2. **OpenAI, cheapest model.**
      - `omp -p --model openai-codex/gpt-6-luna --thinking=low` — `omp token
        openai-codex --list` exits 0;
      - `codex exec … -m gpt-6-luna -c model_reasoning_effort="low" -` — `codex
        login status` exits 0 (`gpt-5-nano` when its status, printed on
        stderr, names an API-key login), prompt on
        stdin;
      - the OpenAI Responses API over HTTPS (`gpt-5-nano`, minimal reasoning)
        — `OPENAI_API_KEY` is set.
   3. **OpenRouter** over HTTPS (`google/gemini-2.5-flash-lite`, then
      `openai/gpt-6-luna`; 60 tokens, temperature 0.2) — `OPENROUTER_API_KEY`
      is set.
   4. **Any other installed harness**, on the user's own login and its
      default model (whatever that costs), in this order:
      - `pi -p` — `pi` on PATH, a `defaultProvider` in
        `~/.pi/agent/settings.json` (or `PI_CODING_AGENT_DIR`), and
        `pi auth check --provider <it> --no-refresh` reports `ready`;
      - `qwen` (one-shot positional prompt) — `qwen` on PATH and
        `~/.qwen/settings.json` names an auth type other than the ended
        `qwen-oauth` tier;
      - `gemini -p` — `gemini` on PATH and `GEMINI_API_KEY` set or an auth
        type in `~/.gemini/settings.json`;
      - `copilot` (prompt on stdin) — `copilot` on PATH and BYOK
        (`COPILOT_PROVIDER_BASE_URL`) or a token (`COPILOT_GITHUB_TOKEN`,
        `GH_TOKEN`, `GITHUB_TOKEN`) in the environment; a `copilot login`
        stored elsewhere is not detected;
      - `opencode run` / `kilo run` — on PATH with a `model` or `provider`
        in `opencode.json`/`kilo.json` or a stored credential in the data
        dir's `auth.json` (kilo without either would answer through its
        anonymous gateway, not the user's account);
      - `hermes chat --oneshot` — `hermes` on PATH and a `provider:` under
        `model:` in `~/.hermes/config.yaml`;
      - `muse exec` (prompt in a file) — `muse` on PATH and `META_API_KEY`
        set or a provider in `${XDG_CONFIG_HOME:-~/.config}/muse/auth.json`
        (`muse auth set`, `muse login`).

      Detection reads local files and runs no networked command. grok, agy
      and cline are not providers: their headless modes keep a shell tool
      the model can run (grok kept `run_terminal_command` under `--tools`,
      `--disallowed-tools` and `--permission-mode plan` and ran it; cline
      auto-approves and ran it; agy offers web tools no flag removes — all
      live, 2026-10-12), and cursor, devin and kiro need accounts.

   Which providers exist is probed once (in parallel, 5 s each) and cached
   for an hour in `HERDR_PLUGIN_CONFIG_DIR/summary-provider.json`
   (`{"v":1,"ts":…,"provider":"<first>"|"none","providers":[…]}`; `none` means
   this Host has no way to summarize). Delete the file to re-probe sooner.
   The omp harnesses also get a config overlay
   (`HERDR_PLUGIN_STATE_DIR/agent-summary-omp.yml`) turning off memory recall
   and WATCHDOG advisors, each of which turns a ~1.5 s call into 12–30 s.
   Harnesses run with `HERDR_*` variables removed from their environment and
   the usual per-user and Homebrew bin directories appended to `PATH` (herdr
   launched by launchd has only `/usr/bin:/bin:/usr/sbin:/sbin`), in their
   own process group, stdin fed and closed (omp hangs on an open one), from
   the dedicated empty directory `HERDR_PLUGIN_STATE_DIR/summary-cwd` (mode
   **0700**; see [Hardening](#hardening)). The API keys are read from the
   environment herdr gives the plugin.
3. The first non-empty line of the answer becomes the summary, minus progress
   chatter (`Working...`), the `Phase:` line, markdown decoration, a leading
   `Done:`/`Working:` style label, wrapping quotes, and a trailing period,
   capped at **100 graphemes** (an ellipsis marks a cut). Titles and the
   other push display fields keep their 80. For a Working Agent, a
   `Phase: <phase>` line naming one of the four phases becomes the entry's
   `progress.phase`; anything else gives none.
4. The notify hook waits for the summary and the debounce sleep together,
   killing the harness's process group `summary_timeout_ms` after the event,
   and only then re-checks the status. A status that moved on meanwhile —
   while the model was still answering, too — pushes nothing, stores
   nothing, and leaves the pane's dedupe state alone. Any failure — no
   provider, a non-zero exit, empty output, a timeout — sends the
   notification without a summary. The entry it stores carries the screen's
   hash, so the next refresh skips that screen.

### Cost

Only a changed screen costs a model call. Idle, Done, and Blocked Agents
sitting still cost nothing after their first summary; each Working Agent
whose screen moved costs about one small call a minute while the app is
open, and the app invokes nothing while it is closed. Each Blocked or Done
event the notify hook receives costs one call too, before the debounce
decides anything: an event the re-check then drops (a status flap) and a
repeat of an already-notified status each cost one. Calls go to the cheapest
model of the first available provider and bill that account (subscription
or API key). A slow or hung model delays a status's notification by up to
`summary_timeout_ms` (default 15 s) after the event, instead of the ~5 s
debounce.

### Hardening

The screen is untrusted input (web pages, repository files, CI logs the Agent
printed), and the harness CLIs treat their working directory as a project whose
config they load. So the harness never sees ambient capabilities:

- it runs from `summary-cwd`, an empty directory only the Host user can
  enter, never a shared temp dir where another local account could plant
  `.omp/`, `mcp.json`, or `.claude/settings.json`;
- its environment names no pane or session: the hook's own minus herdr's
  `HERDR_*` variables, `TMUX`/`TMUX_PANE`, and the session, hook and Chat
  Mode variables the Agent's harness set (`CLAUDECODE`, `CLAUDE_PID`,
  `GEMINI_SESSION_ID`, `GEMINI_CLI_NO_RELAUNCH`, `HERMES_SESSION_ID`,
  `HERMES_EPHEMERAL_SYSTEM_PROMPT`, `COPILOT_CUSTOM_INSTRUCTIONS_DIRS`, …;
  `AGENT_SESSION_ENV` in `rust/summary/agent.rs`), plus `WAYCAR_SUMMARY=1`.
  So a harness whose own hooks still load (gemini, hermes, copilot) cannot
  report the summary call as the Agent: Waycar's Status Hooks and
  extensions find no pane, and do nothing under `WAYCAR_SUMMARY` anyway;
- omp runs with `--no-tools` and `--approval-mode=always-ask` (print mode
  cannot approve a tool), and its overlay sets `mcp.enableProjectConfig:
  false` and lists every omp discovery source in `disabledProviders`, so no
  MCP server, context file, plugin, or hook loads — the user's own
  `disabledProviders` list does not apply to this call, and the model is
  pinned;
- claude runs with `--tools ""`, `--setting-sources user` (no project or
  local settings, hooks, or env), `--strict-mcp-config` (no MCP servers),
  and `--disallowedTools "mcp__*"`;
- codex runs `exec --ephemeral --ignore-user-config --ignore-rules -s
  read-only` with `approval_policy="never"`, history and web search off,
  and the shell tools disabled, with its answer written to a private file
  under `HERDR_PLUGIN_STATE_DIR` (`-o`) and removed afterwards.
- the other harnesses were each checked live against a mock model that
  calls any shell tool it is offered (2026-10-12): pi runs `--no-tools
  --no-session --no-extensions --no-mcp --no-skills --no-prompt-templates
  --no-themes --no-context-files --no-approve --offline` (no tools sent);
  qwen `--safe-mode --chat-recording=false --approval-mode plan
  --max-tool-calls 0` (it still offers read-only tools, but any tool call
  aborts the run, exit 55, before it executes); gemini `-e none
  --approval-mode plan` with a policy file under `HERDR_PLUGIN_STATE_DIR`
  denying every tool (no tools sent); copilot `--available-tools=none
  --no-custom-instructions --disable-builtin-mcps --no-ask-user` under a
  fresh `--session-id`, whose session directory is removed afterwards (no
  tools sent); opencode and kilo `run --pure --agent build|code` with
  `OPENCODE_CONFIG_CONTENT`/`KILO_CONFIG_CONTENT` switching every tool off
  in that agent and sharing off (no tools sent); hermes `--ignore-rules -t
  clarify --source tool` (only the clarifying-question tool, which a
  one-shot run cannot use; the session is kept out of the user's lists);
  muse `exec --no-session-log -c run.toolset=[] -c run.reminder_roster={}
  --disable-shell --disable-write --disable-web-tools --max-model-steps 1`
  (muse.md: no tools sent, no observer agent, nothing recorded).
  gemini, opencode, kilo and hermes still record the call as a session of
  the `summary-cwd` project.

A provider that cannot be prepared (say, the omp overlay cannot be written)
is skipped, and the next one is tried.

### Agent Progress

How far along a Working Agent is: the steps done of its own plan in its
current turn, else the coarse phase the summary model named. There is no
percentage and no time estimate.

**Plan steps** come from the Agent's transcript on this Host, read with the
Chat transcript reader's locators and parsers (`rust/plan_progress.rs`), so
turns split exactly as in Chat Mode. Nothing is sent to a model. The plan
counts only when it was written in the current turn (after the turn's
prompt; a message typed while the Agent works joins the running turn) and
that turn is still open:

| Agent | Plan source |
|---|---|
| omp | `todo` tool result `details.phases[].tasks[]` (a full list after every change; a `view` is not a write) |
| codex | `update_plan` call `{"plan":[{"step","status"}]}` |
| opencode | `todowrite` tool part `state.input.todos` (from `opencode export`) |
| claude | `TaskCreate` (id from its result, `Task #N created…`) and `TaskUpdate {taskId,status}`, replayed; older `TodoWrite {todos}` |
| pi | task extension `TaskCreate` / `TaskUpdate`, replayed as for claude |
| gemini, others | none |

`done` counts `completed` steps and `total` every step except cancelled or
deleted ones. Lists that outlive a turn leave out the steps earlier turns
finished: omp's `todo` list (unless the turn starts a new one with `init`)
and the replayed tasks. A plan with no steps or more than 99 has no steps.
The transcript is found through herdr's `agent_session` (`agent list`) or a
tmux pane's `@waycar_session` (an absolute value is a path, anything else
an id) or `@waycar_transcript`, else, as in Chat Mode, through the pane's
[Chat Marker](#chat-markers-v1) when it applies to the Agent; an Agent with
none of these has no steps. A read that times out or fails — including an
`opencode export` that exits non-zero for any reason other than "Session
not found" — tells the caller so (`PLAN_UNREADABLE`) instead of "no plan",
and nothing stored changes; an aborted read closes the transcript and kills
`opencode export`.

**Phase** is the Working summary call's second line (above): `exploring`
(reading, searching, planning), `implementing` (editing or writing code),
`verifying` (running builds or tests, reviewing diffs), or `wrapping_up`
(the final report, committing or pushing). Within a turn it only moves
forward: a Working entry never lowers the phase of the stored Working or
Blocked entry (an approval asked mid-turn does not end the turn); only an
Idle or Done turn end resets it.

Both need summaries on: they ride the summary store and its refresh.

### Summary store (v1)

`HERDR_PLUGIN_CONFIG_DIR/summaries/` holds one file per pane, named by the
unpadded base64url of the UTF-8 pane id plus `.json`. Each holds one JSON line:

```json
{"v":1,"pane":"wV:p1","status":"working","summary":"Adding backoff to webhook retries; writing 5xx tests","ts":1753305600123,"hash":"9f86d0…","progress":{"done":3,"total":7,"phase":"verifying"},"progress_ts":1753305660123}
```

`status` is the Agent's status when its screen was read (`working`, `idle`,
`done`, or `blocked`), `ts` its unix-milliseconds, and `hash` the sha256 (hex)
of the normalized screen the summary describes (`null` when unreadable; the
app ignores it). An entry is never replaced by one with an older `ts`, so
out-of-order writers cannot regress it. A confirmed Blocked or Done turn
that got no summary still writes its entry, with `"summary":null`: that
tombstone replaces the previous turn's entry, so an older summary never
labels the new turn, and the app shows no summary for it. Files are written
with mode **0600** through a temporary `<name>.json.tmp-<pid>` file and an
atomic rename (a `*.json` glob never sees a partial file), in a directory
created with mode **0700**. Every hook and refresh run first prunes files not
modified for 7 days; with `summary_enabled` off it deletes the whole
directory instead. The app treats an entry whose `status` no longer matches
the Agent's as stale. It reads the whole directory in one SSH exec as
newline-separated JSON and ignores lines it cannot parse or that carry no
summary text; a missing directory means no summaries.

Every entry with a summary names `progress`: the estimate, or `null` when
there is none. The key itself marks a plugin that writes progress (the app
shows a pending rail only for such Hosts); older plugins never write it, and
tombstones carry neither key (the store stays `v` 1):

| Key | Meaning |
|---|---|
| `progress.done`, `progress.total` | Plan steps done and in all ([Agent Progress](#agent-progress)): integers, both or neither, `0 ≤ done ≤ total`, `1 ≤ total ≤ 99`. A reader ignores an invalid pair and keeps the phase. |
| `progress.phase` | `exploring`, `implementing`, `verifying`, or `wrapping_up`. A reader ignores any other value and keeps the steps. |
| `progress_ts` | Unix ms when the progress was last refreshed: `ts` when written with the summary, later when a refresh re-read plan steps (`ts` never moves then, so the summary text keeps its own age). It moves only when the stored or new progress has steps; a phase-only progress keeps the stamp of the answer that named the phase. A reader judges the progress's freshness by `progress_ts`, else `ts`, and ignores it without a valid `progress`. |

Only an entry with a summary carries an estimate (never a tombstone), and
only for `working` or `blocked`: an `idle` or `done` entry has `null`, so
the next turn starts with none, and the activity hook clears the stored
entry's (`clearProgress`, leaving `"progress":null`) when an Agent goes Idle
or Done. A `blocked` entry written
without progress (the notify hook's, or a refresh's) keeps the progress of
the stored `working` or `blocked` entry it replaces, so the app can show the
estimate frozen. A progress-only rewrite re-reads the entry just before
writing and gives up when another writer replaced it meanwhile. A reader
drops only an unreadable `progress`, never the line.
`test-vectors/agent-summary-store-v1.json` holds store lines with what a
reader keeps of each (`null` for a dropped line; `declares_progress` says
whether the line has the `progress` key), shared by the Rust tests
here and the app's `AgentSummary` tests.

### Privacy

Summarizing sends up to the last 60 lines of an Agent's screen to the model
provider picked above — Anthropic (claude, omp), OpenAI (omp's Codex login,
codex, the OpenAI API), OpenRouter and the model it routes to, or the
default model of another installed harness (pi, qwen, gemini, copilot,
opencode, kilo, hermes, muse) — or to
whatever `summary_command` reaches, under that account's own terms: about
once a minute per Working Agent whose screen changed while the app is open,
and on every Blocked or Done event. Plan steps are read from the Agent's
transcript on the Host and sent to no model. The summary itself is stored
on the Host and travels to the app over SSH or end-to-end encrypted in the
push. It is
off unless the app's **AI summaries** setting (or a hand-written
`"summary_enabled": true` in `notify.json`) turns it on; switching it off
stops the refresh, keeps screen contents on the Host, and deletes the stored
summaries at the next refresh or status event.

## Activity hook

The second manifest `[[events]]` hook on `pane.agent_status_changed` runs
`waycar herdr-event activity` as its own short-lived process. herdr invokes both
this command and `waycar herdr-event notify` for the same event (verified on
0.8.0); there is no in-plugin dispatcher. It is independent of the alert
notify hook: `notify` flags do not gate it, and a Host with neither a
`live_activity` nor a `live_activity_start` registration sends nothing.

The hook lists the Host's agents through `HERDR_BIN_PATH` (`herdr agent list`),
resolves workspace labels best-effort through `herdr workspace list`, and drives
one Live Activity per Host. Eligible statuses are **Working**,
**Blocked**, and **Done**; idle and unknown panes are never listed. Idle
panes are counted in plaintext `counts.idle` (a display-only chip) but never
start or keep an activity alive. The encrypted
details envelope uses the same Notification Key as alerts, sealed under AAD
`HERDR-ACTIVITY:1` (see `docs/agents/live-activity-contract.md` and
`test-vectors/live-activity-content-v1.json`).

Anti-noise, in order:

1. **Cheap exits**: no device has a 32-byte key plus either a
   `live_activity` object with a plausible hex token and valid env, or a
   `live_activity_start` object with a plausible hex token and UUID
   `host_id`; or `activity/last-state.json` recorded `ended: true` and the
   incoming status is not working/blocked/done.
2. **Latest-wins debounce**: the script writes `activity/claim.json` and
   sleeps `activity_debounce_ms` (default 1500). A newer claim from an
   overlapping invocation wins; the loser exits without sending.
3. **One sender at a time**: the winner then holds `activity/send.lock`
   while it reads last-state, decides, sends and records last-state, so an
   invocation that started after the debounce ended sees what the one before
   it sent instead of sending it again. A lock whose process is gone, or
   that is older than two minutes (longer than any send takes), is broken;
   a run that cannot get the lock within 150 s fails instead of waiting on.
4. **Unchanged snapshot**: an eligible `{pane_id: status}` map, idle count
   and the `{pane_id: progress}` map of the Agents the envelope lists
   identical to last-state send no update. An idle-count or visible progress
   change alone sends a priority-5 update. A pending push-to-start is not
   suppressed.

With AI summaries on, a Working or Blocked Agent's entry carries `progress`
(plan steps and/or phase) from its summary-store record when that record was
written in the Agent's current status; a Blocked Agent whose record is still
Working keeps that estimate (frozen); otherwise the plan-step tick's own steps
apply. An `idle` or `done` status event clears the pane's stored progress
and tick steps first. While the episode is live and an Agent is Working, the
hook keeps one detached plan-step tick (`waycar activity-tick`, lock
`activity/tick.lock` with a heartbeat, steps in `activity/plan-steps.json`)
running: about every 150 s it re-reads the Working Agents' plan steps from
their transcripts (no model call; an unreadable transcript changes nothing),
stores changes, and pushes them at priority 5. It exits when no Agent is
Working, the episode ends, summaries are switched off, or after 2 hours.

An empty eligible set sends `event: end` (skipped if already ended) with zero
counts (including `idle: 0`), `dismissal_date` equal to the timestamp, and an envelope whose
`agents` array is empty. Otherwise it sends `event: update` with
`stale_date` = timestamp + 900. Priority is **10** only when some pane is
blocked now and was not blocked in last-state (absent last-state counts as
empty); otherwise **5**.

Each device with a live update token gets one `POST /push` with
`kind: liveactivity`, the activity token, and the sealed envelope. Transient
failures (network errors, 429, 5xx) are retried up to 3 attempts. A
`410 Unregistered` verdict deletes only that entry's `live_activity` field,
preserving the alert `token`, `key`, `notify` flags, `live_activity_start`,
and any field this plugin does not understand. A relay-origin
`413` degrades the envelope one step at a time (drop every `title` and legacy
`name`, then `rows`, then `progress`, then send `agents: []`; workspace/kind/
status stay until the last step) and retries; the hook also pre-degrades when
the projected ciphertext would exceed the Live Activity size budget.

### Push-to-start

A device whose `live_activity_start` registration has no running activity to
update gets `event: start` instead, so the Host's Live Activity appears even
when the app is not running. An update token is *live* unless this hook
ended its activity with an `end` push; a device without `live_activity_start`
keeps the older behavior and is always sent updates. The hook starts an
activity when all of these hold:

- the eligible inventory is non-empty;
- the device has no live update token (absent, pruned by a 410, or ended);
- the device has not been started in this **episode**. An episode ends when
  the eligible inventory empties; a live update token appearing also resets
  the device. An update 410 during an episode (the user dismissed the
  activity) counts as started, so a dismissed activity stays dismissed until
  the Host goes quiet.

Before sending, the hook waits `activity_start_grace_ms` (default 8000), then
re-reads the registration: a device that gained a live update token meanwhile
(the open app started its own activity) is skipped, and a newer invocation
that took the debounce claim makes the decision instead. The start body adds
`attributes_type: "AgentActivityAttributes"`, `attributes: {"hostID":
host_id}`, and a fixed generic `alert` (APNs requires one; it names no Host,
agent, or task), with priority 10 and `stale_date` = timestamp + 900. A 410
for the push-to-start token deletes only `live_activity_start`.

The hook cannot end a pushed activity until the app has registered that
activity's update token (it does so the next time it runs with the Host
connected). Until then the activity shows its start content, marked stale
after 15 minutes.

Last-state (`activity/last-state.json`: `sent_at_ms`, `statuses`, `idle`,
`preferences`, `ended`) is
written only after at least one successful delivery. Push-to-start
bookkeeping lives in `activity/start-state.json` (`ended_tokens`: update
tokens this hook ended; `started`: device alert token → start time for the
current episode). All state writes are temp-file + rename.

## Tests

```bash
cargo test --locked
```

Run it in this directory. CI also gates on `cargo fmt --check` and `cargo
clippy --locked --all-targets --all-features -- -D warnings`.

`sh test/waycar-hook-dispatch.sh` checks which half of `bin/waycar-hook` (tmux
or herdr-core) a hook reaches, against a fake tmux and a stub `waycar`.
`scripts/ci/core-distro-check.sh` runs the herdr-core Host Tools against a real
`herdr-core` in a container (see `.github/workflows/core-distros.yml`).

## License

Licensed under the Apache License 2.0. Derived from
[Heeler](https://github.com/ZingerLittleBee/Heeler) by ZingerLittleBee and
contributors; see [LICENSE](LICENSE) and [NOTICE](NOTICE).
