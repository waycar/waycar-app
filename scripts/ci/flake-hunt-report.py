#!/usr/bin/env python3
"""One Markdown report for a flake hunt (.github/workflows/flake-hunt.yml).

Each argument is one job's folder from scripts/ci/flake-hunt.sh: `label` and
`passes`, a `<step>.status` and `<step>.log` per step (`pass-N` for each pass
of the full lane), and `stopped`, naming the setup step that ended the hunt
early. The report lists every failing test, grouped by test (the xcodebuild
`Failing tests:` list, so a test a crash ended counts too), with how many
passes it failed in and its first recorded issue, then what each pass ended
with. Missing folders and files are reported, never raised: the hunt never
fails a run.
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
    r"(?P<path>\S+\.swift):(?P<line>\d+): error: -\[(?P<suite>\S+) (?P<name>[^\]]+)\] : (?P<message>.*)$")
FAILING_HEADER = "Failing tests:"
OBJC_NAME = re.compile(r"^-\[(?P<suite>\S+) (?P<name>.+)\]$")
RUN_SUMMARY = re.compile(r"Test run with (?P<tests>\d+) tests? in \d+ suites? (?P<result>passed|failed)")
RELAUNCH = re.compile(r"^Restarting after unexpected exit, crash, or test timeout")
CRASH_REPORTS = re.compile(r"^error: (?P<count>\d+) Waycar crash report\(s\) from this run")
TIMEOUT_STATUS = 124
MESSAGE_LIMIT = 160


@dataclass
class Issue:
    suite: str
    name: str
    where: str
    message: str


@dataclass
class Failure:
    test: str
    first_issue: str | None
    passes: set[tuple[str, int]] = field(default_factory=set)


@dataclass
class Pass:
    number: int
    status: int | None
    tests: int | None = None
    failing: int = 0
    relaunches: int = 0
    crash_reports: int = 0

    def outcome(self) -> str:
        if self.status is None:
            return "did not run"
        parts = ["timed out"] if self.status == TIMEOUT_STATUS else []
        if self.tests is not None:
            parts.append(f"{self.tests} tests")
        if self.failing:
            parts.append(f"{self.failing} failing")
        if self.relaunches:
            parts.append(f"{self.relaunches} test host relaunch(es)")
        if self.crash_reports:
            parts.append(f"{self.crash_reports} crash report(s)")
        if self.status not in (0, TIMEOUT_STATUS) and not (
                self.failing or self.relaunches or self.crash_reports):
            parts.append(f"exit {self.status} with no failing test")
        return ", ".join(parts) or "passed"


@dataclass
class Job:
    label: str
    stopped: str | None
    stopped_status: int | None
    stopped_tail: list[str]
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


def test_identity(entry: str) -> str:
    """`Suite.test()` for both forms xcodebuild lists (`-[Suite test]` too)."""
    if match := OBJC_NAME.match(entry):
        return f"{match['suite']}.{match['name']}"
    return entry


def first_issue_for(test: str, issues: list[Issue], used: set[int]) -> str | None:
    """The first issue that names the test's function, else the first unused
    one from its suite's file (a display-named test prints its display name)."""
    suite, _, name = test.partition(".")
    for matches in (lambda issue: issue.name == name,
                    lambda issue: issue.suite == suite):
        for index, issue in enumerate(issues):
            if index not in used and matches(issue):
                used.add(index)
                return f"{issue.where}: {issue.message}"
    return None


def parse_pass(job: str, number: int, status: int | None, log: str,
               failures: dict[str, Failure]) -> Pass:
    result = Pass(number=number, status=status)
    issues: list[Issue] = []
    failing: list[str] = []
    in_failing = False
    for raw in log.splitlines():
        line = TIMESTAMP.sub("", ANSI.sub("", raw)).rstrip()
        if in_failing and line.startswith("\t") and line.strip():
            test = test_identity(line.strip())
            if test not in failing:
                failing.append(test)
            continue
        in_failing = line.strip() == FAILING_HEADER
        line = line.strip()
        if match := SWIFT_ISSUE.search(line):
            suite = Path(match["file"]).stem
            issues.append(Issue(suite, match["name"], f"{match['file']}:{match['line']}", match["message"]))
        elif match := XCTEST_ISSUE.search(line):
            file = Path(match["path"]).name
            issues.append(Issue(match["suite"], match["name"], f"{file}:{match['line']}", match["message"]))
        elif match := RUN_SUMMARY.search(line):
            result.tests = int(match["tests"])
        elif RELAUNCH.search(line):
            result.relaunches += 1
        elif match := CRASH_REPORTS.search(line):
            result.crash_reports += int(match["count"])
    used: set[int] = set()
    found = [(test, first_issue_for(test, issues, used)) for test in failing]
    if not failing:
        # A pass xcodebuild never finished (a timeout) lists no failing tests:
        # name each from its issue, `Suite.test` after the suite's file.
        for issue in issues:
            test = f"{issue.suite}.{issue.name}"
            if all(test != seen for seen, _ in found):
                found.append((test, f"{issue.where}: {issue.message}"))
    for test, detail in found:
        failure = failures.setdefault(test, Failure(test=test, first_issue=detail))
        if failure.first_issue is None:
            failure.first_issue = detail
        failure.passes.add((job, number))
    result.failing = len(found)
    return result


def read_job(folder: Path, failures: dict[str, Failure]) -> Job:
    label = (read_text(folder / "label") or folder.name).strip() or folder.name
    stopped = (read_text(folder / "stopped") or "").strip() or None
    if stopped:
        log = (read_text(folder / f"{stopped}.log") or "").splitlines()
        tail = [line for line in log if "error" in line.lower()][-3:] or log[-3:]
        return Job(label, stopped, read_int(folder / f"{stopped}.status"), tail, [])
    passes = []
    for number in range(1, (read_int(folder / "passes") or 0) + 1):
        status = read_int(folder / f"pass-{number}.status")
        log = read_text(folder / f"pass-{number}.log") or ""
        passes.append(parse_pass(label, number, status, log, failures))
    return Job(label, None, None, [], passes)


def cell(text: str) -> str:
    text = text if len(text) <= MESSAGE_LIMIT else text[: MESSAGE_LIMIT - 1] + "…"
    return text.replace("|", "\\|")


def report(folders: list[Path]) -> str:
    failures: dict[str, Failure] = {}
    jobs = [read_job(folder, failures) for folder in folders if folder.is_dir()]
    missing = [folder for folder in folders if not folder.is_dir()]
    ran = sum(1 for job in jobs for item in job.passes if item.status is not None)
    lines = [f"## Flake hunt: {len(failures)} failing test(s) in {ran} pass(es)", ""]
    if failures:
        lines += ["| Test | Failed in | First issue |", "|---|---|---|"]
        for failure in sorted(failures.values(), key=lambda item: (-len(item.passes), item.test)):
            spots = ", ".join(f"{job} #{number}" for job, number in sorted(failure.passes))
            issue = failure.first_issue or "no issue recorded (a crash or a timeout ended it)"
            lines.append(
                f"| `{cell(failure.test)}` | {len(failure.passes)} of {ran} ({spots}) | {cell(issue)} |")
        lines.append("")
    lines += ["| Job | Pass | Outcome |", "|---|---|---|"]
    for job in jobs:
        if job.stopped:
            state = "did not finish" if job.stopped_status is None else f"exit {job.stopped_status}"
            detail = "; ".join(cell(line.strip()) for line in job.stopped_tail) or f"see {job.stopped}.log"
            lines.append(f"| {job.label} | {job.stopped} | {state}: {detail} |")
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
