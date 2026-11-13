# Live Activity wire contract (v1)

The single authority for every shape crossing a process boundary in the
per-Host agent Live Activity pipeline (app ↔ widget ↔ registration file ↔
plugin ↔ relay ↔ APNs). Implementations in `Sources/`, `plugin/`, and
`relay/` must match this file byte-for-byte where it says canonical; the
shared vectors in `plugin/test-vectors/live-activity-content-v1.json` assert
it. Change this file and the vectors in lockstep, never one side alone.

Feature decisions this contract encodes: one Live Activity per Host; lists
agents whose herdr status is `working`, `blocked`, or `done` (idle/unknown
never listed; idle shown only as a plaintext count); hybrid encryption
(plaintext counts, encrypted details); the app
starts activities locally and writes the per-activity push token to the
Host; the plugin drives updates and end over APNs after the app suspends,
and starts the activity through push-to-start when no running activity can
take updates (see [Push-to-start](#push-to-start)).

## ContentState

Decoded by ActivityKit's default `JSONDecoder` (no date/key strategies).
Every field primitive; statuses are strings, never enums — OS-side decoding
drops the whole update on any type mismatch.

```json
{"counts": {"working": 2, "blocked": 1, "done": 0, "idle": 3},
 "envelope": {"v": 1, "kid": "...", "n": "...", "ct": "..."}}
```

- `counts.working`/`blocked`/`done` count the **full** eligible inventory
  (not capped).
- `counts.idle` counts every agent whose herdr status is `idle`. It is
  additive and optional: senders that predate it omit the key, and the app
  decodes a missing `idle` as 0. Idle agents never make a Host eligible —
  an activity starts and ends on `working`/`blocked`/`done` only — and
  never enter the envelope's `agents`. An `end` push sends `idle: 0`.
- `envelope` is Optional on the Swift side: absent or undecryptable
  degrades rendering to counts-only, never drops the update.
- The Swift attributes type is `AgentActivityAttributes` (static content:
  `hostID` UUID string only). The name is shipped-forever: a push-to-start
  sends it verbatim as APNs `attributes-type`, and ActivityKit decodes the
  push's `attributes` (`{"hostID": "<UUID>"}`) with its default decoder.

## Encrypted details envelope

Same AES-256-GCM mechanics, `{v,kid,n,ct}` framing, and kid derivation
(first 8 bytes of SHA-256 over the 32-byte key, unpadded base64url) as the
notification envelope, with AAD **`HERDR-ACTIVITY:1`** for domain
separation: a `HERDR-NOTIFY:1` ciphertext must fail authentication when
opened as an activity envelope, and vice versa.

Decrypted plaintext (canonical form):

```json
{"agents": [{"kind": "claude", "name": "reviewer", "pane": "wV:p1", "progress": {"done": 3, "total": 7}, "status": "blocked", "title": "...", "workspace": "Heeler"}],
 "host": "mbp", "v": 1}
```

- Canonical encoding, identical on both sides: compact JSON (no
  whitespace), object keys in **ascending alphabetical order** at every
  level (Swift: `.sortedKeys, .withoutEscapingSlashes`; the Host Tools'
  Rust code writes the same bytes, and the 1.x Node code built objects with
  alphabetically ordered keys, then `JSON.stringify`).
- `agents` ordered as: eligible agents whose pane id appears in this
  device's `live_activity.pinned_pane_ids` first, by that array's index
  (most recently pinned first); remaining eligible agents in the existing
  order (`blocked` > `done` > `working`, ties by `pane` ascending byte
  order). Cap at **5** after that sort. `counts` still covers everything.
  Pins never change eligibility: idle/unknown stay hidden. A pinned
  working agent may displace an unpinned blocked agent from the visible
  rows. The widget renders rows in envelope order and does not re-sort.
- `title` is `terminal_title_stripped ?? terminal_title`, trimmed to ≤80
  graphemes; omitted (not empty) when unavailable. `kind` falls back to
  `"unknown"`.
- `name` is the herdr agent name (`display_agent ?? name`), trimmed to ≤80
  graphemes; omitted (not empty) when the agent is unnamed.
- `workspace` is the herdr workspace label resolved by `workspace_id`, trimmed
  to ≤80 graphemes and omitted when unavailable. It is additive v1 metadata,
  so older senders remain readable with a kind-only identity. Agent entry key
  order is `kind` < `name` < `pane` < `progress` < `rows` < `status` < `title` < `workspace`.
- Optional `rows` carries the Agent's rendered Agent List Fields, using this
  device's resolved `live_activity.row_layout`. It contains at most three
  nonempty rows, each an array of plain-text spans:
  `[{"bold":true,"dim":false,"fg":"#AbC","text":"Heeler"},{"text":" · "},{"text":"reviewer"}]`.
  Span keys are ordered `bold` < `dim` < `fg` < `text`; styles are optional,
  `fg` accepts only `#RGB` or `#RRGGBB`, and text keeps the first 80 graphemes without adding an ellipsis.
  Separators are separate unstyled spans. Empty fields and rows are omitted,
  and so is a value equal to one already shown earlier in the same row, with
  its separator (a herdr worktree's Workspace and tab both carry the branch
  name). Values compare case-sensitively after Unicode NFC normalization and
  trimming Swift's `whitespacesAndNewlines` (Unicode `Z*`, U+0009–U+000D and
  U+0085; U+FEFF is not whitespace) on both producers;
  plugin text is never interpreted as Markdown. An absent or malformed layout
  omits `rows`, preserving the legacy workspace/kind identity. An explicitly
  empty layout produces `rows: []`.
- Field values match the Console: workspace label; tab label (hide the sole
  tab when its label equals its 1-based position); AgentInfo `title`, falling
  back to the matching pane label only when absent; Agent display name
  (`display_agent`, then `name`, then raw kind); raw terminal title; stripped terminal title (an absent value falls back
  to the raw title with one leading activity glyph removed only at a whitespace
  boundary, while an explicitly empty value stays empty); configured Host display name; capitalized status;
  trimmed `cwd` for directory; and `tokens` values for `$custom` fields.
  `state_icon` and `state_text` render no text because the status indicator
  owns that information. Missing context suppresses that field only.
- Optional `progress` is the Agent Progress estimate, the same shape and
  bounds as the summary-store record's `progress`: `done` and `total`
  integers, both or neither, with 0 ≤ done ≤ total and 1 ≤ total ≤ 99;
  and/or `phase`, one of `exploring`, `implementing`, `verifying`,
  `wrapping_up`. Keys are ordered `done` < `phase` < `total`; absent members
  are omitted. Producers send it only for an Agent whose status is `working`
  or `blocked`, only while AI summaries are on, from the first of: the
  Agent's summary-store record (with summary text) written in its current
  status, when that record has progress; for a Blocked Agent, a record still
  `working` (the notify hook's Blocked record lands seconds after the status
  push, and Blocked shows the frozen last estimate either way); the
  plugin's plan-step tick map (see [Plan-step tick](#plan-step-tick); steps
  only). There is no age gate. Done,
  idle and unknown Agents never carry it. Consumers decode it leniently: an
  invalid `done`/`total` pair drops the steps only, an unknown or mistyped
  `phase` drops the phase only, and nothing valid left means no progress;
  it never fails the payload. It is additive v1 metadata: older widgets
  ignore it, and older senders simply omit it.
