# tmux backend: build plan

Status: implemented on branch tmux-support (PR #62); see ADR 0026. Mike's
answers recorded 2026-09-30 (§0). Research and its validation:
`docs/research/tmux-backend-2026-09-30.md`. Base `47c3fbf8`.

Note (2026-10-29): this plan names the Node files of plugin 1.x (`pair-popup.js`, `notify-hook.js`, `activity-hook.js` and so on). From plugin 2.0.0 the same behavior is one native binary built from `plugin/rust` (ADR 0031); read the `.js` names as history.


Goal (Mike, 2026-09-30):
- herdr first: default onboarding, hero copy, richest features.
- Someone on tmux instead of herdr gets the app working generally the same
  way. Differences exist only where tmux forces them, and §3 lists them.
- herdr and tmux both installed: herdr is the default, and the user can choose
  tmux for new agents.

Not in scope: Zellij or screen; non-default tmux sockets (`-L`/`-S`); Agent of
Empires or agent-deck HTTP APIs; rendering panes from `%output` instead of
attaching.

## 0. Decisions (Mike, 2026-09-30)

| # | Question | Decision |
|---|---|---|
| 1 | Both installed | One Host, one list: herdr Agents and tmux sessions together |
| 2 | Existing tmux sessions on a box with both | Shown right away, existing herdr Hosts included once the app updates; Host detail can hide them |
| 3 | When to promote (waycar.dev, App Store, README) | After testing; phases 1–4 ship first, Live Activities and worktrees included |
| 4 | Hooks at first release | Claude Code, Codex, omp; then pi and opencode |
| 5 | Hook install | With the plugin, in the same install command, no extra prompt. Only Codex's one-time `/hooks` review stays manual |
| 6 | tmux attach semantics | Accepted (alternatives in §4.4) |
| 7 | Open source | Waycar stays closed source; copy never claims it. Superseded 2026-11-11 by ADR 0033: the source is open |
| 8 | App Store copy | Promoted there too, after testing; the readiness doc's "no tmux" keyword rule is revised then |
| – | Assumptions | tmux 3.2 floor; tmux Launches count against the free tier; code after chat-like lands; no Herdr* renames |

## 1. Facts this plan relies on

Verified 2026-09-30 on tmux 3.7c (Homebrew) with private `-L` servers, both
locally and over `ssh -T localhost`, plus live hook runs of Claude Code
2.1.286 and Codex 0.159.2; T20–T23 and the exact commands in §4.3–4.4 come
from a second round that ran them as written. Version floors come from
tmux's `CHANGES` and source tags; distro versions from the distros' package
indexes.

| # | Fact | Consequence |
|---|---|---|
| T1 | `tmux -C attach` runs on a non-PTY exec channel (`ssh -T`). `-CC` fails without a tty (`tcgetattr failed`) | Control channel is a non-PTY exec; WaycarSSH needs a duplex exec primitive (§4.2) |
| T2 | Each `;`-separated command gets its own `%begin <t> <n> 1` … `%end`/`%error` block, in send order. Notifications arrive only between blocks. `<n>` is a server-global counter | Match replies FIFO, never by number |
| T3 | A control client has to stay attached: `-C list-sessions`, `-C new-session -d` and `-C start-server` print and exit. With no sessions, `-C attach` answers `no sessions` (rc 1) | Anchor session; explicit "tmux not running" state |
| T4 | `attach -f no-output,no-detach-on-destroy` works. `-f` flags exist since 3.2, `no-detach-on-destroy` since 3.6, and unknown flags are dropped silently (`#{client_flags}` shows what applied) | No `%output` flood. Below 3.6, reattach on `%exit` (≈50 ms locally) |
| T5 | A control client that never sends `refresh-client -C` never changes window size (`window-size` latest, smallest or largest) | Never send `-C` |
| T6 | No per-pane add or close notification exists. Pane changes in other sessions emit nothing. `%*`/`@*` subscriptions cover only the attached session | Global state needs a session-scope subscription with a format loop |
| T7 | `refresh-client -B 'name::#{S:#{W:#{P:…}}}'` sends one `%subscription-changed` per change in any session, 0.3–1.15 s after it. Commas inside loops must be written `#,` | One push feed for topology and Agent Status |
| T8 | `%sessions-changed`, `%window-add`, `%window-renamed`, `%unlinked-window-add/close/renamed` and `%session-renamed` arrive for every session; `%layout-change` only for the attached one | Immediate resync triggers |
| T9 | Raw tabs and newlines in titles, paths and `@options` come through unescaped, even with `#{q:…}`. tmux 3.4 and 3.5 print every other control byte in command replies as octal text (0x1E as `\036`) and valid UTF-8 as is | Record sentinel ␞ (U+241E), field separator ␟ (U+241F), free text last |
| T10 | Hook processes inherit `TMUX` and `TMUX_PANE`; `tmux set -p -t "$TMUX_PANE" @k v` from a hook lands on the right server and pane | Hooks write pane options; no Host daemon |
| T11 | `pane_current_command` is claude's version (`2.1.286`, it renames its process title) but the name for codex and omp. `pane_title` defaults to the hostname and apps overwrite it. Claude's title showed no spinner while working; Codex's spun while idle | Kind from hooks or the tty's foreground process (§4.3); titles never drive status |
| T12 | With `window-size latest` (the default), the phone attaching to or typing in a window sizes it to the phone, a desk keystroke takes it back, and a phone detach restores the desk. Other windows keep their size (T21) | Accept (decision 6). Kinder than herdr, where an attach owns the pane size until it exits |
| T13 | `attach -d` detaches every other client; the desk client exits 0 | Never `-d` |
| T14 | A grouped session (`new-session -t`) has its own current window, but the active pane and zoom stay window state. `destroy-unattached on` kills an unattached session at once, so it goes in the attach chain. `list-* -a` lists shared objects once per grouped session | Attach command (§4.4); dedupe by id |
| T15 | `send-keys -l -t %N -- '<text, each ' written '\''>'` is literal-safe; a bare `;` token is a command separator. One line `set-buffer -b b -- "<draft>" ; paste-buffer -p -d -b b -t %N ; send-keys -t %N Enter` delivered drafts up to 1 MB byte-exact, with Enter after the bracketed paste closes (3 reply blocks). Inside the double quotes `\`, `"`, `$` and a leading `~` must be escaped (`"~/x"` becomes the home path; `\~` is safe anywhere). `paste-buffer` turns LF into CR unless `-r`, brackets only when the app enabled bracketed paste, and shows control bytes other than TAB and LF as `^[`-style text. `load-buffer -` fails over control mode and prints an unframed error line | Input encoding (§4.3) |
| T16 | Control mode has no bell notification; an `alert-bell` hook fires with an empty `hook_pane` | Bells unused |
| T17 | 3.2 brings subscriptions, pause, `attach -f`, `new-session -e` and `display-popup`. Ubuntu 22.04 ships 3.2a, 24.04 3.4, Debian 12 3.3a, EL9 3.2a, Amazon Linux 2023 3.2a and 3.6a, Fedora and Homebrew 3.7c, EL8 2.7 | Floor 3.2; EL8 unsupported |
| T18 | Claude: `SessionStart` (`session_id`, `transcript_path`) at launch; `PermissionRequest` 0.28 s after an approval appears; `Stop` at turn end, then a late internal `SubagentStop`; Esc fires no `Stop`; no hooks fire before folder trust | Mapping with guards (§4.6) |
| T19 | Codex skips hooks until the user reviews them in `/hooks`; its `SessionStart` fires at the first turn; `notify` is a single slot, already taken on this Mac | Install UX; never touch `notify` |
| T20 | `send-keys` types an unknown key name literally instead of failing; `-H` sends raw bytes (3.0+) | Key names checked in the app |
| T21 | An attached `new-session -t A` starts on A's current window, so the phone shrinks the desk's window before `select-window` runs. Creating the grouped session detached, pointing it at the target, then `attach`, all in one chain, never touches the desk's window; the session dies when the phone detaches | Attach command (§4.4) |
| T22 | A login-shell wrapper as the `new-window` command (`exec "$SHELL" -lic '<agent>; exec "$SHELL" -l'`) runs the agent with the window's `-e` env and leaves a login shell when it exits. Typing the command instead echoes it into the pane and the shell history | Launch through the wrapper (§4.3) |
| T23 | Killing a session's last window ends the session; other control clients get only `%unlinked-window-close` and `%sessions-changed`. Shell rc files that run tmux create transient windows | Resync on both; topology tolerates transient windows |
| T24 | Below 3.6 the control client's own session dying (its last window killed, by that client or any other) ends the client: tmux answers, and runs, every command it had already read (the same line or write, up to one ≈4 KB read), then sends `%sessions-changed` and a bare `%exit`, and EOF follows within 0.5 ms. Lines read later, or queued behind a waiting command (`run-shell`), never run and get no reply; no command ran unanswered. `detach-on-destroy off` on the session keeps the client, but switches the desk's clients there too. Verified live on 3.2a, 3.3a and 3.4 on the Linux testboxes (2026-10-04); 3.7c with `no-detach-on-destroy` switches the client to another session instead | A line `%exit` left unanswered goes out once more on the replacement client, on the same server, when every command in it is idempotent; a lost pane move is checked against a fresh snapshot first; input, pastes and creation never go again (§4.3). The user's `detach-on-destroy` stays untouched |
| T25 | `pane_current_command` is the foreground process group leader's name (the proc name on macOS, argv0's basename on Linux; Linux from source review only). A nested shell reads as the shell, `sleep 63 &` reads as the shell, a pipeline reads as its first command, and `sh -c` and shebang scripts read as their interpreter. tmux samples subscriptions about once a second: verified live on Homebrew tmux 3.8, `sleep 2` was pushed at +0.51 s and +2.52 s, and a 0.1 s command loop gave 2 pushes in 4.8 s | Shell Activity from `pane_current_command` plus the batched `ps -t` leader args (§4.3), no extra traffic; interpreter-run scripts read idle and commands under ~1 s may never show |

