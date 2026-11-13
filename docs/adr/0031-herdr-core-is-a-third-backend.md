---
status: proposed
---

# herdr-core is a third Backend over one framed `hc connect`; a Host runs one herdr runtime at a time

_2026-10-29, proposed (WAY-472). Mike's requirement, in the issue thread: a Host can have both the TUI and core installed, so the Host's settings need a flag that picks which one that configuration uses. Design and build plan: `docs/design/herdr-core-backend.md`. Evidence (live runs against `hc` 0.1.14, source reads): `docs/research/herdr-core/`._

Herdr 2 splits the product in two: **herdr-core** (`hc`, Apache-2.0) is a headless runtime that owns terminals, and the **Herdr app** (macOS, Linux, Windows) is one client of it. The original program stays as **Herdr TUI** (`herdr`, the backend ADR 0011 describes). They are separate programs with separate sockets, state and agents: what runs in one never shows in the other. core has no workspaces, tabs, panes or worktrees, no plugin system and no agent list. It keeps terminals alive, reads status only from the program's own OSC 7501 reports, and exposes a documented JSON-RPC API through `hc connect` (stdin/stdout, so it travels over a plain SSH exec).

Waycar adds core as a third Backend, `HostBackend.core`, beside herdr (the TUI) and tmux.

Decisions:

