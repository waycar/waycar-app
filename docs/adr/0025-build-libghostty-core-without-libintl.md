---
status: accepted
---

# Build the libghostty core ourselves, without GNU gettext

This amends ADR 0022, which kept upstream's prebuilt `GhosttyKit.xcframework`
as the native core. Every Apple build of Ghostty statically links GNU gettext
(libintl, LGPL-2.1+): `src/build/SharedDeps.zig` adds it for any Darwin target,
whether or not `-Di18n` is on, and libghostty-spm's release asset ships it in
every slice. A statically linked LGPL library obliges us to let users relink
the app (LGPL-2.1 §6), which App Store distribution of a closed app cannot
offer.

Waycar builds the core itself with
`Packages/GhosttyTerminal/Scripts/build-libghostty.sh`, pinned by commit to
the inputs of the release we already ship: libghostty-spm `7e45d27` (tag
`1.6.20260909`) for its build scripts and Ghostty patch set, Ghostty
`82938b6`, and Zig 0.16.0. The Apple SDK is the selected Xcode's (27.0 for
the first build), not upstream's CI image; the objects still declare iOS 15.0
as their minimum, as upstream's do. Two things differ on purpose:

- `-Di18n=false`, so Ghostty's own code no longer calls gettext. On iOS its
  strings were English anyway: `_()` returns the English text and the locale
  name is copied as is.
- `Scripts/0100-gate-libintl-on-i18n.patch`, one block in `SharedDeps.zig`, so
  libintl is not built or bundled when i18n is off. Without it the objects
  would stay in the archive, unreferenced but still redistributed in the
  published zip.

The script fails unless all six slices are present and none has gettext
members or symbols, and prints the SwiftPM checksum. The zip keeps upstream's
slices and headers, so the Swift layer and its patches are unchanged. The zip
is published as a release asset of the public repository
[otreva/ghosttykit](https://github.com/otreva/ghosttykit) (first release
`1.6.20260909-82938b6-nointl.1`), together with the build scripts, the patch
and `LICENSES/`, and `Package.swift`'s `libghostty` binary target points at
it with its checksum.

Publishing the zip makes Waycar a distributor of everything in it, so the
script also writes `LICENSES/`, published beside the zip. One component
there is copyleft: **z2d** 0.12.1 (MPL-2.0), which Ghostty uses to draw box
and sprite glyphs and which stays linked into the app. MPL-2.0 is file-level
copyleft, so linking it is fine as long as recipients are told where its
source is: the notice carries the MPL-2.0 text and the source link
(`https://deps.files.ghostty.org/z2d-7dbae85c81784dba9988320bf9543ed9a81350c8.tar.gz`),
both in `LICENSES/` and in the app's Acknowledgements. No GPL or LGPL code
remains in the core.

## Considered Options

- **Wait for upstream** — no Ghostty or libghostty-spm release drops libintl,
  and neither project tracks it. An upstream fix is still worth offering: if
  it lands, a later update can go back to upstream's asset.
- **Keep libintl and meet LGPL-2.1 §6** — rejected: it means publishing
  Waycar's object files and build steps for every release, and an App Store
  user cannot swap a library in a signed app anyway.

## Consequences

- Each libghostty update now means rebuilding with the script at the new
  pins (and checking the patch still applies and the license pins match),
  not just copying a URL and checksum. The build takes about 30 minutes.
- The zip must be hosted where SwiftPM can fetch it without credentials; the
  app repository was private when this was decided (ADR 0033 opened it
  later), so it lives in the public `otreva/ghosttykit`, one release per
  build.
- `PROVENANCE.md` records the pins, the patch and the checksum.
