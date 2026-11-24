# 2026-11-24 — Full-width older-base test saw no older bases on CI

- **Broke:** `testRealMoshServerOlderBasesWithFullWidthSymbolRows` saw 0
  older-base states on main `c05fe30` and on PR #20. Not a client bug: the
  plain-lines test in the same runs saw 107–146. mosh-server 1.4.0 picks
  the acknowledged base when that diff is within 100 bytes of the newest
  one's, or once its RTO plus 100 ms runs out. A 226-byte status row
  rarely fits the margin, and a steady delay is part of the RTO.
- **Worked:** the test prints its count, so 50 CI job logs gave the
  baseline in minutes (0–6 a run, two zeros). A throwaway Python mosh
  client against the agent host's real `mosh-server` (`-v` logs each
  send's base) reproduced 0 on purpose at CI's loop pace and sized the
  fix before any Mac time.
- **Watch out:** `mac_run test-swiftmosh` takes no vars, so its
  real-server tests skip. A throwaway commit whose recipe runs them with
  `SWIFTMOSH_REAL_E2E=1` in a loop is the Mac path for a mosh flake.
