#!/usr/bin/env bash
# Fails when an xcodebuild log contains a main-actor isolation warning: an
# `[#ActorIsolatedCall]` call or an untagged `main actor-isolated ...`
# property access (referenced or mutated from a nonisolated context,
# autoclosure, or Sendable closure).
#
# Helpers on SwiftUI `View` types inherit `View`'s `@preconcurrency @MainActor`
# isolation, so a synchronous call or property access from nonisolated code (a
# Swift Testing `@Test` on the cooperative pool, say) is only a warning, which
# neither -warnings-as-errors nor -Werror ActorIsolatedCall promotes. In Swift 6
# mode an isolation violation that only warns is a preconcurrency downgrade; at
# runtime an isolated closure it reaches traps in `dispatch_assert_queue`.
#
# Usage: scripts/check-actor-isolated-calls.sh [--touch] LOG...
# Prints each unique offending diagnostic as `file:line:col: warning: text`;
# a warning raised inside a macro expansion (`#expect`, `@Test`) is reported
# at the source line the expansion note names. Exits 1 if any were found, 0 if
# none, 2 on a usage error or an unreadable log. `--touch` also touches each
# offending source file: an incremental build prints warnings only for files it
# recompiles, so without it a plain rerun would pass the gate unfixed.
set -euo pipefail

touch_sources=0
if [[ ${1:-} == --touch ]]; then
    touch_sources=1
    shift
fi
if [[ $# -eq 0 ]]; then
    echo "usage: $0 [--touch] LOG..." >&2
    exit 2
fi
for log in "$@"; do
    [[ -f $log && -r $log ]] || { echo "Log not found: $log" >&2; exit 2; }
done

findings=$(awk '
    function isolated(line,    text) {
        if (line ~ /\[#ActorIsolatedCall\]$/) return 1
        text = line
        sub(/^.*:[0-9]+:[0-9]+: warning: /, "", text)
        return text ~ /^main actor-isolated /
    }
    function flush() {
        if (pending != "") print pending
        pending = ""
    }
    # CRLF logs and trailing blanks would defeat the end-anchored matches.
    { sub(/[[:space:]]+$/, "") }
    FNR == 1 { flush() }
    # A macro-expansion warning names its real site on the following line.
    pending != "" {
        if ($0 ~ /^`- \/.*:[0-9]+:[0-9]+: note: expanded code originates here/) {
            site = $0
            sub(/^`- /, "", site)
            sub(/: note: expanded code originates here.*/, "", site)
            macro = pending
            sub(/^macro expansion /, "", macro)
            sub(/:.*/, "", macro)
            text = pending
            sub(/^[^ ]+ [^:]+:[0-9]+:[0-9]+: /, "", text)
            print site ": " text " (in expansion of macro " macro ")"
            pending = ""
            next
        }
        flush()
    }
    /^\/.*:[0-9]+:[0-9]+: warning: / && isolated($0) { print; next }
    /^macro expansion [#@][^:]+:[0-9]+:[0-9]+: warning: / && isolated($0) {
        pending = $0
        next
    }
    END { flush() }
' "$@" | awk '!seen[$0]++')

if [[ -z $findings ]]; then
    exit 0
fi
printf '%s\n' "$findings"
if [[ $touch_sources == 1 ]]; then
    printf '%s\n' "$findings" | sed -E 's/:[0-9]+:[0-9]+: warning: .*//' | sort -u |
        while IFS= read -r source; do
            if [[ -f $source ]]; then touch "$source"; fi
        done
fi
exit 1
