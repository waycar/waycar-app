# 2026-11-14 — Attach and keyboard lifecycles as state machines

- **Worked:** rows an earlier pass deferred ("needs Mac execution") all
  converted once each owner pin ran on the Mac before the refactor; splitting
  eleven rows across two agents by file kept their branches conflict-free
  apart from the generated project file.
- **Broke:** a machine that clears a state its owner still mirrors changes
  behaviour without failing any pin (a replacement message jump stopped
  holding the transcript early). Review caught it; the regression pin only
  failed once it forced the exact interleaving inside the read itself.
- **Watch out:** when an owner keeps an observed mirror of machine state,
  check every transition where the machine clears it against the point the
  owner does; and a pin for a race must make the racing step happen inside
  the awaited call, not beside it.
