#!/usr/bin/env python3
"""Write plugin/THIRD-PARTY-LICENSES: the license text of every crate the
`waycar` binary can link, for the tarball (package-plugin.sh ships it).

    scripts/plugin-licenses.py            rewrite the file
    scripts/plugin-licenses.py --check    fail when the file is out of date

The crates are the normal (not build or dev) dependencies of plugin/Cargo.toml
for the four release targets, as `cargo tree` resolves them from Cargo.lock;
the text comes from each crate's own license files in the cargo registry
(`cargo fetch --locked` first). A crate with no license file fails the run:
add its text by hand to scripts/plugin-licenses-extra/<crate>.txt.
Committed port and toolchain notices in scripts/plugin-licenses-extra/runtime/
are appended in filename order; --check covers these texts too. See that
folder's parent README for pinned sources and refresh instructions.
"""

import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "plugin"
OUTPUT = PLUGIN / "THIRD-PARTY-LICENSES"
EXTRA = Path(__file__).resolve().parent / "plugin-licenses-extra"
TARGETS = [
    "x86_64-unknown-linux-musl",
    "aarch64-unknown-linux-musl",
    "aarch64-apple-darwin",
    "x86_64-apple-darwin",
]
LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING|UNLICENSE|NOTICE)", re.IGNORECASE)
HEADER = """Third-party software in the waycar binary

The `waycar` binary statically links the Rust crates listed below. Each group
names the crates that carry the license text that follows it. The crates are the
ones Cargo.lock pins for plugin/Cargo.toml's normal dependencies; the text is
copied from each crate's own license files. Ported code and the statically
linked toolchain/runtime components are covered by the additional notices
at the end (including the Rust standard library and Linux musl libc).
"""


def run(*args):
    return subprocess.run(
        args, cwd=PLUGIN, check=True, capture_output=True, text=True
    ).stdout


def crates():
    """(name, version) of every normal dependency on any release target."""
    found = set()
    for target in TARGETS:
        out = run(
            "cargo", "tree", "--locked", "-e", "normal", "--prefix", "none",
            "--target", target, "--format", "{p}",
        )
        for line in out.splitlines():
            match = re.match(r"^(\S+) v(\S+)", line)
            if match and match.group(1) != "waycar":
                found.add((match.group(1), match.group(2)))
    return sorted(found)


def license_texts(name, version, packages):
    package = packages[(name, version)]
    directory = Path(package["manifest_path"]).parent
    files = sorted(
        path for path in directory.iterdir()
        if path.is_file() and LICENSE_FILE.match(path.name)
    )
    extra = sorted(EXTRA.glob(f"{name}*.txt")) if EXTRA.is_dir() else []
    texts = [path.read_text(encoding="utf-8").strip() for path in files + extra]
    if not texts:
        sys.exit(f"plugin-licenses: {name} {version} ships no license file")
    return texts


def render():
    metadata = json.loads(run("cargo", "metadata", "--locked", "--format-version", "1"))
    packages = {(p["name"], p["version"]): p for p in metadata["packages"]}
    groups = defaultdict(list)
    for name, version in crates():
        for text in license_texts(name, version, packages):
            groups[text].append(f"{name} {version} ({packages[(name, version)]['license']})")
    out = [HEADER]
    # Biggest group first, then by text: a stable order for the check.
    for text, owners in sorted(groups.items(), key=lambda item: (-len(item[1]), item[0])):
        out.append("=" * 78)
        out.append("\n".join(sorted(set(owners))))
        out.append("-" * 78)
        out.append(text)
        out.append("")
    for path in sorted((EXTRA / "runtime").glob("*.txt")):
        out.append("=" * 78)
        out.append(path.read_text(encoding="utf-8").strip())
        out.append("")
    return "\n".join(out) + "\n"


def main():
    text = render()
    if "--check" in sys.argv[1:]:
        current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""
        if current != text:
            sys.exit("plugin-licenses: plugin/THIRD-PARTY-LICENSES is out of date; run scripts/plugin-licenses.py")
        return
    OUTPUT.write_text(text, encoding="utf-8")
    print(f"wrote {OUTPUT.relative_to(ROOT)} ({len(text)} bytes)")


if __name__ == "__main__":
    main()
