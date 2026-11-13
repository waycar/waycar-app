#!/usr/bin/env python3
"""Show or watch the App Store review state of Waycar's newest App Store version.

    scripts/asc-review-state.py --once [--ssh mac]
    scripts/asc-review-state.py [--ssh mac] [--interval 5m] [--deadline 3d]

The state is the newest iOS App Store version (created last), its
appStoreState and appVersionState, and the state of the app's latest review
submission (an unsubmitted draft counts as latest). App Store Connect refuses
`sort` on these lists, so the script sorts them itself.

--once prints the state on one line and exits 0, or non-zero on any error:
run it to prove a watch works where it runs.

Without --once it watches, for Ultimate script automations (`automation ask`,
once: false). It prints nothing while the state stays the same. On a change it
prints one line, `FIRE <version> <old> -> <new>`, each state written
appStoreState/appVersionState/reviewSubmissionState (the old one prefixed with
`<version>:` when the version changed). On a final state (approved, released
or rejected: FINAL) it prints DONE and exits 0. A fresh watch (nothing stored
in $AUTOMATION_STATE) that finds a final state fires
`FIRE <version> <state> (already final)` first; a resumed one whose final
state it already reported only prints DONE.
The deadline counts every tick, failed checks included: when it passes the
script fires with the last state and error, then DONE. Temporary failures
(network, HTTP 5xx or 429, ssh) go to stderr and the watch goes on; anything
else (missing key or ~/.env, HTTP 4xx, a bug) exits non-zero, which wakes the
automation's watcher. The last state and the start time live in the
directory $AUTOMATION_STATE, so a relaunch neither fires twice nor resets its
deadline; DONE clears the start time, so a resumed watch gets a new deadline.

The API key lives on the Mac. --ssh <target> runs every check there under the
Mac's own python3 (Apple's 3.9): this script and asc_client.py go over the ssh
session's stdin, so the Mac needs no checkout of this commit, and the client
loads the Mac's ~/.env.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime

import asc_client

FINAL = {"READY_FOR_SALE", "READY_FOR_DISTRIBUTION", "PENDING_DEVELOPER_RELEASE",
         "REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED"}
STATE_FILE = "asc-review-state.json"
SSH_TIMEOUT = 180


def duration(text):
    match = re.fullmatch(r"(\d+)([smhd]?)", text)
    if not match:
        raise argparse.ArgumentTypeError(f"not a duration like 90s, 30m, 3h or 2d: {text!r}")
    return int(match.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600, "d": 86400}[match.group(2)]


def human(seconds):
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60)):
        if seconds >= size and seconds % size == 0:
            return f"{seconds // size}{unit}"
    return f"{seconds}s"


def parse_time(text):
    """An App Store Connect timestamp (2026-11-01T13:36:11.247Z, 2026-10-15T03:00:39-07:00)
    as epoch seconds; 0 for none."""
    if not text:
        return 0.0
    text = re.sub(r"\.(\d+)", lambda m: "." + m.group(1)[:6].ljust(6, "0"), text.replace("Z", "+00:00"))
    return datetime.fromisoformat(text).timestamp()


def newest_version(versions):
    if not versions:
        raise asc_client.ASCError("App Store Connect lists no iOS App Store version")
    return max(versions, key=lambda item: parse_time(item["attributes"].get("createdDate")))


def latest_submission(submissions):
    """The newest by submittedDate; an unsubmitted draft (no date) is newer than any."""
    if not submissions:
        return None
    return max(submissions, key=lambda item: (item["attributes"].get("submittedDate") is None,
                                              parse_time(item["attributes"].get("submittedDate"))))


def fetch_state(client):
    versions = client.get_all(
        f"/v1/apps/{client.app_id}/appStoreVersions?filter[platform]=IOS&limit=200"
        "&fields[appStoreVersions]=versionString,appStoreState,appVersionState,createdDate")
    submissions = client.get_all(
        f"/v1/reviewSubmissions?filter[app]={client.app_id}&filter[platform]=IOS&limit=200"
        "&fields[reviewSubmissions]=state,submittedDate")
    version = newest_version(versions)["attributes"]
    submission = latest_submission(submissions)
    submission = submission["attributes"] if submission else {}
    return {
        "version": version.get("versionString"),
        "created": version.get("createdDate"),
        "appStoreState": version.get("appStoreState"),
        "appVersionState": version.get("appVersionState"),
        "reviewSubmission": submission.get("state"),
        "submitted": submission.get("submittedDate"),
    }


def local_state():
    return fetch_state(asc_client.Client.from_env())


def remote_state(target):
    """fetch_state() run on target under its own python3, through ssh's stdin."""
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "asc_client.py")) as f:
        client_source = f.read()
    with open(os.path.abspath(__file__)) as f:
        own_source = f.read()
    program = "\n".join([
        "import sys, types",
        "client = types.ModuleType('asc_client')",
        f"exec(compile({client_source!r}, 'asc_client.py', 'exec'), client.__dict__)",
        "sys.modules['asc_client'] = client",
        "sys.argv = ['asc-review-state.py', '--json']",
        f"exec(compile({own_source!r}, 'asc-review-state.py', 'exec'), {{'__name__': '__main__'}})",
    ])
    command = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=20", target, "python3", "-"]
    try:
        result = subprocess.run(command, input=program, capture_output=True, text=True, timeout=SSH_TIMEOUT)
    except subprocess.TimeoutExpired:
        raise asc_client.ASCError(f"ssh {target}: no answer within {SSH_TIMEOUT} s", temporary=True)
    except OSError as error:
        raise asc_client.ASCError(f"ssh {target}: {error}")
    sys.stderr.write(result.stderr)
    sys.stderr.flush()
    if result.returncode != 0:
        lines = result.stderr.strip().splitlines()
        reason = lines[-1] if lines else f"exited {result.returncode}"
        # 255 is ssh's own failure (connection refused, timed out, reset).
        raise asc_client.ASCError(f"ssh {target}: {reason}",
                                  temporary=result.returncode in (asc_client.TEMPFAIL, 255))
    lines = result.stdout.strip().splitlines()
    try:
        return json.loads(lines[-1])
    except (IndexError, ValueError):
        raise asc_client.ASCError(f"ssh {target}: printed no state: {result.stdout.strip()!r}")


