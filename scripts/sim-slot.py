#!/usr/bin/env python3
"""Machine-wide queue for booted iOS Simulators (refs #25).

Agents in many worktrees share one Mac; each booted Simulator costs 2-5 GB and
~230 processes. This caps booted Simulators machine-wide (WAYCAR_SIM_SLOTS,
default 4), grants them FIFO, leases each to one worktree, and reclaims those
whose worktree is gone or that sit idle (WAYCAR_SIM_IDLE_MINUTES, default 10)
while others wait. A base model name or a `name=` destination asks for any
simulator of that model's pool (`<name>` plus `<name> <N>` copies of the same
device type and runtime; `ensure-pool` creates missing copies); a UDID, an
`id=` destination, or a copy's own name pins that simulator. State: one
flock-guarded JSON file in WAYCAR_SIM_SLOTS_DIR (default ~/Library/Application
Support/waycar-sim-slots, shared per user) that older copies of this script in
other worktrees read and write too, so its format only ever gains keys.
`acquire` prints the granted UDIDs on stdout, one line per distinct simulator
in target order; `status` prints its table there; `doctor` says why the queue
is stuck and applies only safe fixes (waiters refused for 5 minutes run it too).
Exit codes: 0 ok, 75 no slot with --no-wait, 1 error/timeout/refusal, 2 usage.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import pwd
import signal
import sys
import time
import uuid
from contextlib import contextmanager, suppress
from pathlib import Path
from typing import Any, Iterator

from sim_slot_probe import (DIAGNOSE, UDID_PATTERN, Failure, Processes, Transient, Want, answers, candidates, ci_claims,
                            current_owner, describe, diagnoses, in_simulator_apps, lineage, list_devices, log, pid_alive,
                            processes, referenced, resolve, run, shared, test_cpu, tree_cpu)


EXIT_NO_SLOT = 75
POLL_SECONDS = 15
REPORT_EVERY_SECONDS = 300
BOOT_GRACE_SECONDS = 300
STALE_TICKET_SECONDS = 300  # Waiters heartbeat every poll; this outlives pid reuse.
SAMPLE_GAP_SECONDS = 2 * POLL_SECONDS  # A longer gap between samples restarts idle clocks.
LOCK_WAIT_SECONDS = 120
BOOT_SECONDS = 900
ACTIVE_STATES = {"Booted", "Booting"}
UNHEALTHY_SECONDS = 1800  # A simulator that failed to boot is picked from a pool last for this long.
POOL_SIZE = 2
SNAPSHOT_SCHEMA = 2  # Snapshots old copies wrote lack device types; never reuse those for pools.
DIAGNOSE_QUIET_SECONDS = 180  # A `simctl diagnose` whose CPU (its children's too) stays flat this long is hung.
DIAGNOSE_BUSY_CPU_SECONDS = 1.0  # More CPU than this since its quiet clock started is progress: the clock restarts.
ACTIVE_CPU_PERCENT = 2.0  # A test run (xcodebuild, apps in the simulator) above this is live: never touched.
PROBE_SECONDS = 20  # launchctl inside a healthy booted simulator answers well within this.
PROBE_RETRY_SECONDS = 120  # A simulator is restarted only once probes on doctor runs this far apart both fail,
PROBE_FORGET_SECONDS = 900  # and no further apart than this.
DOCTOR_AFTER_SECONDS = 300  # A waiter refused this long runs the doctor, at most once per interval machine-wide.

State = dict[str, Any]
Snapshot = dict[str, Any]
EMPTY_SNAPSHOT: Snapshot = {"at": 0.0, "devices": {}, "active": [], "ci": []}


def env_number(name: str, default: int) -> int:
    raw = os.environ.get(name, "").strip() or str(default)
    if not raw.isdigit() or int(raw) < 1:
        raise Failure(f"{name} must be a whole number of at least 1, got {raw!r}", 2)
    return int(raw)


class Config:
    def __init__(self) -> None:
        self.slots = env_number("WAYCAR_SIM_SLOTS", 4)
        self.idle_minutes = env_number("WAYCAR_SIM_IDLE_MINUTES", 10)
        home = pwd.getpwuid(os.getuid()).pw_dir  # Not $HOME: one queue per user, whatever the session.
        default = Path(home) / "Library/Application Support/waycar-sim-slots"
        self.directory = Path(os.environ.get("WAYCAR_SIM_SLOTS_DIR") or default).expanduser()
        # run-ci-ios-tests.sh claims devices here; the test-only override adds a root, never replaces it.
        extra = os.environ.get("WAYCAR_SIM_SLOTS_CI_LOCK_ROOT")
        self.ci_locks = [Path("/tmp/waycar-ci-locks")] + ([Path(extra)] if extra else [])


def booted(snapshot: Snapshot) -> set[str]:
    return {udid for udid, device in snapshot["devices"].items() if device["state"] in ACTIVE_STATES}


def in_use(state: State, snapshot: Snapshot) -> set[str]:
    return booted(snapshot) | set(state["leases"])


def name_of(snapshot: Snapshot, udid: str) -> str:
    return snapshot["devices"].get(udid, {}).get("name", "?")


def short(owner: str) -> str:
    return os.path.basename(owner.rstrip("/")) or owner


def shutdown(snapshot: Snapshot, udid: str) -> bool:
    try:
        result = run("xcrun", "simctl", "shutdown", udid)
    except Transient as error:
        log(str(error))
        return False
    if result.returncode != 0 and "current state: Shutdown" not in result.stderr:
        log(f"shutdown {udid} failed: {result.stderr.strip()}")
        return False
    snapshot["devices"].get(udid, {})["state"] = "Shutdown"
    return True


@contextmanager
def locked(config: Config, deadline: float) -> Iterator[State]:
    """Yield the shared state under an exclusive flock; persist any change."""
    config.directory.mkdir(parents=True, exist_ok=True)
    path = config.directory / "state.json"
    with open(config.directory / "lock", "a") as lock:
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.time() >= deadline:
                    raise Failure("timed out waiting for the queue lock; report `make sim-status` to the user")
                time.sleep(0.1)
        state: State = {"leases": {}, "idle": {}, "tickets": [], "snapshot": None, "sampled_at": 0.0}
        try:
            loaded = json.loads(path.read_text())
            state.update(loaded if isinstance(loaded, dict) else {})
        except FileNotFoundError:
            pass
        except (OSError, ValueError) as error:
            log(f"ignoring unreadable {path}: {error}")
        before = json.dumps(state, sort_keys=True)
        yield state
        after = json.dumps(state, sort_keys=True)
        if after != before:  # The flock makes a fixed temporary name safe.
            temporary = path.with_suffix(".tmp")
            temporary.write_text(after)
            os.replace(temporary, path)


def prune_tickets(state: State, now: float) -> None:
    state["tickets"] = sorted(
        (ticket for ticket in state["tickets"]
         if pid_alive(ticket["pid"]) and now - ticket["seen_at"] < STALE_TICKET_SECONDS),
        key=lambda ticket: ticket["created_at"])


def booting(lease: dict[str, Any], now: float) -> bool:
    """A lease whose acquire is still booting it: leave it alone."""
    pid, until = lease.get("booting") or (0, 0.0)
    return now < until and pid_alive(pid)


def owner_gone(owner: str) -> bool:
    """Only a missing worktree counts; an unreadable one (TCC, unmounted) is kept."""
    try:
        os.stat(owner)
    except (FileNotFoundError, NotADirectoryError):
        return True
    except OSError:
        pass
    return False


def refresh(state: State, config: Config, now: float, destructive: bool) -> Snapshot:
    """List simulators and host processes and prune leases. Destructive
    refreshes also reclaim abandoned and idle simulators, drop expired boot
    failures, keep the doctor's clocks (how long each simulator has been
    booting, how long each `simctl diagnose` has used no CPU), and only they
    feed the snapshot waiters share. Waiters and their ancestors (make,
    shells) are not activity; `name=` counts only for unleased simulators,
    since queued runs pin `id=`."""
    devices, table = list_devices(), processes()
    excluded = lineage({ticket["pid"] for ticket in state["tickets"]} | {os.getpid()}, table)
    snapshot = {"at": now, "devices": devices, "ci": sorted(ci_claims(config.ci_locks)), "schema": SNAPSHOT_SCHEMA}
    by_udid, named = referenced(devices, table, excluded)
    live = booted(snapshot)
    snapshot["active"] = sorted((by_udid | (named - set(state["leases"]))) & live)
    for udid, lease in list(state["leases"].items()):
        if destructive and owner_gone(lease["owner"]):
            if udid in live and udid not in snapshot["ci"] and udid not in snapshot["active"]:
                shutdown(snapshot, udid)
            del state["leases"][udid]
            log(f"reclaimed {name_of(snapshot, udid)} {udid} (owner {lease['owner']} no longer exists)")
        elif udid not in live and now - lease["renewed_at"] >= BOOT_GRACE_SECONDS and not booting(lease, now):
            del state["leases"][udid]
    if destructive:
        state["boot_failures"] = {udid: at for udid, at in state.get("boot_failures", {}).items()
                                  if now - at < UNHEALTHY_SECONDS}
        # The doctor's "stuck booting" clock; restarted after a sampling gap.
        previous = (state["snapshot"] or EMPTY_SNAPSHOT)["at"]
        since = state.get("booting_since", {}) if now - previous <= SAMPLE_GAP_SECONDS else {}
        state["booting_since"] = {udid: since.get(udid, now) for udid, device in devices.items()
                                  if device["state"] == "Booting"}
        state["diagnoses"] = diagnose_clocks(state.get("diagnoses", {}), table, now)
        state["snapshot"] = snapshot
        reclaim_idle(state, config, snapshot, now)
    return snapshot


def reclaim_idle(state: State, config: Config, snapshot: Snapshot, now: float) -> None:
    """While a refused ticket waits, shut down simulators idle for IDLE minutes
    of continuous sampling, counted from the lease renewal at the earliest."""
    idle: dict[str, float] = state["idle"]
    waiting = any(ticket.get("blocked_at") for ticket in state["tickets"])
    if not waiting or now - state["sampled_at"] > SAMPLE_GAP_SECONDS:
        idle.clear()
    if not waiting:
        return
    state["sampled_at"] = now
    leases = state["leases"]
    live = booted(snapshot)
    keep = set(snapshot["active"]) | set(snapshot["ci"])
    keep |= {udid for udid, lease in leases.items() if booting(lease, now)}
    # An unleased simulator a ticket can lease as is right now is kept for it.
    for ticket in state["tickets"]:
        picks, problem = plan(state, config, snapshot, ticket["owner"], wants_of(ticket), ticket["id"])
        if problem is None:
            keep |= {udid for udid in picks if udid not in leases}
    for udid in sorted(set(idle) | live):
        lease = leases.get(udid)
        if udid not in live or udid in keep:
            idle.pop(udid, None)
            continue
        since = max(idle.setdefault(udid, now), lease["renewed_at"] if lease else 0.0)
        if now - since >= config.idle_minutes * 60 and shutdown(snapshot, udid):
            leases.pop(udid, None)
            del idle[udid]
            owner = short(lease["owner"]) if lease else "unleased"
            log(f"reclaimed {name_of(snapshot, udid)} {udid} (idle {int((now - since) // 60)}m, owner {owner})")


def foreign(state: State, snapshot: Snapshot, owner: str, udid: str) -> str | None:
    """Why this simulator belongs to someone other than owner, if it does."""
    lease = state["leases"].get(udid)
    if udid in snapshot["ci"]:
        return "is held by a CI run"
    if lease is not None:
        return None if lease["owner"] == owner else f"is leased by {short(lease['owner'])}"
    return "is in use outside the queue" if udid in snapshot["active"] else None


def wants_of(ticket: dict[str, Any]) -> list[Want]:
    """Tickets from old copies of this script have no `wants`: they pin `udids`."""
    return ticket.get("wants") or ticket["udids"]


def blocker(state: State, snapshot: Snapshot, owner: str, udid: str, taken: set[str], mine: set[str]) -> str | None:
    """Why owner's ticket cannot take this simulator now, if it cannot:
    someone else holds it, an earlier ticket takes it, or this ticket takes it
    for another of its targets (mine)."""
    held = foreign(state, snapshot, owner, udid)
    if held:
        return held
    if udid in taken and state["leases"].get(udid, {}).get("owner") != owner:
        return "is wanted by an earlier request"
    if udid in mine:
        return "is granted for another target"
    return None


def shortage(snapshot: Snapshot, want: Want, pool: list[str], reasons: dict[str, str | None]) -> str:
    """Why a want gets none of its pool."""
    if not pool:
        return f"no simulator for {describe(snapshot['devices'], want)}"
    busy = "; ".join(f"{name_of(snapshot, udid)} {udid} {reasons[udid]}" for udid in pool)
    if isinstance(want, str) or len(pool) == 1:
        return busy
    return f"all {len(pool)} {want['name']} simulators are taken: {busy}"


def choose(state: State, snapshot: Snapshot, owner: str, wants: list[Want], taken: set[str],
           pinned: set[str]) -> tuple[list[str], str | None]:
    """One simulator per want, never one an earlier ticket takes or someone
    else holds, nor one another of these wants takes unless that is all its
    pool holds (a UDID plus the name of that same lone simulator). A pool
    prefers the owner's own lease, then one already booted (no added load),
    then a free one; among those, one that booted fine lately and that no
    ticket pins, then pool order. Returns the picks and None, or stand-ins and
    the reason a want has none. A stand-in someone else holds is preferred:
    old copies of this script read the ticket's `udids` and count a ticket
    waiting on someone else's simulator as blocking nobody."""
    devices, leases, used = snapshot["devices"], state["leases"], in_use(state, snapshot)
    unhealthy = {udid for udid, at in state.get("boot_failures", {}).items() if snapshot["at"] - at < UNHEALTHY_SECONDS}
    pools = [candidates(devices, want) for want in wants]
    picks: dict[int, str] = {}
    problem = None
    for index in sorted(range(len(wants)), key=lambda index: len(pools[index])):  # Pinned ones first.
        pool = pools[index]
        mine = set(picks.values())
        if set(pool) <= mine:  # Nothing but what other wants take, as with a UDID and its lone name: share it.
            mine = set()
        reasons = {udid: blocker(state, snapshot, owner, udid, taken, mine) for udid in pool}
        free = [udid for udid in pool if reasons[udid] is None]
        if free:
            picks[index] = min(free, key=lambda udid: (leases.get(udid, {}).get("owner") != owner, udid not in used,
                                                       udid in unhealthy, udid in pinned, pool.index(udid)))
            continue
        if pool:
            picks[index] = next((udid for udid in pool if foreign(state, snapshot, owner, udid)), pool[0])
        problem = problem or shortage(snapshot, wants[index], pool, reasons)
    return list(dict.fromkeys(picks[index] for index in sorted(picks))), problem


