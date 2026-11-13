---
status: accepted
---

# Waycar internal rename and Keychain service migration

Waycar renames its internal names from Heeler to Waycar: source and test
directories (`Sources/Waycar`, `Sources/WaycarNotificationCore`,
`Sources/WaycarActivityCore`, `Sources/WaycarWidgets`,
`Sources/WaycarNotificationService`, `Tests/WaycarTests`), the SSH and mosh
packages (`Packages/WaycarSSH`, `Packages/WaycarMosh`), the Xcode project,
targets, scheme and Swift module (`Waycar.xcodeproj`, scheme `Waycar`), type
names, log subsystems and queue labels (`com.otreva.waycar…`), test and CI
environment variables (`WAYCAR_*`), the shell marker `WAYCAR_SHELL=1`, the Live
Activity deep-link scheme `waycar://`, and the Keychain services:

| Old service | New service |
| --- | --- |
| `dev.bybee.heeler.ssh` | `com.otreva.waycar.ssh` |
| `dev.bybee.heeler.notifications` | `com.otreva.waycar.notifications` |
| `dev.bybee.heeler.sync` | `com.otreva.waycar.sync` |

Everything that is Heeler's upstream or external keeps the Heeler name.

## Context

Waycar is based on Heeler (ZingerLittleBee/Heeler, Apache 2.0). The first
rename changed only what users see: the app name, bundle identifier, and
permission prompts. Directories, types, Keychain services, environment
variables and the deep-link scheme still said Heeler, so every file, log line
and Keychain item named a different app. The user wanted Heeler gone
everywhere it is Waycar's own.

Keychain services are not cosmetic. Waycar builds before this change stored
Host passwords and the device-only SSH keys under `dev.bybee.heeler.ssh` and
per-Host Notification Keys under `dev.bybee.heeler.notifications`. A build that
simply reads the new services finds nothing: Hosts fail authentication and
notifications from already-registered Hosts cannot be decrypted.

## Decision

**Rename everything that is Waycar's own.** Code, project, packages, scripts
(`scripts/run-waycarssh-package-tests.sh`), identifiers, environment variables,
the shell marker, the deep-link scheme and the remote staging directory
(`${TMPDIR}/waycar.XXXXXXXX`) all use Waycar.

**Copy the device-only Keychain services on first read.** `dev.bybee.heeler.ssh`
and `dev.bybee.heeler.notifications` are read through `MigratingSecretStore`,
which puts the matching Waycar service in front of the old one:

- A read the new service cannot answer falls through to the old service and
  copies the item across. Only accounts the new service lacks are copied, so
  a value written under the new name is never overwritten by an older one and
  repeating the copy is harmless.
- The copy is best effort. A read the old item can answer never fails because
  the copy did (a locked device, say); the next read tries again.
- Old items are left in place as a safety net if a copy fails or a build has
  to be rolled back. The one exception is an explicit removal (a Host password
  cleared, a key replaced away): it clears both services, because an old copy
  left behind would be copied straight back on the next read.
- The migration lives in the stores themselves rather than in an app launch
  hook, so the notification service extension and the widget extension, which
  build their own Notification Key store, can decrypt pushes and Live
  Activity updates before the app is launched for the first time after
  updating.

The synced service `dev.bybee.heeler.sync` never shipped under that name, so
`com.otreva.waycar.sync` has no migration.

**What stays Heeler for now, and why.** The first two are planned renames,
each needing work outside this repository first; the steps are in
[`docs/todo.md`](../todo.md).

- The herdr plugin: the `plugin/` directory, its id `heeler`, action
  `heeler.pair` and install path `herdr plugin install
  ZingerLittleBee/Heeler/plugin`. Every Host runs this upstream plugin and the
  app finds its config dir by id, so a rename needs a renamed plugin
  installable on Hosts plus an app release that accepts both ids.
- The Push Relay's `relay/` directory name. Its host was renamed later (see
  the amendment below).
