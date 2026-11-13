<!--
Title: a Conventional Commits subject (`fix:`, `feat:`, `docs:` ...), imperative,
lowercase, describing the user-facing change.
Link the issue first: `refs #<n>` or `Closes #<n>`. Non-trivial and
agent-written changes need one; small fixes may go straight to a PR.
One change per PR.
-->

refs #

## Problem

<!-- What is wrong or missing, as a user or maintainer sees it. -->

## User impact

<!-- What changes for users, or "none" for internal work. -->

## Why this approach

<!-- Short: the approach you took and the main alternative you rejected. -->

## Evidence

<!--
Proof it works, not a promise:
- Commands you ran and their result (`make test-app TEST_FLAGS=...`, `cargo test --locked`, `npm test`).
- UI changes: screenshots or a recording on iPhone and, where layout matters, iPad.
- The device or simulator and OS you used.
-->

## Checklist

- [ ] One change in this PR, and the issue is linked
- [ ] The PR body is up to date with the final change (update it after review feedback, not only in a comment)
- [ ] User-visible change: `CHANGELOG.md` entry under `[Unreleased]`, written for users
- [ ] Plugin package file changed: plugin version bumped (`plugin/herdr-plugin.toml`, `plugin/Cargo.toml`, `Cargo.lock`, `WaycarPluginRequirement.currentVersion`)
- [ ] `project.yml` changed: regenerated `Waycar.xcodeproj` committed
- [ ] Generated files (wire types, demo terminal, brand tokens, screenshots) regenerated, not hand-edited
- [ ] No keys, tokens, host names or personal data in code, fixtures or screenshots
