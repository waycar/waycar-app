# Mirror: a live terminal that never resizes the desk

Status: **Removed** 2026-10-31. Mike decided a desk-sized screen on the phone
is not what he wants: each screen should lay out the same chat at its own
width, which one PTY cannot do (a TUI lays out for one size), so that is
Chat Mode's job, not the terminal's. The app code (WAY-365, WAY-366 M1, M2)
and `waycar mirror` (plugin 1.6.0 to 2.2.x) were deleted; plugin 2.3.0 has no
bridge. This document stays as the record of what herdr's observe stream and
tmux's `read-only,ignore-size` do. Original decision: Mike, 2026-10-27
(WAY-352: build the watch-only live view before better chat history). Experiments: herdr 0.9.5 on Linux, scripts and raw output attached to
WAY-352.

Working name. The Mirror is a second way to show an Agent's live terminal. It
reads the screen herdr already draws and never attaches, so the pane on the
user's computer keeps its size. Today's Attach stays, as **Fit to phone**.

Not in scope: history. A Mirror shows the screen as it is now, like the desk
does; an alternate-screen Agent leaves no scrollback in herdr
(AGENTS.md, "Load-bearing herdr facts"). Saved chats and search are a separate
piece of work.

## 1. Why Attach resizes, and what does not

- `herdr agent attach` and `terminal attach` resize the pane's PTY to the
  client's size and hold a resize lock until they exit (`attach_terminal_client`,
  `src/server/headless.rs`, v0.9.5). `terminal session control` is the same
  code path. The phone's keyboard going up and down resizes it again (ADR 0013).
- `herdr terminal session observe <target> --cols N --rows N` prints one JSON
  line per frame and never resizes, scrolls, or takes anything over. Many can
  watch one terminal. Verified: three observers at once, and an observer next
  to a desk client, left the pane at its size.
- `observe` and `control` exist in herdr's CLI since 0.7.5, the plugin's floor.
  Both need no PTY and run on a plain SSH exec.
- A frame is `{"type":"terminal.frame","seq":N,"encoding":"ansi","width":W,
  "height":H,"full":bool,"bytes":"<base64 ANSI>"}`. The first frame is full;
  the rest are diffs. Fed to a terminal emulator at W x H they reproduce the
  screen exactly (0 of 44 rows differ from `pane read`, colors and bold kept).
- The viewport is a crop, not a reflow: 60x20 of a 119x40 pane shows its top
  left. A viewport larger than the pane shows the pane at the top left and
  blank cells after it. Omitting `--cols/--rows` means 120x40, not the pane's
  size.
- herdr's API has no column count: `pane get` has rows, `pane layout` ignores
  an attach's resize. The pane's real size is the winsize of its shell's tty,
  which follows every resize: `pane process-info` gives `shell_pid`,
  the process table names its tty (`ps -o tty=` in the Node bridge, `/proc` in
  the native one, since a bare Debian has no `ps`), and the tty device gives
  its size (`stty size` in the Node bridge, the `TIOCGWINSZ` ioctl that `stty`
  makes in the native one).
- `terminal session control` at the pane's exact size changes nothing and
  still scrolls: 10 lines up moved the view, and the PTY kept its size. It
  holds the resize lock, and `--takeover` ends another client's attach of the
  same terminal.
- An observer on an idle pane writes nothing, so it never finds out that its
  SSH client is gone. It outlived a SIGKILLed `ssh` for as long as we looked
  (30 s and counting). A desk resize while observing gives no signal either:
  frames continue at the viewport's size.
- Cost: a 10 Hz spinner screen is 6.9 KB for the first frame, then 105 B per
  frame (about 3.9 KB/s on the wire). Localhost lag is 2 ms. Through a real
  `ssh -T` the first frame arrives in 211 ms including the handshake.

tmux, 3.4 live: a client attached with `-f read-only,ignore-size` leaves the
window at the desk's size; without `ignore-size` the window followed the
phone from 119x39 to 50x29.

## 2. The bridge

`waycar mirror` (plugin 2.0.0; plugin 1.6 to 1.x ran the same protocol as
`sh bin/node.sh src/mirror.js`) is the only thing the app talks to on a
herdr Host. One process per open Mirror, run from the plugin root:

```sh
cd <plugin_root> && exec bin/waycar mirror
```

`plugin_root` comes from `herdr plugin list --json`, as for
`chatTranscriptReadCommand`. A named herdr session is selected the way Attach
selects it, with `HERDR_SOCKET_PATH` in the environment. `HERDR_BIN_PATH`
overrides the herdr binary. No Host value is ever quoted into a shell: the pane
id arrives in the first stdin line.

What it does that a bare `herdr terminal session observe` over SSH cannot:

- starts the observer at the pane's exact size and restarts it when the size
  changes (it re-reads the size every second while watching);
- stops the observer when the app goes away, on stdin EOF, a signal, or a
  stdout write error, so none outlives its channel;
