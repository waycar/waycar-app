# Run learnings

What runs learned, one file per run, for the
[engineering workflow](../engineering-workflow.md#each-run-makes-the-skill-better):
what worked, what broke, and what a future run would otherwise rediscover.
One file each, so branches that land in parallel never edit the same lines.

## Adding an entry

Add `<YYYY-MM-DD>-<slug>.md` to this folder in the same branch or PR as the
run's work. The date is the day the run ends; the slug names the run in a few
words, with its issue number when it has one (`2026-11-12-ipad-test-run`,
`2026-11-14-mosh-stall-400`). Keep it short:

```markdown
# 2026-11-12 — What the run did

- **Worked:** what to do again, one line each.
- **Broke:** what failed and why, one line each.
- **Watch out:** a command, gate or convention a future run would
  otherwise rediscover.
```

Leave other runs' entries alone, except to fold or prune them.

## Folding and pruning

- When a lesson shows up a second time, fold it into the rules it belongs to
  (the [engineering workflow](../engineering-workflow.md) and its
  [Before submit](../engineering-workflow.md#before-submit) checklist, the
  [Mac workflow](../mac-workflow.md), `AGENTS.md`) and delete the entries
  that carried it.
- Keep at most 20 entries. When yours makes 21, fold what is still worth
  keeping from the oldest entries into those rules and delete them, in the
  same branch.

## Reading the log

This folder is the index. File names sort by date, so
`ls -r docs/agents/run-learnings/2*.md` lists the entries newest first.
There is no hand-kept list: every branch would edit it, and parallel
branches would conflict there again.
