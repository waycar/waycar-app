# 2026-11-16 — Main green: a worktree-removal test raced the Console's second snapshot

- **Broke:** `linkedWorktreeRemovalRecordsOnlyItsAffectedAgents` failed once
  on hosted CI with `.staleIdentity`. It staged the post-removal snapshot
  right after the first rows, and the initial sync's second snapshot read
  it, so w1 was gone before the removal asked. A test bug: a removal's
  identity (workspace, repo, checkout path) survives any resnapshot of an
  unchanged Host, so 1.4.0 users cannot hit it.
- **Worked:** a red proof without load: hold the first snapshot, gate the
  next subscribe (the replacement), open both, and release the replacement
  only after the test's `setSnapshot`. All three probes failed on the base.
- **Worked:** the sweep grepped for a `setSnapshot` before an
  identity-checked action (`removeWorktree`, `moveAgent`) with no sync wait
  before it: four tests, now behind `waitForInitialConsoleSync`.
- **Broke:** the projection-level `waitForInitialConsoleSync` timed out on
  a seeded projection: `seed` makes the first subscribe carry the panes, so
  one snapshot is the whole cycle and none follows. There
  `!projection.isAwaitingSnapshot` is the right wait.
- **Watch out:** a wait for the replacement subscribe in
  `capturedSubscriptions` does not mean its snapshot ran.
  `snapshotFetchCount >= 2` does, because the fake reads its response
  before any suspension.
