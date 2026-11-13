---
status: accepted
---

# Keep Host connections across suspension and start mosh from a standby

_2026-10-04, accepted: requested by Mike for the network performance program
(umbrella #105, refs #27 #87); implemented on branch `performance-network`._

Coming back to an Agent was slow because the app threw away everything it had
built. Measured on 2026-10-03 (iPad simulator against a local sshd and herdr
0.9.3, `docs/design/connection-latency.md`), a return after the 20 s
Background Grace Period took 0.69 s to a live terminal at a loopback round
trip and 2.73 s at 100 ms, about 20 round trips. In the field (#27, iPad to a
Mac) it took 10 to 16 s. The return redialed SSH (about 7 round trips plus
105 to 180 ms of Host work per connection on the Linux testboxes), re-proved
herdr, waited for a fresh snapshot before attaching, re-probed mosh with a
second throwaway server, and bootstrapped a new mosh-server over SSH before
the client could send its first datagram.

This ADR records the decisions that remove that work. They change connection
lifetime and channel concurrency, which ADR 0011 says need their own explicit
decision; this is it.

## Decisions fixed here

- **Keep the Host's SSH connection across suspension.** When the Background
  Grace Period runs out, `EventsSession.suspend()` quiesces instead of
  closing: it ends the events channel, the keepalive and every channel the
  Transport holds (tmux control mode included) by explicit close, and keeps
  the Host's pooled connection open (`SSHSessionPool.keep`). On return,
  `resumeKept` probes that connection with an attach-first offer, an early
  subscribe and the ping under `LivenessTiming.deadline`
  (clamp(4 × RTT + 1 s, 2 s, 5 s)), and starts a fresh dial beside it after
  `LivenessTiming.hedgeDelay` (clamp(2 × RTT + 150 ms, 200 ms, 800 ms)).
  The first to answer wins; the loser is closed, and a dead kept connection is
  retired from the pool so nothing rides it again. A connection kept longer
  than `LivenessTiming.keptConnectionMaxAge` (10 min) is redialed without a
  probe, because NAT mappings and server idle limits make it unlikely to
  answer. On the expiration path, where iOS gives no background time, the
  closes are detached (`suspend(locally:)`) so nothing waits on the network.
  This supersedes the deliberate teardown at suspension that ADR 0011's
  connection lifetime assumed and that `CONTEXT.md` described for Suspended
  and the Background Grace Period.
- **Detect a dead link in seconds.** Keepalive and revalidation pings use the
  same liveness deadline instead of the 15 s RPC budget, and revalidation is
  hedged the same way. Revalidation sizes its deadline and hedge delay from
  the last revalidation's latency (`lastRevalidateLatency`), not the dial's
  round trip. `LivenessRace` runs the proof under `AsyncDeadline` on the
  liveness clock (its sleep is injectable, so tests script time), and a proof
  that fails on the link starts the hedge at once; a server's answer, even an
  error, decides the race instead. A network path change (`NetworkPathMonitor`,
  one app-wide monitor with a 300 ms debounce) revalidates every Host, redials
  at once when a path returns after none, and rebinds every running mosh
  session to a fresh UDP flow (`MoshSessionRegistry.rebindAll`). When a mosh
  server answers again after a stall, the Host's disconnected connections are
  redialed at once (`ConsoleStore.moshServerAnsweredAfterStall(on:)`, at most
  every 2 s per Host, never while suspended): a firewall outage is no path
  change, and without this the redial waited out its backoff step.
- **Dial before the first window.** The launch dial starts on the first app
  scene's `UIScene.willConnectNotification`, which restored scene sessions
  post too, ahead of that window's layout. On the simulator that is about
  300 ms earlier than the first window.
- **Standby mosh at grace expiry.** Before the teardown, while the SSH
  connection is still up, `ConsoleStore.prepareMoshStandbys(within:)` starts a
  fresh mosh-server for every live mosh Agent attach (`StandbyMoshStore`),
  bounded by the background time left (`backgroundTimeBeforeTeardown`, at most
  `StandbyMoshStore.bootstrapBudget` of 3 s, keeping
  `ConsoleActivityDriver.teardownReserve` of 5 s for the teardown). The live
  attach is then torn down exactly as before, so the desktop gets its pane
  size back at 20 s. A return within `StandbyMoshStore.maxAge` (50 s) starts
  the mosh client straight at the standby, before any SSH work, with a 3 s
  first-contact timeout (`standbyFirstContactTimeout`); a standby that does not
  answer leaves the attach to the ordinary path.
- **Speculative standby.** While the Console is in front and the Host is
  connected with mosh known to work, the Host keeps one standby for its
  last-viewed or last-named Agent (a notification, Live Activity or link names
  one), renewed every 40 s (`MoshFastPath.speculativeStandbyRefresh`). The
  first preparation of a standby an intent named (`noteAgentIntent`) runs at
  `.interactive` priority, since a tap is about to wait on it; its renewals
  run `.normal`. An Agent whose terminal the cache still holds needs none.
  Standbys and attach bootstraps never run for the same target at once, and
  a standby is single use.
- **Check before replacing.** A mosh session still running when the app
  returns from a possible suspension gets `AgentAttachStore.moshContactWindow`
  (1.5 s) to hear from its server, after an `elicitServerReply()` (SwiftMosh
  patch 15) that a live server acks within its 100 ms ack delay. Heard, it
  is kept; silent, it is replaced with `MoshClientSession.abandon()`, which
  skips the shutdown handshake for a server presumed gone. Mosh sessions are
  no longer replaced when the SSH connection's generation changes, because
  their UDP flow never rode it.
- **Attach first.** Terminal work starts as soon as SSH is authenticated and
  the socket path is known: `EventsSession` hands the new connection to
  terminals before its ping (`provisional`), reserving the connection's
  generation at that handoff and publishing it only once the ping answers.
  RPCs and the events stream still wait for the ping. `ConsoleStore` no longer
  makes an attach wait for the Host's inventory to be verified; an attach that
  fails or ends while its Host is unverified waits for verification and then
  either attaches once more (the target is still listed) or lets the original
  outcome stand (the pane is gone). Terminal work runs at
  `SSHOperationPriority.interactive`, so the session driver serves it ahead of
  normal work. Work the first screen does not need runs after it: backend
  detection is skipped while the cached presence is younger than
  `ConsoleStore.backendPresenceFreshness` (6 h) and otherwise waits for the
  connection to settle; the mosh probe runs only when nothing fresh is known,
  after the first snapshot and never beside an attach bootstrap; on a Host
  with both backends the tmux scope connects after herdr settles. The first
  `events.subscribe` is seeded with the last-known pane set, and any rejection
  of a seeded set falls back once to the global set.
- **Pipelined channel work in libssh2.** Waycar patches its pinned libssh2
  (`Packages/WaycarSSH/Patches/libssh2/0001`–`0004`, recorded in
  `Artifacts/PROVENANCE.md`) so publickey auth signs its first request (one
  round trip less per dial), a PTY request and its exec go back to back (one
  round trip for both), and channel opens keep their state on the channel so
  up to `SessionDriver.pipelinedChannelOpenLimit` (32) await replies at once.
  An open's waiter releases the operation mutex between turns. A refused open
  fails only that channel and spares the session: `CHANNEL_OPEN_FAILURE` is
  final, and the server has already freed its side. A cancelled or timed-out
  open is freed (`freeAbandonedChannelOpen`, 2 s budget) and spares the
  session unless the free cannot finish or the link died under it, which a
  non-blocking `MSG_PEEK` after the free detects (`transportHasEnded`).
  One-shot RPCs return once their response is read and close in the
  background, keeping their admission lease until the channel is really
  closed. This amends ADR 0011's #130 amendment.

## Caching strategy

Every cache is stale-while-revalidate: the remembered answer is used at once,
the live connection re-proves it, and a failure that contradicts it
invalidates it. Nothing cached is trusted for authority it never had.

| What | Where | Lifetime | Revalidated by |
|---|---|---|---|
| `$HOME` and herdr protocol version per Host | `<host>.connection.json` beside the inventory cache (Application Support, excluded from backups, complete protection), via `ConsoleInventoryCache.connectionMemory(for:)` | until the Host's connection target changes | a missing socket at the remembered path re-resolves `$HOME` once and retries; the ping still decides whether the protocol meets the floor |
| Backend presence | `<host>.backends.json`, now with `verifiedAt` | detection skipped for 6 h | a missing-backend failure triggers detection at once |
| Mosh availability per Host and network | `MoshAvailability/MoshAvailability.json` (its own directory under Application Support, excluded from backups, complete protection), `MoshAvailabilityStore` keyed by Host, connection target and `NetworkPathKey` | 24 h (expired records dropped at load); a Host's records deleted when it is removed or re-targeted | a session's first contact proves available; a freshly bootstrapped server that never answers marks UDP blocked on that network. Each outcome is recorded under the network its attempt started on |
| Each Agent's last painted frame | `Caches/AgentLastFrames/` (one JPEG per Agent plus an index, complete protection), `AgentLastFrameStore` | 8 most recent Agents, 24 h, only for the connection target it was taken on | shown under Ignition's Reconnecting veil until the live terminal paints |
| Terminal grid size per layout | `UserDefaults`, `TerminalGridSizeMemory` (16 layouts) | until replaced | the view's first size report becomes a resize |
| Kept SSH connection, standbys | memory only | 10 min / 50 s | the liveness probe; the standby's first contact |

Mosh session keys are never written to disk, and neither is terminal text.
The last frame is an image of the screen, which `PRIVACY.md` discloses.

## The #19 trade-off

ADR 0021 and the herdr facts in `AGENTS.md` make every live attach own its
pane's size until it exits, and an orphaned mosh-server pins the desktop pane
at the phone's size (#19). The standby design keeps that promise because of
two mosh-server 1.4.0 facts (source review of `src/frontend/mosh-server.cc`,
confirmed for the 2026-10-03 investigation):

- After `forkpty()` the child blocks reading its PTY and execs the wrapped
  command (`herdr agent attach … --takeover`) only once the server's serve
  loop sees the first client state advance its remote-state counter, that is
  on the first client datagram (`mosh-server.cc:593-597`, `822-828`). Until a
  client uses it, a standby runs no attach: no resize lock, no takeover, no
  effect on the pane.
- A server that never hears from a client exits after 60 s
  (`mosh-server.cc:682`, `914-918`). An unused standby therefore cleans itself
  up, and `StandbyMoshStore.maxAge` stops at 50 s so a client never races
  that exit.

So the live attach still ends at grace expiry and the desktop gets its size
back then, as before. What is spent is Host-side: one idle mosh-server and one
UDP port per standby for at most a minute. Speculative renewals start a new
server every 40 s and leave the replaced one to time out unused, so a viewed
Agent can briefly have two idle servers. Using a standby takes the pane over
exactly like a fresh attach with `--takeover`.

## Considered options

- **True mosh resume** (keep the client session across suspension, or
  snapshot and restore it with SwiftMosh's existing APIs): a resumed session
  needs one UDP round trip and no SSH at all. Rejected because the attach
  would stay alive through the whole background period, holding the desktop
  pane at the phone's size for up to a minute and breaking #19's guarantee
  that the desk gets its size back at 20 s. A suspended client also stops its
  heartbeat, so the window is bounded by the last state sent, not by the
  return. A standby gives nearly the same return (one UDP round trip plus
  herdr's attach start) without holding the pane.
- **VoIP sockets or other background modes** to keep sockets alive while
  suspended: Waycar declares no `UIBackgroundModes`, and the VoIP path is for
  calls (PushKit pushes must be reported to CallKit). Keeping the connection
  open and probing it on return gets the benefit when iOS leaves the socket
  alive, and the hedged dial covers the case where it does not.
- **Persisting mosh session keys** to resume across a relaunch: puts session
  key material at rest for a server that exits 60 s after its last client
  state anyway, while a cold launch already spends seconds before it could
  try. The last-frame cache makes a cold launch feel fast without it.
- **A pool of pre-opened herdr socket channels**: herdr 0.9.3 closes an idle
  accepted connection after 5 s and still serves a pre-opened channel on its
  next 100 ms read tick (`AGENTS.md`), so a pool would churn without saving
  the tick. Pipelined opens remove the open round trip instead.
- **Always dial fresh on return, in parallel with nothing kept**: simple, but
  pays the full dial and the first channel's PAM session setup every time.

## Consequences

- A healthy return reuses the connection: no TCP, key exchange or auth, no
  PAM session setup, and the terminal attaches before the ping answers.
- A Host whose connection died while the app was suspended is noticed within
  the liveness deadline and redialed beside the probe, never after the 15 s
  RPC budget.
- The Host sees an idle authenticated SSH connection from a suspended phone
  until the app returns (one kept over 10 minutes is then closed unprobed),
  iOS reclaims the socket, or the server or a NAT drops it, and idle standby
  mosh-servers for up to a minute.
- On the expiration path the closes are detached and may not reach the Host;
  the server's own timeouts and `MOSH_SERVER_NETWORK_TMOUT` remain the
  backstop, as ADR 0021 describes.
- A user's Use SSH Instead lasts across connection generations and network
  changes until the capsule's re-probe clears it; automatic mosh
  invalidations do not.
- Network phase logging (`Logger` subsystem `com.otreva.waycar`, category
  `network`, plus signposts) is permanent and carries no host names, addresses
  or content; network analytics events go out only from internal builds
  (`BuildFlavor.internalTesting`) and, in a release-configured one, only once
  the receipt check passes (`AppEnvironment.allowsAdmin`), behind the existing
  opt-in. `host_connect` records what set the connect off (`trigger`):
  `launch`, `foreground`, `retry`, `path_change`, or `mosh_recovery`, the
  redial after a mosh server answers again following a stall.
