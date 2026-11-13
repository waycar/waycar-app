# herdr-core backend: build plan

Status: slices 1a, 1b, 3 and 4 built (WAY-475, WAY-478, WAY-479, WAY-481); see ADR 0031. Evidence: `docs/research/herdr-core/`
(live runs against `hc` 0.1.14 and source reads of herdr-core 0.1.14 and the
Herdr app). Base `d480fc05`.

Goal (Mike, 2026-10-29):
- Someone who runs herdr-core (the runtime under the new Herdr app) gets Waycar
  working the way it works for the herdr TUI and tmux: see every agent and its
  status, open its terminal, answer it, start new ones.
- A Host can have the TUI and core installed together. The Host's settings
  carry a flag that says which one that Host uses.

Not in scope here: Windows Hosts; starting agents on another machine through a
core's `on` (they are listed and attachable, new agents start on the Host
itself); the Herdr app's `herdr-app` layout document (space and tab names);
screen-based status for agents that do not speak OSC 7501; a watch-only Mirror
from core (falls back to Fit to phone); worktrees and new Workspaces on core;
Android (it follows on `android-main`, a separate task).

## 0. Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Both runtimes installed | One Host uses one of them, picked in the Host's settings. Stored per Host in its own synced preference (`HerdrRuntimePreferences`), not in `HostBackendPreferences` and not on `Host`. No pick: the TUI (CTO's call; a user who installs core for the Herdr app keeps today's Console). Mike can flip the default |
| 2 | Core in the type system | New `HostBackend.core` (raw `core`, copy "herdr-core"). Not a runtime field on `.herdr` (ADR 0031) |
| 3 | Pick scope | Applies only when both are found. One found: that one, whatever the pick says. tmux stays additive |
| 4 | Transport | One framed `hc connect` on one non-PTY exec channel: RPC plus events. Terminal attach stays a PTY exec of `herdr-core attach` |
| 5 | Topology | Synthetic: Workspace from `herdr.space` label or start folder, Tab from `herdr.tab` label or the terminal, Pane/Agent = terminal |
| 6 | Status | Only OSC 7501 as core stores it. `unknown` until reported. `error` shows as `blocked` |
| 7 | Launch PATH | Resolve the Host's login PATH once and remember it. Export it in the connect line (slice 1), so a core Waycar starts has a sane environment, and send it as `env.PATH` on every launch (slice 2) |
| 8 | First slices | 1a: backend type, detection, pick, Add Host preflight and gating, dark (resolution never yields core). 1b: transport, Console, Attach, prompts, keys, close; turns it on. Then 2: start agents. Host Tools core mode after (3-4). Install from the app and worktrees later |
| 9 | Floor | core 0.1.10, calls gated on `hello.methods` |
| 10 | Naming in copy | "Herdr TUI" for the original `herdr`, "herdr-core" for `hc`. Existing copy that says "herdr" keeps meaning the TUI |

## 1. Facts this plan relies on

Verified 2026-10-29 on `hc` 0.1.14 (linux x86_64) over pipes that carry the same
bytes as an SSH exec channel; "src" is a read of herdr-core or herdr-app source.
Details, captures and the exact commands are in `docs/research/herdr-core/rpc-facts.md`
(R), `attach-facts.md` (A) and `real-ssh/REAL-SSH-FACTS.md` (S, over a real sshd).

