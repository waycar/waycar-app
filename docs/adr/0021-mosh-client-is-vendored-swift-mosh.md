---
status: proposed
---

# The mosh client is a vendored, patched swift-mosh

_2026-10-04:_ ADR 0027 (#105) changes how a session starts, how it is judged
dead and how it ends; the consequences below stand except where this note
narrows them.

- **Probe and availability.** The per-Host probe no longer runs on every
  connection. What a mosh session or probe learned is kept per Host, connection
  target and network for 24 h (`MoshAvailabilityStore`, in its own
  `MoshAvailability` directory under Application Support, kept out of
  backups): first contact proves mosh available, and a freshly bootstrapped
  server that never answers marks UDP blocked on that network. An outcome is
  recorded under the network its attempt started on, never under one the
  device moved to meanwhile. The probe runs only when nothing fresh is known,
  after the first snapshot and never beside an attach bootstrap. A user's Use
  SSH Instead lasts across connection generations and network changes until
  the capsule's re-probe clears it; an automatic fallback does not.
- **Bootstrap.** It returns on the `MOSH CONNECT` banner line
  (`HostSSHSession.runExecUntilLine`) instead of waiting for the exec to end,
  and the client aims its UDP at the address the dial pinned on a direct
  connection (`HostSSHSession.moshUDPHost`, #122 below), not a second DNS
  lookup of the configured name; through a Jump Host it still uses that name.
- **Standby servers.** A mosh-server may now be started before its client:
  for every live mosh attach at Background Grace expiry, and speculatively for
  a Host's last-viewed Agent. mosh-server 1.4.0 runs the wrapped attach only
  once the first client datagram arrives, and exits after 60 s without one,
  so an unused standby never touches the pane (ADR 0027 has the #19
  analysis).
- **Liveness.** `networkTimeoutMs` is now enforced (SwiftMosh patch 12) and
  the app sets 65 s (`MoshClientConfig(networkTimeoutMs: 65_000)`): a session
  that answered and then fell silent that long fails as `MoshLinkLost` and
  reattaches once over mosh instead of falling back to SSH. 6.5 s of silence
  shows the Reconnecting pill over the live frame (patch 11,
  `MoshAttachSession.stallThresholdMs`). The threshold sits above 3 s on
  purpose: mosh-server acks an idle client's empty states only on its 3 s ack
  interval (`networktransport-impl.h`), and 6500 ms matches mosh's own
  `server_late` warning. A path change rebinds every running session to a new
  local port (patch 13). To hear from the server at once, the rebind and the
  return's contact check send `elicitServerReply()` (patch 15), a repeat of
  the last sent size that mosh-server acks within its 100 ms ack delay. The
  session records that size before a resize's send suspends, so an elicited
  state never undoes a newer resize. When a session's server answers again
  after a stall, the Console redials that Host's disconnected connections at
  once (`ConsoleStore.moshServerAnsweredAfterStall(on:)`, at most once per 2 s
  per Host) rather than leaving them in their backoff. "Any mosh failure still
  falls back to the SSH attach" therefore holds for every failure except a
  link lost after first contact (`MoshLinkLost`), which reattaches over mosh
  once instead.
- **Ending.** A session the user leaves or the app suspends still ends with
  the shutdown handshake and its wait of about a second. Three paths now skip
  it with `abandon()` (patch 14), because no live server is expected to
  answer: a session found silent within `AgentAttachStore.moshContactWindow`
  (1.5 s) on a return from a possible suspension, a replacement after the
  connection was lost, and a first-contact timeout. A session heard on return
  is kept, and mosh sessions are no longer replaced when the SSH connection
  changes. `MOSH_SERVER_NETWORK_TMOUT=60` is the backstop for the abandoned
  ones, as for the three cases listed below.

The Agent terminal's mosh (UDP) transport runs on
[swift-mosh](https://github.com/wiedymi/swift-mosh), an independent MIT
implementation of the mosh client protocol in Swift, vendored as the
repository-local package `Packages/SwiftMosh` at upstream v0.1.8 with Waycar's
patches recorded in its `PROVENANCE.md`. It replaces `Packages/WaycarMosh`,
which linked `libmoshios`: mosh 1.3.2's own client through Blink Shell's iOS
port, plus protobuf 2.6.1. Everything around the session is unchanged: the SSH
connection still bootstraps `mosh-server new`, the per-Host probe still proves
the UDP path, and any mosh failure still falls back to the SSH attach.

## Why

mosh is GPL-3.0-or-later, and statically linking its client made the shipped
app a combined work that must offer its complete source, subscription code
included, to everyone who installs it. mosh's App Store note waives only the
conflict with Apple's terms, "as long as you comply with the GPL in all other
respects, including its requirements to provide users with source code".
Waycar's repository was private, so the GPL client had to go. (ADR 0033 later
opened the source; the client stays out because linking it would make the
Apache-2.0 app a GPL work.) swift-mosh was
chosen among permissive rewrites because it is Swift (no FFI build or foreign
runtime), leaves rendering to the consumer (Ghostty already renders the
Attach), and a comparison against mosh's source found no copied comments,
structure, or internal names beyond protocol vocabulary.

## Consequences

- The server's screen updates are raw terminal bytes fed straight into the
  Attach output; Ghostty is the only screen. When mosh-server builds a state
  on an older base than the one shown, the bytes still apply on top of the
  newest screen, and under heavy ack loss a cell that changed and changed back
  can keep stale content until redrawn. Dropping those states instead was
  measured and rejected: at 250 ms round-trip time it fell to about one frame
  per second. A client-side screen model that keeps recent states is the fix
  if this shows in use.
  *Amended 2026-10-07:* it showed in use, as stray characters from earlier
  output in Agent terminals on slow or lossy links, so SwiftMosh now keeps
  the screens of recent states (`MoshScreen`, Waycar patch 16) and applies
  each diff to its stated base. A state on an older base reaches Ghostty as
  a repaint from the screen it shows to the new one, and returning to the
  app redraws the terminal from the last known screen. Against a real
  mosh-server with every client datagram 150 ms late, 65–73 states per run
  arrived on older bases; the terminal ended exact, where applying them on
  top left 11–18 of 24 rows wrong.
- There is no local echo prediction (libmoshios ran `adaptive`): typing in
  Direct Input over mosh echoes at the server's pace. Composer drafts locally,
  so its feel is unchanged.
- swift-mosh has no resize signals or process-wide handlers, so libmoshios's
  limitation that two live mosh sessions could misdirect a SIGWINCH is gone.
- The library has one maintainer and little field use. The vendored copy is
  ours to fix; upstream updates are re-applied by hand against
  `PROVENANCE.md`, and its real-server suite runs with
  `SWIFTMOSH_REAL_E2E=1 swift test --package-path Packages/SwiftMosh`.
- mosh-server's lifetime is ours to end. An attach holds herdr's resize lock
  on its pane for as long as it runs, and herdr does not reclaim the size on
  its own, so a mosh-server that outlives its client pins the pane at the
  phone's size on the Mac (#19: seventeen orphans, the oldest a day old).
  Ending a running session (`MoshAttachSession.end()`) quits the way mosh's
  own client does: it sends the shutdown state and waits up to about a second
  for mosh-server to acknowledge it, after which the server exits and its
  attach with it. The bootstrap exports `MOSH_SERVER_NETWORK_TMOUT=60` as the
  backstop for a client that never says goodbye (killed app, lost network):
  the server exits 60 s after the client's last new state. That clock ignores
  repeated states, so swift-mosh's idle heartbeat is a new, empty state, as
  mosh's own client's is; with upstream's heartbeat an idle attach was cut off
  after 60 s. Three known cases still leave the attach to that backstop,
  about a minute: a session ended while it is still starting has no
  connection to say goodbye on (a server that never heard from it gives up
  after its own 60 s); a session ended during a network handoff, while
  swift-mosh is replacing its transport and has none, just stops; and an
  Agent terminal the terminal cache does not hold (a private attach store, as
  in a second iPad window) is not ended when the app is suspended, so its
  server times out instead. The trade-off: mosh's roaming no longer bridges a
  silence longer than 60 s (a suspended app, a long outage); such a session
  has ended on the Host and the terminal attaches afresh.
- On a direct connection the bootstrap runs `mosh-server new -s` and aims
  UDP at one fixed address, not the Host's name (#122): an unbound server
  answers from its primary-interface address, and swift-mosh's connected UDP
  flow drops replies from any other source. A literal IP Host keeps its
  literal; a name pins the address the SSH socket reached, with v4-mapped and
  NAT64 well-known-prefix (`64:ff9b::/96`) peers mapped to IPv4. When
  `SSH_CONNECTION` shows sshd reached over loopback (a TCP proxy such as sslh
  on the Host), the server stays unbound, since `-s` would bind loopback. An
  address pinned from a name does not follow DNS across a network handoff
  (split-horizon or dual-stack names), the same as upstream mosh's default of
  sending UDP to the address ssh connected to. This is Waycar's bootstrap,
  not a swift-mosh patch; through a Jump Host none of it applies.
