#!/usr/bin/env python3
"""One compact CI report for a commit or a pull request: every GitHub Actions run, its jobs and their test lanes.

    python3 scripts/ci/ci-evidence.py --sha <sha> | --pr <n> [--repo waycar/waycar-app]
        [--wait] [--deadline 2h] [--json | --fire] [--event push] [--include-schedule]

For each workflow run of the commit (with --pr, the pull request's head commit) it prints the conclusion and
duration, then each job. A job with tests shows what its log says: every lane scripts/run-ci-ios-tests.sh runs
(exit status, executed, pinned and skipped counts, failing tests, the first recorded issue, the gate's own verdicts),
or else its Swift Testing and XCTest totals. A job that did not succeed shows its first ##[error]. A cancelled run
says who or what cancelled it, and a run a newer run of the same workflow replaced (a re-run, a second dispatch, a
newer push in its concurrency group) is marked superseded and does not count.

--wait polls quietly (one stderr line when a run finishes), backing off from 20 s to 3 min, until every run that
counts has finished, then prints the report once. Use it, or an automation, instead of polling gh by hand: in an
`automation ask` script, --fire prints one `FIRE <verdict>` line and `DONE` instead of the report (exit 0); read the
report afterwards with the same command without --wait.

Exit status: 0 every run that counts succeeded; 1 one failed or was cancelled; 2 gh failed, a job log it could not
read included (the report says INCOMPLETE and still shows each run's conclusion), or the arguments are wrong; 3 runs
are still going (no --wait, or the deadline passed) or there are none.

Logs are read only for finished jobs that did not succeed and for successful jobs with a test step (a step whose
name says test or e2e). Needs gh, logged in; it only reads from GitHub. Scheduled runs (they also carry main's sha)
are left out unless --include-schedule.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

# ---- log parsing (pure; scripts/test-ci-evidence.py runs it on saved real logs) ----

TIMESTAMP = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ?")
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
INVISIBLE = dict.fromkeys(map(ord, "\ufeff\u200b"))

# run_xcodebuild's end of a lane; its "::group::<label>" reaches the log as "##[group]<label>".
LANE_END = re.compile(r"^==> (?P<lane>.+): (?P<seconds>\d+)s \(status (?P<status>\d+)\)$")
# run_suite and the package lane on a pass, with what they were held to.
PINNED = re.compile(
    r"^==> (?P<lane>.+): ran all (?P<expected>\d+) pinned tests, (?P<skipped>\d+) skipped \((?P<allowed>\d+) allowed\)$"
)
FULL_LANE = re.compile(r"^==> Full lane executed (?P<executed>\d+) of (?P<total>\d+) tests, (?P<skipped>\d+) skipped")
SWIFT_RUN = re.compile(
    r"Test run with (?P<tests>\d+) tests? in (?P<suites>\d+) suites? (?P<result>passed|failed) after [\d.]+ seconds"
    r"(?: with (?P<issues>\d+) issues?)?"
)
XCTEST_ALL = re.compile(r"Test Suite 'All tests' (?:passed|failed)")
XCTEST_EXECUTED = re.compile(
    r"Executed (?P<executed>\d+) tests?, with (?:(?P<skipped>\d+) tests? skipped and (?:with )?)?"
    r"(?P<failures>\d+) failures? \((?P<unexpected>\d+) unexpected\)"
)
# A Swift Testing skip record ("➜ Test "x" skipped: "why"", "Test x() skipped.") or an XCTest one; never a name
# that merely holds the word ("Test "a skipped read …" started.").
SKIPPED = re.compile(r"(?:^|\s)Test (?!run )\S.* skipped(?::|\.?$)|Test Case '.+' skipped \(")
SWIFT_FAILED = re.compile(r"✘ Test (?!run )(?P<name>.+?) failed after ")
XCTEST_FAILED = re.compile(r"Test Case '-\[(?P<name>[^\]]+)\]' failed")
ISSUE = re.compile(r"✘ Test .+ recorded an issue at .+|: error: -\[.+\] : .+")
# What scripts/run-ci-ios-tests.sh and the scripts it runs say when the gate itself refuses a run.
GATE = [
    re.compile(r"^(?P<lane>.+) did not execute all \d+ tests$"),
    re.compile(r"^(?P<lane>.+) skipped \d+ tests; exactly \d+ may skip$"),
    re.compile(r"^(?P<lane>.+) exceeded [\d.]+ seconds; diagnostics:"),
    re.compile(r"^Mandatory (?:behaviour|package test) not proven: .+"),
    re.compile(r"^The full lane (?:skipped|executed|printed) .+"),
    re.compile(r"^The mandatory WaycarSSH package suites did not execute all .+"),
    re.compile(r"^Every (?:available|replacement) .+ Simulator is claimed by a live run\.?$"),
    re.compile(r"^Gave up after .+WAYCAR_CI_SIM_WAIT_SECONDS.+"),
    re.compile(r"^No available .+ Simulator was found$"),
    re.compile(r"^Simulator destination recovery exhausted .+"),
]


def gate_match(line: str) -> re.Match | None:
    return next((m for m in (pattern.match(line) for pattern in GATE) if m), None)


def clean(line: str) -> str:
    return ANSI.sub("", TIMESTAMP.sub("", line.translate(INVISIBLE))).rstrip()


def test_totals(lines: list[str]) -> dict:
    """Swift Testing's last run summary, XCTest's 'All tests' totals, the skip records and the failing tests."""
    totals: dict = {}
    for i, line in enumerate(lines):
        if XCTEST_ALL.search(line):
            following = next((m for m in map(XCTEST_EXECUTED.search, lines[i + 1 : i + 3]) if m), None)
            if following:
                totals["xctest"] = {k: int(v or 0) for k, v in following.groupdict().items()}
    swift = [m for m in map(SWIFT_RUN.search, lines) if m]
    # swift test prints an empty Swift Testing run after its XCTest bundle, which says nothing; alone, an empty run
    # is a filter that matched nothing.
    swift = [m for m in swift if int(m["tests"])] or ([] if "xctest" in totals else swift)
    if swift:
        m = swift[-1]
        totals["swift"] = {
            "tests": int(m["tests"]),
            "suites": int(m["suites"]),
            "passed": m["result"] == "passed",
            "issues": int(m["issues"] or 0),
        }
    totals["skipped"] = sum(1 for line in lines if SKIPPED.search(line))
    failing = failing_block(lines)
    if not failing:
        failing = [m["name"] for m in map(SWIFT_FAILED.search, lines) if m]
        failing += [m["name"] for m in map(XCTEST_FAILED.search, lines) if m]
    totals["failing"] = list(dict.fromkeys(failing))
    issue = next((m.group(0) for m in map(ISSUE.search, lines) if m), None)
    if issue:
        totals["issue"] = issue.removeprefix("✘ ")
    return totals


def failing_block(lines: list[str]) -> list[str]:
    """xcodebuild's 'Failing tests:' list: indented ids up to the next blank line."""
    names: list[str] = []
    for i, line in enumerate(lines):
        if line.strip() != "Failing tests:":
            continue
        for entry in lines[i + 1 :]:
            if not entry.strip():
                break
            names.append(entry.strip())
    return names


