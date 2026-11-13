# Host Tools notice inputs

`scripts/plugin-licenses.py` generates `plugin/THIRD-PARTY-LICENSES` from the
four release targets' normal Cargo dependencies, then appends `runtime/*.txt`
in filename order. `--check` compares the **whole** result, including these
committed snapshots. No network or installed Zig/rust-src is needed for the
runtime append. The existing `<crate>*.txt` convention remains available for
registry packages lacking license files; runtime inputs live separately so
that they cannot accidentally match a crate name.

## Source pins and refresh

- **Node** (`runtime/01-node.txt`): source reference pinned to **v24.0.0**,
  `c5349f43cd66d2aa02d86414c9ed426f71d3ae48`,
  `lib/internal/util/parse_args/{parse_args.js,utils.js}`. The MIT text is
  the first grant in that revision's root `LICENSE` (the parse_args files
  have no separate license header). The Rust port arrived in
  `413263a326b34dc50817b3d319486028c28a390a`; its JS predecessor
  `plugin/src/chat-read.js` called `node:util`'s `parseArgs`. History records
  Node 24, not a patch revision: v24.0.0 is the explicit source-reference
  pin adopted here, not a claim that history identified the original
  developer's exact Node installation. The Rust tokenizer's `--` handling,
  string-option consumption, inline values and strict checks correspond to
  `argsToTokens`, `checkOptionLikeValue` and `checkOptionUsage` there. Only
  that port's grant is included, not the licenses of unrelated Node deps.
- **musl** (`runtime/02-musl.txt`): complete `lib/libc/musl/COPYRIGHT` from
  the checksum-pinned Zig **0.17.0** release used by
  `scripts/ci/provision-plugin-build.sh`. Its
  `lib/libc/musl/src/internal/version.h` defines **1.2.5**. Also retained:
  distinct leading copyright/permission comments from the source families
  named by COPYRIGHT (`src/regex`, `src/math`, `src/complex`,
  `src/string/arm`, `src/string/aarch64`, `src/crypt`, `src/stdlib/qsort.c`).
  This conservatively covers those families even where the linker discards
  individual functions. These comments are copied, not relicensed.
- **Rust** (`runtime/03-rust.txt`): toolchain **1.99.1**, rustc revision
  `58cf8f9c35b355199727627d07ae34a4e2846d67` (2026-10-13), from
  `rustc -vV`. Install `rust-src` with `cd plugin && rustup component add rust-src`.
  Resolve `S=$(cd plugin && rustc --print sysroot)`; the source is
  `$S/lib/rustlib/src/rust/library`. The inventory uses that directory's
  `Cargo.lock`, the target sysroot's `lib*.rlib` inputs, and the manifests
  for std/alloc/unwind/compiler-builtins. License texts come from the
  vendored packages' top-level license/NOTICE files, `backtrace/LICENSE-*`,
  `stdarch/LICENSE-*`, `compiler-builtins/LICENSE.txt`,
  `compiler-builtins/libm/LICENSE.txt` (the bundled math module's additional
  notice, in `runtime/03a-libm.txt`),
  `../src/llvm-project/libunwind/LICENSE.TXT`, and the toolchain's
  `share/doc/rust/licenses/Unicode-3.0.txt`. Rust root `LICENSE-MIT` and
  `LICENSE-APACHE` are copied at the above exact revision. In-tree Unicode,
  Crossbeam and Alex Crichton copyrights come from
  `$S/share/doc/rust/COPYRIGHT-library.html`; unrelated target/build/test
  dependencies in that HTML are not declared linked. All ten vendored
  runtime dependency versions are named beside their complete texts.
  `panic=abort` is the release profile; unwind support present in the
  prebuilt standard library is covered conservatively too.
- **Zig runtime** (`runtime/04-zig.txt`): Zig 0.17.0 release `LICENSE` and
  `lib/libunwind/LICENSE.TXT`, covering Zig compiler_rt, libzigc, UBSan
  runtime and libunwind support.
  This is not a declaration that the compiler itself is redistributed.
