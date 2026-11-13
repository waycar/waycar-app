---
title: How we set up advisors for OMP
description: A quiet set of reviewer models for OMP, a terminal tool for coding agents. Two big ones speak at plan lock and before "done", two small ones watch for risk, and a fifth from a different family.
date: 2026-10-16
keywords: [omp, advisors, coding agents, reviewer models, watchdog, guardrails]
---

An advisor in OMP, a terminal tool for running coding agents, is a second model that watches your coding agent. It reads what the agent just did. It can look at the repo, read-only. When it has something worth saying, it sends a short note tagged `nit`, `concern` or `blocker`.

I have run advisors since my first day on OMP (version 18.11.2 at the time of writing). Here is the roster I run now, what I know about its cost, and where it fails.

## The rule: speak rarely

Every advisor shares one instruction:

> Be quiet by default. Speak only with a concrete, evidenced finding. One tight note beats many. Never repeat a delivered note. Never restate that things look fine.

My bet is that an advisor that comments every turn teaches the coding agent to skim past it. I have not tested that. I wrote the rule to avoid it.

A second shared instruction, added after a real miss: files can be newer than the transcript an advisor reviews. So before an advisor asserts a file is stale, it must check the file's state against the tool output in the transcript. That rule exists because a correctly applied change once got flagged as a no-op. A false blocker is worse than no note.

