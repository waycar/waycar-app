# 2026-11-15 — Main green again: secret scan, a plugin flake, three app-lane flakes

- **Broke:** the generic leak check failed every push to `main` for a day
  (example LAN addresses in the Find Computers tests) and nothing said so:
  the lander never runs it. It is in Before submit now.
- **Worked:** a red proof for a kernel-timing flake without load: the same
  `spawn` then an immediate `/proc/<pid>/cmdline` read, 300 times, missed
  289. The test had passed only because two more spawns ran first.
- **Worked:** the three hosted app-lane failures shared one cause (now a
  Known trap: Console rows show before the events channel carries their
  panes). Gating the fake's initial snapshot and the replacement subscribe
  made all three fail at once on the base.
- **Watch out:** a mac_run session step without `sha` runs the commit the
  session opened at, not your newest one: pass `sha` on every step.
- **Watch out:** `scan.py` walks untracked files too, a built
  `plugin/target` included: scan a `git archive HEAD` export when the
  worktree has build output.
