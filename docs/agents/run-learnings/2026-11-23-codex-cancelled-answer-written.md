# 2026-11-23 — Codex flake: a cancelled approval answer was still written

- **Broke:** the flake hunt failed
  `cancelledQueuedApprovalKeepsTheRequestAndTheWriteQueueAlive` once in 16
  passes (quiet job, pass 4): the cancelled answer went out and the request
  was gone. A real race in `CodexWebSocket`: each frame's write `Task` did not
  use `self`, so it ran on the global pool and could pass its cancellation
  check before `write` installed the sender's cancellation handler. It bit
  when the test's blocked ping finished before the answer reached the queue.
  Users could not hit it: the app never cancels an answer task.
- **Worked:** red in one step with a loop, not a gate: 1000 sends from tasks
  that cancel themselves first (`withUnsafeCurrentTask { $0?.cancel() }`, no
  polling) leaked frames on the Mac (a throwaway run under thread
  oversubscription, 103 of 20,000). With the turn on the socket's actor: none.
- **Watch out:** a `Task {}` in an actor method runs on the actor only when its
  closure uses `self`. When the order against the caller's actor matters (a
  cancellation handler, a flag set right after), call an actor method from
  the task instead of relying on the closure's captures.
- **Watch out:** the MBP's shared iPhone 17 Pro Max set was missing, so
  `test-app` with the default `SIM` failed at the destination; `SIM='iPhone 17'`
  through `mac_run` ran it.
