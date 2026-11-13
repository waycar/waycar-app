## What and why

<!-- What this changes and the problem it solves. Link the issue: refs #<n>. -->

## How it was tested

<!-- Commands you ran (make test-app TEST_FLAGS=..., cargo test --locked, npm test) and what you checked by hand, on which device or simulator. -->

## Checklist

- [ ] User-visible change: `CHANGELOG.md` entry under `[Unreleased]`, written for users
- [ ] Plugin package file changed: plugin version bumped (`plugin/herdr-plugin.toml`, `plugin/Cargo.toml`, `Cargo.lock`, `WaycarPluginRequirement.currentVersion`)
- [ ] `project.yml` changed: regenerated `Waycar.xcodeproj` committed
- [ ] Generated files (wire types, demo terminal, brand tokens, screenshots) regenerated, not hand-edited
- [ ] No keys, tokens, host names or personal data in code, fixtures or screenshots
