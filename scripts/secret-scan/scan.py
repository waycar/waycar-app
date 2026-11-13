#!/usr/bin/env python3
"""Scan a tree for material that must not be published.

    scan.py [--rules FILE] [--allow FILE] [--no-external] DIR
    scan.py --inventory [--rules FILE] [--allow FILE] DIR

Checks every text file's content and every file's path in DIR against the
rules in scan-rules.tsv beside this script (IPv4 ranges, key material and,
with a fuller rule file, names, emails, phone numbers, ...). A hit is allowed
when a line of scan-allow.tsv names its rule (or *), a glob matching its
path, and a regex matching the hit in full. Prints one line per finding and
exits 1 when there is any; secrets are redacted. Without --no-external it
also runs gitleaks (`gitleaks dir`, with DIR/.gitleaks.toml when there is
one) and trufflehog (`trufflehog filesystem`, skipping the path regexes in
trufflehog-exclude.txt beside this script) when they are on PATH, and fails
on their findings.

--inventory prints, per rule and top-level area, how many hits there are and
how many of them the allowlist covers (a markdown table), and exits 0.
Binary files (a NUL byte, or not UTF-8) are only name-checked.
"""

from __future__ import annotations

import argparse
import fnmatch
import ipaddress
import os
import re
import shutil
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
IPV4 = re.compile(r"(?<![\w.])((?:\d{1,3}\.){3}\d{1,3})(?!\.?\d)(?![A-Za-z_])")
# Never findings: loopback, unspecified, link-local, broadcast, RFC 5737.
ALWAYS_OK = [ipaddress.ip_network(n) for n in (
    "127.0.0.0/8", "0.0.0.0/8", "169.254.0.0/16", "255.255.255.255/32",
    "192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24",
)]
MAX_BYTES = 20 * 1024 * 1024


@dataclass
class Rule:
    id: str
    kind: str
    severity: str
    pattern: str
    description: str
    regex: re.Pattern | None = None
    networks: list = field(default_factory=list)


@dataclass
class Allow:
    rule: str
    glob: str
    match: re.Pattern | None
    reason: str
    used: int = 0


def read_tsv(path: Path, columns: int) -> list[list[str]]:
    rows = []
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cells = line.split("\t")
        if len(cells) != columns:
            sys.exit(f"{path}:{number}: expected {columns} tab-separated columns, got {len(cells)}")
        rows.append(cells)
    return rows


def load_rules(path: Path) -> list[Rule]:
    rules = []
    for rule_id, kind, severity, pattern, description in read_tsv(path, 5):
        rule = Rule(rule_id, kind, severity, pattern, description)
        if severity not in ("fail", "secret", "info"):
            sys.exit(f"{path}: rule {rule_id}: unknown severity {severity}")
        if kind in ("regex", "name"):
            rule.regex = re.compile(pattern)
        elif kind == "ipv4":
            rule.networks = [ipaddress.ip_network(cidr) for cidr in pattern.split(",")]
        elif kind != "ipv4-public":
            sys.exit(f"{path}: rule {rule_id}: unknown kind {kind}")
        rules.append(rule)
    return rules


def load_allow(path: Path) -> list[Allow]:
    entries = []
    for rule, glob, match, reason in read_tsv(path, 4):
        if not reason.strip():
            sys.exit(f"{path}: allow entry for {rule} {glob} has no reason")
        entries.append(Allow(rule, glob, None if match in ("", "*") else re.compile(match), reason))
    return entries


def is_text(data: bytes) -> str | None:
    if b"\0" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def ip_hits(rule: Rule, text: str):
    for match in IPV4.finditer(text):
        try:
            address = ipaddress.IPv4Address(match.group(1))
        except ipaddress.AddressValueError:
            continue
        if any(address in network for network in ALWAYS_OK):
            continue
        if rule.kind == "ipv4":
            hit = any(address in network for network in rule.networks)
        else:
            hit = address.is_global and not address.is_multicast
        if hit:
            yield match.start(1), match.group(1)


def hits_in(rule: Rule, path: str, text: str | None):
    if rule.kind == "name":
        for match in rule.regex.finditer(path):
            yield 0, match.group(0)
        return
    if text is None:
        return
    if rule.kind == "regex":
        for match in rule.regex.finditer(text):
            yield match.start(), match.group(0)
    else:
        yield from ip_hits(rule, text)


def allowed(entries: list[Allow], rule: Rule, path: str, hit: str) -> bool:
    for entry in entries:
        if entry.rule not in ("*", rule.id):
            continue
        if not fnmatch.fnmatchcase(path, entry.glob):
            continue
        if entry.match is not None and not entry.match.fullmatch(hit):
            continue
        entry.used += 1
        return True
    return False


def redact(hit: str) -> str:
    return hit[:4] + "…" if len(hit) > 4 else "…"