- **Darwin** (`runtime/05-darwin.txt`): system-library linkage statement.

When changing any toolchain pin, recheck the real link inputs and update
these snapshots from that toolchain, not from crates.io's latest versions.
When changing Node's port, recheck its source pin. Then run:

```sh
export PATH="$HOME/.cargo/bin:$PATH"
python3 scripts/plugin-licenses.py
python3 scripts/plugin-licenses.py --check
```

## Actual Linux libc linkage (2.3.2)

Verified both Linux release targets with cargo-zigbuild **0.24.0** and Zig
**0.17.0**, provisioned by the repository script. After building all four
release binaries, a temporary linker shim invoked each generated
cargo-zigbuild `zigcc-<target>-*.sh` wrapper with `-v` and captured stderr.
For each Linux target the probe was:

```sh
# CC_<target_with_underscores> points to that same generated zigcc wrapper.
cargo rustc --release --locked --target <target> --bin waycar -- \
  -C linker=<temporary-shim> --print link-args
```

Zig's **actual `ld.lld` invocation**, on both architectures, selected:

```text
-static ... <zig-cache>/crt1.o ...
<rust-sysroot>/lib/rustlib/<target>/lib/libcompiler_builtins-<hash>.rlib
<zig-cache>/libubsan_rt.a ... <zig-cache>/libunwind.a
<zig-cache>/libc.a <zig-cache>/libzigc.a <zig-cache>/libcompiler_rt.a
```

There was **no Rust self-contained libc or CRT input** in either real
linker invocation. cargo-zigbuild's `src/zig/linker_args.rs` removes the
self-contained CRT arguments and `-lc`; Zig supplies its own musl instead.
The musl version comes from the installed Zig source's version header,
not from the unrelated `libc` Rust crate. `readelf -l` on the Linux
executables showed no interpreter, consistent with the static link.
The Darwin executables contain `/usr/lib/libSystem.B.dylib` as a dynamic
load command (also system libcharset/libiconv), not bundled system code.

## Cargo.lock exclusions (2.3.2)

Verified with `cargo tree --locked -e normal --target <target>` in `plugin/`
for **each** of:

- `x86_64-unknown-linux-musl`
- `aarch64-unknown-linux-musl`
- `aarch64-apple-darwin`
- `x86_64-apple-darwin`

Each normal closure contains the same 47 dependency name/version pairs;
none of the audit's 21 X entries occurs in any of the four. "Excluded" here
means absent as a binary dependency; build tools may still run on the build
machine, and proc-macros can emit code without linking their implementation.

| Crate | Release targets linked | Reason excluded |
| --- | --- | --- |
| cc | None | ring build dependency |
| find-msvc-tools | None | cc build dependency |
| shlex | None | cc build dependency |
| proc-macro2 | None | unused serde_derive implementation dependency |
| quote | None | unused serde_derive implementation dependency |
| serde_derive | None | derive feature unselected; serde_core's cfg(any()) edge is never enabled |
| syn | None | unused serde_derive implementation dependency |
| unicode-ident | None | unused serde_derive implementation dependency |
| serde | None | optional dependency not selected; normal path uses serde_core |
| toml_writer | None | toml display feature disabled (parse-only) |
| wasi | None | getrandom's WASI-only dependency |
| windows-sys | None | Windows-only dependency |
| windows-targets | None | Windows-only dependency |
| windows_aarch64_gnullvm | None | Windows target library |
| windows_aarch64_msvc | None | Windows target library |
| windows_i686_gnu | None | Windows target library |
| windows_i686_gnullvm | None | Windows target library |
| windows_i686_msvc | None | Windows target library |
| windows_x86_64_gnu | None | Windows target library |
| windows_x86_64_gnullvm | None | Windows target library |
| windows_x86_64_msvc | None | Windows target library |