def parse_log(text: str) -> dict:
    """A job's log: its lanes (run-ci-ios-tests.sh), the gate's verdicts, the first ##[error] and, when the job
    has no lanes, its test totals."""
    lines = [clean(line) for line in text.split("\n")]
    lanes: list[dict] = []
    gate: list[str] = []
    first_error = None
    group: dict | None = None
    last_closed: dict | None = None

    def in_lane() -> bool:
        # A step's own header group ("Run <command>") is never a lane.
        return bool(group) and not group["label"].startswith("Run ")

    def lane(label: str, body: list[str], **fields) -> dict:
        entry = {"name": label, **fields, **test_totals(body)}
        for line in body:
            if gate_match(line):
                entry.setdefault("gate", []).append(line)
                gate.append(line)
        lanes.append(entry)
        return entry

    def interrupted(end: int) -> None:
        # A lane still open when the step failed or was cancelled, or the log ended.
        nonlocal group
        if in_lane():
            lane(group["label"], lines[group["start"] + 1 : end], status=None, seconds=None, interrupted=True)
        group = None

    for i, line in enumerate(lines):
        if line.startswith("##[group]"):
            interrupted(i)
            group = {"label": line[len("##[group]") :].strip(), "start": i}
        elif line.startswith("##[endgroup]"):
            if group:
                last_closed = {**group, "end": i}
            group = None
        elif line.startswith("##[error]"):
            interrupted(i)
            if first_error is None:
                first_error = line[len("##[error]") :].strip()
        elif m := LANE_END.match(line):
            if last_closed and last_closed["label"] == m["lane"]:
                lane(m["lane"], lines[last_closed["start"] + 1 : last_closed["end"]],
                     status=int(m["status"]), seconds=int(m["seconds"]), interrupted=False)
                last_closed = None
        elif m := PINNED.match(line):
            target = next((x for x in reversed(lanes) if x["name"] == m["lane"]), None)
            if target:
                target["pinned"] = {k: int(m[k]) for k in ("expected", "skipped", "allowed")}
        elif m := FULL_LANE.match(line):
            target = next((x for x in reversed(lanes) if x["name"] == "Full app test lane"), lanes[-1] if lanes else None)
            if target:
                target["full"] = {k: int(m[k]) for k in ("executed", "total", "skipped")}
        elif not group and (g := gate_match(line)):
            # Inside a lane, lane() picks the message up; after one, it is about the lane it names, or the last.
            gate.append(line)
            named = g.groupdict().get("lane")
            target = next((x for x in reversed(lanes) if x["name"] == named), None) if named else None
            target = target or (lanes[-1] if lanes else None)
            if target is not None:
                target.setdefault("gate", []).append(line)
    interrupted(len(lines))
    parsed: dict = {"lanes": lanes, "gate": gate, "error": first_error}
    if not lanes:
        totals = test_totals(lines)
        if "swift" in totals or "xctest" in totals:
            parsed["tests"] = totals
    return parsed


