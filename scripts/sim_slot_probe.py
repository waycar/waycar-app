"""Simulator, process, and target lookups for sim-slot.py (refs #25).

Read-only: nothing here boots, shuts down, or touches queue state. xcrun and
ps are found on PATH so tests can fake them.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
from contextlib import suppress
from pathlib import Path
from typing import Any, NamedTuple, Union


COMMAND_SECONDS = 120
RUNNER = Path(__file__).resolve().parent / "run-app-simulator-tests.py"
UDID_PATTERN = re.compile(r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}", re.I)

Devices = dict[str, dict[str, Any]]


class Process(NamedTuple):
    ppid: int
    elapsed: int  # Seconds since it started.
    cpu_seconds: float  # CPU time used, exited children included (ps -S).
    cpu_percent: float  # Recent %CPU, a decaying average.
    args: str  # The command line, upper-cased.


Processes = dict[int, Process]
# What one target asks for: a UDID, or a model pool {"name", "type", "runtime"}.
Want = Union[str, dict[str, str]]


class Failure(Exception):
    def __init__(self, message: str, status: int = 1) -> None:
        super().__init__(message)
        self.status = status


class Transient(Failure):
    """A simctl/ps call failed or hung; a waiter retries it."""


def log(message: str) -> None:
    print(f"sim-slot: {message}", file=sys.stderr, flush=True)


def run(*command: str, timeout: float = COMMAND_SECONDS) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, capture_output=True, text=True, errors="replace", timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Transient(f"{' '.join(command[:3])}: {error}") from None


def list_devices() -> Devices:
    result = run("xcrun", "simctl", "list", "devices", "--json")
    try:
        listed = json.loads(result.stdout)["devices"] if result.returncode == 0 else None
    except (ValueError, KeyError):
        listed = None
    if listed is None:
        raise Transient(f"cannot list simulators: {result.stderr.strip() or 'bad output'}")
    # Old copies of this script read only name and state; the other keys are additive.
    return {device["udid"].upper(): {"name": device.get("name", "?"), "state": device.get("state", ""),
                                     "type": device.get("deviceTypeIdentifier", ""), "runtime": runtime,
                                     "available": device.get("isAvailable", True)}
            for runtime, devices in listed.items() for device in devices}


def shared(name: str) -> bool:
    """`Waycar CI` and `Waycar #<issue>` simulators are never part of the shared set."""
    return not name.startswith("Waycar ")


def candidates(devices: Devices, want: Want) -> list[str]:
    """The simulators that can serve a want: a UDID itself, or every available
    simulator of the pool's device type and runtime named `<name>` or
    `<name> <N>`, in that order. Only a shared name makes a pool (resolve)."""
    if isinstance(want, str):
        return [want] if want in devices else []
    copy = re.compile(re.escape(want["name"]) + r"(?: ([0-9]+))?")
    members = []
    for udid, device in devices.items():
        named = copy.fullmatch(device["name"])
        if named and device.get("available", True) and (device.get("type"), device.get("runtime")) == (
                want["type"], want["runtime"]):
            members.append((int(named.group(1) or 0), udid))
    return [udid for _, udid in sorted(members)]


def describe(devices: Devices, want: Want) -> str:
    if isinstance(want, str):
        return f"{devices.get(want, {}).get('name', '?')} ({want})"
    return f"any {want['name']} ({len(candidates(devices, want))} in pool)"


def clock_seconds(clock: str) -> float:
    """`[[dd-]hh:]mm:ss[.ss]` (ps etime and time) in seconds."""
    days, _, rest = clock.rpartition("-")
    total = 0.0
    for part in rest.split(":"):
        total = total * 60 + float(part.replace(",", "."))
    return total + int(days or 0) * 86400


def processes() -> Processes:
    """One ps snapshot of every process."""
    result = run("ps", "-S", "-axo", "pid=,ppid=,etime=,time=,%cpu=,args=")
    if result.returncode != 0:
        raise Transient(f"ps failed: {result.stderr.strip()}")
    table: Processes = {}
    for fields in (line.split(None, 5) for line in result.stdout.splitlines()):
        with suppress(ValueError, IndexError):
            table[int(fields[0])] = Process(int(fields[1]), int(clock_seconds(fields[2])), clock_seconds(fields[3]),
                                            float(fields[4].replace(",", ".")), fields[5].upper() if fields[5:] else "")
    return table


def lineage(pids: set[int], table: Processes) -> set[int]:
    """The pids and all their ancestors (make, shells, the agent itself)."""
    seen: set[int] = set()
    for pid in pids:
        while pid > 1 and pid not in seen:
            seen.add(pid)
            pid = table[pid].ppid if pid in table else 0
    return seen


def tree_cpu(pid: int, table: Processes) -> float:
    """CPU seconds a process and all its descendants have used."""
    children: dict[int, list[int]] = {}
    for child, process in table.items():
        children.setdefault(process.ppid, []).append(child)
    total, pending = 0.0, [pid]
    while pending:
        current = pending.pop()
        total += table[current].cpu_seconds if current in table else 0.0
        pending += children.get(current, [])
    return total


# `simctl diagnose` from any Xcode path, run directly or through xcrun.
DIAGNOSE = re.compile(r"(?:^|/)(?:XCRUN\s+)?SIMCTL\s+DIAGNOSE\b")


def diagnoses(table: Processes) -> set[int]:
    """`simctl diagnose` processes; of a wrapper (a shell, xcrun) and the
    diagnose it runs, only the innermost."""
    found = {pid for pid, process in table.items() if DIAGNOSE.search(process.args)}
    return found - {table[pid].ppid for pid in found}


def in_simulator_apps(udid: str) -> str:
    """The path prefix of apps installed in a simulator (the test host, the
    XCTest runner, an app Xcode or `simctl launch` started)."""
    return f"DEVICES/{udid}/DATA/CONTAINERS/BUNDLE/APPLICATION/"


def test_cpu(udid: str, table: Processes) -> float:
    """Recent %CPU of a test run on this simulator: xcodebuild naming it plus
    the apps installed in it."""
    apps = in_simulator_apps(udid)
    return sum(process.cpu_percent for process in table.values()
               if apps in process.args or ("XCODEBUILD" in process.args and udid in process.args))


def answers(udid: str, timeout: float) -> bool:
    """The cheap launch health check: launchctl inside the simulator responds."""
    with suppress(Transient):
        return run("xcrun", "simctl", "spawn", udid, "launchctl", "print", "system", timeout=timeout).returncode == 0
    return False


def referenced(devices: Devices, table: Processes, excluded: set[int]) -> tuple[set[str], set[str]]:
    """Simulators a host process (xcodebuild, simctl, make...) names, by UDID
    and by `name=`. Processes inside a simulator (Devices/<UDID> paths) don't count."""
    # ponytail: host-process args as the activity signal, blind to hands-on
    # Simulator.app use, upgrade to per-device CPU sampling if that bites.
    by_name: dict[str, set[str]] = {}
    for udid, device in devices.items():
        by_name.setdefault(device["name"].upper(), set()).add(udid)
    names = sorted(by_name, key=len, reverse=True)  # iPhone 17 Pro before iPhone 17
    by_udid: set[str] = set()
    named: set[str] = set()
    for pid, process in table.items():
        args = process.args
        if pid in excluded:
            continue
        by_udid.update(match.group(0) for match in UDID_PATTERN.finditer(args)
                       if not args.endswith("DEVICES/", 0, match.start()))
        for match in re.finditer("NAME=", args):
            named |= next((by_name[name] for name in names if args.startswith(name, match.end())), set())
    return by_udid, named


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except PermissionError:
        return True
    except (ProcessLookupError, OverflowError, ValueError):
        return False


