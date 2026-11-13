---
title: Agent Progress
description: A thin bar on each Working agent's card that shows how far along it is, from the agent's own plan steps or the phase of its work.
category: console
order: 95
keywords: [progress bar, plan steps, phase, estimate, exploring, building, verifying, wrapping up, rail]
related: [ai-summaries, agent-footer, live-activities, carplay]
---

Agent Progress draws a thin bar along the bottom edge of a Working agent's card in the Console, filling from left to right. Its label sits next to the summary's age, such as `3/7 · 1m`. It tells you roughly how far along the agent is. It never shows a percentage or a time left.

## What does the bar show?

The bar uses the best estimate the Host has:

1. **Plan steps**, such as **3/7**, when the agent wrote a step list in its current turn. The count is steps done out of all steps.
2. Otherwise a **phase**: **Exploring**, **Building**, **Verifying**, or **Wrapping up**. Within a turn the phase only moves forward.

| What you see | What it means |
| --- | --- |
| A filled bar | Working, with an estimate. |
| A dotted line with no fill | Working, but no estimate yet. |
| A blue bar that doesn't move | Blocked. The bar keeps the last estimate from before the agent stopped. |
| A dim bar | The estimate is out of date: it was made in another status, or is more than three minutes old. |
| No bar | Done, Idle, a shell, or an agent with no estimate. |

Agents are not re-sorted by progress.

## What does it need?

- **AI Summaries** turned on. See [AI Summaries](/help/ai-summaries).
- Waycar plugin 1.4.0 or later on your Host. If a Host has an older plugin, its agents' cards show **Update plugin for progress** instead of a bar. Tap it to update the plugin from the app. See [Update Waycar on your Host](/help/update-host-tools).

While Waycar is open, the estimate refreshes with the summaries, about once a minute.

## Which agents show plan steps?

The Host reads plan steps from the agent's own session file on the Host. Nothing is sent to a model for them.

| Agent | Plan steps |
| --- | --- |
| omp | Yes |
| Codex | Yes |
| opencode | Yes |
| Claude Code | Yes |
| pi | Yes |
| gemini | No, phase only |

A plan from an earlier turn never counts. A plan with more than 99 steps shows a phase instead.

## Where else does it show?

- **Agent screen**: while the agent is Working, the status line above the Toolbar reads "Working · 3/7" with a short bar beside it, or a dotted bar until there's an estimate.
- **Agent Footer**: the **Progress** field prints the label, such as **3/7** or **Verifying**, while the estimate is current. See [The Agent Footer](/help/agent-footer).
- **CarPlay**: a ring around the status symbol, and the label in the detail text, such as "Working · 3/7 · 6m". See [CarPlay](/help/carplay).
- **Lock Screen and Dynamic Island**: a bar under each Working or Blocked agent's row. See [Live Activities](/help/live-activities).
- **Apple Watch Smart Stack and CarPlay Dashboard**: the top agents, each with its label and a small bar.
- **Apple Watch app**: the same bar under each Working or Blocked agent's row and on its detail screen, with the label in the status line, such as "Working · 3/7 · 4m". See [Apple Watch](/help/apple-watch).

## What happens when your phone is locked?

With Waycar closed, your Host keeps the plan steps on the Live Activity current. About every two and a half minutes it reads the Working agents' plan steps again and sends any change. It makes no AI calls while Waycar is closed, so phases refresh only when Waycar or CarPlay is open.

## herdr and tmux

Agent Progress works on both Backends. On herdr the Host finds the agent's session file through herdr. On tmux it uses the session Waycar's hooks record for the pane. An agent with no session file found shows a phase only.
