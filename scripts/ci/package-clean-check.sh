#!/bin/sh
# Fails when a Host Tools package still carries anything of the Node version.
#
#   scripts/ci/package-clean-check.sh <dist-dir>
#
# <dist-dir> is scripts/package-plugin.sh's output. Each of the four tarballs
# in <dist-dir>/plugin/ is unpacked and checked:
#
#   1. Files: no node, nodejs (a Node executable; the text check skips
#      binaries), node.sh, node_modules, package.json, package-lock.json,
#      *.node or top-level src/, and no *.js, *.mjs, *.cjs or *.ts outside
#      hooks/ (hooks/ holds the extensions that opencode, omp and pi load into
#      their own runtime; Waycar never runs them).
#   2. Text: `grep -rniI node` over the unpacked package. Every hit is printed
#      as file:line:text and has to be allowed by a rule below, or the check
#      fails. A line that would run Node is never allowed (the deny rules win).
#   3. Binaries (bin/waycar): the strings the Node launcher and bridge used
#      must be gone. The other "node" strings in a compiled binary are printed
#      for the record but do not fail: they are fragments of rustc's and the
#      C library's string tables (btree/node.rs, INODE64, run-together
#      messages) that change with every toolchain, so a list of them would
#      break on a compiler bump while saying nothing about Node.
#
# Allowed text hits, each with its reason:
#   hooks/**   `import ... from "node:child_process"` style lines and the
#              `NodeJS.Timeout` type: the extension runs inside opencode, omp
#              or pi, which are JavaScript programs, and uses the Node API of
#              that program. The Host Tools never start it.
#   anywhere   A line that says Node is absent: "no Node", "without Node",
#              "needs no Node", "Node is not required" and the like.
#   README.md  The upgrade notes about the Node version (plugin 1.x): what the
#              installer removes ("node-era", "node.sh", "node-versions",
#              "bridge-off"), the old Node processes it leaves running, the
#              user's own Node it never touches, and the remark that the
#              agents on a Host may be Node programs themselves. History and
#              scope, not a command; a README line that runs Node is denied.
#   THIRD-PARTY-LICENSES  The six lines of the notice for chat-read's port of
#              Node's util.parseArgs (scripts/plugin-licenses-extra/runtime/
#              01-node.txt), matched whole: credit for translated source,
#              not a Node runtime. Other lines there get only the rules above.
set -eu

