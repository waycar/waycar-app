#!/usr/bin/env python3
"""Add an uploaded build to the Waycar Testers TestFlight group.

The "Waycar Testers" internal group was created without automatic
distribution (App Store Connect does not allow changing that later), so the
TestFlight workflow calls this after upload: wait for App Store Connect to
finish processing the build, then attach it to the group.

Temporary App Store Connect failures do not stop it: each request is retried
(asc_client.py), a check that still fails is tried again on the next poll,
and a failed add is sent again only once a check shows it did not land.

Usage: asc-distribute-build.py <build-number>
Env: the API key (asc_client.py) and ASC_BETA_GROUP_ID, the group's id
(either may be in ~/.env); optional ASC_APP_ID.
"""
import os
import sys
import time

import asc_client

DEADLINE = 45 * 60
POLL = 30


def wait_until_processed(client, version):
    """The build's id once App Store Connect has processed it."""
    deadline = time.time() + DEADLINE
    while time.time() < deadline:
        try:
            found = client.get(f"/v1/builds?filter[app]={client.app_id}&filter[version]={version}")["data"]
        except asc_client.ASCError as error:
            if not error.temporary:
                raise
            print(f"build {version}: check failed, trying again: {error}", flush=True)
        else:
            if found:
                state = found[0]["attributes"]["processingState"]
                print(f"build {version}: {state}", flush=True)
                if state == "VALID":
                    return found[0]["id"]
                if state in ("FAILED", "INVALID"):
                    raise SystemExit(f"build {version} processing {state}")
            else:
                print(f"build {version}: not visible yet", flush=True)
        time.sleep(POLL)
    raise SystemExit(f"build {version} not processed within {DEADLINE // 60} minutes")


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: asc-distribute-build.py <build-number>")
    version = sys.argv[1]
    client = asc_client.Client.from_env()
    group = os.environ.get("ASC_BETA_GROUP_ID")
    if not group:
        raise SystemExit("ASC_BETA_GROUP_ID is not set: export the TestFlight group id or add it to ~/.env")
    build = wait_until_processed(client, version)

    def in_group():
        found = client.get(f"/v1/builds?filter[app]={client.app_id}&filter[version]={version}"
                           f"&filter[betaGroups]={group}&fields[builds]=version")["data"]
        return any(item["id"] == build for item in found)

    client.post(f"/v1/betaGroups/{group}/relationships/builds",
                {"data": [{"type": "builds", "id": build}]}, verify=in_group)
    print(f"build {version} added to TestFlight group {group}")
    return 0


if __name__ == "__main__":
    sys.exit(asc_client.run(main))
