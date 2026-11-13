#!/usr/bin/env bash
# Writes Sources/Waycar/Resources/WhatsNew.json for a local device build: one
# entry with a unique `id`, which a DEBUG build shows once whatever its build
# number (WhatsNewStore). Called by `make install NOTES=<file|auto>`, which
# restores the committed seed afterwards; never commit the result.
#
# Usage: scripts/write-local-whats-new.sh <notes-file|auto> <device-id> [output]
#   notes file: one `symbol|text` line per item, or plain text (symbol
#   `sparkles`); blank lines and `#` comments are skipped.
#   auto: `git log --no-merges` subjects since the sha last installed on
#   <device-id> (build/local-installs/<device-id>), else the last 20.
# Output defaults to the bundled WhatsNew.json; pass `-` for stdout.
set -euo pipefail

notes=${1:?usage: $0 <notes-file|auto> <device-id> [output]}
device=${2:?usage: $0 <notes-file|auto> <device-id> [output]}
root=$(git rev-parse --show-toplevel)
out=${3:-$root/Sources/Waycar/Resources/WhatsNew.json}
state="$root/build/local-installs/$device"

branch=$(git rev-parse --abbrev-ref HEAD)
sha=$(git rev-parse --short HEAD)
build=$(awk -F'"' '/CURRENT_PROJECT_VERSION: "/ && $2 ~ /^[0-9]+$/ { print $2; exit }' "$root/project.yml")
build=${BUILD_NUMBER:-$build}

if [[ $notes == auto ]]; then
    base=$(cat "$state" 2>/dev/null || true)
    if [[ -n $base ]] && git cat-file -e "$base^{commit}" 2>/dev/null; then
        lines=$(git log --no-merges --format=%s "$base..HEAD")
    else
        lines=$(git log --no-merges --format=%s -20)
    fi
    [[ -n $lines ]] || lines="No new commits since the last install"
else
    [[ -f $notes ]] || { echo "Notes file not found: $notes" >&2; exit 1; }
    lines=$(cat "$notes")
fi

NOTES_LINES=$lines BRANCH=$branch WORKTREE=$(basename "$root") SHA=$sha BUILD=$build \
ID="$branch@$sha-$(date -u +%Y%m%dT%H%M%SZ)" DATE=$(date +%F) OUT=$out python3 - <<'PY'
import json, os, sys
items = [{"symbol": "hammer.fill",
          "text": f"Local build: {os.environ['BRANCH']} ({os.environ['WORKTREE']}) @ {os.environ['SHA']}"}]
for line in os.environ["NOTES_LINES"].splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    symbol, sep, text = line.partition("|")
    if sep and symbol.strip() and " " not in symbol.strip() and text.strip():
        items.append({"symbol": symbol.strip(), "text": text.strip()})
    else:
        items.append({"symbol": "sparkles", "text": line})
doc = {"builds": [{"id": os.environ["ID"], "build": int(os.environ["BUILD"]),
                   "date": os.environ["DATE"], "items": items}]}
text = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
if os.environ["OUT"] == "-":
    sys.stdout.write(text)
else:
    with open(os.environ["OUT"], "w") as f:
        f.write(text)
PY
