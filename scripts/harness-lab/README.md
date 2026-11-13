# Harness lab

A throwaway Linux Host for testing Waycar against 17 agent
harnesses, with no accounts or real keys: every harness that accepts a custom
endpoint talks to a deterministic mock model server instead. It runs on the
Colima Docker context `colima-waycar-harness` (compose project
`waycar-harness-lab`) and never touches the `default` context.

```sh
make harness-lab-up      # build and start mock + host, then print herdr/tmux/waycar versions
make harness-lab-shell   # ssh in as waycar
make harness-lab-down    # remove the containers and network
make harness-lab-reinstall-plugin   # rerun plugin/install.sh after editing plugin/
scripts/harness-lab/lab.sh reconfigure   # push host/config edits without a rebuild
scripts/harness-lab/smoke.sh <kind>      # one "hello WAYCAR" turn in tmux, plus the mock log
```

## Containers and ports

| | inside the compose network | from the Mac |
|---|---|---|
| `mock` (see `mock/`) | `http://mock:8080` | `http://127.0.0.1:18080` (request log: `GET /_log`, shared, so filter by time rather than clearing it) |
| `host` sshd | `host:22` | `127.0.0.1:22300`, user `waycar`, key `~/.ssh/waycar_harness_lab` |

mosh-server is installed, but mosh from the Mac does not reach it: Colima's
localhost port forwarding carries TCP only (a UDP probe on a published port
got no reply), so the compose file publishes SSH alone.

```sh
ssh -i ~/.ssh/waycar_harness_lab -p 22300 \
  -o UserKnownHostsFile=~/.ssh/waycar_harness_lab_known_hosts waycar@127.0.0.1
```

`lab.sh up` creates the key if it is missing and resets the known_hosts entry
(host keys change whenever the container is recreated). sshd is key-only and
allows `AllowTcpForwarding local` plus local streamlocal forwarding, which
herdr's direct-streamlocal transport needs.

## The host

Ubuntu 24.04 with the distro tmux (3.4), Node 22 (NodeSource), herdr from its
release asset, and the harnesses installed as `waycar` with their official
installers. Versions are pinned in `VERSIONS` (passed as build args; one image
layer per harness); `/etc/harness-lab/versions.txt` on the host records what
each layer actually installed. All harnesses run natively on aarch64.

On every start the entrypoint starts the herdr server for `waycar` (detached,
log in `~/.cache/harness-lab/herdr-server.log`) and installs Waycar Host Tools
from the worktree's `plugin/`, mounted read-only at `/opt/waycar-plugin`, with
`WAYCAR_PLUGIN_SOURCE` (herdr mode, plus the `waycar` command and Status
Hooks). `~/work/demo` is a git repo that the harnesses are pre-trusted in.

## How a harness is configured

`host/config/<kind>/` holds each harness's lab configuration, applied at build
time by `host/setup-home.sh`:

- `home/`: files copied into `~` (settings, trust and onboarding state),
- `env`: `KEY=VALUE` lines exported to every shell via `~/.config/harness-lab/env.sh`,
  which `~/.bashrc` sources first, so `ssh host cmd` and tmux panes get it. herdr
  panes do not source it: with no `SHELL` in its environment the herdr server
  runs panes in `/bin/sh` with its own environment, which the entrypoint's login
  shell gave it at container start. An `env` change reaches herdr panes only
  after the herdr server restarts,
- `setup.sh`: configuration the harness's own CLI writes (cline, hermes).

All keys are dummies (`waycar-lab-dummy-key`); the mock accepts any key and
model. Endpoints: Anthropic `http://mock:8080` (claude), OpenAI Responses
`http://mock:8080/v1` (codex), Gemini `http://mock:8080` via
`GOOGLE_GEMINI_BASE_URL` (gemini, agy), OpenAI Chat Completions
`http://mock:8080/v1` (everything else).

One manual step after a fresh container or `reconfigure`: Codex asks to review
the Waycar hooks on its first launch; choose "Trust all and continue".

