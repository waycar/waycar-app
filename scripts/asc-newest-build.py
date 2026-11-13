#!/usr/bin/env python3
"""Print the newest build number App Store Connect has for an app.

Used by the TestFlight workflow to pick the next build number: ASC rejects
reused numbers, and a local `make bump` between CI runs would otherwise make
the naive local+1 collide. Authentication is the same App Store Connect API
key the upload itself uses; asc_client.py says where it comes from.

The app id defaults to Waycar (6815881853); override with ASC_APP_ID.
"""
import sys

import asc_client


def main():
    client = asc_client.Client.from_env()
    builds = client.get(f"/v1/builds?filter[app]={client.app_id}"
                        "&sort=-version&limit=1&fields[builds]=version")["data"]
    print(builds[0]["attributes"]["version"] if builds else 0)
    return 0


if __name__ == "__main__":
    sys.exit(asc_client.run(main))
