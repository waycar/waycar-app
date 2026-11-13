# Connection latency

Summary of the connection-speed program: the "Connected, latency N ms" badge, slow Host tabs, slow RPCs and slow returns to an Agent. Tracking issues: #87 (WS1–WS7) and the umbrella #105 (WS8–WS15). The decisions behind WS8–WS10 are ADR 0027; the investigations are summarized in `connection-latency-investigations.md`. The maintainers keep the full handoff plan, with the measurement setup on their own test Hosts, in their private ops repository.

## What the badge measures

`HostListView` ← `ConsoleStore.hostLatencies` ← `HostConsoleProjection.latency` ← `EventsSession.currentLatency`, set by `EventsSession.measureLatency(on:)`: a timed herdr `ping`, published at connect, on foreground `revalidate()`, and every 2 s while the Hosts sheet is open. Before WS2 the first request of each new SSH connection also ran a `$HOME` exec inside the timed window.

## Root causes (2026-10-03, four reviews and simulator packet captures)

1. **No `TCP_NODELAY`.** libssh2 writes small packets back to back, and Nagle held the second until the server's delayed ACK: 2 stalls per foreground revalidate and 7–10 per cold launch, each about RTT + 40 ms, up to RTT + 200 ms on cellular.
2. **`$HOME` exec inside the timed ping.** About 2–3 RTT plus a remote shell start; the connection's first session channel also pays the server's PAM/logind/motd setup, about 250 ms on a 2-vCPU cloud test Host.
3. **Serialization behind other session work.** Channel opens and SFTP held `SessionDriver`'s operation mutex across their network waits while backend detection, the mosh probe, tmux detection, re-attach and sidebar reads ran beside the ping.
4. **Cellular path.** The same Host measured about 108 ± 77 ms RTT from a phone on cellular against about 36 ms on Wi‑Fi.
5. **Every one-shot RPC is about 3 RTT.** herdr serves one request per connection: open a `direct-streamlocal` channel, exchange, then wait for the peer's `CHANNEL_CLOSE`.

Ruled out: terminal or events-stream contention, socket polling granularity, IPv6 address ordering, VM capacity, the keepalive.

## Baseline (iOS Simulator → a cloud test Host, RTT ≈ 34 ms, 2026-10-03)

| Condition | Badge (ms) |
|---|---|
| Cold launch, list visible, no terminal | 493, 529, 565, 613 |
| Background → foreground (revalidate) | 264, 385, 390, 429, 470 |
| Same, opencode terminal open | 236, 264, 293, 348 |
| Same, Shell streaming output | 247, 261, 403, 429 |
| Cold launch restoring into a terminal | bimodal: ~490 or 1004–1154 |

Predicted critical path from launch to a usable Agent list: about 17–18 RTT plus stalls (0.6–0.75 s at 32 ms, 1.4–1.75 s at 80 ms).

## Workstreams

