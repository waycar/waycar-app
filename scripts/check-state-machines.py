#!/usr/bin/env python3
"""Check that docs/design/state-machines.md indexes every state machine.

A state machine is a Swift type that conforms to `StateMachine` (the app,
its extensions and the local packages) or a Rust type with
`impl StateMachine for` (plugin/rust). The check fails when:

- a conforming type has no `### TypeName` entry in the doc's Index;
- an Index entry names a type that no longer conforms, or a `File:` that
  does not exist or does not declare the type;
- a Catalogue row points at a file that does not exist, or says
  `converted` for a type the Index does not have.

Declarations are read with comments and string literals blanked out, a
type's own inheritance clause only (never its `where` clause), and generic
brackets balanced, so nesting does not hide or invent a machine.

Runs on Linux and macOS with only the standard library:
`python3 scripts/check-state-machines.py` (from the repository root, or
pass `--root`). `make check-state-machines`, `make test-app` and
.github/workflows/state-machines.yml run it, after its regression tests in
scripts/test-check-state-machines.py.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

DOC = pathlib.Path("docs/design/state-machines.md")
SWIFT_ROOTS = ("Sources", "Packages")
RUST_ROOTS = ("plugin/rust",)

SWIFT_DECL = re.compile(r"\b(struct|enum|class|actor|extension)\s+([A-Za-z_][\w.]*)")
SWIFT_NOT_TYPES = {"func", "var", "let", "subscript", "init", "deinit", "case"}
SWIFT_TYPE = r"(?:struct|enum|class|actor)\s+{name}\b"
RUST_IMPL = re.compile(r"\bimpl\b")
RUST_TRAIT_FOR = re.compile(r"((?:\w+::)*StateMachine)\s+for\s+&?\s*((?:\w+::)*\w+)")
RUST_TYPE = r"(?:struct|enum)\s+{name}\b"
SWIFT_QUOTE = re.compile(r'(#*)"(?:"")?')
RUST_QUOTE = re.compile(r'r(#*)"')
RUST_CHAR = re.compile(r"'(?:\\u\{[0-9A-Fa-f]+\}|\\.|[^\\'\n])'")
WHERE = re.compile(r"where\b")
NOT_NEWLINE = re.compile(r"[^\n]")

INDEX_HEADING = re.compile(r"^###\s+`?(\w+)`?\s*$")
INDEX_FILE = re.compile(r"^-\s+\*\*File:\*\*\s+`([^`]+)`")
CATALOGUE_ROW = re.compile(r"^\|\s*([A-Z]+-\d+)\s*\|(.*)\|\s*$")


def comment_end(text: str, i: int) -> int | None:
    """The index after the comment starting at `i` (`//` to the end of the
    line, or a nested `/* … */`), or None when none starts there."""
    if text.startswith("//", i):
        end = text.find("\n", i)
        return len(text) if end < 0 else end
    if not text.startswith("/*", i):
        return None
    depth, j, n = 1, i + 2, len(text)
    while j < n and depth:
        if text.startswith("/*", j):
            depth, j = depth + 1, j + 2
        elif text.startswith("*/", j):
            depth, j = depth - 1, j + 2
        else:
            j += 1
    return j


def string_end(text: str, i: int, rust: bool) -> int | None:
    """The index after the string literal starting at `i`, or None when none
    starts there. Swift: `"…"`, `\"""…\"""`, `#"…"#` and interpolation (`\\(…)`,
    `\\#(…)` in a raw string), whose own comments and string literals are
    skipped too. Rust: `r#"…"#` (plain and byte strings are handled by the
    caller)."""
    quote = (RUST_QUOTE if rust else SWIFT_QUOTE).match(text, i)
    if not quote:
        return None
    hashes = quote.group(1)
    closing = ('"""' if not rust and quote.group(0).endswith('"""') else '"') + hashes
    escape = "\\" + hashes
    j, n = quote.end(), len(text)
    while j < n and not text.startswith(closing, j):
        if not rust and text.startswith(escape, j):
            j += len(escape)
            if text.startswith("(", j):
                depth, j = 1, j + 1
                while j < n and depth:
                    end = comment_end(text, j)
                    if end is None:
                        end = string_end(text, j, rust=False)
                    if end is not None:
                        j = end
                        continue
                    depth += {"(": 1, ")": -1}.get(text[j], 0)
                    j += 1
            else:
                j += 1
        elif rust and not hashes and text[j] == "\\":
            j += 2
        else:
            j += 1
    return min(n, j + len(closing))


def blank(text: str, rust: bool = False) -> str:
    """`text` with comments and string literals replaced by spaces (newlines
    kept), so a declaration inside either is never read as code. Block
    comments nest in both languages."""
    out: list[str] = []
    i, n = 0, len(text)

    def skip_to(end: int) -> None:
        nonlocal i
        out.append(NOT_NEWLINE.sub(" ", text[i:end]))
        i = end

    while i < n:
        if (end := comment_end(text, i)) is not None:
            skip_to(end)
        elif (end := string_end(text, i, rust)) is not None:
            skip_to(end)
        elif rust and (char := RUST_CHAR.match(text, i)):
            skip_to(char.end())
        elif rust and text[i] == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            skip_to(min(n, j + 1))
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def skip_generics(text: str, i: int) -> int:
    """The index after a balanced `<…>` starting at `i` (or `i` itself)."""
    while i < len(text) and text[i].isspace():
        i += 1
    if i >= len(text) or text[i] != "<":
        return i
    depth = 0
    while i < len(text):
        if text[i] == "<":
            depth += 1
        elif text[i] == ">" and text[i - 1] != "-":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return i


def inheritance(text: str, i: int) -> list[str]:
    """The inheritance clause after a Swift type name ending at `i`: its
    top-level entries, stopping at `where` or `{`."""
    i = skip_generics(text, i)
    while i < len(text) and text[i].isspace():
        i += 1
    if i >= len(text) or text[i] != ":":
        return []
    entries, current, depth = [], [], 0
    for j in range(i + 1, len(text)):
        c = text[j]
        if depth == 0 and (c == "{" or WHERE.match(text, j) and not text[j - 1].isalnum()):
            break
        if c in "<([":
            depth += 1
        elif c in ">)]" and not (c == ">" and text[j - 1] == "-"):
            depth -= 1
        if c == "," and depth == 0:
            entries.append("".join(current))
            current = []
        else:
            current.append(c)
    entries.append("".join(current))
    return [re.sub(r"^(?:@\w+\s*)*", "", entry.strip()) for entry in entries]


def conforms(entries: list[str]) -> bool:
    return any(entry == "StateMachine" or entry.endswith(".StateMachine") for entry in entries)


def swift_machines(text: str) -> list[str]:
    """Names of the Swift types in `text` that conform to StateMachine."""
    if "StateMachine" not in text:
        return []
    names = []
    for match in SWIFT_DECL.finditer(blank(text)):
        name = match.group(2)
        if name in SWIFT_NOT_TYPES or name == "StateMachine":
            continue
        if conforms(inheritance(match.string, match.end())):
            names.append(name.split(".")[-1])
    return names


def rust_machines(text: str) -> list[str]:
    """Names of the Rust types in `text` with `impl StateMachine for`."""
    if "StateMachine" not in text:
        return []
    code = blank(text, rust=True)
    names = []
    for match in RUST_IMPL.finditer(code):
        rest = code[skip_generics(code, match.end()):].lstrip()
        trait = RUST_TRAIT_FOR.match(rest)
        if trait and trait.group(1).split("::")[-1] == "StateMachine":
            names.append(trait.group(2).split("::")[-1])
    return names


def find_machines(root: pathlib.Path) -> dict[str, pathlib.Path]:
    """Every conforming type, by name, with the file that declares it."""
    machines: dict[str, pathlib.Path] = {}
    for top in SWIFT_ROOTS:
        for path in sorted((root / top).rglob("*.swift")):
            if "/.build/" in path.as_posix() or "/Generated/" in path.as_posix():
                continue
            for name in swift_machines(path.read_text(encoding="utf-8", errors="replace")):
                machines.setdefault(name, path.relative_to(root))
    for top in RUST_ROOTS:
        for path in sorted((root / top).rglob("*.rs")):
            for name in rust_machines(path.read_text(encoding="utf-8", errors="replace")):
                machines.setdefault(name, path.relative_to(root))
    return machines


def section(lines: list[str], title: str) -> list[str]:
    """The lines of the `## <title>` section, up to the next `## `."""
    start = next((i for i, line in enumerate(lines) if line.strip() == f"## {title}"), None)
    if start is None:
        return []
    end = next(
        (i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines)
    )
    return lines[start + 1 : end]


def declares(root: pathlib.Path, file: str, name: str) -> bool:
    path = root / file
    if not path.is_file():
        return False
    pattern = RUST_TYPE if path.suffix == ".rs" else SWIFT_TYPE
    return re.search(pattern.format(name=re.escape(name)), path.read_text(encoding="utf-8")) is not None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=pathlib.Path, default=pathlib.Path.cwd())
    return run(parser.parse_args().root.resolve())


def run(root: pathlib.Path) -> int:
    """Checks the tree at `root`; prints problems to stderr, returns 0 or 1."""
    doc = root / DOC
    if not doc.is_file():
        print(f"error: {DOC} is missing", file=sys.stderr)
        return 1
    lines = doc.read_text(encoding="utf-8").splitlines()
    errors: list[str] = []

    index: dict[str, str | None] = {}
    current: str | None = None
    for line in section(lines, "Index"):
        if heading := INDEX_HEADING.match(line):
            current = heading.group(1)
            index[current] = None
        elif current and (file := INDEX_FILE.match(line)):
            index[current] = file.group(1)

    machines = find_machines(root)
    for name, path in sorted(machines.items()):
        if name not in index:
            errors.append(
                f"{path}: `{name}` conforms to StateMachine but has no `### {name}` entry "
                f"in the Index of {DOC}"
            )
    for name, file in sorted(index.items()):
        if file is None:
            errors.append(f"{DOC}: Index entry `{name}` has no `- **File:** `path`` line")
        elif not declares(root, file, name):
            errors.append(f"{DOC}: Index entry `{name}` names {file}, which does not declare it")
        elif name not in machines:
            errors.append(f"{DOC}: Index entry `{name}` does not conform to StateMachine")

    for line in section(lines, "Catalogue"):
        row = CATALOGUE_ROW.match(line)
        if not row:
            continue
        cells = [cell.strip() for cell in row.group(2).split("|")]
        for file in re.findall(r"`([^`]+\.(?:swift|rs|sh))`", " ".join(cells)):
            if not (root / file).is_file():
                errors.append(f"{DOC}: Catalogue row {row.group(1)} names {file}, which does not exist")
        converted = re.search(r"\bconverted\b.*?`(\w+)`", " ".join(cells[2:]))
        if converted and converted.group(1) not in index:
            errors.append(
                f"{DOC}: Catalogue row {row.group(1)} is converted to `{converted.group(1)}`, "
                f"which the Index does not have"
            )

    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    if errors:
        print(
            f"\n{len(errors)} problem(s). Add or fix the entries in {DOC} "
            "(its Convention section shows the entry format).",
            file=sys.stderr,
        )
        return 1
    print(f"state machines: {len(machines)} indexed, catalogue paths exist")
    return 0


if __name__ == "__main__":
    sys.exit(main())
