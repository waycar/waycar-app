# 2026-11-15 — Pre-launch wording: private-era comments, Mac-runner text, patch counts

- **Worked:** counting patches from each `PROVENANCE.md` before editing a
  number, then checking the spun-out `waycar/swift-mosh` README too: the
  launch copy's "16" was neither the library's 17 nor the app's 20.
- **Worked:** replaying a spin-out's new commits the way its history was
  built (`git format-patch --relative=Packages/SwiftMosh <cut>..main --
  Packages/SwiftMosh`, then `git am -3`), then `diff -r` against
  `git archive` of the monorepo package: only the fork's own files and its
  `Scripts/` → `scripts/` rename may differ.
- **Watch out:** a regex sweep for "private repo" misses the same idea in
  other words ("the relay is not public", "App Review material stays
  private"); read the hits' neighbours too.
- **Watch out:** the spin-out's own CI runs only on its push, after the
  fact; the monorepo's `SwiftMosh package (macOS host)` job, with
  `SWIFTMOSH_REAL_E2E=1`, on a commit with the identical package tree is
  the evidence before it.
