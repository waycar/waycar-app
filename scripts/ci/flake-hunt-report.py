#!/usr/bin/env python3
"""One Markdown report for a flake hunt (.github/workflows/flake-hunt.yml).

Each argument is one job's folder from scripts/ci/flake-hunt.sh: `label`,
`passes` and `package-passes`, a `<step>.status` and `<step>.log` per step
(`package-pass-N` for each pass of the WaycarSSH package E2E lane, `pass-N`
for each pass of the full lane), and `stopped`, naming the setup step that
ended the hunt early. The report lists every failing test, grouped by test (the xcodebuild
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


# A pass's lane as the report names it: the full lane's passes go unnamed.
PACKAGE_LANE = "package"


@dataclass
class Failure:
    test: str
    first_issue: str | None
    # (job, lane, pass number)
    passes: set[tuple[str, str, int]] = field(default_factory=set)


@dataclass
class Pass:
    number: int
    status: int | None
    lane: str = ""
    tests: int | None = None
    failing: int = 0
    relaunches: int = 0
    crash_reports: int = 0

    def name(self) -> str:
        return f"{self.lane} {self.number}".strip()

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


NO_ISSUE = "no issue recorded (a crash or a timeout ended it)"
UNMATCHED = "its suite recorded an issue no test name matched; see the pass log"


def attribute(failing: list[str], issues: list[Issue],
              one_launch: bool = True) -> dict[str, str]:
    """Each failing test's first issue. An issue names its test's function,
    and its file the suite: both match first, then the function alone when
    only one failing test has it. A display-named test's issue names neither;
    it goes to the one failing test of its suite left without an issue, and
    to none when several are left: never a guess. Last, every issue of a pass
    with one failing test is that test's: a display-named test whose suite
    extension lives in a file of another name (the WaycarSSH package suites)
    gets the first. Not after a test host relaunch, whose failing list covers
    only the last launch."""
    def detail(issue: Issue) -> str:
        return f"{issue.where}: {issue.message}"

    split = {test: test.partition(".")[::2] for test in failing}
    names = [name for _, name in split.values()]
    found: dict[str, str] = {}
    claimed: set[int] = set()
    for test, (suite, name) in split.items():
        mine = [index for index, issue in enumerate(issues) if issue.name == name
                and (issue.suite == suite or names.count(name) == 1)]
        claimed.update(mine)
        if mine:
            found[test] = detail(issues[mine[0]])
    left = [test for test in failing if test not in found]
    for test in left:
        suite = split[test][0]
        loose = [index for index, issue in enumerate(issues)
                 if index not in claimed and issue.suite == suite]
        alone = sum(1 for other in left if split[other][0] == suite) == 1
        if loose and alone:
            found[test] = detail(issues[loose[0]])
        else:
            found[test] = UNMATCHED if loose else NO_ISSUE
    if one_launch and len(failing) == 1 and issues \
            and found[failing[0]] in (NO_ISSUE, UNMATCHED):
        found[failing[0]] = detail(issues[0])
    return found


def parse_pass(job: str, number: int, status: int | None, log: str,
               failures: dict[str, Failure], lane: str = "") -> Pass:
    result = Pass(number=number, status=status, lane=lane)
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
    found = list(attribute(failing, issues, result.relaunches == 0).items())
    if not failing:
        # A pass xcodebuild never finished (a timeout) lists no failing tests:
        # name each from its issue, `Suite.test` after the suite's file.
        for issue in issues:
            test = f"{issue.suite}.{issue.name}"
            if all(test != seen for seen, _ in found):
                found.append((test, f"{issue.where}: {issue.message}"))
    for test, detail in found:
        failure = failures.setdefault(test, Failure(test=test, first_issue=detail))
        if failure.first_issue in (NO_ISSUE, UNMATCHED) and detail not in (NO_ISSUE, UNMATCHED):
            failure.first_issue = detail
        failure.passes.add((job, lane, number))
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
    for lane, prefix, count in (
            (PACKAGE_LANE, "package-pass", "package-passes"), ("", "pass", "passes")):
        for number in range(1, (read_int(folder / count) or 0) + 1):
            status = read_int(folder / f"{prefix}-{number}.status")
            log = read_text(folder / f"{prefix}-{number}.log") or ""
            passes.append(parse_pass(label, number, status, log, failures, lane))
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
            spots = ", ".join(
                f"{job} {lane + ' ' if lane else ''}#{number}"
                for job, lane, number in sorted(failure.passes))
            issue = failure.first_issue or NO_ISSUE
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
            lines.append(f"| {job.label} | {item.name()} | {item.outcome()} |")
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
