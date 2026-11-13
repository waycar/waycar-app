#!/usr/bin/env python3
"""Wait for every GitHub Actions run of one commit on main to finish.

    python3 scripts/ci/watch-main.py --sha <prefix> [--repo waycar/waycar-app]
        [--interval 120] [--deadline 3h] [--once]

Made for Ultimate script automations: an `automation ask` whose script runs
`python3 ~/src/waycar/scripts/ci/watch-main.py --sha <sha>`. Such a
script starts in its own folder, not the checkout, so gh always gets --repo.

It watches push runs only: scheduled ones (uptime, sweeper) also carry main's
sha and keep appearing. Silent while runs are pending; gh's stderr passes
through. When every run for
the sha is done it prints `FIRE <sha>: <name>: <conclusion> <url>; ...` (one
line, since Ultimate delivers only the FIRE line's text), then `DONE`, exit 0.
The deadline is counted on every tick, gh errors included; when it passes the
script fires with the last known status or gh error, then `DONE`, exit 0.
With $AUTOMATION_STATE set the start time is kept there, so a relaunched
script keeps its deadline. --once prints the current status without FIRE and
exits 0, or 1 when gh failed (a sha GitHub doesn't know included): run it to
prove a watcher works.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

FIELDS = "name,status,conclusion,headSha,url"


def duration(text):
    match = re.fullmatch(r"(\d+)([smh]?)", text)
    if not match:
        raise argparse.ArgumentTypeError(f"not a duration like 90s, 30m or 3h: {text!r}")
    return int(match.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[match.group(2)]


def sha_prefix(text):
    if not re.fullmatch(r"[0-9a-fA-F]{7,40}", text):
        raise argparse.ArgumentTypeError(f"not a 7-40 character hex sha: {text!r}")
    return text.lower()


def gh(*args):
    """gh's stdout, or the error as a string; gh's stderr passes through."""
    try:
        result = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"watch-main: {error}", file=sys.stderr, flush=True)
        return None, str(error)
    sys.stderr.write(result.stderr)
    sys.stderr.flush()
    if result.returncode != 0:
        lines = result.stderr.strip().splitlines()
        return None, lines[-1] if lines else f"gh exited {result.returncode}"
    return result.stdout, None


full_shas = {}


def fetch(repo, sha):
    """The push runs for sha on main, or the error as a string."""
    if sha not in full_shas:
        # gh run list --commit takes only a full sha.
        full, error = gh("api", f"repos/{repo}/commits/{sha}", "--jq", ".sha")
        if error:
            return None, error
        full_shas[sha] = full.strip()
    out, error = gh("run", "list", "--repo", repo, "--branch", "main", "--event", "push",
                    "--commit", full_shas[sha], "--limit", "50", "--json", FIELDS)
    if error:
        return None, error
    try:
        runs = json.loads(out)
    except json.JSONDecodeError as error:
        print(f"watch-main: gh printed no JSON: {error}", file=sys.stderr, flush=True)
        return None, f"gh printed no JSON: {error}"
    return sorted(runs, key=lambda r: r.get("name", "")), None


def describe(runs):
    if not runs:
        return "no push runs on main yet"
    return "; ".join(f"{r.get('name')}: {r.get('conclusion') or r.get('status')} {r.get('url')}" for r in runs)


def started_at(sha):
    state = os.environ.get("AUTOMATION_STATE")
    if not state:
        return time.time()
    path = os.path.join(state, f"watch-main-{sha}.started")
    try:
        with open(path) as f:
            return float(f.read())
    except (FileNotFoundError, ValueError):
        now = time.time()
        os.makedirs(state, exist_ok=True)
        with open(path, "w") as f:
            f.write(str(now))
        return now


def main():
    parser = argparse.ArgumentParser(description="Wait for every Actions run of one commit on main.")
    parser.add_argument("--sha", required=True, type=sha_prefix, help="commit sha or prefix (7+ hex)")
    parser.add_argument("--repo", default="waycar/waycar-app")
    parser.add_argument("--interval", default=120, type=duration, help="seconds between checks (default 120)")
    parser.add_argument("--deadline", default=3 * 3600, type=duration, help="give up after this long (default 3h)")
    parser.add_argument("--once", action="store_true", help="print the current status and exit")
    args = parser.parse_args()

    if args.once:
        runs, error = fetch(args.repo, args.sha)
        if error:
            print(f"{args.sha}: gh failed: {error}")
            return 1
        if not runs:
            print(f"{args.sha}: {describe(runs)}")
            return 0
        print(f"{args.sha}: {sum(r.get('status') == 'completed' for r in runs)} of {len(runs)} runs done")
        for run in runs:
            print(f"  {run.get('name')}: {run.get('conclusion') or run.get('status')} {run.get('url')}")
        return 0

    started = started_at(args.sha)
    last_runs, last_error = None, None
    while True:
        runs, error = fetch(args.repo, args.sha)
        if error:
            last_error = error
        else:
            last_runs, last_error = runs, None
            if runs and all(r.get("status") == "completed" for r in runs):
                print(f"FIRE {args.sha}: {describe(runs)}", flush=True)
                print("DONE", flush=True)
                return 0
        remaining = started + args.deadline - time.time()
        if remaining <= 0:
            status = describe(last_runs) if last_runs is not None else "no successful check"
            if last_error:
                status += f"; last gh error: {last_error}"
            print(f"FIRE {args.sha}: deadline passed; {status}", flush=True)
            print("DONE", flush=True)
            return 0
        time.sleep(min(args.interval, remaining))


if __name__ == "__main__":
    sys.exit(main())
