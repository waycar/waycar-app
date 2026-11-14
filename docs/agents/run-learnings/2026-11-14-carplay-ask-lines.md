# 2026-11-14 — CarPlay: varied ask lines after an Agent introduction

- **Worked:** a pure picker with an injected draw
  (`CarVoiceScript.askLine(after:randomIndex:)`) and the "never twice in a
  row" state on the long-lived `AgentVoiceService`, so tests need no sleeps or
  globals: `randomIndex: { $0.lowerBound }` pins the draw. New spoken lines
  went to Mike as one multi-choice card before submit.
- **Broke:** a stored `any RandomNumberGenerator` passed `&random` to a
  generic `inout` parameter does not compile ("type 'any
  RandomNumberGenerator' cannot conform", Xcode 27): Swift does not open an
  existential for `inout`. Inject a closure instead.
- **Broke:** a constant-0 test generator hangs `Int.random(in: 0..<n, using:)`
  whenever `n` doesn't divide 2^64 (any non-power of two): the rejection
  sampling in `next(upperBound:)` rejects a 0 draw forever. A constant 1
  always draws index 0. The reviewer caught it before the Mac run.
- **Watch out:** spoken car lines must never be yes/no questions: "yes" goes
  out as the question and "no" is a conversation exit
  (`AgentVoiceService.isConversationExit`). The marketing site
  (`apps/web/src/pages/carplay.astro`, the car article) quotes app lines
  verbatim; keep an old line in a pool so those quotes stay true.
