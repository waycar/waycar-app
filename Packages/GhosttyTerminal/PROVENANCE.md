# libghostty-spm provenance

- Upstream: <https://github.com/Lakr233/libghostty-spm>, release
  `1.6.20260909`, commit `7e45d27160f9b34aca9ca5c9820e9207482f9f04`. MIT;
  `LICENSE` is upstream's, unchanged, and ships verbatim as the app's
  `libghostty-spm-MIT.txt` notice (`Sources/GhosttyTheme/LICENSE` likewise as
  `GhosttyTheme-MIT.txt`).
- Vendored: `LICENSE` and `Sources/GhosttyKit`, `Sources/GhosttyTerminal`,
  `Sources/GhosttyTheme` from that commit. Not vendored: `ShellCraftKit`, the
  upstream tests, examples, build scripts, and Ghostty patch set. The app links
  only the `GhosttyTerminal` and `GhosttyTheme` products; `Package.swift` keeps
  just those and pins `MSDisplayLink` exactly at the `2.2.0` the app already
  resolved.
- The native core is not vendored as source. `Package.swift`'s `libghostty`
  binary target is Waycar's own build (ADR 0025), published as the release
  `1.6.20260909-82938b6-nointl.1` of the public repository
  <https://github.com/otreva/ghosttykit> (asset `GhosttyKit.xcframework.zip`,
  with `LICENSES.zip` beside it). It replaces upstream's release asset
  `upstream.82938b633ba6/GhosttyKit.xcframework.zip` (checksum
  `2d9a26e80c3836c450f03ea2cf9d191841d9093d4f61c1cea466d2fc8e215dbb`; audit in
  `docs/research/ghostty-1.6.20260909-upgrade.md`), which statically linked
  GNU gettext (libintl, LGPL-2.1+) into every slice.