## 2. UX scenarios

1. **tmux-only box, Pairing.** `curl -fsSL https://waycar.dev/install.sh | sh`
   on a box with tmux and no herdr says "herdr not found, setting Waycar up
   for tmux", installs the host tools and the agent hooks, and shows the
   Pairing Code. Scan: the Host is added with a `tmux` chip. Every tmux
   session is a Workspace, agent panes are Agents with live status, plain
   panes are Shells. From here the app behaves as it does for herdr.
2. **Manual add, nothing installed.** Address plus key. Preflight finds no
   herdr and finds tmux 3.4, so the Host connects as tmux. Agents are detected
   by process and show Unknown. Host detail shows the install command, which
   adds the hooks.
3. **Blocked while away.** claude asks for approval. Phone in hand: the row
   turns Blocked within about a second. Phone locked: an encrypted push
   "Blocked: …"; tapping it opens that Agent attached.
4. **Look without disturbing the desk.** Opening an Agent attaches a private
   view, so the desk keeps its current window and its size. Only when the
   desk shows that same window does its size follow the side that typed last.
   In a split window, the phone's pane becomes that window's active pane.
5. **Reply.** Composer Send pastes the draft (multi-line safe) and presses
   Enter; on a Shell it runs the command. A Blocked Agent gets the same
   insert-without-Enter as on herdr.
6. **Start work.** New Agent on a tmux Host: pick a session, get a new window
   running the agent in its directory; pick a directory, get a new tmux
   session; pick a Worktree (phase 4), get a fresh checkout in its own
   session. Default Shell opens a plain window.
7. **Done clears** when the Agent is opened on the phone, or focused on the
   desk if tmux focus events are on.
8. **tmux not running.** On a tmux-only Host the Console says "tmux isn't
   running on <Host>" with Start Session (creates `main` at the home
   directory; the button is disabled while a start is in flight, and a
   `main` that already exists counts as started). A session started at the
   desk shows up within about 15 s while the app is in front.
9. **Old tmux.** An EL8 box fails preflight: "tmux 3.2 or later is required
   (found 2.7)".
10. **Both installed.** The Console lists the herdr Agents and the tmux
    sessions together, tmux rows with a small tmux mark. This includes
    existing herdr Hosts once the app updates. New Agent lists both kinds of
    Workspace; for a new Workspace or shell, a herdr | tmux switch is set to
    herdr. Host detail can make tmux the default or hide tmux.
11. **herdr down, tmux up, on a box with both.** The Console keeps the tmux
    Agents live and shows herdr's failure in its own issue row ("herdr on
    <Host>") with a Retry for herdr alone; the herdr rows stay as last known.
    The same holds the other way round.
12. **tmux installed but unused** (Ubuntu Server ships it): no tmux rows and
    no notice; New Agent still offers tmux.
13. **herdr-only users.** Nothing changes: herdr Pairing stays the default and
    the hero copy stays herdr.
14. **Site visitor who uses tmux.** waycar.dev still leads with herdr; the
    eyebrow and an "Already on tmux?" section show the table and the same
    install command.

## 3. Capability table

Target: the same Console, Agent detail, Composer, New Agent, Closed Sessions,
notifications, Live Activities, worktrees and Summaries on both. The tmux
column shows where each gap closes. README, README-zh and waycar.dev publish
this table when tmux ships.

| | herdr | tmux |
|---|---|---|
| Host needs | herdr 0.7.5+ running; SSH stream-local forwarding; Node 20+ for the plugin | tmux 3.2+; plain SSH (exec and PTY); Node 20+ for pairing and push |
| Inventory | Workspaces, tabs, panes | sessions, windows, panes |
| Agent detection | herdr, 22 CLIs | Waycar hooks; process name for the rest |
| Agent Status | herdr's screen detection and integrations | Waycar hooks: Claude Code, Codex, omp (phase 2), pi and opencode (phase 6); screen detection for the rest (phase 6), Unknown until then |
| Blocked/Done push, Attention Badge | herdr plugin | Waycar hooks |
| Live Activities | herdr plugin | phase 4 |
| Agent Summaries | herdr plugin | phase 6 |
| Attach | one writable owner, Take Over | private view per attach; several clients; no Take Over (none needed) |
| Terminal size while attached | phone owns the pane size until it detaches | the window the phone shows takes the phone's size; if the desk shows it too, the last side to type wins |
| Composer delivery | `agent.prompt` / `pane.send_input` | bracketed paste, then Enter |
| First-prompt wait after a launch | herdr's `launch_pending` | claude's `SessionStart` hook, else 8 s; then held while the screen shows a dialog. Others a short settle. Prompts to a Blocked Agent are refused (`agent_blocked`) |
| New Agent in a Workspace / new Workspace | yes | new window / new session |
| New Agent on a Worktree; worktree removal | yes | phase 4 (git over SSH) |
| Closed Sessions resume | herdr's `agent_session` | session id from hooks |
| Move pane | yes | `break-pane` / `join-pane`; the pane keeps its id |
| Rename | `agent.rename` / `tab.rename` | window name |
| Agent Row Layout from the plugin | yes | built-in default (no plugin) |
| Pairing Code | herdr plugin popup | `waycar pair` |
| Mosh, AI Usage, Skills, SFTP attachments, Dictation, Snippets, Jump Host, iCloud Sync | yes | yes |

