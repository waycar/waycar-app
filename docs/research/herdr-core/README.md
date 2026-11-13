# herdr-core research (WAY-472)

What `hc` (herdr-core) does on the wire, measured for a mobile client. Binary
tested: `hc` 0.1.14 (Linux x86_64, static), source at herdr-core commit
`29e6d37`, Herdr app source read at `f9ed5cd`. Measured 2026-10-29.

Design that rests on this: `docs/design/herdr-core-backend.md`; decision record:
`docs/adr/0031-herdr-core-is-a-third-backend.md`.

| File | What it is |
|---|---|
| `rpc-facts.md` | Request/response API through `hc connect`: `hello`, errors, records, `terminal.run/send/keys/read/kill/put`, `machine.exec`, `file.*`, `doc.*`, the `herdr-app` document, compatibility policy, minimum versions per method |
| `attach-facts.md` | Framed mode, `terminal.attach`, key bytes, `hc attach` on a PTY, events, lifecycle and core restarts, install and update, both runtimes on one machine, the detection recipe |
| `hc_probe.py` | Stdlib Python 3 client: spawns `hc connect`, sends JSON-RPC, prints replies (`--hc PATH` or `HC_BIN` picks the binary) |
| `hc_attach_probe.py` | Same for framed mode: attach, frame decoding, CREDIT, events |
| `hc_detect.sh` | One POSIX `sh` detection snippet (finds `herdr-core`/`hc`, rejects a foreign `hc`, prints version and socket state; starts no core) |
| `fixtures/` | Real captures. `README.md` and `README-attach.md` index them. The one hand-made file is named `...HANDMADE...` |
| `real-ssh/` | The same questions asked over a real OpenSSH server in a container, plus the installer run online: `REAL-SSH-FACTS.md`, its probes and raw outputs. The container recipe is `scripts/core-lab/` |

Rules for using it:
- A fixture shows what 0.1.14 did on 2026-10-29. Pids, timestamps and addresses
  change on every run; do not assert on them. The core `name` in `hello` is the
  capture sandbox's hostname.
- Refresh captures with the probes from a neutral directory (no workspace paths),
  inside a scratch core: a short root such as `/tmp/hc-neutral` (Unix socket
  paths are limited to about 107 bytes), `HOME`, `XDG_RUNTIME_DIR`,
  `XDG_STATE_HOME`, `XDG_CONFIG_HOME` and `HC_SESSION` set to throwaway values,
  and `hc server stop` at the end. Never point a probe at a real core.
- Real agents (Claude Code, Codex) were not run. Where a statement depends on
  one, it is marked `[INFERENCE]` in the facts files.
- Not run: macOS Hosts, the Linux systemd user-service start path, Windows,
  remote machines added to a core, `hc update` against the live release, the app's own SSH library. A real OpenSSH server was run (`real-ssh/`).