def walk(root: Path):
    for directory, subdirs, files in os.walk(root):
        subdirs[:] = sorted(d for d in subdirs if d != ".git")
        for name in sorted(files):
            full = Path(directory, name)
            yield full, full.relative_to(root).as_posix()


def scan(root: Path, rules: list[Rule], entries: list[Allow]):
    """Yield (rule, path, line, hit, allowed) for every hit in the tree."""
    for full, path in walk(root):
        text = None
        if full.is_file() and not full.is_symlink() and full.stat().st_size <= MAX_BYTES:
            text = is_text(full.read_bytes())
        for rule in rules:
            for offset, hit in hits_in(rule, path, text):
                line = text.count("\n", 0, offset) + 1 if text is not None and rule.kind != "name" else 0
                yield rule, path, line, hit, allowed(entries, rule, path, hit)


def external_tools(root: Path) -> int:
    """Run gitleaks and trufflehog when installed; return how many failed."""
    failed = 0
    if shutil.which("gitleaks"):
        command = ["gitleaks", "dir", str(root), "--redact", "--no-banner", "--exit-code", "1"]
        config = root / ".gitleaks.toml"
        if config.is_file():
            command += ["--config", str(config)]
        print(f"scan: running {' '.join(command[:2])}" + (f" --config {config}" if config.is_file() else ""),
              file=sys.stderr)
        result = subprocess.run(command)
        if result.returncode != 0:
            print(f"scan: gitleaks reported findings (exit {result.returncode})")
            failed += 1
    else:
        print("scan: gitleaks not on PATH, skipped", file=sys.stderr)
    if shutil.which("trufflehog"):
        command = ["trufflehog", "filesystem", str(root), "--no-verification", "--no-update", "--fail", "--json"]
        # Path regexes, one per line, of files whose only hits are known fakes.
        exclude = HERE / "trufflehog-exclude.txt"
        if exclude.is_file():
            command += ["--exclude-paths", str(exclude)]
        print("scan: running trufflehog filesystem (no verification, no network)", file=sys.stderr)
        result = subprocess.run(command, stdout=subprocess.PIPE, text=True)
        if result.returncode != 0 or result.stdout.strip():
            findings = [line for line in result.stdout.splitlines() if line.strip()]
            print(f"scan: trufflehog reported {len(findings)} finding(s) (exit {result.returncode})")
            failed += 1
    else:
        print("scan: trufflehog not on PATH, skipped", file=sys.stderr)
    return failed


def inventory(root: Path, rules: list[Rule], entries: list[Allow]) -> None:
    counts = defaultdict(lambda: [0, 0])
    for rule, path, _line, _hit, ok in scan(root, rules, entries):
        area = path.split("/", 1)[0] if "/" in path else "(root files)"
        counts[(rule.id, area)][0] += 1
        counts[(rule.id, area)][1] += ok
    print("| Rule | Severity | Area | Hits | Allowed | Findings |")
    print("|---|---|---|---:|---:|---:|")
    for rule in rules:
        areas = sorted(area for rule_id, area in counts if rule_id == rule.id)
        if not areas:
            print(f"| {rule.id} | {rule.severity} | — | 0 | 0 | 0 |")
        for area in areas:
            hits, ok = counts[(rule.id, area)]
            findings = 0 if rule.severity == "info" else hits - ok
            print(f"| {rule.id} | {rule.severity} | {area} | {hits} | {ok} | {findings} |")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dir", type=Path)
    parser.add_argument("--rules", type=Path, default=HERE / "scan-rules.tsv")
    parser.add_argument("--allow", type=Path, default=HERE / "scan-allow.tsv")
    parser.add_argument("--inventory", action="store_true")
    parser.add_argument("--no-external", action="store_true", help="skip gitleaks and trufflehog")
    parser.add_argument("--unused-allow", action="store_true", help="also list allow entries nothing matched")
    args = parser.parse_args()
    if not args.dir.is_dir():
        parser.error(f"{args.dir} is not a directory")
    rules, entries = load_rules(args.rules), load_allow(args.allow)

    if args.inventory:
        inventory(args.dir, rules, entries)
        return 0

    findings = 0
    by_rule = defaultdict(int)
    for rule, path, line, hit, ok in scan(args.dir, rules, entries):
        if ok or rule.severity == "info":
            continue
        findings += 1
        by_rule[rule.id] += 1
        shown = redact(hit) if rule.severity == "secret" else hit
        print(f"{path}:{line}: [{rule.id}] {shown!r} ({rule.description})")
    if args.unused_allow:
        for entry in entries:
            if entry.used == 0:
                print(f"scan: unused allow entry: {entry.rule}\t{entry.glob}", file=sys.stderr)
    external = 0 if args.no_external else external_tools(args.dir)
    if findings:
        summary = ", ".join(f"{rule_id} {count}" for rule_id, count in sorted(by_rule.items()))
        print(f"scan: {findings} finding(s): {summary}")
    if findings or external:
        return 1
    print("scan: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
