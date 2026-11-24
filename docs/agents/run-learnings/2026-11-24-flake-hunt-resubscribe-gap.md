# 2026-11-24 — Two flake-hunt failures in the pane resubscribe gap

- **Broke:** the flake hunt at `5499cc6` failed two tests once each in 16
  passes. Both acted right after the Console's first rows, while it swapped
  in its pane subscription and no events channel was live. Test races, not
  app bugs; users could not hit either.
- **Broke:** `aFailedHostIsAskedAgainWhicheverNonRetryableClassStoppedIt`
  (loaded job, host-key case only by chance) closed the scripted link after
  the resubscribe's connection check. `ScriptedTransport` still accepts a
  subscribe once closed, so the Host stayed connected: the pass log shows no
  loss and no dial. A real closed link refuses the subscribe.
- **Broke:** `concurrentLifecycleCallsFinishInCallOrder` (quiet job) gated a
  ping and reactivated in the gap; `revalidate()` pings only a live channel,
  so the gate was never entered. The pass log matched exactly: line 49, then
  `console.isActive` false at line 60.
- **Worked:** red in one Mac run: gate the first snapshot, gate the next
  subscribe once it is entered, open the snapshot, then act while the
  resubscribe waits. Both old orderings failed at the CI lines; both fixed
  ones passed with the subscribe held 200 ms.
- **Watch out:** the gap now has a line in Known traps. Sibling tests
  already used the file's `waitUntilPaneResubscribeSettles`: check a
  failing test's neighbours for the step it skipped.
