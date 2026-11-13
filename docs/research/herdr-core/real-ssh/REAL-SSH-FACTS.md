# herdr-core over a REAL OpenSSH server: facts (WAY-472, CoreRealSshProbe)

Lab: Ubuntu 24.04.5 container (`OpenSSH_9.6p1 Ubuntu-3ubuntu13.20`, kernel 7.0.0-38), sshd on :22, user `waycar` (uid 1001, no sudo binary),
key auth only, `AllowTcpForwarding no`, `PrintMotd yes`, `UsePAM yes`, stock `.profile`/`.bashrc` from `/etc/skel`. Client = the `ssh` of
the same image, `ssh -T -o BatchMode=yes 127.0.0.1` (loopback). herdr-core installed by the **official online installer**:
`hc 0.1.14`, sha256 `1a4919b72d8c2c0bb528b963fc3aa7c873ada6f93ff9680767efa8d7f4724c00`, 6 694 040 bytes.
Date 2026-10-29. Every number is in `evidence/out/*` (raw output); drivers are in `probes/`. The byte captures (`evidence/cap/*`, 2.2 MB, pipe versus ssh streams) are not committed: regenerate them with the probes against `scripts/core-lab`.

Tags: **OBSERVED** = ran it (command + excerpt), **SOURCE** = file:line, **[INFERENCE]** = not run.
Image revisions: experiments ran on `corelab:1` (host keys were baked in by apt) and `:2`; the delivered Dockerfile fixes that (host keys removed at build,
generated at first start) and the fake agent's `blocked` mode (`:4`). `final-proof.txt` re-ran install, launch and `ls --json` on `:4`. Nothing else differs.

## Surprises (read first)

1. **A noisy `~/.bashrc` DOES corrupt a plain `ssh -T host '<cmd>'` exec on Ubuntu.** OBSERVED: with `echo NOISE-BASHRC-TOP` as line 1 of `.bashrc`,
   `ssh -T host 'echo X'` prints `NOISE-BASHRC-TOP\nX\n`, and the connect line's stdout starts `NOISE-BASHRC-TOP\n{"id":0,...`. Cause: Debian/Ubuntu's bash reads
   `~/.bashrc` even for non-interactive, non-login `bash -c` when `SSH_CONNECTION` is set [INFERENCE: build option `SSH_SOURCE_BASHRC`; the behaviour is OBSERVED,
   the option name is not checked]. Only the part above the stock "not interactive: return" guard runs. `.profile` noise and noise after the guard do NOT reach an exec
   channel (OBSERVED, section 7). This contradicts the expectation "it should not for non-interactive exec" in the assignment. It agrees with, but sharpens,
   `attach-facts.md` Gotcha 3 ("anything the login shell prints to stdout corrupts the stream") and design §5 ("treat the first byte that does not start the `hello` reply as a failure").
   Remedy that works (OBSERVED): print a marker line from the connect line just before `exec` and discard everything up to it (section 7).
2. **`ssh -T host` + stdin script is not clean even with stock rc files**: the login shell prints the full Ubuntu banner + `/etc/motd` on stdout
   (`Welcome to Ubuntu 24.04.5 LTS ...`, 16 lines before the first command output, OBSERVED). `ssh -T host sh -s < script` and `ssh -T host '<cmd>'` do not. Use a command, never a bare login shell.
3. **Ubuntu's exec PATH is not `/usr/bin:/bin`.** OBSERVED `ssh -T host 'printf %s "$PATH"'` → `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin`.
   Contradicts `rpc-facts.md` §2: "[INF] ... yields a poor PATH on macOS/most Linux (sshd default `/usr/bin:/bin`)". Only user directories (`~/.local/bin`, nvm, cargo) are missing; the C5 conclusion (pass `env.PATH`) stands.