| # | Fact | Consequence |
|---|---|---|
| C1 | A terminal record has no `id`; `address` (`t7`, `t1b`, `box/t3`) is the id. Opaque, never reused, burned by a failed spawn (R§3) | Pane id `hc:<address>`: the app strips its own prefix, and never parses the address |
| C2 | `hc connect` starts the core when nobody listens (12 ms). Every `hc` subcommand except `-V`, `server stop` and `update --from` does too. "Not installed" is exit 127 with `herdr-core is not installed here` on stderr (R§2, A§6) | No "core not running" state. Detection uses `--version` only |
| C3 | Plain mode is strictly serial, and after `events.subscribe` the connection ignores every request. Framed mode (`hello {framed:true}`) runs calls side by side and carries events on a channel (R§3, A§1, src `server.rs:301`) | One framed connection |
| C4 | Event and attach streams start with 256 KiB of credit. Without CREDIT the stream stops at exactly 262144 bytes (A§1, A§4) | Send CREDIT for the event channel as it is consumed |
| C5 | The core's environment is frozen at its first start (first caller's, minus `SSH_CONNECTION/CLIENT/TTY`); later callers cannot change it. An SSH exec PATH has no user directories: `~/.local/bin`, nvm and cargo are missing (Ubuntu 24.04's exec PATH is the full system PATH; macOS's is `/usr/bin:/bin:/usr/sbin:/sbin`), so `claude` fails with `spawn_failed` (R§2, S§3) | Per-run `env.PATH`; or `argv: ["bash","-lc",...]` |
| C6 | `~` is never expanded. A bad cwd reports the program, not the folder (`spawn_failed`). `terminal.run` takes no size: 200x120 until a viewer attaches (R§4) | Validate folders with `machine.exec` first |
| C7 | `terminal.send` pastes (bracketed only if the program asked) and presses Enter; refuses `blocked` unless `force`; waits up to 5 s in a terminal's first 10 s for output to settle; the 3 s quiet rule applies only after a human typed in an attached viewer (R§5) | Composer delivery; no insert-without-submit over RPC |
| C8 | `terminal.keys` validates all names or sends nothing. It knows letters, digits, `` ` \ [ ] , = - . ' ; / ``, `space`, `enter`, `tab`, `backspace`, `esc`, `delete`, `insert`, `home`, `end`, `pageup`, `pagedown`, arrows, `f1`-`f12`, modifiers `shift ctrl alt super`. It rejects herdr TUI's `minus period slash quote ...` and cannot type `+ " : % &` or shifted symbols (R§5) | Key-name table in section 7 |
| C9 | Status is the program's own OSC 7501 record. `status` is null and `reported` false until the first report; `status_ms` moves only when the state word changes; `turn` counts leaves from `working`. `state` is `idle`, `working`, `done`, `blocked` (`kind` permission, question, auth), `error`; open vocabulary (R§3) | Section 6 |
| C10 | Events: `created lost restarted keep finished removed status turn title labels size foreground doc`. The subscribe snapshot includes finished terminals. `missed` carries a fresh snapshot; `seq` restarts with each core process; a `heartbeat` notification comes every 15 s when nothing is queued (A§4) | Section 5 |
| C11 | Core restart, `hc update` and a crash end every connection with EOF and no CLOSE frame; terminals survive. `server stop` kills programs (A§6) | EOF means reconnect, re-hello, replace all state |
| C12 | `hc attach` works on a PTY (`TERM` any), detaches on Ctrl+\, detaches at once when the channel closes, follows `SIGWINCH`, and exits 0 for exited, killed, detached and lost; messages go to stderr. It asks the outer terminal DA1/colors first and waits up to 500 ms (A§3) | Section 8 |
| C13 | PTY size follows the newest active typing viewer (attach, keys, resize, focus); the last detach snaps it to 200x120; `observe` never leads (A§1) | No takeover; phone size applies while it types |
| C14 | The installer puts `herdr-core` in `~/.local/bin`, and an `hc` symlink only if none exists; some window managers ship an unrelated `hc`. The Herdr app finds core in `PATH`, then `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/share/mise/shims`, `~/.nix-profile/bin`, `/run/current-system/sw/bin`, `~/.cargo/bin`, and accepts a binary only if `--version` prints `hc <digits>` (A§7, src herdr-app `core_bin.rs`) | Detection recipe in section 4 |
| C15 | The Herdr app labels its terminals `herdr.space` and `herdr.tab` (local ids) and starts each with a `cwd` (a new tab starts in the focused terminal's folder). An empty label means "parked" (herdr-app `window.rs`, `hc.rs`) | Topology in section 6 |
| C16 | Methods arrived: `machine.exec` 0.1.6; `doc.*` and `terminal.keep` 0.1.8; `file.*` and `status_ms` 0.1.10; `terminal.run.outlive_parent` 0.1.13. API "only grows" (core's released-schema test) (R§1, R§9) | Floor 0.1.10; ignore unknown fields; open string vocabularies |
| C17 | TUI and core never share sockets, state or agents, and no variable is read by both: core reads `HC_*`, TUI `HERDR_*`. A core started inside a TUI pane would hand that pane's `HERDR_*` to every terminal (A§8) | Hooks keyed on `HERDR_PANE_ID` must not fire in core terminals (section 11) |
| C18 | A terminal's programs get `HC_TERMINAL_ID`, `HC_TERMINAL_SOCKET`, `HC_SESSION` (A§8) | Host Tools identify the terminal with `HC_TERMINAL_ID` |
| C19 | Core keeps a 24 h, 500-record window of finished terminals, readable until `rm` (R§3). The Herdr app only kills, never removes (`terminal.rm` is not among the calls it uses) | Waycar's Close kills and leaves the record to core's retention |
| C20 | Over a real sshd (Ubuntu 24.04, OpenSSH 9.6) the framed stream, the `hello` line and the client bytes are identical to the pipe captures; the first reply takes 0.19 s (ssh handshake). The official installer ran online through a non-interactive exec in 0.7 s and starts no core (S§1, S§2) | The pipe research stands for the SSH transport |
| C21 | Debian and Ubuntu bash reads `~/.bashrc` above its "not interactive" guard even for `bash -c` under sshd, so a noisy `~/.bashrc` prints into `ssh -T host '<cmd>'`, ahead of the `hello` reply. `.profile` noise and noise after the guard do not. A bare `ssh -T host` plus a stdin script prints the whole motd. A marker printed just before `exec` and everything before it discarded works (S§7) | Connect and attach lines print a marker; the client discards up to it |
| C22 | The login PATH has `~/.local/bin` only once that directory exists (Ubuntu's `.profile` adds it `if [ -d ... ]`) (S§3) | A login PATH cached before the first install lacks it: re-resolve on `spawn_failed` and after Backend Install |
| C23 | `ServerAliveInterval`/`CountMax` are client-side: the client gives up at about 75 s, but the host kept a ghost viewer and its PTY size for 170 s. Only the server's `ClientAliveInterval` frees it (75.5 s with 15 x 4). The app cannot change a Host's sshd (S§5) | A dropped phone leaves a ghost viewer; see section 8 and risks |
| C24 | The installer's update branch restarts the core even for the same version: every open connection ends in EOF (S§1). `server restart` takes 0.3 s over ssh (3.3 s once) | An in-app install or update is followed by a reconnect, not an error |

What the app side already has (Waycar maps, 2026-10-29):

| # | Fact | Consequence |
|---|---|---|
| W1 | Each Backend is one `ConsoleScope(host, backend)` projection: `HostConsoleProjection` + `EventsSession` + one `Transport` over the Host's one pooled SSH session. The backend is chosen in `ConsoleStore.desiredBackends` and instantiated in one `switch`, `SSHTransportConnector.connect(settings:backend:replacing:)` | The seams for the pick and for the new transport |
| W2 | `Transport` has 70 members: 24 required, 46 defaulted (default = no-op, empty or throw). The UI learns support from three capability booleans, `agent.backend ==` branches and thrown defaults | Section 7 and 10 |
| W3 | `TmuxTransport` is the precedent for a terminal-only backend: it fabricates `SessionSnapshot`, synthesizes `HerdrEvent`s and throws `HerdrAPIError` codes the UI branches on | Copy its shape (pure builders plus one actor) |
| W4 | `HostBackend` is switched exhaustively in 10 places and looped with `allCases` in 9. The raw value is persisted in synced `ClosedSession.backend`, in cache envelopes and file names, and in `HostBackendPreferences.newAgentBackend` | Section 3; ADR 0031 consequences |
| W5 | `Host` has 10 coded keys; per-Host backend choices live in `HostBackendPreferences` (one synced blob), not on `Host`, because a `Host` edit restarts the projections and an older build strips unknown `Host` keys | The pick is a preference, not a `Host` field |
| W6 | Notification banners and Live Activities read a registration file through the Transport; the default throws `pluginNotInstalled`. Host Tools' `install.sh` exits unless herdr or tmux 3.2 is present | Slice 1 gates those surfaces for core Hosts; slices 3-4 remove the gate |
| W7 | `Host.swift` and the transport files are in the Android lineage's compile list and must stay Foundation-only. `Waycar.xcodeproj` is committed and CI never runs xcodegen | New files need a regenerated, committed project; no UIKit/SwiftUI in transport code |

## 2. Naming and copy

- "Herdr TUI" is the original `herdr`; "herdr-core" is `hc`. Say "the Herdr app" only for the desktop app.
- `HostBackend.herdr.displayName` stays "herdr" in running copy (help pages, errors). The picker and anything about the pick use the two full names.
- Waycar is not affiliated with herdr: keep that sentence wherever Install copy appears.
- The binary the app runs is `herdr-core`, never bare `hc` (section 4).

## 3. Which runtime a Host uses

> **2026-11-01 amendment:** the exclusive-slot resolution and UI below are
> historical, superseded by ADR 0031's side-by-side amendment. Both detected
> runtimes now keep independent projections in one Console, alongside tmux.
> The lead is internal and TUI-first, falling back to core when needed;
> protocol memory and runtime-specific operations stay on their owning Backend.
> Host settings contain only per-runtime visibility toggles, no lead or launch
> default. New Agent alone offers a segmented picker for new-Workspace launches
> when two or more Backends are present: Herdr TUI, Herdr Core, tmux, in that
> order. The choice is remembered per Host in `RecentWorkspaceStore`, including
> tmux; existing Workspaces continue to decide their own Backend. The app repairs `core_enabled` on
> both-runtime detection to match core visibility (default true), not the lead;
> hiding core writes false. Hiding TUI does not silence herdr-owned notifications.
> Host Tools already support this contract: no plugin version bump or hook
> environment/tty guard changes are required.

Resolution is a pure function of detection and the pick, and it decides the Host's herdr slot:

| TUI found | core found | pick | herdr slot |
|---|---|---|---|
| yes | no | any | `.herdr` |
| no | yes | any | `.core` |
| yes | yes | none | `.herdr` |
| yes | yes | `tui` | `.herdr` |
| yes | yes | `core` | `.core` |
| no | no | any | `.herdr` (its projection reports what is missing, as today) |

`backends` is that slot plus `.tmux` when tmux is usable and shown. The resolution lives next to `HostBackendPresence.backends` and `ConsoleStore.desiredBackends`, takes the Host's `HerdrRuntime?` pick, and has a table-driven test for every row above and for tmux in every combination.

Storage:
- A new `HerdrRuntimePreferences` store (UserDefaults `host-herdr-runtime-preferences`, JSON `{version:1, hosts:{<uuid>:"tui"|"core"}}`), registered as its own `SyncedPreference` beside `HostBackendPreferences` (`WaycarAppModel`), whose `reload()` runs `ConsoleStore.reconcileAllBackends`. Absent means no pick; setting nil removes the entry. It is not a key inside `HostBackendPreferences`: an older build decodes that blob with fixed keys and writes it back without the new key, and iCloud would sync that as the pick's removal. An older build ignores a separate key, so the pick survives it.
- `newAgentBackend` keeps its two stored values (`herdr`, `tmux`). `herdr` means "this Host's herdr slot, whichever runtime it resolves to". Never write `core` to that key: an older build fails the whole preferences blob on an unknown raw value.
- Presence gains `core: CorePresence?` (version, binary path) decoded with `decodeIfPresent`, so cache files written before this change still read. `<host>.backends.json` stays the cache for presence.
- Duplicating a Host does not copy the pick (preferences are keyed by Host id; same as `showsTmux`).

UI:
- Host detail, "Backends" section (`HostOnboardingView.backendPreferencesSection`): today it shows only when herdr and tmux are both present. It also shows when TUI and core are both found. First row: Picker "Herdr runtime" with "Herdr TUI" and "herdr-core". Footer: "This Host has both. They don't share agents, so Waycar shows one. Pick the one this Host uses." With no pick, the footer adds "Showing Herdr TUI until you choose."
- A change calls the existing reconcile path: the old scope ends (its cache file is deleted with the scope, as for `showsTmux`), and the new one starts from its own cache file when there is one, else empty until its first snapshot. Switching back therefore shows the old runtime's rows after its first snapshot, not at once. No `Host` edit, no projection restart of tmux.
- The Host card gets a muted "herdr-core" badge when the Host's backends are exactly `[.core]` (as `TmuxBadge` does for tmux-only Hosts). A TUI Host shows none.
- `HostOnboardingStore.isDualBackend` today is "backends equal `[.herdr, .tmux]`". Generalize it to "a herdr-slot backend plus tmux", so a core Host with tmux keeps the tmux toggles, and add the separate "both runtimes found" condition for the picker.
- Discoverability: while a Host has both runtimes found and no pick, the Console shows one Host issue row in the slot of "No tmux or herdr on this Host" (`ConsoleHostStatusPresentation`): "Both Herdr TUI and herdr-core are on <Host>. Showing Herdr TUI. Tap to choose." Tapping opens Host detail, Backends. Any pick, including "Herdr TUI", removes it. Nothing else changes in the Console meanwhile.
- A dual Host with a pick of `core` in the Console shows tmux rows badged `tmux` as today; core rows are unbadged like TUI rows.
- Accessibility identifier for UI tests: `host.herdrRuntime.picker`.
- `HostOnboardingStore` gets a fresh detection on appear (it already runs `runChecks`); a failed detection keeps the cached presence.

Why not on `Host`: see ADR 0031. Why not hide the choice when only one is found: the pick stays dormant and is not lost when the other runtime is later uninstalled and reinstalled.

## 4. Detection and presence

Extend `HostBackendDetection.command` (still one `/bin/sh -c` exec, marker-delimited, tolerant of login chatter, CRLF and truncation). Add, before the end marker:
- `core=<version>` and `corepath=<absolute path>` when a candidate passes. Candidates, in order: `herdr-core` then `hc` found by `command -v`, then in the Herdr app's usual directories (C14). A candidate passes only if its `--version` output is `hc <digits>`; `hc: herbstclient 0.9` must not pass.
- Nothing that starts a core. `herdr-core --version` does not. Never run `hc server status` or `hc ls` in detection (C2).
- Reuse `docs/research/herdr-core/hc_detect.sh` as the starting script; it was tested against a foreign `hc`, a missing install and `~/.local/bin` off PATH. It cannot tell a stale socket from a live core, and does not need to: connecting starts a core.

`HostBackendPresence` stays `Codable`/`Equatable`; `herdrOnly` stays as is. `HerdrHostPath.extraPATH` gains the Herdr app's directories for the core exec lines. `isBareHerdrCommand` and the exit-127 mapping learn the `herdr-core` command (today they match only the word `herdr`).

Failure vocabulary: not installed (exit 127 plus the stderr text) maps to a new `TransportError` for core missing; version below the floor or a missing required method (`hello.methods`) maps to "update herdr-core on this Host" with `herdr-core update` in the copy (the app runs `herdr-core`, never bare `hc`, section 2); a refused generation (`unsupported_generation`) says Waycar needs an update.

Add Host and Host detail checks: `HostOnboardingStore.runChecks` and `PreflightReport` (`Preflight.swift` 131 and 303, `HostOnboardingStore` 173, 181 and 205, `HostOnboardingView` 730) treat only herdr (ping, then all passed) and tmux as passing. A core-only Host would connect, ping as core and end with no report, and the Add Host flow would not finish. Core gets its own checklist (connect and marker, `herdr-core` found and at or above the floor, `hello` generation and required methods, one `events.subscribe`), skips `listSessions`, and Host detail shows the result.

Analytics: `console_active.backend` gains the values for core (`core`, and a combined value with tmux). `PRIVACY.md` lists those values and says what the presence cache holds now; the test that pins the vocabulary changes with it.

## 5. Transport

> **#389 amendment (2026-11-11):** Waycar no longer lets `connect` start
> core. `CoreConnectCommand` probes with a plain Unix connect (Perl's
> `IO::Socket::UNIX`; off macOS Python's `socket` when Perl or its module
> is missing; a socket-file check, which a stale socket passes, when
> neither is there), in the same exec before the marker. A stopped core
> exits 125 and maps to `.coreNotRunning`; exit 127 remains
> `.coreNotInstalled`. Socket derivation
> mirrors Host Tools (`HC_SOCKET`, `HC_TERMINAL_SOCKET`, normalized session,
> absolute XDG paths, logind, state); `HC_SOCKET` is pinned for connect and
> start and attach. Config-file socket overrides remain unsupported, as in
> Host Tools.
> Only Start Herdr Core or a found Backend Install calls `server status`,
> which starts a detached core and returns. It exports the connect line's
> login PATH. On macOS the shared one-shot Interactive launchd job runs in
> `gui/<uid>`, forwarding PATH, HOME, the pinned socket and set HC_SESSION /
> XDG_RUNTIME_DIR / XDG_STATE_HOME, without adding LC_ALL. The attach line
> runs the same probe first, so a core that stopped after the connection
> came up is reported (125), not restarted. Earlier auto-start descriptions
> below record the original implementation, not the current behavior.

New directory `Sources/Waycar/Transport/Core/`. Foundation only.

Connection:
- One non-PTY exec channel through the duplex-exec primitive `TmuxTransport` uses (`openControlChannel`). Admission: tmux already holds the single `.control` lease, and a Host can run core and tmux together, so core gets its own class `.core` (limit 1, sharing the ordinary session budget as `.control` does). `SSHChannelAdmission.Limits.production` and the `MaxSessions` arithmetic in its comment are updated (today 1 control + 5 attach + 3 ordinary = 9 of 10; with both, 1 + 1 + 5 + 2 = 9), and a test opens core and tmux together.
- `HostControlChannel` (the protocol in `HostSSHServices.swift`) has only `write`, `read` and `close`. Core needs how the command ended: exit 127 and its stderr text, `hc`'s own error line, and "an exit status ends the transport". The protocol gains `exitStatus` and `standardErrorTail`, which the concrete `HostSSHControlChannel` already has, and every `HostSSHServices` test double changes with it. The Mirror bridge path takes an `.attach` lease, which is the wrong class here.
- A non-zero exit before the `hello` reply: read the stderr tail. `hc connect` prints one line `{"error":{"kind","message","hint"}}` there (observed with a socket path over the limit, 107 bytes on Linux and 103 on macOS: exit 2, stdout empty). Show `message` and `hint`.
- Command (shape from herdr-core's own client; quote with `ShellWord`): `sh -c 'PATH=<login PATH>; p=<detected path or $(command -v herdr-core) or $HOME/.local/bin/herdr-core>; [ -x "$p" ] || { echo "herdr-core is not installed here" >&2; exit 127; }; printf "%s\n" <marker>; exec "$p" connect'`. The client discards every byte up to and including the marker line (C21), bounded (give up after 64 KiB or 10 s with "extra text on login"); the first byte after it must start the `hello` reply, else the connection fails with a plain message. Core uses its default session. `Host.sessionName` selects a TUI session and stays a TUI-only setting: reusing it would point a Host with a TUI session named `work` at an empty core session named `work`. The Host form's session footer says "Herdr TUI only". A core session field can follow if anyone needs one. Never run a bare login shell and feed it a script (motd).
- Login PATH, slice 1: a core that nobody has started yet is started by this very connection and freezes its environment for every terminal on the machine, the desktop app's included (C5). So the connect line exports the Host's login PATH, never the SSH default. It is resolved once per Host over an SSH exec of the login shell (`$SHELL -lc 'printf %s "$PATH"'`, marker-delimited like detection, with a fallback that appends the usual directories), remembered in `HostConnectionMemory` like the home directory, and re-resolved once when a launch fails with `spawn_failed` and after a Backend Install (C22). If it cannot be resolved, use the usual directories (C14) ahead of the SSH PATH rather than failing.
- `-T`, `ServerAliveInterval=15`, `ServerAliveCountMax=4` equivalents are the SSH layer's job (herdr-core's own client uses the same values for its machine links).

Layers (pure where possible, so they test without a process):
1. `CoreFrameCodec`: `[channel u32 LE][kind u8][len u32 LE][payload]`, max payload 16 MiB; kinds DATA 0, CREDIT 1, CLOSE 2, RESIZE 3, FOCUS 4, FACTS 5. Buffers partial headers and partial payloads; frame boundaries are arbitrary (A§1). Replay `fixtures/attach-wire-minimal.*` and the captured event streams.
2. `CoreRPCClient` (actor): `hello {framed:true, generation:1}` as a plain line first, then frames. Channel 0 JSON-RPC, ids to continuations, calls concurrent, a per-call timeout (30 s default), reply keys read by name. Errors: `data.kind` is the discriminator (`code` is -32000 for almost everything), `hint` may be empty, and an unknown kind is a generic failure showing message and hint. Section 7 has the mapping to `HerdrAPIError` codes.
3. `CoreInventory` (pure): terminal table from the subscribe snapshot, `apply(event)` exactly as the schema README's table says (herdr-app's `EventLines::apply` is a working reference), ignores events with `seq` at or below the snapshot's, replaces everything on `missed`. Drops nothing for `finished`; the snapshot builder excludes finished terminals.
4. Events: `events.subscribe {}` (unfiltered, so `doc` events arrive too; ignore them) on channel 0 returns `{channel, seq, terminals}`. Lines arrive in DATA frames on that channel and can split mid-line. Send CREDIT with the payload length after each frame is consumed. A heartbeat arrives about every 15 s when no event is queued; no frame at all for 45 s is a dead connection (close and reconnect). A heartbeat is not an event.
5. Reconnect: EOF, an exit status or a timeout ends the transport; the existing `EventsSession` machinery redials. Every reconnect does `hello`, `events.subscribe`, and replaces all state with the snapshot (never merge across connections; `seq` restarts). Terminals survive, so Console rows do not close.

`ping()` returns `ServerInfo(backend: .core, version, protocol: generation)` from `hello`, and `server.status` is the liveness check. `awaitSocketPathReadiness` is a no-op (core resolves its own path).

Synthesized events: map core events to the herdr kinds the projection already reads (`HostConsoleProjection` reads `pane.agent_status_changed {pane_id, agent_status}`, `pane.updated {pane}`, `pane.agent_detected {pane_id, released}`; any kind in `resyncEventKinds` triggers a re-snapshot). Core `status` becomes `pane.agent_status_changed`; `created`, `restarted`, `finished`, `lost`, `removed`, `labels` and identity-changing `foreground` become a resync kind; `title`, `size` and `turn` need no event unless the row shows them. `sessionSnapshot()` answers from `CoreInventory`, with no round trip.

As built in 1b (`Sources/Waycar/Transport/Core/`):
- Channel 0 carries one JSON message per DATA frame, with no trailing newline (captured, `attach-wire-minimal`). The "lines that can split mid-line" are the events channel's. A client that waits for a newline on channel 0 never sees a reply: found by the live suite, not by the fakes.
- `CoreRPCClient` runs one reader task and one writer task (an ordered `AsyncStream` of whole frames), so frames never interleave. A connection ends once, for one reason (`close()`, EOF, a read or write error, a malformed frame, 45 s of silence while subscribed), and that reason fails every pending call, the notification stream and every later call.
- A connection carries one events subscription, which feeds the inventory for the connection's whole life. A stream the consumer ends does not touch the connection: `EventsSession` resubscribes whenever its pane set changes, and the next `subscribeToEvents` hands out a new stream over the same inventory with no round trip. A lost connection is never repaired in place: the stream ends with the failure and `EventsSession` dials a replacement transport.
- Methods the floor check requires (`CoreTransport.requiredMethods`): `server.status`, `events.subscribe`, `terminal.list`, `terminal.read`, `terminal.send`, `terminal.keys`, `terminal.kill`. A snapshot asked for before any subscription is one `terminal.list {all:true}`.
- The login PATH is resolved by `CoreLoginPath` (`$SHELL -lc`, marker-delimited, 8 s), kept in `HostConnectionMemory.loginPATH` (`ConnectionFacts`, decoded when absent), forgotten after a Backend Install (`ConsoleStore.backendInstallEnded`); the re-resolve on `spawn_failed` belongs to slice 2.
- `HostSSHServices.openCoreChannel(command:)` takes the `.core` lease; `HostControlChannel` has `exitStatus(timeout:)` and `standardErrorTail()`. Exit 127 from `CoreConnectCommand`'s own lines (they print the not-installed text) is `.coreNotInstalled` for both the connect and the attach line (`HerdrHostPath.missingBinaryError`).
- New `TransportError` cases: `.coreNotInstalled`, `.coreNeedsUpdate(detail:)`, `.coreNeedsWaycarUpdate`, `.coreRefused(message:hint:)`. The Add Host and Host detail checklist is `connection`, `remote environment`, `herdr-core installed`, `herdr-core 0.1.10 or later` (also the method check), `herdr-core answers` (connect line, marker and `hello`), `herdr-core live updates` (one `events.subscribe`).
- `HerdrRuntimePolicy` and every `coreEnabled` parameter are gone: a Host resolves to `.core` as soon as the table says so.

## 6. Inventory mapping

Ids: Pane `hc:<address>`; Terminal `hc:<core.id prefix>:<address>` (a state wipe restarts addresses at `t1`, and `core.id` changes then); Tab `hc:tab:<key>`; Workspace `hc:ws:<key>`. Addresses with a `/` (terminals of machines the core added) stay opaque.

Topology (flat core becomes the herdr model; C15):
- Workspace key: the terminal's `herdr.space` label when non-empty, else its start `cwd`, prefixed by its machine (`box/`) when remote. Label: the folder basename of the space's first terminal by address order (`~` for the home folder, `Terminals` when nothing else is known), prefixed `box · ` for a remote machine. Parked terminals (empty label) fall back to the folder rule.
- Tab key: `herdr.tab` label when non-empty within a Workspace, else one Tab per terminal. Tab label: the terminal's `name`, else its title, else the program's name. A Tab with several labelled terminals has several Panes.
- Pane per terminal: `cwd` = `foreground.cwd`, else the start `cwd`; `terminal_title` from `title`.
- `WorkspaceInfo`/`TabInfo` roll-ups (agent status, pane and tab counts, active tab) are computed here. `focused` is always false (core has no focus).
- Finished terminals are not rows. A terminal that disappears (finished or removed) is a closed Agent the way a closed TUI pane is (Closed Sessions, `onAgentsClosed`).
- Order is stable: Workspaces by first appearance, Tabs by address order.

Agents and kinds:
- A terminal is an Agent when it has reported (`reported`) or its kind is recognized; otherwise it is a Shell row (`PaneInfo` only).
- Kind: the report's `app` against `SupportedAgentKind` (raw value, executable, known aliases such as `claude-code`), else the foreground command line through the same detection tmux uses (`AgentKindDetection.kind(commandLine:)`, extracted from `TmuxAgentDetection` in 1b; Claude renames its process title to its version number, so match on argv). Unknown `app` strings stay as the display name with kind unknown.
- `AgentInfo`: `agent` kind, `name` the terminal's name, `agentStatus` (below), `stateChangeSeq` from `status_ms`, no `agent_session` (core has none: Closed Session resume falls back to each kind's picker or latest session), `launch_pending` false, `interactive_ready` true.
- Shell Activity comes free: busy when `foreground.pid` differs from the terminal's `pid`, idle when equal; absent `foreground` is unknown (the default).

Status:
- `status.state` maps `idle` to idle, `working` to working, `done` to done, `blocked` to blocked, `error` to blocked. `status == null` or `reported == false` is unknown. Any other word is unknown. `kind` and `msg` are not shown in slice 1.
- Core never clears `done` on its own, and Waycar's `focusAgent` turns Done into Idle on herdr. For core, `focusAgent` is a client overlay: remember `(address, turn)` when the user opens a Done Agent and present idle until the status word or `turn` changes. No RPC is sent.
- No `status` means Unknown in the Console. The existing Unknown help page gains a core paragraph: agents show status when they speak OSC 7501.

## 7. Transport members on core

Required members first, then the defaulted ones that need an override. Everything else keeps the default.

| Member | Core |
|---|---|
| `ping`, `revalidate` | `hello` (version, generation); `server.status` for liveness |
| `listAgents`, `sessionSnapshot` | from `CoreInventory` |
| `readPane`, `readAgent` | `terminal.read {lines}`; `lines: 0` is the visible screen, more is scrollback above it. Alt-screen programs have no scrollback (`complete: false`); the screen is 120 rows when nobody is attached |
| `promptAgent` | Screen checks as for herdr and tmux (sign-in, folder trust; via `terminal.read`), then `terminal.send {terminal, text}` without `wait`. `blocked` becomes `agent_blocked`; `unavailable` ("still starting", "lost, waiting") becomes `agent_not_ready`; `finished` and `not_found` become `agent_not_found`. `started: false` or `null` is not an error |
| `checkAgentInputScreen` | `terminal.read` plus `AgentScreen` |
| `sendAgentKeys` | `terminal.keys {terminal, keys}` after the name table below. Never `force`: keys are not refused when blocked |
| `sendPaneInput` | `{text, keys: [enter]}` is `terminal.send`; text alone has no RPC (send is paste plus Enter): throw unsupported and have the Composer keep text local; keys alone are `terminal.keys` |
| `closePane`, `closeTab` | `terminal.kill` (idempotent), nothing more: the record stays readable for core's retention window, as when the Herdr app closes a pane |
| `focusAgent` | the local overlay in section 6 |
| `subscribeToEvents` | section 5 |
| `attachTerminal`, `probeMoshServer`, `runMoshBootstrap` | section 8 |
| `shellActivities` | from `foreground` (section 6) |
| `startAgent` | section 9 (slice 2); until then unsupported with a plain message |
| `startAgentInNewWorktree`, `...InNewWorkspace`, `renameAgent`, `renameWorkspace`, `movePane`, worktree list/remove | not supported on core; the UI is gated by capability (section 10); the members throw `HerdrAPIError` `unsupported` |
| `isConnected`, `close` | channel state; `close` ends the exec channel (core detaches the viewer at once) |
| notification registration, config, summaries, chat markers and transcripts, sidebar layout | default (`pluginNotInstalled`, empty) until slice 4 |
| file and host-exec members (`listDirectories`, `remoteHomeDirectory`, `gitBranch`, preview, skills, resource usage, `stageImage`/`stageFile`) | the existing SSH-exec implementations through `HostSSHServices`, as tmux does; `stageImage` may use `terminal.put` later |

Key names (Waycar toolbar spelling to `terminal.keys`): identical for `esc tab shift+tab enter backspace left right up down home end insert delete pageup pagedown f1`-`f12`, letters, digits, `space`, `backslash` and `ctrl+`/`alt+` chords; `minus` is `-`, `comma` `,`, `period` `.`, `slash` `/`, `quote` `'`, `semicolon` `;`, `backtick` `` ` ``; `plus double_quote colon percent ampersand` and shifted symbols cannot be sent by name (the toolbar types them into the open Attach, which is the usual path; a voice or composer shortcut that needs one reports it as unsupported on core). `⇧Enter` stays `ctrl+j` (a newline), as on herdr. A table-driven test pins every toolbar key against the accepted list.

Error mapping (core `data.kind` to what the UI branches on):

| core kind | `HerdrAPIError` code |
|---|---|
| `not_found`, `finished` | `agent_not_found` / `pane_not_found` (by call) |
| `blocked` | `agent_blocked` |
| `unavailable` | `agent_not_ready` |
| `spawn_failed` | `agent_start_failed` after the folder was validated (the program is missing) |
| `name_taken`, `invalid_params` | `invalid_argument` with the message |
| `unsupported_generation` | transport failure: Waycar needs an update |
| anything else | `core_error` with `kind`, `message` and `hint` kept |

(`agent_start_failed`, `invalid_argument` and `core_error` are new codes the UI treats as a generic failure unless a screen needs more.)

As built in 1b: `probeMoshServer()` answers false and `runMoshBootstrap` throws, so the mosh runner never tries core and Attach stays on SSH (mosh stays slice 5). `readPane`/`readAgent` ask `lines: 0` for `visible` and the request's lines (capped at 1000) for `recent`, drop trailing blank rows and keep the last `lines`; `closeTab` kills every terminal of the Tab; `sendPaneInput` with text and no Enter throws `unsupported` (core's `send` always presses Enter). A status event that moves a seen Done terminal on prunes the Done overlay (`CoreDoneOverlayMachine`'s `inventoryChanged`), and a `turn` that does so with the same word presents Done again (`recordMoved`, B-23).

## 8. Attach

- `attachTerminal` builds a PTY exec: `/bin/sh -c '<PATH>; <marker>; exec "$p" attach "$1"' attach '<address>'` with the PTY's columns and rows, through the same `HostSSHSession.attachTerminal` and bootstrap-marker gate herdr uses. The id is rejected if it contains `'`, `\` or a control character, as for herdr.
- No takeover: `takeover: false` in capabilities, so `HostTerminalOwnership` never shows Live in Another Window or Take Over for core rows (tmux rows already skip them). The app may attach several terminals at once (the Host's attach limit applies); desk viewers keep typing.
- Size: the phone's size applies while it is the newest active typing viewer; the desk's returns when the desk types; the last detach snaps to 200x120. The first attach to a terminal nobody watches resizes it from 200x120, so a reflow is expected. A dropped connection leaves a ghost viewer on the Host for as long as sshd keeps the session (C23); it still leads the size while nobody else is active. The app closes its own attach channels when it leaves (the core detaches at once on a clean close); only a dead link leaves a ghost.
- The end of an attach: `hc attach` exits 0 for everything and prints one status line (`[detached from t3]`, `[t3 finished: exited]`, `[lost the core; it keeps t3 running: hc attach t3]`). Do not classify by that text: ask the inventory (terminal finished: Session Ended; live: reconnect). The line may reach the screen; that is fine. OpenSSH adds `Connection to ... closed.` after it; the app's SSH library does not.
- `Ctrl+\` detaches (C12). The key toolbar has no such key; a hardware keyboard could send it. The Attach treats the resulting exit as a detach and offers Reconnect.
- mosh: not built for core (slice 5, WAY-483). `moshAttachCommand` does not fall out of the shared code cheaply: its bootstrap script refuses `'` and `\`, and core's attach line carries the login PATH and a not-installed message that use both, so it needs its own quoting and a live mosh-server run. `probeMoshServer()` still answers false and Attach stays on SSH. A later task.
- Watch-only Mirror: none. Mirror was removed from the app on 2026-10-31 (`docs/design/mirror.md`); `hc attach --observe` over a non-PTY exec, which streams raw output, stays the route if a watch-only view returns.

## 9. Start an agent on core (slice 2)

1. Login PATH: the resolver of section 5. A core that is already running keeps its own PATH, so every launch also sends it as `env.PATH` (step 3). The core's own PATH is never trusted (C5).
2. Folder: absolute (`~` expanded by the app from the resolved home), validated with `machine.exec {argv: ["test","-d",<dir>]}`. A relative folder is an error.
3. `terminal.run {argv, cwd, env: {PATH}, labels: {"waycar": "1", "waycar.kind": <kind>}}`, no `wait`, no template. `argv` is the kind's launch command from the shared launch builder (extract it from the tmux launch code; codex gets `--no-daemon`, per `hc --skill`, or its commands run outside core). Do not name the terminal (names are unique among live terminals and `name_taken` is avoidable). A `spawn_failed` after step 2 means the program is missing: say "<kind> is not installed on this Host, or is not on its PATH", not core's raw text.
4. A first prompt (including Chat Mode's) waits for `status.state == idle` from events. An agent that never reports is read with `terminal.read` after a short wait and prompted only when its input is on screen (`AgentScreen.inputIsOnScreen`, the opencode/kilo/cline gate). Then `terminal.send`. Do not resend after a failed or slow send: read first (core's own rule).
5. The returned `Agent` is built from the run reply's record. The terminal appears in the Console through the normal event path.

The New Agent sheet on core: kind picker and folder only; the worktree and new-Workspace options are hidden (capabilities), not disabled with a reason, because nothing the user does enables them.

As built in slice 2 (WAY-476):
- The shared launch builder is `AgentLaunchBuilder` (`argv` for core, `shellLine` for tmux, one set of rules for the executable, `--no-daemon` and the environment names). Core sends the request's environment as `terminal.run`'s `env`, with `PATH` added, instead of an `env` prefix. `--no-daemon` is probed with `machine.exec codex --help` on the PATH the launch uses.
- `env.PATH` is taken literally by core, so `$HOME` and the mise expansions of the usual directories are evaluated by one exec on the Host (`CoreLaunch.launchPathCommand`): the login PATH first, the usual directories after it. A launch that fails `spawn_failed` after the folder passed asks the Host for its login PATH again (C22) and retries once, only when the PATH changed; otherwise it says "<kind> is not installed on this Host, or is not on its PATH" (`agent_start_failed`). A folder that is not there is `folder_not_found`.
- A core Workspace is a folder, so "a new folder" is the existing `startAgentInNewWorkspace` with the directory and no label, and a launch into an existing Workspace uses the first terminal's start folder (or `request.cwd`). Default Shell is hidden on core (`offersShell`): a plain terminal has no start path yet. Chat Mode follows the same rule as on any Host, now that slice 4 gave core Host Tools.
- The first-prompt gate (`CoreLaunchGateMachine`, checked by `promptAgent` after the sign-in and trust screen checks): a terminal that has reported through OSC 7501 is ready (the Composer's delivery rules and core's own `blocked` refusal do the rest); one that has not is left alone for `unreportedWait` (5 s), then read, and let through only when its kind's input marker is on screen, or, for a kind with no marker, when something is drawn and the kind's own minimum delay has passed. A transport with no event subscription asks `terminal.get` for the record.

## 10. Capabilities and gating

`HostBackendCapabilities` today has `takeover`, `pluginRowLayout`, `namedSessions`. Add what the UI branches on today with `agent.backend ==` and make each site use the flag or an explicit `.core` decision (the maps list the sites: `ConsoleView` 1446, 1457, 1490, 1576, 1858; `ConsoleStore` 1172, 1754, 1816-1819, 1862, 1955, 2941, 3447, 3501, 3821, 4257; `HostConsoleProjection` 1878, 1955; `StartAgentStore` 309, 334, 1788; `LaunchPromptStager` 313, 383; `AgentNotificationRouter` 34, 104; `WatchStateBuilder` 185; `AgentGlanceList` 74; `TypedLaunchDetector` 291; `UnreadAgentsStore` 45; `EventsSession` 1113). Core's row:

| capability | herdr | core |
|---|---|---|
| `takeover` | yes | no |
| `pluginRowLayout` (sidebar layout) | yes | no |
| `namedSessions` | yes | no (default session only) |
| worktrees, new Workspace | yes | no (slice 6) |
| rename Tab/Agent/Workspace, Move to Workspace | yes | no |
| Host Tools surfaces (notifications, Live Activity, Chat Mode, summaries, pairing offer, plugin update) | yes | yes (slice 4) |

For a core Host with no Host Tools: slice 4 removed the gates, so it gets the same Install Waycar Host Tools row, offer and update flow as any other Host (the installer accepts a core-only Host since slice 3). Host detail no longer says "Not available on herdr-core yet." The Unknown-status help and the copy still never promise a push for an agent that does not report OSC 7501.

As built in 1a: `HostBackendCapabilities` gained `hostTools`, `worktrees`, `renaming` and `startsAgents` beside the three it had (core: all four false; tmux: `worktrees` true, since it has sessions and git worktrees, `renaming` true for Agent and Workspace). Slice 4 removed `hostTools` again, with the "unknown" Host Tools state it drove (`ConsoleStore.waycarPluginStatus`) and the "Not available on herdr-core yet." lines in Host detail and the notification row. Rename Tab stays herdr-only by an explicit `== .herdr`. `WatchStateBuilder.statusSince` is nil for core until 1b settles the unit of `status_ms` (the research does not say whether it is an epoch). `CorePresence.meetsFloor` reads the version's first three numbers, so `0.1.14-rc1` counts as `0.1.14`.

Section 4 says `HerdrHostPath.extraPATH` gains the Herdr app's directories; as built they are a separate `HerdrHostPath.coreExtraPATH` (the Nix profile and NixOS system profile), exported by `corePathExport` in the detection script and in the wrap of a bare `herdr-core`. `extraPATH` itself is shared with commands the plugin's tests pin (the update command's fixture), so it did not change.

`AgentNotificationRouter.backend(of:)` collapses to tmux or herdr today: teach it `hc:` ids. `Watch` sequence units (`WatchStateBuilder:185`) compare `stateChangeSeq` within one backend: core's is a millisecond clock like tmux's sequence; keep the units per backend.

The herdr slot also owns roles that are written as `== .herdr` today. Each moves to whichever backend fills the slot. Review of this design found them; line numbers are from `d480fc05`, so re-grep at build time:
- `ConsoleStore.endProjection`: the `scope.backend == .herdr` branch hands Host-level probes and Chat Marker reads to another projection.
- `connectionMemory: backend == .herdr ? memory : nil` and `EventsSession`'s protocol-version memory: core's generation must never be stored as herdr's protocol number.
- `waitsForHerdr` (tmux waits on the herdr slot, not on `.herdr`) and `leadProjection`.
- `ConsoleInventoryCache`'s file suffix (`.herdr` has none, core gets `core`; pin it in a test).
- `SSHTransportConnector.connect` defaults to `.herdr` and its `switch` needs the core case.

Declare `.core` between `.herdr` and `.tmux` in the enum, and write `leadProjection` and `waitsForHerdr` by backend, never by position in `allCases` (projections are iterated in that order).

## 11. Host Tools core mode (slices 3 and 4)

Needs plugin 2.0.0 (WAY-443, PR 348) merged first: it deletes the Node reference, so a core mode is written once, in Rust.

Plugin side (slice 3, plugin 2.2.0; WAY-479 corrected this list: the first draft had `install.sh` gated wrongly, missed the extensions, the marker GC and the stale environment, and said the tty guard does not apply):
- `install.sh`: a core-only Host installs the standalone Host Tools (the tmux-mode shape: no herdr plugin to link, `waycar` CLI, hooks, `~/.config/waycar`). `detect_backends` learns core with the same `--version` rule (`herdr-core`, then `hc`, in `PATH` and the C14 directories; run nothing but `--version`); the error text names all three; a Host with the TUI, core and tmux needs no new flag. `waycar hooks install` is gated on core or tmux 3.2+, not on the mode: it used to run only when tmux was usable, so the gate is widened (this also installs the hooks on a herdr + core Host). The success line `installed Waycar <v> for tmux in <dir>` stayed as it was in slice 3 (the app parses it); slice 4 changed the wording and the parser together (below). `waycar status --json` reports `backends.core` (version or null, appended after `tmux`, version stays 1); the app's `StatusHooksReport` learns it (decoded optionally).
- Agent hooks identify the terminal by `HC_TERMINAL_ID`: the pane id the app sees is `hc:<address>`; the hook reads the terminal with `herdr-core get <address> --json` and never trusts the hook's own PATH (core is found as `install.sh` finds it, with `HC_SOCKET` taken from `HC_TERMINAL_SOCKET`, so a hook never starts another core). **The tty guard does apply.** A core first started in a tmux or herdr pane hands every terminal that pane's `TMUX_PANE` and `HERDR_*` (terminals inherit the first caller's environment, C5), so environment variables cannot say which runtime is innermost, and a hook that exits on `HERDR_PANE_ID` or a mismatched `TMUX_PANE` would go silent in a core terminal. `bin/waycar-hook` therefore tries tmux first (its own tty check) and falls through to `waycar hook-status` when tmux does not take the hook and `HC_TERMINAL_ID` is set; that command takes the terminal only when the agent's controlling tty (the same `CLAUDE_PID`, parent and one-hop rules as the tmux guard, no hop for codex and cline) is the tty of the process core records as the terminal's `pid`. It also does nothing for a named `HC_SESSION` (addresses repeat across sessions), when `core_enabled` is false in `notify.json`, and when the terminal is not alive. And it never asks a core that is not listening: every `hc` subcommand but `--version` starts a core with the caller's environment frozen into it, and a process that merely inherited `HC_TERMINAL_ID` (a herdr pane started from a core terminal, once that core is gone) would otherwise start one holding that pane's `HERDR_*`. A plain connect to the socket (`core::running_core`) comes first, here and in every trigger that is not inside a core terminal's own hook. The Codex daemon trap is the same one (Waycar launches codex with `--no-daemon`).
- A `CoreBackend` implements the existing Rust `Backend` trait for notifications (`recheck` through `get`, `summarize` through `read`, `describe`, `attention`); the `hc:` prefix gets its own validator (`core::is_core_pane_id`) beside `is_tmux_pane_id`, and `waycar notify` accepts it. A terminal that never reported OSC 7501 (`reported: false`) has only what the hooks wrote: its `waycar.status` label must still be the event's status (so a later hook that moved it on during the hold drops the event, as for tmux), and with no label the hook is trusted; one that has reported must show the hook's status, with core `error` read as `blocked` and core `idle` with a higher `turn` than the hook recorded at `working` read as `done` (a turn end an agent may report as `idle`; to be confirmed against a live Claude Code). Chat Marker garbage collection learns the prefix (`hc:` markers are kept while core lists the terminal and kept when core cannot answer); the GC also runs from the core notify path, in an hourly slot of its own so it never takes the slot of the herdr hook's collection (which judges every backend), since it ran only from the herdr event hook. Chat Mode's reply push is not implemented on core: the marker's `terminal_id` needs `core.id`, which the CLI does not print.
- Status itself needs no hook: the agent's own OSC 7501 report is the status. Hooks start the notification on Blocked and Done and write labels on the terminal (`herdr-core label <address> k=v`; core has no field for these): `waycar.kind`, `waycar.turn` (core's `turn` when `working` was hooked), `waycar.status` (only while the terminal has reported nothing, so the conditional statuses of the hook still work), and `waycar.session` and `waycar.transcript` for Chat Mode and plan progress. `release` removes all five. The omp, pi, opencode and kilo extensions carry their own pane gate and write through `waycar hook-status <agent> session`.
- The Live Activity includes core terminals that report OSC 7501 and `activity-tick` keeps and prunes their plan steps in a bucket of their own. A herdr or tmux trigger, or `summaries refresh`, asks a core only when one already listens (a plain connect to its socket), because every `hc` subcommand starts a core with the caller's environment. A `herdr-core events` watcher for agents with no hooks, and screen-based status, stay out of scope.
- Plugin version bump per the AGENTS.md rule (2.1.0 to 2.2.0, on top of the FCM provider's 2.1.0); `scripts/check-plugin-version.sh`; `.github/workflows/core-distros.yml` beside `tmux-distros.yml`: `scripts/ci/core-distro-check.sh` installs the pinned core with its own installer in a container, runs `install.sh` with no flag as a non-root user, runs a fake OSC 7501 agent in a real core terminal whose Claude hooks must push for `hc:<address>` to `scripts/ci/relay-standin.py`, and with tmux checks that a core started from a tmux pane and a tmux pane each push once.

App side (slice 4):
- A shared `HostToolsService` and a `HostToolsTransport` protocol, extracted from `TmuxTransport+HostTools` and used by tmux and core; `CoreTransport` implements the protocol so registration, banners, Live Activities, summaries and Chat Mode work.
- The gates from section 10 are gone. `HostBackendCapabilities.hostTools` and `offersHostTools` are removed: every backend has Host Tools.
- `WaycarPluginInstall.Mode.core` is the third mode of the Host Tools offer and update flow.
- `WaycarPluginRequirement.coreMinimumVersion = "2.2.0"` applies only to Hosts whose resolved backends include core. `minimumVersion` stays 1.4.0. `scripts/check-plugin-version.sh` guards the new constant.
- `StatusHooksReport.Backends.core` reads the `backends.core` member of `waycar status --json`.
- `core_enabled` is written when the runtime pick changes on a TUI+core Host: false when the TUI is picked, true when core is. Also once per Host and launch on a detection that finds both runtimes with no pick: `false` (the TUI), and only into a `notify.json` that has no `core_enabled` yet (WAY-483), so a core agent cannot push while the Console shows the TUI.
- A core `agent_session` comes from the `waycar.session` and `waycar.transcript` labels.
- The installer line is now `installed Waycar <v> in <dir>` (plugin 2.2.1). The app's parser accepts it and the old `for tmux in` line; the herdr-mode line is unchanged.

## 12. Install from the app (slice 5)

`BackendInstallTarget` gains core: download `https://releases.herdr.dev/core/install.sh` to a temp file and run it, as the herdr target does (a pipe from curl hides a failed download), then run a fresh detection; the result is "installed" only when detection finds core. No wake step is needed (a fresh install starts no core, and the first `hc connect` starts one). Failure reasons to map: `hc: needs curl`, `hc: needs tar` (new), `hc: cannot reach ...` and `hc: download failed` (cannot reach installer), `hc runs on Linux and macOS for now` and `no build for ...` (unsupported system), checksum mismatch and `does not run on this machine` (other), exit 1 for all. The panel order on a Host with neither is Install Herdr TUI, Install tmux, Install herdr-core (decided in WAY-482); the consent sheet, the exact command and the "not affiliated" line follow the existing rules.

As built in slice 5 (WAY-483):
- Panel on a bare Host (iOS): Install Herdr TUI, Install tmux, Install herdr-core, all outlined, none recommended. A tmux that is too old offers TUI then core. `HostBackendGap.offersCore` is true for both gaps: core needs no admin rights. The core row uses the TUI's preflight rules (Linux or macOS, x86_64 or arm64, not Android, curl); `tar` is only known to the installer, so `hc: needs tar` is `BackendInstallFailure.noTar`. The Android button waits for WAY-484.
- The exec wrapper runs core like herdr: curl guard, temp file, no ignored SIGPIPE. A core counts as installed only when the fresh detection finds `core` at or above `CorePresence.minimumVersion`; an old core, or herdr alone, is `failed(.other)`. No wake step.
- Found and the Console: `ConsoleStore.backendInstallEnded` already forgets the Host's cached login PATH and calls `backendFound`, which records the presence and retries every projection. That covers the installer's update branch, which restarts a running core (same version too) and ends every connection in EOF: the projection reconnects on a new connection, with no error row. The panel only offers core where no runtime was found, so a Host that already runs core reaches this only through a stale presence or Check Again.
- The Found screen for core is "herdr-core Found" with one note and no Host Tools offer. The consent sheet is the approved copy, with typographic apostrophes as the rest of the app uses.

## 13. Tests and proof

Unit (Swift Testing, in the existing layout):
- `CoreFrameCodec` over the captured byte streams; partial headers, split payloads, 16 MiB limit, unknown kinds ignored.
- `CoreRPCClient` against a scripted duplex: concurrent calls, error mapping (every row of the table in section 7), EOF mid-call, timeouts, `hello` refusal paths (generation, missing method, below floor).
- `CoreInventory.apply` over the captured event sequence and `missed`; seq filtering; a restart (new snapshot replaces all).
- Snapshot builder: labelled and unlabelled terminals, parked, remote addresses, finished excluded, kind detection (`app` and argv), status table including `error`, `reported:false`, the Done overlay.
- Resolution matrix and the stores: `HerdrRuntimePreferences` round trip, sync merge and reset; a `HostBackendPreferences` blob an older build wrote, with and without `newAgentBackend`, leaves the pick alone; `newAgentBackend` is never `core`; presence cache without `core` still decodes; `ConsoleInventoryCache` file suffix for `.core`; `leadProjection` and `waitsForHerdr` with core + tmux in both declaration orders.
- Channel admission: core and tmux open their channels together on one Host and neither waits for the other; the arithmetic comment matches `Limits.production`.
- `HostControlChannel`: exit status and stderr tail through the services protocol, with the doubles updated; exit 127 with the "not installed" text; a non-zero exit before `hello` shows `hc`'s error line; a noisy `.bashrc` before the marker is discarded and a missing marker fails in bounded time.
- Add Host preflight on a core-only Host ends with a report.
- Detection parser with the fixtures style of `HostBackendDetectionTests` (chatter, CRLF, truncation, foreign `hc`).
- Key table against the accepted names; PATH quoting.
- UI test for the picker (`host.herdrRuntime.picker`) and for the Host detail with one runtime found (no picker).
- Recorded transcripts live in `Tests/WaycarTests/Support/CoreTranscripts.swift`, each constant documented with the command that produced it (the `TmuxTranscripts.swift` precedent). Regenerate from a neutral directory with the probes; never commit workspace paths.

Contract smoke against real `hc` (Linux, GitHub-hosted runner, no secrets): a CI job that downloads a pinned `herdr-core` release, checks its checksum against the manifest, and runs the probes' assertions (hello shape and methods, record fields, status event order, framed attach prelude and CREDIT stall, EOF on restart). A weekly run against `latest.json` warns, and does not fail PRs, when the shape drifts.

Live proof (the slice's acceptance, with the evidence in the PR):
1. Real sshd, real `hc`, no stubs: the core lab (`scripts/core-lab`, a throwaway Ubuntu container with OpenSSH, with sshd on a published port; its README has the exact commands) with core installed by its own installer over an SSH exec, the nine lab terminals (fake agents that print OSC 7501: idle, working, blocked with kind, done, error; one plain shell; three labelled `herdr.space`/`herdr.tab`), and the Mac itself as a second Host (macOS: no `/run/user`, a state-dir socket; unrun in the research). The app on a simulator shows the rows with those statuses; a status change reaches the row in under 2 s; the Composer prompt and a `down enter` answer arrive (`terminal.send` refuses a blocked agent); Attach shows the screen, types, resizes and ends cleanly on exit; Close kills; killing the core's connection (`herdr-core server restart`) reconnects with the rows intact and the terminals still running. A `.bashrc` that echoes above the guard still connects.
2. Both runtimes on one box (the existing herdr stub for the TUI): the Host detail shows the picker and the Console shows the choose row; no pick uses the TUI; picking core switches the Console without touching tmux rows; switching back shows the TUI's rows after its first snapshot. A preferences blob written by an older build leaves the pick alone.
3. A core-only box with a minimal SSH PATH: `claude`-style launch works through the login PATH (slice 2).
4. `make test-app` on the iPhone simulator, plus the iPad run for the Host detail change, as the engineering workflow requires. Simulator rules in AGENTS.md apply.

Not run in the research, and so not proof of anything: macOS Hosts (no `/run/user`, state-dir socket path, Herdr app co-running), the systemd user-service start path, a real Claude Code or Codex under core, the app's own SSH library (libssh2: window-change, keepalive, exec without a PTY). A real OpenSSH server was run (C20 to C24).

## 14. Slices

| Slice | What | Depends on |
|---|---|---|
| 0 | This ADR, design and research (docs PR) | none |
| 1a | `HostBackend.core` with every switch and `allCases` loop, the enum order, presence and detection, the resolution table and `HerdrRuntimePreferences`, picker, badge, Console choose row, Add Host preflight, capability flags and gating. Resolution never yields `.core` yet (one flag in the resolver) and the picker stays hidden, so nothing user-visible changes | 0 |
| 1b | `CoreFrameCodec`, `CoreRPCClient`, `CoreInventory`, the snapshot builder, `CoreTransport` read, input, close and attach, the `.core` admission class and the control-channel members, the login PATH resolver; flips the flag; help pages (`herdr-vs-tmux`, a herdr-core page, host-page Backends), CONTEXT, PRIVACY, README, CHANGELOG | 1a |
| 2 | Start agents on core: login PATH, folder, launch builder, first prompt, Closed Session resume | 1b |
| 3 | Host Tools core mode (plugin): `install.sh`, `status`, hooks, `CoreBackend`, CI job, version bump | 0; plugin 2.0.0 (PR 348) |
| 4 | App: Host Tools on core: registration, banners, Live Activities, summaries, Chat Mode, plugin update flow; gates off | 1b, 3 |
| 5 | Install herdr-core from the app; mosh for core if not in slice 1b | 1b |
| 6 | Follow-ups, each its own task: worktrees and new Workspace on core (git through `machine.exec`); watch-only Mirror from `hc attach --observe` (space and tab names from the `herdr-app` document shipped: `CoreAppLayout`, read-only, tolerant); screen-based status for agents without OSC 7501; Android parity on `android-main` | 1-4 |

Slice 1 was cut in two on review. The tmux build was 221 files, and 1a is the part that changes shared plumbing, so it lands with nothing user-visible before 1b adds the transport. The contract check is its own PR (PR 350). Core Hosts did not work at all before 1b, so a partial release changes nothing for existing Hosts: the TUI stays the default and tmux is untouched.

Every PR: a regenerated, committed `Waycar.xcodeproj` when files are added, a CHANGELOG entry for user-visible changes (written for users, no internal paths), a run-learnings entry in `docs/agents/run-learnings/`, `CONTEXT.md` terms (Backend, Host, Transport, Status Hooks, Host Tools, Notification Registration), and the Android compile-list note in the PR body.

## 15. Risks and open questions

- **Status coverage.** Only agents that speak OSC 7501 show status. Claude Code and Pi are reported to; for others it is unknown. Many first-run rows will read Unknown. The copy says why; screen detection is the later answer (slice 6).
- **Preview API.** core is 0.x, generation 1. The contract smoke and tolerant decoding are the defence. Add `hello.methods` checks for every optional method.
- **Environment.** A core first started from a phone connection freezes that connection's environment for every terminal on the machine, the desktop app's included. Waycar exports the Host's login PATH in its own connect line so what it starts is sane, and sends `env.PATH` on its own launches so it also works against a core that is already running. It cannot repair terminals other clients start (the Herdr app and `hc machine add` have the same trap).
- **Ghost viewers.** A dropped phone (a suspended app, a lost network) leaves its attach as a viewer on the Host until sshd drops the session; with stock sshd that is much longer than the app's own keepalive. While no desk viewer is active the ghost still leads the PTY size, so the desk sees the phone's width until someone types or focuses it. It cannot type, and the next attach from the phone supersedes it. The app cannot fix the Host's `ClientAliveInterval`; a help note names it for Hosts where this bites.
- **Labels and layout are app-owned.** `herdr.space`, `herdr.tab` and the `herdr-app` document belong to the desktop app. Waycar reads the labels (stable enough to survive the app's own re-adoption logic) and the document's space and tab names (`CoreAppLayout`: tolerant, read-only, refreshed on `doc` events) and writes neither; the only labels Waycar sets are its own `waycar*` ones on terminals it starts. A terminal started from the phone has no `herdr.space`, so the Herdr app lists it as an agent without a pane, and Waycar groups it by folder. Adopting phone-started agents into the matching space is a later task.
- **Older builds.** An older build cannot read a `core` raw value in synced Closed Sessions and ignores it (safe). It would lose per-Host preferences if `newAgentBackend` ever held `core`, which is why it never does. The runtime pick has its own key, which an older build does not read or rewrite, so the pick survives a mixed-version account (an older build shows its own view: the TUI).
- **Default pick.** TUI when both are found keeps every current Host unchanged. If Mike prefers core to win, the change is one line in the resolution table and its test.
- **Install order.** Decided in WAY-482: Install Herdr TUI, Install tmux, Install herdr-core, with no "recommended" label.
- **PR size.** 1b is still large; review in commits, run the full simulator suite once, and keep `HostBackend` switches compiler-checked (no `default:` that hides the new case).
