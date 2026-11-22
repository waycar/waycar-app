#!/bin/sh
# After a site deploy: waycar.dev serves the install.sh this deploy built, and
# every package it names.
#
#   scripts/ci/check-live-installer.sh <the install.sh this deploy shipped>
#
# web.yml's deploy job runs it after `wrangler deploy` with dist/install.sh.
# The live file must be byte-identical. Each build's tarball names carry their
# own hash, so an identical file proves this deploy is the one serving, and
# the file's `version='X.Y.Z'` must be plugin/herdr-plugin.toml's. Then each
# of the four tarballs it names must download and match its sha256 line.
#
# Why: `wrangler deploy` succeeds once its upload lands, not once waycar.dev
# serves it. From 2026-11-20 to 11-22 the retired private repository's own
# daily web.yml deployed its frozen snapshot (plugin 2.6.0) to the same Worker,
# and whichever deploy finished last served; on 11-22 that put 2.6.0 back
# over main's 2.6.4 while every web.yml run here stayed green. This check fails
# a deploy that does not take effect, whatever serves instead. A deploy from
# elsewhere that lands after this check has passed is not watched here: the
# next deploy puts main's build back before it checks, and
# `scripts/check-deployed-installer.sh` (release gates) only catches a plugin
# older than the app's versions, if one still serves when it runs.
#
# Edge propagation takes seconds: the install.sh fetch is retried up to
# LIVE_CHECK_ATTEMPTS times (default 12), LIVE_CHECK_DELAY seconds apart
# (default 10). WAYCAR_SITE_URL overrides https://waycar.dev. Every fetch
# carries internal=1, so its analytics events count as ours.
set -eu

expected=${1:?usage: scripts/ci/check-live-installer.sh <install.sh>}
root=$(cd "$(dirname "$0")/../.." && pwd)
base=${WAYCAR_SITE_URL:-https://waycar.dev}
attempts=${LIVE_CHECK_ATTEMPTS:-12}
delay=${LIVE_CHECK_DELAY:-10}

fail() { echo "check-live-installer: $*" >&2; exit 1; }

version_of() { sed -n "s/^version='\([^']*\)'\$/\1/p" "$1" | sed -n 1p; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d ' ' -f 1
  else
    shasum -a 256 "$1" | cut -d ' ' -f 1
  fi
}

[ -s "$expected" ] || fail "$expected is missing or empty"
version=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$root/plugin/herdr-plugin.toml")
[ -n "$version" ] || fail "no version in plugin/herdr-plugin.toml"
[ "$(version_of "$expected")" = "$version" ] \
  || fail "$expected carries plugin '$(version_of "$expected")', not plugin/herdr-plugin.toml's $version"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

url="$base/install.sh?internal=1"
i=1
while :; do
  if curl -fsS --max-time 60 -H 'Cache-Control: no-cache' "$url" -o "$tmp/live.sh"; then
    cmp -s "$expected" "$tmp/live.sh" && break
    live=$(version_of "$tmp/live.sh")
    if [ "$live" = "$version" ]; then
      got="serves plugin $live from another build (other tarballs)"
    else
      got="serves plugin '$live', not $version"
    fi
  else
    got="could not be fetched"
  fi
  [ "$i" -lt "$attempts" ] || fail "$base/install.sh still $got after $attempts tries, so this deploy is not what waycar.dev serves. Something else deployed waycar-web after it, or serves in front of it: in apps/web, \`npx wrangler deployments list\` shows which version serves and \`npx wrangler versions list\` its message (web.yml's name their run)"
  echo "check-live-installer: try $i of $attempts: $base/install.sh $got; again in ${delay}s"
  i=$((i + 1))
  sleep "$delay"
done
echo "check-live-installer: $base/install.sh is this deploy's (plugin $version)"

for target in x86_64_linux aarch64_linux aarch64_darwin x86_64_darwin; do
  tarball=$(sed -n "s/^tarball_$target='\([^']*\)'\$/\1/p" "$expected")
  sum=$(sed -n "s/^sha256_$target='\([^']*\)'\$/\1/p" "$expected")
  [ -n "$tarball" ] && [ -n "$sum" ] || fail "no tarball_$target or sha256_$target line in $expected"
  curl -fsS --retry 3 --max-time 120 "$base/plugin/$tarball?internal=1" -o "$tmp/package" \
    || fail "$base/plugin/$tarball could not be downloaded"
  got=$(sha256_of "$tmp/package")
  [ "$got" = "$sum" ] || fail "$base/plugin/$tarball has sha256 $got; install.sh says $sum"
  echo "check-live-installer: $tarball matches its sha256"
done
