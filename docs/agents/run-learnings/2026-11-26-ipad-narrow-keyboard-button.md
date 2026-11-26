# 2026-11-26 — ⌨ stayed lit after its second tap in a narrow iPad window

- **Broke:** ⌨'s light read first responder, the tools dock *or* a
  positive keyboard inset; its tap read only the first two. The report
  (second tap stops typing, button stays purple) fits only the inset
  term, so the light and the tap now share one predicate.
- **Worked:** reasoning from which inputs the tap ignores before any
  repro: the one term the tap never reads is the only one that can keep
  the light on after a dismissal that worked.
- **Worked:** a throwaway `NSLog` diagnostic in the iPad test host (six
  window placements, compact size class, real keyboard, injected
  hardware claim) showed the full-screen simulator always posts
  `keyboardWillHide` and the inset returns to 0; the red test withholds
  the will-hide on an injected center instead.
- **Watch out:** the unit-test host on the shared iPad simulators runs in
  full-screen multitasking: `UIWindowScene.sizeRestrictions` changes
  nothing (scene stays 1032×1376), so a shrunk-window bug cannot be
  reproduced there, only its notification sequence injected.
- **Watch out:** `mac_run test-app` with `SIM='iPad Pro 13-inch (M5)'`
  runs one iPad suite without `test-ipad`'s package suites; the card's
  full log is local (`/tmp/mac-run-logs/<run>.log`), and `NSLog` cuts a
  line at about 1 KB, so log one value per line.