## Harnesses that need an account

These three have no custom-endpoint or offline mode, so in the lab they stop
at sign-in: install, launch and the login screen are all that can be tested.

| kind | first screen | API-key path |
|---|---|---|
| cursor (`cursor-agent`) | "Signing in … click this link to log in" (browser/QR) | `CURSOR_API_KEY` needs a real Cursor key |
| kiro (`kiro-cli chat`) | "Welcome to Kiro CLI, let's get you signed in!" (Builder ID / Google / GitHub / organization) | `KIRO_API_KEY`, non-interactive only, paid plan |
| devin | "Welcome to Devin CLI! Waiting for login in browser…" | none; a token from a Devin account |

Copilot needs no GitHub login in the lab: its BYOK variables
(`COPILOT_PROVIDER_*`) point it at the mock. Its self-update is off twice:
`COPILOT_AUTO_UPDATE=false` makes its loader run the installed version instead
of the newest one in `~/.cache/copilot/pkg/`, and `"autoUpdate": false` in
`~/.copilot/settings.json` stops the download itself, whatever the pane's
environment. A herdr server started before the variable existed once ran and
re-downloaded 1.0.96 (copilot.md §14).

## The e2e suite

`Tests/WaycarTests/HarnessLabE2ETests.swift` drives the real harnesses on the
lab host through the app's own code: `TmuxTransport` and `WaycarSSHTransport`
over the production connect path, `LaunchPromptStager.launchCommand` (the New
Agent sheet's launch builder, fed the kind's case from
`plugin/test-vectors/harness-launch-v1.json`), `ClosedSession` and
`ClosedSessionResumer`, the chat transcript reader, and Notification
Registration. One case per kind × backend (17 × 2), run one at a time:

```sh
make test-harness-lab                                  # every kind on herdr and tmux
make test-harness-lab KINDS=claude,agy BACKENDS=tmux   # a subset
make test-harness-lab DRY_RUN=1                        # probe the lab, print the config, run nothing
make sim-release                                       # only after KEEP_SIM=1
scripts/harness-lab/lab.sh e2e-reset                   # clean up after an interrupted run
```

`run-e2e.sh` (what the target runs) starts the lab when its SSH does not
answer, checks herdr, tmux, the Host Tools and the mock (refusing a stale mock
image whose `/_health` lacks the `features` the suite needs), records which
herdr integrations are installed, builds for testing, takes the lab lock,
leases `SIM` through `scripts/sim-slot.py`, and puts the suite's
configuration (host, key seed, kinds, backends, integrations) into the
Simulator as `WAYCAR_HARNESS_LAB_CONFIG`. Without that variable the suite is
disabled, so `make test` and CI skip it. It releases the lock, and the
simulator unless `KEEP_SIM=1`, afterwards.

One harness at a time: the lab VM is small, so anyone running a harness on
the lab host (the suite, a probe by hand) first takes the lock
`mkdir /tmp/harness-lab.lock && echo <who> > /tmp/harness-lab.lock/owner` on
the host, and removes it (`rm -rf /tmp/harness-lab.lock`) once its processes
are gone. `run-e2e.sh` waits for it up to `HARNESS_LAB_LOCK_WAIT_SECONDS`
(3600).

On herdr, each case first opens a focused `harnesse2e-focus` Workspace. herdr
reports a finished turn as `done` only while its pane is unseen, and as
`idle` in the focused pane of the focused Workspace (`herdr --skill`; checked
on 0.9.3). Without it, the case's own Workspace would be the only, and so the
focused, one.

The lab reset (`e2e-reset.sh`, copied to `~/.cache/harness-lab/` on the host)
runs before and after every case and at the end of the run. It kills the
`harnesse2e-*` tmux sessions and closes the `harnesse2e-*` herdr workspaces,
and nothing else. The suite never clears the mock's log; it reads its own
entries by Host time and by its per-case `WAYCAR_E2E_<KIND>_<BACKEND>_<nonce>`
tokens.

What a case checks, for each kind that runs against the mock:

