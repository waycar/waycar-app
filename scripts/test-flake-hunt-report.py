#!/usr/bin/env python3
"""Exercise scripts/ci/flake-hunt-report.py on hunt folders built from saved
snippets of real job logs (scripts/testdata/ci-evidence/) and lines cut from
real failing runs. No network."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # leave no __pycache__ beside the script
ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "scripts" / "testdata" / "ci-evidence"
spec = importlib.util.spec_from_file_location(
    "flake_hunt_report", ROOT / "scripts" / "ci" / "flake-hunt-report.py")
fhr = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = fhr  # dataclasses resolve string annotations through it
assert spec.loader
spec.loader.exec_module(fhr)

# Lines from hosted CI (main 30338ef) and Mac runs, with xcodebuild's list of
# failing tests in both of its forms.
CONSOLE_ISSUE = (
    "✘ Test aStaleMissingPluginReadStillDrainsTheNewConnectionsFollowUp() recorded an issue at "
    "HostConsoleProjectionLifecycleTests.swift:152:9: Expectation failed: "
    "await transport.agentSummaryReads == 2\n")
CONSOLE_OTHER_LINE = (
    "✘ Test aStaleMissingPluginReadStillDrainsTheNewConnectionsFollowUp() recorded an issue at "
    "HostConsoleProjectionLifecycleTests.swift:149:9: Expectation failed: reads\n")
PARAMETERIZED_ISSUE = (
    "✘ Test a_controlNoRetire(_:) recorded an issue with 1 argument run → 1 at "
    "ZZProbeTests.swift:50:21: Issue recorded\n")
RUN_FAILED = "✘ Test run with 7560 tests in 659 suites failed after 600.1 seconds with 1 issue.\n"
FAILING_CONSOLE = (
    "Failing tests:\n"
    "\tHostConsoleProjectionLifecycleTests.aStaleMissingPluginReadStillDrainsTheNewConnectionsFollowUp()\n"
    "\n** TEST FAILED **\n")
FAILING_BOTH = (
    "Failing tests:\n"
    "\tHostConsoleProjectionLifecycleTests.aStaleMissingPluginReadStillDrainsTheNewConnectionsFollowUp()\n"
    "\t-[ZZProbeTests a_controlNoRetire(_:)]\n"
    "\t-[ZZProbeTests a_controlNoRetire(_:)]\n"
    "\n** TEST FAILED **\n")


def write_job(root: Path, name: str, files: dict[str, str]) -> Path:
    folder = root / name
    folder.mkdir()
    for file, text in files.items():
        (folder / file).write_text(text, encoding="utf-8")
    return folder


class FlakeHuntReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def rows(self, text: str) -> list[str]:
        return [line for line in text.splitlines() if line.startswith("| `")]

    def test_groups_a_test_across_passes_whatever_line_failed(self) -> None:
        quiet = write_job(self.root, "quiet", {
            "label": "quiet\n", "passes": "3\n",
            "pass-1.status": "65\n",
            "pass-1.log": CONSOLE_ISSUE + CONSOLE_ISSUE + RUN_FAILED + FAILING_CONSOLE,
            "pass-2.status": "65\n",
            "pass-2.log": CONSOLE_OTHER_LINE + PARAMETERIZED_ISSUE + RUN_FAILED + FAILING_BOTH,
            "pass-3.status": "0\n",
            "pass-3.log": "✔ Test run with 7560 tests in 659 suites passed after 400.0 seconds.\n",
        })
        text = fhr.report([quiet])
        self.assertIn("## Flake hunt: 2 failing test(s) in 3 pass(es)", text)
        rows = self.rows(text)
        self.assertIn(
            "`HostConsoleProjectionLifecycleTests.aStaleMissingPluginReadStillDrainsTheNewConnectionsFollowUp()`",
            rows[0])
        self.assertIn("2 of 3 (quiet #1, quiet #2)", rows[0])
        self.assertIn("HostConsoleProjectionLifecycleTests.swift:152: Expectation failed", rows[0])
        self.assertIn("`ZZProbeTests.a_controlNoRetire(_:)` | 1 of 3 (quiet #2)", rows[1])
        self.assertIn("ZZProbeTests.swift:50: Issue recorded", rows[1])
        self.assertIn("| quiet | 1 | 7560 tests, 1 failing |", text)
        self.assertIn("| quiet | 2 | 7560 tests, 2 failing |", text)
        self.assertIn("| quiet | 3 | 7560 tests |", text)

    def test_a_pass_with_no_failing_list_names_tests_from_their_issues(self) -> None:
        quiet = write_job(self.root, "quiet", {
            "label": "quiet\n", "passes": "1\n",
            "pass-1.status": "124\n", "pass-1.log": CONSOLE_ISSUE + CONSOLE_OTHER_LINE,
        })
        text = fhr.report([quiet])
        rows = self.rows(text)
        self.assertEqual(len(rows), 1)
        self.assertIn(
            "`HostConsoleProjectionLifecycleTests.aStaleMissingPluginReadStillDrainsTheNewConnectionsFollowUp()`",
            rows[0])
        self.assertIn("| quiet | 1 | timed out, 1 failing |", text)

    def test_reads_job_logs_crashes_display_names_and_stopped_setups(self) -> None:
        quiet = write_job(self.root, "quiet", {
            "label": "quiet\n", "passes": "4\n",
            "pass-1.status": "65\n",
            "pass-1.log": (DATA / "ios-app-failure-43491553084-132113745445.log").read_text(),
            "pass-2.status": "65\n",
            "pass-2.log": (DATA / "ipad-crash-43729244919-132857817382.log").read_text(),
            "pass-3.status": "124\n",
        })
        loaded = write_job(self.root, "loaded", {
            "label": "loaded\n", "passes": "4\n", "stopped": "build\n", "build.status": "65\n",
            "build.log": "Compiling\n/x/Foo.swift:3:1: error: cannot find 'bar' in scope\n",
        })
        text = fhr.report([quiet, loaded, self.root / "gone"])
        rows = self.rows(text)
        # A display-named test: its issue prints the display name, the list the function.
        tmux = next(row for row in rows if "controlChannelReattachesAfterTmuxExits" in row)
        self.assertIn("TmuxTransportE2ETests.swift:711: Caught error: .timedOut", tmux)
        # A crash ended this one: only the failing list names it.
        crashed = next(row for row in rows if "aTUITapAnywhereRaisesTheKeyboard" in row)
        self.assertIn("`TerminalAttachTests.aTUITapAnywhereRaisesTheKeyboard()` | 1 of 3 (quiet #2)", crashed)
        self.assertIn("no issue recorded (a crash or a timeout ended it)", crashed)
        self.assertRegex(
            text, r"\| quiet \| 2 \| .*1 failing, 1 test host relaunch\(es\), 1 crash report\(s\) \|")
        self.assertIn("| quiet | 3 | timed out |", text)
        self.assertIn("| quiet | 4 | did not run |", text)
        self.assertIn("| loaded | build | exit 65: /x/Foo.swift:3:1: error: cannot find 'bar' in scope |", text)
        self.assertIn("| gone | — | no results (the job did not upload any) |", text)

    def test_a_failed_exit_without_any_failing_test_says_so(self) -> None:
        quiet = write_job(self.root, "quiet", {
            "label": "quiet\n", "passes": "1\n",
            "pass-1.status": "70\n", "pass-1.log": "xcodebuild: error: Unable to find a device\n",
        })
        text = fhr.report([quiet])
        self.assertIn("## Flake hunt: 0 failing test(s) in 1 pass(es)", text)
        self.assertIn("| quiet | 1 | exit 70 with no failing test |", text)

    def test_never_raises_without_folders(self) -> None:
        self.assertIn("no job folders given", fhr.report([]))
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(fhr.main([str(self.root / "gone")]), 0)


if __name__ == "__main__":
    unittest.main()
