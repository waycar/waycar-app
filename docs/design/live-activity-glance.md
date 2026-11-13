# Live Activity glance redesign

Status: Implemented
Date: 2026-09-28
Scope: widget UI in `Sources/WaycarWidgets/AgentLiveActivityWidget.swift` and the Lock Screen row budget in `Sources/WaycarWidgets/AgentActivityDecryptor.swift`. The wire contract, envelope order, pins, eligibility, deep links, stale and counts-only semantics, `AgentStatusPalette`, and the `AgentActivitySurface` seam (Lock Screen dynamic Latte/Mocha, island always Mocha) are unchanged (ADR 0014, `docs/agents/live-activity-contract.md`, `docs/design/issue-247-live-activity-redesign.md`).

## Problem

The per-Host Live Activity could not be read at a glance, so it was tapped as an app shortcut rather than read:

- Every Agent took three lines of 11–12 pt caption text (workspace · tab / Agent kind / directory).
- Status was a 7 pt colored dot, the only status cue on the row.
- Count chips shared the first row with the first Agent, crowding and truncating it.
- The compact Dynamic Island was a bare "1 … 4": a number in a pill and a total, with no status meaning.

Apple's guidance asks the opposite: "Use large, heavier-weight text… make sure key information is legible at a glance"; compact leading and trailing should "read as a single piece of information"; the Lock Screen should "use a layout similar to the expanded presentation".

## Principles

- Answer "does anything need me?" in half a second: the most urgent status, its count, and its color come first.
- Speak the Console's visual language: a kind monogram, the configured identity, the status in words.
- One line per Agent. Identity truncates; status never does.
- Status is carried by symbol, word, and color together, never color alone.
- Lock Screen and expanded island share one anatomy, so either teaches the other.

## Anatomy

**Status vocabulary** (one helper, `AgentActivityStatusVocabulary`): blocked `hand.raised.fill` "Blocked", done `checkmark.circle.fill` "Done", working `progress.indicator` "Working", idle `moon.zzz.fill` "Idle"; any other wire status `circle.fill` and its raw value capitalized, in the palette's unknown (red) role, as in the Console. Colors come only from `AgentActivityStatusStyle.ink/wash(for:on:)`.

**Status header.** The lead is the first non-zero count in attention order (blocked > done > working): symbol + "1 Blocked" in `.headline`, lead ink. The other non-zero counts sit trailing as symbol + number in `.subheadline` semibold, each in its ink, idle last; they never compress. On the Lock Screen VoiceOver reads the whole header as one element: "1 blocked, 1 done, 2 working, 2 idle". The island reads the lead and the other counts as its leading and trailing elements.

**Agent row.** `monogram · row 1 · row 2 · Spacer · status word`, at least 28 pt tall:

- Monogram: 24 pt circle in the status wash (18% Lock Screen, 28% island) with the Console's monogram (`AgentNotificationIdentity.monogram(forKind:)`: the raw kind's first character uppercased) in the status ink.
- Configured row 1 as the headline (`.subheadline` semibold), row 2 as secondary text (`.subheadline`, secondary color, truncates first). Rows 3+ are not drawn. Field color, bold, and dim styles still apply. Legacy producers without `rows` show workspace / kind; an explicitly empty layout shows the kind.
- Status word in the status ink, never truncated.
- Each row is a `Link` to that Agent; VoiceOver reads "waycar · live-activity, Claude, blocked".

**Lock Screen.** Header, rows, footer, 14 pt horizontal and 10 pt vertical padding on the system background. The footer is "+N more", "May be out of date", or both joined by " · ", in `.footnote` medium, starting at the rows' text column (after the monogram). Counts-only (the envelope could not be opened) shows the header alone, plus the stale footer when stale.

**Compact island.** Leading: the lead status symbol in its island ink. Trailing: the lead count in bold monospaced digits, same ink. VoiceOver reads "1 blocked" once, from the leading side.

