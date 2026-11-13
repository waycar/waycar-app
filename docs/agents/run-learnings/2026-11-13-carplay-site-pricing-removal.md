# 2026-11-13 — waycar.dev markets CarPlay; pricing page removed

- **Worked:** three children on disjoint file lists (design, content, pricing)
  landed by cherry-pick with no conflicts; each tolerated one named failing
  test owned by another slice. Checking every spoken line against
  `git show v1.3.0:Sources/Waycar/Voice/CarVoiceScript.swift` and
  `BlockedPromptClassifier.swift` kept the copy to what 1.3.0 ships.
- **Broke:** the branch started on the private history and had to be rebased
  onto the public `main` mid-run; only the ops-only commits dropped out.
- **Watch out:** the site's `.kicker` (and other labels) is
  `text-transform: uppercase`, and Apple forbids its product names in all caps:
  never put iPhone, iPad, CarPlay or Apple Watch in a kicker. Xcode 27
  simulators have no CarPlay display (docs/design/carplay.md §7), so CarPlay
  screens can't come from `make screenshots`. Article and compare bodies may
  link only routes in `src/lib/landing.ts` `FIXED_ROUTES`.
