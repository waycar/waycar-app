# 2026-11-16 — Two hosted-CI flakes on 30338ef: a late resubscribe and UIKit's responder

- **Broke:** `aStaleMissingPluginReadStillDrainsTheNewConnectionsFollowUp`
  counted 3 summary reads, not 2. After a reconnect the Console subscribes
  without the panes, snapshots, then resubscribes and snapshots again; the
  CI log shows that resubscribe after the test's `refreshSidebarMetadata()`
  barrier, so its snapshot asked for summaries once the follow-up read had
  finished. A test bug; an extra summary read is harmless, so 1.4.0 users
  cannot hit it.
- **Broke:** `retiringWhileKeepingTheKeyboardStopsInputWithoutResigning`
  found the retired surface no longer first responder after its 100 ms
  sleep. The failure dump shows its intent still set, so its own release
  never ran (that release clears it). The runner had stalled for a minute
  (`host-load.log`, load over 100 on 3 cores), and the app logged
  `_UIRemoteKeyboards proxy … connection … invalidated` from then on: the
  simulator's keyboard service had dropped the app. A passing run logs none.
  A test bug: no user-facing change.
- **Worked:** red proofs on the Mac without load. Gating the reconnect's
  first snapshot, then the resubscribe, reproduces 3 reads every time; an
  outside `resignFirstResponder()` after the retire reproduces the responder
  failure. Throwaway probes found nothing in a healthy simulator that takes
  a retired surface's responder in 3 s: not key-window changes, not
  `reloadInputViews`, not a blocked main thread.
- **Watch out:** first responder after a run-loop turn belongs to UIKit.
  Check it only synchronously; across a turn, check what the surface itself
  decided (`wantsKeyboard`) behind a `mainQueueTurn()` barrier.
- **Watch out:** grep the failing job's log for `_UIRemoteKeyboards` and
  read `host-load.log` before blaming the app for a keyboard flake.
