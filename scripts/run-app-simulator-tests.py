#!/usr/bin/env python3
"""Run xcodebuild on simulators prepared for app tests (refs #339).

make test-app, make screenshots, and the CI app lane use this entrypoint; every
simulator -destination is prepared: the accessibility tree is enabled, and the
software keyboard is shown even on a simulator that once saw a hardware
keyboard. These simulator preferences are test infrastructure, not app APIs;
recheck them on SDK upgrades. Only the owned keys are restored, including
their original absence/type. After a test action, pass or fail, the Waycar
crash reports those simulators left are printed and fail the run.
"""

from __future__ import annotations

import json
import os
import plistlib
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


PREFERENCES = {
    ("com.apple.Accessibility", "AccessibilityEnabled"): True,
    ("com.apple.Accessibility", "ApplicationAccessibilityEnabled"): 1,
    # A simulator that ever had a hardware keyboard (Simulator.app connects the
    # Mac's) records HardwareKeyboardLastSeen and from then on minimizes the
    # software keyboard, so focusing a text field presents none and the
    # keyboard tests fail on it alone. A fresh simulator has neither key.
    ("com.apple.keyboard.preferences", "AutomaticMinimizationEnabled"): False,
}
DOMAINS = sorted({domain for domain, _ in PREFERENCES})
TEST_ACTIONS = {"test", "test-without-building"}
# After a failure xcodebuild otherwise runs `simctl diagnose`, which can hang for
# its full 600 s timeout while the run still holds its simulator lease.
NO_DIAGNOSTICS = ["-collect-test-diagnostics", "never"]
# run-with-timeout.py SIGKILLs the whole process group 30 s after its SIGTERM
# (KILL_GRACE_SECONDS). xcodebuild gets this long to exit after a forwarded
# signal, then SIGKILL, so the preference restore runs in the rest of that grace.
FORWARDED_SIGNAL_GRACE_SECONDS = 2.0
WAIT_POLL_SECONDS = 0.25
CRASH_CHECKER = Path(__file__).resolve().parent / "check-crash-reports.py"


def simctl(*arguments: str) -> bytes:
    return subprocess.check_output(["xcrun", "simctl", *arguments])


def pin_destinations(arguments: list[str]) -> list[str]:
    """Pin every simulator -destination to its UDID; return those UDIDs in order."""
    indices = [index + 1 for index, argument in enumerate(arguments) if argument == "-destination"]
    if not indices:
        raise ValueError("App tests require at least one -destination")
    udids = []
    for index in indices:
        udid = pin_destination(arguments, index)
        if udid is not None and udid not in udids:
            udids.append(udid)
    return udids


def pin_destination(arguments: list[str], index: int) -> str | None:
    """Resolve names once so preparation and xcodebuild use the same device."""
    destination = dict(part.split("=", 1) for part in arguments[index].split(","))
    if destination.get("platform") != "iOS Simulator":
        return None
    if "id" in destination:
        return destination["id"]

    runtimes = json.loads(simctl("list", "runtimes", "--json"))["runtimes"]
    devices = json.loads(simctl("list", "devices", "available", "--json"))["devices"]
    requested_os = destination.get("OS", "latest")
    candidates = []
    for runtime in runtimes:
        if not runtime["isAvailable"] or runtime.get("platform") != "iOS":
            continue
        if requested_os != "latest" and runtime["version"] != requested_os:
            continue
        version = tuple(int(part) for part in runtime["version"].split("."))
        for device in devices.get(runtime["identifier"], []):
            if device["name"] == destination.get("name"):
                candidates.append((version, device["udid"]))
    if not candidates:
        raise ValueError(f"No available simulator matches {arguments[index]}")
    # Multiple installed runtime builds can report the same device. Deduplicate
    # before rejecting genuinely ambiguous names on the selected OS version.
    latest = max(version for version, _ in candidates)
    matches = {udid for version, udid in candidates if version == latest}
    if len(matches) != 1:
        raise ValueError("Simulator name is ambiguous; use SIM_DESTINATION with id=<UDID>")
    udid = matches.pop()
    destination.pop("name", None)
    destination.pop("OS", None)
    destination["id"] = udid
    arguments[index] = ",".join(f"{key}={value}" for key, value in destination.items())
    return udid


def read_domain(udid: str, domain: str) -> dict:
    return plistlib.loads(simctl("spawn", udid, "defaults", "export", domain, "-"))


def write_preference(udid: str, domain: str, key: str, value: bool | int | None) -> None:
    if value is None:
        simctl("spawn", udid, "defaults", "delete", domain, key)
    else:
        kind = "-bool" if type(value) is bool else "-int"
        simctl("spawn", udid, "defaults", "write", domain, key, kind, str(value).lower())


