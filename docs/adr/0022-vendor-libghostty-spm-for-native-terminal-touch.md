---
status: accepted
---

# Vendor libghostty-spm's Swift layer for native terminal touch

The Swift/UIKit layer of libghostty-spm is vendored as the repository-local
package `Packages/GhosttyTerminal` (upstream 1.6.20260909, `7e45d27`, MIT) with
Waycar's patches recorded in its `PROVENANCE.md`. The native core stays
upstream's prebuilt XCFramework, fetched from the same release URL and
verified against the same SwiftPM checksum. This amends ADR 0004 and
supersedes the "no terminal-text tap handling" consequence of ADR 0010.
_Amended by ADR 0025:_ the native core is now built by Waycar from the same
pinned inputs, without GNU gettext, and fetched from otreva/ghosttykit.

Terminal touch is now native to the surface:

- **Long press selects** with Ghostty's own selection — the word under the
  finger, or the whole URL or path — and a drag extends it. Handles adjust
  either end, and the system edit menu offers Copy, plus Open Link or Preview
  when the selection is exactly a link. Its Open Link makes the same
  open-or-confirm decision a tap on that link would. Selected text is a file
  only in Ghostty's path shapes: it starts with `/`, `./`, `../`, `~/` or
  `$HOME/`, or it is a relative path containing both `/` and `.`
  (`src/app.swift`, `.config/app`), so prose such as `and/or`, `I/O`, `24/7`
  or `2026/09/26` offers no Preview. A selection over several rows is one
  path only where the grid joins those rows by the tap's own rules below and
  the selection covers exactly that joined path, blanks and box borders at
  either end aside (`selectedPathRun()`, patch 2): a path herdr or a TUI
  broke across rows still offers Preview, while rows that merely sit one
  above another — a list of paths, a path over a word or a box's bottom
  rule — do not. A tap on the selection toggles the
  menu; any other tap clears it and does nothing else. The long-press sheet of
  plain viewport text is gone.
- **Handles stay usable at the edges.** While either end of the selection is
  scrolled out of view, that end has no handle and the other does not drag:
  a drag re-presses at the other end, which would cut off the hidden part.
  Where a short selection's two touch areas overlap, the handle whose knob is
  nearer the finger takes the touch (a tie goes to the end handle). A knob
  that would be clipped by the terminal's bounds flips to the other side of
  its bar: the start knob below it on the top row, the end knob above it on
  the bottom row.
- **A tap on a link opens it — when the link is what it says.** Ghostty
  resolves the link under the finger — an OSC 8 target first, then its URL
  and path matcher, soft-wrapped lines included. It opens at once only when
  the target is the whole of the text drawn on the tapped cells: the target
  must read exactly from consecutive cells that include the tapped one; the
  cell before it must be the viewport's first cell, a blank, a hard line end,
  or one of `([{<'"` or a backtick; after it must come a blank, a line end,
  or the viewport's last cell, at most after four of `.,;:!?)]}>'"` or
  backticks; and neither neighbouring cell may resolve to the same target,
  so an OSC 8 run longer than its target does not count. That check reads
  the rows around the tap once and is linear in the target, which may be no
  longer than the viewport; its two neighbour probes are hovers, which send
  nothing to a mouse-tracking program. Anything that fails it asks first, as
  do wide characters: an OSC 8 target that is only the start of its text
  (`https://a.example` over `https://a.example.b.example/`, `~/k` over
  `~/k.pub`) or differs from it, any `file:` URL, a path that climbs back
  out of a name with `..` (below), and a web link whose authority carries
  userinfo (`user@`, `user:pw@`) or any non-ASCII character, even when its
  text matches. The confirmation shows where it leads — the web link's
  scheme and host, percent-encoded so a look-alike name shows, and the full
  address, or the Host path a Preview reads, resolved against the pane's
  directory and the Host's home with `..` folded — with Open (or Preview),
  Copy, and Cancel, and a confirmed file is read at that one path, with no
  fallback reading. A link over blank cells is not a target. A path holding
  a format character (a bidi override or isolate, a zero-width space) is
  none either: it draws nothing, or reorders what is drawn.
  An `http`/`https` target still passes `TerminalLinkPolicy`; a `file:` URL
  must name no host or `localhost`; no other scheme opens. A tap on a
  `file:` link naming another machine (`ls --hyperlink` writes
  `file://build-box/…`) says so in the preview's failure alert rather than
  seeming to do nothing; it is still never read.
