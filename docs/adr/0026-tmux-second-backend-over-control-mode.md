---
status: accepted
---

# tmux is a second backend, reached over control mode, with herdr the default

_2026-09-30, proposed; Mike's answers recorded in `docs/design/tmux-backend.md` §0.
2026-10-01, accepted: implemented on branch `tmux-support` (PR #62)._

Waycar adds tmux as a second backend so that someone on tmux instead of herdr
gets the app working generally the same way. herdr stays first: default
onboarding, hero copy, richest features. A Host may run herdr, tmux or both;
with both, the Console lists both backends' Agents in one list, New Agent
defaults to herdr, and the user can start new Agents in tmux.

A `TmuxTransport` conforms to the existing `Transport` and maps tmux into the
herdr-shaped inventory, event and error model the Console already consumes:
session to Workspace, window to Tab, pane to Pane. It speaks tmux control mode
(`tmux -C attach -f no-output,no-detach-on-destroy`) over one non-PTY SSH exec
channel. A session-scope format subscription (`refresh-client -B` looping every
session, window and pane) plus tmux's session and window notifications stand
in for herdr's event stream. Agent Status comes from Waycar's Status Hooks installed
into the agent CLIs, which write tmux pane user options (`@waycar_status` and
siblings) from inside the pane; there is no Host daemon. The hooks ship with
the existing plugin package and install in the same command. Attach runs
`tmux new-session -t` on a PTY, a private grouped session per attach, and
never `attach -d`. A Host with both backends runs one Console projection per
backend (Transport, events session and inventory each), sharing the Host's
one SSH connection, and the Console lists both projections' rows together.
The floor is tmux 3.2.

The facts this rests on were verified on tmux 3.7c on 2026-09-30 (design §1).
A control client works without a PTY but must stay attached to a session.
tmux sends no per-pane lifecycle notifications, and pane changes in other
sessions are silent; only a format-loop subscription sees them, within about
1.2 s. A control client that never sets a size never resizes windows. Hook
processes inherit `TMUX` and `TMUX_PANE`.

## Decisions fixed here

- **Backends are detected per connection.** A backend is present when it is
  installed (herdr on the PATH or its socket present; tmux 3.2 or later), not
  only when it is serving: a stopped herdr stays herdr's failure. With both,
  both are listed (tmux sessions included right away, a per-Host switch hides
  them) and New Agent defaults to herdr unless the Host sets tmux. This is not
  the transport fallback ADR 0011 rules out: herdr still requires stream-local
  forwarding, and a tmux backend needs only exec and PTY.
- **Map, don't rename.** herdr's schema is the canonical model. TmuxTransport
  builds `SessionSnapshot`, synthesizes `HerdrEvent`s and throws `HerdrAPIError`
  with the codes the UI branches on. Its ids carry a `tmux:` prefix, which the
  host tools use too, so they never collide with herdr's in stores keyed by
  pane id. Herdr*-named types are renamed only if a third backend arrives.
- **Status from hooks, otherwise Unknown.** The hook mapping (design §4.6)
  carries guards learned from herdr's hook era (#198, #249). Titles and
  spinners are not signals. Screen detection over `capture-pane` is a later
  addition for hook blind spots and agents without hooks.
- **Host tools through install.sh.** The installer gains a tmux mode that
  installs a standalone `waycar` CLI from the plugin tarball (pairing, hooks,
  notify) and installs the agent hooks in the same run. This amends ADR 0007,
  which rejected a standalone script because shipping it was an out-of-band
  step; install.sh is that step already. It amends ADR 0008's trigger on tmux:
  agent hooks instead of herdr `[[events]]` hooks, with the same envelope,
  relay and Notification Registration format. A Host keeps one registration
  file and one host-side notifier, which reads both backends, so ADR 0014's
  single producer per Host holds.
- **Shared attach, no takeover.** tmux allows several clients, so Waycar never
  detaches the desk. Window size follows tmux's `window-size latest`; holding
  it for the phone (herdr's behavior) would need changing the user's options
  and recreates herdr's pinned-size problem (#19).
- **One projection per backend.** herdr's projection is untouched by tmux: its
  snapshot, its all-or-nothing `events.subscribe` and its failure handling
  stay as they are. Host-keyed reconcilers (Unread Marks, Closed Sessions,
  terminal caches, launch detection, the inventory cache) gain the backend in
  their key. A dual Host shows herdr's status while tmux lists no sessions;
  otherwise it is Connected while either projection is and Failed only when
  both are. A failed projection keeps its own Failed state and presentation,
  its rows stay last-known, and nothing retries it on a timer.

## Considered options

- **One backend per Host entry** (both installed means two entries): simpler,
  but it cannot list tmux and herdr Agents together or start a tmux Agent next
  to herdr ones, which Mike chose.
- **One `CompositeTransport` merging both backends behind one events session
  and one projection**: rejected in review. One ping gates the whole Host, one
  stream failure redials both, verification and reconciliation are per Host,
  so a failed backend's rows could be neither kept honestly nor closed
  correctly, and merged pane subscriptions would send tmux ids to herdr's
  all-or-nothing `events.subscribe`.
- **Status from Agent of Empires (`aoe serve`) or agent-deck's web API**: each
  needs a token, a direct-tcpip tunnel and session-to-pane mapping, and covers
  only their users.
- **Screen detection as the primary status source** (herdr's model since
  0.6.7): needs per-pane screen reads over SSH, where herdr reads its PTYs in
  process. Kept as the later fallback.
- **iTerm2-style panes rendered from `%output`** instead of attaching:
  per-pane views without touching the desk, but a second terminal pipeline and
  sizes still bound to the window.
- **Splitting `Transport` into an SSH layer and a backend protocol**: cleaner
  names for no behavior change, against about 250 test-double construction
  sites and the in-flight chat-like branch.
- **A control client per tmux session**, so `%*` subscriptions would do: one
  session channel each against OpenSSH's default `MaxSessions` of 10.
- **A host daemon with a vendor relay** (Moshi's model): rejected; no vendor
  server sits in the control path.

## Consequences

- tmux Hosts work where SSH stream-local forwarding is disabled.
- Status quality on tmux depends on hooks. Esc interrupts, trust dialogs and
  unreviewed Codex hooks stay invisible until screen detection lands, and the
  published capability table says so.
- A connection that carries tmux takes its control channel out of the
  ordinary exec budget (4 → 3), keeping one session channel of headroom under
  OpenSSH's default `MaxSessions`.
- Below tmux 3.6 the control client exits when its anchor session dies;
  TmuxTransport reattaches (about 50 ms locally) without a Host status change.
- Host Connection Status and Agent Inventory become per projection on dual
  Hosts; `CONTEXT.md` changes with the implementation.
- The pane option names and their value encoding are a cross-implementation
  contract between the host tools and the app, pinned by a shared test vector
  and versioned like the pairing envelope.
- The 3.2 floor excludes RHEL, Alma and Rocky 8 (tmux 2.7).

## Implementation notes (2026-10-01)

Learned while building it, on tmux 3.7c unless noted:

- A failing command in an `a ; b ; c` control line drops the rest of the
  line: one `%error` block, none for the rest. Commands that must run
  independently go on separate lines.
- `rename-window`, `rename-session`, `new-window -n/-c` and
  `new-session -s/-c` expand formats, including `#(shell)`, so every user
  string is `#`-escaped.
- `%config-error` arrives inside the attach command's own reply block.
- `-u` is required over SSH exec, or tmux draws non-ASCII as `_`.
- `load-buffer -` fails over control mode; drafts go through `set-buffer`.
- `send-keys` types unknown key names literally, so the app checks names.
- Bracketed paste followed by Enter on one control line submits exactly once
  in claude, codex and omp.
- Codex's shared app-server daemon runs hooks with the environment of
  whichever pane started the daemon, so `TMUX_PANE` is wrong for daemon-run
  hooks. Waycar launches codex with `--no-daemon` when supported, and
  `waycar-hook` exits unless the agent's tty (`ps -o tty= -p $PPID`) equals
  the pane's `#{pane_tty}`. Hooks also exit when `HERDR_ENV` or
  `HERDR_PANE_ID` is set.
- A shell rc can create sessions on the tmux server through the inherited
  `$TMUX` (observed: a `.zprofile` that starts a `gh-runner` session); the
  inventory tolerates foreign sessions.
- The trust story of ADR 0008 is amended: Waycar stays closed source.
  Superseded by ADR 0033 (2026-11-11), which opens the source.