def restore_preferences(changed: list[tuple[str, str, str]], originals: dict) -> bool:
    """Put every changed key back to its original value or absence; whether all
    succeeded. Each device and domain restores concurrently, inside the grace a
    watchdog's SIGTERM leaves before its SIGKILL."""
    groups: dict[tuple[str, str], list[str]] = {}
    for udid, domain, key in changed:
        groups.setdefault((udid, domain), []).append(key)

    def restore_domain(udid: str, domain: str, keys: list[str]) -> list[str]:
        try:
            current = read_domain(udid, domain)
        except (subprocess.CalledProcessError, OSError, ValueError) as error:
            return [f"Could not restore {domain} on {udid}: {error}"]
        errors = []
        for key in keys:
            original = originals[udid][(domain, key)]
            # A write that failed before creating the key needs no deletion.
            if original is None and key not in current:
                continue
            try:
                write_preference(udid, domain, key, original)
            except (subprocess.CalledProcessError, OSError) as error:
                errors.append(f"Could not restore {domain}/{key} on {udid}: {error}")
        return errors

    if not groups:
        return True
    with ThreadPoolExecutor(max_workers=len(groups)) as pool:
        results = list(pool.map(lambda item: restore_domain(*item[0], item[1]), groups.items()))
    errors = [error for result in results for error in result]
    for error in errors:
        print(error, file=sys.stderr)
    return not errors


def check_crash_reports(since: float, udids: list[str]) -> bool:
    """Print the Waycar crash reports the run's simulators left since it
    started; whether there were none and the check itself worked."""
    udid_arguments = [argument for udid in udids for argument in ("--udid", udid)]
    # Harnesses with fake simulators set these so a real crash elsewhere on
    # this Mac cannot fail them, and so they skip the ReportCrash settle.
    overrides = []
    settle = os.environ.get("WAYCAR_CRASH_REPORT_SETTLE_SECONDS")
    if settle:
        overrides += ["--settle", settle]
    reports_dir = os.environ.get("WAYCAR_CRASH_REPORTS_DIR")
    if reports_dir:
        overrides += ["--reports-dir", reports_dir]
    try:
        status = subprocess.call([sys.executable, str(CRASH_CHECKER), "--since", repr(since),
                                  *udid_arguments, *overrides])
    except OSError as error:
        print(f"Could not check crash reports: {error}", file=sys.stderr)
        return False
    if status not in (0, 1):
        print(f"Crash report check failed with status {status}", file=sys.stderr)
    return status == 0


def run(arguments: list[str]) -> int:
    if TEST_ACTIONS.intersection(arguments) and NO_DIAGNOSTICS[0] not in arguments:
        arguments = [*arguments, *NO_DIAGNOSTICS]
    udids = pin_destinations(arguments)
    if not udids:
        return subprocess.call(["xcodebuild", *arguments])

    originals = {}
    for udid in udids:
        # -b boots a shut-down device and waits for its services before defaults
        # or the test host can start. CI already overlaps this boot with compilation.
        subprocess.run(["xcrun", "simctl", "bootstatus", udid, "-b"], check=True)
        current = {domain: read_domain(udid, domain) for domain in DOMAINS}
        originals[udid] = {(domain, key): current[domain].get(key) for domain, key in PREFERENCES}
        for (domain, key), value in originals[udid].items():
            if value is not None and type(value) not in (bool, int):
                raise ValueError(f"Cannot safely restore {domain}/{key}: unexpected preference type")

    changed = []
    child = None
    interrupted = 0
    interrupted_at = None

    def interrupt(signum: int, _frame: object) -> None:
        nonlocal interrupted, interrupted_at
        interrupted = signum
        if interrupted_at is None:
            interrupted_at = time.monotonic()
        if child is not None:
            try:
                child.send_signal(signum)
            except ProcessLookupError:
                pass
        else:
            raise SystemExit(128 + signum)

    # A hangup ends the run too (make over `ssh -t`, a closed terminal), so it
    # restores like the others. A signal ignored on entry (nohup, a background
    # job) stays ignored, for xcodebuild as well.
    previous_handlers = {
        signum: signal.signal(signum, interrupt)
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
        if signal.getsignal(signum) is not signal.SIG_IGN
    }
    status = 1
    started = None
    try:
        for udid in udids:
            for (domain, key), value in PREFERENCES.items():
                # Record before writing so a cancelled/failed write is also restored.
                changed.append((udid, domain, key))
                write_preference(udid, domain, key, value)
            print(f"==> Simulator {udid}: accessibility and software keyboard prepared for app tests", flush=True)
        started = time.time()
        child = subprocess.Popen(["xcodebuild", *arguments])
        status = None
        while status is None:
            try:
                status = child.wait(timeout=WAIT_POLL_SECONDS)
            except subprocess.TimeoutExpired:
                if interrupted_at is not None \
                        and time.monotonic() - interrupted_at >= FORWARDED_SIGNAL_GRACE_SECONDS:
                    child.kill()
                    status = child.wait()
        status = 128 + interrupted if interrupted else (128 - status if status < 0 else status)
    finally:
        # Let cleanup finish if the watchdog signals the whole process group.
        for signum in previous_handlers:
            signal.signal(signum, signal.SIG_IGN)
        restored = restore_preferences(list(reversed(changed)), originals)
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        if not restored and status == 0:
            status = 1
    # A watchdog's SIGKILL follows its SIGTERM within seconds; a signalled run
    # has already failed and has no time for the ReportCrash settle.
    if started is not None and TEST_ACTIONS.intersection(arguments):
        if interrupted:
            print("==> Crash report check skipped: the run was interrupted", file=sys.stderr)
        elif not check_crash_reports(started, udids) and status == 0:
            status = 1
    return status


def main() -> int:
    try:
        return run(sys.argv[1:])
    except (subprocess.CalledProcessError, OSError, ValueError) as error:
        print(f"App simulator test setup failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