| WS | What | Status |
|---|---|---|
| WS1 | `TCP_NODELAY` on the connected socket (`SocketConnector`) | landed (#87) |
| WS2 | `$HOME` lookup off the timed path; a remembered `$HOME` skips it | landed (#87) |
| WS3 | Channel opens release the operation mutex while they wait; interactive work first (`SSHOperationPriority`); connect work reordered | landed (#105) |
| WS4 | One-shot RPCs return once the response is read; EOF, close and free finish in the background under the admission lease | landed (#105) |
| WS5 | The ~1 s cold-launch mode (investigation): not auth | done |
| WS6 | Why a streaming Shell rides SSH while the Host says "MOSH" (investigation) | done |
| WS7 | Field check on a real iPhone | open |
| WS8 | Attach first, defer the rest, remember `$HOME` and the herdr protocol per Host | landed |
| WS9 | Keep the connection across suspension, detect a dead link fast | landed (ADR 0027) |
| WS10 | Mosh fast path: standby servers, availability memory, stall pill | landed (ADR 0027) |
| WS11 | Patched libssh2: no `PK_OK` query, pty-req with exec, the `requirev` fix, pipelined opens | landed |
| WS12 | Happy Eyeballs connect (RFC 8305) | landed |
| WS13 | Last frame on entry and cold launch | landed |
| WS14 | Network telemetry (`os_log` phases, signposts, internal-build analytics) | landed |
| WS15 | herdr's 100 ms first-request tick (upstream) | prepared, not filed |

## Before/after numbers (#105)

Measured 2026-10-04, the same way as the 2026-10-03 baseline: iPad Pro 13-inch (M5) simulator against a local sshd with herdr 0.9.3, loopback RTT and 50 ms injected each way. Each cell is the median of three runs (six for "Cold launch → Agent list usable"; the 70 s baseline cells are two runs). "Live" now means the first visible content (or 400 ms after the first bytes), where the baseline stopped at mosh-server's blank first frame, so "first bytes" is the baseline-equivalent number.

| Scenario | Before, RTT≈0 | Before, RTT≈100 | After, RTT≈0 | After, RTT≈100 |
|---|---|---|---|---|
| Tap Agent row → live | 641 ms | 1057 ms | 678 ms | 1126 ms |
| Tap Agent row → first bytes | 641 ms | 1057 ms | 625 ms | 976 ms |
| Tap Shell row → live | 576 ms | 960 ms | 689 ms (one UI outlier) | 783 ms |
| Return after > 20 s background → live | 691 ms | 2728 ms | 349 ms | 465 ms |
| Return after 95 s background → live (new) | – | – | 376 ms | 698 ms |
| Cold launch restoring into an Agent → live | 1744 ms | 4756 ms | 1443 ms | 2189 ms |
| Cold launch restoring into an Agent → cached frame shown (new) | none | none | 777 ms | 777 ms |
| Cold launch → Agent list usable | 1144 ms | 2906 ms | 992 ms | 1692 ms |
| 10 s outage → trouble shown | nothing visible | not measured | 4.31 s (stall pill) | 3.95 s |
| 70 s outage → Host shows trouble | 30.3 s, 42.8 s (two runs) | not measured | 27.1 s (stall pill at 5.4 s) | 17.6 s (pill at 4.2 s) |
| 70 s outage → terminal live after unblock | +2.7 s, +3.3 s (two runs) | – | +7.3 s (1.2–12.4) | +7.3 s (2.4–8.5) |

At 100 ms the biggest wins are the return (−83%), cold restore (−54%) and the cold-launch list (−42%).

- **Return after > 20 s:** through the standby mosh session, revalidated over the kept SSH connection: about 2 RTT plus roughly 350 ms of lifecycle and UI time.
- **Return after 95 s:** the kept SSH connection plus a fresh mosh bootstrap (the standby is at most 50 s old).
- **Cold restore:** rides mosh from the first attach because availability is remembered: about 11 RTT from the SYN, down from about 36.
- **Slow recovery after a long outage** was bimodal (a dial in flight got through in 1.2–2.4 s; one that had just timed out slept an 8 s backoff step). Since then a mosh server that answers again after a stall redials its Host at once (`ConsoleStore.moshServerAnsweredAfterStall(on:)`); the last row predates that.

## herdr's 100 ms first-request tick (WS15)

herdr 0.9.3 reads a new API connection's first request line without blocking and sleeps 100 ms on every empty read, so a request that arrives after accept waits for the next tick: over SSH every one-shot RPC pays about 100 − (RTT mod 100) ms. The same tick paces `events.subscribe` delivery and the `wait` calls. An accepted connection that sends no full request line within **5 s** is closed (EOF measured at 5.04 s), so a pre-opened channel must be used within about 4.9 s and still waits for its tick.

A fix that waits with `poll(2)` instead, measured as p50 of 20 release-build runs:

| Ping sent after connect | 2 ms | 20 ms | 50 ms |
|---|---|---|---|
| Local socket, before | 104 ms | 79 ms | 48 ms |
| Local socket, after | 0.0 ms | 0.1 ms | 0.1 ms |
| Through `ssh -L` streamlocal, before | 105 ms | 81 ms | 51 ms |
| Through `ssh -L` streamlocal, after | 0.2 ms | 0.4 ms | 0.4 ms |

Status: prepared, not filed. herdr takes outside changes as bug issues, so the route is an issue that describes the delay.