def plan(state: State, config: Config, snapshot: Snapshot, owner: str, wants: list[Want],
         ticket_id: str | None) -> tuple[list[str], str | None]:
    """The simulators to lease and None when they can be leased now, else
    stand-ins and the reason. FIFO among tickets needing capacity: each earlier
    ticket that fits reserves its simulators and room, the first that does not
    fit holds back everyone behind it, and one with nothing it can take (all
    held by others) blocks nobody."""
    used = in_use(state, snapshot)
    pinned = {want for ticket in state["tickets"] for want in wants_of(ticket) if isinstance(want, str)}
    taken: set[str] = set()
    load, ahead, full = len(used), 0, False
    for ticket in state["tickets"]:
        if ticket["id"] == ticket_id:
            break
        picks, problem = choose(state, snapshot, ticket["owner"], wants_of(ticket), taken, pinned)
        new = [udid for udid in picks if udid not in used]
        if problem or not new:
            taken.update([] if problem else picks)
            continue
        ahead += 1
        full = full or load + len(new) > config.slots
        if not full:
            taken.update(picks)
            load += len(new)
    picks, problem = choose(state, snapshot, owner, wants, taken, pinned)
    new = [udid for udid in picks if udid not in used]
    if problem or not new:
        return picks, problem  # No added load: a renewal or an already-booted simulator.
    if full or load + len(new) > config.slots:
        return picks, f"{ahead} earlier request(s) waiting" if ahead else f"{len(used)}/{config.slots} slots in use"
    return picks, None


