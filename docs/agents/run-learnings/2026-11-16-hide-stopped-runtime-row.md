# 2026-11-16 — Hide a stopped runtime's Console row

- **Worked:** a new app file needs `project.pbxproj` regenerated, and this
  host has no xcodegen, so the store went into an existing file
  (`WaycarPluginNotice.swift`, the Console notice answers) and nothing
  needed regenerating.
- **Watch out:** Console notice answers (plugin Not now, Host Tools offer,
  now the stopped-runtime Hide) are synced preferences, not device-local
  view state: register the key in `WaycarAppModel`'s `SyncedPreference` map
  with a `canRead`, and list it in the iCloud Sync help page.
