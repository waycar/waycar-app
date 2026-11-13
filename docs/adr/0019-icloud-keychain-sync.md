---
status: accepted
---

# iCloud Sync through iCloud Keychain

Waycar syncs Hosts, Host passwords, the SSH identity keys, trusted host key
fingerprints and app preferences between the user's devices through iCloud
Keychain. Every synced item is a generic-password Keychain item under the
service `com.otreva.waycar.sync`, written with `kSecAttrSynchronizable = true`
and `kSecAttrAccessibleAfterFirstUnlock`. There is no CloudKit container, no
`NSUbiquitousKeyValueStore`, no iCloud Drive file, no new entitlement and no
sign-in screen.

This supersedes the rule that every Waycar secret is a `ThisDeviceOnly`
Keychain item. It also amends ADR 0017 (RSA-SHA2-512 authentication), whose
consequence says the RSA Key's private half is "never copied, logged, or
exported": with iCloud Sync on, the Device Key and RSA Key sync to the user's
other devices through iCloud Keychain.

## Context

The user's goal: "If I log into my iPad, I just want all of the hosts and keys
to be there so I can go right into an agent session immediately without having
to think about anything."

Until now every Waycar secret was a `ThisDeviceOnly` Keychain item, so it
never moved to another device through backup or iCloud Keychain, while Host
records lived in UserDefaults. A second device therefore started empty and
needed its own Pairing for every Host. A phone restored from backup was worse:
its Hosts came back from UserDefaults but its keys did not, so
`DeviceKeyStore.loadOrCreate()` silently minted a new Device Key and every
restored Device Key Host failed authentication until it was paired again.

## Decision