**Minimal island.** The lead symbol and count together in caption bold.

**Expanded island.** Leading region: the header lead, one line, scaling down to 75% rather than moving below the TrueDepth camera (that would add height and clip the rows). Trailing region: the other non-idle counts (at most two), matching the compact and minimal totals, which exclude idle. Bottom region: in envelope order, all rows when the total is 3 or fewer, otherwise 2 rows and "+N more" (N = total − 2) so the footer fits the expanded height. Counts-only draws no rows. The key line takes the lead status ink, or the muted idle ink when nothing is actionable. The expanded island clips its content to rounded corners inset from its edge (seen on the iOS 27 simulator: the last trailing digit and the footer's "+" were cut), so the trailing counts keep 10 pt from the right, the bottom region 6 pt from its sides and bottom, and the footer starts at the text column.

**Dynamic Type.** The Lock Screen view and every island presentation cap Dynamic Type at `.large` (`.dynamicTypeSize(...DynamicTypeSize.large)`). The Lock Screen has a hard 160 pt limit with no slack at four rows, and the default size is already larger than the old caption text.

## Budget

ActivityKit caps the Lock Screen presentation at 160 pt. `AgentActivityLockScreenMetrics` holds the constants the view draws with, and `lockScreenAgents(isStale:)` shows the largest row count `n` (at most 4) such that
`10 × 2 + 22 (header) + 6 + 28 × n + (footer ? 6 + 16 : 0) ≤ 160`, where the footer appears when Agents remain or the activity is stale.

| Case | Rows | Footer | Estimate |
| --- | --- | --- | --- |
| fresh, 1–4 Agents | all | none | ≤ 160 pt |
| fresh, 5+ Agents | 3 | "+N more" | 154 pt |
| stale, 1–3 Agents | all | "May be out of date" | ≤ 154 pt |
| stale, 4+ Agents | 3 | "+N more · May be out of date" | 154 pt |
| counts-only | 0 | stale only | 42–64 pt |

`AgentActivityPresentationTests.bannersFitTheLockScreenHeightBudget` renders the real `AgentActivityLockScreenView` for 1–5 Agents, fresh and stale, Light and Dark, plus 80-grapheme identities, and 4 Agents at `.accessibility3`, at 360 pt wide. It asserts every banner stays within 160 pt and within 2 pt of the estimate above.

## Decisions

- **Header plus Console rows (variant A).** Chosen: the header gives the half-second answer; the rows say who, in the same language as the Console.
- **Rejected B, rows only with no header.** Loses the half-second answer, and the Lock Screen would no longer match the compact and expanded island, which lead with the status.
- **Rejected C, status-icon rows** (status symbol leading, identity, kind trailing). Diverges from the Console's monogram-and-status-word rows, so the two surfaces would teach different vocabularies.
- **Deferred D, an Agent Summary line under Blocked and Done rows.** It would need an additive `summary` field in the envelope from both producers and a plugin change: the activity hook pushes about 1.5 s after a status change, while the summary is written 5–15 s later, and nothing re-triggers the activity hook when it lands.
- **Blocked stays herdr blue, not red.** `AgentStatusPalette` owns the status colors across the app; the Live Activity keeps them.
- **The directory row is dropped** from the whole Live Activity (Lock Screen and Dynamic Island): each Agent shows its first two Agent List Fields rows, and the third (the directory by default) is not drawn. It was the least useful of the three lines and the one that pushed rows past a glance.
- **10 pt vertical padding, not the HIG's 14 pt.** The extra 8 pt would cost the fourth row inside 160 pt.

## Verification limit

The layout is verified with `ImageRenderer` in tests and on the iOS 27 simulator with a real ActivityKit activity (Lock Screen, compact, and expanded). A physical Lock Screen, Always-On display, and StandBy Night Mode were not exercised. On the iOS 27 simulator the Lock Screen banner renders dark in Light appearance; that is the ActivityKit appearance issue the #247 design already records, not this layout.
