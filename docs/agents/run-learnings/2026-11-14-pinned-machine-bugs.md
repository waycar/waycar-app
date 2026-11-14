# 2026-11-14 — Pinned state-machine bugs B-39, B-42–B-45

- **Worked:** red-first in one Mac session: a throwaway commit (base plus
  the new tests only, built with a scratch `GIT_INDEX_FILE` and
  `git commit-tree`, never on the branch) failed exactly the new tests,
  then the same session ran the tip incrementally.
- **Worked:** an OpenCode 2 live check needs no Mac or testbox: this agent
  host has tmux and node, `opencode-contract.py --fetch` gives the pinned
  binary, and the harness-lab mock runs as a plain `node server.js`.
- **Watch out:** to make a main-actor race pin deterministic, release the
  awaited answer and ask for the competing step in the same main-actor job
  (`Task { gate.release(); await leave() }`): the released continuation is
  queued first. A gate whose `wait()` is nonisolated resumes off the main
  actor first, so the order is not fixed.
- **Watch out:** a restart Task that awaits a `@MainActor` closure resumes
  its caller without another hop, so a counter bumped at the closure's end
  proves the code right after the await has run: wait for that, not for a
  later release.
