# Fixtures for `attach-facts.md`

Real captures of herdr-core 0.1.14 from `hc_attach_probe.py` (spawns `hc connect --session NAME` over plain pipes = SSH exec without pty, `hello {framed:true}`, then framed mode). Taken in an isolated scratch lab (own HOME/XDG dirs and `HC_SESSION`, clean `env -i` environment, working directory `/tmp/hcna/proj`). Agents are `sh` scripts (OSC 7501 status, byte-echo programs); `top` is the only real program. No paid agent was run.
They are a clean re-run of the scenarios `attach-facts.md` was written from: pids, timestamps, `created_ms`, event `seq` values and terminal addresses differ from the numbers quoted in the md; the shapes, sizes and byte sequences are the same.

Formats: `*.bin` = byte-exact core→client stream after the plain-mode hello reply line (frames `[channel u32 LE][kind u8][len u32 LE][payload]`); `*.out.bin` = byte-exact client→core stream including the plain hello line; `*.json` = decoded frames (`dir` in/out, `t` seconds, `ch`, `kind`, `len`, `payload_b64`, plus `json`/`lines`/`reason` where decodable) and the hello reply. `attach-nocredit-flood` and `attach-events-missed` are trimmed (their `note` says how).

| fixture | what it shows | section of `attach-facts.md` |
|---|---|---|
| `attach-wire-minimal.{bin,out.bin,json,txt}` | whole session byte by byte: hello line, `terminal.attach`, CREDIT, typed DATA, RESIZE, CLOSE both ways; `.txt` = annotated header decode | 1 |
| `attach-alt-firstpaint.*` | first paint of an alt-screen program (`ESC[?1049h`, tab stops, `?9001l`) | 1 |
| `attach-plain-history3.*` | first paint of a main-screen program, `history: 3` | 1 |
| `attach-scroll-history50.*` | first paint with 50 history lines + 27 screen rows | 1 |
| `attach-agent-status-title.*` | first paint carrying OSC 2 title and the OSC 7501 status record | 1 |
| `attach-agent-live-status.*` | live OSC 7501 / title bytes inside the stream | 1 |
| `attach-win32-firstpaint.*` | `?2004h` and trailing `ESC[?9001h` in the first paint | 1, 2 |
| `attach-queries-nofacts.*`, `attach-queries-facts.*` | the core answers OSC 10/11/12, CSI 16t/18t/c/6n itself; effect of a FACTS frame | 1 |
| `attach-top-resize.*` | `top` (real full-screen app): reflowed first paint then redraw; RESIZE frame | 1 |
| `attach-nocredit-flood.*` | no CREDIT: 256 KiB then silence; CREDIT → full repaint (trimmed) | 1 |
| `attach-close-exited.*`, `attach-close-killed.*` | CLOSE reason JSON (`exited` exit 3, `killed` signal 1); attach after finish → `finished` error | 1 |
| `attach-kept-lost.*` | kept terminal, `kill -9`: CLOSE `signaled`, attach → `unavailable`, re-attach after restart | 1, 6 |
| `attach-multichannel.*` | three attaches on one connection (channels 1-3) | 1 |
| `attach-observe.*` | `observe` attach: DATA and RESIZE ignored | 1 |
| `attach-size-desktop.*`, `attach-size-phone.*` | two viewers (120x40, 52x28) on one terminal; program prints `SIZE rows cols` on SIGWINCH | 1 |
| `attach-keys-bytes.*` | Enter, Esc, arrows (normal and application), bracketed paste, Backspace as DATA → bytes the program read | 2 |
| `attach-signals-via-data.*` | DATA `03`, `1c`, `1a` → SIGINT, SIGQUIT, SIGTSTP | 2 |
| `attach-focus.*` | FOCUS 1/0 frames → `ESC[I` / `ESC[O` when the program enabled `?1004` | 2 |
| `attach-events-framed.*` | framed `events.subscribe` through created, title, status, foreground, turn, size, labels, keep, lost, restarted, finished, removed; heartbeats at 15.0 s and 30.0 s | 4, 6 |
| `attach-events-plain.txt` | plain-mode `events.subscribe` lines with timestamps; labels, finished, removed, heartbeat at 15.0 s | 4 |
| `attach-events-doc.*` | a `doc` event (no `terminal`, no value) | 4 |
| `attach-events-label-filter.*` | label-filtered subscription: `labels` event with `record` on entering, without on leaving | 4 |
| `attach-events-missed.*` | slow subscriber: `missed` + snapshot, `seq` resumes (trimmed) | 4 |
| `attach-core-restart.*` | attach + events on one connection across `hc server restart`: stream ends with EOF, no CLOSE frame | 4, 6 |
