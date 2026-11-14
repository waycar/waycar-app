# 2026-11-14 — A mac_run target for the harness lab

- **Worked:** `mac_run {target: "test-harness-lab", vars: {DRY_RUN: "1"}}`
  checks the lab on the Mac without starting the VM: the Colima profile is
  stopped at 8 GiB, the Host Tools download works, and `make -n` prints the
  make line.
- **Broke:** a fresh clone cannot install the lab host's Host Tools.
  `install.sh` with `WAYCAR_PLUGIN_SOURCE` needs a Linux `plugin/bin/waycar`,
  and a checkout has only `waycar-hook`. The target downloads the release
  binary of the commit's plugin version and checks it against the sha256 that
  version's `install.sh` pins, so a plugin version that is not released yet
  fails there.
- **Watch out:** `colima start` makes its own Docker context current, unless
  it gets `--activate=false`, which still creates the context. It also saves
  its flags into `colima.yaml`, unless it gets `--save-config=false` (colima
  0.10.3 source review).
  `colima list` reports the memory the VM had when it last ran; the next
  start reads `colima.yaml`. And lab.sh uses `HARNESS_LAB_CONTEXT` when it is
  set, so pin it.
