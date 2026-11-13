# Review Prompt

Status: Implemented. `Sources/Waycar/Review/`, the ask in `ContentView`, the About row and admin rows in Settings.

Waycar occasionally asks Apple's system rating prompt to appear, after real use, and links to the App Store review page from Settings › About. That is all it does.

## No incentive, ever

Rewarding a review is forbidden and impossible, and the code is built so it cannot creep in:

- **Forbidden.** App Review Guideline 3 (introduction): "If we find that you have attempted to manipulate reviews, inflate your chart rankings with paid, incentivized, filtered, or fake feedback … we will take steps to preserve the integrity of the App Store, which may include expelling you from the Apple Developer Program." Guideline 5.6.1: "Use the provided API to prompt users to review your app … and we will disallow custom review prompts." ([App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), checked 2026-10-15.)
- **Impossible.** StoreKit never says whether a review was written, or whether the system sheet even appeared. There is nothing to reward, and nothing to condition on.
- **So:** the prompt is tied to nothing that could be given as a reward (Waycar is free, ADR 0032), and no copy anywhere mentions rewards, bonuses or "in exchange". It is also not a sentiment gate: no "Do you like Waycar?" pre-prompt, no custom dialog, no routing of unhappy users away. Apple's `requestReview` sheet is the only prompt (Guideline 5.6.1).

## When it may ask

`ReviewPromptPolicy` (pure, injected `now`) is eligible only when all of these hold. The numbers are named constants in that one file. The counters gate every ask, not just the first: asking resets the value-event count, the distinct days and the first-event date, so the next ask needs fresh use after the last one.

| Rule | Constant | Value |
| --- | --- | --- |
| Value events since the last ask | `minimumValueEvents` | 15 |
| On distinct calendar days | `minimumDistinctDays` | 3 |
| Days since the first value event after the last ask | `minimumDaysSinceFirstEvent` | 7 |
| Not yet asked for this marketing version | | |
| Days since the last ask | `minimumDaysBetweenPrompts` | 120 |
| Not blocked: no Blocked Agent, no sheet or error showing, CarPlay not connected | | |

A **value event** is a successful phone-side action that shows real use:

- a successful New Agent launch from the sheet (`StartAgentStore.submit`, never for an Agent that was already running or a plain shell);
- a closed-Agent Resume (`ClosedSessionResumer`, once it started);
- a Composer message the Host accepted for an Agent (`AgentComposerStore.markDelivered`, wired by `ConsoleStore`; a Shell's Composer is not counted);
- a message the Host accepted through the shared `AgentActionService` (`recordDelivery`): the Apple Watch's send and its notification Reply action (`WatchBridge.sendNotificationReply`), and CarPlay's spoken question (`AgentVoiceService.send`) and Deny-and-instruct correction. One event per delivery; a refused, kept-as-draft or unconfirmed message, a Blocked Agent's and a Shell's never count. The service watches the Agent's status after the send and notes its finished turn (the watch ends when the Agent leaves the list or after `AgentActionService.turnWatchWindow`, a 4-hour cap that only bounds a stuck watcher, since these turns can run longer than `positiveMomentWindow`) (`TurnTracker`, the Composer's Done rule), so these users can be asked too.

Failed actions never count. Typing into the terminal (Direct Input), an Agent typed into a Shell and New Terminal never count either.

## Where it asks