- `host` is the Host machine's short hostname (first DNS label), ≤80
  graphemes.
- Unknown fields in plaintext or envelope frame are ignored (additive v1
  metadata); breaking changes bump `v` on both ends together.
- Size budget: the base64url `ct` should stay ≤ ~2800 bytes so the full
  APNs payload stays under 4096. Producers degrade in order: drop all
  `title` and legacy `name` fields, then `rows`, then `progress`, then send
  `agents: []`; a step that would drop nothing is skipped. Workspace/kind
  identity remains after rows and progress are dropped; counts always fit.

The widget opens with a status header: the lead count in attention order
(blocked, then done, then working) as symbol + "N Status", followed by every
other non-zero count as symbol + number, idle last in the muted palette
colour. Below it each Agent gets one line: a monogram of its kind, configured
row 1 as the headline, row 2 as secondary text, and its status in words and
status colour. Rows 3+ are not drawn on the Lock Screen or in the Dynamic
Island. A row-2 value equal (by the same comparison) to one already
on that line is dropped with its separator, since both rows share it. It
preserves field colors, bold and dim styles. When `rows` is absent
it uses workspace and friendly Agent kind as the legacy identity. Agent order
remains unchanged. The Lock Screen shows up to 4 Agent lines within its 160 pt
budget (3 when a "+N more" or stale footer is needed), followed by "+N more"
when Agents remain. The expanded Dynamic Island shows up to 3 lines when the
total is 3 or fewer, otherwise 2 lines and "+N more"; its trailing counts
never include idle. The compact
Dynamic Island shows the lead status symbol and its count; minimal shows the
symbol and count together. Totals are `working + blocked + done` only: idle is
never part of the total. The envelope's `host` is not a separate heading, but
a configured `host` field can display the per-device Host name.

