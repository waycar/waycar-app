# 2026-11-16 — Hide a stopped runtime's Console row

- **Worked:** a new app file needs `project.pbxproj` regenerated, and this
  host has no xcodegen, so the store went into an existing file
  (`WaycarPluginNotice.swift`, the Console notice answers) and nothing
  needed regenerating.
- **Worked:** UI proof for a Console row the demo never shows: a throwaway
  commit in a scratch worktree adds a demo launch flag (one Host's connect
  throws `.herdrNotRunning`), injects the store, adds one XCUITest to
  `ReadmeScreenshots`, and points `capture-screenshots.sh` at it with
  `exit 0` before the site copies and hero. `mac_run target: screenshots`
  with that `repo` and `deliverables: docs/images/screenshots/*/stopped-*.png`,
  then `scp mac:Desktop/...` to read the PNGs here.
- **Watch out:** Console notice answers (plugin Not now, Host Tools offer,
  now the stopped-runtime Hide) are synced preferences, not device-local
  view state: register the key in `WaycarAppModel`'s `SyncedPreference` map
  with a `canRead`, and list it in the iCloud Sync help page.
