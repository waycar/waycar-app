# 2026-11-13 — The hosted iOS lane, green on the 3-core runner

- **Worked:** a throwaway probe workflow on a scratch branch (boot one fresh
  simulator on an otherwise idle runner, sample the load every 10 s, delete
  the branch) settled in one run what five red lanes only hinted at.
- **Worked:** memory and swap in the host-load samples ruled memory out in
  one run (7 GB, never under 22% free); CPU was the problem.
- **Broke:** a new iOS 27 simulator's first boot saturates the public repo's
  3-core `xcode-27` runner for about 15 minutes (load 300–600). Overlapped
  with fixture setup and the build, it made tmux builds take minutes, the
  build pass its watchdog, and fixture timeouts fire. The private staging
  repo got 5 cores, so it never showed.
- **Broke:** `actions/cache` saves only when the whole job passes, so a lane
  that never went green rebuilt its tmux cache on every run. Save a costly
  cache in its own step with `actions/cache/save`.
- **Watch out:** hosted runs read `host-load.log` in the diagnostics
  artifact: one-minute load against cores, free memory, and the top
  processes. A sample gap of minutes means the machine itself stalled.
