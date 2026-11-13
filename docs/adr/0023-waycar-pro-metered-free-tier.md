---
status: superseded by ADR-0032
---

# Waycar Pro: metered free tier, on-device StoreKit, Keychain Launch ledger

Waycar is free with every feature, metered at 10 Launches per rolling 30
days. Waycar Pro, an auto-renewing subscription with a monthly plan
(`com.otreva.waycar.pro.monthly`, $5.00 a month) and an annual plan
(`com.otreva.waycar.pro.annual`, $40.00 a year), both in subscription group
"Waycar Pro", removes the limit. There is no trial or Family Sharing. The
monthly plan was added on 2026-09-28; see the amendment below.
Purchases and entitlement run on device through StoreKit 2: no server, no
receipt validation service, no third-party SDK. Launches are counted in a
synchronizable iCloud Keychain ledger that ignores the iCloud Sync switch.

This amends ADR 0019 (iCloud Sync through iCloud Keychain): Waycar now has a
second synchronizable Keychain service, `com.otreva.waycar.launches`, that
syncs whether or not iCloud Sync is on, and whose items merge by union
instead of by ADR 0019's per-item last-writer rules.

## Context

Waycar needs revenue without hiding features: a phone app that can't start an
Agent is not worth trying. The unit of value is starting work on a Host from
the phone, so that is what is metered. Everything that watches, steers or
answers an Agent that already exists stays free and unlimited.

A count kept only on one device resets with a reinstall or a second device,
and a count kept on a server needs an account. The user already has iCloud
Keychain for iCloud Sync, and Keychain items outlive the app.

## Decision

**Launch.** A Launch is one of:

- a phone-started New Agent, Default Shell or New Terminal
  (`StartAgentStore.submit()`, including launches from an Agent's own
  screen);
- a closed-Agent Resume (`ClosedSessionResumer`, through the same gate with
  origin `.resume`);
- a typed Launch: an Agent appearing on a Pane the phone typed into since that
  Pane's previous Agent ended.

Desk-started Agents are never counted. A launch that fails is not counted:
only the success branch records. Default Shell followed by typing `claude`
into it from the phone is two Launches, by definition.

**Allowance.** `LaunchAllowance` is a pure rule: limit 10, window 30 days,
`remaining`, `canLaunch`, and `nextSlotFreesAt` = oldest in-window Launch +
30 days. `LaunchGate` answers `canLaunch` (Pro, or the allowance has room).
At the limit the entry buttons open the paywall instead of the start sheet,
and `submit()` re-checks and moves to `.needsPro`. Purchasing resumes the
Launch. Existing Agents and Shells, Composer, Direct Input, Agent
Notifications and Live Activities keep working at the limit.

**Pro Launches are not recorded.** `record(origin:)` is a no-op while Pro, so
a user whose subscription lapses starts with 10 fresh Launches.

**Entitlement.** `ProEntitlementStore` reads `Transaction.currentEntitlements`
at launch, listens to `Transaction.updates` for the app's lifetime, and
finishes every verified transaction. Each refresh publishes StoreKit's
cached entitlement before the product and status calls, which need the
network, so a Pro user never reads as Free (and never records a Launch)
while they are slow or offline. Pro means a verified, unrevoked
entitlement exists, or the subscription status is `.inGracePeriod`. Billing
Grace Period is on (16 days) in App Store Connect, so a failed renewal keeps
Pro through the grace period; billing retry after grace means Free. Offline,
StoreKit's cached entitlement is trusted. A `.subscribed` status counts only
while its verified transaction's expiration date is in the future: StoreKit
can keep reporting `.subscribed` after the period ended, and then the cached
entitlement decides. There is no grandfathering.

**Admin panel.** Settings › Subscription › Admin offers an override (Real
store / Force Pro / Force Free), Launch reset and max-out, and a clock
offset. Force Pro unlocks the paid feature without a purchase, so the panel
must never reach the App Store.
`AppEnvironment.allowsAdmin` requires two things. First, a compile-time
flag: the binary is a Debug build, or was compiled with the `WAYCAR_ADMIN`
Swift condition, which only interim TestFlight archives set (`make
testflight` and the CI TestFlight workflow, through `ADMIN_BUILD=1`).
`make publish` archives without it, and only that build is submitted for
review. Second, for a release admin build, a verified `AppTransaction`
whose environment is not production. The
override and the clock offset are stored in UserDefaults but applied only
while admin is allowed, so a tester's settings do nothing once an App Store
build replaces the TestFlight one. TestFlight uses the real sandbox store.

**Launch ledger.** `LaunchLedger` stores records `{id, at, deviceID, origin}`
as a JSON array in one generic-password item per device, `launches.<deviceID>`,
under service `com.otreva.waycar.launches`, `kSecAttrSynchronizable = true`,
`AfterFirstUnlock`. The device ID is a UUID kept in a `ThisDeviceOnly` item,
created once. Each device writes only its own item, pruned to the last 30
days (plus clock slack) on every write, so devices never write the same item
and there is nothing to conflict. Reading takes the union of every
`launches.*` item, de-duplicated by record `id`. This is the merge rule.
Records decode one by one: a record this build cannot read is dropped and
logged without losing the rest of its item, and an origin a later build adds
still counts and round-trips unchanged. An item that is not a JSON array is
skipped, and replaced only if it is this device's own.

Keychain failures fail open, by choice: a failed read keeps the last good
reading (empty at launch, so the full allowance), and a failed write or
device-ID read records nothing. Each is logged. Blocking every Launch on a
Keychain error would punish the user for the platform.

