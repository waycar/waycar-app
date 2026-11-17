# 2026-11-17 — 1.4.2 live: review-smoke baseline and site copy

- **Worked:** a `--filter=tree:0` bare clone of `waycar/waycar-app` proved
  in seconds that a fresh clone resolves the new `REVIEW_SMOKE_PREVIOUS` tag,
  with no Mac run.
- **Broke:** nothing, but the help gate lifting at `make publish` hid that
  nine ungated site files still said Zellij, Codex and OpenCode 2 come "in the
  next update" after 1.4.2, which ships them, went live.
- **Watch out:** after a release goes live, `grep -rni "next update"
  apps/web/src` (outside `content/changelog/`) and check `dist/index.md`
  after `npm run build`: `src/llms/index.md` repeats Setup's requirement
  list by hand. The handoff step in `docs/guides/releasing.md` now says so.