Progress: Lock Screen and expanded Dynamic Island rows draw a 2.5 pt rule
under the identity text, inside the unchanged 28 pt row, for Working and
Blocked Agents that carry `progress` (Blocked's bar is frozen; Done draws
none). A Working row's trailing status word becomes the progress label
("3/7", "Verifying"), and the rule's fill dims once the activity is stale.
When the lead status is Working and at least one of the top 3 Agents has
progress, the compact Dynamic Island trailing shows up to 3 hairline bars
(one per Agent, envelope order) instead of the count. The `.small` family
(Watch Smart Stack, CarPlay Dashboard) shows the host name, the lead count
and the top 3 Agents by short name, each with its label and a mini bar. No
percentage, ETA or time-left text appears anywhere.

## Relay request (plugin → relay)

Extends the existing `POST /push`. Bodies without `kind` behave exactly as
today (alert path, byte-identical); the alert path rejects any body that
does carry `kind`.

```json
{"kind": "liveactivity", "token": "<hex activity or push-to-start token>",
 "env": "production" | "sandbox",
 "event": "start" | "update" | "end", "priority": 5 | 10,
 "timestamp": <unix seconds>,
 "stale_date": <optional, > timestamp>,
 "dismissal_date": <optional, end only>,
 "counts": {"working": N, "blocked": N, "done": N, "idle": N},
 "envelope": "<canonical envelope JSON string>",
 "attributes_type": "AgentActivityAttributes",       // start only
 "attributes": {"hostID": "<UUID>"},                  // start only
 "alert": {"title": "<generic>", "body": "<generic>"}} // start only
```

Validation (relay-origin failures use `{"error": ...}`): `event` whitelist;
`priority` ∈ {5, 10}, and on `update`/`end` 10 requires
`counts.blocked >= 1` (a `start` may always use 10); `timestamp`
integer within `[now − 86400, now + 300]`; `counts` exactly the three keys
`working`/`blocked`/`done` plus optional `idle`, all integers 0..999 (no
other keys); the relay forwards `idle` only when the request carried it;
`envelope` non-empty string, never parsed; `collapse`
absent. `start` requires `attributes_type` exactly `AgentActivityAttributes`
(`bad_attributes_type`), `attributes` exactly `{"hostID"}` with a canonical
8-4-4-4-12 hex UUID string (`bad_attributes`), and `alert` exactly
`{"title", "body"}`, each a non-empty string of at most 100 UTF-8 bytes
(`bad_alert`); `update` and `end` must carry none of the three. The relay
additionally observes the counts, the start/update/end/priority signal, and
on a start the Host id and the generic alert — nothing else new (PRIVACY.md
documents this).

## APNs request (relay → Apple)

`POST /3/device/<activity token>` with the existing ES256 JWT. Headers:
`apns-push-type: liveactivity`, `apns-topic:
<APNS_TOPIC>.push-type.liveactivity` (suffix-derived, no new config),
`apns-priority: 5|10`. Body:

