# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately, never in a public issue, pull
request or discussion:

1. **GitHub private vulnerability reporting** (preferred): open
   <https://github.com/waycar/waycar-app/security/advisories/new>, or the
   repository's **Security** tab › **Report a vulnerability**.
2. If you cannot use GitHub, email **support@waycar.dev** with "Security" in
   the subject. Do not send exploit details to any other address.

Include what is affected (app version and device, plugin version, Host OS
and herdr, tmux or herdr-core version), how to reproduce it, and what an
attacker gains. We aim to acknowledge a report within a few working days,
keep you informed while we fix it, and credit you in the advisory unless you
prefer otherwise. Please give us a reasonable time to ship a fix before you
publish.

## Scope

In scope, in this repository:

- **The app** (`Sources/`, `Packages/`): SSH and host key handling, the
  Keychain and iCloud Keychain items, Pairing Codes, the Notification Keys
  and the decryption of notifications and Live Activities, Chat Mode, links
  and files opened from a Host.
- **The Host Tools** (`plugin/`, installed by
  `https://waycar.dev/install.sh`): the installer, the `waycar` binary, the
  Status Hooks, Enrollment and the notification encryption.
- **The Push Relay** (`relay/`, deployed at `https://waycar-apns.otreva.com`).
- **The site** (`apps/web/`, <https://waycar.dev>).

Out of scope: herdr, herdr-core, tmux, OpenSSH, mosh and the coding agents
themselves (report to their projects), vulnerabilities in third-party
dependencies that Waycar's use does not expose, and findings that need a
compromised Host or device to begin with. [PRIVACY.md](PRIVACY.md) describes
what the relay and the app can and cannot see.

## Supported versions

Fixes ship in the next App Store release and the next plugin version; only
the latest app and plugin releases are supported.