1. **Launch.** The case starts in a new Workspace at `~/work/demo`, in Chat
   Mode where the build offers it (model, Quick thinking, Chat Prompt marker)
   and with the vector's first message. The mock log shows the first message
   with the vector's `wire` facts: model, effort and the marker in the system
   prompt. The status goes working → done, and the pane is listed as its kind.
2. **Plain turn.** The prompt reaches the mock (with the marker on every
   turn), and the status goes working → done.
3. **Tool turn.** `WAYCAR_TOOL` or `WAYCAR_TOOL_MUTATE`. Where the lab can
   make the kind ask (`HarnessLabProfile`), the turn goes blocked, the plugin
   pushes for blocked while it holds, and approving it gives working → done.
   Otherwise there is no blocked, and the profile says why. Two kinds ask
   only because of lab configuration: grok's `~/.grok/config.toml` asks
   before every shell command (`[permission] ask = ["Bash"]`), and hermes's
   `waycar-lab-approval` plugin (`~/.hermes/plugins/`, enabled by
   `setup.sh`) asks before a terminal command when the launch sets
   `WAYCAR_LAB_HERMES_ASK=1`. The tool result
   reaches the mock, and done gets its own push. Pushes go to a mock relay:
   the case points `notify.json`'s `relay_url` at
   `http://mock:8080/harnesse2e-relay/<nonce>`, registers a fake device, and
   restores both files afterwards. A delivery posts once per registered
   device, and an interrupted run can leave its fake device behind, so a
   push counts as new only 1 s or more after the last one. Statuses are read
   through `listAgents()` while the case holds the Console's event stream,
   since tmux reads screens (approvals of agy, cline and kiro) only then.
4. **Transcript.** Read the way the Chat view reads it. A Chat Mode kind shows
   both turns and a closed turn. Any other kind reads `unsupported`.
5. **Close and resume.** Close the pane, record the Closed Session as the
   Console does, and resume it through `ClosedSessionResumer`. The next
   request carries the earlier turns, and the Chat Prompt survives. herdr
   reports sessions only through its integrations, and never for codex;
   claude, pi, copilot, qwen and grok launches pin their own session id, so
   they resume on herdr without one. A case with no session (none reported
   by the backend, none pinned by the launch) resumes with the kind's
   continue-the-latest form (`--continue`, gemini's and hermes's
   `--resume latest`, muse's `resume --last`), which reopens the case's own session since cases
   run one at a time in `~/work/demo`. It skips this step, and says so, only
   where that form is empty (opencode, cline) or an interactive picker
   (claude, codex, omp, pi, devin).

The launch, plain and resumed turns are answered in text alone. herdr 0.9.3
does not report such a turn for copilot (`HarnessLabProfile`'s
`herdrTextTurnsUnreported`): its copilot screen rules have no match for
copilot 1.0.95's `◉ Working esc edit prompt`, shown until the model's first
output, and the mock's reply arrives in one burst that ends the turn about
200 ms later. There the case says so and waits for the reply on screen
instead of done; copilot's tool turn still goes blocked → working → done on
herdr. The evidence is in copilot.md §11.

cursor, kiro and devin need an account. For them a case checks only the
sign-in screen: `AgentScreen.signInRequired` recognizes it, a prompt fails
with `AgentSignInRequiredError` without typing anything, and no working or
blocked status is reported.

Lab preconditions: run `make harness-lab-reinstall-plugin` after any change
to `plugin/`. Codex shows its hooks review on launch until the hooks are
trusted; the suite answers it with "Trust all", the documented one-time
step. herdr integrations are optional (`herdr integration install <kind>`).
The suite expects herdr sessions and omp's herdr turns only where the probe
found the integration installed.

Runtime: about 1.5 min per case against the mock, 30 s per sign-in case, so
about 45 min for the full matrix plus the build. A case is capped at 12 min:
every wait has its own budget, mostly 60 s, and cold launches of opencode,
kilo, cline and hermes get 90–120 s.
