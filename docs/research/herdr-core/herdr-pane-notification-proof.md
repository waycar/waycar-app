# Core started inside a herdr pane: notification isolation

Live harness-lab proof, 2026-11-01. Source checkout: `949c6f3127d45309702466dbbed3a4e6ce2a1a26`.
No product changes.

## Setup

- Mac Colima profile `waycar-harness`: aarch64, VZ, 4 CPUs, 8 GiB.
- Ubuntu 24.04 harness Host: herdr 0.9.3, herdr-core 0.1.14,
  Waycar Host Tools 2.3.0.
- Used the published `plugin-v2.3.0` Linux aarch64 musl binary from
  `waycar-2.3.0-aarch64-unknown-linux-musl-e22b48ac9b83.tar.gz`;
  `sha256sum -c` against its release checksum returned `OK`.
  Installed it with the checkout's plugin using `lab.sh reinstall-plugin`.
- Installed core with `HC_VERSION=0.1.14 sh /tmp/core-install.sh`.
  The installer ignores a `--version` argument; the initial attempt installed
  0.1.16. Removed that unused binary and installed the pin before testing.
- Started `scripts/ci/relay-standin.py --port-file /tmp/e1-7900/port` inside
  the Host. Configured synthetic device credentials and the local relay URL
  in **`waycar config-dir`**, with `core_enabled=true` and zero debounce.
  On this herdr Host that directory is
  `~/.config/herdr/plugins/config/waycar`, not `~/.config/waycar`.

Commands on the Mac, after tar-syncing the tracked checkout:

```sh
export PATH=/opt/homebrew/bin:$PATH
colima start waycar-harness --cpu 4 --memory 8 --vm-type vz --vz-rosetta
cd ~/src/waycar-e1-7900
make harness-lab-up
scripts/harness-lab/lab.sh reinstall-plugin
scripts/harness-lab/lab.sh ssh 'python3 /tmp/e1-7900/proof.py'
```

Rosetta was unavailable; the native aarch64 image built successfully without it.
The throwaway Python proof and shell agent were deleted after the run.

## Method

The proof used the same fake OSC-7501 agent pattern and installed Claude hook
commands as `scripts/ci/core-distro-check.sh`, but started core from a **herdr**
pane rather than a tmux pane:

1. Created a workspace with `workspace.create`, read its returned root pane id,
   and sent this shell command through `pane.send_text`:
   `herdr-core run --bg --name proof -- sh /tmp/e1-7900/agent.sh`.
2. Read the returned core terminal address. The agent recorded its environment;
   asserted `HERDR_ENV=1` and `HERDR_PANE_ID` equal to the creating herdr pane.
3. For each state, the agent printed OSC 7501, then ran the corresponding
   installed `waycar-hook` command from `~/.claude/settings.json` with `{}`
   stdin, `CLAUDECODE=1` and `CLAUDE_PID` naming its own tty-owning process.
   Hooks ran on the core terminal's tty, not the herdr pane's tty.
4. Counted **all** `/push` requests at the relay. After each hook acknowledgement,
   waited for the expected count and then another two seconds to catch duplicates.
   Asserted every push collapse id equals
   `base64url(sha256(bytes(0...31) + "HERDR-NOTIFY-COLLAPSE:hc:<address>")[:16])`.
   Thus a push for the inherited herdr pane, not just a duplicate core push,
   would fail the check.

## Observed transcript

```text
created herdr pane w2:p1
core hc 0.1.14 terminal t2 inherited HERDR_ENV=1 HERDR_PANE_ID=w2:p1
plugin waycar 2.3.0 core_enabled=true
UserPromptSubmit: total pushes=0; every push targets hc:t2; no herdr-pane push
PermissionRequest: total pushes=1; every push targets hc:t2; no herdr-pane push
PostToolUse: total pushes=1; every push targets hc:t2; no herdr-pane push
Stop: total pushes=2; every push targets hc:t2; no herdr-pane push
PASS: exactly one Blocked + one Done push, zero herdr duplicates
```

The first fixture attempt wrote the wrong configuration directory and timed out
waiting for its first push. Core labels already showed `waycar.kind=claude` and
`waycar.turn=0`; `waycar status --json` exposed the actual config directory.
Correcting only the fixture to use `waycar config-dir` produced the transcript
above. No hook or runtime code was changed.

## Bounds and cleanup

This proves the installed hooks' routing with inherited herdr environment and
real core tty checks. It does not test a real Claude model turn, APNs delivery,
the app's notification display, or late delivery beyond the observation window.

`make harness-lab-down` removed both containers and the compose network.
`colima stop waycar-harness` completed; `colima list` showed it stopped at 8 GiB.
Restored Docker's default context, removed `~/src/waycar-e1-7900` and the local
release download directory. No simulator was used.