def age(seconds: float) -> str:
    seconds = max(0, int(seconds))
    if seconds < 3600:
        return f"{seconds}s" if seconds < 60 else f"{seconds // 60}m"
    return f"{seconds // 3600}h{seconds % 3600 // 60:02d}m"


def status_lines(state: State, config: Config, snapshot: Snapshot, now: float) -> list[str]:
    used = in_use(state, snapshot)
    lines = [f"Simulator slots: {len(used)}/{config.slots} in use (WAYCAR_SIM_SLOTS); while others wait, "
             f"simulators idle for {config.idle_minutes}m are shut down",
             f"  {'SIMULATOR':<24} {'UDID':<36} {'STATE':<8} {'OWNER':<16} {'LEASE':>5} {'IDLE':>5}"]
    for udid in sorted(used, key=lambda udid: (name_of(snapshot, udid), udid)):
        lease, since = state["leases"].get(udid), state["idle"].get(udid)
        owner = short(lease["owner"]) if lease else "CI" if udid in snapshot["ci"] else "unleased"
        lines.append(f"  {name_of(snapshot, udid)[:24]:<24} {udid} "
                     f"{snapshot['devices'].get(udid, {}).get('state', 'Missing'):<8} {owner:<16} "
                     f"{age(now - lease['acquired_at']) if lease else '-':>5} "
                     f"{age(now - since) if since is not None else '-':>5}")
    lines.append(f"Queue: {len(state['tickets'])} waiting")
    for position, ticket in enumerate(state["tickets"], 1):
        wanted = ", ".join(describe(snapshot["devices"], want) for want in wants_of(ticket))
        since = time.strftime("%H:%M", time.localtime(ticket["created_at"]))
        lines.append(f"  {position}. {short(ticket['owner'])} wants {wanted}; waiting since {since}")
    return lines


