#!/usr/bin/env python3
"""Exercise scripts/ci/ci-evidence.py: its log parsing on saved snippets of real job logs (scripts/testdata/ci-evidence/:
public CI runs named <run id>-<job id>, and one Mac `make test-swiftmosh` without SWIFTMOSH_REAL_E2E, whose skips CI
never has; lines cut from the full logs and left as they were, local paths left out), and its report on stubbed gh
answers. No network."""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # leave no __pycache__ beside the script
ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "scripts" / "testdata" / "ci-evidence"
spec = importlib.util.spec_from_file_location("ci_evidence", ROOT / "scripts" / "ci" / "ci-evidence.py")
ce = importlib.util.module_from_spec(spec)
assert spec.loader
spec.loader.exec_module(ce)


def fixture(name: str) -> str:
    return (DATA / name).read_text(encoding="utf-8")


def lanes(parsed: dict) -> dict:
    return {lane["name"]: lane for lane in parsed["lanes"]}


def shipped_echo(prefix: str, **values: str) -> str:
    """The line run-ci-ios-tests.sh prints, from its own echo statement (with its continuation lines) run in bash."""
    lines = (ROOT / "scripts" / "run-ci-ios-tests.sh").read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.strip().startswith(prefix))
    statement = [lines[start]]
    while statement[-1].rstrip().endswith("\\"):
        statement.append(lines[start + len(statement)])
    assignments = "; ".join(f"{k}={v}" for k, v in values.items())
    out = subprocess.run(["bash", "-c", f"{assignments}; " + "\n".join(statement)], capture_output=True, text=True, check=True)
    return out.stdout.strip()