def ci_claims(roots: list[Path]) -> set[str]:
    """Mirror run-ci-ios-tests.sh lock_is_stale: a device claim is live while
    its pid runs with the start time the claim recorded."""
    held = set()
    for claim in (claim for root in roots for claim in root.glob("device-*")):
        try:
            pid = int((claim / "pid").read_text().strip())
            start = (claim / "start").read_text().strip()
        except (OSError, ValueError):
            continue
        if start and pid_alive(pid) and run("ps", "-o", "lstart=", "-p", str(pid)).stdout.strip() == start:
            held.add(claim.name[len("device-"):].upper())
    return held


def current_owner() -> str:
    with suppress(Transient):
        result = run("git", "rev-parse", "--show-toplevel")
        if result.returncode == 0 and result.stdout.strip():
            return os.path.realpath(result.stdout.strip())
    return os.path.realpath(os.getcwd())


def resolve(targets: list[str]) -> list[Want]:
    """What each target asks for. A UDID, an `id=` destination, or a name
    outside the shared set pins that simulator; any other name or destination
    (resolved like the app test runner) asks for any simulator in that one's
    pool, `<name>` plus `<name> <N>`, so a copy's own name in effect pins that
    copy. A target equal to an earlier one adds nothing; generic destinations
    need no simulator and drop out."""
    wants: list[Want] = []
    runner = None
    devices: Devices | None = None
    for target in targets:
        want: Want = target.upper()
        if not UDID_PATTERN.fullmatch(target):
            destination = target if "=" in target else f"platform=iOS Simulator,name={target}"
            if runner is None:
                spec = importlib.util.spec_from_file_location("waycar_simulator_runner", RUNNER)
                assert spec is not None and spec.loader is not None
                runner = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(runner)
            try:
                udid = runner.pin_destination([destination], 0)
            except (ValueError, KeyError, subprocess.CalledProcessError) as error:
                raise Failure(f"cannot resolve {target!r}: {error}") from None
            if udid is None:
                log(f"{target!r} needs no simulator")
                continue
            want = udid.upper()
            if not re.search(r"(?:^|,)id=", destination):
                devices = devices or list_devices()
                device = devices.get(want)
                if device and device.get("type") and shared(device["name"]):
                    want = {"name": device["name"], "type": device["type"], "runtime": device["runtime"]}
        if want not in wants:
            wants.append(want)
    return wants