- The landing site's deploy target: the `heeler.bybee.dev` domain, the
  `heeler-landing` Cloudflare Worker, and the App Store link to "Heeler for
  herdr", which need a Waycar domain and listing.
- Attribution: "Based on Heeler", the README credit to ZingerLittleBee/Heeler,
  LICENSE and NOTICE, and every URL under `github.com/ZingerLittleBee/Heeler`
  (repository, issues, pull requests, workflow runs).

## Consequences

- Merging upstream Heeler now conflicts heavily: nearly every upstream change
  touches a path or type that has a different name here. Each merge needs the
  rename reapplied to the incoming changes.
- Shell rc hooks that skip agent auto-launch on `HEELER_SHELL` must check
  `WAYCAR_SHELL` instead; Default Shell and New Terminal panes no longer set
  `HEELER_SHELL`.
- Live Activities started by the previous build carry `heeler://` links, which
  no longer route. Taps on them do nothing useful until the activity ends and a
  new one starts with `waycar://` links.
- The old Keychain items remain on every device that ran an earlier build.
  Only the migrating stores read them, and only a removal of the same item
  deletes them.
- Log subsystems changed, so saved Console.app filters on `dev.bybee.heeler`
  need updating.

## Amendment: the Push Relay host

The relay host did not stay Heeler for long. Heeler's Worker at
`heeler-apns.bybee.dev` signs for Heeler's team and bundle id, so APNs rejects
every Waycar push sent through it. Waycar now runs its own Worker,
`waycar-push-relay`, at `https://waycar-apns.otreva.com`, signing for
`com.otreva.waycar` under team `5NWMRTN5BA`. The app and the plugin default to
it, and both treat `heeler-apns.bybee.dev` (like the older
`herdr-apns.bybee.dev`) as a previous production relay: a Host config still
naming it is moved to the new default the next time the app registers.

## Amendment (2026-09-26)

The landing site is retired. The marketing site is now `apps/web/`, served at
`waycar.dev`. No code, configuration, or site content references
`heeler.bybee.dev` or the `heeler-landing` Worker; only this ADR's history
does. The landing-site bullet under "What stays Heeler for now" no longer
applies.

## Amendment (2026-09-27): plugin renamed

The herdr plugin is now id `waycar` (action `waycar.pair`), installed from
`https://waycar.dev/install.sh`. The Enrollment command is `waycar-enroll`.
Legacy `heeler` id support in the app and the installer's `heeler` config
migration were removed on 2026-09-27; Hosts still running `heeler` reinstall
via `https://waycar.dev/install.sh` and pair again.

## Amendment (2026-09-27): Keychain and relay migrations removed

`MigratingSecretStore` is gone. `com.otreva.waycar.ssh` and
`com.otreva.waycar.notifications` are read directly; nothing reads the
pre-rename device-only services anymore. The Push Relay no longer treats the
previous Heeler relay endpoints as the production default, so a saved or
Host-side relay URL naming one is no longer rewritten. Devices that never ran
a migrating build lose access to their pre-rename secrets: they generate a new
Device Key and RSA Key (so every key-authenticated Host must be re-paired),
must re-enter Host passwords, and must re-register notifications. Items left
under the pre-rename services are now orphaned; nothing deletes them, which
supersedes the "only a removal of the same item deletes them" consequence
above.

## Amendment (2026-09-27): attribution without Heeler branding

Settings › About no longer has the "Based on Heeler" link. The app credits
Heeler in Settings › About › Acknowledgements instead: the `Heeler` entry in
`Sources/Waycar/Resources/Notices/inventory.json` points at
`Heeler-Apache-2.0.txt`, which carries the upstream copyright line, a
statement that Waycar is a modified version of Heeler, and Heeler's Apache
2.0 license. The public herdr plugin package ships Heeler's license and an
attribution notice as its `LICENSE` and `NOTICE`. This replaces the "Based on
Heeler" item in the attribution bullet above.