def acquire(config: Config, targets: list[str], wait: bool, timeout_minutes: float) -> int:
    wants = resolve(targets)
    if not wants:
        return 0
    if len(wants) > config.slots:
        raise Failure(f"{len(wants)} simulators requested but WAYCAR_SIM_SLOTS is {config.slots}")
    owner = current_owner()
    deadline = time.time() + timeout_minutes * 60
    ticket_id = uuid.uuid4().hex if wait else None
    first, enqueued, granted, last_note, noted_at = True, False, False, "", 0.0
    udids: list[str] = []

    def verdict(state: State, snapshot: Snapshot) -> tuple[list[str], str | None]:
        unknown = [want for want in wants if not candidates(snapshot["devices"], want)]
        if unknown:
            raise Failure(", ".join(f"no simulator with UDID {want}" if isinstance(want, str)
                                    else f"no available {want['name']} simulator" for want in unknown))
        return plan(state, config, snapshot, owner, wants, ticket_id)

    try:
        while True:
            with locked(config, deadline if wait else time.time() + LOCK_WAIT_SECONDS) as state:
                now = time.time()
                if wait:
                    mine = next((ticket for ticket in state["tickets"] if ticket["id"] == ticket_id), None)
                    if mine is None:  # First pass, or dropped as stale while suspended.
                        # `udids` is what old copies of this script read: the current picks.
                        mine = {"id": ticket_id, "pid": os.getpid(), "owner": owner, "wants": wants,
                                "udids": [want for want in wants if isinstance(want, str)], "created_at": now}
                        state["tickets"].append(mine)
                    mine["seen_at"], enqueued = now, True
                prune_tickets(state, now)
                snapshot = state["snapshot"] or EMPTY_SNAPSHOT
                # Waiters share one listing per poll interval; a grant re-lists.
                cached = (wait and not first and 0 <= now - snapshot["at"] < POLL_SECONDS
                          and snapshot.get("schema") == SNAPSHOT_SCHEMA)
                try:
                    if not cached:
                        snapshot = refresh(state, config, now, destructive=True)
                    picks, reason = verdict(state, snapshot)
                    if reason is None and cached:
                        snapshot = refresh(state, config, now, destructive=True)
                        picks, reason = verdict(state, snapshot)
                    if wait:
                        mine["udids"] = picks
                except Transient as error:
                    if not wait:
                        raise
                    reason = f"simulator query failed, retrying ({error})"
                if reason is None:
                    udids = picks
                    created = [udid for udid in udids if udid not in state["leases"]]
                    # Boot and bootstatus each get BOOT_SECONDS; the marker outlives neither.
                    until = now + 2 * len(udids) * BOOT_SECONDS + LOCK_WAIT_SECONDS
                    for udid in udids:
                        lease = state["leases"].setdefault(udid, {"owner": owner, "acquired_at": now})
                        lease["renewed_at"], lease["booting"] = now, [os.getpid(), until]
                        state["idle"].pop(udid, None)
                    state["tickets"] = [ticket for ticket in state["tickets"] if ticket["id"] != ticket_id]
                    granted = True
                    to_boot = [udid for udid in udids if snapshot["devices"][udid]["state"] not in ACTIVE_STATES]
                    names = {udid: name_of(snapshot, udid) for udid in udids}
                    break
                treat = False
                if wait:
                    blocked_at = mine.setdefault("blocked_at", now)  # Only a refused ticket counts as waiting.
                    # Long waiters take turns running the doctor, one run per interval machine-wide.
                    treat = min(now - blocked_at, now - state.get("doctor_at", 0.0)) >= DOCTOR_AFTER_SECONDS
                    if treat:
                        state["doctor_at"] = now
                position = next((index for index, ticket in enumerate(state["tickets"], 1)
                                 if ticket["id"] == ticket_id), 0)
                note = f"{reason}; queue position {position} of {len(state['tickets'])}"
                report = status_lines(state, config, snapshot, now) if now >= deadline else []
            if not wait:
                raise Failure(f"no simulator slot: {reason}; see `make sim-status`", EXIT_NO_SLOT)
            if report:
                print("\n".join(report), file=sys.stderr)
                raise Failure("timed out waiting for a simulator slot; run `make sim-doctor`, never bypass the "
                              "queue, and report its output and `make sim-status` to the user")
            if first:
                log("waiting for a simulator slot; keep doing work that needs no simulator meanwhile "
                    "(`make sim-status` shows the queue, `make sim-doctor` unsticks it)")
            if note != last_note or time.time() - noted_at >= REPORT_EVERY_SECONDS:
                log(f"waiting: {note}")
                last_note, noted_at = note, time.time()
            if treat:
                try:
                    done = examine(config)[1]
                except Failure as error:
                    done = [f"could not run ({error})"]
                for line in done or ["found nothing it may fix; `make sim-doctor` shows why the queue waits"]:
                    log(f"doctor: {line}")
            first = False
            time.sleep(max(0.0, min(POLL_SECONDS, deadline - time.time())))
    finally:
        if enqueued and not granted:
            with suppress(Failure), locked(config, time.time() + 10) as state:
                state["tickets"] = [ticket for ticket in state["tickets"] if ticket["id"] != ticket_id]
    boot(config, owner, udids, to_boot, created, names)
    print("\n".join(udids), flush=True)
    return 0


