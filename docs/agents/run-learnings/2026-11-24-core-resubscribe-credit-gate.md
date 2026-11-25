# 2026-11-24 — herdr-core resubscribe test waited for the credit, not the pump

- **Broke:** `CoreTransportTests.resubscribingReusesTheConnection` failed
  once on hosted CI at `6ab0b2b`. It waited for the client's CREDIT of the
  `working` event, but the client credits a frame when it reads it, before
  the pump applies it. When the second stream attached first, `working`
  was that stream's first event, not `done`. A test race: the app delivers
  every event in order, and the Console's resnapshot after each resubscribe
  reads the same inventory, so users could not hit it.
- **Worked:** red without load: a `doc` event (`herdr-app`) whose `doc.get`
  the fake holds (`.none`, then `answer`) parks the pump while the next
  event is credited. The old gate failed 10 of 10 with `working`; waiting
  for `sessionSnapshot()` to show `working` passed, and the suite passed
  100 iterations.
- **Watch out:** `#expect(try await …)` printed `<not evaluated>` (a
  Known trap): print the value in the throwaway red to see what arrived.
