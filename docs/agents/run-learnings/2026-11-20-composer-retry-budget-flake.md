# 2026-11-20 — Composer retry flake: a millisecond budget on the real clock

- **Broke:** the flake hunt failed
  `agentNotReadyRetryExhaustionSurfacesTheRefusalWithAttemptsLeft` once in
  16 passes (quiet job, pass 3, 0.427 s against 0.020 s elsewhere): one
  `agent_not_ready` attempt instead of several. Not an app bug: the test
  gave the Composer's wait a 20 ms budget on `ContinuousClock`, the host
  stalled through the first attempt, and the budget ran out before any
  retry, as it should. In the app the budget is 45 s with a 0.5 s pace.
- **Worked:** red in one step: a 50 ms `Task.sleep` in the test's prompt
  closure failed the same expectation every time. Then the store took a
  `now` and `sleep` (defaults: the real clock) and the seven tests that
  count retries inside 20–40 ms run on a clock only the wait's sleep moves,
  so the count is exact (4 for 20 ms at a 5 ms pace), stall or not.
- **Watch out:** a test that counts what happens inside a budget the code
  measures needs that budget on an injected clock, even when the budget is
  tiny: the host's stall, not the budget, decides the count.