```json
{"aps": {"timestamp": <unix seconds>, "event": "start" | "update" | "end",
         "content-state": {"counts": {...}, "envelope": {...}},
         "stale-date": <start/update: timestamp + 900>,
         "dismissal-date": <end only: = timestamp, immediate removal>,
         "attributes-type": "AgentActivityAttributes",   // start only
         "attributes": {"hostID": "<UUID>"},              // start only
         "alert": {"title": "...", "body": "..."},        // start only
         "input-push-token": 1}}                          // start only
```

`update` and `end` never carry an `alert` field — the existing
alert-notification path owns alerts. APNs requires an alert on `start`, so a
start carries the plugin's fixed generic text (title "Agents active", body
"Agent status is live on your Lock Screen."), never a Host, agent, or task
name. `input-push-token: 1` asks iOS 18 to issue the pushed activity an
update token, which the app then registers like a locally started one.
Priority 10 only when an agent **newly** entered `blocked`, or for a start
(at most once per episode per device); 5 otherwise.
The plugin's duplicate-update suppression keys on the eligible
`{pane: status}` map plus the idle count and the `{pane: progress}` map of
the Agents some update device's envelope lists (its pins and the cap of 5;
last-state records them as `visible`), so an idle-count or visible progress
change alone pushes an update at priority 5 while the activity is running
(never after `end`, and never starting one). A progress change on an Agent
past the cap pushes nothing.
Existing 4096-byte pre-check applies; 410/413 verdicts pass through to the
plugin unchanged (`{"reason": ...}`).

## Plan-step tick

Status hooks run only on status events, so a plan step finished between
them would wait for the next one. While an episode is live (an update or
start was delivered and no `end` since), AI summaries are on and the last
pushed state has a Working Agent, every status run makes sure one detached
tick process (`waycar activity-tick`) is running. A lock file in the
activity state directory (`activity/tick.lock`, `{pid, ts}`) keeps it
single-instance; the tick rewrites `ts` as a heartbeat before each wait,
before each plan read and around each push, and a lock whose holder died or
whose heartbeat is older than two intervals plus one plan read (310 s) is
taken over, so a pid reused after a crash blocks ticks for minutes at most.

About every 150 s the tick reads each Working Agent's plan steps from its own
transcript (no model call ever):

- **Could not read** (timeout, abort, parse or IO error): nothing is written
  anywhere; the stored and shown estimate stays.
- **No plan this turn**: the steps are dropped from the Agent's Working
  summary-store record (its phase stays) and from the tick's map.
- **Steps**: written onto the Agent's Working summary-store record when one
  with summary text exists, and into the tick's own plan-step map
  (`activity/plan-steps.json`, `{pane: {done, total}}`), which covers a turn
  that started while the app was closed and no Working record exists. The
  tick never writes summary records or tombstones of its own.

Map entries are dropped once their pane is listed in another status than
Working or Blocked, or is no longer listed by a backend that answered (tmux
answering "no server running" counts as an empty answer; any other tmux
failure leaves tmux panes' entries alone). When a
visible Working Agent's estimate differs from the last pushed one (its own
steps, or an estimate the summary refresh wrote), the tick runs the same
update flow at priority 5 under the same send lock. It pushes only while the
inventory's statuses equal the last pushed ones (a status change is the
hooks' push, with their priority rule) and never starts an activity. It exits
when no Agent is Working, the episode ended, summaries were switched off, or
after 2 hours; the next status event starts a new one. It follows the
trigger's herdr CLI and environment and the Host's `tmux_enabled`. When it
finds summaries switched off it deletes `activity/plan-steps.json` and, if
the last push showed any progress, sends one priority-5 update through the
same flow (which now carries no progress) before exiting, so a pocketed Live
Activity never keeps bars the user turned off. A record's explicit
`progress: null` means no estimate, like an absent key.

Every `idle` or `done` status event (herdr hook and `waycar notify`) ends
that pane's turn: before anything else, whether or not a Live Activity is
registered, the plugin drops the pane's stored progress (summary store
`clearProgress`) and its tick map entry, so the next turn never starts from
the old steps or phase.

## Registration file (additive per-device fields)

Written by the app (set on start and token rotation, cleared on local end
or user dismissal while foregrounded), read fresh by the plugin on every
event:

