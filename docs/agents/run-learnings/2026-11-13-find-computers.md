# 2026-11-13 — Find Computers and keys-only Hosts

- **Worked:** reviving a stale draft by cherry-picking it into worker branches,
  then folding their commits onto the public `origin/main` with
  `git rebase --onto origin/main <old base>`; nothing conflicted.
- **Worked:** `deliverables: ["Waycar.xcodeproj/project.pbxproj",
  "Sources/Waycar/Info.plist"]` on a `test-app` run, then `cmp` against the
  committed files, proves the committed project matches what xcodegen writes.
- **Broke:** `make install` to a phone missing from the development profile
  failed with "No Accounts": the Mac's GUI session has no Xcode account.
  `build-device` now passes the App Store Connect key (`ASC_AUTH_FLAGS`) and
  registers the device itself.
- **Broke:** `#expect(await waitUntil { … })` does not compile:
  `waitUntil` throws and returns nothing. Write `try await waitUntil { … }`.
- **Watch out:** Bonjour reports one service per interface. Keep every
  interface's record until the merge, so a sweep find on the second address
  can still enrich the named row.
- **Watch out:** `xcrun devicectl device capture screenshot` captures a
  physical device's screen, but only while it is unlocked and awake; a
  locked phone captures black and refuses `process launch`.
- **Watch out:** iOS's Local Network prompt makes the app inactive, and what
  a search sees behind it (a denial, probes waiting out the answer) is not
  final. Feed scene activity into the machine and decide there: gating
  milestones on activity at delivery time lost a count that finished while
  inactive and still reported one that started behind the prompt.
- **Watch out:** two branches that each add a WaycarSSH package test both
  rewrite the same pinned count in `scripts/run-ci-ios-tests.sh` to the same
  number; git merges that cleanly and the count is one short.
