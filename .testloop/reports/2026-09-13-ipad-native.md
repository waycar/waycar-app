# testloop — 2026-09-13 — ipad-native (iPad first-class acceptance)

**Verdict:** accepted with four fixes (ten commits, final SHA `1b6c792`); hover and hold-⌘ overview remain unexercisable with synthetic input · **Rounds:** 4 · **Branch:** `feat/ipad-native`

Acceptance of the six-package iPad round (target-lanes, input-chrome,
drop-composer, split-presentation, keyboard-commands, multiwindow) merged onto
`feat/ipad-native` from `main@f241466`. Rounds 1–2 ran while the Mac screen was locked, so the driver executed
every step at device level with `idb` and `simctl`. Once the screen was
unlocked, rounds 3–4 re-ran the screen-dependent items through the Codex
computer-use tester on the iPad Pro Simulator (real key chords via
`cliclick`, Simulator menus via osascript, Windowed Apps mode, cross-app
touch drags), and the driver finished the two drag steps by hand.

## Covered

- iPad Pro 13-inch (M5), portrait: empty state, form-sized Hosts / Settings /
  New Agent sheets, Composer menus, Attach Links popover, the whole hardware
  keyboard command table (⌘1–9, ⌘[ ⌘], ⌘F, ⌘N, ⌘,, ⌘⇧H, ⌘E, ⌘↩, ⌘W), key
  pass-through to the agent TUI (Ctrl-C, Esc, arrows, letters), ⌘+ / ⌘−,
  the hardware-keyboard shortcut strip, Open in New Window, input in the second
  window, same-Host terminal handover between windows, scene restoration after
  background + terminate.
- iPad mini (A17 Pro): onboarding with a fresh Device Key, sheets, sidebar
  overlay, Attach Links popover, strip, Composer with the software keyboard.
- iPhone 17 regression: onboarding, full-height Hosts sheet, Attach Links as a
  sheet, Composer with the software keyboard, Direct-input strip.