**Mechanism.** iCloud Keychain only. Synced items cannot be `ThisDeviceOnly`,
so they use `AfterFirstUnlock`. iCloud Keychain is end-to-end encrypted under
standard data protection ([Apple](https://support.apple.com/en-us/102651)) and
items sync only between the user's own trusted devices ([Apple Platform
Security, "Secure keychain
syncing"](https://support.apple.com/guide/security/secure-keychain-syncing-sec0a319b35f/web)).

**What syncs.**

- Hosts: every field of the Host record, including Jump Host settings and the
  herdr session name. One Keychain item per Host (`host.<uuid>`), so adding,
  editing or deleting a Host on one device does the same on the others, and
  concurrent edits to different Hosts do not collide. Deleting writes a
  tombstone that is never removed, so a device that was offline or had sync
  off still drops the Host (and its password) when it next syncs.
- Host passwords, per Host.
- The Device Key (Ed25519) and the RSA Key.
- Trusted host key fingerprints, so a synced Host connects without a
  first-connect prompt. Sync only adds a fingerprint a device lacks; it never
  replaces a host key a device already trusts, so a mismatch is settled on
  that device the usual way.
- App preferences: Snippets, per-Host Agent Row Layouts, Pins, app
  appearance, the Toolbar catalog (its layout, spacing and Custom Keys, kept
  per device type so iPhone and iPad sync separately, ADR 0024),
  terminal font, terminal light and dark themes, the custom Push Relay
  URL, the Hide Back Button setting, and the per-Host answers to the Host
  Tools install, move-off-Node and plugin update offers (Not now, the
  reminder switch), so they also survive a reinstall. The input mode (Composer or Direct
  Input) is no longer a preference and no longer syncs (ADR 0016). A
  removal is an explicit marker; a catalog this build cannot read is never
  pushed, so resetting it on an older build cannot wipe it elsewhere.
- Closed Sessions, one item per record with tombstones and a date-based
  expiry (see the amendment below).

**Absence is never deletion.** Only a Host or Closed Session tombstone, or a
preference removal marker, deletes anything; a Closed Session's expiry is
the one deletion by date. A missing item means iCloud Keychain has not
delivered it yet or lost it (turned off with "Delete from This iPhone", a
reset, a restore that has not synced), so the device that still has the data
publishes it again.

**What never syncs.** Notification Keys and Notification Registration: each
device registers its own push token with each Host (ADR 0008). Also per
device: Live Activity choices, terminal zoom, floating control positions,
recent selections, and the Console list's collapse state and flat or grouped
mode.

**Canonical identity.** Keys are published as content-addressed records
(`ed25519-identity.<keyID>`, `rsa-identity.<keyID>`) that are never
overwritten and never deleted. Every device uses one canonical key per
algorithm, chosen deterministically: the newest key the user replaced on
purpose (Settings › iCloud Sync › Replace Device Key / Replace RSA Key), else
the oldest key that existed before sync was turned on, else the oldest key
created since. Each device remembers the origin and time its own key was first
published under, so a record iCloud Keychain loses is published again with the
same rank. A new iPad that briefly makes its own key before the iPhone's key
arrives switches to the iPhone's key once it syncs; the iPhone never switches
away. Keys are still generated on device and still never leave the Keychain;
the Keychain now includes the user's iCloud Keychain.

**On by default.** Settings › iCloud Sync has a switch. On first launch after
updating, the device publishes its existing Hosts, passwords, fingerprints and
keys. Turning the switch off first copies this device's synced passwords and
the canonical keys into this-device-only Keychain items — if any copy fails,
sync stays on and says why — then stops syncing. The device keeps using the
shared key; the copies in iCloud Keychain and on other devices are left alone.
Turning it back on publishes this device's Hosts and passwords over the synced
copies, so edits made while sync was off win, except for Hosts deleted
elsewhere in the meantime.

**Cadence.** Hosts, passwords, keys and fingerprints are written to iCloud
Keychain as they change. The app re-reads synced items on launch, on every
return to the foreground or background, every 30 seconds while open, and a
moment after a synced preference changes, and retries Hosts that failed to
connect once new Hosts, fingerprints or keys arrive; connected Hosts are left
alone. iCloud Keychain posts no
change notification, so re-reading is the only way to notice another device's
writes.

## Consequences

- One SSH identity is shared across the user's devices instead of one per
  device. It is protected by iCloud Keychain end-to-end encryption, never
  written to a file, and never visible to the developer or Apple.
- There is no per-device revocation. Losing a device means removing it from
  the Apple Account, replacing the key in Settings › iCloud Sync (every device
  switches to the new key), and on every Host replacing the old public key line
  with the new one: the old key keeps working until its line is removed.
  Settings shows both lines, the new one with a dated comment. The old key's
  record stays in iCloud Keychain.
- Sync is eventually consistent. If two devices change the same item, one
  change wins. Each device keeps a base of the Hosts it last agreed on, so
  turning sync back on publishes only what this device changed while sync was
  off (Host edits and deletions, passwords set here), never stale copies.
- A device that signs in to a different Apple Account republishes what it
  still holds into that account's iCloud Keychain, because a missing item is
  never read as a deletion. Turn iCloud Sync off before handing a device to
  someone else.
- The app cannot detect whether iCloud Keychain is on, so it never claims a
  Host or key is synced. Sync needs the same Apple Account with two-factor
  authentication on each device, iCloud Keychain turned on, and Waycar's iCloud
  Sync switch on.
- If Waycar was used on two devices before sync, each had its own Device Key.
  After sync both use the canonical key, and a Host that trusted only the other
  device's key needs the canonical key added to `authorized_keys` (the Host
  form shows it) or a fresh Pairing. Hosts are unaffected when only one device
  had Waycar.
- Items sync only between installs of the same app, with the same bundle id
  and team: the App Store and TestFlight builds share them; a build from source
  with a different bundle id does not.
- Real propagation needs two physical devices on one Apple Account. The unit
  tests cover the merge and identity rules against an in-memory stand-in for
  iCloud Keychain, not iCloud itself.

## Alternatives rejected

- **File export and import.** Moving private keys means a
  passphrase-protected file that can land in Mail, AirDrop or iCloud Drive,
  and iCloud Drive is not end-to-end encrypted under standard data protection.
- **CloudKit private database.** Encrypted fields are end-to-end encrypted
  only with Advanced Data Protection. It needs a container, schema deployment,
  and account and zone-reset handling, and its data counts against the user's
  iCloud quota.
- **`NSUbiquitousKeyValueStore`.** Apple says not to store sensitive data in
  it (stored unencrypted on disk), and it needs an entitlement.
- **Per-device keys with re-enrollment on each new device.** Defeats the
  goal of not having to think about it.
- **Multi-key authentication** (offer every synced key to a Host). Rejected to
  keep the transport unchanged; one canonical key per algorithm instead.

## Amendment (2026-09-26): Closed Sessions

Closed Sessions (CONTEXT.md) sync too, as a third record type beside Hosts
and preferences. They are a growing collection that several devices append
to at once and forget from one record at a time, which is the Host
catalog's collision profile, not a preference's: one item per record,
`closed-session.<id>`, under the same service. The id is a hash of the Host,
the Agent kind and herdr's session reference (or, without one, the terminal
the Agent ran in), so every device that saw the same Agent close writes the
same item. Each record carries two times: when the capturing device last saw
the Agent running (the live snapshot before the one it was gone from, or for
rows seeded from the on-device inventory cache, when that snapshot was taken)
and when it noticed the Agent gone. Where two copies differ, the one last
seen running later wins.