## 4. Design

### 4.1 Backends per Host

**Presence**
- herdr is present when `herdr` resolves on the Host PATH (`HerdrHostPath`)
  or its socket path exists; tmux is present when `tmux -V` reports 3.2 or
  later. A present backend that fails is that backend's failure, never an
  absent backend, so a herdr Host whose herdr is stopped keeps today's
  failure even when its OS ships tmux.
- Detection is one exec, run alongside the herdr ping on every connection;
  the result is cached with the last-known inventory for cold launch. It is
  not a user setting.
- herdr only, or tmux absent or below 3.2: exactly today's behavior. tmux
  only: tmux. Both: both, in one list (decision 1). `Host.sessionName` stays
  herdr-only.

**One projection per backend**
- A Host runs one `HostConsoleProjection`, with its own `EventsSession` and
  Transport, per present backend: `WaycarSSHTransport` for herdr,
  `TmuxTransport` for tmux. A tmux-only Host is the one-projection case.
  herdr's projection stays exactly as it is: tmux never enters its snapshot,
  its all-or-nothing pane-scoped `events.subscribe` or its failure handling.
- `ConsoleStore` keys projections by Host and backend (today by Host,
  `ConsoleStore.swift:46-48`) and lists both projections' rows in one
  Console. `ConsoleAgent` and `ConsoleWorkspace` carry their backend, which
  drives the tmux mark and per-row capabilities; nothing parses ids.
- Everything Host-keyed that reconciles against a verified snapshot gains the
  backend in its key, so a projection reconciles only its own rows: Unread
  Marks, Closed Session capture, terminal caches and transport generations,
  and the inventory cache (one file per backend).
  Host-wide aggregates (`hostStatuses`, `hostsAwaitingSnapshot`, the
  Attention Badge's live count) combine both.
- Host status on a dual Host is herdr's while tmux lists no sessions, so a
  herdr user whose OS ships tmux sees exactly today's states. Otherwise it is
  Connected while either projection is, and Failed only when both are,
  presenting herdr's failure. A failed projection keeps its own Failed state
  and Standing Failure, and its rows stay last-known. When the Host presents
  the other backend, the failed one gets its own Console issue row (the
  ambient surface ADR 0011 requires) with its full Transport Error
  Presentation and a Retry of that backend alone. Nothing retries it on a
  timer (ADR 0011, #147); that Retry and foreground re-proof do, as today.
- Host-level exec features ride the first Connected projection, herdr first,
  so a herdr that failed at connect does not take them down while tmux
  serves.
- Ids: `TmuxTransport` and the host tools prefix every tmux workspace, tab,
  pane and terminal id with `tmux:`, on tmux-only Hosts too, and strip it for
  tmux commands. Pushes, Live Activity pins and Summaries carry the prefixed
  id, so the app matches them against rows verbatim. Pins, Unread Marks and
  Closed Sessions stay keyed by Host plus pane id, without collisions.
- `ClosedSession` gains `backend` (`decodeIfPresent`; absent means herdr),
  captured from the row. Resume, including its new-Workspace-at-the-directory
  fallback, launches on that backend.

**Shared connection**
- One SSH connection per Host serves both projections. `HostSSHSession`
  (§4.8) owns it and both Transports take it. A backend Transport's
  `close()` releases only its own channels and never waits on the Host; the
  session closes with its last Transport and redials once when either
  projection reconnects. A link failure drops both Transports, as today's
  single connection does.
- A Transport EventsSession drops after a link failure is not closed, since
  Terminals may still use it; `Transport.transportDistrusted()` makes it
  give up what a replacement on the same connection needs. tmux releases its
  control channel (the one `.control` slot), stops its event work and never
  opens a control client again; attach and exec keep working until `close()`.
- Host detail's checks (preflight, onboarding probes) dial their own
  connection instead of the pooled one, so they never queue behind the
  Console's channels.
- `SSHTransportConnector.connect`
  (`Sources/Waycar/Hosts/TransportConnector.swift`) takes the backend and
  returns that backend's Transport on the Host's session. Its "deliberately
  no second path" comment is about stream-local fallback and stays true for
  herdr.

**Preferences and UI**
- Two per-Host preferences live outside `Host`, keyed by Host id and synced
  with the other app preferences: New Agent default (herdr when present) and,
  on dual Hosts, Show tmux sessions (on). They stay out of `Host` because
  editing a `Host` replaces its projection and drops its terminals
  (`ConsoleStore.setHosts`, `ConsoleStore.swift:404-431`).
- Turning Show tmux sessions off stops the tmux projection, which records no
  Closed Sessions, as when a Host leaves the catalog, and writes
  `tmux_enabled: false` into the Host's `notify.json`, so the host notifier
  stops pushing and counting tmux Agents.
- New Agent lists herdr Workspaces and tmux sessions, tmux ones marked;
  picking a Workspace picks its backend. A new Workspace at a directory,
  Default Shell and New Terminal get a herdr | tmux control, shown only on
  dual Hosts and preset to the Host's default.
- Capabilities are static per backend and apply per row: Take Over, Live in
  Another Window and terminal window ownership (`HostTerminalOwnership`,
  keyed by Host today) apply to herdr rows only; tmux rows always attach.
- An older build ignores all of this and dials herdr only, so a tmux-only
  Host fails preflight there until that device updates. Accepted: raising
  `recordVersion` would hide every Host from older builds.
- tmux running inside a herdr pane shows twice: a herdr Shell running tmux,
  plus the tmux rows. Accepted; herdr reports no foreground command to hide
  it by.
- Recency inside a Console bucket compares `stateChangeSeq` only between
  rows of the same Host and backend (herdr counts per Host, tmux in
  wall-clock nanoseconds); otherwise a Host's herdr rows lead its tmux rows.
- `ServerInfo` gains `backend`; `HostOnboardingView` shows "tmux 3.4" for
  tmux. tmux snapshots set `SessionSnapshot.version` to the tmux version and
  `protocolVersion` to 0; the projection reads it only to choose herdr
  subscriptions, which `TmuxTransport` ignores.

### 4.2 WaycarSSH: duplex exec channel and budget

- `SSHConnection.openExecStream(command:timeout:) -> SSHExecStreamChannel`:
  exec without `pty_req`, with `write`/`read`/`close` shaped like
  `SSHStreamLocalChannel`, stderr drained separately and the exit status
  reported at close. It follows the driver rules of ADR 0011 and its #130
  amendment like any long-lived channel.
- `SSHChannelAdmission.ChannelClass.control`: one per connection that
  carries tmux, taken out of the ordinary exec and SFTP budget (4 → 3), so
  the session channels stay at control 1 + exec 3 + attach 5 = 9, one under
  OpenSSH's default `MaxSessions`: the headroom ADR 0011 and ADR 0017 keep.
  The connection ceiling stays 18. herdr's RPC and events ride forwarding
  channels, which `MaxSessions` does not count. Waiting for the `.control`
  slot is bounded by the request timeout (`TransportError.timedOut`), since
  its holder can be a Transport that is going away.
- Tests go in the WaycarSSH package suite
  (`scripts/run-waycarssh-package-tests.sh`).

### 4.3 TmuxTransport

New folder `Sources/Waycar/Transport/Tmux/`:

| File | Role |
|---|---|
| `TmuxTransport.swift` | `actor TmuxTransport: Transport` |
| `TmuxControlChannel.swift` | owns the control channel: pending-command FIFO, line reader, reattach |
| `TmuxControlParser.swift` | pure: bytes to replies (`ok`/`error` plus lines) and notifications |
| `TmuxCommand.swift` | pure: command builders and quoting |
| `TmuxInventory.swift` | pure: list output to `SessionSnapshot` and Agents |
| `TmuxAgentDetection.swift` | pure: pane fields and `@waycar_*` to kind and status |
| `TmuxEvents.swift` | pure: notifications and subscription diffs to `HerdrEvent`s |
| `TmuxAttachCommand.swift` | attach and mosh command lines |
| `TmuxErrors.swift` | tmux error text to `HerdrAPIError` codes and `TransportError` |

**Control channel**
- `exec env -u TMUX tmux -C attach -f no-output,no-detach-on-destroy -t <anchor>`,
  run with the PATH fix-up the herdr commands already use (`HerdrHostPath`).
- The anchor is the lowest-id session without `destroy-unattached on`, since
  the control client counts as attached and would keep such a session alive.
  Always pass `-t`: a bare attach picks the session with the newest activity.
- Startup: attach, then `display -p '#{version}…#{client_flags}'` (floor check,
  and whether `no-detach-on-destroy` applied), then the two subscriptions,
  then the snapshot.
- `%exit` while the server lives (the anchor died on a server below 3.6,
  T24): reattach to a new anchor inside the same Transport, resubscribe,
  emit a resync. That is not a Host Connection Status change. A command
  line `%exit` left unanswered never ran. It goes out again on the
  replacement client when every command in it is idempotent (reads, kills,
  renames, selects, option sets: `TmuxCommand.isIdempotent`) and the
  replacement reached the same server (`#{start_time}.#{pid}`), whose ids
  the line names, and again should that client's anchor die too (a bulk
  Close emptying several sessions). A kill that finds its target gone
  answers `can't find …`, which callers take as done, so a bulk Close that
  takes the anchor's last window closes every row. A pane move (break-pane,
  join-pane) is no replay, since it would move the pane again: a snapshot
  from the replacement client shows whether the pane landed, as tmux keeps
  pane ids, and only otherwise does the line go out again. Anything else
  (input, pastes, new windows and sessions) fails with a link error and is
  never re-sent, so a Composer delivery cannot run twice (ADR 0018).
  `%exit` with no session left to anchor on (the server gone, say) goes
  idle (below) and resyncs; a reattach that fails ends the event stream
  and takes EventsSession's reconnect path. Whichever notices the ended
  channel first, its pump or a request, handles that end, once.