- Round 3 (GUI, iPad Pro): rotation to landscape and back with the split
  view and terminal reflowing (1a–1d); ⌘1/⌘3/⌘4 selection, ⌘] ⌘[ host
  cycling, ⌘F search, ⌘E Composer↔Direct both ways with Ctrl-C / Esc / arrows
  passing through, ⌘↩ send, ⌘+ / ⌘−, ⌘V into the Composer draft, ⌘W closing
  the detail; the Attach Links popover with real links.
- Round 4 (GUI, iPad Pro): Attach Links popover anchored to the chip and to
  the Direct-input floating button; Composer and Direct-input inset after the
  software keyboard leaves (fix 4 regression); Windowed Apps live resize
  narrow/wide with terminal reflow; two windows on one Host with
  `Live in Another Window` / `Take Over Here` handover both ways; cross-Host
  windows both live; drag of selected Safari text into the Composer (copy
  badge while hovering, text inserted); drag of a Photos image (placeholder
  token + `Waiting for image…`, Send disabled, then the remote path and Send
  enabled; the file landed on the Host). 15/15 PASS.
- Unit gates: targeted suites after each fix; full `make test` on the final SHA
  (see Verification).

## Found & fixed

- **No ⌘ command fired while the terminal had focus (Direct input).**
  libghostty's `UITerminalView.pressesBegan` never calls `super`, so UIKit never
  reached the scene's key commands: ⌘E could not return to the Composer, ⌘1–9,
  ⌘N, ⌘W were dead. `TerminalScreenView` now routes ⌘ chords other than the
  zoom pair to the next responder and keeps everything without ⌘ on the
  Ghostty path (`8100904`, `Sources/Heeler/Terminal/TerminalScreenView.swift`,
  test `commandChordsBypassGhosttyExceptZoom`).
- **Attach Links popover detached from its chip.** The `.popover` sat on the
  whole detail view, so on iPad it rendered top-centre with the list
  off-screen. It is now attached to the Composer chip and to the Direct-input
  floating button, sharing one origin state (`67767ee`,
  `Sources/Heeler/Console/AgentTerminalView.swift`, `AgentComposerView.swift`,
  test `attachLinksPopoverPresentsOnlyFromTheControlThatOpenedIt`).
- **Terminal drawn at 2/3 size after the first software-keyboard raise on the
  iPad Pro.** libghostty derives a wrong `contentsScale` from the old IOSurface
  after a resize and only corrects it on the next render tick; an idle Composer
  never ticks. `HeelerTerminalView` now re-runs layout 0.1 s and 0.5 s after a
  bounds change so the sublayer scale is reasserted (`247dafd` + test fixup
  `e8f1049`, `TerminalScreenView.swift`, tests
  `everyTerminalSizeChangeSchedulesOneScaleSettle`,
  `scaleSettleFollowUpsRunInOrderAfterTheChange`). Manual re-check: see
  Verification.

- **Composer and Shell Terminal kept the software keyboard's height as
  bottom inset after a hardware keyboard reconnected (round 3).** The
  `.system` layout pinned the inset to `lastPresentedHeight`, which survives
  dismissal; with a hardware keyboard the will-hide arrives while the Composer
  keeps focus, so an empty band the size of the keyboard stayed below the
  Composer. `TerminalKeyboardInset` now confirms a dismissal (350 ms after
  will-hide, unless a presentation answers it), publishes
  `isSoftwareKeyboardDismissed`, and the Composer / Shell layouts use the
  current height in that state; handoffs (Composer↔Direct, Keys↔Text) carry
  an unconfirmed dismissal across the responder switch and reconcile it
  against the window's keyboard measurement on exit, including the case where
  a keyboard presents during the handoff after a confirmed dismissal
  (`8e3c920`, `ebce436`, `4d96086`; `TerminalKeyboardInset.swift`,
  `AgentComposerView.swift`, `AgentTerminalView.swift`,
  `ShellTerminalView.swift`). The iPad re-check of `4d96086` then found the
  other side of the same coin: disconnecting the hardware keyboard while the
  Composer already had focus left the Composer under the software keyboard.
  The device's unified log showed UIKit posting the will-show frame with its
  origin on the screen's bottom edge (`(0, 1376, 1032, 403)`), which measures
  as zero coverage and was dropped, and before fix 4 the `lastPresentedHeight`
  pin had hidden that. `TerminalKeyboardInset` now remembers such a missed
  presentation and settles against the window's `keyboardLayoutGuide` on
  did-show (`90770ee`). That still left the Composer under the keyboard on
  the device: the unified log showed `UIWindow.keyboardLayoutGuide.layoutFrame`
  is always `.zero` for this app's windows, so every did-show settle measured
  nothing. The inset now reads the root view's guide converted into the
  window (`8b3e07e`), and every other guide reader (the Agent terminal's
  window measurement, the Composer's handoff settle, and the terminal's own
  settle fallback, which had therefore only ever ended on its 0.5 s timer)
  goes through that one helper (`1b6c792`). 16 new tests across
  `TerminalAttachTests` and `TerminalKeysKeyboardTests`, two of them against
  a real `UIWindow` with the real keyboard. Manual re-checks on the iPad Pro
  and the tester's round-4 steps 2a–2d: see Verification.

## Still open

- **Trust alert dropped after Save (pre-existing on main).** Saving the Add
  Host form presents `Trust this Host?` while the form sheet is still
  dismissing; UIKit logs `Attempt to present … which is already presenting` and
  the alert is lost, leaving `The host key is not trusted` until the Host is
  reopened. Reproduced on iPad Pro, iPad mini and iPhone 17;
  `Sources/Heeler/Hosts/` is untouched since the base, so it is not an iPad
  regression. Worth an issue.
- **⌘W falls through to iPadOS Close Window.** When the app's ⌘W is disabled
  (sheet open, nothing selected) the system closes the window; with a single
  window the app quits. Behaviour of every multi-scene app, but the app-level
  ⌘W (close Agent view) shares the chord. Decision needed on whether to keep
  ⌘W.
- **Simulator shows the hardware strip everywhere.** `GCKeyboard.coalesced` is
  never nil on the Simulator, so the software-keyboard strip variant (Esc, Tab,
  arrows) is only covered by unit tests; real devices without a keyboard keep
  it.
- **Cosmetic:** on the iPad mini in portrait (and on the iPad Pro in Direct
  input with the sidebar overlay open) the sidebar overlay's bottom edge is
  drawn over the Direct-input strip as two rounded light blocks.
- **Hosts sheet has no Done button on iPad** (dismiss by tapping outside);
  `HostListView.swift` is unchanged since the base, so pre-existing.
- **Dismissal heuristic.** The 350 ms confirmation window is a heuristic;
  a real iPad with a Magic Keyboard whose shortcuts bar animates slower than
  that would be worth a check.
- **Keyboard geometry coverage (review N3/N4).** The live-window tests use
  full-screen windows with plain root controllers; non-zero root offsets,
  Stage Manager resizing, floating / split keyboards and cross-scene
  transfers are not covered, and the destination-owned handoff watchdog's
  frozen-zero adoption is only exercised indirectly. A stale positive guide
  during a cancelled dismissal animation could keep an inset until the next
  keyboard notification.
- **Cosmetic:** after a hardware keyboard reconnects while the Composer or
  the Direct-input terminal keeps focus, iPadOS's floating shortcuts pill
  (`A · The · I'm · mic`) sits over the left part of the agent strip until
  the next focus change; the strip itself is at the bottom edge with no band.

## Not exercised

- **Pointer hover.** Simulator's `Send Pointer to Device` captures the mouse
  with relative motion, so the pointer cannot be steered onto a control.
- **Hold-⌘ shortcut overview.** iPadOS never shows it for synthetic key
  events (cliclick or idb); needs a physical keyboard.
- **Hardware strip ↔ software strip switch** on device: `GCKeyboard.coalesced`
  is never nil on the Simulator (unit-tested only).
- **Paste Pairing Code** (excluded by the user).

## Verification

- Targeted suites (checker, iPhone 17): 81 tests / 6 suites on `67767ee`;
  214 tests / 7 suites on `e8f1049`, all green.
- Fix 4 chain (checker, on a dedicated `Heeler ipad-native iPhone 17`
  simulator because the shared `iPhone 17` was being used by another session
  and the first isolated device never presented a software keyboard): 166
  tests / 5 suites on `4d96086`, 169 tests / 5 suites on `90770ee`, 171
  tests / 5 suites on `1b6c792`, all green,
  `composerAndDirectInputTransferVisibleKeyboardWithoutReloading` three
  consecutive passes.
- iPad Pro manual re-check of fix 4 on `1b6c792` (driver, device-level only:
  hardware keyboard toggled through a CoreSimulator helper, taps via `idb`,
  evidence `.testloop/evidence/round-4/driver-1b6c792/`): Composer focused,
  keyboard disconnected → Composer and strip directly above the software
  keyboard, terminal full width (02); reconnected → strip at the bottom, no
  band (03); Direct input, disconnected + terminal tap → key strip above the
  keyboard (05); reconnected → strip at the bottom (06, 08); Composer →
  Direct switched 0.3 s after the disconnect → strip above the keyboard (07);
  back to Composer with the hardware keyboard → Composer above the shortcuts
  bar (09). The Direct → Composer switch 0.3 s after a reconnect could not be
  landed (the tab is moving during the hide animation; the reconnect itself
  laid out correctly, 06b); the fixer's device runs cover both quick switches
  (`.testloop/evidence/round-4/fixer-4e/`, `fixer-4f/`). The same sequence on
  `90770ee` had left the Composer under the keyboard, which is what led to
  `8b3e07e`.
- Code review of the fix-4 chain (codex, read-only): `8e3c920` REJECT (B1
  handoff could discard an unconfirmed dismissal, N1 Shell Terminal, N2 real
  clocks) → `ebce436` REJECT (B2 keyboard presenting inside a handoff after a
  confirmed dismissal) → `4d96086` ACCEPT (N3 watchdog exit not directly
  tested) → `90770ee` ACCEPT (N4 layout-guide geometry injected in tests,
  Stage Manager / floating keyboard geometry not exercised) → `8b3e07e` +
  `1b6c792` ACCEPT (only direct guide read is the shared helper; N4 closed
  for root-guide acquisition, did-show recovery and the Composer settle
  path, broader geometry still open; N3 unchanged).
- Full `make test` on `90770ee`: app suite 1809 tests / 169 suites,
  HeelerSSH package suites 49 tests (15 executed, 34 skipped as before), all
  green. Full `make test` on `1b6c792` (final SHA): app suite 1811 tests /
  169 suites, HeelerSSH package suites 49 tests / 3 suites, all green; tree
  clean apart from this report; HEAD unchanged; `Makefile` `SIM ?= iPhone 17`,
  `scripts/run-ci-ios-tests.sh` default `iPhone 17` and `ci.yml` unchanged.
- iPad Pro manual re-check of fix 3: PASS on two fresh launches (full-size
  terminal at 0.7 s, 3 s and 10 s after the first keyboard raise, and after a
  second raise).
- Code review of the three fixes (codex, read-only): ACCEPT, no blocking
  findings; N1 notes that ⌘C / ⌘V / ⌘A in Direct input now travel the
  responder chain and have no runtime evidence yet (static trace: ⌘V still goes
  through the existing paste review, ⌘C through Ghostty's selection copy, ⌘A
  has no handler).
- Full `make test` on `e8f1049`: the first attempt died before any test
  launched (`Mach error -308, server died`) because the driver restarted
  Simulator.app during the run; the rerun result is recorded below.
- Full `make test` rerun on `e8f1049`: app suite 1797 tests / 169 suites, HeelerSSH package suites 49 tests (15 executed, 34 skipped as before), all green; tree clean, HEAD unchanged.
- `make build-sim` for iPad Pro 13-inch (M5) and iPad mini (A17 Pro):
  BUILD SUCCEEDED on `e8f1049`; Info.plist has UIDeviceFamily 1+2, all four
  iPad orientations, `UIApplicationSupportsMultipleScenes` true, activity type
  `dev.bybee.heeler.agent`, version 0.1.7 (19).
- `scripts/run-ci-ios-tests.sh` default simulator: `iPhone 17` (unchanged).

## Artifacts

- Results: `.testloop/test-results.md` (round 4), archived under
  `.testloop/iterations/ipad-native-round-1/`, `-round-2/`, `round-3/` and
  `round-4/`.
- Evidence: `.testloop/evidence/round-1/` … `round-4/`; fix-4 device runs
  under `round-4/fixer-4e/`, `round-4/fixer-4f/`, `round-4/driver-4d96086/`,
  `round-4/driver-90770ee/`, `round-4/driver-1b6c792/`.
- Simulator hardware-keyboard toggle without Simulator.app (the menu and
  ⇧⌘K paths collide with the user's foreground apps): `hwkb-toggle` in the
  fleet round directory, a small CoreSimulator helper
  (`SimDevice setHardwareKeyboardEnabled:keyboardType:error:`).
- Fleet round directory (briefs, verdicts, checks, manifest):
  `$TMPDIR/herdr-fleet-ipad-native/`.
