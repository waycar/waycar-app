# 2026-11-14 — Shorter Agent cards: no rule, one-line summary

- **Worked:** one throwaway unit test mounting the real `ConsoleView` over
  `DemoScreenshotComposition` (`setHosts`, `resume`, then 4 s for the demo
  Agents), with a static knob in a throwaway commit switching the card
  between variants, rendered "before", A and B side by side in one
  `mac_run` step per device. The owner picked from one sheet instead of
  three rounds.
- **Worked:** the swipe-close buttons' accessibility frames gave each card's
  pitch per variant (164 → 148 → 127 pt) without measuring pixels.
- **Watch out:** `AgentCardChrome` pads every card in the Console and the
  Hosts sheet (Host, AI Usage, closed-session, queued-launch), so a padding
  change there changes them all. And the summary's loading skeleton has a
  fixed height: change it with the summary's font and line count, or the
  card jumps when the first summary arrives.