class LogParsingTests(unittest.TestCase):
    def test_a_failed_app_lane_names_its_test_issue_and_error(self) -> None:
        # Run 43491553084 (main): the tmux 3.2a matrix lane failed and the gate stopped there.
        parsed = ce.parse_log(fixture("ios-app-failure-43491553084-132113745445.log"))
        self.assertEqual(parsed["error"], "Process completed with exit code 65.")
        found = lanes(parsed)
        self.assertEqual(list(found), ["Build for testing", "WaycarSSHSessionE2ETests", "TmuxTransportE2ETests-tmux-3.2a"])
        self.assertEqual(found["WaycarSSHSessionE2ETests"]["status"], 0)
        self.assertEqual(found["WaycarSSHSessionE2ETests"]["swift"], {"tests": 13, "suites": 1, "passed": True, "issues": 0})
        failed = found["TmuxTransportE2ETests-tmux-3.2a"]
        self.assertEqual((failed["status"], failed["seconds"]), (65, 179))
        self.assertEqual(failed["swift"], {"tests": 21, "suites": 1, "passed": False, "issues": 1})
        self.assertEqual(failed["failing"], ["TmuxTransportE2ETests.controlChannelReattachesAfterTmuxExits()"])
        self.assertTrue(failed["issue"].startswith('Test "without no-detach-on-destroy the control channel reattaches'))
        self.assertIn("TmuxTransportE2ETests.swift:711:6: Caught error: .timedOut", failed["issue"])
        rendered = "\n".join(ce.render_lane(failed))
        self.assertIn("✗ TmuxTransportE2ETests-tmux-3.2a: 21 tests in 1 suite failed, 1 issue, 0 skipped · status 65 · 2m59s", rendered)
        self.assertIn("failing: TmuxTransportE2ETests.controlChannelReattachesAfterTmuxExits()", rendered)

    def test_a_passing_app_job_reports_its_lanes_and_the_full_lane_counts(self) -> None:
        # Run 43526207696 (PR head 3437d9cc): every lane passed.
        parsed = ce.parse_log(fixture("ios-app-pass-43526207696-132232485032.log"))
        self.assertIsNone(parsed["error"])
        found = lanes(parsed)
        self.assertEqual(list(found), ["Build for testing", "ZellijTransportE2ETests", "Full app test lane"])
        self.assertNotIn("swift", found["Build for testing"])
        self.assertEqual(found["ZellijTransportE2ETests"]["swift"]["tests"], 6)
        full = found["Full app test lane"]
        self.assertEqual(full["full"], {"executed": 6912, "total": 7150, "skipped": 238})
        # Three `➜ Test … skipped:` records are in the snippet; the suite record, "a skipped read …" and "… are
        # skipped to …" are not test skips.
        self.assertEqual(full["skipped"], 3)
        self.assertEqual(ce.render_lane(full), ["✓ Full app test lane: ran 6912 of 7150, 238 skipped (all proven elsewhere) · 8m17s"])

    def test_a_failed_package_lane(self) -> None:
        # Run 43529595689: SessionDriverE2ETests timed out in the WaycarSSH package lane.
        parsed = ce.parse_log(fixture("package-failure-43529595689-132243703778.log"))
        found = lanes(parsed)
        self.assertEqual(list(found), ["WaycarSSH package build", "WaycarSSH package E2E"])
        e2e = found["WaycarSSH package E2E"]
        self.assertEqual((e2e["status"], e2e["swift"]["tests"], e2e["swift"]["suites"]), (65, 137, 10))
        self.assertEqual(e2e["failing"], ["SessionDriverE2ETests.execFinishesOnOutputTheStandardErrorReadQueued()"])
        self.assertEqual(parsed["error"], "Process completed with exit code 65.")

    def test_a_job_cancelled_between_lanes(self) -> None:
        parsed = ce.parse_log(fixture("ios-app-cancelled-43529595689-132243703517.log"))
        self.assertEqual(parsed["error"], "The operation was canceled.")
        self.assertEqual([(x["name"], x["status"]) for x in parsed["lanes"]], [("Build for testing", 0)])

    def test_a_job_cancelled_inside_a_lane_reports_it_interrupted(self) -> None:
        passing = fixture("ios-app-pass-43526207696-132232485032.log").splitlines()
        cut = next(i for i, line in enumerate(passing) if "Test run with 7150 tests" in line)
        cancelled = fixture("ios-app-cancelled-43529595689-132243703517.log").splitlines()
        tail = cancelled[next(i for i, line in enumerate(cancelled) if "Terminated: 15" in line) :]
        parsed = ce.parse_log("\n".join(passing[:cut] + tail))
        last = parsed["lanes"][-1]
        self.assertEqual((last["name"], last["status"], last["interrupted"]), ("Full app test lane", None, True))
        self.assertTrue(ce.render_lane(last)[0].startswith("… Full app test lane"))

    def test_a_job_without_lanes_reports_its_xctest_totals(self) -> None:
        # SwiftMosh's swift test: XCTest totals, then an empty Swift Testing run that says nothing.
        parsed = ce.parse_log(fixture("swiftmosh-pass-43491553084-132113744867.log"))
        self.assertEqual(parsed["lanes"], [])
        self.assertEqual(parsed["tests"]["xctest"], {"executed": 189, "skipped": 0, "failures": 0, "unexpected": 0})
        self.assertNotIn("swift", parsed["tests"])
        self.assertEqual(ce.lane_counts(parsed["tests"]), "XCTest 189 executed, 0 failures, 0 skipped")

    def test_xctest_totals_with_skips(self) -> None:
        # XCTest's summary gains "with N tests skipped and" once a test skips.
        parsed = ce.parse_log(fixture("swiftmosh-skips-mac-8f20288.log"))
        self.assertEqual(parsed["tests"]["xctest"], {"executed": 189, "skipped": 9, "failures": 0, "unexpected": 0})
        self.assertNotIn("swift", parsed["tests"])
        self.assertEqual(ce.lane_counts(parsed["tests"]), "XCTest 189 executed, 0 failures, 9 skipped")

    def test_pinned_counts_come_from_the_gates_own_echo(self) -> None:
        # A green lane says what run_suite held it to; the line is rendered by the shipped echo statements.
        log = fixture("ios-app-failure-43491553084-132113745445.log").splitlines()
        end = next(i for i, line in enumerate(log) if "==> WaycarSSHSessionE2ETests: 128s (status 0)" in line)
        marker = shipped_echo('echo "==> $lane: ran all', lane="WaycarSSHSessionE2ETests", expected_tests=13, skips=2,
                              expected_skips=2)
        self.assertEqual(marker, "==> WaycarSSHSessionE2ETests: ran all 13 pinned tests, 2 skipped (2 allowed)")
        found = lanes(ce.parse_log("\n".join(log[: end + 1] + [marker])))
        self.assertEqual(found["WaycarSSHSessionE2ETests"]["pinned"], {"expected": 13, "skipped": 2, "allowed": 2})
        self.assertEqual(ce.lane_counts(found["WaycarSSHSessionE2ETests"]), "ran 11 of 13 pinned, 2 skipped (2 allowed)")

        script = (ROOT / "scripts" / "run-ci-ios-tests.sh").read_text()
        count = re.search(r"^package_e2e_count=(\d+)$", script, re.M)
        assert count
        package = shipped_echo('echo "==> WaycarSSH package E2E: ran all', package_e2e_count=count[1])
        log = fixture("package-failure-43529595689-132243703778.log").splitlines()
        end = next(i for i, line in enumerate(log) if "==> WaycarSSH package E2E: 171s" in line)
        found = lanes(ce.parse_log("\n".join(log[: end + 1] + [package])))
        self.assertEqual(found["WaycarSSH package E2E"]["pinned"]["expected"], int(count[1]))

    def test_gate_verdicts_attach_to_the_lane_they_name(self) -> None:
        log = fixture("ios-app-failure-43491553084-132113745445.log").splitlines()
        end = next(i for i, line in enumerate(log) if "==> WaycarSSHSessionE2ETests: 128s (status 0)" in line)
        verdicts = [
            "WaycarSSHSessionE2ETests did not execute all 13 tests",
            "Mandatory behaviour not proven: Events (subscribeDeliversEvents())",
        ]
        parsed = ce.parse_log("\n".join(log[: end + 1] + verdicts))
        self.assertEqual(lanes(parsed)["WaycarSSHSessionE2ETests"]["gate"], verdicts)
        self.assertEqual(parsed["gate"], verdicts)


