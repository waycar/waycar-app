# 2026-11-16 — `make screenshots` works again (App Store 1.4.0 captures)

- **Broke:** on main the run's first UI test failed on both simulators
  within a second ("Failed to get list of active applications:
  Accessibility error -25218", at the device orientation), five runs in a
  row; iPad New Agent waited for a Chat Mode row that First Message pushed
  off the sheet; and the app-test keyboard setting put the software keyboard
  over every iPad shot that opens an Agent. Nobody had run it since the
  captures of 2026-10-31.
- **Worked:** reading the failure from the session clone's xcresult over
  `ssh mac` (`xcrun xcresulttool get test-results tests|activities`):
  mac_run's log has only pass/fail lines, and the activities named the
  failing call.
- **Watch out:** an XCUI failure ends the test or teardown block it happens
  in, even inside `XCTExpectFailure` with `continueAfterFailure` on, so a
  retry loop in one test never retries; separate teardown blocks do.
- **Watch out:** `-retry-tests-on-failure` retries at once, still inside a
  startup failure window; it hid the failure in one run and not the next.