When an Agent the phone prompted reaches Done (`AgentComposerStore` sees the message's turn finish, or, for a message sent through `AgentActionService`, its status watch does), `ReviewPromptStore` notes it. `ContentView` only supplies state (scene phase, the Agent on screen, blockers) and calls `ReviewPromptStore.askIfDue`, which waits `positiveMomentSettle` (2 s), re-checks, and asks only if the user is on the Console or on that Agent's screen, the window is in front and nothing is in the way, and the turn finished within `positiveMomentWindow` (10 min). While only a blocker is in the way, `askIfDue` re-checks every `positiveMomentRetryInterval` (2 s) until it clears or the window ends, then asks once: a sheet UIKit presents (Settings) closing is not an event SwiftUI observes, so the ask cannot rely on a re-run. The task's cancellation (route change, scene change, blocker change) stops the polling. Before deciding, `askIfDue` calls `normalizeClock()` (a clock set back clamps the last ask to now); `shouldPrompt` itself never mutates, so a view body may read it. Window-wide blockers are `isFreeForNotificationAsk` and CarPlay connected. A Standing Failure, Host sync error or Blocked Agent blocks only when it is the finished turn's own Host or Agent (`isBlocked`): an unrelated offline Host or forgotten Blocked Agent never suppresses the ask. A route change (returning to the Console), a foreground return or a blocker clearing tries again. The store calls `didPrompt()` as it requests: Apple may silently not show the sheet and caps it at three a year ([Requesting App Store reviews](https://developer.apple.com/documentation/storekit/requesting-app-store-reviews)), which is fine.

## State

`ReviewPromptStore` is `@MainActor @Observable`, UserDefaults-backed (one JSON value), with injected defaults and clock. Local to the device: no analytics event, no network, no Keychain, no iCloud. The unit-test host, previews and demo screenshots are suppressed (`isSuppressedInThisProcess`); the demo composition installs no store, so it never records or asks.

## Settings

- About › **Rate Waycar** opens `AppStoreListing.writeReviewURL` (`https://apps.apple.com/app/id6815881853?action=write-review`, the listing id from `apps/web/src/data/links.ts`). A plain link, no reward language.
- Settings › **Admin** (Debug and TestFlight only, `AppEnvironment.allowsAdmin`; `AdminSettingsView`): read-only state (events, days, first event, last asked, eligible now), a value-event **Stepper** (raw count only), **Reset Counter**, **Reset 120-Day Gap**, **Make Eligible Now** and **Reset Review Prompt** (everything).

## Trying it

In development builds (Debug) StoreKit is expected, per Apple's documentation, to display the rating sheet when `requestReview()` is called; under TestFlight it has no effect, and only the App Store build can show it, at Apple's discretion. The sheet has been seen on the iOS 27.0 simulator and has NOT yet been seen on a physical iPhone (iOS 27.0.1, Debug `devicectl` install); the cause is undetermined. Apple decides whether to present it, so **Settings › About › Rate Waycar** is the reliable path. To exercise the ask, run a Debug simulator build (`make sim` target, per `AGENTS.md`), open Settings › Admin, tap **Make Eligible Now**, then send an Agent a message and wait for its turn to finish while on the Console or that Agent's screen. The sheet appears about 2 s later. Tap **Make Eligible Now** again to repeat it; **Reset Review Prompt** returns to a fresh install and will not ask until the thresholds are met again. The ask is suppressed under XCTest, previews and demo screenshot mode.

On an iPhone: `make install NOTES=<file>` with a one-line notes file saying what to test (`NOTES=auto` would list unrelated commits) (a Debug build; the sheet is not guaranteed to show, and never does under TestFlight). Open Settings › Admin. The stepper raises or lowers the event count by one (floor 0) without inventing days or a first-event date; **Make Eligible Now** fills all of it; **Reset Counter** zeroes the count, days and first event but keeps the 120-day gap and last-asked version; **Reset 120-Day Gap** clears the last ask but keeps the counters; **Reset Review Prompt** clears everything. Then send an Agent a message and let it finish while you are on the Console or on that Agent.

If no sheet appears, first check iPhone Settings › App Store › In-App Ratings & Reviews (if off, the system suppresses every request). Then tap **Request Review Sheet in 5 s** in the same section, dismiss Settings and stay on the Console. After 5 s the store calls the root window's own `requestReview` closure (the one the production ask uses, registered by `ContentView`), not one from the Settings sheet, so a sheet or keyboard in the way cannot explain a miss. It bypasses eligibility and never touches the counters or `didPrompt()`; if no window has registered the closure, it does nothing and a caption says so. If the sheet appears but the ask doesn't, the system is declining only at the ask's moment (e.g. keyboard up after a Composer send); if nothing appears with In-App Ratings & Reviews on, the device is declining.