- A cancelled command returns `cancelled` at once and the channel stays
  open: its line keeps its FIFO place with no caller, so its replies are read
  and dropped. The channel ends only when a line times out or cannot be
  written.
- With no session to anchor on, TmuxTransport runs one-shot `tmux` commands
  over ordinary exec (`tmux ls`, `tmux new-session -d -s main`). A tmux-only
  Host polls `tmux ls` every 15 s while the event stream is open, and its
  keepalive pings re-check too. A dual Host never polls: re-checks run on
  activation, on a command, and on foreground re-proof
  (`Transport.revalidate()`), so herdr Hosts whose OS merely ships tmux pay
  nothing. The role comes from the backend detection run at connect, which
  also stands in for the `tmux -V` probe.
- `ping()` is a `display -p '#{version}'` round trip, which keeps
  EventsSession's 30 s keepalive meaningful. On an idle dual Host it only
  checks locally that the SSH connection is up.
- Every exec runs through the account's login shell (fish reads `\'` and
  `\\` inside single quotes as escapes), so an argument holding a quote,
  backslash or control character is refused with `invalidDirectoryPath`
  before anything runs; the automatic worktree lookup skips such directories.
  Git ref names (a worktree's branch, base and slug) refuse only backslash
  and control characters, which git forbids anyway, with git's own
  `worktree_create_failed` message: a quote, written `'\''`, reads alike in
  POSIX shells and fish (fish's only escapes inside single quotes are `\'`
  and `\\`).

**Inventory.** One control line runs `list-sessions -F …; list-windows -a -F …;
list-panes -a -F …`. Each record is `␞<id>␟<fields>` (U+241E, U+241F:
printable, because tmux 3.4 and 3.5 escape control bytes in replies, T9)
with free text last, and every field is `#{s/␞|␟//:field}`, so tmux strips
both separators from each value and no path, title or option can split a
record or forge one. The parser cuts at Unicode scalars, not Characters, and
also drops records whose ids are not `$N`/`@N`/`%N` or whose last field
still holds ␟. `TmuxInventory` builds a
`SessionSnapshot` with its memberwise initializer, as `DemoScreenshotMode`
and `ConsoleInventoryCache` already do. All ids carry the `tmux:` prefix
(§4.1).

| herdr | tmux | id | fields |
|---|---|---|---|
| Workspace | session | `tmux:$N` | `session_name`; cwd from `session_path` |
| Tab | window | `tmux:@N` | `window_name` |
| Pane, terminal | pane | `tmux:%N` (terminal id = pane id) | `pane_current_path`, `pane_current_command`, `pane_tty`, `pane_pid`, `pane_title` |
| Agent | pane with a detected kind | pane id | status from `@waycar_status`, `stateChangeSeq` from `@waycar_seq`, session from `@waycar_session`; title from `pane_title` |

- Dedupe by id (T14). Hide Waycar's attach sessions (`waycar-*`) and every
  grouped session except one per group: the session named like the group,
  else the lowest id.
- Agent display name: the window name, unless it is tmux's automatic-rename
  artifact (equal to `pane_current_command`, e.g. `2.1.286`); then the kind.
- Worktree metadata (`worktree`: `checkout_path`, `is_linked_worktree`,
  `repo_key` = the common git dir, `repo_root` = the main worktree,
  `repo_name`) for each session whose directory (`session_path`, else the
  active pane's cwd) is in a git work tree: one `git rev-parse` exec per
  snapshot over all uncached directories, cached per directory for 60 s.

**Events.** `subscribeToEvents` returns a `HerdrEventStream` fed from:
- notifications (T8), translated to herdr kinds already in
  `HostConsoleProjection.resyncEventKinds` (tab created, closed or renamed;
  workspace created, closed or renamed); `%layout-change` needs no mapping,
  since `wc-topo` sees pane changes;
- subscription `wc-topo`, every pane's session, window and pane ids,
  `pane_current_command` and `pane_dead`:
  `refresh-client -B 'wc-topo::#{S:#{W:#{P:#{s/␞|␟//:session_id}␟…␞}}}'`,
  in the inventory's separators, so no `#,` escaping is needed; each field
  strips both, and rows with a bad id are dropped, as in the inventory. Any
  change triggers a resync, which catches other
  sessions' panes and agents starting or exiting;
- subscription `wc-status`, the same form over `pane_id`, `@waycar_status`,
  `@waycar_agent`, `@waycar_session` and `@waycar_seq`. A status change
  becomes `pane.agent_status_changed`: applied in place
  (`Agent.replaceStatus`), then the projection's usual resync, one list round
  trip on tmux. A kind or session change resyncs, so a `/clear` while idle is
  seen as a switch in place.

Resyncs are debounced by 250 ms. The `EventSubscription`s EventsSession asks
for are ignored: tmux pushes everything, and no pane-scoped subscription
exists that a dead pane could wedge (contrast herdr's all-or-nothing
`events.subscribe`). Screen-detection verdicts survive a deliberate
resubscribe; they reset on `close()`, on link loss, and when the server has
no sessions left.

**Agent kind and status**
- Kind, first match wins: `@waycar_agent` (set by the hook) → a known name in
  `pane_current_command` (`codex`, `omp`, `opencode`, `gemini`, `pi`, …) → any
  other command, resolved once per pane and pid from the tty's foreground
  process over exec (`ps -t <pane_tty> -o pid=,pgid=,tpgid=,stat=,args=`, the
  row whose `stat` has `+`; Linux untested) → otherwise a Shell (ADR 0018). A
  pane running vim is a Shell, as on herdr.
- Status: `@waycar_status` (working, blocked, done, idle), else Unknown.
  Options are ignored while the pane's foreground command is a shell, so an
  agent killed without `SessionEnd` leaves no stale status.
- `focusAgent` (herdr's "seen") reads `display -p -t %N '#{@waycar_status}'`
  and, only when it is `done`, sends one single-block command
  `set-option -p -F -t %N @waycar_status '#{?#{==:#{@waycar_status},done},idle,#{@waycar_status}}'`.
  Not `if -F`: a true condition adds a second `%begin`/`%end` block for the
  inner command and shifts every later reply. The read keeps an unset option
  unset (the `-F` form would write an empty string).
- Shell activity: a Shell's Shell Activity comes from `pane_current_command`
  (T25) plus the leader args the existing batched
  `ps -t <pane_tty> -o pid=,pgid=,tpgid=,stat=,args=` call already resolves:
  a shell name is idle, anything else is running that command line. It adds
  no traffic. Known limits: `ssh`, `tmux attach`, editors and REPLs read
  running; a script run through a shell interpreter (a bash shebang,
  `sh -c`) reads idle; a command under ~1 s may never show. It never feeds
  Agent Status.

**Input**
- `promptAgent` and `sendPaneInput`: one control line
  `set-buffer -b waycar-<uuid> -- "<draft>" ; paste-buffer -p -d -b waycar-<uuid> -t %N ; send-keys -t %N Enter`
  (T15). The draft escapes `\`, `"`, `$` and `~`, and writes newlines as
  `\n`. LF-to-CR is what a terminal paste sends, and control bytes arriving
  as visible text is safer in a TUI than raw escapes. Submit-carrying input
  is never retried automatically (ADR 0018). `-d` deletes the buffer only
  after a paste, so a line that fails is followed by a best-effort
  `delete-buffer` on the same channel, detached so the error or
  cancellation returns at once. A channel that has ended gets none: the
  cleanup never reconnects.
- `promptAgent` refuses an Agent whose reported status is Blocked with
  herdr's `agent_blocked`: Enter would answer its question or dialog.
- `sendAgentKeys`: a table from Waycar's key model to tmux key names
  (`Escape`, `Tab`, `BTab`, `Up`, `BSpace`, `C-c`, `M-x`, `F1`, …), checked in
  the app because tmux types unknown names literally (T20); anything without
  a name goes as `send-keys -H` bytes.
- Input typed into the attached terminal (Direct Input, taps, the Blocked
  insert) is unchanged.

**Launch**
- Agent in an existing Workspace:
  `new-window -d -t '$S:' -c <cwd> -n <label> -P -F '#{pane_id}…#{window_id}' '<wrapper>'`,
  where the wrapper is T22's `exec "$SHELL" -lic '<agent command>; exec "$SHELL" -l'`
  with its inner quotes written `'\''`. The agent gets the user's rc, and an
  exiting Agent falls back to a Shell row as on herdr.
- New Workspace at a directory: `new-session -d -s <label> -c <dir> -P -F …`.
  `.` and `:` in the label become `_` (tmux 3.2–3.6 rewrite them, 3.7 does
  not), so every version gets the same name and collisions are checked
  against it.
- Default Shell and New Terminal: no command, `-e WAYCAR_SHELL=1` (ADR 0018).
- First-prompt wait: claude is promptable once its `SessionStart` hook has set
  `@waycar_session`, or 8 s after launch when no hook sets it (a Host without
  Status Hooks); after that, a screen check keeps the gate closed while the
  pane shows a dialog (claude's folder trust), since Enter would accept it.
  opencode drops input until its TUI draws its input box, 6–24 s after launch
  on Linux test Hosts (1.18.34; its plugin sees nothing of the TUI, which runs
  in another thread), so it is promptable once its alternate screen shows the
  box (a `┃`-bordered row), at once if its pane already has an
  `@waycar_status`, or 30 s after launch whatever the screen shows.
  Other kinds 1.5 s after detection. Earlier, `promptAgent` throws
  `agent_not_ready`, which `AgentComposerStore.promptWaitingOutLaunch` waits
  out, unless the Agent's live status turns Blocked: then it stops retrying
  and the user answers the dialog in the terminal, as with herdr's `blocked`
  launch.
- Closed Session resume: the agent's own resume command in a new window.

**Other Transport methods**

| Method | tmux |
|---|---|
| `closePane` / `closeTab` | `kill-pane -t %N` / `kill-window -t @W`; an emptied session closes itself |
| `renameAgent` / `renameWorkspace` | `rename-window -t @W` / `rename-session -t $S` |
| Shell rename (today a downcast to `WaycarSSHTransport.renameTab`, `HostConsoleProjection.swift:756-761`) | becomes a Transport requirement; tmux: `rename-window -t @W` |
| `readPane` / `readAgent` | `capture-pane -p -J -S -<lines> -t %N`; an alternate-screen app gives only its visible screen, as on herdr |
| agent-kind probe, Skills, file reads, CodexBar, model context, staging, mosh probe, remote home and directory listing | `HostSSHSession` (§4.8) |
| worktree methods | `git worktree list --porcelain` of the session's checkout (source = the main worktree, every other entry linked). Launch: `git worktree add` (base resolution reused from `WorktreeBaseResolution`; an existing branch checked out as-is) into herdr's default root `~/.herdr/worktrees/<repo>/<branch slug>` (`-2`… when taken; one root on a Host with both backends), then a new session named after the checkout directory running the agent or the marked shell. `WorktreeLaunchAttempt` keeps a retry from adding twice and reconciles by the minted branch; a typed branch already in a linked worktree is reused, with a session opened there when none shows it. Removal: the exact linked checkout only, `git worktree remove` (no force), then `kill-session` for every session in that checkout and its group; the branch survives |
| `movePane` | new Tab: `break-pane -d -s %P -t '$S:' [-n <label>]`; new Workspace: `new-session` at the pane's directory, the same `break-pane` into it, then `kill-window` on the placeholder; if that line fails, cleanup kills the placeholder window (never the session, which may already hold the moved pane). Existing Tab: `join-pane -d -h\|-v [-l N%] -s %P -t <%Q\|@W>`. `focus` adds `select-window` / `select-pane`. tmux keeps the pane id; an emptied window or session closes itself, and a single-pane window moves whole, keeping its id. A move into the pane's own Tab answers `same_tab` unchanged |
| sidebar layout | none; tmux Hosts get a built-in default Agent Row Layout |
| Summaries | phase 6: host tools read `capture-pane` instead of `herdr pane read` |
| Notification Registration and config | the Host's one registration file (§4.5); phase 2 |

**Errors and preflight**
- tmux error text maps to the `HerdrAPIError` codes the UI already branches
  on (`can't find pane` → `pane_not_found`, …; the list comes from the
  existing `catch` sites). Anything else is `HerdrAPIError(code: "tmux_error")`
  carrying tmux's text.
- New `TransportError` cases with presentations: `tmuxNotInstalled` and
  `tmuxTooOld(found:)`. No server or no sessions is not an error: a tmux-only
  Host is Connected with an empty, explained Console (scenario 8); a dual Host
  just shows no tmux rows (scenario 12).
- `Sources/Waycar/Hosts/Preflight.swift` for tmux: connection, remote
  environment, tmux installed and 3.2 or later, server state, and a soft
  "Waycar hooks" check that warns but never blocks. It also notices Codex
  hooks still waiting for `/hooks` review by reading `trusted_hash` entries,
  never writing them.

### 4.4 Attach and mosh

- Both `TerminalAttachTarget` cases carry the pane id and build one command.
- After the existing bootstrap marker, on the PTY, one chain (T21):
  `exec tmux new-session -d -t '$S' -s 'waycar-<8 hex>' \; set-option -t 'waycar-<8 hex>' destroy-unattached on \; select-window -t 'waycar-<8 hex>:@W' \; select-pane -t '%P' \; attach -t 'waycar-<8 hex>'`,
  shell-quoted, with `$` ids in single quotes. The desk's window keeps its
  size unless the desk shows the same window, and the grouped session dies
  when the phone detaches.
- Mosh runs the same command after `mosh-server new … --`; the
  `MOSH_SERVER_NETWORK_TMOUT` handling is unchanged (ADR 0021).
- No `-d` and no Take Over: `request.takeover` is ignored, and the capability
  hides Take Over and Live in Another Window. Several app windows can attach
  at once.
- Size follows T12; the five-per-Host retention is unchanged.
- An orphaned attach is just one more client: the desk's next keystroke takes
  the size back, unlike herdr's pinned size (#19).
- `close()` of a Transport that made attach sessions does not wait for the
  Host: a detached sweep, bounded at 2 s, kills every unattached
  `waycar-<8 hex>` session (one whose chain failed before `set-option`), then
  returns the connection hold.
- Agents started from Waycar get their own window, so the active-pane effect
  only arises for panes the user split at the desk.

Alternatives to the size and active-pane behavior (decision 6), all worse:

| Alternative | Why not |
|---|---|
| Phone never resizes (`attach -f ignore-size`) | the phone shows a cropped, desk-sized screen |
| Phone holds the size while attached, as herdr does | needs `window-size smallest` or a manual `resize-window`, both changing the user's options; the desk stays phone-sized until the phone leaves, and a stuck phone session pins it (#19) |
| Per-client active pane (`attach -f active-pane`, tmux 3.2–3.7) | removed in tmux 3.8, now at release candidate 3 |
| Render panes from `%output` with per-window client sizes (`refresh-client -C @w:WxH`) | a second terminal pipeline, and tmux still gives each window one size |
| Move the Agent's pane into its own window (`break-pane`) | rearranges the desk's layout |

The Mirror (WAY-365, [`mirror.md`](mirror.md); removed 2026-10-31, kept here
as a record of what was measured) took the first row's trade-off on purpose. It is a live, read-only view whose point is to leave the
desk's window alone, so it accepts that the phone shows a desk-sized screen
(it pans) and attaches with `-f read-only,ignore-size`, in the same chain
without a status line (`set-option -t 'waycar-<8 hex>' status off`). Its PTY
is the window's size, read as `#{window_width}x#{window_height}`, and follows
the window when the desk resizes it (one `display -p` per second, then an SSH
window-change). `ignore-size` only holds while another client without the flag
is attached; with none, the Mirror's PTY sizes the window, which is why the PTY
is exactly the window's size. Observed on tmux 3.2a, 3.4 and 3.8. Take control
is not offered: watching is all a read-only client does, and Fit to phone stays
the way to type.

### 4.5 Host tools: pairing and push without herdr

The herdr plugin's tarball (`plugin/`) gains a tmux mode. Its pairing and
crypto modules (`pair-accept.js`, `pairing-session.js`, `bootstrap-key.js`,
`authorized-keys.js`, `envelope.js`, the `*-envelope.js` files) already have no
herdr dependency, and the Push Relay contract has no herdr field.

| Piece | Behavior |
|---|---|
| `waycar pair` | `pair-popup.js` in the current terminal; state in `~/.local/state/waycar`; forced command `node …/pair-accept.js …` as today. A key binding is printed, not installed: `bind W display-popup -E waycar pair` |
| `waycar hooks install\|uninstall\|status` | idempotent, order-preserving merge into `~/.claude/settings.json`, `~/.codex/hooks.json` (plus `[features] hooks = true` when the key is absent; an explicit `hooks = false` is the user's opt-out and is left alone, reported in the output and as `hooksDisabled: true` on the codex row of `--json`) and an omp extension file; keeps every existing hook (herdr's, Moshi's, the user's); never touches Codex `notify`. Hooks are installed by install.sh (whenever tmux 3.2+ is present, in either mode, unless `--no-hooks`), by running `waycar hooks install`, or from Host detail's Install Status Hooks over SSH, which preflight prompts for when hooks are missing. Nothing installs them automatically at herdr startup: that would edit agent configs on every start and ignore `--no-hooks` |
| `waycar-hook <agent> <status>` | POSIX sh, about 10 ms: exits unless `TMUX_PANE` is set and the agent's tty is that pane's `#{pane_tty}` (an agent in a herdr pane can inherit `TMUX_PANE` from a herdr started inside tmux; phase 0 checks how a hook reads the agent's tty); applies the §4.6 guards, sets `@waycar_status` and `@waycar_seq`, and on entering blocked or done starts `waycar notify` detached. Hook matchers do the routing, so it parses no JSON |
| `waycar hook-session` | Node, `SessionStart` only: reads stdin JSON, sets `@waycar_agent`, `@waycar_session`, `@waycar_transcript` (percent-encoded) |
| `waycar notify` | `notify-hook.js` logic with a tmux adapter: 5 s hold, recheck `@waycar_status`, dedupe in the state dir, attention count, seal with the Notification Key from the Host's one registration file (below), POST to the relay |
| `install.sh` | Installs what the box has in one run, no extra prompt (decision 5): the herdr plugin when herdr is on PATH (today's flow), the tmux tools and the agent hooks when tmux 3.2+ is present, or both. Links `~/.local/bin/waycar`, prints the files it changed and the Codex `/hooks` step, offers Pairing. `--tmux` forces tmux mode; `--no-hooks` skips hooks. The app's host-tools probe trusts `~/.local/bin/waycar` only as this symlink (into a root whose `herdr-plugin.toml` has `id = "waycar"`), else uses the install dir's `bin/waycar` |

- A Host has one Notification Registration file: in the herdr plugin's
  config directory when the plugin is installed, else in `~/.config/waycar/`
  (honoring `$XDG_CONFIG_HOME`). The app and the host tools resolve it the
  same way, so registering, Live Activity tokens and pins, and removal stay
  one read-merge-write (`NotificationRegistrationCeremony`).
- One host-side notifier per Host: the herdr `[[events]]` hook and the agent
  hooks run the same code, which reads both backends (`herdr agent list`, and
  `list-panes -a` unless `tmux_enabled` is false) for the Attention Badge
  count and, in phase 4, the Live Activity content. A dual Host thus keeps
  the single producer ADR 0014 assumes.
- The Pairing Code envelope (`HERDR-PAIR:1:`) is unchanged; the backends are
  detected after Enrollment.
- The Live Activity adapter (`activity-hook.js`) is phase 4; Summaries are
  phase 6.
- This amends ADR 0007, which rejected a standalone script because shipping it
  was an out-of-band step (`install.sh` is that step today), and ADR 0008,
  whose trigger becomes agent hooks instead of herdr `[[events]]` hooks on
  tmux.

### 4.6 Hook to status mapping

Pane options, pinned by a shared vector
`plugin/test-vectors/tmux-pane-options-v1.json` consumed by Node and Swift:
`@waycar_status` (`working`, `blocked`, `done`, `idle`), `@waycar_agent`,
`@waycar_session`, `@waycar_transcript`, `@waycar_seq` (nanoseconds).
Tool events never revive idle or done (herdr #198).

Claude Code (`~/.claude/settings.json`):

| Event (matcher) | Sets |
|---|---|
| `SessionStart` (`startup\|resume\|clear\|fork`) | idle, plus session (on `compact`, session only) |
| `UserPromptSubmit` | working |
| `PreToolUse` (not `AskUserQuestion`, `ExitPlanMode`) | working, from working or blocked only |
| `PermissionRequest` | blocked |
| `Notification` (`permission_prompt\|elicitation_dialog\|elicitation_url_dialog\|agent_needs_input`) | blocked |
| `PostToolUse`, `PostToolUseFailure`, `ElicitationResult` | working, from blocked only |
| `Stop`, `StopFailure` | done |
| `Notification` (`idle_prompt`) | idle if still working (Esc backstop) |
| `SubagentStop`, `PostToolBatch` | ignored |
| `SessionEnd` | unset every `@waycar_*` |

Codex (`~/.codex/hooks.json`):

| Event | Sets |
|---|---|
| `SessionStart` | session only (fires at the first turn) |
| `UserPromptSubmit` | working |
| `PreToolUse` | working, from working or blocked only |
| `PermissionRequest` | blocked |
| `PostToolUse` | working, from blocked only |
| `Stop` | done |
| `Interrupt` | idle (documented; not yet seen live) |
| `SessionEnd` | unset |

omp (extension file, mirroring herdr's own omp integration): `agent_start` →
working; `tool_approval_requested` and the `ask` tool → blocked, resolved →
working; `agent_end` (unless `willContinue`, 250 ms debounce) → done; session
file path → `@waycar_session`. pi and opencode follow herdr's integrations
the same way in phase 6. pi's `session_shutdown` and opencode's plugin
`dispose` (run on Ctrl+C, `/exit` and a closed pane, verified live on 1.18.34)
unset every `@waycar_*`.

Done clears when Waycar opens the Agent (`focusAgent`), on the next prompt, on
`SessionEnd`, or, if the user turns on tmux `focus-events`, from a
`pane-focus-in` hook. Never on a timer.

Blind spots until the phase 6 screen detection: Claude's trust dialog,
Claude's Esc (working until `idle_prompt`, about 60 s), Codex plan-mode
questions, Codex hooks not yet reviewed, agents without hooks.

### 4.7 Herdr*-named types

Decision: herdr's schema stays Waycar's canonical vocabulary for inventory,
events and errors. TmuxTransport maps into it, as `DemoScreenshotTransport`
already does. Nothing is renamed in this work; revisit if a third backend
arrives. Renaming would change no behavior, touch about 250 `ScriptedTransport`
construction sites, and collide with chat-like, which is rewriting
`Transport.swift`, `WaycarSSHTransport.swift` and `ScriptedTransport.swift`.

| Type | Role | On tmux |
|---|---|---|
| `Generated/HerdrAPITypes.swift` (`SessionSnapshot`, `AgentInfo`, …) | wire schema and canonical model | built by `TmuxInventory` |
| `HerdrEvent`, `HerdrEventKind`, `HerdrEventStream` | event vocabulary | synthesized by `TmuxEvents` |
| `HerdrAPIError` | errors the UI branches on (about 12 sites) | thrown with mapped codes |
| `HerdrSession`, `HerdrSocketLocation`, `HerdrSessionName`, `HerdrHostPath` | herdr-only | unused, except `HerdrHostPath`'s PATH fix-up |
| `HerdrSidebarSnapshotStore` | herdr plugin row layout | herdr rows only |

- Doc comments on these types say tmux produces them too.
- User-visible "herdr" strings reachable from a tmux row or Host become
  backend-aware: errors, Settings row-layout labels, onboarding (a phase 1
  audit).
- Optional, after chat-like lands: rename `WaycarSSHTransport` to
  `HerdrTransport` mechanically and update AGENTS.md, which cites it.

### 4.8 Shared exec services

`HostSSHSession` owns the Host's SSH connection: `WaycarSSHTransport`'s dial
(Jump Host, host key policy, credentials, PATH fix-up), the one
`SSHChannelAdmission`, the `$HOME` cache, and the features that never touch
herdr (agent-kind probe, Skills, file slice and preview, model context
window, CodexBar, image and file staging, mosh probe and bootstrap, remote
home and directory listing). `isConnected` reads it, and both Transports
take it (§4.1). Today the Console reaches the directory listing and Shell
rename by downcasting to `WaycarSSHTransport` (`ConsoleStore.swift:681-701`,
`HostConsoleProjection.swift:756-761`); they become a session call and a
Transport requirement. This edits `WaycarSSHTransport.swift`, so it lands
after chat-like.

## 5. Promotion

Timing: after testing, in the first release with phases 1–4 (decision 3).
App Review 2.3.1 wants accurate metadata, and the table must say plainly what
tmux lacks.

Guardrails: herdr first in the hero, the onboarding default and the
screenshots; tmux visible one level down; publish §3; keep every
non-affiliation line; no third-party names in the App Store name or subtitle.

| Surface | Change (draft copy) | Where |
|---|---|---|
| `README.md`, `README-zh.md` | Hero line unchanged. Below it: "Built for herdr. Also works with plain tmux 3.2+." A "herdr or tmux" section with §3 and a tmux quick start; the install command auto-detects. Both languages in lockstep | this branch |
| waycar.dev hero | Eyebrow "Native for iPhone & iPad · built for herdr · works with tmux". The install label and code-block title stop saying "herdr plugin": "installs Waycar's host tools for herdr or tmux" | marketing-site-scaffold |
| waycar.dev section | "Already on tmux?" after How it works: three bullets, §3, the same command | marketing-site-scaffold |
| waycar.dev FAQ | "Do I need herdr?": "No. Waycar is built for herdr and gets the most out of it, but plain tmux 3.2 or later works too. On tmux, agent status and notifications come from Waycar's hooks for your agent CLIs." | marketing-site-scaffold |
| waycar.dev meta | `index.astro` title and description add "or tmux" | marketing-site-scaffold |
| In the app | No-Hosts screen: "Works with herdr or tmux". Add Host footnote. A `tmux` chip on tmux-only Host rows. Soft hooks-check copy | this branch |
| Analytics | `backends` property on Host added and connected events, to measure tmux adoption | this branch |

Positioning against Moshi (App Store name "Moshi: herdr/tmux on SSH/MOSH";
status needs its `moshi-hook` daemon, which holds a WebSocket to Moshi's
server), QuickTUI, AgentPanes and Multiplex: "No account. No vendor server sees
your sessions: SSH goes straight to your computer, and notifications are end
to end encrypted." Waycar stayed closed source (decision 7) until ADR 0033
opened it, so until then copy never said "open source" about Waycar, its
plugin or its relay.

## 6. Cross-branch touch points

From local refs on 2026-09-30 (`git rev-list origin/main..<branch>`, `git status`).

| Branch | State | Overlap | Rule |
|---|---|---|---|
| chat-like | 1 commit ahead plus a large uncommitted diff | `Transport.swift`, `WaycarSSHTransport.swift`, `ScriptedTransport.swift`, `StartAgentStore`/`StartAgentView` (New Agent sheet, where the herdr \| tmux control goes), `ConsoleStore`, `ClosedSession*`, `plugin/README.md`, `plugin/src/notification-envelope.js`, `plugin/test-vectors/notification-payload-v1.json`, `CONTEXT.md`, `CHANGELOG.md`, ADR 0025 | Land chat-like first; this ADR is 0026; phase 2 follows its envelope changes; Chat Mode on tmux can read `@waycar_transcript` |
| marketing-site-scaffold | clean, at `origin/main` | `apps/web` Hero, Faq, index, footer, install code block | Site copy goes through that workspace, after tmux ships |
| app-store-submission | merged | readiness doc §8.1 (keywords say "no tmux"; promo; description) | Revise §8.1 when tmux ships |
| subscription | merged | Launch definition, `TypedLaunchDetector` (a Shell turning into an Agent) | tmux snapshots must show the same transition; tmux Launches count the same |
| onboarding-v2, default-state-no-servers | merged | No-Hosts and Add Host screens | tmux copy lands on main |
| live-activities-v2 | 3 commits ahead | Live Activity content and design docs | The phase 4 adapter emits the same payloads |
| `plugin/install.sh` (main) | herdr-only installer | tmux mode | phase 2 |

## 7. Phases and acceptance

| Phase | Scope | Done when |
|---|---|---|
| 0 Spikes | `openExecStream`; the control parser against real sshd and tmux; prompt delivery (paste, then Enter) into real claude, codex and omp TUIs; a shell rc that auto-launches an agent, which the launch wrapper runs before Waycar's agent (whether agent windows get ADR 0018's `WAYCAR_SHELL=1`). Launch (T22) and attach (T21) are otherwise settled | each spike has a recorded transcript and a decision |
| 1 tmux Hosts | For tmux-only Hosts: presence and ids (§4.1), `HostSSHSession` (§4.8), §4.2–4.4, 4.7, `ClosedSession.backend`. Status is Unknown until phase 2 | a tmux Host adds and pairs, lists, attaches over SSH and mosh, replies, starts agents and shells, closes and renames; herdr suites unchanged; iPhone and iPad smoke |
| 2 Status and push | §4.5, 4.6: install.sh tmux mode, `waycar pair`, hooks for Claude Code, Codex and omp, notify, Notification Registration | status within about 1.5 s; Blocked and Done push while locked; Attention Badge |
| 3 Both installed | §4.1: a second projection per Host, backend-scoped reconcilers, the Host status rule, per-Host preferences, the New Agent herdr \| tmux control; one host-side notifier and one registration file per Host (§4.5) | scenarios 10–13 on a box with both |
| 4 Live Activities, worktrees | the Live Activity adapter; New Agent on a Worktree and worktree removal on tmux | same behavior as herdr |
| 5 Test, then promote | TestFlight on real tmux Hosts (Ubuntu 22.04, macOS, a box with both); then §5 | testing passes; §5 ships with that release |
| 6 Later parity | Summaries, pi and opencode hooks, screen detection (a subset of herdr's Apache-2.0 manifests over `capture-pane`, rate-limited, for hook blind spots and hookless agents), reading `@pane_status` and `@workmux_pane_status` | each remaining §3 gap closed |

## 8. Testing

- Pure Swift tests for the parser, quoting, inventory, detection, event
  synthesis, backend-scoped reconciliation and the Host status rule, fed
  with control-mode transcripts recorded in phase 0.
- Real: `scripts/run-ci-ios-tests.sh` gives the disposable sshd a private
  tmux server (its own `TMUX_TMPDIR`) and runs `TmuxTransportE2ETests`
  against the runner's tmux (3.7c), then once more per pinned release
  that `scripts/build-ci-tmux.sh` builds from checksummed tarballs into a
  per-machine cache: 3.2a (Ubuntu 22.04, EL9; reattach path), and 3.4
  (Ubuntu 24.04) and 3.5a (Debian 13), which vis-escape command replies. Each
  pass must run every named test, and merge CI fails if a release cannot be
  built. `openExecStream` cases run in the WaycarSSH package suite.
- Node (`npm test` in `plugin/`): hook guards, settings-merge fixtures that
  keep existing user hooks, the tmux notify adapter, the shared pane-option
  vector.
- Manual: an Ubuntu 22.04 Host (tmux 3.2a, so the reattach path runs), a Mac
  with both herdr and tmux, and a physical iPhone and iPad.
- Linux testboxes (`scripts/testboxes/`, `make test-tmux-remote BOX=…`):
  the 17-test `TmuxTransportE2ETests` suite passed over real SSH on each,
  with opencode 1.18.34 and pi run on an OpenRouter free model; the
  `tmux-distros.yml` workflow runs `scripts/ci/tmux-distro-check.sh` on
  the same distros in containers.

  | Distro | tmux | Stock Node |
  |---|---|---|
  | Ubuntu 24.04 | 3.4 | 18 |
  | Ubuntu 22.04 | 3.2a | 12 |
  | Debian 12 | 3.3a | 18 |
  | Fedora 44 | 3.7c | 22 |
  | Rocky 9.3 | 3.2a | 16 (module streams up to 24) |

## 9. Risks

| Risk | Mitigation |
|---|---|
| Hook blind spots make status wrong. herdr reported claude and codex state from hooks until 0.6.6 and moved to screen detection in 0.6.7 for this reason | guards, the `idle_prompt` and `Interrupt` backstops, Unknown rather than guesses, phase 6 screen detection, and the table says so |
| Dual Hosts run two projections, and every Host-keyed reconciler gains a backend key | a phase of its own (3); the `CONTEXT.md` amendment reviewed before code |
| Agent CLIs change their hook events | the same exposure herdr has; host tools are versioned |
| A TUI swallows the Enter right after a paste | phase 0 spike; fallback is a separate `send-keys Enter` after a short delay |
| The user's tmux config or shell rc reacts to our attach or new sessions (rc files that run tmux create transient windows, T23) | anchor rule; `waycar-` session names; topology diffs tolerate transient windows |
| tmux pane ids restart at `%0` with the server | a Pin can land on a different pane after a tmux restart (herdr ids have the same class of problem); Closed Sessions key on the session id |
| When desk and phone show the same window, its size follows the side that typed last | accepted (decision 6); other windows keep their size (T21) |
| The subscription loop costs O(panes) per second | two small formats; fine at agent scale |
| Older builds see a synced tmux-only Host as herdr | transitional; accepted (§4.1) |
| tmux ships on most Linux servers, so tmux sessions appear on herdr Hosts after the update | intended (decision 2); Show tmux sessions turns them off per Host |
| One shared connection: a stuck tmux channel can invalidate it for herdr too | the same rule as today, where RPC, events and attach already share one connection |

## 10. Docs to update during implementation

- `CONTEXT.md`: Host ("runs a herdr server"), Agent, Agent Status ("herdr's
  detected state"), Pane, Workspace, Shell (attach and rename on tmux), Agent
  Row Layout (a built-in default on tmux; the plugin's layout covers herdr
  rows only), Attention Badge and Notification Registration (one producer and
  one file per Host), Closed Session (its backend), Transport, Attach, Host
  Connection Status and Agent Inventory (per projection on dual Hosts); new
  terms Backend, Waycar Hooks, Host Tools; Push Relay's _Avoid_ entry becomes
  "backend (that's herdr or tmux)".
- ADRs amended by 0026: 0007 (standalone pairing), 0008 (trigger on tmux),
  0011 (on tmux the control round trip, not herdr's ping, is the health
  check), 0014 (the one producer reads both backends), 0018 (a tmux Shell
  attaches by pane id and renames by window).
- `AGENTS.md`: a "Load-bearing tmux facts" section (§1) and the Transport bullet.
- `CHANGELOG.md`, `README.md`, `README-zh.md`, `PRIVACY.md` (the hooks send
  nothing off the Host except encrypted push), `plugin/README.md`; ADR 0026 to
  accepted; ADR 0008 amended, since its trust story says "the relay is open
  source" and the relay is not public (decision 7).

## 11. Open questions

Answered 2026-09-30 (§0). Still open:

1. Start phase 0 now? Its spikes touch only `Packages/WaycarSSH` and new
   files, so they need not wait for chat-like; phases 1+ do.