def boot(config: Config, owner: str, udids: list[str], to_boot: list[str], created: list[str],
         names: dict[str, str]) -> None:
    """Runs outside the lock: a boot can take minutes on a loaded Mac. Boots
    them all, then waits for each, then confirms the leases survived. Any
    failure or signal gives back only what this call leased; renewals stay."""
    failed: list[str] = []
    try:
        for udid in to_boot:
            log(f"booting {names[udid]} {udid}")
            result = run("xcrun", "simctl", "boot", udid, timeout=BOOT_SECONDS)
            if result.returncode != 0 and "current state: Booted" not in result.stderr:
                log(f"boot {udid}: {result.stderr.strip()}")
        for udid in udids:
            if run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=BOOT_SECONDS).returncode != 0:
                failed.append(udid)
        if failed:
            raise Failure(f"could not boot {', '.join(f'{names[udid]} {udid}' for udid in failed)}")
        with locked(config, time.time() + LOCK_WAIT_SECONDS) as state:
            lost = [udid for udid in udids if state["leases"].get(udid, {}).get("owner") != owner]
            if lost:
                raise Failure(f"lost the lease on {', '.join(lost)} while booting")
            for udid in udids:
                state["leases"][udid]["renewed_at"] = time.time()
                state["leases"][udid].pop("booting", None)  # A concurrent renewal may have cleared it.
                state.get("boot_failures", {}).pop(udid, None)
    except BaseException:
        with suppress(Failure), locked(config, time.time() + LOCK_WAIT_SECONDS) as state:
            for udid in failed:  # Pools pick it last for a while (UNHEALTHY_SECONDS).
                state.setdefault("boot_failures", {})[udid] = time.time()
            for udid in udids:
                lease = state["leases"].get(udid)
                if lease is None or lease["owner"] != owner:
                    continue  # Taken over while booting: not ours to touch.
                lease.pop("booting", None)
                if udid in created:
                    del state["leases"][udid]
                    if udid in to_boot or udid in failed:
                        with suppress(Failure):
                            run("xcrun", "simctl", "shutdown", udid)
        raise
    leased = ", ".join(f"{names[udid]} ({udid})" for udid in udids)
    log(f"{short(owner)} holds {leased}; run `make sim-release` when simulator work is done")