def label(state):
    return "/".join(state.get(field) or "none" for field in ("appStoreState", "appVersionState", "reviewSubmission"))


def key(state):
    return state.get("version"), label(state)


def final(state):
    return state.get("appStoreState") in FINAL or state.get("appVersionState") in FINAL


def describe(state):
    submission = state.get("reviewSubmission") or "none"
    if state.get("reviewSubmission"):
        submission += f" (submitted {state['submitted']})" if state.get("submitted") else " (not submitted)"
    return (f"version {state.get('version')}: appStoreState {state.get('appStoreState')}, "
            f"appVersionState {state.get('appVersionState')}, reviewSubmission {submission}")


def load_memory(directory):
    if not directory:
        return {}
    try:
        with open(os.path.join(directory, STATE_FILE)) as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return {}


def save_memory(directory, memory):
    if not directory:
        return
    os.makedirs(directory, exist_ok=True)
    path = os.path.join(directory, STATE_FILE)
    with open(path + ".tmp", "w") as f:
        json.dump(memory, f)
    os.replace(path + ".tmp", path)


def watch(fetch, interval, deadline, directory, clock=time.time, sleep=time.sleep, out=print):
    memory = load_memory(directory)
    if "started" not in memory:
        memory["started"] = clock()
        save_memory(directory, memory)
    last_error = None
    while True:
        try:
            state = fetch()
        except asc_client.ASCError as error:
            if not error.temporary:
                raise
            last_error = str(error)
            print(f"asc-review-state: check failed, trying again: {error}", file=sys.stderr, flush=True)
        else:
            last_error = None
            old = memory.get("last")
            changed = old is not None and key(old) != key(state)
            if old is None or changed:
                memory["last"] = state
                save_memory(directory, memory)
            if changed:
                before = label(old) if old.get("version") == state.get("version") else f"{old.get('version')}:{label(old)}"
                out(f"FIRE {state.get('version')} {before} -> {label(state)}", flush=True)
            elif old is None and final(state):
                out(f"FIRE {state.get('version')} {label(state)} (already final)", flush=True)
            if final(state):
                break
        remaining = memory["started"] + deadline - clock()
        if remaining <= 0:
            last = memory.get("last")
            text = f"FIRE {last.get('version') if last else '?'} deadline passed after {human(deadline)}"
            text += f"; still {label(last)}" if last else "; no successful check"
            if last_error:
                text += f"; last error: {last_error}"
            out(text, flush=True)
            break
        sleep(min(interval, remaining))
    del memory["started"]
    save_memory(directory, memory)
    out("DONE", flush=True)
    return 0


def main():
    parser = argparse.ArgumentParser(description="Show or watch Waycar's App Store review state.")
    parser.add_argument("--once", action="store_true", help="print the state and exit")
    parser.add_argument("--json", action="store_true", help="print the state as one JSON line and exit (what --ssh runs)")
    parser.add_argument("--ssh", metavar="TARGET", help="run each check on TARGET (the Mac, which has the API key)")
    parser.add_argument("--interval", default=5 * 60, type=duration, help="time between checks (default 5m)")
    parser.add_argument("--deadline", default=3 * 86400, type=duration, help="give up after this long (default 3d)")
    args = parser.parse_args()

    fetch = (lambda: remote_state(args.ssh)) if args.ssh else local_state
    if args.json:
        print(json.dumps(fetch()))
        return 0
    if args.once:
        print(describe(fetch()))
        return 0
    return watch(fetch, args.interval, args.deadline, os.environ.get("AUTOMATION_STATE"))


if __name__ == "__main__":
    sys.exit(asc_client.run(main))
