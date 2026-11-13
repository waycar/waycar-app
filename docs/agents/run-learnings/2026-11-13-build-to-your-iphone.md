# 2026-11-13 — Build to your own iPhone (`make install TEAM=…`)

- **Worked:** one project-level `WAYCAR_BUNDLE_ID` setting that every bundle
  ID, the Watch app's companion ID and the app group derive from, overridden
  on xcodebuild's command line only when `TEAM` is set; nothing reaches the
  Swift package targets.
- **Worked:** hand-written Info.plist and entitlements edits, then byte-compared
  with what `make generate` wrote on the Mac (mac_run deliverables): identical,
  so only the pbxproj needed the Mac.
- **Broke:** XcodeGen 2.46 always overwrites `CODE_SIGN_ENTITLEMENTS` with a
  target's `entitlements.path`, so a per-build entitlements swap needs the
  setting itself (`CODE_SIGN_ENTITLEMENTS: $(WAYCAR_APP_ENTITLEMENTS)`) and a
  hand-kept entitlements file.
- **Broke:** a personal-team build on the build Mac stopped at `No Accounts`:
  its Xcode has no Apple account signed in, and the maintainer's device builds
  only reuse existing profiles. `defaults read com.apple.dt.Xcode
  IDEProvisioningTeamByIdentifier` still listed the teams: it is a cache.
- **Broke:** App Store Connect key auth (`ASC_AUTH_FLAGS`, which mac_run's
  `~/.env` supplies) did not stand in for the account either: xcodebuild
  answered `Authentication failed: Make sure a bearer token was provided…`
  and fell back to the wildcard profile. So no new bundle ID can be
  provisioned on the build Mac until someone signs in to Xcode there.
- **Watch out:** mac_run passes only its own variables, so test a new make
  variable with a verification commit that sets its default, never landed.
