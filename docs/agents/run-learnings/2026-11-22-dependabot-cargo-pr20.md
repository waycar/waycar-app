# 2026-11-22 — Dependabot cargo group (#20): plugin 2.6.4

- **Worked:** pushing the fix (plugin patch bump, regenerated
  `THIRD-PARTY-LICENSES`) onto Dependabot's own branch and merging the PR,
  instead of a separate branch that supersedes it.
- **Worked:** qrcode 0.15's `default-features = false` now also drops its new
  `std` feature; the plugin needs none of it, and
  `qr_symbol::tests::the_modules_equal_what_the_qrcode_package_builds_for_the_vectors`
  is the check that the Pairing Code QR did not change.
- **Broke:** `cargo update -p waycar --offline` failed on a registry cache
  that did not have the bumped crates yet, and passed once an online cargo
  call (`cargo metadata`, via `plugin-licenses.py`) had fetched them.
- **Broke:** this entry and a docs fold first rode the Dependabot branch;
  the PR sweeper then treated #20 as a human PR that changes the workflow
  and asked for a linked issue. The docs moved to an Ultimate branch and the
  Dependabot branch was reset to the bump plus its plugin fix.
- **Watch out:** a Dependabot PR carries only the bump and what it needs
  (plugin version, notices, code for API changes); its run-learnings entry
  and any doc edits land through `workspace submit`.
- **Watch out:** after the version bump, `git diff plugin/Cargo.lock` must
  show only the `waycar` version line.
- **Broke:** the SwiftMosh job failed once, unrelated to the PR:
  `testRealMoshServerOlderBasesWithFullWidthSymbolRows` left the terminal
  right but saw 0 older-base states (`XCTAssertGreaterThan`): the real
  mosh-server never built on an older base that run. A rerun passed; a
  flake-hunt candidate.
