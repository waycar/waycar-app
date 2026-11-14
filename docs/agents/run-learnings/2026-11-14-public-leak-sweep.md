# 2026-11-14 — Leak sweep of the public repositories

- **Worked:** scanning every blob reachable from any ref of a mirror clone
  (branches, tags, `refs/pull/*`), plus the commits the repository activity
  API lists as force-pushed away or on deleted branches, fetched by SHA:
  GitHub keeps serving them, and a tip-only scan never sees them.
- **Broke:** a leak guard that scans only the pushed tree let a path one
  commit added and the next removed reach public history. `scan.py --commits`
  checks what each unpublished commit adds and its message; text a later
  commit removes is still published by the commit that added it.
- **Watch out:** GitHub shows the edit history of issue and PR bodies and
  comments, so editing text out does not remove it. Actions logs and
  artifacts of a public repository are public; the `.xcresult` data files in
  the CI diagnostics artifacts are zstd-compressed, so a plain grep finds
  nothing in them.
- **Watch out:** every GET of `https://waycar.dev/install.sh` counts as an
  install; a script that reads it adds `?internal=1` (AGENTS.md › Analytics).