```json
"live_activity": {"token": "<hex per-activity push token>",
                  "started_at": "<ISO 8601>",
                  "pinned_pane_ids": ["wV:p7X", "wV:p1"],
                  "host_name": "My Mac",
                  "row_layout": {"rows": [[{"token":"workspace"}],
                                          [{"token":"agent"}],
                                          [{"token":"directory"}]],
                                 "row_gap": 0, "rows_by_agent": {}}}
```

Missing field = send nothing (fail closed; `notify` flags do not gate this
path). On APNs 410 the plugin deletes only this field, preserving the
device entry's alert `token`, `key`, `notify`, and unknown fields. A user
dismissing the activity while the app is dead self-heals through that 410
on the next push.

Two Host entries in the app can reach the same computer (a Tailscale name
and a LAN address): they share this file and this device's one entry in it.
The app shows one Live Activity per computer (entries that trust a common
host-key digest are one; the first with Live Activities on wins, then catalog
order), and every app-side clear is compare-and-clear: `live_activity` only
while it still holds the token this Host wrote, `live_activity_start` only
while its `host_id` names this Host. The entry's `env` must match the APNs
environment of the build holding the token; when a TestFlight build
registered the token and a development build on the same device now holds
it, the app re-registers the entry on its next read of the file.

`pinned_pane_ids` is this Host's pin recency list: pane-id strings,
most-recently-pinned first. The app writes it whenever it writes
`live_activity` and pushes an update when the pin set changes while the
Host is connected and an activity is running. Missing, null, a
non-array, or any non-string entry is treated as an empty list (older
apps never write the field). Empty
string entries are still strings and are kept. The field is additive v1
metadata; unknown sibling keys on `live_activity` must survive a rewrite.

`row_layout` is the app's resolved per-Host Agent List Fields layout: at most
three rows, at most 16 fields per row, no per-kind overrides. Each field has
`token` and optional `fg`, `bold`, and `dim`, matching the Console layout JSON.
`row_gap` and `rows_by_agent` are accepted for structural compatibility but do
not change activity rendering. The app writes this layout and optional
`host_name` on registration, layout edits, Host name changes, and plugin sync.
The plugin falls back to the short hostname when `host_name` is absent.
Registration preferences participate in duplicate-update suppression, so the
next status hook can send changed layout or pin preferences even if statuses
are unchanged. The hook reads tab/pane context only when configured fields
need it, once per workspace rather than once per Agent. Foreground app updates
use the same resolved layout; background delivery still follows status events.

`live_activity_start` is a sibling device-entry field, independent of
`live_activity` (clearing one never touches the other):

```json
"live_activity_start": {"token": "<hex push-to-start token>",
                        "host_id": "<Host UUID, uuidString form>"}
```

The app writes it for every known Host whose Live Activity toggle is on
while iOS allows Live Activities, and removes it otherwise, whenever
ActivityKit reports a new push-to-start token, the toggle changes, or the
app returns to the foreground (a failed write retries on reconnect). The
token is per app install and activity type, so every such Host gets the same
token with its own `host_id` — the app's random identifier for that Host,
never its name or address. The device must already be registered
(`deviceNotRegistered` otherwise). Missing or malformed (non-hex token,
non-UUID `host_id`, invalid entry `env`) = never start. On a 410 for the
push-to-start token the plugin deletes only this field.

## Push-to-start

The plugin starts a Host's Live Activity on a device when all hold:

- the eligible inventory is non-empty;
- the device has a valid `live_activity_start` and **no live update token**:
  `live_activity` absent, pruned by a 410, or holding a token whose activity
  the plugin itself ended with an `end` push (tracked in its state as
  `ended_tokens`). A device without `live_activity_start` keeps the pre-start
  behavior: its update token always receives updates;
- the device has not been started in the current **episode**. An episode ends
  when the eligible inventory empties; a live update token appearing also
  resets the device's guard. An update 410 during an episode (the user
  dismissed the activity) sets the guard, so a dismissed activity stays
  dismissed until the Host goes quiet;
- no update token appeared during the start grace (`activity_start_grace_ms`,
  default 8 s, re-read after the wait). The grace outlasts the app's own
  foreground start (3 s settle plus the token write), so an open app's local
  activity wins instead of racing a pushed duplicate and its alert.