The ledger is always synchronizable and never goes through the
`com.otreva.waycar.sync` path, so turning iCloud Sync off neither stops it
syncing nor copies it to this-device-only items. It holds only timestamps,
origins and random IDs: no Host, Agent or command.

**Typed Launch detection.** `TypedLaunchDetector` watches Pane transitions,
not command text, using the rule measured against herdr 0.9.1 (recorded in
`AGENTS.md`):

- A new Agent on Pane P is (a) `pane.agent_detected` without `released`, or a
  snapshot or `agent.list` fold that shows an Agent on P after P showed none,
  or (b) P's `agent_session.value` changing from one non-nil value to a
  different one (omp's no-gap retype). `name`, `terminal_id`, `pane_id` and
  `launch_pending` are not identity.
- It is a typed Launch if and only if Waycar sent input to P (Composer
  `send_input`, `send_text`, Direct Input or attached-terminal keystrokes)
  after the previous Agent's last `idle`/`done` transition, or, where P read
  as a Shell, after the `released` event or the entry's disappearance. Input
  that prompts an Agent is followed by a later `done`, so restarting an Agent
  at the desk after prompting it from the phone does not count.
- A live snapshot showing P's Agent `idle` or `done` settles P as the live
  event does, so a `done` missed while the app was suspended does not leave
  P armed. Input to a Shell that starts nothing (`ls⏎`) disarms P once a
  snapshot requested 10 s after it still shows a Shell, and an Agent herdr
  reports live 10 s or more after the input is not the one the input typed
  (herdr notices a typed Agent within about 1.3 s). A snapshot settles P
  only under the same 10 s delay, since until herdr notices the change it can
  still show the Agent the input replaced.
- A snapshot is requested before and applied after the events that arrive
  while it is in flight. The projection signals each request; a Pane with an
  event after it is stale in that snapshot and left for the follow-up one.

The armed flag is kept per `(hostID, paneID)` in UserDefaults on this device,
so input sent before backgrounding still counts on the next snapshot, and is
dropped when the Pane disappears. On a typed Launch the detector records
`.typed` if the gate allows it; otherwise it adds the Agent to
`lockedAgents`. The Agent keeps running on the Host; its detail on the phone
shows the paywall in place of the terminal and Composer until the user buys
Pro, which clears the set.

## Consequences

- Counting is eventually consistent. Keychain sync latency lets two devices
  briefly exceed the limit together. Accepted.
- The count survives delete and reinstall and follows the Apple Account to an
  iPad, because Keychain items outlive the app and sync. A user with iCloud
  Keychain off keeps a per-device count.
- Accepted detection loophole: herdr notices an Agent only at its next
  foreground-process check. A same-kind claude or codex retype that is already
  the foreground process at that check gives no signal at all (no event, same
  entry, same `agent_session`). That takes typeahead or a retype within tens
  of milliseconds of exit, not hand typing after a Ctrl-C.
- Launches from the desk, and Agents started by anything other than the phone,
  are free by design; Waycar meters its own launching, not the Host.
- Nothing in the notification service or widget extensions is gated.
- Accepted loophole: the lock on an over-limit typed Agent lives in this
  device's UserDefaults and records nothing in the ledger. The same Agent is
  unlocked on the user's other devices and after a reinstall. Syncing locks
  would need an identity herdr does not reliably report (see `AgentKey`);
  the case needs phone typing past the limit, and every later Launch is
  still refused.
- Real renewal, grace and cross-device propagation need the sandbox store and
  two physical devices. Unit tests cover the allowance, the ledger merge
  against an in-memory Keychain, the gate, the detector, and StoreKitTest
  (`SKTestSession`) purchase, expiry, grace and revocation.

## Alternatives rejected

- **`NSUbiquitousKeyValueStore`.** ADR 0019 already rejected it; it needs a
  new entitlement, is stored unencrypted, and offers last-writer-wins on a
  single key where per-device items give conflict-free union.
- **One shared synced ledger item.** Every device would rewrite the same item
  and concurrent Launches would lose each other under last-writer-wins.
- **Tying the ledger to the iCloud Sync switch.** Turning sync off would
  become a way to reset the count on a second device.
- **Server-side receipt validation or a subscriptions SDK.** Needs a backend
  or a third party for what StoreKit 2 verifies on device.
- **Matching typed command text** (`claude⏎`). Aliases, scripts and Direct
  Input keystrokes defeat it; Pane transitions are what herdr reports.
- **Recording Launches while Pro.** A lapsed subscriber would come back
  already at the limit.

## Amendment (2026-09-28): monthly and annual plans

Waycar Pro was first built as one annual plan at $39.99. It now has two plans
with flat prices: `com.otreva.waycar.pro.monthly` at $5.00 a month and
`com.otreva.waycar.pro.annual` at $40.00 a year. Both sit in the "Waycar Pro"
group at the same level, because they are the same offer with different
terms. A switch between them takes effect at the next renewal.

`ProEntitlementStore.productIDs` lists both plans, monthly first. Either plan
is Pro; no other product ID is. The store loads both products and reads the
subscription status from any one of them, since the status covers the whole
group. The paywall and the locked-Agent card list both plans through
`SubscriptionStoreView(productIDs:)`. No subscriber was on the annual plan, so
none needed a migration. There is still no trial, introductory offer
or Family Sharing.

## Amendment (2026-11-01): Welcome Allowance (WAY-306)

Free has no Launch limit for 30 days after the first real Host is saved. After that, it allows 10 Launches per rolling 30 days, starting with no welcome Launches counted. Pro stays unlimited. The welcome clock continues while Pro is active. A lapsed subscription does not start a new period.
