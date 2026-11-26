# 2026-11-26 — Flake-hunt mosh probe check raced a Console rebuild

- **Broke:** `aDiscardedProbeLetsTheNextReconcileProbeAgain` failed once in
  16 flake-hunt passes (loaded job, `e9462bf`): `moshProbe` read
  `(generation: 0, available: true)` 100 ms after the discard. The answer was
  discarded and the claim given back; a Console rebuild in that sleep probed
  again on the new reading, and that answer counted. A test race, not an app
  bug: the Host re-probed as designed, so users could not hit it.
- **Worked:** red 5/5 on the Mac: await the discarded probe's Task, call
  `rebuild()`, then the old check. The fix gates the next probe, awaits the
  discarded Task instead of sleeping, and reconciles in the last wait, since
  a probe a stray rebuild began before the reading reverted is discarded in
  turn. 25/25 with and without that stray rebuild; with the claim kept (the
  bug it guards) it still fails.
- **Watch out:** under load the natural race beat a 5 ms poll for the
  released claim (red v1 never saw it in 30 s): await the probe's Task
  rather than polling for a state the next rebuild undoes.