The start content is built like an update (the device's pins, layout, and
host name when a stale `live_activity` still carries them; defaults
otherwise).

**App adoption rule.** The app watches ActivityKit's `activityUpdates` and
scans `Activity.activities` at launch, on foreground return, and before any
local start. An activity for a known Host is adopted into the Host's session
rather than duplicated: its push token flows into `live_activity`, and the
next settle refreshes its content. When a Host has more than one activity,
the newest wins (a newly announced one, or the last in ActivityKit's
oldest-first list) and the others end immediately; a replaced session's
token is cleared until the new one's arrives. Activities for unknown Hosts
end immediately. An activity iOS ended (its 8-hour limit) stays on the Lock
Screen, frozen, for up to 4 hours until it is dismissed: the app never
adopts one, dismisses it immediately when it finds it (state stream, launch,
foreground return, or before a local start), and lets the next settle start
a fresh one while Agents still want it. A retired activity ActivityKit still
lists is ended again on every scan.

**Background handoff limit.** A pushed activity can take updates only after
the app registers its update token over SSH. iOS delivers that token when it
next runs the app, but Waycar opens Host connections from its foreground
scene, so the write normally lands the next time the app is opened with the
Host connected. Until then the activity shows its start content, marked
stale after 15 minutes, and the plugin cannot end it; iOS ends it after its
usual eight-hour limit if the app never returns. Push-to-start delivery from
a killed app is itself best-effort on Apple's side.

## FCM provider (Android Live Update)

Registration entries with `"provider": "fcm"` (plugin 2.1.0+) take Live Updates too, with none of the APNs machinery:

- Eligible when `live_activity.enabled === true` and the entry's `token` is an FCM registration token (50–512 characters of
  `[A-Za-z0-9_:.-]`); the update target is that `token`. There is no per-activity token and no push-to-start, so
  `live_activity_start` is ignored, the start grace and `ended_tokens` bookkeeping do not apply, and an event the plugin would
  call `start` is sent as `update`.
- The relay body is `{"provider":"fcm","kind":"liveactivity","token","env","event":"update"|"end","priority":5|10,"envelope"}`.
  No `counts`, no `timestamp`, no `stale_date`/`dismissal_date`, no `attributes_type`/`attributes`/`alert` (the app derives the
  counts from the envelope's agents, C35). `event` and `priority` are the only plaintext.
- The relay sends `data {v:"1", t:"la", event, prio, envelope}` as an FCM data-only message (`plugin/test-vectors/fcm-data-message-v1.json`);
  priority HIGH only for `priority` 10, ttl 300 s (`end`: 3600 s).
- A 410 prunes the whole registration entry (there is no `live_activity` token to drop). The envelope, its AAD, degrade steps
  and agent order are exactly the ones above.

## Shared vectors

`plugin/test-vectors/live-activity-content-v1.json`, same schema style as
`notification-payload-v1.json`: non-`decodeOnly` `valid` vectors must be
reproduced byte-for-byte by the seal side and opened by the open side;
`invalid` vectors must fail with the given typed error. Includes the
cross-AAD case proving domain separation. Pin-order cases also carry
`inventory`, `pinned_pane_ids`, and `counts` (including `idle`) so both
suites pin the shared sort rule and count rule. Inventory cases may also
carry `summaries` (pane id → summary-store record), pinning which Agents
carry `progress`, and `row_layout`, `workspace_labels` (workspace id →
label) and `tabs` (`tab_id`, `workspace_id`, `label`, `position`, `count`),
pinning the rendered `rows`. The decode-only "malformed progress is
ignored" case gives each agent's lenient result in `expectProgress` (outside
the ciphertext). The `degrade` section lists, for one full plaintext, what
each degrade step must leave. The `pushToStart` section
pins the start attributes: the plugin must build exactly its
`attributesType` and `attributes` from `hostId`, and the app must decode
those attributes as `AgentActivityAttributes` with the default decoder.
Consumed by both the Rust suite (`cargo test --locked` in `plugin/`) and WaycarTests;
regenerate the envelopes only via an independent raw-crypto script.
