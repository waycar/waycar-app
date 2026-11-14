# 2026-11-14 — herdr transport and events session state machines

- **Worked:** two `mac_run` workers, one per file set (the herdr transport,
  `EventsSession` + `ConnectionLiveness`), each with the other's files
  off-limits, landed separately. Running each refactor in the same Mac run as
  the next row's pins kept the queue waits down without losing the
  green-at-base proof.
- **Worked:** owner tests that need real SSH (the herdr Transport) live in
  the SharedFixture lane, so its pinned count rises with them (155 → 163);
  `test-app` with TEST_FLAGS skips them.
- **Broke:** two race pins looked deterministic and were not: one waited a
  fixed 3 s window, one awaited a continuation's release rather than the step
  it released. Ask of every race pin: does the await prove the racing step
  happened, or only that it was released? Hold the step at the fake server
  instead.
- **Broke:** a merge commit went in with conflict markers in
  `docs/design/state-machines.md`; the index check still passed. It now fails
  on markers (`scripts/check-state-machines.py`).
- **Broke:** the first real `make test-harness-lab` from a fresh clone: the
  name-only destination resolved to iOS 27.2, which holds no shared Pro Max
  (`run-e2e.sh` now takes `SIM_DESTINATION`). Then claude was not signed in to
  the mock, because its endpoint config was never committed, and it updated
  itself mid-run. codex covered the herdr path end to end.
- **Watch out:** a lab harness's config must be committed: claude's
  (`config/claude/env`: endpoint, dummy `ANTHROPIC_AUTH_TOKEN`, no
  auto-update) had lived only in the worktree that first ran the lab.
  `ANTHROPIC_API_KEY` instead opens an approval dialog whose default is No.