4. **The login PATH only contains `~/.local/bin` once that directory exists.** OBSERVED on a fresh container before the installer: `bash -lc 'printf %s "$PATH"'` has no `~/.local/bin`; after the
   installer it is the first entry (Ubuntu's `.profile` adds it only `if [ -d "$HOME/.local/bin" ]`). Design §5 caches the login PATH per Host in `HostConnectionMemory`:
   a PATH resolved before the first install (or before `claude` created `~/.local/bin`) stays without it until the "re-resolve once on `spawn_failed`" path runs [INFERENCE for the caching consequence].
5. **`ServerAliveInterval=15 ServerAliveCountMax=4` does not free a ghost viewer on the host.** Contradicts `attach-facts.md` §4 "A half-open TCP connection is only noticed when sshd
   notices: hc's own machine links use `... ServerAliveInterval=15 ServerAliveCountMax=4` ... copy those" and Gotcha 13 "Use SSH keepalives" if read as a cure for ghosts. OBSERVED: with the
   link frozen, the client gives up at 74.5 s but the core keeps the viewer (and its PTY size) for the whole 170 s window; stock sshd has `ClientAliveInterval 0`. Only server-side
   `ClientAliveInterval 15 / ClientAliveCountMax 4` freed the viewer (75.5 s). The app cannot change a Host's sshd config (section 5).
6. **The installer's "update" branch restarts the core even when the version is identical** (`hc updated to 0.1.14.` with the same sha256): every open connection hits EOF (OBSERVED, section 1).
7. `herdr-core server restart` took **0.26–0.32 s** over ssh in 4 of 5 runs, **3.29 s** once (the first restart of that core). `attach-facts.md` §6 says 3.09 s. Cause of the difference not determined.
8. `server stop` can silently not stop: if `/run/user/<uid>` appears after a core was started with the state-dir socket, `server stop` prints `{"stopped":false}` and `ls` fails
   with `kind: unavailable ... the core listens at /home/waycar/.local/state/herdr-core/default/default.sock, but this shell looks at /run/user/1001/herdr-core/default.sock` (OBSERVED, section 3).
9. `ssh -tt` (OpenSSH) appends `Connection to 127.0.0.1 closed.` to the PTY after hc's own last line. Design §8 "The line may reach the screen; that is fine" holds; a non-OpenSSH client will not print it.
10. Fake `blocked` agents are not answerable with `terminal.send` (`kind: blocked`, by design) — use `terminal.keys ["y","enter"]` (OBSERVED, `rpc-facts.md` §5 says so; the lab README now says so).
11. `herdr-core ls --json` is a compact projection `{address, agent, cwd, name, state, status, turn}` (no labels/cols/rows); `--label K=V` filters. Not in `rpc-facts.md` (that file is about `terminal.list`).

Confirmed unchanged by the real sshd: the byte stream, framing and timing (section 2), DA1 wait of ~0.5 s (section 4), detach on channel close (section 4), PTY size rules (section 4), EOF + no CLOSE on core restart (section 6).

## Not verified

- macOS host (zsh `.zshenv`/`.zprofile`, `launchd`, no `/run/user`, sshd PATH `/usr/bin:/bin:/usr/sbin:/sbin`), fish/csh login shells, a Linux host with a real systemd user manager and linger (`systemd-run --user` core start, session-var refresh), pam_systemd setting `XDG_RUNTIME_DIR`.
- Any SSH client other than OpenSSH `ssh` (the app's library: its `window-change`, keepalive, channel close and exec-without-pty behaviour). Only mux fallback and error text of OpenSSH were seen.
- A real network cut (Wi-Fi/cellular roam, NAT rebind, RST after heal): emulated with a loopback proxy that stops forwarding without FIN/RST (`probes/cutproxy.py`). Ghost lifetime with stock sshd beyond 170 s (TCP keepalive defaults 7200 s/75 s/9 probes are read from `/proc`, not waited for).
- Reaching the lab from the Mac simulator through a published container port (the probes ran inside the container).
- A newer herdr-core than 0.1.14 (the installer's "latest" is the installed version, so no version change was exercised); `hc update` via ssh; downgrade; `HC_VERSION`.
- `AllowTcpForwarding no` consequences for the app (none seen: no forwarding is used); `UsePAM no`; sshd `MaxStartups` pressure; `MaxSessions` raised.
- Real agents (paid, not run). Fake agents only.
- That every noisy-rc effect applies to other distros' bash (Fedora/Arch ship bash without that build option [INFERENCE]).
- Heartbeat/CREDIT/`missed` under real flow-control stalls over ssh (SIGSTOP of the client was done; the credit window never filled: no queue growth seen, see section 5).

## Differs from the pipe emulation

| What | Pipe emulation (`rpc-facts.md`, `attach-facts.md`) | Real sshd |
|---|---|---|
| bytes core→client / client→core | n/a | **identical** to pipes for the same session (sha256 equal, section 2) |
| time to first reply | `hello` in 2 ms | **0.194 s**: ssh connect + auth + PAM session; a second request on the same connection: same as pipes (50 ms sleeps in the probe) |
| exec env | `env -i HOME PATH=/usr/bin:/bin ...` | `HOME SHELL=/bin/bash LANG=C.UTF-8 (pam_env /etc/default/locale) LOGNAME USER PATH=<long system PATH> PWD SSH_CLIENT SSH_CONNECTION`; no `XDG_RUNTIME_DIR`, no `SSH_TTY` without `-t` |
| login scripts | none | `.bashrc` above the guard runs for exec (Surprise 1); `.profile` does not; motd only for a bare login shell |
| client stderr | n/a | `Warning: Permanently added '127.0.0.1' (ED25519) ...` (first connect, stderr) and, with `-tt`, `Connection to 127.0.0.1 closed.` on the PTY |
| exit status | `hc connect` exit | passed through by ssh: `127` for "not installed", `3`/`11` for attach errors; ssh's own failures are `255` |
| half-open connection | `kill -STOP hc connect` only | sshd keeps the session (stock config); core sees nothing (section 5) |
| core socket | `$XDG_RUNTIME_DIR/...` or state dir | no `XDG_RUNTIME_DIR` and no `/run/user/1001` in the container → state-dir socket `~/.local/state/herdr-core/default/default.sock`; on a logind host `/run/user/<uid>/herdr-core/` (Surprise 8) |
| core start | transient detached child | `setsid`-detached `herdr-core serve`; **survives the ssh channel closing** (OBSERVED: first started by `ssh host 'herdr-core server status'`, still running afterwards) |
| ssh multiplexing | n/a | `MaxSessions 10` per connection (section 8) |

## 1. The official installer, online, over a non-interactive ssh exec

**OBSERVED** fresh container (nothing in `~/.local`, no core, no state): `ssh -T -o BatchMode=yes 127.0.0.1 'curl -fsSL https://releases.herdr.dev/core/install.sh | sh'`
```
stdout:  hc 0.1.14 installed into /home/waycar/.local/bin/herdr-core.
         Add /home/waycar/.local/bin to your PATH to use hc.
         Agents: hc --skill. People: hc --help.
stderr:  (empty)        exit code: 0        time: 0.66 s (0.73-0.78 s on three other fresh containers)
```
- Files: `~/.local/bin/herdr-core` (`-rwxr-xr-x`, 6 694 040 B) and `~/.local/bin/hc -> herdr-core` (no other `hc` existed). Nothing else under `~/.local`, no `~/.config`, no `~/.local/state`.
  (`~/.cache/motd.legal-displayed` appears, but from the PAM session of the ssh login, not the installer.) No rc file edited.
- **No core running afterwards** (`ps` finds no `herdr-core serve/hold`; no `~/.local/state`).
- PATH advice: printed although it is only advice; a following `ssh host 'herdr-core --version'` fails: `bash: line 1: herdr-core: command not found`, exit 127. `ssh host '~/.local/bin/herdr-core --version'` → `hc 0.1.14`, exit 0.
- Login PATH before/after: section 3 / Surprise 4.

**Second run, no core running** (the update branch): stdout `hc updated to 0.1.14.` + the same two lines; **stderr** `hc: no systemd user manager here: the core ends with whatever started it`; exit 0, 0.75 s;
afterwards `herdr-core serve` (pid 221 in that run) is running and `~/.local/state/herdr-core/default/{core.json,core.lock,core.log,default.sock,screens,terminals.json}` exist. It survived the ssh channel closing.

**Third run, core running with 11 live terminals (lab agents plus two `sh` loops) and a framed event subscriber open** (`evidence/out/upd.txt`):
```
before: core pid 13996 uptime_ms 33050 live 11 holder pid 1820
rc=0 time=0.694s     stdout: hc updated to 0.1.14. ...     stderr: hc: no systemd user manager here...
after:  core pid 14571 uptime_ms 27 live 11 holder pid 1820
subscriber: [1.644] EOF on hc stdout (connection closed) / [1.744] connect process exit code 0
```
Same sha256 (`1a4919b7...`) before and after, but a new mtime: the binary is re-installed and the core restarted although the version is the same. The 10 agent program pids (and the holder pid) were unchanged
(the one `agent pids CHANGED` line in `upd.txt` is my own `grep -E "...|sleep 600"` matching its own command line). The subscriber saw EOF and `ssh` exit 0; no CLOSE frame.
[INFERENCE] Installing from the app while a Console is open therefore ends that Console's connection: reconnect + re-snapshot, as for any restart.

## 2. The design's connect line over ssh exec, no tty

Line used (design §5 shape, PATH = login PATH):
`sh -c 'PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin; p=$(command -v herdr-core) || p=$HOME/.local/bin/herdr-core; [ -x "$p" ] || { echo "herdr-core is not installed here" >&2; exit 127; }; exec "$p" connect'`
run as `ssh -T -o BatchMode=yes 127.0.0.1 "<line>"`.

- **hello, plain** (`hc_probe.py --ssh ... call hello`): reply is the same single line as over pipes (`{"id":1,"jsonrpc":"2.0","result":{"core":{"id":"0525...","name":"<container id>"},"features":["framed","attach","events","status","shell"],"framed":false,"generation":1,"methods":[32 names],"version":"0.1.14"}}`). `features` run: no missing method.
- **hello, framed, `terminal.get`, `terminal.attach observe` on `alpha`, CLOSE** (`hc_attach_probe_ssh.py`): ch0 reply first, then first paint 404 B on ch1, `ch=1 CLOSE reason=null` after our CLOSE, `connect process exit code 0`.
- **Byte comparison, same core, same script, pipe (`herdr-core connect`) vs ssh, 2 runs each** (`evidence/cap/{pipe1,pipe2,ssh1,ssh2}.*`, not committed):
  ```
  hello line  sha256[:12] 3c058bdaa604  (all four)      core->client frames  d2cf4d3ee16e (all four, 1843 B)     client->core  41313575bdc1 (all four)
  ```
  **Identical bytes, identical framing**: no extra bytes, nothing before the hello line, no re-chunking visible in the 9-byte-header reads. The only difference is time: the first reply arrives at 0.191–0.194 s over ssh vs 0.002 s over a pipe (ssh handshake; `ssh -tt host printf hi` baseline is 0.190–0.198 s to first byte,
  0.216 s to exit); later exchanges have the same spacing as pipes (reply to the 2nd request 0.051 s after the 1st in both).
- **events.subscribe with CREDIT** (probe sends CREDIT = payload length per DATA frame): snapshot `seq` + terminals, then event lines in DATA frames. Heartbeat OBSERVED at **15.19 s and 30.19 s** on the probe clock (subscribe at ≈0.19 s) = 15.00 s after the subscription, same as the pipe fixture.
  A pipe and an ssh subscriber attached to the same core at once received the same events: 89 ssh events, 90 pipe events (one more before the ssh subscription), 89 common, **89 byte-identical** (`sort_keys` JSON), arrival-time difference −1…+2 ms (`probes/scenarios/evcmp.py`).
- **terminal.list**: works (`call terminal.list` and via `events` snapshot).
- **Full `launch-lab-terminals.sh reset` while subscribed** (killed 9 old terminals, started 9): counts for that stretch: `{'status': 41, 'finished': 9, 'turn': 2, 'removed': 9, 'created': 9, 'title': 10, 'foreground': 9}`. Per new terminal:
  ```
  created     {"address":"t12","name":"charlie","labels":{"lab":"core"},"cwd":"/home/waycar/work/charlie","cols":200,"rows":120,"state":"live","argv":["sh","/home/waycar/lab/fake-agent.sh","charlie","blocked"]}
  title       {"title":"charlie"}
  status      {"records":{},"reported":true,"status":{"app":"charlie","kind":"permission","msg":"Allow rm -rf /tmp/x?","state":"blocked"}}
  foreground  {"argv":["sh","/home/waycar/lab/fake-agent.sh","charlie","blocked"],"cwd":"/home/waycar/work/charlie","name":"sh","pid":1046}     (+50 ms)
  ```
  The plain shell: `created` (argv `["/bin/bash"]`), `foreground` (bash), `title` `waycar@<host>: ~/work/shell` (bash prompt OSC 0).
  Kill: `status {...,"status":null}`, `finished {"exit_code":0,"reason":"killed","signal":null}` (fake agent traps SIGHUP and exits 0) or `signal:1` (plain shell), then `removed {}`.
- **Event sequence for one `work` turn on a fake agent** (`herdr-core send alpha work`, seq values are core-wide; the gaps are other terminals' events; t = seconds from the first `working`):
  ```
  -0.003 title      {"title":"alpha"}
   0.000 status     {"records":{},"reported":true,"status":{"app":"alpha","msg":"working 10%","progress":10,"state":"working"}}
   0.334 status     ... "msg":"working 20%","progress":20    (then 30..80 every 0.335 s)
   2.687 status     ... "msg":"working 90%","progress":90
   3.023 status     {"records":{},"reported":true,"status":{"app":"alpha","msg":"work finished","state":"done"}}
   3.023 turn       {"state":"done","turn":1}
   3.023 status     {"records":{},"reported":true,"status":{"app":"alpha","state":"idle"}}
  ```
  `done` and `idle` arrive in the same millisecond, so a client that only samples the state sees `working` → `idle` and learns about `done` only from the `status` event itself or `turn` (`state:"done"`).
  `ask`: `blocked` → (after `y`) `working` → `done` (`final-proof.txt`: `charlie` `done`, turn 1). A blocked terminal refuses `terminal.send` with `kind:"blocked"`; `terminal.keys ["y","enter"]` goes through.
- Attach flood without CREDIT (stall at 262 144 B): same total over pipe and ssh; DATA frame lengths differ between runs (503 vs 835 frames) because the core batches by timing, not because of ssh (`evidence/out/flood.txt`).

## 3. Environment of a core first started by an ssh exec

Three fresh states (`herdr-core server stop`, `rm -rf ~/.local/state/herdr-core`, no `herdr-core serve/hold` process), then `terminal.run {"line":"echo PATH=$PATH SHELL=$SHELL HOME=$HOME PWD=$PWD; env | grep -E '^(SSH_|XDG_|HC_|LANG|TERM|USER|LOGNAME|MAIL)' | sort","wait":true}` through a second connect (`evidence/out/s3-env.txt`).

| first start by | PATH the terminal saw |
|---|---|
| **A** `ssh -T host '~/.local/bin/herdr-core server status'` (stderr: `hc: no systemd user manager here...`; `herdr-core` by bare name: exit 127) | `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin` |
| **B** the connect line without a PATH export (hc's own line) | same as A |
| **C** the design's line exporting the login PATH | `/home/waycar/.local/bin:/usr/local/sbin:...:/snap/bin` (starts with `~/.local/bin`) |

All three: `SHELL=/bin/bash HOME=/home/waycar PWD=/home/waycar`, `HC_TERMINAL_ID=t1`, `HC_TERMINAL_SOCKET=/home/waycar/.local/state/herdr-core/default/default.sock`, `HC_SCOPE=...`, `LANG=C.UTF-8`, `LOGNAME=waycar`, `USER=waycar`, `TERM=xterm-256color`, `TERM_PROGRAM=ghostty`. **No `SSH_*`** (stripped; the exec itself had `SSH_CLIENT`, `SSH_CONNECTION`), **no `XDG_*`**, no `HC_SESSION`.
`LANG=C.UTF-8` comes from sshd/PAM: `/etc/default/locale` contains `LANG=C.UTF-8` and the ssh exec env has it (the client sent no `LANG`). The second connect's env did not change the first start's PATH (A, B: `~/.local/bin` absent although the second connect was the same line).
- Login PATH, all OBSERVED identical on this host: `bash -lc`, `$SHELL -lc`, `sh -lc`, `bash -ilc` → `/home/waycar/.local/bin:/usr/local/sbin:...:/snap/bin`; plain exec PATH lacks `~/.local/bin`. **Does `~/.local/bin` appear? Yes in the login PATH, only if the directory exists (Surprise 4)**: before the installer
  `bash -lc` printed `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin`, after it `/home/waycar/.local/bin:...`.
- `.profile` echo does not corrupt an exec channel; `.bashrc` echo above the guard does. Full proof in section 7. (A `fish` login shell: not needed, not tested.)
- Socket path / `/run/user`: in this container `/run/user/1001` does not exist, so the socket is in the state dir. OBSERVED with `/run/user/1001` created afterwards (as logind would on a real host) while a state-dir core ran:
  `ssh host '~/.local/bin/herdr-core server stop'` → `{"stopped":false}` (the core keeps running), `herdr-core ls` →
  `{"error":{"hint":"XDG_RUNTIME_DIR or HC_SOCKET differs from where the core started; set HC_SOCKET to the first path","kind":"unavailable","message":"the core listens at /home/waycar/.local/state/herdr-core/default/default.sock, but this shell looks at /run/user/1001/herdr-core/default.sock"}}`.
  With `HC_SOCKET=<state path>` stop worked; a fresh core then listened at `/run/user/1001/herdr-core/default.sock` and `core.lock` said so. `LAB_LOGIND_DIR=1` creates that directory at container start to test the logind layout.

## 4. `ssh -tt ... 'herdr-core attach <addr>'` on a local PTY

Command: `/bin/sh -c 'PATH=...; p=$(command -v herdr-core) || p=$HOME/.local/bin/herdr-core; [ -x "$p" ] || {...exit 127;}; printf "@@WAYCAR-ATTACH@@\n"; exec "$p" attach "$1"' attach 'alpha'` via `ssh -tt -o BatchMode=yes 127.0.0.1` (Python PTY, `TERM=xterm-256color`, `probes/ptyssh.py`, `s4a.py`, `s4b.py`; sizes read with a local `herdr-core get alpha --json`).

- **Output**: `@@WAYCAR-ATTACH@@\r\n` (the marker, `\n`→`\r\n` by the PTY), then hc's startup queries `ESC]10;?ESC\ ESC]11;?ESC\ ESC]12;?ESC\ ESC[16t ESC[c`, `ESC[?1004h`, then the first paint `ESC[!p ESC[?2026l ...` (346 B total for the idle fake agent). Byte-for-byte what `attach-facts.md` §1/§3 describes.
- **Resize** (TIOCSWINSZ on the PTY master → SIGWINCH → ssh `window-change` → hc RESIZE → core): `core size` after each change, polled every 5 ms: 80x24 → 100x30 after 0.093 s (0.034 s once), → 52x28 0.101 s, → 120x40 0.099 s, → 80x24 0.101 s. The delay is hc's ≤100 ms `window_size()` poll (`attach-facts.md` §3); ssh adds nothing measurable.
- **Time to first paint** (spawn → first `ESC[!p`; `ssh -tt host printf` itself needs 0.19 s to first byte):
  with a DA1 reply to `ESC[c` from the outer terminal: **0.195–0.197 s** (3 runs) ⇒ hc adds ≈1–2 ms;
  with no DA1 reply: **0.695–0.699 s** (3 runs) ⇒ **+0.502 s** (the 500 ms wait). `attach-facts.md` says 0.004 s / 0.506 s over pipes: same.
- **Detach by closing the PTY master** (what a dropped channel looks like): ssh exits (`rc=255`, ssh's own) 0.009 s later; core back to **200x120 in 0.011 s** after the close. Detach by `Ctrl+\` (`0x1c`): hc exits 0.015 s later with `[detached from dt1]`, core 200x120.
- **Exit codes and last output** (`evidence/out/s4b.txt`; stdout and stderr share the PTY; before the status line hc restores modes: `...ESC[?7h ESC[?25h ESC[?1007h ESC[r ESC8 ESC[0 q ESC(B ESC[0m ESC]104ESC\ ESC]110ESC\ ESC]111ESC\ ESC]112ESC\ ESC]22;ESC\`):

  | event | ssh exit | last text on the PTY |
  |---|---|---|
  | program exits 3 | **0** (at 1.519 s) | `\r\n[ex1 finished: exited]\r\nConnection to 127.0.0.1 closed.\r\r\n` |
  | `herdr-core kill` | **0**, 0.121 s after the kill | `[kl1 finished: killed]` + ssh line |
  | `Ctrl+\` | **0** | `[detached from dt1]` + ssh line |
  | unknown terminal | **3** | `error: no terminal "nope"\r\nhint: see \`hc ls --all\`` + ssh line |
  | finished terminal | **11** | `error: t11 has finished\r\nhint: read what it left: hc read t11` + ssh line |
  | `herdr-core` missing | **127** | `herdr-core is not installed here\r\n` + ssh line |
  | core restarted (section 6) | **0** | `[lost the core; it keeps tick running: hc attach tick]` + ssh line |

  The program's own exit code is not propagated (3 → ssh 0). The `Connection to 127.0.0.1 closed.` line is the OpenSSH client's (silence with `-q`).
- **Two attaches from two ssh sessions** (`two` terminal, program printing `stty size` on SIGWINCH): A 80x24 attached → **80x24**; B 52x28 attached → **52x28**; A types → **80x24**; B types → **52x28**; B resizes to 60x30 → **60x30** (0.008 s);
  B's ssh gone → **80x24**; A's ssh gone → **200x120**. Matches `attach-facts.md` §1 (newest active viewer leads; last detach → 200x120).
- **vim-tiny (alt screen)**: `herdr-core run --bg --name vi1 -- vi -u NONE -N note.txt`, attach 100x30: first paint at 0.194 s, 6 827 B, chunks `[19, 32, 8, 6768]`, contains `ESC[?1049h` and `line one`; core size 100x30.
  Resize to 60x20: core saw it after 0.094 s; 1 200 B followed, starting `ESC[27m ESC[23m ESC[29m ESC[m ESC[H ESC[2J ESC[?25l ESC[1;1Hline one\r\nline two\r\n...` (vim redraws on SIGWINCH). `:q!` → `[vi1 finished: exited]`, ssh exit 0, record `exit_code:0`, `cols:60`.

## 5. Liveness: frozen client, cut link

Core-side view = number of ESTAB unix sockets on `default.sock` (`ss -xpn`), `herdr-core get` size, process list (`probes/s5a.py`, `s5b.py`, `s5c.py`, `cutproxy.py`; raw: `evidence/out/s5*.txt`).

**5a SIGSTOP of an attached ssh client for 60 s, then SIGKILL** (stock sshd):
```
t=0  attached A 80x24: size (80, 24)  core client conns 1, remote `herdr-core attach` 1, sshd established 1
t=0..56 (every 5 s) size (80, 24) conns 1  attach procs 1  sshd established 1          <- no change for 60 s
t=31 B attaches 60x30 -> (60, 30);  t=41 B detaches -> (80, 24)   <- the STOPPED ghost A pins the size
SIGKILL ssh: rc=-9; core size back to 200x120 after 0.002 s; conns 0; no `herdr-core attach` left
```
(`attach procs=2` in the raw lines counts the probing shell's own `pgrep -f`; real value is that minus 1.)
**5b SIGSTOP of a framed events subscriber's ssh for 60 s** (13 samples, bravo emitting an event per second, heartbeats due every 15 s): core client connections stayed 1, queues `Recv-Q 0 Send-Q 0` on the core's socket the whole time, remote `herdr-core connect` process alive; the stalled bytes sit in ssh/sshd/kernel buffers, far below the 256 KiB credit, so the core never notices. SIGKILL: connections 0 after **0.014 s**.
**5c ghost lifetime, four cases, 170 s window** (terminal sizes 80x24/81x25/82x26/83x27 identify the ghosts):

| case | link | sshd | client | what happened |
|---|---|---|---|---|
| C1 | frozen (no FIN/RST) | stock (`ClientAliveInterval 0`) | `-o ServerAliveInterval=15 -o ServerAliveCountMax=4` | client exited at **t=74.5 s**, rc **255**, PTY text `Timeout, server 127.0.0.1 not responding.`; **core still holds the 80x24 ghost at t=170 s** |
| C2 | frozen | `ClientAliveInterval 15, ClientAliveCountMax 4` (second sshd on :2222) | plain | core dropped the viewer (→ 200x120) at **t=75.5 s**; sshd log `Timeout, client not responding from user waycar 127.0.0.1 port 36618` |
| C3 | SIGSTOP of ssh | same as C2 | plain | dropped at **t=75.5 s** (kernel ACKs for the stopped process, but sshd's keepalive request goes unanswered) |
| C4 | SIGSTOP of ssh | stock | plain | **ghost still there at t=170 s** (= 5a) |

So: with the stock host config **a ghost persists indefinitely from the host's point of view** (≥170 s observed; the kernel's TCP keepalive defaults on this host are `tcp_keepalive_time 7200`, `intvl 75`, `probes 9`, `tcp_retries2 15` read from `/proc/sys/net/ipv4`, [INFERENCE] ≈2 h for an idle session, ≈15 min if sshd has data to send, e.g. an active terminal's output).
What pins the PTY size meanwhile: the ghost is a non-observe viewer; it leads while it is the newest active viewer and again whenever the others leave (5a). A new viewer or any typing viewer overrides it immediately. [INFERENCE] The app should (a) use `observe:true` where it only watches, (b) attach with `resumed:true` after a reconnect until the user acts, (c) treat its own 45 s "no frame" rule (heartbeat is 15 s) as the client-side detector, which does not free the host side.
Client `ServerAlive*` is only a client-side detector (C1); it never closes the remote session by itself. [INFERENCE] a cut that heals later is cleaned up by the TCP RST the vanished client's closed socket produces at the next server packet (heartbeat every 15 s on events); not run.

## 6. `herdr-core server restart` while a framed subscription and an attach PTY are open

`ssh -T host '~/.local/bin/herdr-core server restart'` (`probes/s6.py`; `evidence/out/s6*.txt`):
- The restart command: exit 0, stdout `{"core":{...},"finished":9,"holder":{"current":true,...,"terminals":12},"live":12,"pid":13155,"uptime_ms":14,"version":"0.1.14"}`, stderr `hc: no systemd user manager here...`; **0.26–0.32 s in 4 runs, 3.29 s in the first** (Surprise 7). Core `id` unchanged, pid changed, 12 terminals live before and after.
- **Framed subscription over ssh -T**: frames continue to the last complete event frame (`seq 847 status ... bravo step 70`), then **EOF on stdout at the moment the core closes (~0.2 s after the restart command started, i.e. right after its ssh connect), `ssh` exit code 0, no CLOSE frame, no stderr from hc**. `RX bytes per channel` empty (no attach).
- **Attach PTY**: ssh exits **0** within a few ms of the restart reply; last bytes: the mode-restore sequence then `[lost the core; it keeps tick running: hc attach tick]\r\nConnection to 127.0.0.1 closed.`.
- **Reconnect + re-snapshot**: new `ssh` + plain `hello {framed:true}` + `events.subscribe`: hello reply at **0.215 s**, snapshot reply at **0.217 s** (`seq` 0, `terminals` array); whole probe with a 0.3 s hold 0.598 s. Re-attach: first paint **0.219 s** after the ssh process started, contains `tick`, core size back to 80x24. [INFERENCE: dominated by the 0.19 s ssh connect; over a pooled SSH session a new exec channel would be much cheaper.]
- Terminals survive (`tick` kept counting; same holder).

## 7. stdout/stderr cleanliness

Setup: `PrintMotd yes` with a real `/etc/motd`; `.bashrc`/`.profile` variants: none, `echo NOISE-PROFILE` at line 1 of `.profile`, `echo NOISE-BASHRC-TOP` at line 1 of `.bashrc`, `echo NOISE-BASHRC-AFTER-GUARD` right after the stock `case $- in *i*) ;; *) return;; esac`, and all three (`evidence/out/s7-noise*.txt`, `s7-c-variants.txt`, `s7pty.txt`).
Each cell is what reaches **stdout** (no tty):

| rc state | (a) `ssh -T host '<connect line>'` | (b) `ssh -T host 'echo X'` | (c) `printf 'echo X\n' \| ssh -T host` | (d) `... \| ssh -T host sh -s` |
|---|---|---|---|---|
| clean | `{"id":0,...` first byte | `X` | Ubuntu banner + motd (16 lines), then `X` | `X` |
| `.profile` noise | clean | clean | + `NOISE-PROFILE` | clean |
| `.bashrc` top noise | **`NOISE-BASHRC-TOP\n` then `{"id":0,...`** | **`NOISE-BASHRC-TOP\nX`** | banner + motd + `NOISE-BASHRC-TOP`, then `X` | **`NOISE-BASHRC-TOP\nX`** |
| `.bashrc` after-guard noise | clean | clean | clean (non-interactive shell returns at the guard) | clean |
| all | as `.bashrc` top | as `.bashrc` top | banner + motd + `NOISE-PROFILE\nNOISE-BASHRC-TOP\nX` | `NOISE-BASHRC-TOP\nX` |

- **MOTD**: `PrintMotd yes` never reaches an exec (`'<cmd>'`) channel. It is printed for a bare login shell (c) and an interactive `ssh -tt host` (OBSERVED: `Welcome to Ubuntu` and the lab banner present). It is a bare-login-shell-only problem.
- The existing probe `hc_probe.py` crashes on the noise line (`json.decoder.JSONDecodeError: Expecting value: line 1 column 1 (char 0)`): any client that parses the first byte as JSON fails, which is what design §5 asks for.
- **PTY (`ssh -tt`, attach line)**: with the `.bashrc` top noise the PTY starts `NOISE-BASHRC-TOP\r\n@@WAYCAR-ATTACH@@\r\n...`; `ssh -tt host` interactive shows all three noises + motd. stderr: nothing from rc files reached stderr in these runs; the only stderr text seen is ssh's `Warning: Permanently added ...` (first connect) and hc's `hc: no systemd user manager here...` (exit 0).
- **How should the client detect it?** The noise precedes the protocol, ends with a newline in every case seen, and cannot appear after `exec`. Two options:
  1. Design §5 as written: first byte of stdout is not `{` (or the `hello` reply does not parse) → fail with "extra text on login". Correct, but a user with an echo in `.bashrc` can never connect.
  2. OBSERVED to work: have the connect line print a marker just before `exec` — `... ; printf "@@WAYCAR-CORE@@\n"; exec "$p" connect'` — and discard every byte up to and including the marker line:
     ```
     NOISE-BASHRC-TOP
     @@WAYCAR-CORE@@
     {"id":0,"jsonrpc":"2.0","result":{"core":{"id":"73722ea3e24fff22b8f...
     ```
     (the hello is sent after the marker is seen, or at once: the noise comes from the shell before our line runs, so ordering is guaranteed). A marker that never appears within the connect timeout means "not a Waycar-compatible exec" (e.g. `.bashrc` that `exec`s tmux/zsh) [INFERENCE]. Surface the discarded text in the error/diagnostics (it names the culprit).

## 8. sshd limits

`MaxSessions 10` (sshd -T: `maxsessions 10`, `maxstartups 10:30:100`). OBSERVED: 12 simultaneous `ssh -S ctl -T host 'sleep 6; echo done'` over one ControlMaster connection: **10 channels opened on the master, 2 got `mux_client_request_session: session request failed: Session open refused by peer`**; OpenSSH's client then falls back to a fresh connection for the refused ones, so all 12 finished `rc=0` with `done` (3 `sshd: waycar [priv]` listed while sleeping — `evidence/out/s8.txt`). A client that does not fall back sees the SSH channel-open failure `administratively prohibited` / "Session open refused by peer" for the 11th concurrent session on one connection. (The same message family appears for `AllowTcpForwarding no`: `channel 2: open failed: administratively prohibited: open failed`, OBSERVED with `ssh -L` from a second container.)

## Lab acceptance evidence

`evidence/out/final-proof.txt` (image `:4`, fresh container, port published as `<docker host>:<port>`→22): installer exit 0 in 0.73 s; `launch-lab-terminals.sh` started 9 terminals; `herdr-core ls --json`:
```
t1 alpha   idle     /home/waycar/work/alpha      t6 shell   (no status)  /home/waycar/work/shell
t2 bravo   working  /home/waycar/work/bravo      t7 sp1-tb1 idle  (herdr.space=sp1 herdr.tab=tb1)
t3 charlie blocked  /home/waycar/work/charlie    t8 sp1-tb2 idle  (herdr.space=sp1 herdr.tab=tb2)
t4 delta   done     /home/waycar/work/delta      t9 sp2-tb1 idle  (herdr.space=sp2 herdr.tab=tb1)
t5 echo    error    /home/waycar/work/echo       --label herdr.space=sp1 -> [sp1-tb1, sp1-tb2]; sp2 -> [sp2-tb1]
```
`work` on alpha: `working` → `idle`, turn 1. `charlie`: `send y` refused (`blocked`), `keys y enter` → `done`, turn 1. `LAB_AUTHORIZED_KEY` path: a second container started with the first one's public key accepted it (`authorized_keys=1 line`), had different host keys, refused password auth (`Permission denied (publickey)`) and refused forwarding (`administratively prohibited`).