dist=${1:?usage: scripts/ci/package-clean-check.sh <dist-dir>}
dist=$(cd "$dist" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail=0
bad() { echo "package-clean-check: FAIL: $*" >&2; fail=1; }

set -- "$dist"/plugin/waycar-*.tar.gz
[ "$#" = 4 ] || { echo "package-clean-check: expected 4 tarballs in $dist/plugin, found $#" >&2; exit 1; }

# awk program: reads grep's `./path:line:text`, prints the hits no rule allows.
rules='
function lower(s) { return tolower(s) }
{
  line = $0
  if (!match(line, /^\.\/[^:]+:[0-9]+:/)) { print line; next }
  prefix = substr(line, 1, RLENGTH)
  text = substr(line, RLENGTH + 1)
  path = substr(prefix, 3)
  sub(/:[0-9]+:$/, "", path)
  l = lower(text)

  # Deny: a line that runs Node, wherever it is.
  if (l ~ /(^|[^a-z])(sh|bash|exec) +(\.\/)?(bin\/)?node\.sh/ ||
      l ~ /(^|[^a-z.\/_-])node +(--[a-z-]+ +)?[a-z0-9_.\/-]*\.(m|c)?js/ ||
      l ~ /(^|[^a-z.\/_-])node +--(test|version|eval|check)/ ||
      l ~ /(^|[^a-z.\/_-])node +-[evpc]( |$)/ ||
      l ~ /(^|[^a-z])npm +(ci|test|run|install|exec)/ ||
      l ~ /(^|[^a-z.\/_-])npx /) { print line; next }

  # hooks/: the agents'"'"' own runtime.
  if (path ~ /^hooks\// && text ~ /^[ \t]*import .* from "node:[a-z_\/]+";?[ \t]*$/) next
  if (path ~ /^hooks\// && text ~ /NodeJS\.Timeout/) next

  # A line that says Node is absent.
  if (l ~ /(no|without|never|neither|nor|not need|needs no|does not need|doesn.t need|no longer needs?) +(a +|the +)?`?node/) next
  if (l ~ /node(\.js)? (is|are) (not|no longer) (needed|required|used)/) next

  # README upgrade notes and the line about the agents'"'"' own runtimes.
  if (path == "README.md" &&
      l ~ /node-era|node leftovers|node version|plugin 1\.x|node\.sh|node-versions|bridge-off|user.s own node|node processes|old node|node programs|^node\.js:/) next

  # The util.parseArgs port notice, line for line.
  if (path == "THIRD-PARTY-LICENSES" &&
      (text == "Node.js util.parseArgs port (MIT)" ||
       text == "Source reference: Node v24.0.0, c5349f43cd66d2aa02d86414c9ed426f71d3ae48" ||
       text == "https://github.com/nodejs/node/tree/c5349f43cd66d2aa02d86414c9ed426f71d3ae48/lib/internal/util/parse_args" ||
       text == "specialized for waycar chat-read. The notice below is from Node LICENSE;" ||
       text == "this is not a redistribution of the Node executable or its dependencies." ||
       text == "Copyright Node.js contributors. All rights reserved.")) next

  print line
}'

n=0
for tarball in "$@"; do
  n=$((n + 1))
  name=$(basename "$tarball")
  pkg=$work/$n
  mkdir -p "$pkg"
  tar -xzf "$tarball" -C "$pkg"
  [ -d "$pkg/waycar" ] || { bad "$name: no waycar/ directory"; continue; }
  cd "$pkg/waycar"
  echo "package-clean-check: $name"

  [ -s bin/waycar ] || bad "$name: bin/waycar is missing or empty"
  [ -s bin/waycar-hook ] || bad "$name: bin/waycar-hook is missing or empty"

  # 1. Files.
  files=$(find . \( -name node -o -name nodejs -o -name node.sh -o -name node_modules -o -name package.json -o -name package-lock.json -o -name '*.node' \) -print)
  [ -z "$files" ] || bad "$name carries Node files: $files"
  [ ! -e src ] || bad "$name carries src/"
  js=$(find . -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.ts' \) ! -path './hooks/*' -print)
  [ -z "$js" ] || bad "$name carries script files outside hooks/: $js"

  # 2. Text.
  grep -rniI node . >"$work/hits" || true
  total=$(wc -l <"$work/hits" | tr -d ' ')
  awk "$rules" "$work/hits" >"$work/denied"
  denied=$(wc -l <"$work/denied" | tr -d ' ')
  echo "package-clean-check:   $total text hits mentioning node, $((total - denied)) allowed, $denied not"
  if [ "$denied" != 0 ]; then
    cut -c1-240 "$work/denied" | sed 's/^\.\///' >&2
    bad "$name: $denied hit(s) mention Node and are not on the allowlist (printed above as file:line:text)"
  fi

  # 3. Binaries: the launcher's and bridge's strings, then the record.
  for needle in 'node\.sh' 'WAYCAR_NATIVE' 'WAYCAR_BRIDGE' 'bridge-off' 'node-versions' 'NODE_OPTIONS' 'NODE_PATH' '\.nvm' '\.volta' 'nodejs'; do
    if grep -aq -e "$needle" bin/waycar; then bad "$name: bin/waycar contains the string $needle"; fi
  done
  echo "package-clean-check:   bin/waycar: node-ish strings (for the record): $(grep -ao -i '[[:alnum:]_./:-]*node[[:alnum:]_./:-]*' bin/waycar | cut -c1-60 | sort -u | tr '\n' ' ')"
  cd "$work"
done

if [ "$fail" != 0 ]; then
  echo "package-clean-check: FAILED" >&2
  exit 1
fi
echo "package-clean-check: ok: 4 tarballs carry no Node"