- starts `terminal session control --takeover` at the pane's exact size on
  request, and refuses to forward `terminal.resize`, so the only way a Mirror
  can resize the pane is the one narrow race under "Rules worth knowing";
- gives the app one stable stream, whatever herdr's CLI does later.

### Protocol v1

NDJSON, UTF-8, one object per line. stdin carries commands, stdout events,
stderr diagnostics nobody parses. Unknown types in either direction are ignored.

stdin, app to bridge:

| line | meaning |
|---|---|
| `{"type":"mirror.open","pane":"w1:p1","protocol":1}` | First line, within 5 s. The pane id stays opaque; it may not be empty, start with `-`, contain whitespace or control characters, or exceed 128 characters. |
| `{"type":"mirror.control","enabled":true}` | Take control. The bridge reads the pane's size again, stops the observer, and starts control at that size. |
| `{"type":"mirror.control","enabled":false}` or `{"type":"terminal.release"}` | Release. The bridge asks herdr to let go, then watches again at the pane's current size. |
| `terminal.input`, `terminal.scroll`, `terminal.mouse` | While controlling, forwarded to herdr as sent (herdr's own control commands: `text` or base64 `bytes`; `direction`, `lines`, `source`; `action`, `button`, `column`, `row`). While only watching: `mirror.notice` `not_controlling`. |
| `terminal.resize` | Never forwarded. `mirror.notice` `resize_ignored`. |

stdin EOF ends the bridge.

stdout, bridge to app:

| line | meaning |
|---|---|
| `{"type":"mirror.ready","protocol":1}` | The protocol the bridge speaks. First line out. |
| `{"type":"mirror.reset","reason":"open","mode":"watch","cols":119,"rows":40}` | Precedes the first frame of every herdr child. `reason`: `open`, `resize`, `restart` (herdr ended the stream silently), `control`, `release`. The app clears its screen, sets the grid to `cols` x `rows`, and applies the frames that follow. |
| `terminal.frame` | herdr's line, byte for byte. Apply in order. |
| `{"type":"mirror.ping"}` | Every 5 s, so a dead link shows on an idle pane. |
| `{"type":"mirror.notice","code":"...","message":"..."}` | Not fatal. `control_unavailable` (size unreadable, or herdr refused control: the stream stays or returns to watching), `control_lost` (another client took the terminal over), `not_controlling`, `resize_ignored`. |
| `terminal.closed` | herdr's, passed on, then the bridge exits 0: the pane closed, herdr detached us, or herdr is handing over to a new process (reconnect). |
| `{"type":"mirror.error","code":"...","message":"..."}` | Fatal, then exit 1. `pane_not_found`, `herdr_unavailable` (not installed, no server, repeated stream failures), `size_unavailable` (no shell, no tty, or its size unreadable). `bad_request` exits 2. |

Exit codes: 0 stream ended or app gone, 1 after `mirror.error`, 2 bad request,
127 no Node 20 (`bin/node.sh`; Node-era Hosts only).

Rules worth knowing:

- A reset is the only place the grid changes. Frames of the previous child never
  follow it.
- The bridge forwards whole lines only. A line cut off by a stop is dropped.
- Slow reader: when stdout fills, the bridge stops reading herdr. herdr drops a
  stalled observer after 30 s, and the bridge starts a new one (`restart`, a
  full frame). After 60 s without a drain the bridge ends.
- A herdr child that dies without `terminal.closed` is restarted after 200 ms,
  three times per 10 s, then `herdr_unavailable`.
- While controlling, the pane's size is not polled: control holds the lock.
- Control by another client: `--takeover` ends their attach, and theirs ends
  ours the same way. Ours turns into `control_lost` and watching resumes.
- Take control reads the pane's size and then starts herdr's control client.
  A desk resize in those few milliseconds makes control start at the old size
  and resize the pane to it until the release. herdr's CLI offers no
  start-only-if-this-size, so the bridge cannot close the window; the
  guarantee is "never resizes the pane except in that race".

## 3. The app side

Built so far: `MirrorTerminalStore` (`Sources/Waycar/Console/`) owns the stream
of one Mirror. Its status is connecting, live (the first frame of a stream has
drawn), stalled (no line for 12 s, the bridge pings every 5 s), ended (pane
closed, Host cannot mirror it, or a failure with a retry) or stopped. It writes
`reset` and frames into a `MirrorFeed` that a surface attaches to; a reset
drops what it replaces, and a surface that attaches after commands were lost
asks for a fresh stream. A new run, after a possible suspension, a stall, a
newer connection or a dying channel, opens a new bridge and gets a reset and a
whole screen; the surface stays the same and shows the old screen until the
reset. `AgentTerminalCache.acquire(pipeline:)` picks Attach or Mirror; a
Mirror opens through `EventsSession.withTransport`, so it takes a channel of
the Host's budget and not the Host's terminal slot, and it counts against the
retention budget like an Attach. `AgentAttachStore` keeps the Agent
interaction (Composer staging, close, leave order) and forwards start,
foreground, connection change and leave to the Mirror.

Not built yet. The shape the bridge was made for:

- A Mirror needs plugin 1.6.0. Below that, or when the bridge errors with
  `size_unavailable` or `herdr_unavailable`, the Host falls back to Fit to
  phone (Attach) and the usual Host Tools update offer applies. Raise
  `WaycarPluginRequirement.minimumVersion` only with the app change that
  relies on the bridge.
- The stream rides one non-PTY SSH exec channel. Not mosh: mosh syncs a
  screen, not a byte stream. A reconnect starts a new bridge and a full frame.
- Rendering (built, WAY-366 M2; spike WAY-363): `MirrorSurfaceView`
  (`Sources/Waycar/Terminal/`) holds a Ghostty surface with window padding 0
  in a scroll view. Ghostty derives the grid from pixels and has no
  fixed-grid call, so the frame is `cols x cellWidth` by `rows x cellHeight`
  from the cell the engine reports (`MirrorGridSizer`); measured exact at 380
  font sizes per device. A reset clears (`ESC c`) and then sizes, and frames
  wait until the engine measures the pane's grid. A font change that grows
  the cell first inflates the frame so the grid never dips below the pane's.
  The view starts at fit width (119 columns on a 440 pt phone is about 4.6 pt
  text, an overview), pinch zooms through the scroll view and commits a
  fractional font at the end, and a font is capped so the surface stays under
  8192 px. The keyboard resizes the viewport, never the surface. Watch takes
  no touch: a drag pans. A Mirror keeps its surface across reconnects and
  shows the old screen until the new reset, so it caches no Last Frame.
- Typing: the Composer keeps `agent.prompt`; toolbar keys and Esc go as
  `pane.send_keys`; insert-without-submit stays `pane.send_input`; typing
  straight into the terminal means Take control (a long-lived `terminal.input`
  stream, not one API connection per key).
- Take control is released after a few idle seconds, so the resize lock is not
  held while nobody types.
- tmux has no bridge: the Mirror attaches with `-f read-only,ignore-size` on a
  PTY sized to the window (`#{window_width}x#{window_height}`) and follows the
  window's size. `docs/design/tmux-backend.md` §4.4 rejected `ignore-size`
  because the phone shows a desk-sized screen; the Mirror accepts that and pans.

## 4. Smoke record

Plugin at this commit, herdr 0.9.5, Ubuntu 24.04 container, OpenSSH 9.6,
the bridge started by `ssh -T host 'cd plugin && exec sh bin/node.sh src/mirror.js'` (the plugin 1.x
Node bridge; from 2.0.0 the command is `bin/waycar mirror`):

- Watching htop at 119x40: replay of the frames in pyte matched `pane read` on
  0 of 40 rows. After a desk resize to 90x30 the bridge sent
  `mirror.reset reason=resize cols=90 rows=30` and the replay matched on 0 of 30.
- Take control left the pane at its size; a `terminal.resize` was ignored;
  release returned to watching. Typed text reached the pane and showed in the
  mirror.
- SIGKILL of the `ssh` client left no bridge or herdr process, while watching
  an idle pane and while controlling.
- A closed pane produced `terminal.closed` and exit 0. An unknown pane gave
  `pane_not_found`; an option-like pane id and a missing `mirror.open` gave
  `bad_request`.
- A named herdr session (`herdr --session s2`, socket
  `~/.config/herdr/sessions/s2/herdr.sock`): with `HERDR_SOCKET_PATH` set to
  that socket the bridge streamed the s2 pane; without it, the default
  session's pane.

The native bridge (`waycar mirror`, WAY-443) was run the same way against herdr
0.9.5 in a bare `debian:12-slim` container (no Node, no `ps`), started under a
pty so herdr had a server and a pane `w1:p1`:

- Open, Take control, a typed `echo mirror-smoke-ok` (the pane showed it),
  release, and a resize of the herdr client's tty gave `mirror.ready`,
  `mirror.reset reason=open` at 93x39, `control`, `release`, then
  `reason=resize` at 63x29, and exit 0 on the end of stdin. No herdr
  `terminal session` process was left.
- Against a fake herdr, the Node bridge and the native one wrote the same
  stdout, stderr and exit codes in nine runs: an idle pane with a ping, control
  and release, a bad first line, a first line that is not `mirror.open`, an
  unknown pane, stdin closed before `mirror.open`, no `mirror.open` for 5 s,
  SIGTERM, and a terminal on stdin.

Not verified: macOS Hosts (the pane's tty is named by `ps` there and its size
read from the device; the Node bridge ran `stty -f`), an iPhone or Simulator, a
link with real latency or loss, herdr older than 0.9.5. CI has no herdr
binary, so these checks do not run there; the unit tests use a fake herdr and
fake time.
