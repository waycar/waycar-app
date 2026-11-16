# 2026-11-16 — Jump Host deadline test: the deadline landed in the wrong phase

- **Broke:** `handshakeDeadlinesTerminatePromptly` failed once on hosted CI
  (8116baa): no `connectionInvalidated` after the inner 150 ms deadline. The
  Jump Host's forwarding open took 151 ms there, so the deadline ran out in
  the open, which keeps the Jump Host by design, not in the stalled
  handshake, which closes it. A test bug; the app reports the same timeout
  either way, so 1.4.0 users cannot hit it.
- **Worked:** the `[WaycarSSH]` diagnostic lines name the phase a deadline
  hit (`direct-tcpip open … timed out` against `handshake … over the Jump
  Host transport timed out`); grepping passing runs' logs for the same test
  showed which phase it normally hits.
- **Worked:** a red proof without load: `holdNextChannelOpenSlotForTesting`
  past the deadline puts it in the open every time.
- **Watch out:** a sub-second deadline that must first outlast an sshd round
  trip measures the runner: size it with `.sshdBudget`, and bound the
  elapsed time by the deadline plus slack.
- **Watch out:** `connectThrough` gives the open and the handshake each the
  whole timeout, so one attempt can take about twice it (#15).
