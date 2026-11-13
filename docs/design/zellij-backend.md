# Zellij backend: build plan

Status: building, one landing (Mike, 2026-11-12). Evidence: [`../research/zellij-backend-2026-11.md`](../research/zellij-backend-2026-11.md) (facts Z1–Z19, Zellij 0.46.0, live and source). Base `f5501b2`.

Goal: Zellij sessions on a Host appear in Waycar the way tmux sessions do: Agents and terminals in the Console, status, attach, New Agent, Closed Sessions and push, over SSH, with nothing on the Host beyond Zellij and Waycar's Host Tools (and the Host Tools only for hook status and push).

## 0. Decisions (Mike, 2026-11-12, card 1616)

| # | Question | Decision |
|---|---|---|
| 1 | Version floor | **0.46.0**: agent-reported status (OSC 7501), `set-resurrect-command`, the version-independent socket directory (Z9, Z15, Z17, Z18). Older: "update Zellij" |
| 2 | Change feed | A POSIX `sh` loop on the Host, on one non-PTY exec channel, that prints the inventory only when it changed (section 4). No Host Tools, no Zellij plugin |
| 3 | Opening an Agent | The exact pane, with the Z8 recipe; checked afterwards, and the whole session when the check fails. Never move the desk's tab on purpose (section 7) |
| 4 | New Agent | A new tab in the chosen session; its own background session when no client is attached (Z14) or for a new Workspace (section 8) |
| 5 | Status for agents that do not report | Host Tools hooks write one small file per pane; never write into a pane's tty (Z9) |
| 6 | Closed Sessions | Zellij's own closed sessions are listed; Resume is the user's tap; Delete asks first (section 9) |
| 7 | Runtime label | "Zellij", after tmux: Herdr TUI / Herdr Core / tmux / Zellij |
| 8 | Delivery | One landing |

## 1. Ids and mapping

- Session → Workspace, tab → Tab, terminal pane → Pane (and Agent when one runs). Plugin panes (`is_plugin`) and suppressed panes (`is_suppressed`) are never rows.
- **Pane id** (shared with Host Tools and push): `zellij:<session>/terminal_<n>`. Session names cannot contain `/` (`validate_session_name`), so the last `/` splits it. Every other id (Workspace, Tab, Terminal) follows tmux's shape with a `zellij` prefix; the Terminal id also carries an app-side generation per session name, bumped when the session leaves the live list and comes back, because pane numbers restart in a new session of the same name.
- A session name with a control character is skipped (it would break the line framing in section 4).
- Order: sessions as `ls` prints them, tabs by `tab_position`, panes by id.
- No focus is derived: Zellij keeps a focused pane per tab and focus is per client, so every Tab and Pane reads unfocused (as on herdr-core).
- A pane's title is `title`; its folder `pane_cwd`; its command line `pane_command`.

## 2. Detection

- One more probe in `HostBackendDetection`'s script, through `waycar_watch` like every other program (5 s): `zellij --version` (prints `zellij 0.46.0`), found by `command -v`, then `~/.local/bin`, `~/.cargo/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, the Nix profiles. Report version and absolute path (`ZellijPresence`, decoded optionally so old cache files read). Nothing else runs: every read command is side-effect free (Z6), but detection needs none of them.
- Below 0.46.0: presence says "needs update"; the Host detail says "Zellij <v> is too old. Waycar needs 0.46 or later." and the runtime is not offered.
- Every later command uses the detected absolute path.

## 3. Per-Host wiring

- `HostBackend.zellij` (raw `zellij`, display "Zellij"), declared after `.tmux`; `hasTerminal` true; not a herdr slot. Older builds already decode Closed Sessions lossily (`ClosedSessionsStore.LossySession`), so a synced `zellij` record is skipped there, not fatal.
- Visibility: a per-runtime toggle "Show Zellij sessions", default on, beside tmux's in Host detail › Backends; New Agent offers "Zellij" in the runtime picker when present, remembered per Host like the others (memory `runtime-choice-per-host`).
- Capabilities: `takeover` false, `pluginRowLayout` false, `namedSessions` false, `worktrees` false, `startsAgents` true, Agent and Tab rename yes, **Workspace rename no** (hooks address a session by `ZELLIJ_SESSION_NAME`, which a rename leaves stale in running panes, Z11).
- A Zellij-only Host gets a muted "Zellij" badge, as tmux-only and core-only Hosts do.
- Add Host and Host detail checklist: connection, remote environment, Zellij installed, Zellij 0.46 or later, Zellij answers (`ls`; "no sessions" passes), Status Hooks (as tmux).
- Admission: the change feed is a long-lived session channel in a new class `.zellij` (limit 1) in the shared session pool with ordinary, `.control` and `.core`; one-shot commands use `.ordinarySession`.
- Host Tools: `waycar status --json` gains `backends.zellij` (version or null); `WaycarPluginRequirement.zellijMinimumVersion` (2.6.0, the first plugin with a Zellij mode) is read only for a Host whose backends include Zellij, like `coreMinimumVersion`.

