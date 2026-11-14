# 2026-11-14 — Pair a keys-only Host from its page

- **Worked:** retargeting the Pairing Code (the Host's own address and port)
  instead of matching a finished pairing against saved Hosts: the connector's
  existing per-candidate host-key check already refuses another machine before
  the Bootstrap Key is used, so the merge needed no new ceremony step and no
  state-machine change, and updating under the same Host id kept every
  id-keyed record (Notification Key, Live Activities, Closed Sessions).
- **Broke:** nothing on the Mac; review caught that the stale-record guard
  compared only address and port, so a Host given a Jump Host on another
  device mid-pairing would have been switched to the key unverified.
- **Watch out:** the Host page is `.id(host.recordForm)`, so anything that
  updates the Host from a sheet must present that sheet above the page
  (HostListView's `HostAdditionSheet`), or the update tears it down; and a
  guard for "is this still the record we verified" must cover every field
  that decides where the connection goes, Jump Host included.