Forgetting a record — Forget, or using the resume of a record herdr never
reported a session for — writes a tombstone, `closed-session-deleted.<id>`,
holding when that happened, and never earlier than the times of the record
it forgets. Unlike a Host tombstone it is not absolute: it overrides a copy
whose Agent was last seen running no later than it. The closure time cannot
serve: a device back
from a suspension notices, only now, closures that happened long before, so
comparing when a closure was noticed would let its capture outrank a Forget
made elsewhere meanwhile. Keyed on the last sighting, neither that capture nor
a device republishing a stale copy can bring a record back, while the same
session seen running after a resume and closing again is a new record. A
capture whose Agent was last seen running more than 30 days ago, or at an
unknown time (a cache written before the sighting was kept), is not recorded
at all: every tombstone that would have covered it may have expired. Each
device keeps the tombstones it wrote, so a record forgotten while sync was
off is forgotten everywhere once it is back on.

The times compare one device's clock with another's. Stamping a tombstone
no earlier than the record's own times keeps a Forget effective from a device
whose clock is behind; a time another device wrote more than five minutes
past this device's clock is read as this device's now plus five minutes, so
a clock running far ahead can neither keep a record or tombstone past its
expiry nor let a tombstone forget later closures. That clamp happens once:
the device whose clock runs ahead republishes its own value over any other
copy, so while this device holds a clamped copy it keeps it rather than
clamping again, and it writes the clamped value back only when it first
clamps it. Clamping on every pass would move its copy forward with its clock
and trade writes with the other device every pass; the one write-back lets
the item expire on time once that device stops publishing it. The cost is
that a later change to that record or tombstone made on the device running
ahead reaches this one only once its clock catches up with that stamp.

Records expire 30 days after they closed, on every device and without a
tombstone: a pass drops an expired record here and removes its item, and
drops a tombstone once every record it could override has expired. A pass
removes an item only when this device keeps nothing under that account, so it
never deletes what it just wrote. A record for a Host this device does not
know yet is neither adopted nor removed; it arrives with its Host. Records go
up with the pass that follows a change rather than as they change, and one
that fails does not hold up the rest of the pass. A record this build cannot
read (a newer build's Agent kind) is never overwritten from here.

On the device, records live in one file under Application Support, excluded
from backups like the Console's last-known inventory they are captured from.
That cache is unreadable while the device is locked and may simply start
empty; the records are protected until the first unlock instead, so a capture
made while the device is locked still persists. The synced copies are iCloud
Keychain items as above.

Revised 2026-09-27: a record whose session is running again — resumed on
any device, used or not, or restored by herdr — is no longer forgotten. Each
device just leaves it out of its Closed list while the rows it lists run that
session, and lists it again when that Agent closes (its closure is captured
as a later copy of the same record). Tombstoning on sight let one device
forget a record another device was in the middle of resuming, and let a
misread snapshot on the resuming device itself forget a record the user
never used; hiding is local and forgets nothing, so neither can happen. A
record without a session cannot be matched to the Agent it resumed, so a
used resume of one still writes a tombstone.
