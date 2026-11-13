# 2026-11-13 — Open-source go-day: the first public commits

- **Worked:** the repository's own CI, run once on GitHub-hosted runners
  before the posts, found what the self-hosted runners had hidden; every
  failure was fixed by a small commit on `main`, not by skipping the check.
- **Broke:** `cargo test` in `plugin/` aborts on any machine with tmux on
  `PATH` and no `WAYCAR_TEST_TMUX` (hosted Ubuntu has tmux): `real_tmux.rs`
  links its scratch `bin/tmux` to the bare name `tmux`, a link to itself,
  so every real-tmux test dies with `ELOOP`. The workflows that run it now
  name the binary; the test helper itself is fixed in plugin 2.6.1.
- **Broke:** Codex 0.169.0 made the pinned 0.167.1 TUI open on an "Update
  available" menu, so the contract's `tui_joins` scenario never saw the
  reply. Scratch Codex configs set `check_for_update_on_startup = false`.
- **Watch out:** on GitHub Free, rulesets, fork-PR approval, secret scanning
  and push protection can only be turned on once a repository is public.
  Set them in the same minute as the visibility change.