def release(config: Config, targets: list[str], everything: bool, force: bool) -> int:
    owner, wants, status = current_owner(), resolve(targets), 0
    with locked(config, time.time() + LOCK_WAIT_SECONDS) as state:
        now = time.time()
        prune_tickets(state, now)
        snapshot = refresh(state, config, now, destructive=True)
        leases = state["leases"]
        udids: list[str] = []
        for want in wants:  # A pool means the copies this owner holds, else the named one.
            pool = [want] if isinstance(want, str) else candidates(snapshot["devices"], want)
            udids += [udid for udid in pool if leases.get(udid, {}).get("owner") == owner] or pool[:1]
        if everything:
            udids += [udid for udid, lease in leases.items() if lease["owner"] == owner]
        udids = list(dict.fromkeys(udids))
        if not udids:
            log(f"{short(owner)} holds no simulators")
        for udid in udids:
            problem = foreign(state, snapshot, owner, udid)
            if not problem and not force and udid not in leases and udid in booted(snapshot):
                problem = "is not leased (hand-booted?); pass --force to shut it down"
            if problem:
                if leases.get(udid, {}).get("owner") == owner:
                    del leases[udid]  # CI-held: give up our lease but never shut it down.
                log(f"refusing to shut down {name_of(snapshot, udid)} {udid}: it {problem}")
                status = 1
            elif udid not in booted(snapshot) or shutdown(snapshot, udid):
                leases.pop(udid, None)
                state["idle"].pop(udid, None)
                log(f"released {name_of(snapshot, udid)} {udid}")
            else:
                status = 1
    return status


def status(config: Config) -> int:
    """Read-only for simulators: prunes queue bookkeeping, never shuts one down."""
    with locked(config, time.time() + LOCK_WAIT_SECONDS) as state:
        now = time.time()
        prune_tickets(state, now)
        snapshot = refresh(state, config, now, destructive=False)
        print("\n".join(status_lines(state, config, snapshot, now)))
    return 0


def ensure_pool(config: Config, targets: list[str], size: int) -> int:
    """Create `<name> <N>` copies (same device type and runtime) until each
    named model's pool has size available simulators. Distinct names keep
    name resolution, old copies of this script included, unambiguous."""
    wants = resolve(targets)
    for want in wants:
        if isinstance(want, str):
            raise Failure(f"ensure-pool takes shared simulator names, not {want} (UDIDs, id= destinations, Waycar CI "
                          "and Waycar #<issue> simulators are never pooled)", 2)
    # Under the queue lock so two runs never pick the same name.
    with locked(config, time.time() + LOCK_WAIT_SECONDS):
        devices = list_devices()
        names = {device["name"] for device in devices.values()}
        for want in wants:
            pool, number = candidates(devices, want), 2
            for _ in range(size - len(pool)):
                while f"{want['name']} {number}" in names:
                    number += 1
                name = f"{want['name']} {number}"
                result = run("xcrun", "simctl", "create", name, want["type"], want["runtime"])
                if result.returncode != 0:
                    raise Failure(f"cannot create {name}: {result.stderr.strip()}")
                names.add(name)
                pool.append(result.stdout.strip().upper())
                log(f"created {name} {pool[-1]}")
            log(f"{want['name']} pool: {', '.join(pool)}")
    return 0


def diagnose_clocks(previous: dict[str, list[float]], table: Processes, now: float) -> dict[str, list[float]]:
    """Per `simctl diagnose` pid: since when it and its descendants have used
    no CPU, as far as the looks so far tell, and their CPU seconds then."""
    clocks = {}
    for pid in diagnoses(table):
        cpu = tree_cpu(pid, table)
        since, base = previous.get(str(pid), (now, cpu))
        if abs(cpu - base) > DIAGNOSE_BUSY_CPU_SECONDS or table[pid].elapsed + 1 < now - since:
            since, base = now, cpu  # It made progress, or its pid now belongs to a newer process.
        clocks[str(pid)] = [since, base]
    return clocks


def stop(pid: int, seen_at: float) -> bool:
    """SIGTERM, then SIGKILL after 5 s, each sent only while pid is still the
    `simctl diagnose` seen at seen_at, never a reused pid; True once it is gone."""
    for signum in (signal.SIGTERM, signal.SIGKILL):
        try:
            process = processes().get(pid)
        except Transient:
            return False
        if process is None or not DIAGNOSE.search(process.args) or process.elapsed + 1 < time.time() - seen_at:
            return True  # It exited; the pid is free or another process's.
        try:
            os.kill(pid, signum)
        except ProcessLookupError:
            return True
        except PermissionError:
            return False
        deadline = time.time() + 5
        while pid_alive(pid) and time.time() < deadline:
            time.sleep(0.1)
        if not pid_alive(pid):
            return True
    return False


