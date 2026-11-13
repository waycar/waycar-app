# Connection-latency investigations

Summary of the investigation workstreams of `docs/design/connection-latency.md` (tracking issues #87 and #105). Investigations changed no code; their proposals fed the change workstreams. The full reports, with captures from the maintainers' test Hosts, stay in the private ops repository.

## WS6: Why a streaming Shell rides SSH while the Host says "MOSH" (2026-10-03)

**Question.** While a Shell streamed output, a capture showed about 2,100 packets on SSH and only 104 on mosh UDP, while the Host page said "Connected over mosh".

**Answer.** The output rode the SSH attach channel (`herdr terminal attach` on a PTY exec channel of the Host's one SSH connection), by design. `MoshTransportChoice.select` is the only mosh-or-SSH decision: Agent panes go over mosh, plain Shells always over SSH, so a Shell never "falls back". The Hosts-list capsule is a per-Host mosh capability (a probe proved the UDP path), not a per-terminal transport, so "MOSH" and an SSH Shell are both true at once.

- **Ruled out:** the events stream (complete `PaneInfo` values folded locally, no RPC per line), pane reads (none on the attach path), a fallback.
- **tmux control mode.** *Correction (2026-10-04, #105):* this report first said "Show tmux sessions" is off by default. It is on (`HostBackendPreferences.showsTmux` returns `entries[hostID]?.showsTmux ?? true`), so a dual Host runs the tmux scope on the same SSH connection unless the user turns it off. Control mode subscribes with `no-output`, so it carried format notifications, not the Shell's output; the cost of the default was contention, and since #105 the tmux scope connects only after herdr's connection settles.
- **Verdict per ADR 0021:** correct as designed; the label overstates what it proves. Proposed: a more precise accessibility label or a per-terminal transport chip, and, as a design change, Shells over mosh too.

## WS5: The ~1 s cold-launch badge mode is not auth (2026-10-03)

Cold launch restoring into a terminal was bimodal (about 490 ms or 1004–1154 ms). Not a second dial, not keyboard-interactive and not slow auth: auth runs before the clock starts, and server-side password checking took about 21 ms with no variance. The slow mode was a race inside the timed window: the ping's `$HOME` exec and backend detection's exec contended for the connection's first session channel (which pays the server's ~250 ms session setup) and for the operation mutex. WS2 and WS3 removed it; auth needed no change.

## WS2: the `$HOME` lookup off the timed path (2026-10-03)

| Measurement | Before | After |
|---|---|---|
| Connect-path ping | 0.27–20 ms when another scope had cached `$HOME`, ~106–130 ms when the ping resolved it | 0.27–0.35 ms, every launch |
| Off-clock readiness (the exec, with first-channel setup) | inside the clock | 18–25 ms, awaited before the clock |

The exec still runs once per dial and never for an absolute socket path. On a dual Host the row badge kept showing the launch re-prove queued behind the tmux scope's connect work, which WS3 then fixed.

## #105: where a return to an Agent spends its time (2026-10-03)

### Live timeline (iPad simulator → local sshd + herdr 0.9.3)

RTT≈100 is 50 ms each way of injected delay; "Show tmux sessions" off; n=3 per cell unless noted.

| Scenario | RTT≈0 | RTT≈100 | ≈ RTTs |
|---|---|---|---|
| Tap Agent row (Host connected) → live | 641 ms | 1057 ms | 4.2 |
| Tap Shell row → live | 576 ms | 960 ms | 3.8 |
| Background 32 s (past the 20 s grace) → live | 691 ms | 2728 ms | 20 |
| Terminate in session → cold restore → live | 1744 ms | 4756 ms | 30 |
| Cold launch → Agent list usable (n=6) | 1144 ms | 2906 ms | 17.6 |
| 70 s outage → Host shows trouble | 30.3 s, 42.8 s | not run | |

Findings that became work: about 450–520 ms of a tap was UI layout before the first size report (WS10 starts pipelines at intent); the terminal waited for ping, subscribe and snapshot (WS8); channel opens completed one RTT apart, queued on the mutex (WS3, WS11); a cold-restored Agent rode SSH because the mosh probe landed late (WS10); idle detection took 15–45 s (WS9); a mosh session whose server still answered was rebuilt after a freeze (WS10); the dial started 0.6–1.1 s after `app.init` (WS9).

### Host-side SSH costs (five Linux test Hosts and a Mac's sshd, ~1 ms LAN)

- A new connection costs about 7 round trips plus 105–180 ms of Host work (fork 11–18 ms, key exchange 12–37 ms, key login 69–86 ms).
- The first channel on a connection pays post-login session setup once: 4–64 ms for a socket forward, more on full systemd Hosts.
- On a warm connection a socket forward costs about 2 ms and an exec 14–68 ms; Fedora and Rocky source `~/.bashrc` for SSH commands (about 30 ms per exec).
- `mosh-server new` takes 3.9 ms on Linux and about 130 ms extra over SSH on a macOS Host.
- Reusing a live connection is the biggest Host-side lever (WS9).

### Mosh protocol (swift-mosh and mosh-server 1.4.0 source)

- mosh-server runs the wrapped `herdr agent attach` only after the first client datagram and exits after 60 s with no client, so a standby server has no pane side effects (ADR 0027).
- The UDP endpoint was a second DNS lookup of the host name, not the SSH peer address (WS10 uses the peer IP on a direct connection).
- `networkTimeoutMs` was declared and never read (SwiftMosh patch 12, app value 65 s).

### herdr's read tick (herdr v0.9.3 source and a local benchmark)

- The API server sleeps 100 ms on every empty read of a new connection's first request line, so every one-shot RPC over SSH pays about 100 − (RTT mod 100) ms; idle accepted connections are closed after 5 s.
- A `poll(2)` wait answered a ping sent 2/20/50 ms after connect in 0.0/0.1/0.1 ms (before: 104/79/48 ms, p50 of 20, release builds), and through `ssh -L` streamlocal in 0.2/0.4/0.4 ms (before: 105/81/51 ms). Status: WS15 in the plan.