# ---- GitHub ----


class GhError(Exception):
    pass


def gh(*args: str, timeout: int = 120) -> str:
    try:
        result = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GhError(str(error)) from error
    if result.returncode != 0:
        lines = result.stderr.strip().splitlines()
        raise GhError(lines[-1] if lines else f"gh exited {result.returncode}")
    return result.stdout


def gh_json(path: str):
    return json.loads(gh("api", path))


_escape_flag: list[str] | None = None


def job_log(repo: str, job_id: int) -> str:
    """A finished job's log. gh 2.8x and later refuse a body with terminal escapes unless told to pass them."""
    global _escape_flag
    if _escape_flag is None:
        try:
            _escape_flag = ["--allow-escape-sequences"] if "allow-escape-sequences" in gh("api", "--help") else []
        except GhError:
            _escape_flag = []
    return gh("api", *_escape_flag, f"repos/{repo}/actions/jobs/{job_id}/logs", timeout=300)


def parse_time(text: str | None) -> float | None:
    if not text:
        return None
    return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()


def seconds_between(start: str | None, end: str | None) -> int | None:
    a, b = parse_time(start), parse_time(end) if end else time.time()
    return None if a is None or b is None else max(0, round(b - a))


def resolve(repo: str, sha: str | None, pr: int | None) -> dict:
    if pr is not None:
        data = gh_json(f"repos/{repo}/pulls/{pr}")
        return {"sha": data["head"]["sha"], "pr": pr, "branch": data["head"]["ref"], "state": data["state"]}
    return {"sha": gh("api", f"repos/{repo}/commits/{sha}", "--jq", ".sha").strip()}


