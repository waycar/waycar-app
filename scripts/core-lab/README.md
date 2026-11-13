# core lab: a real OpenSSH server with herdr-core on it

A throwaway Ubuntu 24.04 container (OpenSSH 9.6, sshd on port 22, user `waycar` without sudo, key auth only,
`AllowTcpForwarding no`, `PrintMotd yes`, `UsePAM yes`). herdr-core is **not** in the image: the app's live E2E
(and `REAL-SSH-FACTS.md`) install it with the official online installer, over a real ssh exec channel.

Files

| File | What |
|---|---|
| `Dockerfile`, `entrypoint.sh` | the image; entrypoint writes host keys, authorizes `$LAB_AUTHORIZED_KEY`, runs sshd in the foreground |
| `agents/fake-agent.sh` | fake agent, prints OSC 7501 (`work`, `ask`, `fail`, `quit` on stdin; see header) |
| `launch-lab-terminals.sh` | starts 9 terminals through `herdr-core run --bg` (5 fake agents, 1 shell, 3 labelled for spaces/tabs) |
| `docs/research/herdr-core/real-ssh/probes/` | the research probes, patched to go through ssh (`hc_attach_probe_ssh.py --ssh`, `LAB_REMOTE_LINE` in `hc_probe.py`) and the pty/ssh harnesses used for the facts file |
| `docs/research/herdr-core/real-ssh/REAL-SSH-FACTS.md` | what was measured over the real sshd (raw outputs in `real-ssh/evidence/out/`) |

Any Docker works. Use `--rm` and resource limits, never bake a credential into the image, and remove what you start.

## Build

```sh
docker build -t corelab:1 scripts/core-lab
```
(about 20 s; the image is ~250 MB).

## Run it where the simulator can reach it

```sh
docker run -d --rm --name corelab --cpus 1 --memory 2g --pids-limit 512 -p 2222:22 \
  -e LAB_AUTHORIZED_KEY="$(cat app_key.pub)" corelab:1
```

* `LAB_AUTHORIZED_KEY` is the app's **public** key (one or several lines). Never pass or bake a private key.
* The simulator connects with `ssh -p 2222 waycar@<docker host>` (Waycar Host: the Docker host's address, port
  `2222`, user `waycar`, the key whose public half you passed). Host keys are generated at first start, so the
  fingerprint changes on every new container (the entrypoint prints them: `docker logs corelab`).
* `-e LAB_GENERATE_CLIENT_KEY=1` makes the container create a throwaway client key *inside* itself
  (`/home/waycar/.ssh/id_lab`, used by default in the container's own ssh config) so `ssh waycar@127.0.0.1` works
  from `docker exec -u waycar`. This is how the loopback probes run. `-e LAB_LOGIND_DIR=1` also creates
  `/run/user/<uid>` like logind on a real Linux host. `-e LAB_SSHD_ARGS='-o ClientAliveInterval=15 -o ClientAliveCountMax=4'`
  passes extra sshd options.

## Use it

```sh
L() { docker exec -u waycar corelab "$@"; }
# install herdr-core the official way, over a real ssh exec channel (no tty), as the app's installer does
L ssh -T -o BatchMode=yes -o StrictHostKeyChecking=accept-new 127.0.0.1 'curl -fsSL https://releases.herdr.dev/core/install.sh | sh'
# the lab terminals (any user shell works; the script finds ~/.local/bin/herdr-core itself)
L ssh -T 127.0.0.1 'sh $HOME/lab/launch-lab-terminals.sh'            # add `reset` as first argument to kill+remove the old ones first
L /home/waycar/.local/bin/herdr-core ls --json
```
Fake agents take commands as input lines: `L ~/.local/bin/herdr-core send alpha work` (working 10..90 over 3 s, done, idle).
`charlie` starts `blocked` (permission) and waits for `y`/`n`: `terminal.send` refuses a blocked terminal (`kind: blocked`),
so answer with `L ~/.local/bin/herdr-core keys charlie y enter` (or `send --force`). `herdr-core ls --json` is a compact
projection (address, agent, cwd, name, state, status, turn); labels, cols and rows need `terminal.list`/`terminal.get`.

The probes are not in the image; copy them in when you need them:
`docker cp docs/research/herdr-core/real-ssh/probes corelab:/home/waycar/lab/ && docker exec corelab chown -R waycar:waycar /home/waycar/lab`.
Then, as `waycar` in `~/lab/probes` (`REAL-SSH-FACTS.md` has the exact connect line):
```sh
export LAB_REMOTE_LINE="sh -c 'PATH=\$HOME/.local/bin:/usr/bin:/bin; p=\$(command -v herdr-core) || p=\$HOME/.local/bin/herdr-core; [ -x \"\$p\" ] || { echo \"herdr-core is not installed here\" >&2; exit 127; }; exec \"\$p\" connect'"
python3 hc_probe.py --ssh 'ssh -T -o BatchMode=yes 127.0.0.1' call hello
python3 hc_attach_probe_ssh.py --ssh 'ssh -T -o BatchMode=yes 127.0.0.1' --subscribe --do sleep:20
python3 s4a.py     # ssh -tt attach on a local pty (DA1, resize, detach); s4b s5a s5b s5c s6 s7pty = the other scenarios
```
`probes/scenarios/*` are the shell/python drivers behind the numbers in `REAL-SSH-FACTS.md`; their raw output is in
`real-ssh/evidence/out/`. The byte captures (pipe and ssh streams with equal sha256, 2.2 MB) are not committed: regenerate them with the probes.

## Reset

* Soft reset (keeps the install): `L ssh -T 127.0.0.1 'sh $HOME/lab/launch-lab-terminals.sh reset'`.
* Fresh core state: `L /home/waycar/.local/bin/herdr-core server stop` (this **kills** the programs), then
  `L rm -rf /home/waycar/.local/state/herdr-core`.
* Back to "herdr-core not installed" (to test the install path again): `L rm -rf /home/waycar/.local/bin/herdr-core /home/waycar/.local/bin/hc /home/waycar/.local/state/herdr-core` after stopping the core.
* Noisy shell rc experiments: `/home/waycar/.bashrc.orig` and `.profile.orig` are the stock files if you saved them (the probes do); otherwise copy `/etc/skel/.bashrc` and `/etc/skel/.profile` back.
* Simplest of all: `docker rm -f corelab` and start a new one (new host keys, empty home).

## Clean up

```sh
docker rm -f corelab                               # also frees the published port
docker rmi corelab:1                               # the image you built
```