def activity(config: Config, snapshot: Snapshot, udid: str, idle: dict[str, float], table: Processes,
             now: float) -> str:
    """What the doctor sees a leased simulator doing."""
    cpu = test_cpu(udid, table)
    if cpu >= ACTIVE_CPU_PERCENT:
        return f"a test is using {cpu:.0f}% CPU"
    if udid in snapshot["active"]:
        return "a host process names it"
    if udid in idle:
        return f"idle {age(now - idle[udid])} (reclaimed at {config.idle_minutes}m while others wait)"
    return "no host process names it"


def spared(udids: list[str], quiet: float, table: Processes) -> str | None:
    """Why a `simctl diagnose` does not count as hung behind a failed test, if it does not."""
    if not udids:
        return "it is not tied to a leased simulator"
    if quiet < DIAGNOSE_QUIET_SECONDS:
        return (f"it has used no CPU for only {age(quiet)}; a doctor run once that reaches "
                f"{age(DIAGNOSE_QUIET_SECONDS)} kills it")
    if any(test_cpu(udid, table) >= ACTIVE_CPU_PERCENT for udid in udids):
        return "its test run is using CPU"
    return None


def diagnose_fixes(snapshot: Snapshot, leases: dict[str, Any], clocks: dict[str, list[float]],
                   table: Processes) -> tuple[list[str], list[str]]:
    """Kill each `simctl diagnose` hung behind a failed test: tied to a leased
    simulator through its own args or its ancestors' (the xcodebuild run that
    started it), no CPU from it or its descendants for DIAGNOSE_QUIET_SECONDS,
    and its test run idle too."""
    found: list[str] = []
    done: list[str] = []
    now = time.time()
    clocks = diagnose_clocks(clocks, table, now)
    for pid in sorted(diagnoses(table)):
        named = {match.group(0) for ancestor in lineage({pid}, table) if ancestor in table
                 for match in UDID_PATTERN.finditer(table[ancestor].args)}
        udids = sorted(named & set(leases))
        where = ", ".join(f"{name_of(snapshot, udid)} {udid} ({short(leases[udid]['owner'])})" for udid in udids)
        label = f"simctl diagnose pid {pid} ({age(table[pid].elapsed)} old{f', on {where}' if where else ''})"
        quiet = now - clocks[str(pid)][0]
        problem = spared(udids, quiet, table)
        if problem:
            found.append(f"{label}: left alone, {problem}")
        elif stop(pid, now):
            done.append(f"killed {label}: it used no CPU for {age(quiet)} after a failed test")
        else:
            found.append(f"{label} is hung but could not be killed")
    return found, done


def health_fixes(config: Config, snapshot: Snapshot, leases: dict[str, Any], booting_since: dict[str, float],
                 unanswered: dict[str, float], table: Processes, now: float) -> tuple[list[str], list[str]]:
    """Shut down each shared simulator nobody leases, uses, or CI claims that
    has been booting for BOOT_SECONDS, or whose launchctl probe failed on
    doctor runs PROBE_RETRY_SECONDS to PROBE_FORGET_SECONDS apart (one slow
    answer on a loaded Mac is not enough), so the next grant boots it fresh.
    One an app runs in (Xcode, hands-on use) is left alone; Simulator.app
    showing only a system screen is invisible here."""
    found: list[str] = []
    done: list[str] = []
    suspects: dict[str, str] = {}
    failing: dict[str, float] = {}  # Probes failed now, by the first of the consecutive failures.
    for udid, device in sorted(snapshot["devices"].items()):
        if udid in leases or udid in snapshot["ci"] or udid in snapshot["active"] or not shared(device["name"]):
            continue
        label = f"{device['name']} {udid}"
        if device["state"] == "Booting" and now - booting_since.get(udid, now) >= BOOT_SECONDS:
            suspects[udid] = f"stuck booting for {age(now - booting_since[udid])}"
        elif device["state"] == "Booted" and not answers(udid, PROBE_SECONDS):
            first = unanswered.get(udid, now)
            if now - first > PROBE_FORGET_SECONDS:
                first = now
            failing[udid] = first
            if any(in_simulator_apps(udid) in process.args for process in table.values()):
                found.append(f"{label} does not answer, but an app runs in it (Xcode or hands-on use?): left alone")
            elif now - first >= PROBE_RETRY_SECONDS:
                suspects[udid] = f"launchctl inside it did not answer on doctor runs {age(now - first)} apart"
            else:
                found.append(f"{label} does not answer; if it still does not on a doctor run in "
                             f"{age(first + PROBE_RETRY_SECONDS - now)}, that run restarts it")
    with locked(config, time.time() + LOCK_WAIT_SECONDS) as state:
        state["unanswered"] = failing  # Only consecutive failures count.
        if suspects:
            snapshot = refresh(state, config, time.time(), destructive=False)
        for udid, why in suspects.items():
            label = f"{name_of(snapshot, udid)} {udid}"
            if udid in state["leases"] or udid in snapshot["active"] or udid in snapshot["ci"]:
                found.append(f"{label} looked unhealthy ({why}) but is in use now: left alone")
            elif shutdown(snapshot, udid):
                failing.pop(udid, None)
                state.setdefault("boot_failures", {})[udid] = time.time()  # Pools pick it last for a while.
                done.append(f"shut down unleased {label} ({why}); the next grant boots it fresh")
            else:
                found.append(f"{label} is unhealthy ({why}) and would not shut down")
    return found, done


