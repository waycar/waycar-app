# 2026-11-18 — Codex Stop test: the interrupt beat Codex storing the prompt

- **Broke:** `CodexTransportE2ETests.stopInterrupts` failed once on hosted CI
  (461215f): the interrupted turn had no user message. The test stopped as
  soon as Working showed. Codex announces the turn 7–20 ms before it stores
  the prompt, and an interrupt in that gap drops the prompt for good (X26).
  A test bug: a tapped Stop comes long after that gap. First failure in the
  last 28 red hosted runs.
- **Worked:** the lane's `codex-model.log` showed no `WAYCAR_SLOW` request,
  so the turn died before it reached the model. Then a throwaway Python
  probe built on `codex-contract.py`'s `Scratch` and `WebSocket` classes
  reproduced it on Linux in seconds: interrupt on `turn/started` lost the
  prompt 13 of 30 times, after the prompt showed 0 of 30. A shallow sparse
  clone of `openai/codex` at the pinned tag found the cause in
  `core/src/session/turn.rs`.
- **Watch out:** the flake hunt's app lane runs without the real-SSH
  fixtures: every fixture suite (shared sshd, tmux, Core, Codex, OpenCode)
  skips there, so it cannot catch a race like this one.
