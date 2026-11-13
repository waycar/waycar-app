# 2026-11-13 — Every Linux CI job on GitHub-hosted runners

- **Worked:** moving the last self-hosted Linux jobs to `ubuntu-latest`, then
  one `workflow_dispatch` each to show them green before relying on the
  schedule.
- **Broke:** pushing a shared checkout's `main` also pushed another run's
  unpushed local commits. Check `git log origin/main..HEAD` first.
- **Watch out:** in a private repository every hosted job bills at least a
  whole minute against the free 2,000 a month. A 10-minute cron is about
  4,464 a month, hourly about 744: estimate the minutes before you pick a
  schedule.
