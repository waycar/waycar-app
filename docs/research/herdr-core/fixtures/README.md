# Fixtures for `rpc-facts.md`

Real captures of herdr-core 0.1.14 over `hc connect` (plain mode, JSON-RPC 2.0, one line per message, no pty), taken in an isolated
scratch lab (scratch HOME/XDG dirs under `/tmp/hc-neutral`, working directory `/tmp/hc-neutral/proj`, own `HC_SESSION` per scenario).
Agents are `sh` scripts that print OSC 7501 status sequences; no paid agent was run. Wire strings are exact stdout lines.
Only `rpc-doc-herdr-app-HANDMADE.json` contains hand-made data (its `document`); the `doc.get` exchange inside it is real.

Shapes: `exchanges` is either a list of `{note, sent, received[]}` (raw request line, raw reply lines) or an object
`{name: [{request, reply_raw}]}`. Large request bodies (8 MiB base64, 1 MiB doc value) are replaced by an `<elided: …>` marker; replies are real.

| file | what it shows | used by `rpc-facts.md` § |
|---|---|---|
| `rpc-hello.json` | `hello`: all result fields, `generation` mismatch error, wrong-typed and unknown params | 1 |
| `rpc-discover-info.json` | `rpc.discover` summary: OpenRPC version, `info`, method names | 1 |
| `rpc-version-matrix.json` | `hello.methods`/`features` of every release 0.1.0–0.1.13 (downloaded, sha256-verified) → when each method appeared | 1 |
| `rpc-errors.json` | one request/reply per error kind (parse_error, invalid_request, unknown_method, invalid_params, not_found, name_taken, spawn_failed, live, finished, conflict, edit_failed, machine_unknown, unsupported_generation) | 1, 4 |
| `rpc-env-autostart.json` | cold start time, what env/PATH programs inherit from an ssh-like first connect, second connect ignored, PATH override and login-shell workarounds | 2 |
| `rpc-run-templates.json` | `templates.list`, `terminal.run` via template (`first_message`), quiet template, never-reporting template (30 s), plain agent + immediate `send`, status "zoo" run, finished record | 3, 4 |
| `rpc-terminal-records.json` | plain program record, own shell + `foreground`, finished record, `parent`/`caller` child terminals, `terminal.list` (live, `all`, by label) | 3 |
| `rpc-agent-input.json` | fake agent through idle/working/done/blocked/error: `send`, `send wait`, `if` mismatch, blocked refusal, `force`, `keys`, `interrupt`, status objects | 3, 5 |
| `rpc-input-misc.json` | `send` bracketed-paste vs raw, ESC stripping, UTF-8, `keys` multi/partial error, `interrupt`, finished/not_found errors, `not_started` wait | 5 |
| `rpc-keys-matrix.json` | every key name tried through `terminal.keys` → bytes the program read, or the error | 5 |
| `rpc-read.json` | `terminal.read` with different `lines`, alt-screen program, finished terminal, agent screen | 6 |
| `rpc-wait-label-keep-kill.json` | `terminal.wait` (output / timeout), `label`, `keep`, `rm`, `kill`, label filter | 6 |
| `rpc-put.json` | `terminal.put`: landing path, name sanitising, duplicates, base64 strictness, 8 MiB limit, finished terminal | 6 |
| `rpc-exec-files.json` | `machine.exec` (git, ls, worktree, limits, timeout, signals), `file.read/write/edit`, writing a template via `file.write` | 4, 7 |
| `rpc-doc.json` | `doc.get`/`doc.set`: versions, conflicts, null delete, name rule, 1 MiB limit | 8 |
| `rpc-doc-herdr-app-HANDMADE.json` | **hand-made** `herdr-app` layout document (spaces → tabs → layout tree → terminal ids) from the app's Rust types, plus a real `doc.get` of it | 8 |
| `rpc-events-stream.json` | plain-mode `events.subscribe` snapshot, event notifications for one run, a `doc` event, heartbeat | 3 (events) |