def list_runs(repo: str, sha: str, events: list[str] | None, include_schedule: bool) -> list[dict]:
    data = gh_json(f"repos/{repo}/actions/runs?head_sha={sha}&per_page=100")
    runs = data.get("workflow_runs", [])
    if events:
        runs = [r for r in runs if r.get("event") in events]
    elif not include_schedule:
        runs = [r for r in runs if r.get("event") != "schedule"]
    runs.sort(key=lambda r: (r.get("name") or "", r.get("created_at") or ""))
    # A newer run of the same workflow, event and branch replaces the older ones: they no longer count.
    newest: dict = {}
    for run in sorted(runs, key=lambda r: r.get("created_at") or ""):
        newest[(run.get("workflow_id"), run.get("event"), run.get("head_branch"))] = run
    for run in runs:
        latest = newest[(run.get("workflow_id"), run.get("event"), run.get("head_branch"))]
        run["_superseded_by"] = latest["id"] if latest["id"] != run["id"] else None
    return runs


def wants_log(job: dict) -> bool:
    if job.get("status") != "completed" or job.get("conclusion") == "skipped":
        return False
    if job.get("conclusion") != "success":
        return True
    return any(re.search(r"\btests?\b|\be2e\b", step.get("name") or "", re.I) for step in job.get("steps") or [])


def cancel_reason(repo: str, job_id: int) -> str | None:
    try:
        notes = gh_json(f"repos/{repo}/check-runs/{job_id}/annotations")
    except GhError:
        return None
    messages = [n.get("message") or "" for n in notes]
    return next((m for m in messages if "cancel" in m.lower()), messages[0] if messages else None)


