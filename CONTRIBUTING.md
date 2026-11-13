# Contributing to Waycar

Issues and pull requests are welcome. Bug reports from real setups are
especially valuable: much of this app is shaped by what breaks in daily use,
and a report that names the app version, the herdr, tmux or herdr-core
version, the SSH topology and what the screen showed is already half the fix.

Security problems go through [SECURITY.md](SECURITY.md), never a public
issue. Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Orientation

Read these before changing anything non-trivial:

- [`CONTEXT.md`](CONTEXT.md): the domain vocabulary. Issues and pull
  requests read better when they use these terms the way the code does.
- [`docs/adr/`](docs/adr/): the decisions that look strange from outside
  (the transport design especially) and the dead ends that led to them.
  Challenge them with evidence.
- [`AGENTS.md`](AGENTS.md): the working guide for people and coding agents
  alike: architecture, the load-bearing herdr, tmux, SSH and mosh facts, and
  the conventions. Coding agents are welcome contributors; the repository is
  structured for them.

The repository carries four deliverables: the app (`Sources/`, `Packages/`),
the Host Tools that render Pairing Codes and post notifications (`plugin/`, a
static Rust binary), the stateless Push Relay (`relay/`, dependency-free
Node), and the site at <https://waycar.dev> (`apps/web/`, Astro).

## Building and testing

Everything goes through `make`; `make help` lists the targets. The Xcode
project is generated from `project.yml` with XcodeGen
(`brew install xcodegen`), and every `make` build target regenerates it. CI
builds the *committed* `Waycar.xcodeproj`, so commit the regenerated project
with any `project.yml` change.

- `make sim` builds and runs the app on the simulator; `make test-app` runs
  the app suite, `make test` adds the `Packages/WaycarSSH` suites (through
  `scripts/run-waycarssh-package-tests.sh`, not `-only-testing`) and the
  SwiftMosh suite.
- One suite:
  `make test-app TEST_FLAGS='-only-testing:WaycarTests/<SuiteTypeName>'`.
  Use these entrypoints rather than plain `xcodebuild`: they prepare the
  simulator (accessibility on, software keyboard shown) and restore it after.
- Simulator targets lease their simulator through `scripts/sim-slot.py`, a
  queue for machines several checkouts share; on your own Mac it grants one
  at once. `make sim-status` shows it, `make sim-release` frees yours.
- `cargo test --locked` in `plugin/` for the Host Tools (CI also runs
  `cargo fmt --check` and
  `cargo clippy --locked --all-targets --all-features -- -D warnings`).
  `npm test` in `relay/` for the Push Relay (Node 20 or later, no install
  step), `npm ci && npm test` in `apps/web/` for the site.

Suites that need a real SSH server skip cleanly without their fixture. CI
(`.github/workflows/ci.yml`, GitHub-hosted macOS) provisions disposable sshd
instances and runs all of them; `make test-ci-app` runs the same app lane on
your Mac. It creates its own `Waycar CI` simulator, and with passwordless
sudo a temporary macOS account for the real-password tests
(`WAYCAR_CI_PASSWORD_FIXTURE=0` skips that one). Suites for a Linux test Host
(`scripts/testboxes/`, `make test-tmux-remote`) or the agent-harness lab
(`scripts/harness-lab/`, `make test-harness-lab`) run only where one is
configured.

Generated or shared files are never hand-edited:

- `Sources/Waycar/Transport/Generated/` comes from
  `scripts/generate-wire-types.py --schema scripts/herdr-schema.json`; CI
  fails on drift.
- `plugin/test-vectors/` is read by both the Swift and the Rust suites;
  change it in lockstep with both, and with
  `docs/agents/live-activity-contract.md` for the Live Activity vectors.
- Screenshots, the demo terminal frames and the brand tokens are generated
  (`make screenshots`, `scripts/demo-terminal/make_omp_frames.py`,
  `scripts/generate-brand-tokens.py`).

## Pull requests

- Swift 6 strict concurrency; no force unwraps or `try!` outside tests.
- Conventional Commits (`feat:`, `fix:`, `docs:`, …) with an imperative,
  lowercase subject; reference issues with `refs #<n>`.
- User-visible changes get a `CHANGELOG.md` entry under `[Unreleased]`,
  referencing the pull request. Entries are published verbatim at
  waycar.dev/changelog and in the app, so write them for users: no internal
  paths, ADR numbers or hostnames. Internal refactors and test work stay out.
- Any change to a file the plugin package ships (`plugin/bin`, `hooks`,
  `herdr-plugin.toml`, `install.sh`, the tmux pane-option vector, the Rust
  crate and its `Cargo.toml`, `Cargo.lock` and `rust-toolchain.toml`,
  `scripts/package-plugin.sh`, `scripts/build-plugin-binaries.sh`) bumps the
  plugin version in `plugin/herdr-plugin.toml` and `plugin/Cargo.toml`
  (+ `Cargo.lock`: `cargo update -p waycar --offline` in `plugin/`) and
  `WaycarPluginRequirement.currentVersion`: patch for fixes, minor for new
  behavior. An app change that relies on new plugin behavior also raises
  `WaycarPluginRequirement.minimumVersion`
  (`Sources/Waycar/Transport/WaycarPlugin.swift`).
  `scripts/check-plugin-version.sh` checks this in CI.
- Never hand-edit `MARKETING_VERSION`, write a release file, or create a
  version tag: the maintainers cut releases with `make publish`
  (`docs/guides/releasing.md`).
- Keys and secrets never appear in code, logs, fixtures or issues.

Issue and pull request numbers in commit messages, comments and docs from
before the open-source cut (and `WAY-<n>` ids) refer to the archived private
tracker; they are not links into this repository.

## License

Waycar is licensed under the Apache License 2.0 ([LICENSE](LICENSE)). By
contributing you agree that your contribution is licensed under the same
terms (Apache-2.0 section 5, inbound = outbound). There is no CLA. Waycar is
derived from Heeler; keep its attribution ([NOTICE](NOTICE)) intact.
