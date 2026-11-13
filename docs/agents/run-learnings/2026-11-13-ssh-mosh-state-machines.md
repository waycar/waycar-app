# 2026-11-13 — SSH and mosh lifecycles as state machines

- **Worked:** lanes no local target can run (the WaycarSSH package E2E, the
  real-server SwiftMosh suites) were proven on hosted CI by pushing the branch
  as a draft PR (`gh pr create --draft`) before landing; the PR sweeper skips
  drafts. Close the draft and delete its branch at submit.
- **Worked:** a suite that turns a missing fixture into a skip needs a count
  guard: CI's SwiftMosh step reads each real-server suite's XCTest summary and
  fails unless all its tests ran with none skipped.
- **Broke:** hosted iOS CI's full app lane was red for unrelated reasons (a
  cold build past the 1800 s watchdog, starved 30 s waits), so it cannot gate
  a landing on its own; the app lane came from `make test-ci-app` on the Mac.
- **Watch out:** in a vendored package, deferring a row is the right call when
  its ordering protects something no owner test sees (a nonce, a native
  pointer freed under a mutex); write the reason into the catalogue row.
