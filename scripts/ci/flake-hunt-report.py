#!/usr/bin/env python3
"""One Markdown report for a flake hunt (.github/workflows/flake-hunt.yml).

Each argument is one job's folder from scripts/ci/flake-hunt.sh: `label`,
`passes`, `build.status` and `build.log`, then `pass-N.status` and
`pass-N.log` per pass. The report lists every test that recorded an issue,
with how many passes it failed in and its first message, then what each pass
ended with (a test host relaunch, crash reports, a timeout). Missing folders
and files are reported, never raised: the hunt never fails a run.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
# A GitHub job log's timestamp, so a downloaded job log reads like a pass log.
TIMESTAMP = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ?")
SWIFT_ISSUE = re.compile(
    r"✘ Test (?P<name>.+?) recorded an issue(?: with .+?)? at "
    r"(?P<file>[^\s:]+\.swift):(?P<line>\d+):\d+: (?P<message>.*)$")
XCTEST_ISSUE = re.compile(
    r"(?P<path>\S+\.swift):(?P<line>\d+): error: -\[\S+ (?P<name>[^\]]+)\] : (?P<message>.*)$")
RUN_SUMMARY = re.compile(r"Test run with (?P<tests>\d+) tests? in \d+ suites? (?P<result>passed|failed)")
RELAUNCH = re.compile(r"^Restarting after unexpected exit, crash, or test timeout")
CRASH_REPORTS = re.compile(r"^error: (?P<count>\d+) Waycar crash report\(s\) from this run")
TIMEOUT_STATUS = 124
MESSAGE_LIMIT = 160


@dataclass
class Failure:
    name: str
    where: str
    message: str
    passes: set[tuple[str, int]] = field(default_factory=set)


@dataclass
class Pass:
    number: int
    status: int | None
    tests: int | None = None
    issues: int = 0
    relaunches: int = 0
    crash_reports: int = 0

    def outcome(self) -> str:
        if self.status is None:
            return "did not run"
        if self.status == TIMEOUT_STATUS:
            return "timed out"
        parts = []
        if self.tests is not None:
            parts.append(f"{self.tests} tests")
        if self.issues:
            parts.append(f"{self.issues} issue(s)")
        if self.relaunches:
            parts.append(f"{self.relaunches} test host relaunch(es)")
        if self.crash_reports:
            parts.append(f"{self.crash_reports} crash report(s)")
        if self.status != 0 and not (self.issues or self.relaunches or self.crash_reports):
            parts.append(f"exit {self.status} with no test issue")
        return ", ".join(parts) or "passed"


@dataclass
class Job:
    label: str
    planned: int | None
    build_status: int | None
    build_tail: list[str]
    passes: list[Pass]


def read_text(path: Path) -> str | None:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return None


def read_int(path: Path) -> int | None:
    text = read_text(path)
    try:
        return int(text.strip()) if text is not None else None
    except ValueError:
        return None


def parse_pass(job: str, number: int, status: int | None, log: str,
               failures: dict[tuple[str, str], Failure]) -> Pass:
    result = Pass(number=number, status=status)
    for raw in log.splitlines():
        line = TIMESTAMP.sub("", ANSI.sub("", raw)).strip()
        if match := SWIFT_ISSUE.search(line):
            where = f"{match['file']}:{match['line']}"
        elif match := XCTEST_ISSUE.search(line):
            where = f"{Path(match['path']).name}:{match['line']}"
        else:
            if match := RUN_SUMMARY.search(line):
                result.tests = int(match["tests"])
            elif RELAUNCH.search(line):
                result.relaunches += 1
            elif match := CRASH_REPORTS.search(line):
                result.crash_reports += int(match["count"])
            continue
        result.issues += 1
        key = (match["name"], where)
        failure = failures.setdefault(
            key, Failure(name=match["name"], where=where, message=match["message"]))
        failure.passes.add((job, number))
    return result


def read_job(folder: Path, failures: dict[tuple[str, str], Failure]) -> Job:
    label = (read_text(folder / "label") or folder.name).strip() or folder.name
    planned = read_int(folder / "passes")
    build_status = read_int(folder / "build.status")
    build_log = read_text(folder / "build.log") or ""
    passes = []
    for number in range(1, (planned or 0) + 1):
        status = read_int(folder / f"pass-{number}.status")
        log = read_text(folder / f"pass-{number}.log") or ""
        passes.append(parse_pass(label, number, status, log, failures))
    tail = [line for line in build_log.splitlines() if "error:" in line][-5:]
    return Job(label, planned, build_status, tail, passes)


def cell(text: str) -> str:
    text = text if len(text) <= MESSAGE_LIMIT else text[: MESSAGE_LIMIT - 1] + "…"
    return text.replace("|", "\\|")


def report(folders: list[Path]) -> str:
    failures: dict[tuple[str, str], Failure] = {}
    jobs = [read_job(folder, failures) for folder in folders if folder.is_dir()]
    missing = [folder for folder in folders if not folder.is_dir()]
    ran = sum(1 for job in jobs for item in job.passes if item.status is not None)
    lines = [f"## Flake hunt: {len(failures)} failing test(s) in {ran} pass(es)", ""]
    if failures:
        lines += ["| Test | Where | Failed in | First issue |", "|---|---|---|---|"]
        ordered = sorted(failures.values(), key=lambda item: (-len(item.passes), item.where))
        for failure in ordered:
            spots = ", ".join(f"{job} #{number}" for job, number in sorted(failure.passes))
            lines.append(
                f"| `{cell(failure.name)}` | `{failure.where}` | {len(failure.passes)} of {ran} "
                f"({spots}) | {cell(failure.message)} |")
        lines.append("")
    lines += ["| Job | Pass | Outcome |", "|---|---|---|"]
    for job in jobs:
        if job.build_status != 0:
            detail = "; ".join(cell(line) for line in job.build_tail) or "see build.log"
            state = "did not run" if job.build_status is None else f"exit {job.build_status}"
            lines.append(f"| {job.label} | build | {state}: {detail} |")
            continue
        for item in job.passes:
            lines.append(f"| {job.label} | {item.number} | {item.outcome()} |")
    for folder in missing:
        lines.append(f"| {folder.name} | — | no results (the job did not upload any) |")
    if not jobs and not missing:
        lines.append("| — | — | no job folders given |")
    return "\n".join(lines) + "\n"


def main(arguments: list[str]) -> int:
    sys.stdout.write(report([Path(argument) for argument in arguments]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
