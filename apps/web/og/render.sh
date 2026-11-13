#!/bin/sh
# Render the 1200x630 share cards into ../public/: home.html -> og.png (the
# default card, Layout.astro) and ipad.html -> og-ipad.png (/ipad), plus
# x-header.html -> x-header.png, the @waycardev X profile header, and the App
# Store creative assets (appstore-header.html, appstore-search.html) into
# output/app-store/creative/ (see the README there).
# The cards pull fonts, screenshots, and the icon from the repo, so rerun this
# after any of those change. Needs Google Chrome; the App Store assets also need
# python3 with Pillow to drop the alpha channel App Store Connect rejects.
#
# Chrome sometimes lingers after writing the screenshot, so each render runs in
# the background with its own throwaway profile and is killed once the PNG
# lands (or after 30 s).
set -eu
cd "$(dirname "$0")"
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

render() {
  in="$1"; out="$2"; size="${3:-1200,630}"; scale="${4:-1}"
  prof="$(mktemp -d "${TMPDIR:-/tmp}/waycar-og-chrome.XXXXXX")"
  rm -f "$out"
  "$chrome" \
    --headless=new --disable-gpu --hide-scrollbars --no-first-run --no-default-browser-check \
    --user-data-dir="$prof" --force-device-scale-factor="$scale" \
    --virtual-time-budget=3000 --allow-file-access-from-files \
    --window-size="$size" --screenshot="$out" "file://$PWD/$in" >/dev/null 2>&1 &
  i=0
  while [ ! -s "$out" ] && [ $i -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
  sleep 1
  pkill -f "user-data-dir=$prof" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$prof"
  [ -s "$out" ] || { echo "render failed: $in" >&2; exit 1; }
  echo "$out"
}

render home.html ../public/og.png
render ipad.html ../public/og-ipad.png
# X profile header (not served by the site; upload it on x.com/waycardev).
render x-header.html x-header.png 1500,500

# App Store creative assets: laid out at half size, rendered at 2x to Apple's
# template sizes (product page header 3840x1646, search results 3840x2560).
creative=../../../output/app-store/creative
mkdir -p "$creative"
render appstore-header.html "$creative/product-page-header.png" 1920,823 2
render appstore-search.html "$creative/search-results.png" 1920,1280 2
python3 - "$creative/product-page-header.png" "$creative/search-results.png" <<'EOF'
import sys
from PIL import Image
for path in sys.argv[1:]:
    Image.open(path).convert("RGB").save(path, optimize=True)
EOF