def collect(repo: str, target: dict, runs: list[dict]) -> dict:
    """The whole report: runs, their jobs, and what each finished job's log says."""
    report_runs = []
    for run in runs:
        entry = {
            "id": run["id"],
            "name": run.get("name"),
            "event": run.get("event"),
            "status": run.get("status"),
            "conclusion": run.get("conclusion"),
            "attempt": run.get("run_attempt", 1),
            "url": run.get("html_url"),
            "seconds": seconds_between(run.get("run_started_at"), run.get("updated_at") if run.get("status") == "completed" else None),
            "superseded_by": run["_superseded_by"],
            "jobs": [],
        }
        jobs = gh_json(f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100").get("jobs", [])
        for job in jobs:
            item = {
                "id": job["id"],
                "name": job.get("name"),
                "status": job.get("status"),
                "conclusion": job.get("conclusion"),
                "seconds": seconds_between(job.get("started_at"), job.get("completed_at")) if job.get("started_at") else None,
                "url": job.get("html_url"),
            }
            if job.get("conclusion") == "cancelled" and entry["superseded_by"] is None:
                item["cancel_reason"] = cancel_reason(repo, job["id"])
            if wants_log(job) and entry["superseded_by"] is None:
                for _ in range(2):
                    try:
                        item.update(parse_log(job_log(repo, job["id"])))
                        item.pop("log_error", None)
                        break
                    except GhError as error:
                        item["log_error"] = str(error)
            entry["jobs"].append(item)
        reasons = [j["cancel_reason"] for j in entry["jobs"] if j.get("cancel_reason")]
        if entry["conclusion"] == "cancelled" and reasons:
            entry["cancel_reason"] = reasons[0]
            if "higher priority" in reasons[0]:
                entry["superseded_by"] = "a newer run in its concurrency group"
        report_runs.append(entry)
    counted = [r for r in report_runs if not r["superseded_by"]]
    pending = [r for r in counted if r["status"] != "completed"]
    red = [r for r in counted if r["status"] == "completed" and r["conclusion"] not in ("success", "neutral", "skipped")]
    unread = [j for r in counted for j in r["jobs"] if j.get("log_error")]
    # A job log gh could not read leaves the evidence incomplete (exit 2), whatever the runs concluded; the report
    # still shows each run's conclusion.
    verdict = "INCOMPLETE" if unread else "RED" if red else "PENDING" if pending or not counted else "GREEN"
    return {"repo": repo, **target, "verdict": verdict, "runs": report_runs}


# ---- rendering ----

MARK = {"success": "✓", "neutral": "✓", "skipped": "-", None: "…"}


def mark(conclusion: str | None, status: str | None = "completed") -> str:
    if status != "completed":
        return "…"
    return MARK.get(conclusion, "✗")


def span(seconds: int | None) -> str:
    if seconds is None:
        return "?"
    return f"{seconds}s" if seconds < 60 else f"{seconds // 60}m{seconds % 60:02d}s"


def plural(n: int, word: str) -> str:
    return f"{n} {word}{'' if n == 1 else 's'}"


def lane_counts(lane: dict) -> str:
    pinned, full, swift, xc = lane.get("pinned"), lane.get("full"), lane.get("swift"), lane.get("xctest")
    if pinned:
        return (f"ran {pinned['expected'] - pinned['skipped']} of {pinned['expected']} pinned, "
                f"{pinned['skipped']} skipped ({pinned['allowed']} allowed)")
    if full:
        return f"ran {full['executed']} of {full['total']}, {full['skipped']} skipped (all proven elsewhere)"
    parts = []
    if swift:
        issues = f", {plural(swift['issues'], 'issue')}" if swift["issues"] else ""
        parts.append(f"{plural(swift['tests'], 'test')} in {plural(swift['suites'], 'suite')} "
                     f"{'passed' if swift['passed'] else 'failed'}{issues}")
    if xc and (xc["executed"] or not swift):
        parts.append(f"XCTest {xc['executed']} executed, {plural(xc['failures'], 'failure')}")
    if parts:
        parts.append(f"{lane.get('skipped', 0)} skipped")
    return ", ".join(parts)


def render_lane(lane: dict) -> list[str]:
    status = lane.get("status")
    sign = "…" if lane.get("interrupted") else "✓" if status == 0 else "✗"
    counts = lane_counts(lane)
    state = "interrupted" if lane.get("interrupted") else "" if status == 0 else f"status {status}"
    head = f"{sign} {lane['name']}" + (f": {counts}" if counts else "")
    tail = " · ".join(x for x in (state, span(lane["seconds"]) if lane.get("seconds") is not None else "") if x)
    lines = [head + (f" · {tail}" if tail else "")]
    if status != 0 or lane.get("interrupted"):
        if lane.get("failing"):
            shown = lane["failing"][:8]
            more = f" (+{len(lane['failing']) - 8} more)" if len(lane["failing"]) > 8 else ""
            lines.append(f"    failing: {', '.join(shown)}{more}")
        if lane.get("issue"):
            lines.append(f"    first issue: {lane['issue']}")
    for message in lane.get("gate", []):
        lines.append(f"    gate: {message}")
    return lines


def render(report: dict) -> str:
    runs = report["runs"]
    counted = [r for r in runs if not r["superseded_by"]]
    tally: dict = {}
    for run in counted:
        key = run["conclusion"] if run["status"] == "completed" else run["status"]
        tally[key] = tally.get(key, 0) + 1
    where = f"PR #{report['pr']} ({report.get('branch')}) head {report['sha'][:12]}" if report.get("pr") else report["sha"][:12]
    summary = ", ".join(f"{n} {k}" for k, n in sorted(tally.items())) or "no runs"
    lines = [f"{report['verdict']} {report['repo']} {where}: {summary}"]
    if len(counted) < len(runs):
        lines[0] += f"; {len(runs) - len(counted)} superseded"
    for run in runs:
        state = run["conclusion"] if run["status"] == "completed" else run["status"]
        attempt = f" · attempt {run['attempt']}" if run["attempt"] and run["attempt"] > 1 else ""
        so_far = "" if run["status"] == "completed" else " so far"
        if run["superseded_by"]:
            lines.append(f"- {run['name']} · {run['event']} · {state} · superseded by {run['superseded_by']}{attempt} · {run['url']}")
            continue
        lines.append(f"{mark(run['conclusion'], run['status'])} {run['name']} · {run['event']} · {state} · "
                     f"{span(run['seconds'])}{so_far}{attempt} · {run['url']}")
        if run.get("cancel_reason"):
            lines.append(f"    cancelled: {run['cancel_reason']}")
        for job in run["jobs"]:
            job_state = job["conclusion"] if job["status"] == "completed" else job["status"]
            took = "" if job_state == "skipped" else f" · {span(job['seconds'])}"
            lines.append(f"  {mark(job['conclusion'], job['status'])} {job['name']} · {job_state}{took}")
            if job.get("error") and job.get("conclusion") != "success":
                lines.append(f"      error: {job['error']}")
            if job.get("cancel_reason") and job.get("cancel_reason") != run.get("cancel_reason"):
                lines.append(f"      cancelled: {job['cancel_reason']}")
            if job.get("log_error"):
                lines.append(f"      log unavailable: {job['log_error']}")
            for lane in job.get("lanes", []):
                lines.extend(f"      {line}" for line in render_lane(lane))
            tests = job.get("tests")
            if tests:
                lines.append(f"      tests: {lane_counts(tests)}")
                if tests.get("failing"):
                    lines.append(f"      failing: {', '.join(tests['failing'][:8])}")
                if tests.get("issue") and job.get("conclusion") != "success":
                    lines.append(f"      first issue: {tests['issue']}")
            if not job.get("lanes"):
                lines.extend(f"      gate: {message}" for message in job.get("gate", []))
    return "\n".join(lines)


def fire_line(report: dict) -> str:
    """One line for an automation: the verdict and, when red, each failing run, job and lane."""
    problems = []
    for run in report["runs"]:
        if run["superseded_by"] or run["status"] != "completed" or run["conclusion"] in ("success", "neutral", "skipped"):
            continue
        jobs = [j for j in run["jobs"] if j.get("conclusion") not in ("success", "skipped", None)]
        detail = "; ".join(
            j["name"] + "".join(f" [{lane['name']}]" for lane in j.get("lanes", []) if lane.get("status") != 0)
            for j in jobs
        )
        problems.append(f"{run['name']} {run['conclusion']}{f' ({detail})' if detail else ''}")
    unread = [j["name"] for r in report["runs"] if not r["superseded_by"] for j in r["jobs"] if j.get("log_error")]
    if unread:
        problems.append(f"logs gh could not read: {', '.join(unread)}")
    head = f"{report['verdict']} {report['sha'][:12]}" + (f" (PR #{report['pr']})" if report.get("pr") else "")
    return f"FIRE {head}: " + ("; ".join(problems) if problems else f"{len(report['runs'])} runs") + " — details: ci-evidence.py without --wait"


# ---- main ----


def duration(text: str) -> int:
    match = re.fullmatch(r"(\d+)([smh]?)", text)
    if not match:
        raise argparse.ArgumentTypeError(f"not a duration like 90s, 30m or 2h: {text!r}")
    return int(match.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[match.group(2)]


def sha_prefix(text: str) -> str:
    if not re.fullmatch(r"[0-9a-fA-F]{7,40}", text):
        raise argparse.ArgumentTypeError(f"not a 7-40 character hex sha: {text!r}")
    return text.lower()


def wait_for_runs(args, target: dict) -> list[dict]:
    """Poll until the same finished runs show on two polls in a row (a late workflow can still appear), the deadline
    passes, or no run has appeared after 10 minutes. gh failing five times in a row, or on every poll until the
    deadline, raises GhError."""
    started = time.monotonic()
    interval, done, first = 20.0, set(), True
    last_runs, previous, failures, last_error = None, None, 0, GhError("no answer from gh")
    while True:
        try:
            runs = list_runs(args.repo, target["sha"], args.event, args.include_schedule)
            failures = 0
        except GhError as error:
            failures += 1
            if failures >= 5:
                raise
            print(f"ci-evidence: gh failed ({error}); retrying", file=sys.stderr, flush=True)
            # Two answers in a row confirm the runs are done; one with a failure between them does not.
            last_error, runs, previous = error, None, None
        if runs is not None:
            last_runs = runs
            counted = [r for r in runs if not r["_superseded_by"]]
            finished = [r for r in counted if r.get("status") == "completed"]
            if first:
                print(f"ci-evidence: waiting for {target['sha'][:12]}; {len(finished)} of {len(counted)} runs done",
                      file=sys.stderr, flush=True)
                done.update(r["id"] for r in finished)
                first = False
            for run in finished:
                if run["id"] not in done:
                    done.add(run["id"])
                    print(f"ci-evidence: {run.get('name')} {run.get('conclusion')} ({len(finished)} of {len(counted)} done)",
                          file=sys.stderr, flush=True)
            snapshot = sorted((r["id"], r.get("run_attempt"), r.get("status")) for r in counted)
            if counted and len(finished) == len(counted):
                if snapshot == previous:
                    return runs
                interval = 20.0  # look once more soon: a workflow that starts late must not be missed
            previous = snapshot
            if not counted and time.monotonic() - started > 600:
                return runs
        elapsed = time.monotonic() - started
        if elapsed >= args.deadline:
            print("ci-evidence: deadline passed", file=sys.stderr, flush=True)
            if last_runs is None:
                raise last_error
            return last_runs
        time.sleep(min(interval, max(1.0, args.deadline - elapsed)))
        interval = min(interval * 1.5, 180.0)


def main() -> int:
    parser = argparse.ArgumentParser(description="One compact CI report for a commit or pull request.")
    which = parser.add_mutually_exclusive_group(required=True)
    which.add_argument("--sha", type=sha_prefix, help="commit sha or prefix (7+ hex)")
    which.add_argument("--pr", type=int, help="pull request number (its head commit)")
    parser.add_argument("--repo", default="waycar/waycar-app")
    parser.add_argument("--wait", action="store_true", help="poll until every run that counts has finished")
    parser.add_argument("--deadline", type=duration, default=2 * 3600, help="with --wait, give up after this long (default 2h)")
    output = parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", help="print the report as JSON")
    output.add_argument("--fire", action="store_true", help="print one FIRE line and DONE, for an automation script")
    parser.add_argument("--event", action="append", help="only runs of this event (repeatable): push, pull_request, ...")
    parser.add_argument("--include-schedule", action="store_true", help="also count scheduled runs")
    args = parser.parse_args()

    try:
        target = resolve(args.repo, args.sha, args.pr)
        runs = wait_for_runs(args, target) if args.wait else list_runs(args.repo, target["sha"], args.event, args.include_schedule)
        report = collect(args.repo, target, runs)
    except GhError as error:
        if args.fire:
            print(f"FIRE ci-evidence: gh failed: {error}\nDONE", flush=True)
            return 0
        print(f"ci-evidence: gh failed: {error}", file=sys.stderr)
        return 2
    if args.fire:
        print(fire_line(report), flush=True)
        print("DONE", flush=True)
        return 0
    print(json.dumps(report, indent=1) if args.json else render(report))
    return {"GREEN": 0, "RED": 1, "INCOMPLETE": 2}.get(report["verdict"], 3)


if __name__ == "__main__":
    sys.exit(main())
