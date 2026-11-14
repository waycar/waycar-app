# 2026-11-14 — CI's package lane on the Mac, and one CI report per commit

- **Worked:** `make test-ci-package` reuses `scripts/run-ci-ios-tests.sh`
  as is (`WAYCAR_CI_LANE=package`), so the Mac runs CI's exact fixtures,
  `Waycar CI` claim and pinned count; a `mac_run` session step with
  `background: true` ran it while the branch went on.
- **Worked:** `scripts/ci/ci-evidence.py` read every lane of a 15 MB iOS job
  log in seconds; one call replaces a loop of `gh run view` polls.
- **Broke:** `gh api …/actions/jobs/<id>/logs` printed nothing on gh 2.103:
  it refuses a body with terminal escapes unless `--allow-escape-sequences`.
- **Watch out:** a green lane never printed the count it was held to, so
  `run_suite` and the package lane now print
  `==> <lane>: ran all N pinned tests, S skipped (A allowed)`; keep that line
  and `ci-evidence.py`'s `PINNED` pattern in step
  (`scripts/test-ci-evidence.py` runs the shipped echo).
