# herdr-core request/response API over `hc connect` — verified facts (WAY-472, HcRpcProbe)

Binary under test: `hc 0.1.14` (linux x86_64, static; `herdr-core`, `hc` is a symlink), source commit 29e6d37.
Everything ran as plain-mode JSON-RPC 2.0, one line per message, through `hc connect` pipes (no pty), in isolated scratch sessions.
Tags: **OBS** = observed here (command/excerpt); **SRC** = read in source (`herdr-core/crates/herdr-core/src/…`, `file:line`); **[INF]** = inference.
Paths (repo-relative, this file's directory): fixtures in `fixtures/rpc-*.json` (real captures; one hand-made, marked; index in `fixtures/README.md`), script `hc_probe.py`.
Re-run anything with `hc_probe.py call METHOD '{json}'` inside a scratch env (see the script's header; point it at a binary with `--hc` or `HC_BIN`).

Conventions used below: "record" = a Terminal object (the thing `terminal.run/get/list/kill/label/keep` return and events carry).
Wire excerpts are exact lines from stdout, trimmed with `…`.

---

## 1. `hello`, errors, feature detection, minimum core version

**OBS** `{"jsonrpc":"2.0","id":1,"method":"hello","params":{}}` →
```
{"id":1,"jsonrpc":"2.0","result":{"core":{"id":"2cd73df696a22eb8527c71f0c2168b50","name":"6a09d8670141"},"features":["framed","attach","events","status","shell"],"framed":false,"generation":1,"methods":["hello","server.status","server.stop","server.restart","terminal.run","templates.list","terminal.list","terminal.get","terminal.kill","terminal.rm","terminal.keep","terminal.label","terminal.read","terminal.attach","terminal.send","terminal.wait","terminal.keys","terminal.interrupt","terminal.put","machine.exec","file.read","file.write","file.edit","doc.get","doc.set","events.subscribe","machine.add","machine.list","machine.connect","machine.rename","machine.rm","rpc.discover"],"version":"0.1.14"}}
```
(fixture `fixtures/rpc-hello.json`)

| field | type / meaning |
|---|---|
| `core.id` | 32 hex, permanent random id of this core's state dir; reset only if state is wiped (SRC `api/types.rs:12-18`). Same id after `server.restart` (OBS). |
| `core.name` | the host's short hostname, lower-cased and sanitised to `a-z0-9-_.` (SRC `server.rs:hostname`, `addr.rs:clean_name`). Used as the machine name in `name/t7` addresses. |
| `version` | string `0.1.14`. Do not feature-detect on it. |
| `generation` | u32, protocol generation, `1` (SRC `api.rs:15`). The only compat gate: `hello {"generation":2}` → error `unsupported_generation` (OBS below). Omit it or send 1. |
| `features` | `["framed","attach","events","status","shell"]` (SRC `api.rs:16`). `shell` = "terminal.run with no argv / with `line` works" (added 0.1.6). |
| `methods` | the method table, in table order. **OBS: the set equals the OpenRPC doc's method set (32 = 32, `rpc.discover` result `==` `schema/hc.openrpc.json`, `released.openrpc.json` == current at 0.1.14).** |
| `framed` | echo of the request flag. Request params (`generation`, `framed`, `core`, `calls_you`) are all optional; `core`/`calls_you` are for core→core peers (ignore). |

Unknown extra params are **ignored** everywhere (`hello {"bogus":1}` → normal result, OBS). `"jsonrpc":"2.0"` is not checked (OBS: `{"id":12,"method":"hello"}` works). Notifications (no `id`) get no reply (OBS). String ids are echoed back (OBS `"id":"abc"`). Object keys in replies are alphabetically sorted (serde_json), not request order.

**Error object** (SRC `rpc.rs:41-43`, OBS everywhere): `{"error":{"code":<int>,"message":"<human>","data":{"kind":"<stable>","hint":"<human>"}},"id":..,"jsonrpc":"2.0"}`.
- `code`: -32700 parse_error, -32600 invalid_request, -32601 unknown_method, -32602 invalid_params, -32603 internal; **everything else is -32000** (so branch on `data.kind`, not `code`).
- unknown method: `{"error":{"code":-32601,"data":{"hint":"see `hc schema`","kind":"unknown_method"},"message":"unknown method \"nope.method\""},"id":9,…}`
- unparseable line: `{"error":{"code":-32700,"data":{…"kind":"parse_error"},"message":"expected ident at line 1 column 2"},"id":null,…}` (connection stays open).
- missing `method`: `-32600 invalid_request "missing method"`. `params` as array → `invalid_params` ("invalid length 0, expected struct …"). Missing field: `invalid_params "missing field `terminal`"`. Wrong type: `invalid_params "invalid type: integer `5`, expected a string"`.
- `hint` may be `""` (internal; `machine.exec` spawn_failed OBS).

**All `data.kind` values** (SRC grep of `RpcError::new("…")` + `rpc.rs` + OpenRPC `errors`; `fixtures/rpc-errors.json` has live samples of the bold ones):
- protocol (`rpc.rs`): **parse_error**, **invalid_request**, **unknown_method**, **invalid_params**, internal (also `doc.set` may return it).
- terminals: **not_found**, **name_taken**, **spawn_failed**, unavailable, invalid_template, **finished**, **live** (rm of a live terminal), **blocked**, **status_mismatch**, needs_target, needs_framed, refused (attach/own-terminal), busy (core-internal note typing, not returned to clients).
- hello: **unsupported_generation**.
- machine/files/docs: **machine_unknown**, needs_update, needs_login, unreachable, hc_missing, incompatible, already_added, install_failed, denied (peer cores), windows (internal), config (bad config.toml/templates path), **conflict** (doc.set version), **edit_failed**, not_text, io.
- CLI-only (never over RPC): usage (exit 2), cancelled.
- Declared per method in OpenRPC `errors`; not every kind that can occur is declared (e.g. `refused`, `denied`, `busy`, `needs_login` are raised but not listed) — **treat the set as open; unknown kind ⇒ generic failure showing `message`+`hint`.**

**Is every OpenRPC method in `hello.methods`?** Yes, equal sets (OBS python: `set(openrpc) - set(hello.methods) == set()` both directions).

**Feature detection recipe (SRC `remote.rs:1000-1030` is herdr-core's own client doing this):** call `hello`, require the needed names in `methods`; do not send an unknown method just to probe (it returns `unknown_method`, harmless, but `hello` is cleaner). On 0.1.14 `terminal.keys`, `doc.get`, `doc.set`, `events.subscribe` are all present (OBS). Older core: `unknown_method` for the missing method (herdr-core maps that to its own `needs_update`).

**When were methods added — measured, not guessed.** The git repo is a single squashed commit (`git log` has 1 commit), release notes are just "chore: release X". So I downloaded every release 0.1.0…0.1.13 from `releases.herdr.dev/core/<v>/manifest.json` (sha256-verified, scratch dir), ran each, sent `hello` + `rpc.discover`, and diffed (`fixtures/rpc-version-matrix.json`, `hc_probe.py NEEDED`):

| release | what is new |
|---|---|
| 0.1.0 | 25 methods incl. `hello terminal.run/list/get/kill/rm/label/read/attach/send/wait/keys/interrupt/put templates.list events.subscribe rpc.discover server.* machine.add/list/connect/rename/rm`. Terminal record already has `foreground`, `labels`, `status`, `records`, `reported`, `turn`, `parent`, `die_with_parent`, `title`, `template`, `rm`… features `framed attach events status`. |
| 0.1.4 | `terminal.attach` gains `caller` |
| 0.1.5 | `terminal.read` result may carry `why` |
| **0.1.6** | **`machine.exec`**, `terminal.run.line`, feature `shell` (run with no argv = own shell) |
| **0.1.8** | **`doc.get`, `doc.set`, `terminal.keep`**, record field `keep`, `terminal.run.keep` |
| 0.1.9 | `terminal.attach.resumed` |
| **0.1.10** | **`file.read/write/edit`**, record field `status_ms`, machines `via`/`temporary` |
| 0.1.11, 0.1.12 | no schema change |
| 0.1.13 | `terminal.run.outlive_parent` (`die_with_parent` stays but is "ignored: children end with their parent unless outlive_parent") |
| 0.1.14 | no schema change vs 0.1.13 |

Smoke-tested the same request set (run argv, send, keys, read, kill, list, subscribe) against all 14 builds: identical result shapes except the record gaining `keep` (0.1.8) and `status_ms` (0.1.10) and `run {line}` failing with `invalid_params "missing field `argv`"` before 0.1.6 (OBS).
**Recommendation [INF]:** minimum 0.1.10 if the app uses `file.*` or `status_ms`; 0.1.8 if only `doc.*`/`keep`; 0.1.6 floor for `machine.exec` + `line`; 0.1.0 has everything else. Gate each feature on `hello.methods`, show "update hc" otherwise (`hc update` is the upgrade path; `install.sh` or `hc update` restarts the core, terminals keep running — SRC `distribution/install.sh:59-62`).

---

## 2. Connecting

**What `hc connect` is (SRC `cli.rs:808-827`):** it opens the core's Unix socket (starting the core if nobody listens), then is a dumb byte pump stdin→socket and socket→stdout. Nothing else is ever written to stdout. OBS: stdin EOF immediately → exit 0, stdout 0 bytes, stderr 0 bytes. SRC: no banner / update-notice code exists (`grep -i "update available|nag"` → nothing). Errors of `hc connect` itself go to **stderr** as one JSON line `{"error":{"hint","kind","message"}}` plus a non-zero exit (usage=2, unavailable=5, …; SRC `rpc.rs:55-69`). OBS: `--session a/b` → stderr `{"error":{"hint":"use letters, digits, - _ .","kind":"usage","message":"HC_SESSION \"a/b\" can't be a folder name"}}`, exit 2, stdout empty. Core start failure (read-only state dir) → exit 5 `{"error":{"hint":"check the core log in the state directory","kind":"unavailable","message":"cannot start core: Permission denied (os error 13)"}}`.
On Linux hosts without a systemd user manager hc prints one **stderr** line `hc: no systemd user manager here: the core ends with whatever started it` (OBS, SRC `platform/systemd.rs:73`); it can also print `hc: turned on linger for <user>…` on stderr. **Do not treat stderr as an error channel on exit 0.**

**Auto-start (SRC `client.rs:81-96, 167-200`, OBS):** `hc connect` tries the socket; if refused it spawns `herdr-core serve` detached (own session `setsid`; on Linux with a systemd user manager as a transient user service via `systemd-run --user`), then polls the socket every 10 ms for up to 5 s ("core did not start within 5 s", kind `unavailable`). **OBS cold start to first `hello` reply: 12–13 ms** (`fixtures/rpc-env-autostart.json: cold_start_seconds 0.012`). The reply to the very first request therefore just works; there is no "core not running" state a client sees — `hc connect`, `hc server status` (OBS: `server status` also starts it) always start one. `server stop` on a session with no core returns `{"stopped":false}` without starting one (OBS).

**Env/PATH/SHELL/cwd the core captures (OBS + SRC `platform/mod.rs:48-72`, `api/run.rs:101,196-235`):**
Test = core first started by `env -i HOME=… SHELL=/bin/bash USER=node LOGNAME=node PATH=/usr/bin:/bin LANG=C.UTF-8 SSH_CONNECTION=… SSH_CLIENT=… SSH_TTY=… hc connect` (emulates an ssh exec channel; there is no sshd in the sandbox), then `terminal.run {"line":"echo PATH=$PATH SHELL=$SHELL HOME=$HOME USER=$USER LANG=$LANG; env|grep …; command -v claude codex node || echo NOT_FOUND","wait":true}`:
```
PATH=/usr/bin:/bin SHELL=/bin/bash HOME=/tmp/hc-neutral/home USER=node LANG=C.UTF-8
HC_SCOPE=…  HC_SESSION=rpc3  HC_TERMINAL_ID=t1  HC_TERMINAL_SOCKET=/tmp/hc-neutral/run/herdr-core/rpc3.sock
TERM=xterm-256color  TERM_PROGRAM=ghostty  XDG_RUNTIME_DIR=/tmp/hc-neutral/run
claude/codex/node NOT FOUND          # they live in /usr/local/bin, not on the captured PATH
```
- **Programs inherit the core's whole environment = the env of the process that FIRST started the core**, minus `SSH_CONNECTION/SSH_CLIENT/SSH_TTY` (and on Linux systemd `INVOCATION_ID`… service vars), plus `HC_SESSION`, `HC_TERMINAL_ID`, `HC_TERMINAL_SOCKET`, `HC_SCOPE`; defaults `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=ghostty` (if unset/herdr), `LANG` guessed if absent. `PAGER/GIT_PAGER/GH_PAGER=cat` only when `wait:true`.
- **A later `hc connect` with a different/richer env does NOT change it** (OBS: second connection with `PATH=/usr/local/bin:/usr/bin:/bin:/rich/path MARKER=second-connect` → program saw `PATH=/usr/bin:/bin MARKER=`). The env is frozen until the core restarts. So whichever client touches a host first decides PATH for every terminal there, including the desktop app's. [INF] A phone-triggered cold start from a non-login ssh exec channel yields a poor PATH on macOS/most Linux (sshd default `/usr/bin:/bin`), and it sticks. **Corrected over a real sshd** (`real-ssh/REAL-SSH-FACTS.md`, Surprise 3): Ubuntu 24.04's exec PATH is the full system PATH, `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin`. What every exec PATH lacks is the user's own directories (`~/.local/bin`, nvm, cargo), so the conclusion (pass a login PATH) stands.
- On Linux with a systemd user manager only the *login-session* variables (`DISPLAY`, `WAYLAND_DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`, `SSH_AUTH_SOCK`, … — SRC `systemd.rs` `SESSION`) are refreshed from the manager at each run; **PATH is still the first caller's** (SRC `systemd.rs:278` test `a_service_keeps_the_callers_paths_but_not_its_ssh_login`). macOS has no such step. **Not testable here (no user manager in the sandbox; custom XDG_RUNTIME_DIR forces the plain-spawn path).**
- Core cwd = cwd of the starting process (`--same-dir` on systemd, else inherited). `terminal.run` without `cwd` uses it (OBS: result `cwd` = the directory I launched from). Over ssh that is `$HOME`.
- `SHELL` in programs = whatever the starting env had (`SHELL=` empty under `env -i`). `terminal.run` with no argv/line starts `$SHELL` (OBS argv `["/usr/bin/bash"]`), non-login, falling back to `/bin/sh` (SRC `platform/unix.rs:159`).

**Decision for Waycar [INF from the above]:** pass what you need explicitly: (a) per run `env: {"PATH": …}` — OBS: `argv:["claude","--version"]` with `env.PATH=/usr/local/bin:/usr/bin:/bin` runs (`"2.1.311 (Claude Code)"`) while without it → `spawn_failed … No such file or directory`; lookup honours the *override* PATH; and/or (b) start the agent through a login shell: `argv:["bash","-lc","claude"]` (OBS: picks up `~/.profile` PATH; `bash -ilc` too). Plain `line` is `sh -c` **non-login** (OBS: `sh: 1: fakeclaude: not found` although `~/.profile` adds it) so nvm/`~/.local/bin` entries set in rc files are NOT seen. Best of both: resolve the user's login PATH once over SSH (`$SHELL -lc 'echo $PATH'`) or via `machine.exec {"argv":["bash","-lc","printf %s \"$PATH\""]}` and pass it as `env.PATH` on every `terminal.run`.

**stdout cleanliness:** every stdout line in all my sessions parsed as JSON (the probe `json.loads` every line). **Yes, JSON only.**

**`hc connect --session NAME` (SRC `cli.rs:504-515`):** sets `HC_SESSION=NAME` for this process then connects/starts *that session's* core (separate sockets, state, terminals). Config and templates are shared across sessions (docs/security.md:44).
**Session-name grammar (SRC `paths.rs:83-95`, OBS):** trimmed; empty → `default`; refused: `.`, `..`, control chars, any of `` / \ : * ? " < > | `` → usage error exit 2. Allowed (OBS): `UPPER`, `ok-name_1.x`, even `a b` (space inside). Not limited to the terminal-name grammar. **Max length is not a number**: the socket path `<dir>/<session>.sock` and the longest holder socket `<dir>/<session>.holder.<8 hex>.sock` must fit `sun_path` (107 on Linux, 103 on macOS, SRC `platform/unix.rs:83`). OBS: 60-char session with dir `/tmp/hc-neutral/run/herdr-core` (27 chars) → `usage … the socket path … is too long here (109 bytes; this system allows 107)`. Formula: `len(dir) + 1 + len(session) + 12 + 1 + 8 ≤ 107` → with `/run/user/1000/herdr-core` (25) max session ≈ 60. Keep sessions ≤ 16 chars [INF recommendation].
**Default socket path (SRC `platform/unix.rs:88-95`, `docs/security.md:59-81`):**
- `$XDG_RUNTIME_DIR` set: `$XDG_RUNTIME_DIR/herdr-core/<session>.sock` (OBS `/tmp/hc-neutral/run/herdr-core/rpc1.sock`, holder `rpc1.holder.2d96edca.sock` beside it).
- unset, and `/run/user/<uid>` exists (Linux with logind): `/run/user/<uid>/herdr-core/<session>.sock` (SRC "Logins without XDG_RUNTIME_DIR (some ssh setups) must still find the core").
- unset and no `/run/user/<uid>` (**macOS always; this sandbox**): `<state>/<session>.sock` where state = `$XDG_STATE_HOME/herdr-core/<session>` else `~/.local/state/herdr-core/<session>` → `~/.local/state/herdr-core/default/default.sock` (OBS in sandbox: dirs `…/home2/.local/state/herdr-core/nox/{core.json,core.lock,core.log,screens,terminals.json}`; socket is created beside them while the core runs). The session name appears twice, so macOS path budget is smaller (103). `HC_SOCKET` or config `socket =` overrides.
- Because `hc connect` resolves the path itself, **a client must not hard-code it**; run `hc connect` with the same user/HOME and it finds the right core. Do NOT export `XDG_RUNTIME_DIR` differently between the desktop app and ssh exec: an ssh session without it falls back to `/run/user/<uid>` (Linux) or the state dir; mismatches produce two cores (SRC `client.rs listening_elsewhere`).
**Installed vs not running (SRC `distribution/install.sh`, `machines.rs:206-221`):**
- Install dir `~/.local/bin` (`HC_INSTALL_DIR` overrides); binary **`herdr-core`**, and an `hc` symlink **only if no `hc` exists** (`install.sh:69-71`; some window managers ship an `hc`). So detect/launch **`herdr-core`**, never rely on `hc`. `~/.local/bin` is not on a non-interactive ssh PATH, which is why herdr-core's own client runs `sh -c 'p=$(command -v herdr-core) || p=$HOME/.local/bin/herdr-core; [ -x "$p" ] || { echo "herdr-core is not installed here" >&2; exit 127; }; HC_SESSION=… exec "$p" connect'` (SRC `machines.rs:215-217`; hc_probe.py `REMOTE_LINE`). OBS through `env -i … PATH=/usr/bin:/bin sh -c LINE`: installed only in `~/.local/bin` → works (hello OK); not installed → `herdr-core is not installed here` on stderr, **exit 127**, stdout empty. herdr-core itself maps exit 127 or that text to `hc_missing` (SRC `machines.rs:327-333`).
- "Installed but core not running" is **not a distinguishable state** for a client: a connect just starts it. If you want to know without side effects: `herdr-core --version` (OBS prints `hc 0.1.14`, never starts a core) and `herdr-core server stop` returns `stopped:false` when nothing runs (side-effect free). A core that is wedged shows as `unavailable` "core did not start within 5 s" on connect.
- Reconnect semantics: `server.restart`/`server.stop` reply `{"stopped":true}` and then **every connection hits EOF** (OBS, SRC `cli.rs:801 wait_closed`); terminals survive in holder processes (OBS: after `server.restart` the same 5 live terminals, same `core.id`, new core pid; the next `hc connect` auto-started the new core in 10 ms). Also expect EOF on `hc update`. A client must treat EOF as "reconnect, re-`hello`, re-read state".

---

## 3. Terminal records (`terminal.list`, `terminal.get`, events)

`terminal.list {"all"?,"labels"?}` → `{"terminals":[record…],"hidden_finished":N}` (+`machines` array only if machines were added). `all:false` (default) hides finished ones and counts them in `hidden_finished` (OBS `hidden_finished:15`). `labels:{k:v}` = all must match. No `children_of` filter in `list` (only in `events.subscribe`). `terminal.get {"terminal":"t7"|"name"|"machine/t7"}` → one record. Samples in `fixtures/rpc-terminal-records.json`, `fixtures/rpc-agent-input.json`, `fixtures/rpc-run-templates.json`.

**Identity: a record has NO `id` field. `address` is the id** (OBS: first thing that bit my probe: `KeyError: 'id'`). `address` = `t7`; shape (SRC `terminals.rs:166-205`) = `t` + first digit 1-9 + zero or more of `0123456789bcdfghjkmnpqrstvwxyz` (30 symbols, no vowels, no `l`), counting t1..t9, t10..t9z, t100…; OBS `t1w`, `t1x`, `t1y`. A failed spawn **burns an id** (OBS: `t1` ok, failing `claude` took `t2`, next run got `t3`). Ids are per core and **never reused** ("this terminal forever on this core"). On a core with added machines the list also contains `box/t3` (machine name prefix); there is no separate `machine` field. [INF] treat as opaque; compare with `==`; never parse numbers.
**Names** (SRC `addr.rs:6-14`, OBS): 1–32 chars of `a-z0-9-_.`, must start with a lowercase letter or digit, must not look like an id (`t7`, `t1b`; `t3po` is fine), no uppercase/space/non-ASCII. Violation → `invalid_params "bad name \"Bad Name\": use 1-32 of a-z 0-9 - _ . starting with a letter or digit, not shaped like an id (t7)"`. **Unique among live terminals** (OBS `name_taken`: `a live terminal is already named "dupname"`); a finished terminal's name is free again and resolving a name picks the live one, else the most recent finished (SRC `terminals.rs:resolve`). `name` is `null` when unnamed.
**Labels** (SRC `types.rs:27-59`, `terminals.rs:458`; OBS): JSON object string→string. Key: non-empty, no `=`. Value: any string; empty value deletes the key (`terminal.label {"labels":{"a":""}}`). **OBS: no size limit** — 300-char key + 5000-char value, non-ASCII key `ünï`, key with space all accepted. Non-string value → `invalid_params`. Label keys are returned sorted.

**Record fields** (OpenRPC `Terminal`; OBS real values; `required` in schema = `address labels argv cwd state created_ms screen cols rows`, everything else may be absent or null — see §9):
| field | type | meaning |
|---|---|---|
| `address` | string | id, above |
| `name` | string\|null | |
| `labels` | {string:string} | |
| `argv` | [string] | what actually ran: for `line`/templates it is `["sh","-c","<line>"]`, for own shell `["/usr/bin/bash"]` |
| `cwd` | string | start directory as requested (relative joined to core cwd; symlinks kept) |
| `state` | `"live"`\|`"finished"` | **use this, not `pid`**: OBS finished records keep their `pid` |
| `pid` | int\|null | program pid on the host |
| `exit_code` | int\|null | OBS exit 3 → `3`, `reason:"exited"` |
| `signal` | int\|null | OBS kill → `signal:1` (SIGHUP) `reason:"killed"`; ctrl+c'd sh → `exit_code:null,signal:2` |
| `reason` | string\|null | finished: `exited killed server_stop host_shutdown holder_lost stopped_by_restart`; live+`keep`: `signaled`, `spawn_pending`; null while running |
| `created_ms`, `finished_ms` | u64 ms since epoch / null | |
| `status` | object\|null | root OSC 7501 record `{state, kind?, progress?, app?, title?, msg?}` (below); null if never reported or after exit |
| `status_ms` | u64\|null | when the **state word** last changed (not on other field changes: OBS unchanged across `working`→`working` updates). 0.1.10+ |
| `records` | {id:Status} | other 7501 records by `id=`; omitted when empty |
| `reported` | bool | program ever sent a 7501 report |
| `turn` | u64 | +1 each time status leaves `working` (OBS idle→working→done: `turn:1`) |
| `title` | string | OSC 0/2 window title, *not* `status.title` (OBS `my title`) |
| `foreground` | {pid,name,argv,cwd}\|absent | process-group leader now + its cwd, refreshed ~2/s; absent in the run reply, present ~0.5 s later; OBS `{"argv":["sleep","30"],"cwd":"/tmp","name":"sleep","pid":2508439}` inside a shell; **omitted when null (finished)** |
| `parent` | string\|null | address of the terminal that started it (OBS `"t11"`) |
| `notify`, `die_with_parent`, `rm`, `keep` | bool | run options echoed (`keep`: 0.1.8+) |
| `template` | string\|null | template name used |
| `submit`,`stop`,`paste_gap_ms` | omitted unless a template set them | per-agent submit key / stop key / paste gap |
| `identity` | string | `"ghostty"` — TERM_PROGRAM the program sees |
| `screen` | `"exact"`\|`"inexact"` | `inexact` after a core crash |
| `cols`,`rows` | u16 | OBS `200`/`120` headless default; **changes while a viewer is attached** (OBS 100×40 under `hc attach` in a 100×40 pty; back to 200×120 on detach) |

**Status object (OBS, `fixtures/rpc-agent-input.json`, events stream):** the program's own words, replaced (not merged) on each report; absent keys mean empty.
- idle: `{"app":"fakeagent","state":"idle"}`
- working: `{"app":"zoo","msg":"step 1","progress":40,"state":"working","title":"Refactoring"}` (`msg`/`title` arrive base64 on the wire, are **decoded** in the record)
- done: `{"app":"zoo","msg":"All done","state":"done"}`
- blocked: `{"app":"zoo","kind":"permission","msg":"Allow rm -rf /tmp/x?","state":"blocked"}` (`kind` ∈ `permission question auth`)
- error: `{"app":"zoo","msg":"It broke","state":"error"}`
- sub-records: `terminal.get.records = {"sub1":{"app":"zoo","msg":"subtask","state":"working"}}`; `state=clear[:id=…]` removes.
- Core answers the program's probe `ESC ] 7501 ; ? ST` with `ESC ] 7501 ; ? : states=idle,working,done,blocked,error : kinds=permission,question,auth ST` (OBS). **[INF, from `strings` of the local `claude` 2.1.311 binary, not run]** Claude Code contains `PROGRAM_STATUS:7501`, sends that `?` probe and, if answered, emits `state=…:progress=…:title=…:msg=…` reports and `state=clear`; so a real Claude under hc probably reports status; `codex` unverified.
Plain program that never reports (OBS): `status:null,reported:false,status_ms:null,turn:0`, `foreground` present. Plain `sleep`: `terminal.wait` follows exit.
Finished sample (OBS): `{"exit_code":7,"finished_ms":1793307328328,"reason":"exited","signal":null,"state":"finished","status":null,"turn":1,"title":"my title",…}`. Retention (SRC `terminals.rs:9-10`): finished records live 24 h, max 500; `terminal.rm` removes now.
**Child terminals (OBS `fixtures/rpc-terminal-records.json`):** `terminal.run {"parent":"t11"}` sets `parent:"t11"` and (default) `die_with_parent:true`; `{"parent":…,"outlive_parent":true}` → `die_with_parent:false`. `caller` param = "HC_TERMINAL_ID of whoever calls" and **must be an address** (`caller:"par-a"` (a name) → `parent:null`; `caller:"t12"` → `parent:"t12"`; SRC `run.rs:110-120`: an explicit `parent` beats `caller`, `no_parent:true` only suppresses the caller-derived one). Launching from inside a terminal with the CLI (`hc run` in terminal t11, env `HC_TERMINAL_ID`) gave `parent:"t11"`. Killing the parent (OBS) killed children with `die_with_parent` (`reason:"killed",signal:1`) and left the `outlive_parent` one running. A phone client calling the API directly has no parent unless it passes one; **recommended: none** [INF].
`list` order = registry order, numeric id counter ascending (SRC `terminals.rs` `BTreeMap<u32,_>`; I did not assert it live), then each machine's. Events (below) carry the same record.

**Events (`events.subscribe`, plain mode) — OBS `fixtures/rpc-events-stream.json`:**
- Request `{"method":"events.subscribe","params":{"terminal"?:…,"children_of"?:…,"labels"?:{…}}}` → `{"channel":null,"seq":20,"terminals":[record…]}` — the snapshot **includes finished terminals** (16 records in my scratch core) and excludes docs. Unknown `terminal` filter → `not_found`.
- Then only notifications: `{"jsonrpc":"2.0","method":"event","params":{"data":{…},"seq":22,"terminal":"t3","type":"status"}}`; types `created lost restarted keep finished removed status turn title labels size foreground doc` (SRC schema/README.md:95-110). OBS sequence for one run: `created, status(idle), foreground, status(working…), status(+records), status(done), turn{state:"done",turn:1}, status(blocked), status(error), title, status(idle), status(null,records{}), finished{exit_code,finished_ms,reason,signal}`.
- `{"jsonrpc":"2.0","method":"heartbeat","params":{"seq":103}}` every 15 s of silence (OBS at +15 s; `HC_HEARTBEAT_MS` overrides). `missed` (fresh snapshot) if the client falls behind. `seq` restarts per core process → re-snapshot after reconnect.
- **Plain-mode trap (SRC `server.rs:222-235`, OBS):** after `events.subscribe` the connection never answers requests again (OBS: `terminal.list` on a subscribed connection → no reply in 3 s; the server just discards what you send). **Use a second `hc connect` for requests** (two ssh exec channels), or framed mode.
- `doc` events: `{"type":"doc","data":{"name":"herdr-app","version":1}}` with no `terminal` (OBS), only for unfiltered subscribers; no value → re-`doc.get`.

---

## 4. `terminal.run`

Params (OpenRPC / SRC `types.rs:184-262`); all optional but a program source:
| param | semantics (OBS) |
|---|---|
| `argv` [string] | program + args, **exec'd directly (no shell)**; `argv[0]` is first looked up as a **template name** (see below) |
| `line` string | `sh -c LINE` (non-login). Exclusive with a non-empty `argv` (`invalid_params "give argv or line, not both"`). `argv:[]` + `line` fine |
| neither | core's own shell (`$SHELL`) |
| `cwd` | **no `~` expansion**; relative joins the **core's** cwd (OBS `~`/`sub/dir` → spawn_failed). Default = core cwd |
| `name`, `labels` | §3 |
| `env` {string:string} | set on top of the core env (OBS `FOO`, `PATH`); PATH override is used to resolve `argv[0]` |
| `keep` | on loss replace with a shell (never reruns the command) |
| `parent`, `no_parent`, `outlive_parent`, `no_notify`, `die_with_parent` (ignored), `caller` | §3. Parent gets typed "notes" about the child unless `no_notify` [SRC]; irrelevant without a parent |
| `rm` | remove record right after exit (OBS: gone immediately, `get` → not_found) |
| `wait` (+`timeout`) | block until not working / exited / timeout (default 180 s, config `wait_timeout`); reply gains `wait` and `output` (screen+history, tail ≤ RUN_OUTPUT). OBS `{"wait":{"children":[],"ended":true,"exit_code":0,"reason":"exit","signal":null,"status":null,"terminal":"t1","turn":0},"output":"…"}` |
| `on` | another machine (core-to-core) — not needed |
| **no size params** | `cols/rows/size` are silently ignored (OBS: result still 200×120). Size comes from config `headless` (default 200x120) until a viewer attaches and resizes. |

Result = the record **as of start** (`status:null`, `reported:false`, no `foreground` yet) **plus** `first_message?`, `wait?`, `output?` (`RunResult`, SRC `types.rs:744`). The reply comes back as soon as the holder spawned the program (OBS 0.0 s for a plain program).
Errors (OBS `fixtures/rpc-errors.json`): unknown program, **or bad cwd** → `spawn_failed "cannot start \"pwd\": No such file or directory (os error 2)"` (**the same message names the program for both causes; "Not a directory" for a file cwd; "Permission denied" for non-exec**), hint "check the program name and cwd"; duplicate live name → `name_taken`; bad name/label/ both argv+line / negative timeout → `invalid_params`; `parent:"t999"` → `not_found`; `on:"nowhere"` → `machine_unknown`; broken template file → `invalid_template`. Every failure after id allocation burns an id.
**`machine.exec` differs:** bad cwd gives the clearer `spawn_failed "cannot start folder /nonexistent: No such file or directory"`; use it to validate a directory before `run` [INF].

**Templates (SRC `templates.rs`, `docs/templates.md`; OBS):** `templates.list` → `{"templates":[{"name","description","command","error"?}]}`; files `<config>/herdr-core/templates/<name>.md` with `---` frontmatter (`command` required; `description`, `ready: quiet`, `submit`, `stop`, `paste_gap_ms`) and a body = opening instructions; read fresh on each use. `terminal.run {"argv":["fake","Do the thing"]}` where `fake` is a template: runs `sh -c <command>` (so template commands get the same non-login PATH), then sends `body + "\n\n" + task` as the first message once the agent is ready, and returns `first_message`:
```
"first_message":{"sent":true,"started":true,"turn":0}
"first_message":{"reason":"it never reported its status, so it may be showing a dialog; check its screen (hc read t1b), then hc send t1b","sent":false}
```
- Ready = first 7501 report (default) or output quiet 800 ms (`ready: quiet`). OBS: with a reporting agent the **run reply took 1.0 s** (waits for the report, then the send); with a template whose program never reports the **reply blocked 30.0 s** (`HC_READY_MS` default 30 000) and returned `sent:false` — a mobile client needs a ≥35 s timeout for template runs, or avoid templates for agents that may not report. `first_message` only exists for template runs. Without a task string (`argv:["fake"]`) and an empty body nothing is sent (`first` empty).
- **An app can start a plain program without any template** (`argv`/`line`). A template is needed only for the built-in "deliver the first prompt when ready" behaviour. An app can *create* one at runtime through `file.write` (OBS: `file.write` created `…/config/herdr-core/templates/fake.md` incl. parent dirs; `templates.list` showed it) — needs the core's config path: `machine.exec {"line":"echo ${XDG_CONFIG_HOME:-$HOME/.config}"}`. The `command:` is a single fixed line; model/flags cannot be per-launch parameters, so a template per variant [INF]. A template named like a real program (`claude.md`) hijacks `argv:["claude"]` (SRC `run.rs:7-10`); a broken one makes it `invalid_template`.
- Other templated detail: `terminal.run` stores `submit/stop/paste_gap_ms` on the record.

**Launching `claude` interactively in a chosen directory with a first prompt, safely (what I can support with evidence; real claude not run):**
1. Resolve directory with `machine.exec` (`git rev-parse --show-toplevel`, `ls`) — absolute path, no `~`.
2. `terminal.run {"argv":["bash","-lc","claude"],"cwd":"/abs/dir","name":"…","labels":{…}}` (login shell for PATH) **or** `argv:["claude"]` with `env.PATH` from a resolved login PATH. Interactive: yes (a pty, `TERM=xterm-256color`).
3. Prompt delivery without a template: `terminal.send {"terminal":addr,"text":"…"}` can be called immediately: in the first 10 s of a terminal's life `send` first waits (≤ 5 s) for 800 ms of output silence (SRC `input.rs:settle`, OBS `terminal.send` right after `run` took 1.02 s and delivered `first prompt here`). It does **not** know about trust/permission dialogs: for an agent that reports status it refuses on `blocked` (`blocked` error, below); for one that does not, check `terminal.read`/`reported` first. Safer: wait for `status.state=="idle"` (poll `terminal.get`/events) before the first `send`; if `reported` stays false for ~N s fall back to read-then-send.
4. Template route: write a `ready: quiet` or default template whose `command` is `bash -lc claude`, then `terminal.run {"argv":["waycar-claude","prompt"],"cwd":…}` and inspect `first_message.sent`; do not blindly resend when `sent:false` (it may still have arrived — read first; SKILL.md).

---

## 5. Input: `terminal.send`, `terminal.keys`, `terminal.interrupt`

**`terminal.send {"terminal","text","force"?,"if"?:"idle"|"working","wait"?,"timeout"?}`** (SRC `input.rs:117-215`, OBS `fixtures/rpc-agent-input.json`, `fixtures/rpc-input-misc.json`):
- Types `text` as a **paste, then Enter**: bracketed paste (`ESC[200~ … ESC[201~`) only if the program enabled mode 2004, else the raw text; 200 ms gap (`PASTE_GAP`; template `paste_gap_ms` overrides); then `\r` (template `submit` overrides). OBS bytes (python reader): 2004 on → `b'\x1b[200~line one\nline two\x1b[201~'` then `b'\r'`; 2004 off → `b'line one\nline two'` then `b'\r'` (embedded newlines go in raw, i.e. may submit early in programs without bracketed paste); `ESC[201~` inside the text is stripped (`a\x1b[201~b` → `ab`); UTF-8 and emoji pass through.
- Result `{"status":"idle"|…|null,"turn":N,"started":true|false|null,"wait"?}`: `status`/`turn` as they were when the text went in; `started` = whether the program went `working` (or a turn ended) within 5 s; **`null` for programs that never reported** (no way to know). **`started:false` after a 5.2 s wait is not a failure** (OBS: prompt that made my fake go `blocked` → `started:false`, status then `blocked`). Latency: 0.2 s (paste+gap) + up to 5 s `started` window (OBS 0.21 s when it started working; 5.2 s when not).
- `if:"idle"|"working"`: types only if status equals it, else `status_mismatch` (`"t2 is idle, not working"`, hint "nothing was typed", OBS); other words → `invalid_params unknown variant `blocked`, expected `idle` or `working``.
- **blocked refusal:** status `blocked` and not `force` → `{"kind":"blocked","message":"t2 is blocked (permission)","hint":"typing would answer its dialog; read its screen first (hc read t2), or --force"}`; `force:true` types anyway (OBS `started:true,status:"blocked"`). Silent/idle/working/error/done are accepted (error: no refusal).
- `wait:true` (+`timeout`, default 180): after the paste, waits for that send's turn; result gains `wait` = `{"children":[],"ended":true,"exit_code":null,"reason":"status","signal":null,"status":"done","terminal":"t2","turn":5}`. `reason` ∈ `status exit output timeout not_started message children`. **`not_started` (OBS):** reporting agent that stays `idle` → `{"started":false,…,"wait":{"ended":false,"reason":"not_started","status":"idle",…}}` after 5.2 s. `ended:false` + `timeout` = check-in; the terminal is still running.
- **The "~3 s quiet rule" is about a human typing, not about agent output** (SRC `input.rs:65-67` `HC_QUIET_MS` 3000). OBS with `hc attach bp` in a pty: I typed `x`; a `terminal.send` issued 0.2 s later was held **3.0 s** and then delivered; the `terminal.keys` issued right after (≈3.2 s after the human keystroke) returned in 0.03 s; `terminal.interrupt` never waits (quiet=0; its 0.5 s was its own watch timeout). Input from all agents/API calls is queued per terminal so sends never interleave; while an agent's input is going in, a *human's* keystrokes are **held** and replayed afterwards (SRC `Gate::human`, `set_busy`; not exercised live). With no other viewer attached (phone is the only client) there is no delay. [INF] a phone UI that attaches (framed) *and* sends via API will self-delay 3 s after its own typing.
- Other refusals: finished → `finished "t5 has finished"` (hint `hc read t5`); lost kept terminal → `unavailable "… is lost, waiting for its new shell"`; **first 10 s after creation** → may wait ≤5 s for output to settle, else `unavailable "… is still starting: its output has not settled"` with "nothing was typed" (SRC `input.rs settle`).
- Gotcha: `send` always appends Enter. There is **no API to insert text without submitting** except `terminal.keys` one key at a time or framed attach DATA.

**`terminal.keys {"terminal","keys":[…]}`** → `{"status":…,"turn":N}` (SRC `keys.rs:8-64`, OBS fixtures `fixtures/rpc-keys-matrix.json` = every name sent to a raw reader, bytes in repr). Keys are encoded **for the program's current modes** (application cursor keys, kitty keyboard) by libghostty; 30 ms between keys. **Validation is all-or-nothing:** `["x","nope","y"]` → `invalid_params unknown key "nope" (try enter, esc, up, ctrl+c, alt+x, f5, a)` and **nothing was typed** (OBS). Not refused for `blocked` (keys are how you answer a dialog). Names are case-insensitive (`ENTER`, `Ctrl+C` OK; but `A` → `a`; use `shift+a` for `A`).
Accepted names (SRC `key_code`):
- letters `a-z`, digits `0-9`; punctuation **only** these literal chars: `` ` `` `\` `[` `]` `,` `=` `-` `.` `'` `;` `/`; named: `backslash`, `space`, `enter`/`return`, `tab`, `backspace`, `esc`/`escape`, `delete`/`del`, `insert`, `home`, `end`, `pageup`/`pgup`, `pagedown`/`pgdn`, `up` `down` `left` `right`, `f1`…`f12`.
- modifiers joined with `+` (any order): `shift`, `ctrl`/`control`, `alt`/`meta`/`opt`, `super`/`cmd` — e.g. `ctrl+c`, `alt+x`, `shift+tab`, `ctrl+alt+delete`.
OBS bytes: enter `\r`; esc `\x1b`; tab `\t`; shift+tab `\x1b[Z`; backspace `\x7f`; delete `\x1b[3~`; up/down/right/left `\x1b[A/B/C/D`; home `\x1b[H`; end `\x1b[F`; pageup `\x1b[5~`; pagedown `\x1b[6~`; insert `\x1b[2~`; ctrl+c `\x03`; ctrl+d `\x04`; ctrl+l `\x0c`; ctrl+z `\x1a`; ctrl+j `\n`; ctrl+] `\x1d`; ctrl+space `\x00`; alt+x `\x1bx`; alt+enter `\x1b\r`; f1 `\x1bOP`; f5 `\x1b[15~`; f12 `\x1b[24~`; shift+up `\x1b[1;2A`; ctrl+left `\x1b[1;5D`; shift+enter `\x1b[27;2;13~`; single chars as themselves.
Errors (OBS, all `invalid_params unknown key "<k>" …`): `f13`, `f0`, `+`, `!@#$%^&*()_{}|:"<>?~`, non-ASCII (`é`), `""`, `hello`, `hyper+x`, `ctrl+`, `ctrl++`, `ctrl+[`, `ctrl+@`, `tab+tab`, `ctrl+i`, `ctrl+m` (use `tab`/`enter`), `ctrl+shift+a`, `C-c`, `ctrl-c`, and herdr-TUI word names `minus plus quote comma colon percent backtick semicolon period slash double_quote ampersand`. Silently odd: `shift+1` → `1` (not `!`), `ctrl+1` → `1`, `alt+shift+x` → `ESC x`, `super+k` → `k`.

**Waycar toolbar vs `terminal.keys`** (`HerdrKeyNames.swift`, the maintainers' notes; table is for the herdr TUI `pane.send_keys`):
| toolbar key | herdr-TUI spelling today | `terminal.keys` |
|---|---|---|
| Esc / Tab / ⇧Tab | `esc` `tab` `shift+tab` | same strings ✓ |
| ⇧Enter (sent as Ctrl-J) | `ctrl+j` | `ctrl+j` ✓ (`\n`) — `shift+enter` would send `\x1b[27;2;13~` |
| arrows, Enter, Backspace | `left up down right enter backspace` | same ✓ |
| **Home End Insert ForwardDelete PgUp PgDn** | *not expressible* | **all expressible**: `home end insert delete pageup pagedown` ✓ |
| F1–F12 | `f1`…`f12` | same ✓ (F13+ not accepted; toolbar has only F1–F12) |
| characters a-z 0-9 | the char | same ✓ |
| space | `space` | `space` ✓ |
| `-` `,` `.` `/` `'` `;` `` ` `` `\` | `minus comma period slash quote semicolon backtick backslash` | **literal char** (`-` `,` `.` `/` `'` `;` `` ` `` `\`) or `backslash`; the **herdr names are rejected** except `backslash` — table must be re-mapped |
| `+` `"` `:` `%` `&` | `plus double_quote colon percent ampersand` | **cannot be expressed** (`+`, `"`, `:`, `%`, `&` all `unknown key`) |
| any other shifted symbol `! @ # $ ^ * ( ) _ { } | < > ? ~`, uppercase, non-ASCII/emoji, `[`/`]` fine but `ctrl+[` no | n/a in table | **cannot be expressed**; there is no raw-text-without-Enter call in plain mode → these must go through `terminal.send` (adds Enter) or framed-attach DATA (other agent's area) |
| modifier chords ctrl/alt+letter | `ctrl+c` etc. | same ✓ (`alt+x`→`ESC x`); `ctrl+i`, `ctrl+m` rejected (use tab/enter) |

**`terminal.interrupt {"terminal","timeout"?=10}`** → `{"key":"esc"|"ctrl+c","outcome":"stopped"|"exited"|"still_working"|"unknown"}` (SRC `input.rs:241-290`). Sends `esc` if the program ever reported status (template `stop` overrides), else `ctrl+c`; then watches: reporting program → `stopped` when not working / `exited`; non-reporting → `stopped` if a shell got the terminal back, `exited`, else `unknown` after the timeout. OBS: `{"key":"esc","outcome":"stopped"}` on the fake agent; `{"key":"ctrl+c","outcome":"exited"}` on `sleep` under `sh -c` (record then `exit_code:null,signal:2`); `unknown` for a raw reader that ignores ctrl+c. Finished → `finished`.

---

## 6. `terminal.read`, `kill`, `rm`, `keep`, `label`, `wait`, `put`

**`terminal.read {"terminal","lines"?=0}`** → `{"text","complete","how":"screen"|"history"|"stitched","why"?}` (SRC `types.rs:325-349`). No separate screen/history switch: `lines` = scrollback lines **above** the screen; `0` = visible screen only. Text is plain (no escapes), lines `\n`-joined, trailing blank screen rows trimmed. OBS (300-line output, 200×120 headless screen): `lines:0` → 120 lines (`line 181…line 300`, `how:"screen"`); `lines:5` → 125; `150` → 270; `1000` → all 300 (`how:"history"`, `complete:true`). Request more than exists = fine. **Screen height is the terminal's 120 rows, not the phone's** unless attached.
- Alt-screen program (`ESC[?1049h` + two lines): `lines:0` → `{"complete":true,"how":"screen","text":"ALT SCREEN LINE 1\nline 2"}`; `lines:50` → `complete:false` (history of a full-screen app belongs to the app). `how:"stitched"` (core scrolls a full-screen app to read it) and `why:"working"` not exercised (needs a real TUI).
- Finished terminal: still readable (`how:"history"`, text intact, OBS) until `rm`/retention.
- `terminal.read` counts as "seen" for a parent; no other side effects.

**`terminal.kill {"terminal"}`** → the (finished) record: `state:"finished",reason:"killed",signal:1` (SIGHUP), idempotent (second kill returns the same record, OBS). **`terminal.rm`** → `{"removed":"t8"}`; on a live terminal → `live "t8 is still running"` (hint "kill it first"); again → `not_found`. **`terminal.keep {"terminal","keep":bool}`** → record with `keep` set (OBS true/false toggles; recovery behaviour not exercised). **`terminal.label {"terminal","labels":{k:v}}`** → full record; `key=""` removes; bad key `x=y` → `invalid_params "bad label key"`.
**`terminal.wait {"terminal","output"?,"timeout"?=180,"children"?,…}`** → `WaitResult`; OBS `{"ended":true,"reason":"output",…}` when the text appeared **after the wait started**, `{"ended":false,"reason":"timeout"}` after the timeout (still running). Blocks the connection.
**`terminal.put {"terminal","name","data":base64}`** → `{"path":"/…/state/herdr-core/<session>/files/<t>/<name>","bytes":N}` (SRC `put.rs`, OBS `fixtures/rpc-put.json`): lands in the **state dir of that terminal** (`$XDG_STATE_HOME/herdr-core/<session>/files/<address>/`), removed with the terminal record, file mode 0644 in a 0700 state dir. Name is reduced to a safe basename (`../../etc/pa ss wd.PNG` → `pa_ss_wd.PNG`: `[A-Za-z0-9._-]` only, leading dots stripped, `file` if empty; non-ASCII → `_`); duplicates become `shot-2.png`. **It does not type anything into the terminal** — follow with `terminal.send` of the returned `path` (as the agent expects, e.g. `@path`). Limit **8 MiB raw** (8 388 608 B OK in 0.16 s; +1 → `invalid_params "at most 8 MB per put"`); one message, so ≈11 MB line. **Base64 must be plain standard alphabet without newlines/URL-safe chars** (`data is not base64` for a wrapped or `-_` encoding; padding optional; empty data OK). Finished terminal → `finished "… has finished"`, hint "nothing there to read it".

---

## 7. `machine.exec`, `file.*`, and "is there a workspace/tab/worktree/dir API?"

**No.** The 32-method OpenRPC set has no workspace, tab, pane, worktree, git, or directory-listing method (list in §1; AGENTS.md "Core is a runtime, not a multiplexer"). Spaces/tabs only exist as an opaque document written by the desktop app (§8). Directory browsing/git must use `machine.exec` (or SSH exec).
**`machine.exec`** (0.1.6+; SRC `exec.rs`, OBS `fixtures/rpc-exec-files.json`): `{"argv":[…]|"line":"…","cwd"?,"env"?{},"input"?base64,"timeout"?}` → `{"code":int|null,"signal":int|null,"stdout":b64,"stderr":b64,"truncated":bool,"timed_out":bool,"ms":int}`. No pty (`[ -t 0 ]`/`-t 1` both false, OBS), stdin closed unless `input`, runs with the core env + `env` (so PATH is the core's — pass `env.PATH` or use `line` with `bash -lc`). **stdout and stderr are base64**. Limits: timeout default 60 s, **(0, 600]** else `invalid_params "timeout must be more than 0 and at most 600 s"`; stdout first **8 MiB**, stderr **1 MiB**, `truncated:true` (OBS 9 MB out + 2 MB err → 8 388 608 / 1 048 576 bytes, `truncated:true`, still `code:0`); timeout kills the process group: `{"code":null,"signal":15,"timed_out":true,"ms":1004}`; killed by signal → `{"code":null,"signal":9}`; non-zero exit is **not** an error (`code:128` + stderr). Errors: bad cwd/program → `spawn_failed "cannot start folder /nonexistent: …"` / `cannot start no-such-prog: …` (hint `""`); neither/both argv & line → `invalid_params "give either argv or line"`. Plain-mode caveat: it runs on the connection serially, and **if the client closes the connection the exec is killed** (SRC `server.rs:closed`; framed mode supports `$/cancelRequest`).
**Can it replace SSH exec for a directory browser? [INF, supported by OBS]** Yes, within the plain-mode serial constraint: OBS `git rev-parse --show-toplevel` (cwd inside a repo) → `/tmp/hc-neutral/repo1\n`; outside → `code:128`; `ls -1pA` → `.git/\na.txt\nsub/\n`; `git worktree add -b feat1 <path>` → `code:0`, stderr `Preparing worktree (new branch 'feat1')`; `git worktree list --porcelain` via `line`. 2–10 ms each. Cost = base64 + one connection; benefit = reuses the already-open `hc connect` channel and the core's env. `~` is not expanded: `file.read {"path":"~/.profile"}` → `not_found "no file <core-cwd>/~/.profile"`; get `$HOME` with `machine.exec {"line":"printf %s \"$HOME\""}`.
**`file.read {"path","cwd"?,"offset"?,"limit"?}`** (0.1.10+) → `{"text","first","last","lines"}` (lines 1-based, line endings kept; default whole file up to 8 MiB; binary → `not_text`); directory/socket → `invalid_params "<path> is not a regular file"` (no listing); missing → `not_found` (hint "check the path, or hc exec ls"). **`file.write {"path","data":b64}`** → `{"path","bytes"}` replaces the file, **creates parent dirs** (OBS `new/deep/x.txt`), 8 MiB. **`file.edit {"path","edits":[{old,new}…]}`** all-or-nothing, `old` must occur exactly once: `edit_failed "the old text is not in the file"` / `"…is in the file 2 times"`. Errors `needs_update` when the target machine is old (n/a locally).

---

## 8. `doc.get` / `doc.set` and the `herdr-app` document

**API (SRC `schema/README.md:149-182`, `api/doc.rs`; OBS `fixtures/rpc-doc.json`):** `doc.get {"name","on"?}` → `{"value":<any json>|null,"version":N}`; never-written name → `{"value":null,"version":0}`. `doc.set {"name","value","version","on"?}` → `{"version":N+1}` only if `version` equals the current; stale/future → `conflict "document \"herdr-app\" is at version 1, not 0"`, hint "read doc.get and retry with its version" (OBS for 0 and 99). `value:null` deletes but keeps the version (OBS `scratch1` → version 1, value null). Name = terminal-name grammar (`Bad Name` → `invalid_params`). **1 MiB limit** of serialized JSON (`invalid_params "document exceeds 1 MiB of JSON"`, OBS). Persisted in `docs.json` in core state, survive restart. Change notifications: `doc` events without a value (OBS). Cross-machine: `on:"<machine>"`.
**`herdr-app` document (SRC `herdr-app/src/mirror.rs:9-33`, `mirror_sync.rs:74-104`, `layout.rs`):** the desktop app reads/writes document **name `"herdr-app"` on each core** with compare-and-set (`doc.get` on connect, `doc.set` with the last seen version, on `conflict` re-read + merge; `mirror_sync.rs round_timeout`). Shape (`Document` = `{"spaces":[SharedSpace]}`, all fields `#[serde(default)]`):
```
{"spaces":[{ "id":"s<32hex>", "name":"waycar", "folder":"/home/u/src/waycar",
   "tabs":[{ "id":"tab01", "name":"main",
             "root":{ "id":"tab01","type":"row","children":[
                {"id":"p1","type":"block","content":{"terminal":"t1"},"size":{"weight":2.0}},
                {"id":"col1","type":"column","children":[
                    {"id":"p2","type":"block","content":{"terminal":"t2"}},
                    {"id":"p3","type":"block","content":{"terminal":"t3"}}]}]}}]}]}
```
- Space = `{id,name ("" = auto-named after its first terminal),folder (cwd for new terminals),tabs}`; Tab = `{id,name,root}`; `root` = layout `Node`: `{"id","type":"row|column|stack|block", "children"?, "content"?, "size"?{px|weight}, …look fields…}`. A pane is a `block` whose `content` is `{"terminal":"<local address>"}` (also `{"mod":…,"props":…}`, `{"tab":"active"|…,"pane":…}`, `{"agent":"focused"|…}`); `stack` has `active`; nodes may carry `floating` blocks, titles, colors, etc. Terminal ids are **core-local** (`t1`); the app prefixes `machine/` only in its in-memory model (`mirror.rs qualify/local`). Tab `root.id` equals the tab id; fresh ids = `prefix + 32 hex`. Per-screen view state (focus, zoom, active tab) is **not** in the document (`View` is private).
- **Versioned/stable? No.** The `version` is only the doc.set CAS counter. The JSON has **no schema version field**, is owned by the app (not core: core "never interprets their contents"), and its types carry app-internal look/mod fields. herdr-app `AGENTS.md`: "Preserve compatibility with released versions and installed user data. Discuss breaking changes … with the maintainer"; `README` "the app's core (the model, **machine layout documents**, commands…) stays small". So it is a de-facto contract with compatibility intent but **no published spec**.
- **Could Waycar read it to show the user's Herdr app spaces/tabs? [INF]** Technically yes: `doc.get {"name":"herdr-app"}` returns `{spaces:[{name,folder,tabs:[{name,root…}]}]}`; walk `root` collecting `content.terminal` leaves → addresses → join with `terminal.list`. Risks: (1) format owned by app, unversioned, may change without core's compat tests (those only check the OpenRPC schema; `doc` values are opaque); (2) `Content`/`Kind` are untagged/tagged serde enums that gain variants (mods/agent/context) — decode tolerantly, ignore unknown nodes; (3) **read-only**: a write with a stale or invalid doc would reshape the user's desktop layout and can race the app's own CAS flush; never `doc.set` `herdr-app`; (4) only exists if the Herdr app ever ran against that core (otherwise `{"value":null,"version":0}`); (5) names `""` for auto-named spaces, `folder` may be `""`; (6) terminals listed may be finished/removed (dangling ids); (7) shared layout carries *no* focus/active-tab info; (8) `folder` is the app's notion, not the terminal's cwd. If Waycar wants its own spaces it should use its **own doc name** (e.g. `waycar`, same CAS rules) rather than touching `herdr-app`.
- Hand-made sample: `fixtures/rpc-doc-herdr-app-HANDMADE.json` (HAND-MADE from the Rust types, *not* captured from the app; the `doc.get` exchange in it is real against a scratch core).

---

## 9. Compatibility policy and tolerant decoding

SRC `schema/README.md:12-19`, `tests/compat.rs`: "The API only grows." `schema/released.openrpc.json` = API as last released (OBS: equals current `hc.openrpc.json` at 0.1.14, and `rpc.discover` returns the same document byte-for-value). A test fails on: removed method/param/result field; a new **required** input; an input that accepts less; an answer that **can carry a new kind of value** or loses its type (schema shape compare, depth ≤ 8). A real break requires a new protocol `generation` "decided on purpose" (`hello.generation`, now 1; `hello {"generation":2}` → `unsupported_generation`, hint "this core speaks generation 1"). Status: "preview (protocol generation 1, version 0.x)".
**What the guard does not cover (so a client must tolerate):**
- **New fields appear in objects** (this happened: `keep` 0.1.8, `status_ms` 0.1.10, `why`, `first_message`…). A decoder with `deny_unknown_fields`/strict Codable keys breaks. Swift `Codable` ignores unknown keys by default — keep it that way; no `.convertFromSnakeCase` surprises with `ms` suffixes.
- **Open vocabularies are strings, not enums:** `status.state` (idle working done blocked error today, "stored as reported"), `status.kind`, `wait.reason`, `terminal.reason`, `how`, `outcome`, `data.kind`, event `type`. Decode as `String`; unknown → neutral.
- Behaviour/defaults are not covered (e.g. `die_with_parent` is now ignored; `outlive_parent` appeared in 0.1.13; `terminal.run` template wait is 30 s).
- Optional/nullable (OpenRPC + OBS): **absent when empty**: `Terminal.foreground`, `.records`, `.submit`, `.stop`, `.paste_gap_ms`; `Status.app/title/msg` (absent = ""), `Status.kind`, `.progress`; `ReadResult.why`; `RunResult.first_message/wait/output`; `SendResult.wait`; `FirstMessage.started/reason/turn`; `WaitResult.from`. **Present but null:** `Terminal.name pid exit_code signal reason finished_ms status status_ms parent template`; `SendResult.status`, `.started`; `KeysResult.status`; `WaitResult.exit_code signal status`; `ExecResult.code signal`; `StatusResult.holder installed_by`; `SubscribeResult.channel` (plain). Schema-"required" Terminal fields: `address labels argv cwd state created_ms screen cols rows` only; treat all others (incl. `keep`, `turn`, `reported`, `title`, `notify`, `identity`) as optional with defaults.
- Numbers: ms timestamps are u64 (1.79e12, exceed 32-bit; use Int64/Double); `turn` u64; `seq` u64.

---

## Gotchas for the Swift engineer
1. A terminal record has **no `id`**; `address` (`t7`, `t1b`, `box/t3`) is the id — opaque, never reused, burned by failed spawns.
2. Plain mode is **strictly serial**: replies in order; `terminal.wait`, `send wait`, `run wait`, `machine.exec`, and template runs (up to 30 s!) block every later request on that connection. Use separate connections for slow calls.
3. After `events.subscribe` the plain connection **ignores all further requests** (silently). Events need their own `hc connect`; reconnect ⇒ new snapshot (`seq` restarts), the snapshot includes finished terminals.
4. The core's env is frozen at **first start** (PATH of whoever started it, SSH_* stripped); later connects can't fix it. `argv:["claude"]` under a bare ssh PATH → `spawn_failed`. Pass `env.PATH` per run or use `argv:["bash","-lc",…]`; `line` is `sh -c` non-login.
5. `~` is never expanded (cwd, file paths); relative `cwd` is relative to the **core's** cwd. `spawn_failed` for a bad cwd names the *program* — validate dirs with `machine.exec`.
6. `terminal.run` takes **no size**; terminals are 200×120 until a viewer attaches (then they take the viewer's size, and snap back on detach). `terminal.read lines:0` returns up to 120 rows.
7. `terminal.send` always appends Enter, is held 3 s after a *human* keystroke on an attached viewer, waits ≤5 s for a freshly started terminal to settle, refuses `blocked` (use `force` deliberately), and `started:false`/`null` are not errors (null = program doesn't report).
8. `terminal.keys` is all-or-nothing validation and cannot type `+ " : % & ! @ # …`, uppercase, or non-ASCII; the herdr-TUI spellings (`minus`, `period`, `double_quote`, …) are **rejected**; Home/End/Insert/Delete/PgUp/PgDn **are** supported now.
9. `state` (`live`/`finished`) is the liveness truth; `pid` stays set after exit; `status` is `null` until the first 7501 report and again after exit; `status.title/msg/app` are absent when empty; `status_ms` only moves when the state word changes.
10. `data.kind` is the error discriminator; `code` is -32000 for nearly everything. `hint` can be `""`. Unknown kinds must be survivable.
11. `server.stop/restart`/`hc update` ⇒ **EOF on every connection** (reply `{"stopped":true}` arrives first). Reconnect = new `hc connect` (auto-starts), `hello`, re-list; terminals survive.
12. `hc connect` has no "core not running" error: it auto-starts (12 ms). "Not installed" = shell exit 127 + stderr `herdr-core is not installed here`; use the binary name `herdr-core` (an `hc` may be someone else's) and herdr-core's own `command -v … || $HOME/.local/bin/…` line; stderr noise on exit 0 (`no systemd user manager`, `linger`) is not an error.
13. `machine.exec`/`terminal.put`/`file.*` payloads are **base64 (standard alphabet, no newlines)**, ≤ 8 MiB raw (stdout 8 MiB/stderr 1 MiB truncated silently with `truncated:true`); a closed plain connection kills a running exec.
14. `doc.set` needs the exact current `version` (0 for new); never write `herdr-app` (app-owned, unversioned, CAS-raced); use your own doc name.
15. Templates: `first_message` exists only for template runs; `argv[0]` is always tried as a template name first (a `claude.md` template hijacks `claude`); template `command` runs via non-login `sh -c`.

## Not verified
- Real `claude` / `codex` / other agents under hc (paid; not run). Whether they report OSC 7501 is **[INF]** from `strings` of the local `claude` 2.1.311 binary only; codex wrapper has no match (native binary not inspected).
- Linux autostart through a **systemd user manager** (`systemd-run --user`, linger, manager env refresh): sandbox has no manager; custom `XDG_RUNTIME_DIR` forces the plain spawn path. macOS behaviour (state-dir socket path, no manager, `foreground` via macOS code) is SRC only. Windows untouched.
- A genuine **sshd/ssh exec channel** (no sshd available): emulated with `env -i … sh -c LINE` pipes and a minimal ssh-like env; real sshd PATH/SHELL/locale may differ.
- Framed mode, `terminal.attach` byte semantics (other agent); held-keystroke replay *during* an agent send (SRC only; the 3 s rule itself was verified with `hc attach` in a pty).
- `terminal.keep` loss recovery, `stitched` reads / `why:"working"` against a real TUI, `terminal.wait` with `children`, parent "notes" typed into a parent, `machine.*` (core-to-core) methods, `templates` `submit`/`stop` overrides, `ready: quiet` with a slow-starting agent.
- Exact label/name persistence limits beyond the sizes I sent (5000-char values); `hc update` behaviour; 24 h/500 retention (SRC only).
- Behaviour differences between 0.1.0–0.1.13 beyond field shapes and method sets (smoke-tested the same 8 calls only).
- The `herdr-app` document was never produced by the real desktop app here; the sample is hand-made from source types.
