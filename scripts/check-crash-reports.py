#!/usr/bin/env python3
"""Summarize the Waycar crash reports a simulator test run produced.

macOS ReportCrash writes a simulator app crash to
~/Library/Logs/DiagnosticReports/<Process>-YYYY-MM-DD-HHMMSS.ips: a one-line
JSON header, then one JSON body. Many worktrees and CI share this Mac, so only
reports newer than the run start, from the run's simulators (UDID in
coalitionName or procPath), and for com.otreva.waycar* bundles count.
xcodebuild relaunches the test host after each crash, so one crashing test
leaves several reports; they are grouped by exception, top app frame and test.
A simulated report (header `is_simulated`, e.g. ExcUserFault_*: a fault the
system logged while the process kept running) is printed as a note and does
not count.

Exit 0 when the run left no report, 1 when it did, 2 on usage errors, 3 when
the reports directory cannot be listed.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import datetime
from pathlib import Path


DEFAULT_REPORTS_DIR = Path.home() / "Library/Logs/DiagnosticReports"
BUNDLE_PREFIX = "com.otreva.waycar"
# ReportCrash writes the file a moment after the process dies.
DEFAULT_SETTLE_SECONDS = 3.0
# Debug builds put app code in Waycar.debug.dylib; tests, widgets and other
# targets are images named Waycar*.
APP_IMAGE_PREFIX = "Waycar"
TEST_IMAGE_PREFIX = "WaycarTests"
# Compiler-synthesized locations say nothing about where the code lives.
SYNTHETIC_SOURCE = re.compile(r"^(?:/?<|@__swiftmacro)")
# `FooTests.testBar(` in Swift symbols, `-[FooTests testBar]` in Objective-C.
TEST_SYMBOL = re.compile(r"\b(\w*Tests)\.(\w+)\(|\[(\w*Tests) (\w+)\]")


# The body's captureTime, e.g. `2026-10-12 21:09:08.2870 -0400`.
CAPTURE_TIME_FORMAT = "%Y-%m-%d %H:%M:%S.%f %z"


def parse_since(value: str) -> float:
    try:
        return float(value)
    except ValueError:
        pass
    # Python 3.9's fromisoformat rejects a trailing Z.
    if value.endswith(("Z", "z")):
        value = value[:-1] + "+00:00"
    try:
        moment = datetime.fromisoformat(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected epoch seconds or ISO 8601, got {value!r}") from None
    # A naive time is local, as datetime.timestamp() assumes.
    return moment.timestamp()


def parse_udid(value: str) -> str:
    if not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", value):
        raise argparse.ArgumentTypeError(f"not a simulator UDID: {value!r}")
    return value.upper()


def load_report(path: Path) -> tuple[dict, dict]:
    """The header and body of an .ips report; ValueError/OSError when unusable."""
    text = path.read_text(encoding="utf-8", errors="replace")
    header_line, _, body_text = text.partition("\n")
    header = json.loads(header_line)
    body = json.loads(body_text) if body_text.strip() else {}
    if not isinstance(header, dict) or not isinstance(body, dict):
        raise ValueError("not a JSON object")
    return header, body


def as_dict(value: object) -> dict:
    return value if isinstance(value, dict) else {}


def as_list(value: object) -> list:
    return value if isinstance(value, list) else []


def bundle_id(header: dict, body: dict) -> str:
    return str(header.get("bundleID") or as_dict(body.get("bundleInfo")).get("CFBundleIdentifier") or "")


def from_simulators(body: dict, udids: set[str]) -> bool:
    places = f"{body.get('coalitionName') or ''} {body.get('procPath') or ''}".upper()
    return any(udid in places for udid in udids)


def faulting_frames(body: dict) -> list[tuple[str, dict]]:
    """(image name, frame) for the crashed thread, outermost call last."""
    threads = as_list(body.get("threads"))
    index = body.get("faultingThread")
    if isinstance(index, int) and 0 <= index < len(threads):
        thread = as_dict(threads[index])
    else:
        thread = next((as_dict(t) for t in threads if as_dict(t).get("triggered")), {})
    images = as_list(body.get("usedImages"))
    frames = []
    for frame in as_list(thread.get("frames")):
        frame = as_dict(frame)
        image_index = frame.get("imageIndex")
        image = ""
        if isinstance(image_index, int) and 0 <= image_index < len(images):
            image = str(as_dict(images[image_index]).get("name") or "")
        frames.append((image, frame))
    return frames


def describe_frame(image: str, frame: dict) -> str:
    symbol = str(frame.get("symbol") or f"{image or '?'}+{frame.get('imageOffset', '?')}")
    source = frame.get("sourceFile")
    if source and not SYNTHETIC_SOURCE.match(str(source)):
        line = frame.get("sourceLine")
        return f"{symbol} ({source}:{line})" if line is not None else f"{symbol} ({source})"
    return symbol


def top_app_frame(frames: list[tuple[str, dict]]) -> str:
    """The innermost app frame, preferring one with a real source location
    (closures inlined from a function often report only <stdin>)."""
    app = [(image, frame) for image, frame in frames if image.startswith(APP_IMAGE_PREFIX)]
    for image, frame in app:
        source = frame.get("sourceFile")
        if source and frame.get("sourceLine") is not None and not SYNTHETIC_SOURCE.match(str(source)):
            return describe_frame(image, frame)
    return describe_frame(*app[0]) if app else "(no Waycar frame)"


def test_name(frames: list[tuple[str, dict]]) -> str:
    for image, frame in frames:
        if not image.startswith(TEST_IMAGE_PREFIX):
            continue
        match = TEST_SYMBOL.search(str(frame.get("symbol") or ""))
        if match:
            suite, test = (match.group(1), match.group(2)) if match.group(1) else (match.group(3), match.group(4))
            return f"{suite}.{test}"
    return "(no test frame)"


def exception_name(header: dict, body: dict) -> str:
    exception = as_dict(body.get("exception"))
    kind = exception.get("type")
    if not kind:
        return f"bug_type {header.get('bug_type', '?')}"
    signal = exception.get("signal")
    return f"{kind} ({signal})" if signal else str(kind)


def capture_time(body: dict) -> float | None:
    """The body's captureTime as epoch seconds; None when missing or unparseable."""
    value = body.get("captureTime")
    if not isinstance(value, str):
        return None
    try:
        return datetime.strptime(value, CAPTURE_TIME_FORMAT).timestamp()
    except ValueError:
        return None


