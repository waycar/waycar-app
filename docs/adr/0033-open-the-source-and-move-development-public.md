---
status: accepted
---

# Open the source and move development public

_2026-11-11, accepted: the owner's decision. Supersedes decision 7 of
`docs/design/tmux-backend.md` §0 ("Waycar stays closed source") and the
closed-source trust story that ADR 0026 wrote into ADR 0008. ADR 0021 and ADR
0025 keep their decisions; the private-repository reasons they gave no longer
apply._

## Context

On 2026-09-30 the owner decided that Waycar stays closed source
(`docs/design/tmux-backend.md`, decision 7): the repository was private, and
no site, store or doc copy called Waycar, its plugin or its relay open source.
ADR 0026 amended ADR 0008 to match, so trust rested on end-to-end encryption
and on what `PRIVACY.md` discloses, not on code anyone could read.

The code was licensed Apache-2.0 all along (it is a permanent fork of Heeler,
also Apache-2.0), so only the repository's visibility kept it closed. Being
private had costs: hosted macOS minutes were billed, so iOS CI moved to the
maintainer's own Mac and dropped the real-password fixture there; and notes
about the maintainers' machines, test Hosts, App Review and agent workflows
grew inside the same repository as the app.

## Decision

- **The source is public** under Apache-2.0, the license it already carries,
  in a new repository, `waycar/waycar-app`, which is the development repository
  from then on. It starts from one snapshot commit of the private `main`,
  without history.
- **The private repository is archived**, with its history, tags, issues and
  pull requests. Issue numbers and `WAY-<n>` ids in text from before the cut
  refer to it.
- **Internal material moves to a private companion repository**,
  `waycar/ops`: the maintainers' agent rules, the test-Host, lab and App Review
  tooling, store and marketing material, and the workflows that run on the
  maintainers' own machines. The public repository builds and tests without
  it; only the maintainers' release preflight reaches into it.
- **CI runs on GitHub-hosted runners only**, free for public repositories: the
  iOS lane on macOS with the real-password fixture back on, everything else on
  Ubuntu. Deploy secrets live in the `production` environment, used only from
  `main`.
- **Contributions** are licensed inbound = outbound (Apache-2.0 section 5),
  with no CLA. Vulnerabilities are reported privately through GitHub's private
  vulnerability reporting (`SECURITY.md`).

## Consequences

- ADR 0008's trust story holds in its original form again: anyone can read
  the app, the Host Tools and the Push Relay. End-to-end encryption still
  carries the trust; readable code adds a way to check it.
- Site, store and doc copy may call Waycar open source. The comparison pages
  that said "Waycar's app is closed source" change when the repository goes
  public.
- GPL code still stays out of the app: linking, copying or porting mosh's GPL
  client would make the app a GPL work, and Waycar is Apache-2.0 (ADR 0021).
- libghostty's build stays a release asset of `otreva/ghosttykit` (ADR 0025);
  moving it is a separate change.
- A leak on public `main` is public the moment it is pushed. Every pull
  request and push runs a secret scan (gitleaks and generic checks for private
  addresses and key formats), and maintainers run a fuller private scan
  before they push.
- Maintainers and their agents work with two checkouts side by side, the
  public one and the ops one; `AGENTS.md` points to the ops notes.
- References from before the cut (`#<n>`, `WAY-<n>`) do not resolve in the
  public repository; the changelog keeps stripping `#<n>` references when it
  renders.
- The root commit carries no app tag, because an old version's tag would
  point at code that is not that release. `scripts/release-baseline` names
  the newest version released before the cut, and `scripts/publish.sh` uses
  it in place of the tag only while the repository has no `v*` tag; the
  first public release's tag ends that. The plugin's `plugin-v<version>` tag
  does go on the root commit: `plugin/` there is that release.
