# 2026-11-21 — README attribution cleanup

- **Worked:** `rg -n -i --hidden "heeler|zingerlittlebee" apps/` before
  editing: the site (pages, help, `src/llms`) never mentions Heeler, so a
  README-only attribution change needs no site build.
- **Watch out:** attribution the license requires stays put: `NOTICE`,
  `docs/heeler-derived-files.md`, `plugin/NOTICE`/`LICENSE`, the app's
  Acknowledgements (`inventory.json`) and source-file headers. Drop only
  the story around it.