The "few moments" idea came from [a post on X by @thedelost](https://x.com/thedelost/status/2110109013652193621). As I read it, one model runs the session, a small model explores, and a large model advises at three points: before a plan locks, when the same error shows up twice, and before the work is called done. I pasted it into OMP and asked it to build something like that. The first version came out of that one session.

## Organize by when, not by topic

OMP's docs show topic advisors, such as one for architecture and one for fixes. I ran that pair for three months. Then I asked a different question: when does each advisor speak, and what does that cost?

| Advisor | Speaks | Model | Tools |
|---|---|---|---|
| Planner | When a plan locks. When the same error repeats. | Large | read, grep, glob |
| Finish Gate | Once, before "done". Blocks the coding agent until it has looked. | Large | read, grep, glob |
| Sentinel | Every turn. Destructive commands, leaked secrets, writes outside the project. | Small | none |
| Scope | Every second turn. Drift, unrequested refactors, skipped steps. | Small | none |

This week I added a fifth advisor, Cross-check. It runs GLM through OpenRouter. Every other advisor is Anthropic, and reviewers from the same family tend to share blind spots. A different family gives uncorrelated errors. It is working on both my machines.

Three settings do the work:

- `reviewMode: turn` runs after each round of tool calls. `agent-end` runs once, when the coding agent tries to finish.
- `reviewInterval: 2` skips every other turn.
- `syncBacklog: strict` on an `agent-end` advisor means the coding agent cannot finish until the review is done. Only the Finish Gate uses it.

The two small models have `tools: []`. They never open a file. They read the transcript and judge it. That should keep them fast and cheap, and means they cannot change anything.

One honest detail. The Planner acts at "two moments," but `reviewMode: turn` calls it every turn. The silence comes from the prompt, not from a trigger. You pay for the look even when the answer is nothing.

## Only a blocker can steer a live turn

This is the part I got wrong for months, and it changed how every advisor is tuned.

While the primary agent is streaming a turn, only a note tagged `blocker` can steer that turn. A `concern` or a `nit` waits for the turn boundary. And a turn-mode `concern` that arrives at the boundary only becomes a visible card after the agent gives a terminal answer. In other words: by the time a non-blocker is seen, the work it warns about is already done.

That single fact explains two tuning choices.

The Planner now raises a `blocker` when the plan is wrong, or when it breaks a user or AGENTS.md constraint. A concern at plan lock would arrive after the plan is locked and being followed. Too late.

The same reasoning moved the Sentinel's writes-outside-the-project rule up to `blocker`. If that note went out as a concern, the write would be finished before anyone read it.

## A generic WATCHDOG.yml

Replace the placeholders with models you can use. The commented line in the Sentinel is an example house rule. Write your own.

```yaml
instructions: |
  You are a reviewer for a <primary model> primary agent. Be quiet by default.
  Speak only with a concrete, evidenced finding. One tight note beats many.
  Use `nit` for cleanup, `concern` for material risk, `blocker` only when
  continuing would waste work or break things. Never repeat a delivered note.
  Never restate that things look fine.

advisors:
  - name: Planner
    model: <large model>
    reviewMode: turn
    syncBacklog: "off"
    tools: [read, grep, glob]
    instructions: |
      Act ONLY at two moments; otherwise stay silent.
      1. A plan is about to lock (plan proposal, todo list init, or the
         first edit after exploration). Check for wrong direction, missing
         user or AGENTS.md constraints, public-API growth, scope creep.
         Raise wrong direction or a broken user or AGENTS.md constraint
         as a blocker: mid-run, only a blocker can steer the live turn.
      2. The same error or failing approach appears a second time. Say why
         a retry fails again. Name a root-cause hypothesis.

  - name: Finish Gate
    model: <large model>
    reviewMode: agent-end
    syncBacklog: strict
    tools: [read, grep, glob]
    instructions: |
      Review the whole run just before the agent says it is done. Verify
      against the transcript and the workspace, not the agent's claims:
      requests addressed, changes exercised and not only compiled, no
      stubs, callers migrated, docs updated, no leftover dev servers.
      Silent if fine. A failed check is a `concern`. A false "done" is
      a `blocker`.

  - name: Sentinel
    model: <small model>
    reviewMode: turn
    syncBacklog: "off"
    tools: []
    instructions: |
      Classify every tool call and result. Flag only:
      - secrets printed, logged, committed or sent anywhere
      - writes outside the project. Raise this as a blocker: a concern
        would arrive after the write is done.
      # destructive commands are handled by bash.patterns, not advice
      # example house rule: edits in the main checkout, not a worktree
      Anything else: silent.

  - name: Scope
    model: <small model>
    reviewMode: turn
    reviewInterval: 2
    syncBacklog: "off"
    tools: []
    instructions: |
      Flag scope drift, unrequested features, asking the user for facts a
      tool could fetch, and skipped required steps. Otherwise silent.

  - name: Cross-check
    model: <other-vendor model>
    reviewMode: turn
    syncBacklog: "off"
    tools: [read, grep, glob]
    instructions: |
      You are the only advisor from a different model family. Read the
      transcript and look for what the same-family reviewers would miss.
      Otherwise silent.
```

Keep tools read-only. Back the file up before you edit it. Changes apply only to new OMP sessions.

## Where the files live, and how they merge

OMP loads two files together: `~/.omp/agent/WATCHDOG.yml` for you, and `<repo>/WATCHDOG.yml` (or `.omp/WATCHDOG.yml`) for a project.

The merge rule: if both define an advisor with the same name, the more specific file wins, so project beats user. Different names are combined into one roster. Top-level `instructions` from every file are joined.

That is how one repo can switch off an advisor the rest of my machine uses: a project entry with `name: default` and `enabled: false`.

It also bit me. Twice my advisors seemed to vanish from `/advisor configure`. The editor opened on project scope, and a project file in a scratch folder hid my user roster from that view. Run `/advisor status` in a fresh session to see what is really live.

## Some rules do not belong in advice

An advisor reviews a command only after it runs. Advice after the fact is no place for `rm -rf`. So I moved my destructive-command guardrails out of advisor prompts and into `bash.patterns` enforcement in the OMP config. Twelve rules:

- Deny only `rm -rf /`-class roots, and `rm -rf ~` itself.
- Prompt on `rm -rf` with an absolute path or the home directory, on force-push variants (`--force`, `-f`, a `+` refspec), and on `git reset --hard`.

I verified it with a temporary canary deny rule, a force push that got blocked, and an ordinary push that went through untouched.

One known gap: the eval tool bypasses `bash.patterns`. Closing it would break every subagent eval, so for now it stays open.

## What they caught

Some numbers first. In the first three days of the four-advisor roster (25 sessions), the advisors sent 1,253 notes. Cross-check joined this week, so these counts predate it. About 10 percent were blockers (124): 82 from the Sentinel, 21 from Scope, 14 from the Planner, 7 from the Finish Gate. About 133 of the Sentinel's 522 notes were tagged as being about "done," "verified" or "green" claims. These counts are `advise()` calls, meaning notes sent, not advisor runs. They are one person's anecdotes, not a benchmark.

Three catches I keep thinking about.

**Day one: the coding agent argued with its own AGENTS.md.** My AGENTS.md says the main coding agent must delegate file edits. The agent called the change trivial and started editing. An advisor sent a blocker citing the file. The agent replied that it had misread its own AGENTS.md.

**"Verified end-to-end" was not.** A coding agent set up a home network rule and called it verified. An advisor wrote that "verified end-to-end" overstated it. The agent had shown the rule existed and the local path worked, not that traffic from a real public address got through. Later the advisor noted the connection sat behind carrier-grade NAT, so the inbound rule could never have worked.

**A live ad account.** A coding agent created two campaigns in a live ad account without reading the keyword match type. Advisors sent four concerns and two blockers. The agent went ahead anyway. On another day, a Scope blocker stopped a command that would have changed a live pricing setting for every new customer. Only "recreate from scratch" had been approved.

## What it costs

Each advisor is its own model session. In my sessions that meant two to five extra model calls per turn, depending on the roster.

Here is the cost, notional, at API list price, over about two and a half days across 29 sessions: the Planner ran $219, about $0.16 per turn. The Finish Gate ran $173, about $0.30 per run. The two small Haiku advisors together cost about $7. The two retired topic advisors had spent $2.9k all time when I paused them. Another advisor, one with a single narrow trigger that ended up firing on everything, cost about $88 per two and a half days at list price before I dropped it. Its own log put it plainly: "My advice was wrong."

I keep the large advisors on the highest quality tier on purpose. This setup buys review quality, not cheap tokens.

Latency is the other bill. The Finish Gate holds the coding agent at the end by design. In Waycar's own code we turn advisors off for the one-sentence summary calls: with them on, a call of about 1.5 seconds took 12 to 30 seconds.

## Where it breaks

- **Advice is not a gate.** A blocker is a message, not a veto. The coding agent sometimes ignored two or three in a row. For money or live accounts, keep a hard rule outside the model. That is why my destructive-command rules live in `bash.patterns` now, not in advisor prompts.
- **False positives and stale notes.** Once I told the coding agent flatly that an advisory was wrong. The agent also spends thinking time rebutting notes about a turn that is already over.
- **Edit and shell grants.** My old Fixer advisor could edit and run commands. My July note says advisor tool grants bypass the approval mode. The current OMP docs say they honor it. I have not re-checked, so treat it as unverified, and grant read-only tools.
- **Not portable.** Advisors, `WATCHDOG.yml` and `/advisor` are OMP features. The pattern travels. The file does not.

## What to try

1. Start with two advisors: a Finish Gate and a Planner, both with `read`, `grep` and `glob` only.
2. Put the shared "be quiet" instruction at the top.
3. Add a no-tools Sentinel only once you can name two things it should flag.
4. In a new session, run `omp -p --advisor "Reply with exactly: ok"` as a smoke test, then check `/advisor status`.
5. After a week, read the notes with `/advisor dump`. Delete any advisor whose notes you skipped.

A starter skill that writes this file for you is a possible next step. It is not built or published. For now, copy the YAML above.

## Why this matters for Waycar

Advisors run unattended, often on a Host you are not sitting at. An advisor blocker is advice, and the Agent keeps working. A Blocked Agent in the Waycar Console is different: it is waiting for you. We have not built anything that shows advisor notes. The Console is where you notice which Agent is stuck.
