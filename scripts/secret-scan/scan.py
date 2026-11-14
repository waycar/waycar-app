#!/usr/bin/env python3
"""Scan a tree for material that must not be published.

    scan.py [--rules FILE] [--allow FILE] [--no-external] DIR
    scan.py --inventory [--rules FILE] [--allow FILE] DIR
    scan.py --commits REV [--exclude REV ...] [--gitleaks-config FILE] [--no-external]

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

--commits scans history instead of a tree, in the current repository: every
commit reachable from REV and not from an --exclude REV (default
--remotes=origin, what is already public) gets the files it adds or changes,
and its message as COMMIT_MSG, checked with the same rules and allowlist, so
content a later commit removed still fails. gitleaks and trufflehog then run
once over all of them (gitleaks with --gitleaks-config, the tip's
.gitleaks.toml). Findings are prefixed with the commit.
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
import tempfile
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


def git(*args: str, data: bytes | None = None) -> bytes:
    return subprocess.run(["git", *args], input=data, stdout=subprocess.PIPE, check=True).stdout


def write_commits(tip: str, exclude: list[str], out: Path) -> list[str]:
    """For each commit in tip --not exclude, write the files it adds or changes
    under out/<sha>/files/ and its message as out/<sha>/message/COMMIT_MSG."""
    shas = git("rev-list", "--reverse", tip, "--not", *exclude).decode().split()
    for sha in shas:
        files, message = out / sha / "files", out / sha / "message"
        files.mkdir(parents=True)
        message.mkdir()
        (message / "COMMIT_MSG").write_bytes(git("log", "-1", "--format=%B", sha))
        # --cc: a merge contributes only what differs from every parent (its
        # parents in the range are scanned on their own).
        changed = set(filter(None, git("diff-tree", "-r", "-z", "--root", "--cc", "--no-commit-id",
                                       "--name-only", "--diff-filter=AMCRT", sha).split(b"\0")))
        # The commit's own tree gives each path's type: a submodule (gitlink)
        # is a commit this repository usually lacks, so only blobs are read.
        for entry in filter(None, git("ls-tree", "-r", "-z", "--full-tree", sha).split(b"\0")):
            meta, _, raw = entry.partition(b"\t")
            _mode, kind, obj = meta.split()
            if raw in changed and kind == b"blob":
                target = files / raw.decode("utf-8", "surrogateescape")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(git("cat-file", "blob", obj.decode()))
    return shas


def report(root: Path, rules: list[Rule], entries: list[Allow], by_rule: dict, prefix: str = "") -> int:
    findings = 0
    for rule, path, line, hit, ok in scan(root, rules, entries):
        if ok or rule.severity == "info":
            continue
        findings += 1
        by_rule[rule.id] += 1
        shown = redact(hit) if rule.severity == "secret" else hit
        print(f"{prefix}{path}:{line}: [{rule.id}] {shown!r} ({rule.description})")
    return findings


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
    parser.add_argument("dir", type=Path, nargs="?")
    parser.add_argument("--commits", metavar="REV", help="scan each unpublished commit of REV instead of DIR")
    parser.add_argument("--exclude", action="append", metavar="REV",
                        help="with --commits: history already public (default --remotes=origin)")
    parser.add_argument("--gitleaks-config", type=Path, help="with --commits: gitleaks config for the commits' files")
    parser.add_argument("--rules", type=Path, default=HERE / "scan-rules.tsv")
    parser.add_argument("--allow", type=Path, default=HERE / "scan-allow.tsv")
    parser.add_argument("--inventory", action="store_true")
    parser.add_argument("--no-external", action="store_true", help="skip gitleaks and trufflehog")
    parser.add_argument("--unused-allow", action="store_true", help="also list allow entries nothing matched")
    args = parser.parse_args()
    rules, entries = load_rules(args.rules), load_allow(args.allow)
    findings = 0
    by_rule = defaultdict(int)

    if args.commits:
        with tempfile.TemporaryDirectory(prefix="scan-commits.") as temp:
            out = Path(temp)
            shas = write_commits(args.commits, args.exclude or ["--remotes=origin"], out)
            for sha in shas:
                for part in ("files", "message"):
                    findings += report(out / sha / part, rules, entries, by_rule, prefix=f"{sha[:12]}:")
            if args.gitleaks_config:
                shutil.copy(args.gitleaks_config, out / ".gitleaks.toml")
            external = 0 if args.no_external or not shas else external_tools(out)
            print(f"scan: {len(shas)} unpublished commit(s) of {args.commits}", file=sys.stderr)
    else:
        if args.dir is None or not args.dir.is_dir():
            parser.error(f"{args.dir} is not a directory")
        if args.inventory:
            inventory(args.dir, rules, entries)
            return 0
        findings = report(args.dir, rules, entries, by_rule)
        external = 0 if args.no_external else external_tools(args.dir)
    if args.unused_allow:
        for entry in entries:
            if entry.used == 0:
                print(f"scan: unused allow entry: {entry.rule}\t{entry.glob}", file=sys.stderr)
    if findings:
        summary = ", ".join(f"{rule_id} {count}" for rule_id, count in sorted(by_rule.items()))
        print(f"scan: {findings} finding(s): {summary}")
    if findings or external:
        return 1
    print("scan: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