- `Scripts/build-libghostty.sh` builds that core from libghostty-spm
  `7e45d27160f9b34aca9ca5c9820e9207482f9f04` (its
  build scripts and Ghostty patch set), Ghostty
  `82938b633ba646db38591d969c3c526332bd7e65` (that commit's `Ghostty.ref`)
  and Zig 0.16.0, adding `-Di18n=false` and
  `Scripts/0100-gate-libintl-on-i18n.patch` (in Ghostty's
  `src/build/SharedDeps.zig`, libintl is linked only when i18n is on). The
  Apple SDK comes from the selected Xcode, not from upstream's CI: the build
  of 2026-09-30 used Xcode 27.0 (27A266a) with the iOS 27.0 SDK. Its objects
  still declare a minimum of iOS 15.0 (`LC_BUILD_VERSION` minos, the same as
  upstream's asset), below the app's iOS 18.0 target. The result has
  upstream's six slices (`ios-arm64`, `ios-arm64_x86_64-simulator`,
  `ios-arm64_x86_64-maccatalyst`, `macos-arm64_x86_64`, `xros-arm64`,
  `xros-arm64_x86_64-simulator`) and identical headers; each archive loses
  exactly the 30 gettext and gnulib members (`bindtextdom.o` …
  `version.o`) and has no gettext symbols, defined or referenced. That build
  is 76,042,185 bytes, SwiftPM checksum
  `d64018c8fad48bf84a32622c653d33ef0d40ed154e2a760304924497b79c7de9`, and is
  the hosted asset. The zip holds file timestamps, so a rebuild gives a new
  checksum even from the same inputs; `Package.swift` must name the checksum
  of the zip actually hosted. The script also writes `LICENSES/` (the
  third-party notices for everything in the archive, z2d's MPL-2.0 source
  link included), which is published in that repository and release.
- The Waycar patch set is the difference between `Sources/` here and upstream's
  `Sources/` at the commit above (`git diff --no-index`). Every added or
  edited declaration, block or doc comment carries a `(Waycar patch)` comment;
  a one-line call that wires a marked hook in (for example
  `onHoverLink?(url)` in `TerminalCallbackBridge`) and the arguments threading
  a marked field through may not. Deleted code cannot carry a marker: every
  removal is listed below. ADR 0022 records why the layer is vendored.

## Waycar patches

1. **Native touch selection** (`UITerminalView+TouchSelection.swift`,
   `TerminalSelectionHandleView.swift`, `UITerminalView+Interaction.swift`).
   Upstream answered a long press by handing the host a plain-text viewport
   snapshot (`TerminalTextSelectionRequest`) for the host to show elsewhere.
   Now a long press makes Ghostty's own selection: a synthesized double click
   selects the word — or the whole URL or path — under the finger, and the
   second click stays down so a drag extends it by words. Handles in the tint
   colour drag either end (a fresh press at the other end, then a drag, as a
   mouse would; the ends never cross), and `UIEditMenuInteraction` offers Copy
   (`ghostty_surface_read_selection`) plus host actions
   (`touchSelectionMenuElements(forSelectedText:)`). A tap on the selection
   toggles the menu; any other tap clears it and does nothing else — a tap on
   a handle counts as a tap until the finger moves 4 pt, since a handle's
   touch area covers most of a short selection. Where the two handles' touch
   areas overlap, the handle whose knob is nearer the finger takes the touch;
   a knob that would sit outside the terminal view's clipped bounds (the start
   knob on the top row, the end knob on the bottom row) is drawn on the other
   side of its bar. An end Ghostty clamps to the viewport because it scrolled
   out of view has no handle, and while either end is clamped neither handle
   drags, since a drag re-presses at the other end (`touchSelectionRange()`
   compares the selection's text with the visible cells it spans). Removed:
   the request type (`TerminalTextSelectionRequest`), its delegate protocol,
   `TerminalViewState.onTextSelectionRequest` and its delegate method,
   `TerminalSelectionAnchor`, `UITerminalView.activeTextSelectionDelegate`
   with upstream's `handleLongPressForSelection(_:)` (replaced in
   +TouchSelection), and `UITerminalView`'s
   `override open func gestureRecognizerShouldBegin(_:)`, which refused the
   long-press recognizer unless a host had adopted that delegate. The long
   press now always runs, and a host subclass's
   `super.gestureRecognizerShouldBegin` is UIView's default again.
   - Every synthesized event carries shift, which makes Ghostty select even
     while a program has captured the mouse. The host must configure
     `mouse-shift-capture = never` so no program can claim shift back.
   - A button with no Ghostty action of its own (10) is held, with shift, for
     the length of each synthesized gesture (not 11: Ghostty's per-button state
     array ends at 10). Ghostty reports every pointer move
     to a program tracking all motion (DECSET 1003) while no button is down,
     shift or not; with one down, shift keeps the whole gesture local.
   - Ghostty exports no call that clears a selection, and a shift press while
     one exists extends it. `TerminalSurface.clearSelection(restoringPreedit:)`
     clears it through the preedit path instead (`selection-clear-on-typing`),
     setting an invisible preedit and restoring the input method's own.
   - Presses stay more than a cell width from a recent press (they move to the
     other half of the cell), so Ghostty never takes them for a double or
     triple click.
   - Handles are subviews, so `updateSublayerFrames` and `enforceSublayerScale`
     now leave subview-backed layers alone; the handles sit above Ghostty's
     content layer by `zPosition`. A handle touch never reaches the terminal
     view's `touchesBegan`/`touchesEnded` tap handling, and recognizers whose
     delegate is the view (the long press, the hover, a host's own) refuse it
     (`gestureRecognizer(_:shouldReceive:)`). Upstream's touch-scroll pan,
     indirect-pointer pan and pinch have no delegate and do receive it; the
     handle's zero-delay press recognizes first, and UIKit does not let a
     second recognizer recognize alongside it by default.
2. **Link hit test** (`UITerminalView+TouchSelection.swift`,
   `TerminalCallbackBridge`, `TerminalSurfaceCoordinator`).
   `linkHit(at:)` asks Ghostty which link is under a point the way a
   desktop pointer hovering with ⌘ does — an OSC 8 target first, then its URL
   and path matcher, soft-wrapped lines included — and captures the
   `mouse_over_link` answer through a new internal `onHoverLink` bridge hook.
   The probe holds the guard button, so a program tracking the mouse hears
   nothing, and first moves off the surface, since Ghostty re-resolves a link
   only when the pointer changes cells. The hit also says whether the target
   is exactly the text drawn on the tapped cells, so a host can open a matched
   link at once and confirm an OSC 8 target that says something else; a hit on
   blank cells is none. The target counts as the drawn text only when it
   covers the tapped cell and is bounded on both sides: before it the
   viewport's first cell, a blank, a hard line end, an opening `([{<'"` or a
   backtick; after it a blank, a line end or the viewport's last cell,
   optionally after a short run of ASCII prose punctuation `.,;:!?)]}>'"` or
   backticks. The cells just before and after must also resolve to no link or
   another target, so an OSC 8 run longer than its target never counts.
   Anything else, including wide characters, reads as not shown. The cells
   are read row by row, searched once, and the one candidate confirmed with
   a single range read, so the cost is linear in the target, which may be no
   longer than the viewport.
   `flashLink(at:)` leaves that hover up for 350 ms as tap feedback.
   `pathRun(at:)` reads the path characters around a point (Ghostty's
   `path_chars`: word characters and `-.~:/?#@!$&*+;=%`) straight off the
   grid and carries them across row breaks that are not soft wraps — the
   ones `herdr terminal attach` and mosh repaint with cursor moves, and the
   ones agent TUIs make by wrapping their own text, where Ghostty's matcher
   sees each row's fragment alone. A run continues onto the next row when
   it is its row's last text, that text ends within two cells of the edge,
   and the next row's text starts with a path character; back onto the row
   before the same way; at most eight rows either way. Inside a bordered
   box the same holds within the borders: a row whose last character is a
   box-drawing border (U+2500–U+257F) at the edge, at most two blanks after
   the run, with the same border before the run, joins a next row that
   holds that border in both of those columns and then starts with a path
   character — so the box beside it on the next row never joins. A
   scrollbar column of block elements (U+2580–U+259F, OpenCode's `█`) is an
   edge the same way: at most two blanks before it, a block element in that
   column on the other row or nothing there (OpenCode draws the thumb on
   some rows only) and no text past it, and inside the nearest box-drawing
   border before the run (OpenCode's `┃`) when there is one. Unframed, a
   row's text starts past its indentation and a frame column opening it
   where the row has nothing framing its right (Kilo's `┃`) or the row above
   has the same glyph in that column, as Waycar's link scanner reads it. The run
   says whether it started on an earlier row, so a host can tell a mid-word
   continuation from a word of its own, and gives its part on each row with
   where that part lies on the grid (`layouts`: the row's text and the cell
   it starts in, the cell the part's word starts in, the cell past the
   part, the edge the row can reach — the grid's width, or a frame column
   filling its last cell — and whether the part ends within two cells of
   it), so a host can judge each break by where it falls.
   `pathRun(at:joiningRowsShortOfEdge: true)` continues from a row's last
   text however far short of the edge or its frame it ends (OpenCode and
   Kilo wrap a URL at a `/` or `-` well short of it), those breaks marked as
   not near the edge, for a host whose own rule decides which of them carry
   a URL on. The host keeps the row's own
   reading as a fallback, since a path that only ended near the edge joins
   the next row's first word too. `selectedPathRun()` gives the run a
   selection over more than one row covers exactly (blanks, box borders and a
   scrollbar column at either end aside), so a host can offer a path the
   selection spells across a break but not rows that only sit one above
   another.
3. **Host tap hooks** (`UITerminalView.swift`). `sendsTapClicksToSurface`
   lets a host that reports taps itself turn off Ghostty's own tap click, which
   otherwise reported every tap to a mouse-tracking program a second time.
   `touchSelectionWillBegin()` lets a host stop its own scrolling;
   `isHostMomentumScrolling` makes a tap during the host's own flick only stop
   it; `touchSelectionHandlesDidChange()` reports the handles appearing,
   moving and going, and `touchSelectionHandleAreas` where they take touches.
   `claimPointerClick(at:modifiers:)` lets a host take a plain single
   primary mouse or trackpad click (a link it opens) away from Ghostty
   (`UITerminalView+Pointer.swift`): `handleIndirectPointer(phase:at:buttonMask:tapCount:)`
   holds the claimed press back, so no position, press or release reaches
   Ghostty or a program tracking the mouse; released within
   `tapCandidateSlop` it runs the host's action, moved past it (or taken by
   the indirect pan) it replays the press where it began and goes on as an
   ordinary drag, and cancelled it is dropped. Only a press with a click
   count of 1 is claimed: the first click of a multi-click on a link opens
   it, as a finger tap does, and Ghostty, which never saw that click, takes
   the next one for a fresh single click. Hover and modifier-change position
   reports wait while a click is held, and leaving the window drops it.
   Upstream's report path moved into
   `reportIndirectPointer`, and `pointerButton(from:)` takes the button
   mask instead of the event.
4. **Extra mouse buttons stop at 10** (`TerminalPointerPolicy`). Upstream
   mapped a pointer's button 11 to `GHOSTTY_MOUSE_ELEVEN`, which Ghostty
   writes one past the end of its per-button state array.
5. **Selection geometry** (`TerminalSurface.swift`). `SelectionResult` carries
   whether the selection is on screen at all (Ghostty's `-1` top-left point),
   and `TerminalTextInputHandler.markedText` exposes the input method's
   uncommitted text for the preedit restore. `readViewportText(from:to:)`
   reads a range of visible cells.
6. **Hardware keys the focus system would take**
   (`UITerminalView+KeyCommands.swift`, `UITerminalView+Keyboard.swift`;
   #80). On iPadOS the terminal is not a
   focus item, so with a hardware keyboard the focused item stays a sibling —
   a SwiftUI `List` cell — and the focus system and the text input system
   take keys before `pressesBegan`. Each key below is claimed as a
   `UIKeyCommand` with `wantsPriorityOverSystemBehavior`, like upstream's
   Escape and Ctrl combos, and none is offered while the input method has
   marked text, so a composition keeps them.
   - Plain arrows go to the surface as arrow presses instead of moving the
     list's selection. Modified arrows stay with the press path.
   - Return, alone and with Ctrl, Alt or ⌘ in any combination, goes to the
     surface as Enter. ⌘ is dropped on both paths, so ⌘Return submits like
     Return rather than reaching Ghostty as a super-modified Enter its
     keybinds may consume.
   - Shift-Return is a newline: both paths send Ctrl+J, a bare LF in the
     legacy encoding (omp's `tui.input.newLine` binds shift+enter and ctrl+j
     and reads a raw LF as a newline; a kitty-mode terminal reports ctrl+j).
     It takes the key path, never paste. Shift chords with Ctrl, Alt or ⌘
     stay with the press path.
   - Tab and Shift-Tab, which the focus system uses to move between groups,
     go to the surface as Tab presses (Shift-Tab with its Shift), for shell
     completion and reverse completion.
   - Dedupe: one press can arrive both as `pressesBegan` and as the command.
     `keyCommandInput(for:filteredModifierFlags:)` maps the arrows, Return
     and Shift-Return (`"\r"`) and Tab (`"\t"`) to their command inputs with
     no modifier gate, so both paths claim the same signature through
     `claimKeyCommandDelivery(input:modifierFlags:)` and the first one wins.
   - `isExpectingHardwareKeyEcho` (`UITerminalView+UITextInput.swift`) tells
     a subclass that the next `insertText` echoes a press the view already
     handled, so the subclass leaves it to `super`.
   - On the iPadOS 27 iPad #80 was verified on, none of this fires: hardware
     keys reach the view only as `insertText`, with no press and no command.
     The app handles that path (`WaycarTerminalView.insertText`).

The patches are exercised against the live surface by the app suite's
`TerminalTouchInteractionTests` (word and link selection, handle drags, taps
on and off a selection, link hit tests including soft wraps, OSC 8 and paths
broken across repainted rows, and
that none of it sends a byte to a program tracking the mouse) and
`TerminalTouchSelectionEdgeTests` (OSC 8 targets that are only the start of
their text, bounded exact targets, no drag while an end is scrolled away,
overlapping handle touch areas, knobs on the edge rows).

## Updating

Diff upstream's new `Sources/` against the commit above and re-apply the
patches. In `Scripts/build-libghostty.sh` set the new libghostty-spm commit,
the Ghostty commit from that commit's `Ghostty.ref`, and the Zig version its
build requires (its `.github/workflows/build.yml` and Ghostty's
`minimum_zig_version`). Check that `0100-gate-libintl-on-i18n.patch` still
applies; if Ghostty moved that block, regenerate it with
`git diff --full-index` from a clean Ghostty checkout at the new commit, not
from the build tree, which carries libghostty-spm's own `SharedDeps.zig`
edits. Update the package hashes and versions in
`Scripts/collect-libghostty-licenses.sh` to the new `build.zig.zon` pins.
Rebuild, copy the scripts, patch and `LICENSES/` into otreva/ghosttykit and
update its README, publish a new release there (tag
`<libghostty-spm release>-<Ghostty short commit>-nointl.<n>`) with the zip and
`LICENSES.zip`, and set `Package.swift`'s `libghostty` URL and checksum and
the checksum here. Then run
`TerminalTouchInteractionTests`, `TerminalTouchSelectionEdgeTests` and
`TerminalMouseReportingTests`. The
selection and link patches lean on Ghostty's mouse semantics in
`src/Surface.zig` (`mouseButtonCallback`, `cursorPosCallback`,
`mouseRefreshLinks`) and `src/terminal/SelectionGesture.zig`; re-read those at
the new Ghostty commit.