def run(id: int, name: str, status: str, conclusion: str | None, *, event: str = "push", created: str = "2026-11-13T19:22:13Z",
        workflow: int = 1) -> dict:
    return {"id": id, "name": name, "workflow_id": workflow, "event": event, "head_branch": "main", "status": status,
            "conclusion": conclusion, "run_attempt": 1, "created_at": created, "run_started_at": created,
            "updated_at": "2026-11-13T19:32:13Z", "html_url": f"https://github.com/o/r/actions/runs/{id}"}


def job(id: int, name: str, conclusion: str | None, steps: tuple[str, ...] = ()) -> dict:
    return {"id": id, "name": name, "status": "completed" if conclusion else "in_progress", "conclusion": conclusion,
            "started_at": "2026-11-13T19:22:17Z", "completed_at": "2026-11-13T19:25:22Z" if conclusion else None,
            "html_url": f"https://github.com/o/r/actions/runs/1/job/{id}", "steps": [{"name": s} for s in steps]}


class ReportTests(unittest.TestCase):
    def stub(self, runs: list[dict], jobs: dict[int, list[dict]], logs: dict[int, str] | None = None,
             annotations: dict[int, list[dict]] | None = None) -> None:
        def gh_json(path: str):
            if "/actions/runs?" in path:
                return {"workflow_runs": [dict(r) for r in runs]}
            run_id = re.search(r"/actions/runs/(\d+)/jobs", path)
            if run_id:
                return {"jobs": jobs[int(run_id[1])]}
            check = re.search(r"/check-runs/(\d+)/annotations", path)
            if check:
                return (annotations or {}).get(int(check[1]), [])
            raise AssertionError(path)

        originals = (ce.gh_json, ce.job_log)
        ce.gh_json = gh_json
        ce.job_log = lambda repo, job_id: (logs or {})[job_id]
        self.addCleanup(lambda: setattr(ce, "gh_json", originals[0]) or setattr(ce, "job_log", originals[1]))

    def report(self, **kwargs) -> dict:
        runs = ce.list_runs("o/r", "a" * 40, None, False)
        return ce.collect("o/r", {"sha": "a" * 40}, runs)

    def test_a_failed_lane_turns_the_report_red_with_its_evidence(self) -> None:
        self.stub(
            [run(1, "CI", "completed", "failure"), run(2, "Web", "completed", "success", workflow=2),
             run(3, "Web", "completed", "success", event="schedule", workflow=2)],
            {1: [job(11, "Build & test (iOS Simulator)", "failure", ("Build and test",)),
                 job(12, "SwiftMosh package (macOS host)", "success", ("Test SwiftMosh package",))],
             2: [job(21, "Build", "success", ("Build the site",))]},
            logs={11: fixture("ios-app-failure-43491553084-132113745445.log"),
                  12: fixture("swiftmosh-pass-43491553084-132113744867.log")},
        )
        report = self.report()
        self.assertEqual(report["verdict"], "RED")
        self.assertEqual([r["name"] for r in report["runs"]], ["CI", "Web"])  # the scheduled run is left out
        text = ce.render(report)
        self.assertTrue(text.startswith("RED o/r aaaaaaaaaaaa: 1 failure, 1 success"), text)
        self.assertIn("      error: Process completed with exit code 65.", text)
        self.assertIn("      tests: XCTest 189 executed, 0 failures, 0 skipped", text)
        self.assertIn("✗ TmuxTransportE2ETests-tmux-3.2a", text)
        self.assertNotIn("error:", text.split("✓ Web")[1])  # a green job without a test step is not read
        self.assertEqual(ce.fire_line(report),
                         "FIRE RED aaaaaaaaaaaa: CI failure (Build & test (iOS Simulator) [TmuxTransportE2ETests-tmux-3.2a])"
                         " — details: ci-evidence.py without --wait")

    def test_a_replaced_run_and_a_concurrency_cancel_do_not_count(self) -> None:
        self.stub(
            [run(1, "CI", "completed", "cancelled", event="workflow_dispatch"),
             run(2, "CI", "completed", "success", event="workflow_dispatch", created="2026-11-13T19:30:00Z"),
             run(3, "Web", "completed", "cancelled", workflow=2)],
            {1: [job(11, "Build", "cancelled")], 2: [job(21, "Build", "success")], 3: [job(31, "Build", "cancelled")]},
            logs={11: "", 31: ""},
            annotations={31: [{"message": "Canceling since a higher priority waiting request for 'Web-main' exists"}]},
        )
        report = self.report()
        superseded = {r["id"]: r["superseded_by"] for r in report["runs"]}
        self.assertEqual(superseded, {1: 2, 2: None, 3: "a newer run in its concurrency group"})
        self.assertEqual(report["verdict"], "GREEN")
        self.assertIn("- CI · workflow_dispatch · cancelled · superseded by 2", ce.render(report))

    def test_a_cancelled_run_says_who_cancelled_it_and_counts_red(self) -> None:
        self.stub([run(1, "CI", "completed", "cancelled")], {1: [job(11, "Build & test", "cancelled")]},
                  logs={11: fixture("ios-app-cancelled-43529595689-132243703517.log")},
                  annotations={11: [{"message": "The run was canceled by @someone."}, {"message": "The operation was canceled."}]})
        report = self.report()
        self.assertEqual(report["verdict"], "RED")
        self.assertIn("    cancelled: The run was canceled by @someone.", ce.render(report))

    def test_running_jobs_leave_the_report_pending(self) -> None:
        self.stub([run(1, "CI", "in_progress", None)], {1: [job(11, "Build & test", None)]})
        report = self.report()
        self.assertEqual(report["verdict"], "PENDING")
        self.assertIn("… Build & test · in_progress", ce.render(report))

    def test_a_log_gh_cannot_read_leaves_a_green_report_incomplete(self) -> None:
        self.stub([run(1, "CI", "completed", "success")], {1: [job(11, "Build & test", "success", ("Build and test",))]})

        def refused(repo, job_id):
            raise ce.GhError("HTTP 403: Resource not accessible")

        ce.job_log = refused
        report = self.report()
        self.assertEqual(report["verdict"], "INCOMPLETE")
        self.assertIn("log unavailable: HTTP 403", ce.render(report))

    def wait(self, polls: list) -> tuple[list[dict], list[str]]:
        calls: list[str] = []

        def gh_json(path: str):
            calls.append(path)
            answer = polls[min(len(calls), len(polls)) - 1]
            if isinstance(answer, Exception):
                raise answer
            return {"workflow_runs": answer}

        clock = [0.0]
        originals = (ce.gh_json, ce.time.sleep, ce.time.monotonic)
        ce.gh_json = gh_json
        ce.time.sleep = lambda seconds: clock.__setitem__(0, clock[0] + seconds)
        ce.time.monotonic = lambda: clock[0]
        self.addCleanup(lambda: (setattr(ce, "gh_json", originals[0]), setattr(ce.time, "sleep", originals[1]),
                                 setattr(ce.time, "monotonic", originals[2])))
        args = type("Args", (), {"repo": "o/r", "event": None, "include_schedule": False, "deadline": 7200})
        return ce.wait_for_runs(args, {"sha": "a" * 40}), calls

    def test_wait_returns_once_the_same_finished_runs_show_twice(self) -> None:
        a, b = run(1, "CI", "completed", "success"), run(2, "Web", "completed", "success", workflow=2)
        runs, calls = self.wait([[run(1, "CI", "in_progress", None)], [a], [a, b], [a, b]])
        self.assertEqual([r["name"] for r in runs], ["CI", "Web"])
        self.assertEqual(len(calls), 4)  # pending; done; a late run appeared; the same again

    def test_wait_gives_up_when_gh_keeps_failing(self) -> None:
        with self.assertRaises(ce.GhError):
            self.wait([ce.GhError("HTTP 401: Bad credentials")])


if __name__ == "__main__":
    sys.exit(unittest.main())
