#!/bin/bash
# Collects the license texts for everything compiled into GhosttyKit.xcframework
# into one LICENSES/ directory, to publish next to the zip (ADR 0025).
#
# Usage: Scripts/collect-libghostty-licenses.sh <ghostty-dir> <libghostty-spm-dir> <out-dir>
#   <ghostty-dir> is the pinned Ghostty checkout after a build, so its zig-pkg/
#   holds the fetched dependencies. Texts the dependency archives do not carry
#   are downloaded from pinned URLs and checked against their SHA-256.

set -euo pipefail

if [ $# -ne 3 ]; then
    echo "Usage: $0 <ghostty-dir> <libghostty-spm-dir> <out-dir>" >&2
    exit 1
fi

GHOSTTY_DIR=$(cd "$1" && pwd)
SPM_DIR=$(cd "$2" && pwd)
OUT_DIR=$3
PKG="$GHOSTTY_DIR/zig-pkg"

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# Zig package directories are named by content hash (pinned by Ghostty's
# build.zig.zon files), so each glob matches exactly one directory.
pkg_dir() {
    local matches=("$PKG"/$1)
    if [ ${#matches[@]} -ne 1 ] || [ ! -d "${matches[0]}" ]; then
        echo "[!] expected one package directory for $1 in $PKG" >&2
        exit 1
    fi
    echo "${matches[0]}"
}

copy() { # source destination-name
    if [ ! -f "$1" ]; then
        echo "[!] missing license file: $1" >&2
        exit 1
    fi
    cp "$1" "$OUT_DIR/$2"
}

fetch() { # url sha256 destination-name
    curl -fsSL -o "$OUT_DIR/$3" "$1"
    local actual
    actual=$(shasum -a 256 "$OUT_DIR/$3")
    if [ "${actual%% *}" != "$2" ]; then
        echo "[!] checksum mismatch for $1" >&2
        exit 1
    fi
}

FREETYPE=$(pkg_dir 'N-V-__8AAKLKpwC4H27Ps_0iL3bPkQb-z6ZVSrB-x_3EEkub')
HIGHWAY=$(pkg_dir 'N-V-__8AAGmZhABbsPJLfbqrh6JTHsXhY6qCaLAQyx25e0XE')
WUFFS=$(pkg_dir 'N-V-__8AAP5JWgCGP_AD0teWpa4krRvE9VPZzvviGdbmN4jI')

copy "$GHOSTTY_DIR/LICENSE" Ghostty-MIT.txt
copy "$SPM_DIR/LICENSE" libghostty-spm-MIT.txt
copy "$(pkg_dir 'libxev-0.0.0-86vtcwIRFADbH4hk-EjROXxlrKIRPQdA41XiTSytYO-F')/LICENSE" libxev-MIT.txt
copy "$(pkg_dir 'zig_objc-0.0.0-Ir_Sp9gsAQCPAJc0oF5xoWePHWP6Y6tCphDeyNUThJoi')/LICENSE" zig-objc-MIT.txt
copy "$(pkg_dir 'uucode-0.2.0-ZZjBPlK5VADj7fdoq7G8LIHzD5o6FSkcBXXrRWr4jnrA')/LICENSE.md" uucode-MIT.md
copy "$(pkg_dir 'N-V-__8AAHjwMQDBXnLq3Q2QhaivE0kE2aD138vtX2Bq1g7c')/COPYING" Oniguruma-BSD-2-Clause.txt
copy "$HIGHWAY/LICENSE" Highway-Apache-2.0.txt
copy "$HIGHWAY/LICENSE-BSD3" Highway-BSD-3-Clause.txt
copy "$WUFFS/LICENSE-APACHE" Wuffs-Apache-2.0.txt
copy "$WUFFS/LICENSE-MIT" Wuffs-MIT.txt
copy "$FREETYPE/docs/FTL.TXT" FreeType-FTL.txt
copy "$FREETYPE/src/bdf/README" FreeType-bdf-README.txt
copy "$FREETYPE/src/pcf/README" FreeType-pcf-README.txt
copy "$(pkg_dir 'N-V-__8AAIC5lwAVPJJzxnCAahSvZTIlG-HhtOvnM1uh-66x')/OFL.txt" JetBrainsMono-OFL-1.1.txt
copy "$GHOSTTY_DIR/vendor/nerd-fonts/LICENSE" SymbolsNerdFont-LICENSE.txt
copy "$(pkg_dir 'N-V-__8AAJrvXQCqAT8Mg9o_tk6m0yf5Fz-gCNEOKLyTSerD')/LICENSE" libpng-LICENSE.txt
copy "$(pkg_dir 'N-V-__8AAB0eQwD-0MdOEBmz7intriBReIsIDNlukNVoNu6o')/LICENSE" zlib-LICENSE.txt
# stb keeps its license at the end of stb_image.h.
sed -n '/^This software is available under 2 licenses/,$p' \
    "$GHOSTTY_DIR/src/stb/stb_image.h" >"$OUT_DIR/stb-MIT-or-Unlicense.txt"
if [ ! -s "$OUT_DIR/stb-MIT-or-Unlicense.txt" ]; then
    echo "[!] stb license text not found" >&2
    exit 1
fi

# Not carried by the dependency archives. z2d's Zig package leaves out its
# LICENSE (notices for code taken from Cairo, Pixman, tiny-skia and W3C) and
# COPYING (MPL-2.0), so both come from the pinned source tarball.
Z2D_TARBALL="$OUT_DIR/.z2d.tar.gz"
fetch https://deps.files.ghostty.org/z2d-7dbae85c81784dba9988320bf9543ed9a81350c8.tar.gz \
    e55c9d0b156edaddfea32fb1c0e3597e1b6306b9a4ec1888e2f8008c598bced8 .z2d.tar.gz
tar -xzOf "$Z2D_TARBALL" z2d-7dbae85c81784dba9988320bf9543ed9a81350c8/LICENSE >"$OUT_DIR/z2d-LICENSE.txt"
tar -xzOf "$Z2D_TARBALL" z2d-7dbae85c81784dba9988320bf9543ed9a81350c8/COPYING >"$OUT_DIR/z2d-MPL-2.0.txt"
rm -f "$Z2D_TARBALL"
fetch https://www.unicode.org/license.txt \
    e7a93b009565cfce55919a381437ac4db883e9da2126fa28b91d12732bc53d96 uucode-Unicode-3.0.txt
fetch https://raw.githubusercontent.com/simdutf/simdutf/v9.0.0/LICENSE-MIT \
    fc8dbc04e03ad4efc08a647ffe7f995b811a95bc04c0e85a56d5277c6593fa5f simdutf-MIT.txt
fetch https://raw.githubusercontent.com/simdutf/simdutf/v9.0.0/LICENSE-APACHE \
    3d34610fc6b5e1b0bfe4e2f36171c2d62c28ef05cb8d704f5a0073be41a43b3d simdutf-Apache-2.0.txt
fetch https://codeberg.org/ziglang/zig/raw/tag/0.16.0/LICENSE \
    5c537d6853e005298a285d508cff9ac7192cea23576c840d485b2b586a7ff177 Zig-MIT.txt

cat >"$OUT_DIR/README.txt" <<'EOF'
Third-party notices for GhosttyKit.xcframework.zip

This archive is libghostty, the terminal core of Ghostty
(https://github.com/ghostty-org/ghostty, commit
82938b633ba646db38591d969c3c526332bd7e65), built with the scripts of
libghostty-spm (https://github.com/Lakr233/libghostty-spm, release
1.6.20260909) and Zig 0.16.0, with internationalization turned off, so
GNU gettext is not included. It contains code from the projects below.
Each one's license text is in this directory.

- Ghostty: MIT (Ghostty-MIT.txt)
- libghostty-spm: MIT (libghostty-spm-MIT.txt)
- z2d 0.12.1, Copyright 2024-2026 Chris Marchesi: MPL-2.0 (z2d-LICENSE.txt,
  which also carries the notices for code z2d took from Cairo, Pixman,
  tiny-skia and W3C, and z2d-MPL-2.0.txt).
  Source code: https://deps.files.ghostty.org/z2d-7dbae85c81784dba9988320bf9543ed9a81350c8.tar.gz
  (upstream: https://github.com/vancluever/z2d)
- libxev: MIT (libxev-MIT.txt)
- zig-objc: MIT (zig-objc-MIT.txt)
- uucode 0.2.0: MIT (uucode-MIT.md); Unicode data: Unicode License v3
  (uucode-Unicode-3.0.txt)
- Zig 0.16.0 standard library and compiler_rt: MIT (Zig-MIT.txt)
- Oniguruma 6.9.9: BSD-2-Clause (Oniguruma-BSD-2-Clause.txt)
- simdutf 9.0.0: MIT or Apache-2.0 (simdutf-MIT.txt, simdutf-Apache-2.0.txt)
- Highway 1.2.0: Apache-2.0 or BSD-3-Clause (Highway-Apache-2.0.txt,
  Highway-BSD-3-Clause.txt)
- Wuffs 0.4.0-alpha.10: Apache-2.0 or MIT (Wuffs-Apache-2.0.txt, Wuffs-MIT.txt)
- FreeType 2.13.2: used under the FreeType License (FreeType-FTL.txt).
  Portions of this software are copyright (C) The FreeType Project
  (https://freetype.org). All rights reserved. The BDF and PCF drivers carry
  their own notices (FreeType-bdf-README.txt, FreeType-pcf-README.txt).
- JetBrains Mono 2.304: SIL Open Font License 1.1 (JetBrainsMono-OFL-1.1.txt)
- Symbols Nerd Font 3.4.0: MIT (SymbolsNerdFont-LICENSE.txt)
- libpng 1.6.43: libpng license (libpng-LICENSE.txt)
- zlib 1.3.1: zlib license (zlib-LICENSE.txt)
- stb: MIT or public domain (stb-MIT-or-Unlicense.txt)
EOF

echo "[*] licenses: $OUT_DIR ($(find "$OUT_DIR" -type f | wc -l | xargs) files)"
