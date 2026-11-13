---
status: superseded
---

_2026-10-31, superseded: Mike removed the Mirror. He wants the phone and the desk to each lay out the same chat at their own size, and a terminal cannot: one PTY has one size. A desk-sized screen panned on the phone is not that, so the app code and `waycar mirror` were deleted (plugin 2.3.0). The record below stays for what it measured._

# A watch-only live terminal over herdr's observe stream, not another attach

_2026-10-28, accepted: Mike's decision of 2026-10-27 (WAY-352), design in `docs/design/mirror.md`, transport in WAY-365 (PRs #326, #327, #329, #330, #331), rendering spike in WAY-363. The view is WAY-366 and is not built yet._

Attach opens an Agent's terminal at the phone's size. For herdr that resizes the pane's PTY and holds a resize lock until the client leaves, so the tab on the user's computer changes shape every time the phone connects or the keyboard moves (ADR 0013). The Mirror shows the same live screen without touching the pane's size. Attach stays as **Fit to phone**.

Decisions:

- **Read the screen herdr already draws; never attach.** On a herdr Host the app runs `herdr terminal session observe` through a plugin bridge, at the pane's exact size. Many observers can watch one pane. A frame is herdr's own `terminal.frame` line (the first is full, the rest are diffs), so a terminal emulator at the same grid reproduces the screen. The viewport is a crop, not a reflow, which is why the grid must equal the pane's.
- **One bridge process per Mirror, plugin 1.6.0 (`mirror.js`, a Node script then; `waycar mirror` from plugin 2.0.0, ADR 0031).** Bare `observe` over SSH cannot size itself to the pane (herdr exposes no column count; the bridge reads the shell's tty), cannot restart on a desk resize, and outlives a dead SSH client on an idle pane. The bridge starts the observer at the pane's size, restarts it on resize, ends it on stdin EOF or a write error, and is the only thing the app talks to. The wire is NDJSON, protocol v1, unknown types ignored in both directions. The pane id travels in the first stdin line, never in a shell string.
- **A reset is the only place the grid changes.** `mirror.reset` carries `cols`, `rows`, `mode` and a reason; the app clears, sets the grid, then applies frames. The bridge never forwards `terminal.resize`.
- **The transport is a non-PTY SSH exec channel, in the attach class of channel admission.** Not mosh, which syncs a screen and not a byte stream. A reconnect starts a new bridge and gets a full frame. The channel exposes exit status and a stderr tail, because the bridge's exit codes (127 no Node, 64 plugin too old, 1 after `mirror.error`) are how the app chooses between "update Host Tools" and falling back to Fit to phone. Mirror availability is gated on plugin 1.6.0 per Host; `minimumVersion` for the whole app is not raised (the Mirror is optional).
- **Watching is read-only; on herdr, Take control is explicit (tmux has none: Fit to phone is how you type there).** Control uses `terminal session control --takeover` at the pane's exact size, so it neither resizes nor sits idle holding a lock for long: the view releases it after a few idle seconds. Input rides the open session (`terminal.input`, `terminal.scroll`, `terminal.mouse`), not one API connection per key; toolbar keys use herdr key names (`pane.send_keys`), not tmux's. The one way a Mirror can resize the pane is a desk resize inside the few milliseconds between reading the size and control starting; herdr's CLI offers no "only at this size", so the guarantee is "never, except in that race".
- **Render in a Ghostty surface sized to the pane's grid, inside a scroll view that pans and zooms.** The WAY-363 spike measured it. The frame is `cols * cellW + 2 * pad` by `rows * cellH + 2 * pad` points (cell sizes in pixels from the first metrics), with window padding 0, and the grid came out exact in all 380 font-size cases per device. Three constraints carry into the view:
  - The surface is capped at 8192 px wide in the Simulator (not checked on a device); past it, right-hand columns vanish, so the font is clamped.
  - A font change needs an inflated frame first, or the grid dips below the pane's for a moment; apply it only when the font really changes, and allow fractional sizes.
  - A reset is clean as clear (`ESC c`), then resize, then frames (one run per device; the iPad reset call took 354 ms against 53 to 104 ms elsewhere, and the report does not trust that figure or the flicker results). Resizing a live surface shows cropped old content for about 150 to 170 ms.
- **tmux has no bridge.** The Mirror attaches with `-f read-only,ignore-size` on a PTY sized to the window (`#{window_width}x#{window_height}`) and follows the window's size. This reverses `docs/design/tmux-backend.md` §4.4, which rejected `ignore-size` because the phone then shows a desk-sized screen. The Mirror accepts that and pans. Two tmux facts the design missed, found on 3.2a, 3.4 and 3.8: `ignore-size` does nothing while no other client is attached, and a client's status line takes a row, so the Mirror's chain turns the status line off.

## Consequences

- Hosts need plugin 1.6.0 for a herdr Mirror. Below that, or on `size_unavailable` or `herdr_unavailable`, the Host falls back to Fit to phone and the Host Tools update offer applies.
- A Mirror shows the screen as it is now. An alternate-screen Agent leaves no scrollback in herdr, so history, search and offline reading are separate work.
- 119 columns on a 440 pt phone fit at about 6.1 pt text with padding 0 (about 5.6 pt with the default padding). That is an overview size: the default view pans and zooms, and fit width is a zoom level. iPad portrait fits at about 14 pt text.
- Memory grows with the grid. At 3x the presented surface is 15.5 MB for 119x40 at 8 pt and 128.9 MB for 250x70 at 12 pt (Simulator, Debug). An optional render scale of 2 cut the large case to 56.3 MB, at the cost of sharpness nobody has judged on a device.
- A full repaint of a worst-case screen (every cell a different truecolor pair) costs about 37 ms to parse at 119x40 and 120 ms at 250x70. Real bridge frames are diffs and the real recordings are cheap.
- The bridge has no herdr in CI. Its unit tests use a fake herdr and fake time, and the app's real-sshd E2E uses a shell script standing in for the bridge. The live checks (real herdr 0.9.5, real tmux) were run by hand in a container, not on a device.
- The Android lineage (`apps/android/swift-core/sources-android.txt` on `android-main`; main has no such file) lists the files it compiles. `Transport.swift`, `WaycarSSHTransport.swift`, `HostSSHSession.swift` and `TmuxTransport.swift` are on that list and now name Mirror types. When `main` merges into `android-main`, the Mirror transport files must be listed or the references excluded, and `Terminal/HerdrKeyNames.swift` stays out because it needs `AgentQuickKey`, which lives in a UIKit file.

## Open

- No real device run: CPU, memory and the 8192 px cap are Simulator numbers.
- tmux Mirror was not run in the rendering spike (its question 7): grid versus PTY size at several fonts, a tmux client resize while attached, and `terminal.scroll` against tmux scrollback.
- iPad pinch-out through the scroll view did not register in two tries; the cause is unknown.
- Gesture conflicts between the terminal's one-finger pan and pinch and the scroll view's are only partly sorted out (WAY-366).

## Considered options

- **Keep attaching and accept the resize**: rejected. It is the problem: the tab on the user's computer changes size, and the keyboard moves it again.
- **A bare `herdr terminal session observe` over SSH, with no bridge**: rejected. It cannot find the pane's size, follow a desk resize, or end with its channel (an idle observer outlived a SIGKILLed `ssh` for as long as we looked).
- **Render the frames in a custom text view**: not pursued. The frames are ANSI diffs; the Ghostty surface already draws colors, box drawing, CJK and emoji (0 differing text rows in 9 reset segments over 6 recordings; colors and styles were checked by eye, not by pixel diff).
- **Mosh for the stream**: rejected. Mosh syncs a screen state, not a byte stream.
- **A tmux bridge**: not built. A read-only, `ignore-size` client on a PTY sized to the window gives the same guarantee with no Host plugin.