- **A trackpad or mouse click on a link opens it too.** A plain primary
  click decides as a tap does (`tapAction(at:input: .pointer)`), and the
  vendored view holds its press back (`claimPointerClick(at:modifiers:)`):
  released in place, the link opens and no position, press, or release
  reaches Ghostty, so a mouse-tracking program (herdr always tracks) never
  hears it. Moved past the tap slop, it becomes a drag pressed where it
  began. A click with a modifier held (Ghostty's own ⌘-click), a secondary
  click, a click on the input row, or one during a selection or a flick
  stays Ghostty's.
- **The input row keeps the keyboard.** A tap within the caret row's
  standard 44 pt band raises the keyboard even over a path or URL there, on
  the normal and the alternate screen alike: that is where a shell draws its
  prompt (`~/code/app$`), and `herdr terminal attach` keeps every pane on
  the alternate screen. Links elsewhere, a TUI's included, stay tappable.
- **A tap on a file path previews it.** The path resolves against the pane's
  working directory (a shell's follows `cd`) and the Host's home, the file is
  read through the transport's bounded preview read (a regular file of at most
  25 MB), and Quick Look shows it. Only the path the user tapped is fetched.
  Ghostty's matcher sees a path whole only within one row or across soft
  wraps, and every pane reaches it repainted by `herdr terminal attach` (and
  mosh) with cursor moves, while agent TUIs wrap their own text: on a phone's
  narrow grid most absolute paths arrive as row fragments, and a tail without
  a slash is no link at all. So the path characters around the tap are read
  off the grid and carried across a row break when the row's text ends
  within two cells of the edge and the next row's text starts with a path
  character (`pathRun(at:)`, patch 2 in the package's `PROVENANCE.md`). Rows
  of a bordered box join the same way inside their borders: the row's last
  character is a box-drawing border (U+2500–U+257F) at the edge, at most two
  blanks after the path, the same border comes before the path, and the
  other row holds that border in both of those columns, then the path — so a
  box beside it on the next row, a plain row, or another border character
  never joins. At most eight rows join either way.
  That joined path is read first and the row's own reading is the fallback,
  tried only while a reading names nothing or a folder — a path that merely
  ended at the edge still previews. A joined reading is taken only where the
  tapped fragment could be part of a path (it has a `/`, `.` or `~`, or a
  reading of its own), so a word or a rule under a path at the edge stays
  text; a `file:` URL joined across rows is confirmed like any other, and
  any other refused OSC 8 target (`ssh:`) is no link whatever its text reads
  as. Any path with a `..` after a name (`shot.png/../../.ssh/key`, `~/..`)
  is confirmed, whatever put it together — a row join, Ghostty's match
  running on across a blank (`~/ok/shot. x/../../.ssh/id_ed25519.` matches
  whole), a selection, an OSC 8 target, or text drawn in full: otherwise
  remote output could hang `/../../.ssh/id_ed25519` off a harmless name at
  the edge or after a blank, and a tap on that name would read the key.
  The rule looks at the path read, not at what the
  tapped row shows, so a `..` glued to the neighbouring row's name
  (`export` + `../` reads `export..`) cannot slip past it. Leading `..`
  segments only climb from the pane's directory before any name, and `.`
  changes nothing, so a path that passes keeps every name it draws, in
  order, in the path read: the file read is the one its text names, the
  tapped text itself extended only by text drawn against a row edge next to
  it (text concealed with SGR 8 is still read, as within one row, where
  Ghostty's own matcher reads it too). A path that climbs on its own row
  (`./out/../img.png`) asks too; that is rare in output, and telling it
  from a spoofed one would mean trusting how the text was laid out.
  Confirming every indented continuation was rejected: agent TUIs wrap
  under a hanging indent (`⏺ Saved …` over `  …/shot.png`), which would
  make the common case ask. Ghostty's matcher runs a path on across a blank
  while text follows (`/tmp/a.png. Done.`), so a `. ` or `, ` after a name
  with a known file extension ends the path there; and `name.ext:12` is a
  file and its line, not a URL scheme. A bare media
  file name (`shot.png`, a PDF, audio or video), which Ghostty's matcher
  never takes, previews from the pane's directory — but not the tail of a
  word the row before broke (`hot.png`), nor a glob or template (`*.png`,
  `frame_%04d.png`); a bare `README.md` or `Node.js` stays prose. A read
  that fails in any way, the session winding down under it included, says
  so; a new tap, Cancel, or leaving the Agent stops the search before any
  further fallback reading is read.
  _Note (2026-10-13):_ a tap in the terminal still fetches only that path.
  From the Files & Links list, an image or PDF opens a gallery over the list
  that swipes through the list's images and PDFs: a PDF is read only when
  opened or swiped to, an image may be read one ahead, and every local copy
  is deleted when the gallery, the list, or the terminal closes.
  The 24 pt strip along the leading edge that swipes back to the Console
  (on iPad at regular width it opens and closes the Agent list instead; see
  ADR 0024) lies over the first columns: a tap there that does not move goes
  on to the terminal as its own tap would, so a path starting in column 0
  still previews, and a swipe still does its job. The tap is handed on in
  the strip's own coordinates, which are the terminal's (it lies along the
  terminal's leading edge at full height), so an iPad Agent list beside the
  terminal does not offset it. It goes nowhere while the open Workspace
  panel or a dimmed status dialog (Session Ended, Host unavailable, live in
  another window) covers the terminal: those take every other tap there.
  _2026-09-27:_ The Workspace panel is gone; only a dimmed status dialog
  now withholds the edge tap. The
  surface's side is unit-tested (`handleForwardedTap(at:)`); the SwiftUI
  gesture that feeds it is covered only by UI testing.
  _2026-10-22:_ An ended attach no longer dims or covers the terminal: the
  toolbar's connection dot and its popover say so and offer Reattach. Only a
  cold failure (nothing was ever shown to read) keeps a non-dimming dialog,
  so a dimmed dialog, and with it the withheld edge tap, remains for Host
  unavailable and live in another window only.
  Quick Look keeps its own viewer only for an exact list of system types,
  matched by the extension's type and never by conformance: PNG, JPEG, GIF,
  HEIC/HEIF, and WebP; PDF; plain text, JSON, and C, C++, Objective-C,
  Swift, assembly, JavaScript, Python, Ruby, Perl, PHP, and shell source;
  MP3, M4A/MPEG-4 audio, and WAV; MPEG-4 and QuickTime movies. Any other
  file is shown as text — other image formats (TIFF, BMP, PSD, camera RAW,
  EXR, ICNS, TGA), SVG, web pages, 3D scenes, office documents, and types
  third-party apps export — so remote-chosen bytes never reach those
  renderers.
- A tap anywhere else behaves as before.

## Why vendor

Every piece of this sits inside the wrapper's UIKit view: its long-press
recognizer handed the host a text snapshot, its `UITextInput` reports no
selection rects, and its tap path sent Ghostty a click the host could not
suppress. The C API has what native selection needs (mouse press, position and
release; `read_selection`; `mouse_captured`) but none of it can be driven
correctly from a subclass that cannot see the view's gesture state. Upstream
changes would have left the feature on another project's schedule, which is why
ADR 0010 settled for the Attach Links index. Vendoring the Swift layer, as ADR
0021 did for swift-mosh, keeps the change reviewable in-repo while the
checksum-pinned native core keeps the supply-chain review of ADR 0004.

## How it stays out of the remote program's way

ADR 0010 rejected probing links through synthetic mouse input because it could
interfere with TUIs that capture the mouse. That risk is now handled rather
than avoided, and pinned by tests against the live surface:

- Every synthesized event carries shift, and Waycar configures Ghostty with
  `mouse-shift-capture = never`, so selection and hover stay local even while
  Claude Code, codex, or grok track the mouse.
- Ghostty reports pointer motion to a program tracking all motion (DECSET 1003)
  whenever no button is down, shift or not, so each gesture holds a button
  Ghostty gives no action (10). With one down, shift keeps the gesture local.
- Ghostty exports no call that clears a selection, and a shift press extends an
  existing one; the selection is cleared through the preedit path instead,
  which never reaches the PTY.
- Waycar's own tap recognizer already reports taps to a mouse-tracking program,
  so the wrapper's tap click — which reported each one a second time — is off.

`TerminalTouchInteractionTests` asserts that none of selection, handle drags,
taps on a selection, link hit tests, or the link highlight sends a byte.

## Considered Options

- **Keep the upstream pin and subclass** — rejected: the long-press recognizer,
  the tap click, and the edit menu are private to the view.
- **Draw a selection overlay of our own** — rejected: Ghostty's selection
  follows its text through output and scrollback, draws in the theme's colors,
  and knows word and link boundaries; an overlay would re-derive all of that
  from cell coordinates.
- **Scan viewport text for links ourselves** — rejected in favor of Ghostty's
  own matcher and OSC 8 lookup, which see soft wraps and hyperlink cells that
  exported viewport text cannot distinguish.
- **Fetch files over exec** (`cat`, or a shell check of type and size) —
  rejected: the path is remote output, and a check by path and a read by path
  race a file swapped in between. The read is SFTP alone: the path is stat-ed
  so a directory, FIFO, or device is refused before it is opened, then it is
  opened once, the handle is `fstat`-ed, and every chunk is read from that
  handle. Each preview opens its own SFTP channel, not the usage strip's,
  with the open shielded from cancellation, and closes it however the read
  ends — success, failure, timeout, or cancel (the Cancel badge, tapping
  another path, leaving the Agent). A read-kind SFTP use that is cancelled
  or times out mid-request has its subsystem shut down by the session driver
  before the use ends, so libssh2's per-kind continuation cannot hand the
  abandoned reply to a later call; a caller queued behind it gets
  `.channelFailed`. The stat, and the open plus `fstat`, are each bounded by
  the request timeout (15 s by default); each chunk must arrive within the
  request timeout of the previous one; and the whole transfer is capped at
  the request timeout plus the file size at 128 KiB/s, at most five minutes.
  So a large file that keeps arriving on a slow link finishes, while a server
  stuck opening a FIFO swapped in at the last moment does not keep the
  channel.

## Consequences

- Updating libghostty-spm is a manual re-apply against `PROVENANCE.md`,
  followed by `TerminalTouchInteractionTests` and `TerminalMouseReportingTests`.
  The selection and link patches depend on Ghostty's mouse semantics in
  `Surface.zig` and `SelectionGesture.zig`; a new Ghostty commit needs those
  re-read.
- Copy on long press no longer shows the whole viewport's text in a sheet;
  selecting more than the screen shows means dragging toward an edge, which
  scrolls the normal buffer's history (an Agent's alternate screen has none).
- A tap on a mouse-tracking TUI now reaches it once instead of twice.
- The Attach Links index (ADR 0010) stays as the way back to a link that has
  scrolled away.
- Local copies live in the app's temporary directory only while Quick Look
  shows them: closing the preview removes them, and so does leaving the
  Agent, which also cancels a preview still loading — checked one turn later
  against whether the Agent is still on stage, so SwiftUI's spurious
  disappear and reappear closes nothing. The first Agent terminal opened
  after a relaunch sweeps whatever a killed app left, once per process, so
  another window's open preview is never swept.
- While selection handles are up, the Agent screen's back-swipe strip at the
  left edge steps aside so a start handle there can be dragged. On iPad at
  regular width the strip opens and closes the Agent list instead; see ADR
  0024.
