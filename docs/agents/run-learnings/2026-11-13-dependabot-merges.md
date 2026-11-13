# 2026-11-13 — Merging the first Dependabot PRs (plugin 2.6.2)

- **Worked:** `gh pr merge <n> --squash --match-head-commit <full sha>`, one
  PR at a time, oldest first; Dependabot rebases the next PR on its own when a
  merge leaves it behind, so wait for the new head's checks.
- **Broke:** the cargo group PR failed "Pairing plugin (Rust)" only at the
  last step, `plugin-licenses.py --check`: Dependabot changes `Cargo.lock` but
  never regenerates `plugin/THIRD-PARTY-LICENSES` or bumps the plugin version.
- **Watch out:** `--match-head-commit` needs the full 40-character sha. A cargo
  update lands as its own branch: cherry-pick Dependabot's commit, bump the
  plugin patch version, run `python3 scripts/plugin-licenses.py`, then the
  Before submit plugin checks. `fancy-regex` is used only by two hook tests,
  never by the shipped binary.