- **A new `HostBackend` case, not a runtime attribute on `.herdr`.** Every per-backend store (projection scopes, inventory cache file, Unread Marks, Closed Sessions, terminal cache, standby mosh) already keys on the Backend. Reusing `.herdr` for core would hand the TUI's cached snapshot to a core projection on a switch, make every TUI row look closed, and misread the stored herdr protocol number. As a separate case, a switch ends one scope and starts the other from its own cache file, the path `showsTmux` already takes. "Map, don't rename" (ADR 0026) holds: core maps into the herdr-shaped model, the `Herdr*` type names stay.
- **One herdr runtime per Host, picked per Host.** A Host with the TUI and core resolves to exactly one of them for its herdr slot. tmux stays additive beside it, as today. The pick is stored in its own synced per-Host preference (`HerdrRuntimePreferences`), not on `Host` and not as a new key inside `HostBackendPreferences`. An extra `Host` key is stripped by older builds and restarts the Host's projections on every edit. An older build decodes the `HostBackendPreferences` blob with fixed keys and writes it back without the new key, and iCloud would sync that as the pick's removal. A separate key is ignored by an older build and so survives it. It applies only when both are installed; with one installed, that one is used. With no pick, a Host with both uses the TUI, so a user who installs core for the Herdr app does not see their Waycar Console go empty. The Host's settings show the picker only when both are found, and until the user picks, the Console carries one row that says both are installed, which one is showing, and where to choose.
- **Detected, then picked, never assumed.** Presence gains `core` (the version `herdr-core --version` prints). A candidate counts only if `--version` prints `hc <digits>`, because some window managers ship an unrelated `hc`. Detection never starts a core: only `-V`, `server stop` and `update --from` avoid core auto-start, and every other `hc` call starts one.
- **One framed `hc connect` on one non-PTY exec channel carries everything but terminals.** JSON-RPC on channel 0 (calls run concurrently) and the event stream on its own frame channel with CREDIT, exactly as the Herdr app's own client does. Plain mode is rejected: it is strictly serial (a 30 s template run blocks every later call) and a subscribed plain connection silently ignores all requests, so it needs two exec channels. Framed costs one. It gets its own channel-admission class (`.core`): a Host can run core and tmux together, and tmux's control class admits one. No stream-local forwarding is needed, which also unblocks Hosts where `AllowTcpForwarding` is off. Core uses its default session: `Host.sessionName` stays a TUI-only setting, because reusing it would point a Host with a TUI session named `work` at an empty core session of that name. Debian and Ubuntu bash reads `~/.bashrc` above its interactive guard even for an exec (observed over a real sshd), so the connect and attach lines print a marker just before `exec` and the client discards everything up to it.
- **Attach is `herdr-core attach <id>` on a PTY exec channel.** The same shape as `herdr terminal attach`: the terminal engine already renders a PTY, and mosh and window-change keep working. `hc attach` is the viewer: it translates keys, answers the core, follows resizes and detaches when the channel closes. There is no takeover: many viewers may type and the newest active one sets the size, so the Take Over / Live-in-Another-Window path does not apply (`takeover: false`, like tmux).
- **Flat terminals become a synthetic topology.** Workspace = the Herdr app's `herdr.space` label when a terminal carries one, else the terminal's start folder; Tab = the app's `herdr.tab` label, else the terminal; Pane and Agent = the terminal. Terminal ids are `hc:<address>` (opaque, never parsed, like `tmux:` ids). The Herdr app's `herdr-app` document (space and tab names) stays app-owned and unversioned: Waycar reads it tolerantly for display names only (space and tab names by `herdr.space`/`herdr.tab` id, synthesized names when absent) and never writes it.
- **Status only from the program.** `unknown` until the program has reported; then its own word, with `error` shown as `blocked` (it needs the user). No screen detection in the first release, as for tmux. Agents that speak OSC 7501 show status. Claude Code from 2.1.295 and Pi from 1.1.0 are reported to speak it (herdr discussions 5106 and 5073; the Claude Code 2.1.311 binary here carries the probe string; no paid agent was run). The rest show Unknown with a plain explanation. Waycar's agent kind comes from the report's `app` and the foreground command.
- **Launches pass their own PATH.** The core's environment is frozen at its first start (the first caller's, minus `SSH_*`), and a bare SSH exec has a minimal PATH, so `claude` fails with `spawn_failed`. The app resolves the user's login PATH over SSH once per connection and sends it as `env.PATH` on each `terminal.run`, validates the folder first (`~` is never expanded; a bad folder reports the program), and sends the first prompt through `terminal.send` once the agent reports idle.
- **Host Tools gain a core mode in a second step.** Agent notifications, Live Activities and the registration file need the Waycar Host Tools, whose installer today exits unless herdr or tmux 3.2 is present. Until core mode ships, core Hosts get the Console, Attach and the Composer, and the Host Tools offer and notification sections say what is missing instead of failing.
- **Floor: core 0.1.10.** It is the first release with `machine.exec`, `doc.*`, `terminal.keep`, `file.*` and `status_ms`. Calls are gated on `hello.methods`, never on the version string. The API "only grows" (core's released-schema test), and Waycar ignores unknown fields and treats every vocabulary (`status.state`, error `kind`, event `type`) as an open string.
- **`CONTEXT.md` changes.** The **Backend** entry says the backend is "detected on each connection, not stored as a Host setting". That stays true for tmux and for which runtimes exist; the herdr runtime pick is the one stored choice, and the entry says so.

## Considered options

- **Core as `.herdr` with a runtime field on `Host`.** Rejected above: stale snapshot handover and closed-session capture on a switch, a `Host` key older builds strip, a projection restart on every edit.
- **Show both runtimes in one Console, as tmux does beside herdr.** Rejected for now. The runtimes' agents are disjoint, Mike asked for a pick, and a user who wants both can add the Host twice with different picks. Revisit if the pick turns out to be a daily chore.
- **Two plain `hc connect` connections (requests, events).** Rejected: serial replies, a second exec channel, and a template run can stall the first for 30 s.
- **Direct-streamlocal to core's socket.** Rejected: it needs stream-local forwarding, the socket path differs per OS and `XDG_RUNTIME_DIR` (macOS has none), and `hc connect` already resolves the path.
- **Framed attach streams inside the app, no `hc attach`.** Deferred. It would skip the PTY and the 500 ms terminal handshake and enable a watch-only Mirror from `observe`, but it moves key encoding, paste handling, focus and query answering into the app. Revisit with Mirror.
- **Read the `herdr-app` layout document for real space and tab names.** Done: `CoreTransport` reads it tolerantly (`doc.get`, refreshed on `doc` events), read-only, with the synthesized names as fallback.
- **Screen detection for agents that do not speak OSC 7501.** Deferred, as for tmux (ADR 0026).
- **A Host daemon that subscribes to `hc events` for notifications.** Rejected for the same reason ADR 0026 rejected one for tmux: no Host daemon; agent hooks do the pushing.

## Consequences

- core Hosts work where stream-local forwarding is disabled, and need no Host-side install for the Console.
- A core Host has no Status Hooks, Host Tools or herdr plugin until the second step, so no background pushes and no in-app banners (the registration file lives under the Host Tools). The Console says so.
- A new `HostBackend` raw value (`core`) reaches older builds through iCloud: a `ClosedSession` with it is unreadable there and never overwritten (safe), and `newAgentBackend` never stores it (an unknown value there fails the whole preferences blob on an older build). The Backend picker's "New agents start in" keeps its two stored values, and `herdr` means whichever runtime the Host's herdr slot resolves to. An older build does not know the runtime pick at all, so it neither shows nor changes it.
- `HostBackend` declares `.core` between `.herdr` and `.tmux`, and the code that picks the lead projection or waits on herdr works by backend, not by position in `allCases`. Ten exhaustive switches and nine `allCases` loops over `HostBackend` are touched, and the parallel `BackendInstallTarget` switches are not (install is a later slice). The tmux build (PR 62) was 221 files, so the work ships in slices (design section 14).
- `Host.swift` and the transport files stay Foundation-only: the Android lineage compiles them. The core transport files join `sources-android.txt` when `android-main` merges `main`.
- A core transport is bound to an API still in preview (protocol generation 1, version 0.x). A contract smoke against a pinned core release runs in CI, and a weekly run against the latest release warns on drift.
- Windows Hosts are out: core runs there, but Waycar Hosts are POSIX SSH Hosts.
- A dropped phone leaves its attach as a ghost viewer on the Host until sshd drops the session: SSH keepalives on the client do not free it, and only the server's `ClientAliveInterval` does (observed: 170 s and still there with stock sshd). A ghost cannot type, and the next attach supersedes it, but while nobody else is active it still sets the PTY size.

## Amendment — 2026-11-01: side-by-side runtimes

This amendment supersedes the exclusive herdr-slot decision above and the
rejection of showing both runtimes. A Host with Herdr TUI and herdr-core
installed now runs both projections and merges their Agents into one Console.
Their inventories, identities and capability-specific actions remain separate;
tmux remains additive. Installing core must not hide existing TUI Agents, nor
should seeing core Agents require adding the same Host twice.

Host-level roles use an internal **TUI-first lead**, falling back to core
when TUI is absent or hidden; protocol memory and runtime-specific operations
stay with their owning Backend. There is no lead or launch-default setting in
Host settings, only per-runtime visibility toggles. New Agent offers one
segmented picker for new-Workspace launches with every present Backend, in order:
**Herdr TUI**, **Herdr Core**, **tmux**. It remembers the choice per Host;
existing Workspaces keep their owning Backend. Agent cards and visibility
toggles use those same UI names; executable names remain unchanged.

The app, not the plugin, writes `notify.json`'s `core_enabled`. On detecting both
runtimes it repairs the old exclusive selection's value to match core visibility
(default on), and hiding or showing core updates it again. The existing Host
Tools already default core on and honor explicit false, so no new plugin
behavior or minimum version is needed. This does not introduce a TUI notification
switch: hiding TUI Agents does not silence herdr-owned notifications. Hook
environment and tty ownership checks remain unchanged; simultaneous projections
are not a reason to remove duplicate-notification guards.

## Open

- Whether core should eventually lead internally once the TUI's share of installs falls. Today: TUI, to keep every existing Host unchanged.
- Which runtime Install offers first on a Host with neither (Product decision; no install in the first slices).
- A macOS Host with the Herdr app running, and the systemd user-service start path, were not run. A real sshd was (Ubuntu 24.04 container, `docs/research/herdr-core/real-ssh/`); the app's own SSH library was not.