class ListingError(Exception):
    pass


def collect(reports_dir: Path, since: float, udids: set[str]) -> tuple[dict, list[str]]:
    """Grouped matching reports and one-line notes about skipped files."""
    groups: dict[tuple[str, str, str], list[Path]] = {}
    notes = []
    try:
        candidates = sorted(path for path in reports_dir.iterdir() if path.suffix == ".ips")
    except FileNotFoundError:
        return groups, notes
    except OSError as error:
        raise ListingError(f"error: cannot list {reports_dir}: {error}") from None
    for path in candidates:
        try:
            # Cheap stat first: the directory holds every report on this Mac.
            if path.stat().st_mtime < since:
                continue
            header, body = load_report(path)
        except (OSError, ValueError) as error:
            notes.append(f"Skipped unreadable {path.name}: {type(error).__name__}: {error}")
            continue
        # macOS bumps the mtime of old merged reports; trust captureTime.
        captured = capture_time(body)
        if captured is not None and captured < since:
            continue
        if not bundle_id(header, body).startswith(BUNDLE_PREFIX) or not from_simulators(body, udids):
            continue
        frames = faulting_frames(body)
        if header.get("is_simulated"):
            notes.append(f"Not a crash, not counted: {path.name} ({exception_name(header, body)}, "
                         f"frame {top_app_frame(frames)}) is a simulated report; the process was not killed.")
            continue
        signature = (exception_name(header, body), top_app_frame(frames), test_name(frames))
        groups.setdefault(signature, []).append(path)
    return groups, notes


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--since", required=True, type=parse_since,
                        help="run start, epoch seconds or ISO 8601; older reports are ignored")
    parser.add_argument("--udid", required=True, action="append", type=parse_udid,
                        help="a simulator the run used; repeat for several")
    parser.add_argument("--reports-dir", type=Path, default=DEFAULT_REPORTS_DIR)
    parser.add_argument("--settle", type=float, default=DEFAULT_SETTLE_SECONDS,
                        help="seconds to wait for ReportCrash before scanning")
    arguments = parser.parse_args(argv)
    if arguments.settle < 0:
        parser.error("--settle must not be negative")

    if arguments.settle:
        time.sleep(arguments.settle)
    try:
        groups, notes = collect(arguments.reports_dir, arguments.since, set(arguments.udid))
    except ListingError as error:
        print(error, file=sys.stderr)
        return 3
    for note in notes:
        print(note, file=sys.stderr)
    if not groups:
        print("No Waycar crash reports from this run.")
        return 0

    total = sum(len(paths) for paths in groups.values())
    print(f"error: {total} Waycar crash report(s) from this run in {arguments.reports_dir}, "
          f"{len(groups)} distinct cause(s):")
    ordered = sorted(groups.items(), key=lambda item: (-len(item[1]), str(item[1][0])))
    for number, ((exception, frame, test), paths) in enumerate(ordered, 1):
        print(f"[{number}] {len(paths)}x {exception}")
        print(f"    frame:   {frame}")
        print(f"    test:    {test}")
        print(f"    reports: {', '.join(path.name for path in paths)}")
    print("Investigate every crash above before calling the work done.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
