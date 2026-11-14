# 2026-11-14 — CarPlay: varied ask lines after an Agent introduction

- **Worked:** a pure picker over an injected `RandomNumberGenerator`
  (`CarVoiceScript.askLine(after:using:)`, the `GeneratedWorktreeBranch`
  pattern), with the "never twice in a row" state on the long-lived
  `AgentVoiceService`, so tests need no sleeps or globals. New spoken lines
  went to Mike as one multi-choice card before submit.
- **Broke:** a constant-0 test generator hangs `Int.random(in: 0..<n, using:)`
  whenever `n` doesn't divide 2^64 (any non-power of two): Lemire's rejection
  sampling in `next(upperBound:)` rejects a 0 draw forever. A constant 1
  always draws index 0. `ConstantRandomNumberGenerator(value: 0)` was fine in
  `GeneratedWorktreeBranchTests` only because its ranges are powers of two.
  The reviewer caught it before the Mac run.
- **Watch out:** spoken car lines must never be yes/no questions: "yes" goes
  out as the question and "no" is a conversation exit
  (`AgentVoiceService.isConversationExit`). The marketing site
  (`apps/web/src/pages/carplay.astro`, the car article) quotes app lines
  verbatim; keep an old line in a pool so those quotes stay true.