## 4. The change feed

One non-PTY exec, started when the projection connects and closed when it ends. The script is `ZellijWatchCommand.script` (POSIX `sh`, BSD and GNU `sed`); `scripts/ci/zellij-contract.py` runs a verbatim copy of its body (`WATCH_LOOP`) against real Zellij, so change both together. It loops in a background subshell: `ls -n`, then `list-panes -j` per live session, then the state documents; it prints a frame when the result changed and a newline otherwise, then sleeps.

- **It must end on stdin EOF.** OpenSSH sends no `CHANNEL_CLOSE` while a non-PTY child lives, and a close that waits past 2 s invalidates the whole SSH session (AGENTS.md SSH facts). The foreground `cat` returns on EOF and the script ends with `kill 0`: sshd runs the exec in its own process group, so that ends the loop and any `zellij` call it is waiting on at once (a 3 s stand-in call ended in 0.03 s).
- **Only changes are sent.** `ls` lines keep a fixed ` [Created]` in place of the age (it changes every second; the placeholder keeps a name that itself contains `[Created` parseable from the end), `list-panes` loses the cursor position (it changes on every keystroke). `-j` prints pretty multi-line JSON (the contract check found it; JSON strings escape their newlines), so each session's output is folded onto one line first. Z5 measured 1 change in 20 idle polls.
- **Session names.** Each `ls -n` line is parsed from the end: an optional ` (current)` or ` (EXITED - attach to resurrect)`, then the last ` [Created …]`, then the name. Lines without it are skipped (a name with a line feed prints continuation lines without it, so such a session is invisible); names with a control character or a leading `-` (Zellij's `attach` cannot take one positionally) are skipped everywhere; a session whose `list-panes` fails or prints nothing has no Workspace. Right after `attach -b`, `list-panes -j` can print nothing with exit 0 for a moment: a launch check polls (up to 5 s) rather than reading that as gone.
- **Liveness.** An unchanged tick prints one newline; 10 s without a byte means the channel is dead: close and reconnect through `EventsSession` (like tmux's lost link). Every reconnect replaces all state with the first frame.
- **Cost.** One `ls` plus one `list-panes` per live session per second, about 16 ms of Host CPU each (Z4); with more than 4 live sessions the loop sleeps 2 s.
- **Frame.** `\036B` … `\036E`: `ls` lines (`<name> [Created]` plus the suffix), `\036P`, then per live session `\036S<name>` and its `list-panes -j` line, then `\036H` and one hook state document per line (section 6). The parser is pure and tolerant: unknown JSON fields are ignored, a session whose `list-panes` failed (it just closed) keeps no rows.
- Frames become a `SessionSnapshot` (`ZellijSnapshotBuilder`, pure) and synthesized events as tmux does: membership changes emit a resync kind, status changes `pane.agent_status_changed`.

## 5. Status

Per Agent pane, first match wins:

1. The root `program_status` record (`id: null`): `Idle` idle, `Working` working, `Done` done, `Blocked` blocked, `Error` blocked (Z9). Never `attention` (Z10).
2. The hook state document for that pane (section 6), when its `updated_ms` is after the session's first sighting in this connection or the app saw no restart (the app ignores documents older than the session).
3. Screen detection: `TmuxScreenDetector.classify` on `dump-screen --pane-id`, polled every 3 s while the Console is in the foreground, for at most 8 Agent panes that have neither, as tmux does for kinds without hooks.
4. Unknown.

- Done to Idle when the user opens the Agent: a client overlay like `CoreDoneOverlay`, cleared when the state word changes. No Zellij command.
- Kind: the record's `app` through `SupportedAgentKind` (`claude-code` is claude), else the hook document's `kind`, else `pane_command` through `AgentKindDetection.kind(commandLine:)`.
- Shell Activity comes free: a pane whose `pane_command` executable is a shell is idle, anything else busy (`ShellForeground`'s leader rules).

## 6. Host Tools Zellij mode (plugin 2.6.0)

- **State document**, one per pane: `$HOME/.local/state/waycar/zellij/<base64url(pane id)>.json`, written atomically with a lock (`atomic.rs`). The path ignores `XDG_STATE_HOME` on purpose: the app's loop runs in a bare SSH exec, which does not see a login shell's XDG variables. Schema pinned by `plugin/test-vectors/zellij-pane-state-v1.json` (Rust and Swift):
  `{"version":1,"pane":"zellij:<session>/terminal_<n>","kind":"claude","status":"working","seq":3,"session":"<agent session id or path>","transcript":"<path>","launch":"<launch tag>","pid":1234,"updated_ms":1794448338909}`; every field but `version` and `pane` is optional; `release` deletes the file.
- **Which pane.** `bin/waycar-hook` tries tmux first (its own tty check, unchanged), then Zellij, then core. The Zellij branch takes a hook only when `ZELLIJ_PANE_ID` and `ZELLIJ_SESSION_NAME` are set and, from the agent process (the same `CLAUDE_PID`, parent and one-hop rules as the tmux guard, no hop for codex and cline), walking up its parents (at most 16) reaches a process whose parent is a Zellij server, and that pane root has the agent's controlling tty and the same two values in its own environment (`/proc`, `ps` on macOS). List-panes has no tty or pid, so this ancestry is the ownership proof: it rejects the Codex daemon's hooks (no tty), a hook that only inherited the variables (no Zellij ancestor), and an agent in a tmux or `script` pty nested inside a pane (another tty). Muse's restore list gains the three `ZELLIJ` variables. A Zellij started inside tmux hands its panes `TMUX_PANE`; the tmux tty check already rejects those (the agent's tty is Zellij's, not the tmux pane's).
- **Writers.** `waycar hook-status` and `hook-session` gain the Zellij target: status (with the conditional statuses and `seq`), kind, session, transcript, release. The omp, pi, opencode and kilo extensions accept a Zellij pane like a tmux one.
- **Resume.** When a session id is recorded, `zellij -s <session> action set-resurrect-command --pane-id terminal_<n> -- <resume argv>` for kinds whose resume arguments the shared launch vector defines, so a resurrected Zellij session resumes the conversation (Z15).
- **Push.** A Zellij `Backend` adapter (`notify_core.rs`): recheck runs `zellij -s <session> action list-panes -j`, finds the pane (gone means gone; a failed list means unknown), and reads its status the way the app does (record first, document second). Pushes and Live Activity rows carry `zellij:<session>/terminal_<n>`. `zellij_enabled: false` in `notify.json` silences them (default on). Chat Marker GC keeps `zellij:` markers while their session lists the pane and when Zellij cannot answer.
- **Install.** `install.sh` finds `zellij` with `--version` only (0.46+), installs the standalone shape on a Zellij-only Host, and installs the Status Hooks when Zellij is usable. The success lines the app parses stay as they are.
- **GC.** Documents whose session is not live (`zellij ls -s`, closed ones excluded) are removed by the hooks' existing GC slot.
- Version: 2.5.0 → 2.6.0 everywhere the version lives; `WaycarPluginRequirement.currentVersion` 2.6.0.

## 7. Transport members

| Member | Zellij |
|---|---|
| `ping`, `revalidate` | detected version; `ls` answers |
| `listAgents`, `sessionSnapshot` | the latest frame |
| `subscribeToEvents` | section 4 |
| `readPane`, `readAgent` | `dump-screen --pane-id terminal_<n>` (visible), `--full` for history, trimmed to `lines` |
| `promptAgent`, `checkAgentInputScreen` | tmux's flow: serialize per pane, sign-in and trust screen checks, launch readiness (`AgentScreen.readiness`), refuse `blocked`, `paste --pane-id`, the kind's Enter delay, `send-keys … Enter` (skipped if it turned blocked). Paste then Enter in one exec when there is no delay (Z12). The draft travels on the exec's stdin and the Host builds the argument (`paste … -- "$(cat)"`), so quoting never inflates it; drafts over 100 KiB are refused with a plain error (the Host's per-argument limit) |
| `sendAgentKeys`, `sendPaneInput` | `send-keys` after a key table (`ZellijKeys`: Waycar names to `Enter`, `Esc`, `Tab`, `Shift Tab`, `Ctrl c`, `Alt b`, `F1`…, single characters); unknown names are `invalid_key`. Text is `paste` |
| `closePane`, `closeTab` | `close-pane --pane-id`, `close-tab --tab-id` |
| `renameAgent`, rename Tab | An Agent alone in its tab is named by the tab and renamed with `rename-tab-by-id`; otherwise by its pane title, renamed with `rename-pane` (`ZellijSnapshotBuilder.renameTarget`). Tab rename: `rename-tab-by-id` |
| `renameWorkspace`, `movePane`, worktrees | unsupported; the UI is gated |
| `focusAgent` | the Done overlay (section 5) |
| `shellActivities` | from the frame (section 5) |
| `attachTerminal`, mosh | section 8 |
| `startAgent…`, shells | section 9 |
| file, git, home, skills, usage, staging | the shared SSH-exec implementations through `HostSSHServices`, as tmux |

Every user string in a command line goes through `ShellWord`. Every command is `"$Z" -s <session> action …` with the detected path.

## 8. Attach

1. Resolve the pane's session, `tab_id` and number from the inventory.
2. Open the PTY **oversized** (600x200 over SSH; 512x200 over mosh, the SwiftMosh screen model's column cap) and exec `"$Z" attach <session> options --default-mode normal` behind the usual bootstrap marker. The smallest client sizes a tab (Z7), so the desk's tab keeps the desk's size.
3. When Zellij has drawn (output after the marker, then 200 ms of quiet, at most 5 s), send Ctrl g (`0x07`): Zellij consumes it (Normal to Locked), nothing reaches the pane, and the phone becomes the last active client (Z8). Wait for its redraw plus 200 ms of quiet. The phone stays in Locked mode, where every later key goes to the pane. (Contract-proven on 0.46.0: a phone started in Session or Locked mode and moved to Normal by Esc or Ctrl g swallows ordinary typing afterwards, because Normal then differs from the client's default mode; a lone Esc also needs about 1 s before Zellij parses it.)
4. One exec: `list-clients`; `go-to-tab-by-id <tab>`; `focus-pane-id terminal_<n>` (exits 2 with `Pane Terminal(N) is already focused` when it is: not an error; never chain with `&&`); `list-clients`.
5. Check: the phone is the newest client id (0.46 never reuses ids). Success when its pane is `terminal_<n>` and no other client's pane changed. If another client moved instead (the desk typed between steps 3 and 4), move it back (it is now the last active client) with its earlier tab and pane, and keep the phone on the whole session.
6. Resize the PTY to the phone's size and hand the session to the UI; output before that is dropped (Zellij redraws on resize).

- The attach-ready step and the check are a `StateMachine` (`docs/design/state-machines.md`), tested with a fake channel and fake exec.
- mosh: the same steps through the mosh session (initial size 512x200, Ctrl g as input, resize). The mosh projection candidates gain `.zellij`.
- No takeover: several phones are several clients, each with its own focus.
- Detach is closing the channel (Z16); mosh sessions end with mosh's shutdown handshake, as today.
- A closed (`EXITED`) session is never attached by the inventory path; only Resume (section 10) does that.

## 9. New Agent and shells

- Launch line: `AgentLaunchBuilder.shellLine` inside tmux's login-shell wrapper, prefixed `env WAYCAR_LAUNCH=<tag>` (and `WAYCAR_SHELL=1` for shells), run as `/bin/sh -c '<line>'`, so `terminal_command` carries the tag (Z13).
- **Into an existing session:** one exec: `list-clients`; with at least one client, `new-tab --no-focus --name <agent name> --cwd <folder> -- /bin/sh -c '<line>'`, then `list-panes -j`, and the launch is confirmed only when a pane in the new tab carries the tag (Z14 can print an id and create nothing). With no client, or when the check fails, the background session below, named after the Agent.
- **New Workspace / background session:** `cd <folder> && "$Z" attach -b <name> -- /bin/sh -c '<line>'`, with `<name>` unique against `ls -s` (`-2`, `-3`). That starts a Zellij server, which every pane inherits its environment from, so on macOS with a logged-in user it runs as the herdr wake's one-shot launchd job in `gui/<uid>` (`WaycarSSHTransport.wakeExec`, `SSHTransportSettings.wakesInLoginSession`), falling back to the plain exec.
- **Lost answers** (memory `offline-launch-queue-semantics`): reconcile by the exact tag in `terminal_command` across the inventory: found and running, use it; not found, start.
- The first prompt waits as on tmux (section 7); a launch the app makes never blocks on readiness.
- The Agent's name is the tab name (and the session name for a background session).

## 10. Closed Sessions

- **Zellij's closed sessions** (the frame's `EXITED` lines) are Closed Sessions of the Host, one row per session, "Zellij session" as the subtitle and the age from a one-shot `ls -n` when the list opens.
  - **Resume** (the user's tap) opens an Attach of `"$Z" attach <name>`, which resurrects the session; Zellij shows its suspended commands, and agents whose hooks set a resume command come back in their conversation. Nothing else ever resurrects (Z6, memory `no-auto-start-host-services`).
  - **Delete** asks first ("Delete Zellij session “<name>”? Its saved layout is removed from the Host.", Delete / Cancel), then `delete-session <name>`.
- **Closed Agents** in live sessions follow the existing generic capture (`HostConsoleProjection` snapshot diff) and resume through New Agent on Zellij with the kind's resume arguments.

## 11. CI and tests

- `scripts/ci/zellij-contract.py` + `.github/workflows/zellij-contract.yml`, modeled on `core-contract.py`: the pin (0.46.0, the binary sha256 per target) lives only there; `--fetch DIR` for the iOS lane (aarch64 macOS on the runner); scenarios pin Z1–Z16 (JSON fields, side-effect-free reads, OSC 7501 to `program_status`, `attention` clearing, per-tab sizes, the attach recipe, input brackets, `new-tab` with and without a client, `attach -b -- cmd`, closed sessions, `set-resurrect-command`, the watch loop ending on EOF within a second). Scratch `HOME` and `ZELLIJ_SOCKET_DIR`, cleaned on exit. Strict on PRs touching the script, `Transport/Zellij/**` or this doc's research; weekly `--latest --warn`.
- `ZellijTransportE2ETests` in the iOS lane (`scripts/run-ci-ios-tests.sh`, `WAYCAR_ZELLIJ_E2E_CONFIG`, counted with no skips): inventory and status from a fake OSC 7501 agent, a prompt delivered, New Agent with and without a client and its reconcile, attach that leaves a desk client untouched, a closed session listed and deleted.
- `scripts/ci/zellij-distro-check.sh` + `.github/workflows/zellij-distros.yml` (ubuntu:24.04, debian:12, fedora:latest, plus Zellij inside tmux): the contract's verified binary, `install.sh` with no flag, a hook in a real Zellij pane writes its document and pushes to `relay-standin.py`, a wrong-tty hook does nothing.
- Unit tests for the pure layers (frame parser, snapshot builder, status merge, keys, command builders, attach machine) and Rust tests for the Host Tools mode.

## 12. Not in this landing

Worktrees and Move to Workspace on Zellij; Workspace rename; Chat Mode and Summaries on Zellij Agents; Zellij as the linked desk terminal of a Codex or OpenCode chat (`HostBackend.hostsLinkedServerTerminal`: no Chat Marker path yet, so a Zellij-only Host keeps those chats chat-only); approval watch; installing Zellij from the app; analytics vocabulary; custom `ZELLIJ_SOCKET_DIR`s; Zellij older than 0.46; a per-pane attach through Zellij's pane-mirror protocol (0.46 has one, internal and structured, a later option).

## 13. Risks

- 0.46.0 shipped on 2026-11-11 and the JSON is unversioned: the contract check catches drift.
- The attach race (a desk keystroke inside one round trip) moves the desk, which step 5 puts back.
- The change feed costs Host CPU while the app is in the foreground (section 4).
- A desk-side session rename leaves hook documents keyed by the old name until the agent restarts; agents that report their own status are unaffected.
- After a Zellij upgrade, sessions of the old version are invisible to the new CLI until restarted (Z18).
- Oversizing only keeps the desk's size while the phone's tab differs from the desk's. When both view the target tab, the final resize sizes that tab to the phone (smallest client, Z7) for as long as both view it; only a pane mirror, which Zellij does not offer, would avoid it. Accepted.
- A session name holding a line feed prints continuation lines in `ls -n` without ` [Created …]`, so that session has no rows and no Workspace (section 4).