def examine(config: Config) -> tuple[list[str], list[str]]:
    """What holds the queue up, and the safe fixes applied, each naming the
    owner: the reclaim pass every poll runs (worktree gone; idle, only while
    others wait), then diagnose_fixes and health_fixes. Never touches a
    simulator a test is using, a CI claim, or a `Waycar ...` simulator."""
    found: list[str] = []
    with locked(config, time.time() + LOCK_WAIT_SECONDS) as state:
        now = time.time()
        prune_tickets(state, now)
        held = dict(state["leases"])
        snapshot = refresh(state, config, now, destructive=True)
        done = [f"freed {name_of(snapshot, udid)} {udid} from {short(lease['owner'])} "
                f"({'its worktree is gone' if owner_gone(lease['owner']) else 'idle while others wait, or shut down'})"
                for udid, lease in held.items() if udid not in state["leases"]]
        state["doctor_at"] = now
        for position, ticket in enumerate(state["tickets"], 1):
            reason = plan(state, config, snapshot, ticket["owner"], wants_of(ticket), ticket["id"])[1]
            found.append(f"queue {position}: {short(ticket['owner'])} waits: {reason or 'grantable at its next poll'}")
        leases, idle, booting_since = dict(state["leases"]), dict(state["idle"]), dict(state["booting_since"])
        clocks, unanswered = dict(state["diagnoses"]), dict(state.get("unanswered", {}))
    table = processes()
    for udid, lease in sorted(leases.items(), key=lambda item: (name_of(snapshot, item[0]), item[0])):
        found.append(f"{name_of(snapshot, udid)} {udid}: {short(lease['owner'])} has held it "
                     f"{age(now - lease['acquired_at'])}; {activity(config, snapshot, udid, idle, table, now)}")
    for more_found, more_done in (diagnose_fixes(snapshot, leases, clocks, table),
                                  health_fixes(config, snapshot, leases, booting_since, unanswered, table, now)):
        found += more_found
        done += more_done
    return found, done


def doctor(config: Config) -> int:
    """`make sim-doctor`: what held the queue up, what was fixed, and the queue now."""
    found, done = examine(config)
    with locked(config, time.time() + LOCK_WAIT_SECONDS) as state:
        now = time.time()
        prune_tickets(state, now)
        lines = status_lines(state, config, refresh(state, config, now, destructive=False), now)
    print("\n".join([*lines, "Doctor found:", *(f"  {line}" for line in found or ["nothing holding the queue up"]),
                     "Doctor did:", *(f"  {line}" for line in done or ["nothing"])]))
    return 0


def parse(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    take = commands.add_parser("acquire", help="lease simulators, waiting for a slot; prints their UDIDs")
    take.add_argument("--no-wait", action="store_true", help="exit 75 instead of queueing")
    take.add_argument("--timeout", type=float, default=60, metavar="MINUTES", help="give up after (default 60)")
    take.add_argument("targets", nargs="+", metavar="TARGET", help="UDID, simulator name, or -destination")
    give = commands.add_parser("release", help="shut down simulators and free their slots")
    give.add_argument("--all", action="store_true", help="every simulator this worktree holds")
    give.add_argument("--force", action="store_true", help="also shut down named simulators nobody leased")
    give.add_argument("targets", nargs="*", metavar="TARGET")
    commands.add_parser("status", help="show holders and the queue (never shuts anything down)")
    grow = commands.add_parser("ensure-pool", help="create missing copies of the named simulators")
    grow.add_argument("--size", type=int, default=POOL_SIZE, metavar="N",
                      help=f"simulators per model (default {POOL_SIZE})")
    grow.add_argument("targets", nargs="+", metavar="NAME", help="simulator name or -destination")
    commands.add_parser("doctor", help="say why the queue is stuck and apply only safe fixes (hung simctl diagnose, "
                                       "abandoned leases, idle ones while others wait, unhealthy unleased simulators)")
    arguments = parser.parse_args(argv)
    if arguments.command == "release" and not (arguments.all or arguments.targets):
        give.error("pass UDIDs or --all")
    if arguments.command == "acquire" and arguments.timeout < 0:
        take.error("--timeout must not be negative")
    if arguments.command == "ensure-pool" and arguments.size < 1:
        grow.error("--size must be at least 1")
    return arguments


def main(argv: list[str] | None = None) -> int:
    arguments = parse(argv)

    def interrupted(signum: int, _frame: object) -> None:
        raise SystemExit(128 + signum)

    for signum in (signal.SIGTERM, signal.SIGHUP):
        if signal.getsignal(signum) is not signal.SIG_IGN:  # Respect nohup.
            signal.signal(signum, interrupted)
    try:
        config = Config()
        if arguments.command == "acquire":
            return acquire(config, arguments.targets, not arguments.no_wait, arguments.timeout)
        if arguments.command == "release":
            return release(config, arguments.targets, arguments.all, arguments.force)
        if arguments.command == "ensure-pool":
            return ensure_pool(config, arguments.targets, arguments.size)
        if arguments.command == "doctor":
            return doctor(config)
        return status(config)
    except Failure as error:
        log(str(error))
        return error.status
    except OSError as error:
        log(f"state error: {error}")
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
