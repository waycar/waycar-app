#!/bin/sh
# Release check: the install.sh waycar.dev serves today carries a plugin
# version at least as new as every plugin version this build asks Hosts for.
# Run before any app submission (`make archive` runs it, and so do
# `make publish` and the TestFlight workflow, which both archive).
#
#   scripts/check-deployed-installer.sh
#
# Why: the app prompts a Host below WaycarPluginRequirement's
# nativeToolsMinimumVersion to update by running the installer from
# waycar.dev. If the site still serves an older plugin, the update would
# reinstall that older package, the prompt would stay, and the user would be
# left in a loop. The same goes for currentVersion, the plugin Host detail
# offers to a Host that meets its minimum ("2.3.0 available"). `scripts/check-plugin-version.sh` only proves the constant is
# not above the plugin in this checkout; this proves the plugin is deployed.
#
# Compares the numeric major.minor.patch of `version='X.Y.Z'` in the served
# installer with minimumVersion, nativeToolsMinimumVersion, coreMinimumVersion,
# zellijMinimumVersion and currentVersion (Sources/Waycar/Transport/WaycarPlugin.swift), and,
# where the Android app is present, MINIMUM_VERSION and
# NATIVE_TOOLS_MINIMUM_VERSION in its WaycarPluginRequirement.kt.
# INSTALL_SCRIPT_URL overrides the URL, and INSTALL_SCRIPT_FILE reads a local
# file instead of fetching (both for tests).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

fail() { echo "check-deployed-installer: $*" >&2; exit 1; }

requirement=Sources/Waycar/Transport/WaycarPlugin.swift
[ -f "$requirement" ] || fail "$requirement not found"
url=${INSTALL_SCRIPT_URL:-https://waycar.dev/install.sh}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if [ -n "${INSTALL_SCRIPT_FILE:-}" ]; then
  cp "$INSTALL_SCRIPT_FILE" "$tmp" || fail "cannot read $INSTALL_SCRIPT_FILE"
  url=$INSTALL_SCRIPT_FILE
else
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --max-time 60 "$url" -o "$tmp" \
    || fail "could not download $url"
fi

deployed=$(sed -n "s/^version='\([^']*\)'\$/\1/p" "$tmp" | sed -n 1p)
printf '%s' "$deployed" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
  || fail "no version='X.Y.Z' line in $url (found '$deployed')"

# Exit 0 when $1 <= $2, comparing major.minor.patch numerically; a
# prerelease suffix on either side is ignored, as the app does.
version_le() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    sub(/-.*/, "", a); sub(/-.*/, "", b)
    split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
    exit 0
  }'
}

for name in minimumVersion nativeToolsMinimumVersion coreMinimumVersion zellijMinimumVersion currentVersion; do
  required=$(sed -n "s/^[[:space:]]*static let $name = \"\([^\"]*\)\".*/\1/p" "$requirement")
  # currentVersion mirrors the plugin, which may carry a prerelease suffix.
  printf '%s' "$required" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
    || fail "no parseable 'static let $name = \"X.Y.Z\"' in $requirement (found '$required')"
  version_le "$required" "$deployed" \
    || fail "$url serves plugin $deployed, older than WaycarPluginRequirement.$name $required. Merge and deploy the plugin first; an app that asks Hosts for $required would reinstall $deployed and prompt again"
done

# The Android app's constants (apps/android is on the android-main lineage only).
android_requirement=apps/android/core/model/src/main/kotlin/com/otreva/waycar/model/WaycarPluginRequirement.kt
if [ -f "$android_requirement" ]; then
  for name in MINIMUM_VERSION NATIVE_TOOLS_MINIMUM_VERSION; do
    required=$(sed -n "s/^[[:space:]]*const val $name = \"\([^\"]*\)\".*/\1/p" "$android_requirement")
    printf '%s' "$required" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
      || fail "no parseable 'const val $name = \"X.Y.Z\"' in $android_requirement (found '$required')"
    version_le "$required" "$deployed" \
      || fail "$url serves plugin $deployed, older than Android WaycarPluginRequirement.$name $required. Merge and deploy the plugin first; an app that asks Hosts for $required would reinstall $deployed and prompt again"
  done
fi
echo "check-deployed-installer: $url serves plugin $deployed, at least every WaycarPluginRequirement minimum and currentVersion"
