# 2026-11-15 — Weekly iPad crash: ghostty's renderer thread laid out UIKit

- **Broke:** the weekly iPad run read "1687 tests passed" after about 5,900
  had run: the test host crashed, xcodebuild relaunched it for the rest, and
  Swift Testing's summary counts only the last launch. `ci-evidence.py` now
  says "in the last of 2 launches, 1 crash report".
- **Broke:** `ipad-weekly.yml` kept no crash report, so the crashing
  thread's name was lost; the stack in the log had to do. Both app lanes
  (`ipad-weekly.yml`, `ci.yml`'s `build-test`) now upload `Waycar*.ips`
  when they fail.
- **Worked:** `CA_DEBUG_TRANSACTIONS=1` in the scheme's test environment (a
  throwaway commit) printed who created each "deleted thread with
  uncommitted CATransaction": libghostty-spm's `setNeedsDisplay` on the
  renderer thread, about one per surface free, in every lane.
- **Worked:** a red test on the symptom instead of the race: read
  `OSLogStore(scope: .currentProcessIdentifier)` from before the free to a
  marker the test logs itself; the marker's arrival proves the read is
  complete.
- **Broke:** three probes (dirty layers beside the terminal, above it, a
  navigation controller over it) never got laid out by the exit commit,
  which spent four Mac runs: find who creates the transaction first.
- **Watch out:** one Core Animation call off the main thread, even
  `setNeedsDisplay`, leaves an implicit transaction that commits only when
  the thread exits, and that commit can lay out UIKit on that thread.
