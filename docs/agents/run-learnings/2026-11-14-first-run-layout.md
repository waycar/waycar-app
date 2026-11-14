# 2026-11-14 — First-run layout: scan mid-screen, Sample second, Set up by hand last

- **Worked:** rendering the real `ConsoleView` with `HostStore(volatileHosts: [])`
  in a throwaway unit test (window per device size, light/dark,
  `.dynamicTypeSize`, a sheet for the Hosts and Connect screens, run on the
  iPhone and the iPad simulator through `mac_run`) gave true first-run
  screenshots without a launch flag or a shared simulator's Host catalog.
  Walking the hosting view's accessibility elements gave the VoiceOver order
  in the same run.
- **Broke:** `ScrollViewReader.scrollTo` called while an opening animates
  goes nowhere: from `onChange`, the next main-queue turn and
  `onScrollGeometryChange(contentSize)` alike, the offset stayed at the top.
  Scroll from `withAnimation { … } completion:` instead. A one-screen probe
  of all four variants, logging `UIScrollView.contentOffset` every 250 ms,
  settled it in one run.
- **Watch out:** SwiftUI's accessibility nodes in a hosted test window
  report an empty `accessibilityIdentifier`; find them by label.
  `accessibilityActivate()` on the node runs a SwiftUI `Button`'s action.
