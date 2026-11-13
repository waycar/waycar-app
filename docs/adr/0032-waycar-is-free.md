---
status: accepted
---

# Waycar is free: no subscription, no Launch metering

_2026-11-04, accepted. Supersedes ADR 0023._

## Context

The owner decided that Waycar 1.3.0 is free. There is no revenue model: every
feature is free for everyone, and nothing is metered. ADR 0023's design
(Waycar Pro on StoreKit 2, 10 Launches per rolling 30 days, the Welcome
Allowance, typed-Launch detection, the Keychain Launch ledger) has no job
left.

## Decision

- Waycar Pro is deleted: the StoreKit entitlement, the paywall, the locked-Agent
  card, Settings › Subscription, the StoreKit configuration file, and the
  `launch_limit_hit`, `welcome_started` and `welcome_ended` analytics events.
- Every launch simply starts: New Agent, New Chat, Default Shell, New
  Terminal, a closed-Agent Resume, a Queued Launch's replay, and an Agent typed
  into a Shell. Nothing counts or refuses them.
- The admin gate stays. `AppEnvironment.allowsAdmin` (a Debug or
  `WAYCAR_ADMIN` binary whose verified receipt is not from the production App
  Store, as ADR 0023 set it up) still guards the internal-only analytics
  events (ADR 0027) and Settings › Admin, which now holds only the Review
  Prompt controls. The app model runs the receipt check at launch and on each
  return to the foreground; the entitlement store used to.
- SKAdNetwork keeps its launch-time call with the lowest value: there is no
  subscriber conversion to report.

## Consequences

- The ledger's Keychain items (service `com.otreva.waycar.launches`: one
  synchronizable item per device and a device-only device id) are swept once
  per install at launch (`LaunchLedgerSweep`). Deleting the synchronizable
  items removes them from the user's other devices too. A device still on an
  older build can write its item again; the next device that updates sweeps
  it. ADR 0023's amendment to ADR 0019 (a second synchronizable service) ends
  with it.
- After the release, both Waycar Pro subscriptions are removed from sale in
  App Store Connect. The app no longer offers Manage Subscription or Restore
  Purchases; a subscriber manages the subscription in iOS Settings.
- The Review Prompt is unchanged apart from the paywall and lock blockers,
  which no longer exist.
