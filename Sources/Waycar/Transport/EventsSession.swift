import Foundation
import os
import Synchronization
import WaycarSSH

/// Bounded backoff for transient events-channel failures (#18): capped
/// exponential delay, unlimited attempts. Action-required failures stop and
/// surface their exact cause instead of burning retries forever.
struct ReconnectPolicy: Sendable, Equatable {
    var initialDelay: Duration
    var multiplier: Int
    var maxDelay: Duration

    static let `default` = ReconnectPolicy(
        initialDelay: .seconds(1), multiplier: 2, maxDelay: .seconds(30))

    /// The delay before reconnect attempt `attempt` (1-based): the initial
    /// delay grown by `multiplier` per prior failure, clamped at `maxDelay`.
    func delay(beforeAttempt attempt: Int) -> Duration {
        let factor = max(multiplier, 1)
        var delay = initialDelay
        var remaining = attempt - 1
        while remaining > 0, delay < maxDelay {
            delay = delay * factor
            remaining -= 1
        }
        return min(delay, maxDelay)
    }
}

/// Keepalive for the events session (#18). The Transport seam deliberately
/// exposes no SSH-specific keepalive machinery, so the session pings herdr
/// over the ordinary RPC path instead — which is also the stronger check: it
/// generates SSH traffic that keeps NAT mappings alive, is bounded by a
/// liveness deadline of a few round trips (`LivenessTiming.deadline`, #105),
/// and exercises the whole path (SSH + the forwarded socket + herdr), so a
/// dead connection is detected within interval + that deadline.
struct KeepalivePolicy: Sendable, Equatable {
    /// Idle time between pings while the events channel is live. Pings are
    /// skipped while real traffic within the interval — a successful RPC or
    /// an arriving event — already proves the connection alive; both of the
    /// ping's jobs (liveness detection, NAT-mapping refresh) are done by
    /// that traffic. A keepalive ping proves liveness only: it does not
    /// republish `currentLatency` (see `startKeepalive`), so the displayed
    /// value stays the one proved at connect, at the last foreground
    /// `revalidate()`, or at the last `sampleLatency()` the open Hosts sheet
    /// asks for, rather than flickering on every idle tick — each
    /// ping costs a full SSH channel open/exchange/close, ~3 network round
    /// trips, not worth paying every interval just to redraw a number.
    var interval: Duration

    static let `default` = KeepalivePolicy(interval: .seconds(30))
}

/// Where the events session stands; the UI derives staleness from this.
enum EventsSessionStatus: Sendable, Equatable {
    /// A new activation is establishing its first usable events path,
    /// outside the automatic retry loop. Emitted synchronously from
    /// `activate()` before `run` is spawned.
    case connecting
    /// The server acknowledged the events subscription. Every emission,
    /// including a same-Transport subscription reinstall, requires a fresh
    /// `sessionSnapshot()` while consuming events. herdr 0.9.0 lifecycle
    /// subscriptions do not replay pre-subscription events. A deliberate
    /// reinstall stays `.connected` through its brief stream gap; the next
    /// emission triggers a snapshot that covers changes during that gap.
    case connected
    /// Automatic recovery after a retryable failure; covers the announced
    /// backoff and the dial that follows. Observable only while that cycle
    /// is the current one.
    case reconnecting(attempt: Int, delay: Duration, failure: TransportError)
    /// Automatic recovery stopped because retrying without user intervention
    /// cannot repair the failure. Observable only while no connection work
    /// is running.
    case failed(TransportError)
    /// Deliberately torn down (the app's background grace period elapsed);
    /// no reconnect activity until `resume()`.
    case suspended
    /// `end()` was called; the session is finished for good. Ownership
    /// terminal, not a connection condition.
    case ended
}

/// One element of the session's update stream: status transitions and events
/// interleaved in the order they happened.
enum EventsSessionUpdate: Sendable, Equatable {
    case status(EventsSessionStatus)
    case event(HerdrEvent)
}

/// The self-healing events channel for one Host (#18): owns the Host's
/// Transport, keeps its dedicated `events.subscribe` channel alive across
/// network blips and foreground/background transitions, and reports every
/// transition so the UI can show staleness.
///
/// Layer-honest reconnect: a dropped *channel* re-subscribes on the same SSH
/// connection through the transport's single-channel state machine; a dead
/// *SSH connection* (`isConnected == false`, or a timeout that means the
/// connection cannot be trusted) is closed and re-established via `connect`,
/// then pinged — the first call on every new connection path — before RPCs
/// may use it. Terminals do not wait for that ping (attach first, #105), and
/// with a remembered protocol at or above the floor neither does the first
/// events subscribe; the ping still decides whether the connection stands.
///
/// Lifecycle: a fresh session is suspended; `resume()` activates it (call on
/// launch and on foregrounding), `suspend()` quiesces it (call once the
/// app's background grace period elapses), `end()` is terminal. Quiescing
/// ends the events channel, the keepalive and every channel the Transport
/// holds (tmux control mode included) by explicit close, but keeps the
/// Host's pooled SSH connection open (#105). The return then probes that
/// connection with a short deadline instead of dialing, and a hedged fresh
/// dial starts beside the probe once it is slow (`ensureTransport`). A
/// connection kept longer than `LivenessTiming.keptConnectionMaxAge` is
/// closed and redialed instead. Without a pooled connection (`unshared`),
/// suspension closes everything, as before. Lifecycle calls serialize
/// internally — a `resume()` racing into a `suspend()`'s in-flight teardown
/// waits for it instead of interleaving (quick background→foreground
/// bounces are routine on iOS; callers never need to serialize their own
/// calls).
///
/// Liveness: keepalive and revalidation pings count as failed after
/// `LivenessTiming.deadline`, a few round trips rather than the 15 s RPC
/// budget. A dead link therefore shows within seconds, and a connection
/// found dead is retired from the pool so the redial cannot ride it again.
///
/// `updates` supports a single consumer and buffers at most
/// `updatesBufferLimit` updates (#22): under overflow the oldest are shed
/// and an `.event(.eventsDropped)` marker is yielded in their place (see
/// `HerdrEvent.eventsDropped` for the delivery guarantee), so the consumer
/// always learns it must resync instead of trusting incomplete deltas.
/// Statuses can be shed too — they are state, not edges, so the newest one
/// wins: terminal transitions (`.suspended`, `.ended`) are always the last
/// thing yielded and therefore survive, and a shed `.connected`'s resync
/// duty is covered by the marker.
actor EventsSession {
    private enum Phase {
        case suspended, active, ended
    }

    /// Status transitions and events, in order. Finishes after `end()`.
    nonisolated let updates: AsyncStream<EventsSessionUpdate>
    private let updatesContinuation: AsyncStream<EventsSessionUpdate>.Continuation
    /// Successful herdr ping round trips on the Host's live SSH connection.
    /// This is separate from `updates`: latency is latest-value telemetry, not
    /// part of the ordered status/event convergence stream. It is a *signal* —
    /// "a new measurement exists" — and carries the sample for callers that
    /// only want the number. A consumer that also folds `updates` must read
    /// `currentLatency` instead of this payload; see that property.
    nonisolated let latencyUpdates: AsyncStream<Duration>
    private let latencyContinuation: AsyncStream<Duration>.Continuation
    /// Installed, ping-proven Transport generations. Unlike `.connected`, this
    /// signal does not wait for the events channel, so a visible terminal can
    /// recover as soon as its own connection prerequisite is ready. Terminals
    /// may already ride a new connection before its `ping` (#105, attach
    /// first), under the generation it is published with once that `ping`
    /// proves it; one whose `ping` fails is never published.
    nonisolated let terminalTransportGenerations: AsyncStream<UInt64>
    private let terminalTransportContinuation: AsyncStream<UInt64>.Continuation
    /// The round trip the Host's *current* connection last proved, or nil
    /// while no live connection has proved one.
    ///
    /// `updates` and `latencyUpdates` are separate streams with separate
    /// consumers, so their consumption order establishes nothing: a delayed
    /// sample from a dead connection could otherwise land after the status
    /// that ended it. This value is instead written strictly before the update
    /// that makes the same fact observable — set before the `.connected` that
    /// follows a fresh ping, cleared before any non-connected status leaves
    /// `yieldUpdate` — so folding an update and reading this in the same turn
    /// yields a measurement that belongs to that update's own connection, at
    /// whatever moment either stream is actually consumed.
    nonisolated var currentLatency: Duration? { latencyBox.withLock { $0 } }
    private nonisolated let latencyBox = Mutex<Duration?>(nil)
    /// How many updates the bounded buffer has shed so far. Every shed
    /// update is covered by a marker (see `yieldUpdate`), so this is
    /// observability for diagnostics and tests, not a consumer signal.
    private(set) var droppedUpdateCount = 0

    var subscriptions: [EventSubscription]
    /// The Host's connection: which pooled connection each Transport rides,
    /// and the holds that keep it across a suspension (#105).
    let sharing: SharedConnection
    let clock: LivenessClock
    private let reconnectPolicy: ReconnectPolicy
    private let keepalive: KeepalivePolicy?
    private let terminalWaiterDidRegister: (@Sendable () -> Void)?
    /// The herdr protocol version earlier connections reported (#105): when
    /// it meets the floor, a new connection's first `events.subscribe` goes
    /// out alongside its `ping` instead of after it.
    let connectionMemory: (any HostConnectionMemory)?

    private var phase: Phase = .suspended
    /// The Host's live Transport. It never escapes this module; consumers
    /// use `withTransport` or `withTerminalTransport` so replacement and
    /// terminal admission remain local.
    var currentTransport: (any Transport)?
    /// The pooled connection `currentTransport` rides; nil when unpooled.
    var currentConnection: SharedConnection.ID?
    /// The connection held open across the last suspension, and since when
    /// (#105). The next activation probes it instead of dialing.
    var keptConnection: KeptConnection?
    /// What the kept connection's probe in flight has handed out
    /// (`resumeKept`).
    var keptProbe: KeptProbeHandout?
    /// The generation the kept connection's probe offered terminals (#105):
    /// attaches on it rode the connection kept across the suspension.
    var keptTransportGeneration: UInt64?
    /// What set the next connect off, for its report (#105).
    private var connectTrigger: NetworkAnalytics.ConnectTrigger = .launch
    private var hasActivated = false
    /// The live events channel's loss, and when, until it is back or given
    /// up on (#105).
    private var pendingLoss: (reason: NetworkAnalytics.Failure, at: ContinuousClock.Instant)?
    /// The latest ping round trip any connection proved; liveness
    /// deadlines and the hedge delay derive from it (`LivenessTiming`).
    var lastRoundTrip: Duration?
    /// The latest `revalidate()` round trip, kept apart from the ping's
    /// (#105): a backend's revalidate can cost more than its ping (tmux on
    /// an idle dual Host runs a `tmux ls` exec where its ping is local), so
    /// revalidation's deadline and hedge delay derive from this alone, and
    /// take `LivenessTiming`'s patient defaults until one is observed.
    var lastRevalidateLatency: Duration?
    /// The dial the run loop is waiting on, so `redialNow()` can cancel one
    /// a network change left stuck. `afterRedial`: it started after a
    /// redial, with the link already known to be back, so a later redial
    /// leaves it alone.
    private var dialInFlight:
        (id: UInt64, afterRedial: Bool, task: Task<SharedTransport, any Error>)?
    private var nextDialID: UInt64 = 0
    /// A `redialNow()` came since the last dial started: the next dial is
    /// the redial's own. Cleared once the events channel is live.
    private var redialSinceLastDial = false
    /// Set when `redialNow()` cancelled the dial in flight: the run loop
    /// dials again at once instead of treating the cancellation as a
    /// failure.
    private var redialRequested = false
    /// A new connection's Transport between its dial and its `ping`: already
    /// offered to terminals (attach first), not yet to RPCs, the events
    /// channel or `terminalTransportGenerations`. Closed with the activation
    /// like `currentTransport`.
    var provisional: ProvisionalTransport?
    /// Monotonic identity for the installed, ping-proven Transport.
    /// Subscription-only reconnects reuse the same Transport and therefore do
    /// not advance it.
    private(set) var transportGeneration: UInt64 = 0
    /// The generation most recently reserved for a new connection
    /// (`reserveTransportGeneration`). A connection whose `ping` fails
    /// burns its reservation, so terminals that rode it never share a
    /// generation with the next one.
    var reservedTransportGeneration: UInt64 = 0
    var hasReservedTransportGeneration = false
    /// Set when the connection can no longer be trusted even though it may
    /// still look alive (a timed-out request or keepalive ping): the next
    /// reconnect replaces the transport instead of reusing it.
    var transportSuspect = false
    /// The keepalive failure that forced the current teardown, surfaced in
    /// the following `.reconnecting` status.
    private var pendingKeepaliveFailure: TransportError?
    /// The most recent proof the connection is alive: the connect-path ping,
    /// a successful RPC through `withTransport`, an arriving event, or an
    /// answered keepalive. The keepalive loop skips its ping while this is
    /// fresher than its interval (see `KeepalivePolicy.interval`).
    private var lastConnectionActivity: ContinuousClock.Instant?
    /// Set while `updateSubscriptions` tears the live channel down on
    /// purpose: the run loop then re-subscribes immediately — same
    /// connection, no backoff, no `.reconnecting` — instead of treating the
    /// graceful stream end as a failure.
    var resubscribeRequested = false
    /// Whether `subscriptions` is a seed — derived from a cached snapshot
    /// (#105) rather than a live one on this connection — that no
    /// subscribe has accepted yet. Any rejection of a seed falls back to the
    /// global set once, like `pane_not_found` always does.
    private var subscriptionsAreSeeded = true
    private var liveStream: HerdrEventStream?
    /// Identifies the current activation so a cancelled connection attempt
    /// cannot install itself after a later resume has already started.
    var activationGeneration: UInt64 = 0
    private var runTask: Task<Void, Never>?
    #if DEBUG
        var runTaskForTesting: Task<Void, Never>? { runTask }
    #endif
    private var keepaliveTask: Task<Void, Never>?
    private var backoffSleep: Task<Void, any Error>?
    private var backoffGeneration: UInt64?
    /// The most recently enqueued lifecycle transition; each new one chains
    /// behind it, so transitions never interleave across the suspension
    /// points inside a teardown (see the actor doc).
    private var lifecycleTransition: Task<Void, Never>?
    /// Each target has one owner, with at most five live PTYs per Host.
    /// A permit spans the operation and explicit channel teardown.
    private var terminalsInUse: Set<TerminalAttachTarget?> = []
    private var terminalWaiters: [TerminalWaiter] = []
    private var terminalIdleWaiters: [CheckedContinuation<Void, Never>] = []
    private var terminalTransportWaiters: [TerminalTransportWaiter] = []
    /// `withTransport` callers waiting for a Transport an active run loop is
    /// installing (a silent replacement — no status change, unlike the
    /// `.reconnecting` cycles).
    private var transportWaiters: [TransportWaiter] = []
    /// An action-required connection failure is sticky until the user starts a
    /// new activation. Requests arriving after the failed run must receive the
    /// real failure instead of waiting for work that no longer exists.
    private var terminalTransportFailure: TransportError?
    private var isWindingDown = false
    /// Virtual sessions must not report fixture activity as network usage.
    private let recordsNetworkTelemetry: Bool

    /// A session whose every connection comes from `connect`, unshared:
    /// nothing is kept across a suspension or replaced by a hedge.
    init(
        subscriptions: [EventSubscription],
        connect: @escaping @Sendable () async throws -> any Transport,
        reconnectPolicy: ReconnectPolicy = .default,
        keepalive: KeepalivePolicy? = .default,
        updatesBufferLimit: Int = HerdrEventStream.bufferLimit,
        terminalWaiterDidRegister: (@Sendable () -> Void)? = nil,
        connectionMemory: (any HostConnectionMemory)? = nil,
        clock: LivenessClock = .continuous,
        recordsNetworkTelemetry: Bool = true
    ) {
        self.init(
            subscriptions: subscriptions,
            connection: .unshared(connect),
            reconnectPolicy: reconnectPolicy,
            keepalive: keepalive,
            updatesBufferLimit: updatesBufferLimit,
            terminalWaiterDidRegister: terminalWaiterDidRegister,
            connectionMemory: connectionMemory,
            clock: clock,
            recordsNetworkTelemetry: recordsNetworkTelemetry)
    }

    init(
        subscriptions: [EventSubscription],
        connection: SharedConnection,
        reconnectPolicy: ReconnectPolicy = .default,
        keepalive: KeepalivePolicy? = .default,
        updatesBufferLimit: Int = HerdrEventStream.bufferLimit,
        terminalWaiterDidRegister: (@Sendable () -> Void)? = nil,
        connectionMemory: (any HostConnectionMemory)? = nil,
        clock: LivenessClock = .continuous,
        recordsNetworkTelemetry: Bool = true
    ) {
        self.subscriptions = subscriptions
        sharing = connection
        self.clock = clock
        self.reconnectPolicy = reconnectPolicy
        self.keepalive = keepalive
        self.terminalWaiterDidRegister = terminalWaiterDidRegister
        self.connectionMemory = connectionMemory
        self.recordsNetworkTelemetry = recordsNetworkTelemetry
        // Bounded (#22): dropping is safe because every drop is surfaced
        // through `yieldUpdate`'s marker; see the actor doc for the policy
        // and HerdrEventStream.bufferLimit for the sizing rationale.
        (updates, updatesContinuation) = AsyncStream.makeStream(
            of: EventsSessionUpdate.self,
            bufferingPolicy: .bufferingNewest(updatesBufferLimit))
        (latencyUpdates, latencyContinuation) = AsyncStream.makeStream(
            of: Duration.self,
            bufferingPolicy: .bufferingNewest(1))
        (terminalTransportGenerations, terminalTransportContinuation) =
            AsyncStream.makeStream(
                of: UInt64.self,
                bufferingPolicy: .bufferingNewest(1))
    }

    /// Activates the session (initially, or after `suspend()`): announces
    /// `.connecting` immediately, then establishes the transport and
    /// channel, emitting `.connected` on success and `.reconnecting` for
    /// automatic retry iterations. Returns once any in-flight teardown has
    /// finished and the activation is underway. No-op while active or ended.
    ///
    /// `seed` replaces the subscription set the activation subscribes with
    /// first (#105): the set the consumer derives from its last-known
    /// snapshot, so the resync after `.connected` finds it already in force
    /// and needs no second subscribe. A seed is no proof — any rejection of
    /// it falls back to the global set at once (see `run`). Ignored unless
    /// this call activates the session.
    func resume(seeding seed: [EventSubscription]? = nil) async {
        await enqueueLifecycleTransition { await self.activate(seeding: seed) }
    }

    /// Restarts an active session whose reconnect loop stopped on a
    /// non-retryable failure. Also provides an explicit retry for a currently
    /// reconnecting session after the user changes Host settings.
    func retry() async {
        await enqueueLifecycleTransition { await self.restart() }
    }

    /// Re-proves a session that believes it is still connected, and reports
    /// the truth either way.
    ///
    /// Nothing in this actor's own machinery asks a live connection whether
    /// it survived the app being suspended: the reconnect loop is parked on
    /// the events stream, which a frozen socket never ends, and the keepalive
    /// only speaks up on its own schedule. Foregrounding is the moment to
    /// ask, because that is the moment a user is looking at whatever the
    /// answer means. A failed ping goes down the keepalive's own path, so the
    /// session drops into the ordinary visible `.reconnecting` sequence
    /// instead of sitting on a dead link.
    ///
    /// Every failure class is reported, not just the timeout a hung socket
    /// produces: post-#138 a severed link classifies as `.sshUnreachable`, and
    /// a herdr that stopped while the app was away classifies as the
    /// non-retryable `.streamLocalOpenFailed` / `.herdrNotRunning` /
    /// `.socketNotFound` (nothing starts it but the user's Start Herdr TUI), which
    /// correctly takes the Host to `.failed` with its setup guidance rather
    /// than retrying something no retry can fix.
    ///
    /// The ping is a liveness check under `LivenessTiming.deadline`, not
    /// the RPC budget (#105). On a pooled connection it is hedged: once it
    /// goes unanswered for `LivenessTiming.hedgeDelay`, or fails on the
    /// link, a fresh connection is dialed beside it. Whichever proves itself
    /// first stands. A replacement that wins is installed under a new
    /// generation, the events channel re-subscribes on it without a
    /// `.reconnecting`, and the connection that lost is retired and closed.
    /// The Console runs this on every foreground return and every network
    /// path change.
    ///
    /// No-op unless a channel is actually live: a suspended session is
    /// `resume()`'s business, and one already reconnecting is visibly working
    /// on it. `trigger` is what asked, for the report of a hedge that wins.
    func revalidate(after trigger: NetworkAnalytics.ConnectTrigger = .foreground) async {
        guard
            phase == .active,
            let stream = liveStream,
            let transport = currentTransport
        else { return }
        let connection = currentConnection
        let clock = clock
        let interval = NetworkInterval("revalidate")
        let outcome: LivenessRace.Outcome<(latency: Duration, info: ServerInfo), Replacement>
        do {
            outcome = try await LivenessRace.run(
                deadline: LivenessTiming.deadline(roundTrip: lastRevalidateLatency),
                clock: clock,
                proof: { try await Self.measure(transport, revalidating: true, now: clock.now) },
                hedge: connection.map {
                    replacementHedge(replacing: $0, roundTrip: lastRevalidateLatency)
                })
        } catch is CancellationError {
            interval.end("cancelled")
            return
        } catch TransportError.cancelled {
            interval.end("cancelled")
            return
        } catch {
            interval.end(NetworkAnalytics.Failure(error).rawValue)
            await keepaliveDidFail(Self.transportFailure(error), on: stream)
            return
        }
        switch outcome {
        case .proof(let measured):
            interval.end("kept")
            lastRevalidateLatency = measured.latency
            guard publishLatency(measured.latency, measuredOn: stream) else { return }
            noteConnectionActivity()
        case .hedge(let replacement):
            let elapsed = interval.end("hedge")
            reportConnect(
                HostConnectReport(
                    outcome: .success, duration: elapsed, path: .hedge, trigger: trigger))
            await adopt(replacement, replacing: transport, on: stream)
        }
    }

    /// Re-measures the badge on demand (#134): one plain herdr `ping` under
    /// the keepalive's liveness deadline (`LivenessTiming.deadline`), timed
    /// and published through the same stale-stream gate as `revalidate()`'s.
    /// The Hosts sheet calls it on its own cadence while it is visible. It
    /// is no liveness race: nothing is hedged or replaced, and it never goes
    /// through `HostConsoleProjection.revalidate()`, so a `.failed` session
    /// is not retried by it. A failed ping goes down the keepalive's path.
    /// It runs at the caller's SSH priority, `.normal` from the sheet, so it
    /// queues behind terminal work. No-op unless a channel is live; a live
    /// channel's install was itself ping-proven or is being proven by this
    /// ping, so only a proven connection publishes a value.
    ///
    /// Returns whether the ping proved the session's live channel: false
    /// when nothing was live, the ping failed, or the channel it answered on
    /// was replaced meanwhile.
    @discardableResult
    func sampleLatency() async -> Bool {
        guard
            phase == .active,
            let stream = liveStream,
            let transport = currentTransport
        else { return false }
        do {
            let clock = clock
            let measured = try await LivenessRace.withDeadline(
                LivenessTiming.deadline(roundTrip: lastRoundTrip), clock: clock
            ) {
                try await Self.measure(transport, revalidating: false, now: clock.now)
            }
            lastRoundTrip = measured.latency
            guard publishLatency(measured.latency, measuredOn: stream) else { return false }
            noteConnectionActivity()
            return true
        } catch is CancellationError {
        } catch TransportError.cancelled {
        } catch {
            await keepaliveDidFail(Self.transportFailure(error), on: stream)
        }
        return false
    }

    /// Quiesces the session for backgrounding: ends the events channel and
    /// the keepalive, closes the Transport (with every channel it holds) and
    /// stops all reconnect activity, but keeps the pooled SSH connection the
    /// Transport rode open for the return to probe (#105). Without a pooled
    /// connection, the connection closes too. No-op unless active.
    ///
    /// `locally` is for a suspension with no background time left (the
    /// expiration path): nothing here waits on the network then. The
    /// closes run on their own, and terminals are not waited for. Otherwise
    /// this returns once everything is down.
    func suspend(locally: Bool = false) async {
        await enqueueLifecycleTransition { await self.deactivate(locally: locally) }
    }

    /// The link is shown to be back (#105): a network path after none, or a
    /// mosh server answering after a stall. A reconnect waiting out its
    /// backoff dials now. A dial started before that, possibly still
    /// retrying its SYN where there was no path, is cancelled and dialed
    /// again; later connects no longer join it. A dial an earlier redial
    /// started is left alone: it already rides the link that came back, and
    /// the path-return and mosh-recovery signals for one recovery would
    /// otherwise cancel each other's fresh dial. No-op while the events
    /// channel is live (`revalidate()` covers that) and while inactive.
    /// `trigger` labels the connect this sets off.
    func redialNow(trigger: NetworkAnalytics.ConnectTrigger) async {
        guard phase == .active, !isWindingDown, liveStream == nil else { return }
        if dialInFlight?.afterRedial == true { return }
        connectTrigger = trigger
        redialSinceLastDial = true
        if let stuck = dialInFlight {
            redialRequested = true
            await sharing.abandonDial()
            if dialInFlight?.id == stuck.id { stuck.task.cancel() }
        }
        backoffSleep?.cancel()
    }

    /// Terminal teardown: like `suspend()`, then finishes `updates` for
    /// good. Idempotent.
    func end() async {
        await enqueueLifecycleTransition { await self.finish() }
    }

    /// Replaces the subscription set. Needed because pane-scoped kinds
    /// (`pane.agent_status_changed`) subscribe per pane id, and panes come
    /// and go. While the channel is live it is ended by explicit close and
    /// re-subscribed immediately on the same connection; the fresh
    /// `.connected` that follows is the consumer's usual re-snapshot signal,
    /// so anything missed in the gap rides the normal snapshot-then-delta
    /// path. While suspended or between reconnects the new set simply takes
    /// effect on the next subscribe. No-op when the set is unchanged.
    ///
    /// Pane-scoped entries survive only as long as the subscription that
    /// carries them: any disconnect drops them (see `dropSnapshotSubscriptions`),
    /// so callers must reinstall the set after every `.connected` rather than
    /// assume the last one is still in force.
    func updateSubscriptions(_ subscriptions: [EventSubscription]) async {
        guard self.subscriptions != subscriptions else { return }
        self.subscriptions = subscriptions
        subscriptionsAreSeeded = false
        guard phase == .active, let stream = liveStream else { return }
        resubscribeRequested = true
        await stream.end()
    }

    /// Runs an ordinary RPC against the currently installed Transport.
    /// Calls are intentionally concurrent; the Transport owns its channel
    /// budget. The Transport value never becomes caller-owned state.
    ///
    /// A Transport the run loop is replacing (a subscription reinstall that
    /// found the connection degraded) must not fail every Host-scoped RPC
    /// while the status still claims `.connected`: callers wait for the next
    /// installed Transport, the same grace `withTerminalTransport` has. Every
    /// run-loop exit path — a `.reconnecting`/`.failed` announcement, or
    /// windDown — releases that wait with the real failure, so a suspended,
    /// stopped, or user-retryable Host still fails loudly and at once.
    ///
    /// `retryOnLinkFailure: false` is for calls that must not be replayed:
    /// a link failure cannot say whether herdr already received the request,
    /// so resending a submitted shell command or Agent prompt could run it
    /// twice. Such a call still distrusts the dead link (the next call rides
    /// the replacement) but surfaces the failure for a deliberate resend.
    func withTransport<Value: Sendable>(
        retryOnLinkFailure: Bool = true,
        _ operation: @escaping @Sendable (any Transport) async throws -> Value
    ) async throws -> Value {
        let transport = try await awaitUsableTransport()
        do {
            let value = try await operation(transport)
            noteConnectionActivity()
            return value
        } catch {
            // A degraded SSH link can sit installed-but-dead until the run
            // loop's own traffic notices. A caller that hit it first does
            // what the keepalive does — distrust the transport, let the run
            // loop redial, and retry once on the replacement. Retrying only
            // while this transport is still the installed one keeps a raced
            // replacement from double-failing a caller, and server answers
            // (API rejections) are never retried.
            guard Self.isTransportLinkFailure(error) else {
                throw error
            }
            // A replacement may already be in flight (currentTransport nil)
            // or a fresher transport may have been installed since; either
            // way the single retry rides whatever is current. It is also
            // bounded: an operation that exhausts its own deadline on the
            // replacement surfaces that cause instead of a second full
            // wait, and a failing redial releases the waiter through the
            // run loop's announce with its real cause.
            if isSameTransport(currentTransport, transport) {
                transportSuspect = true
                currentTransport = nil
                currentConnection = nil
                // Dropped without `close()`, since Terminals may still use
                // it; it gives up what its replacement on the same
                // connection waits for (tmux's control slot). Detached, so
                // the redial below never waits on it. herdr's is a no-op.
                Task { await transport.transportDistrusted() }
                // The run loop is parked on the live stream and cannot act on
                // the suspect mark by itself: a link whose events reader is
                // still alive never ends the stream, and with the keepalive
                // quiet or disabled nothing else wakes it — the retry below
                // would wait forever. End the channel the way a failed
                // keepalive does, but flagged as a deliberate re-subscribe so
                // the run loop re-dials silently (no `.reconnecting`) and
                // installs the replacement this retry rides. A redial that
                // fails instead releases the waiter through the run loop's
                // announce with its real cause.
                resubscribeRequested = true
                await liveStream?.end()
            }
            guard retryOnLinkFailure else {
                throw error
            }
            let replacement = try await awaitUsableTransport()
            do {
                let value = try await operation(replacement)
                noteConnectionActivity()
                return value
            } catch TransportError.timedOut {
                throw error
            }
        }
    }

    /// Link-level failures worth one redial-and-retry: the SSH connection
    /// itself failed or swallowed the call. Server answers and cancellation
    /// are not retried. An unsent request's cause counts like the bare one.
    static func isTransportLinkFailure(_ error: any Error) -> Bool {
        switch RequestNotSentError.unwrapped(error) as? TransportError {
        case .sshUnreachable, .timedOut: true
        default: false
        }
    }

    func isSameTransport(
        _ a: (any Transport)?, _ b: any Transport
    ) -> Bool {
        guard let a else { return false }
        guard let aObject = a as AnyObject?, let bObject = b as AnyObject? else {
            return false
        }
        return ObjectIdentifier(aObject) == ObjectIdentifier(bObject)
    }

    /// The installed Transport, or — while the active run loop is
    /// establishing one — the next Transport it installs.
    private func awaitUsableTransport() async throws -> any Transport {
        if let terminalTransportFailure { throw terminalTransportFailure }
        if let transport = currentTransport { return transport }
        guard phase == .active, !isWindingDown, runTask != nil else {
            throw TransportError.sshUnreachable(detail: "The Host is not connected.")
        }
        let id = UUID()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<any Transport, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let transport = currentTransport {
                    continuation.resume(returning: transport)
                } else {
                    transportWaiters.append(
                        TransportWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelTransportWaiter(id: id) }
        }
    }

    /// Runs one terminal lifetime with exclusive access to its target.
    /// A second caller for that target waits until teardown returns. A caller
    /// that races foreground recovery waits for this activation's next
    /// Transport instead of failing only because installation is still in
    /// flight. Attach comes first (#105): a new connection is handed over as
    /// soon as it is authenticated and its socket path known, so neither its
    /// `ping` nor events subscription and snapshot work are prerequisites.
    /// `operation` gets the generation the connection is published under
    /// once its `ping` proves it. A connection whose `ping` fails instead is
    /// closed, ending the terminal riding it, and this throws that failure
    /// rather than reporting an ordinary end; the caller decides whether to
    /// try again.
    func withTerminalTransport<Value: Sendable>(
        target: TerminalAttachTarget? = nil,
        _ operation: @escaping @Sendable (any Transport, UInt64) async throws -> Value
    ) async throws -> Value {
        try await acquireTerminal(target: target)
        do {
            try Task.checkCancellation()
            let ready = try await awaitTerminalTransport()
            try Task.checkCancellation()
            guard terminalTransportIsCurrent(ready) else {
                throw TransportError.cancelled
            }
            let value: Value
            do {
                // A terminal is what the user is waiting on: its channel
                // open, PTY request and exec go ahead of queued background
                // work on the shared SSH connection (#105, C-PRIORITY).
                value = try await SSHOperationPriority.$current.withValue(.interactive) {
                    try await operation(ready.transport, ready.transportGeneration)
                }
            } catch let error as CancellationError {
                throw error
            } catch {
                if let rejection = ready.rejection?.failure { throw rejection }
                throw error
            }
            if let rejection = ready.rejection?.failure { throw rejection }
            noteConnectionActivity()
            releaseTerminal(target: target)
            return value
        } catch {
            releaseTerminal(target: target)
            throw error
        }
    }

    /// Every activation announces `.connecting` synchronously before `run`
    /// is spawned — a first dial, a return from Suspended, and a Reconnect
    /// Request from Connected, Reconnecting or Failed alike. Automatic
    /// iterations inside this activation stay `.reconnecting`.
    private func activate(
        seeding seed: [EventSubscription]? = nil,
        trigger: NetworkAnalytics.ConnectTrigger? = nil
    ) {
        guard phase == .suspended else { return }
        phase = .active
        connectTrigger = trigger ?? (hasActivated ? .foreground : .launch)
        hasActivated = true
        if let seed {
            subscriptions = seed
            subscriptionsAreSeeded = true
        }
        terminalTransportFailure = nil
        redialSinceLastDial = false
        activationGeneration &+= 1
        let generation = activationGeneration
        yieldUpdate(.status(.connecting))
        runTask = Task { await self.run(generation: generation) }
    }

    /// Restarts the current activation. `.connecting` is announced and the
    /// generation advances before teardown, so a consumer never observes the
    /// previous `.connected` against a Transport that `windDown` has already
    /// removed. The old `run` sees the generation change and cannot install
    /// a Transport into this activation.
    private func restart() async {
        guard phase == .active else {
            activate(trigger: .retry)
            return
        }
        activationGeneration &+= 1
        let generation = activationGeneration
        connectTrigger = .retry
        yieldUpdate(.status(.connecting))
        await windDown()
        guard phase == .active, activationGeneration == generation else { return }
        runTask = Task { await self.run(generation: generation) }
    }

    private func deactivate(locally: Bool) async {
        guard phase == .active else { return }
        phase = .suspended
        settleLoss(recovered: false)
        await keepConnectionAcrossSuspension()
        await windDown(locally: locally)
        yieldUpdate(.status(.suspended))
    }

    /// Holds the installed, trusted connection open before `windDown`
    /// closes the Transport on it (#105), so the next activation can probe
    /// it instead of dialing. A pool hop: no network.
    private func keepConnectionAcrossSuspension() async {
        guard currentTransport != nil, !transportSuspect, let connection = currentConnection,
            await sharing.keep(connection)
        else { return }
        if let previous = keptConnection, previous.id != connection {
            await sharing.release(previous.id)
        }
        keptConnection = KeptConnection(id: connection, since: clock.now())
    }

    private func finish() async {
        guard phase != .ended else { return }
        phase = .ended
        settleLoss(recovered: false)
        await windDown()
        if let kept = keptConnection {
            keptConnection = nil
            await sharing.release(kept.id)
        }
        yieldUpdate(.status(.ended))
        updatesContinuation.finish()
        latencyContinuation.finish()
        terminalTransportContinuation.finish()
    }

    /// The single gate every update leaves through: yields it and, when the
    /// bounded buffer sheds something to make room, follows up with the drop
    /// marker. One marker covers every update shed before it; a marker that
    /// is later shed itself lands right back here and is re-armed (see
    /// `HerdrEvent.eventsDropped`).
    private func yieldUpdate(_ update: EventsSessionUpdate) {
        // Ordered before the yield, so no consumer can observe a status that
        // ends a connection while `currentLatency` still holds that
        // connection's measurement.
        if case .status(let status) = update, status != .connected {
            latencyBox.withLock { $0 = nil }
        }
        guard case .dropped = updatesContinuation.yield(update) else { return }
        droppedUpdateCount += 1
        if case .dropped = updatesContinuation.yield(.event(.eventsDropped)) {
            droppedUpdateCount += 1
        }
    }

    /// Chains `transition` behind the previously enqueued one and waits for
    /// it. Enqueueing is synchronous on the actor, so the chain order is the
    /// call order and no transition ever observes another one mid-teardown.
    private func enqueueLifecycleTransition(
        _ transition: @escaping @Sendable () async -> Void
    ) async {
        let previous = lifecycleTransition
        let task = Task {
            await previous?.value
            await transition()
        }
        lifecycleTransition = task
        await task.value
    }

    // MARK: Reconnect loop

    /// One activation's lifetime: connect/subscribe, stream, and reconnect
    /// with bounded backoff, until the phase or generation changes. A stale
    /// run may outlive suspend while an SSH bridge ignores cancellation, but
    /// it can never install a Transport into a newer activation.
    private func run(generation: UInt64) async {
        var attempt = 0
        while activationIsCurrent(generation) {
            let stream: HerdrEventStream
            do {
                let (transport, early) = try await ensureTransport(for: generation)
                guard activationIsCurrent(generation) else {
                    if let early { Self.discard(early.stream) }
                    break
                }
                if let early {
                    let earlyStream = try await early.stream.value
                    // The set changed while the early subscribe was in
                    // flight: replace it on the same connection.
                    guard early.subscriptions == subscriptions else {
                        await earlyStream.end()
                        continue
                    }
                    stream = earlyStream
                } else {
                    let requested = subscriptions
                    stream = try await Self.subscribe(transport, requested)
                    guard requested == subscriptions else {
                        await stream.end()
                        continue
                    }
                }
                // An RPC may have distrusted this connection while the
                // subscribe was in flight; its stream cannot make it live again.
                guard isSameTransport(currentTransport, transport), !transportSuspect else {
                    if activationIsCurrent(generation) { resubscribeRequested = false }
                    await stream.end()
                    continue
                }
            } catch {
                guard activationIsCurrent(generation) else { break }
                if redialRequested {
                    // `redialNow()` cancelled a dial the network change left
                    // stuck: dial again at once, with no backoff and no
                    // `.reconnecting`.
                    redialRequested = false
                    continue
                }
                let failure = Self.transportFailure(error)
                if failure == .timedOut {
                    // The connection swallowed a request whole; do not trust
                    // it for the retry even if it still looks alive.
                    transportSuspect = true
                }
                // A pane that exited between the snapshot behind this
                // subscription set and this subscribe is an ordinary race,
                // not a connection problem: retry it straight away with the
                // global set rather than showing the user a failure. A set
                // seeded from a cached snapshot (#105) may also name an event
                // kind this server no longer speaks, so any rejection of a
                // seeded set gets the same one retry.
                if Self.namesAMissingPane(failure)
                    || (subscriptionsAreSeeded && Self.isRejection(failure)),
                    dropSnapshotSubscriptions()
                {
                    continue
                }
                guard failure.isRetryable else {
                    recordTerminalTransportFailure(failure)
                    failTerminalTransportWaiters(failure, for: generation)
                    failTransportWaiters(failure)
                    yieldUpdate(.status(.failed(failure)))
                    settleLoss(recovered: false)
                    return
                }
                failTransportWaiters(failure)
                dropSnapshotSubscriptions()
                attempt += 1
                connectTrigger = .retry
                await emitReconnectingAndBackOff(
                    attempt: attempt, failure: failure, generation: generation)
                continue
            }
            subscriptionsAreSeeded = false
            if !activationIsCurrent(generation) {
                await stream.end()
                break
            }
            liveStream = stream
            redialSinceLastDial = false
            attempt = 0
            pendingKeepaliveFailure = nil
            yieldUpdate(.status(.connected))
            settleLoss(recovered: true)
            startKeepalive(stream: stream)

            var streamFailure: TransportError?
            do {
                for try await event in stream.events {
                    // Teardown cancels this task but deliberately does not
                    // await it (see `windDown`), and a channel closed with
                    // events still buffered delivers them before finishing.
                    // Without this check those late events would be yielded
                    // *after* the terminal `.suspended`/`.ended` status and,
                    // under a full bounded buffer, shed it — breaking the
                    // guarantee that a terminal transition is the last thing
                    // the consumer sees. Discarding them is safe: `.suspended`
                    // already declares everything since the last `.connected`
                    // stale, and the `.connected` that follows a resume
                    // obliges a fresh snapshot anyway.
                    guard activationIsCurrent(generation) else { break }
                    noteConnectionActivity()
                    yieldUpdate(.event(event))
                }
                // Graceful finish: the channel was ended explicitly, by
                // suspend()/end() or by a failed keepalive.
            } catch {
                streamFailure = Self.transportFailure(error)
            }
            if liveStream === stream {
                stopKeepalive()
                liveStream = nil
            }
            guard activationIsCurrent(generation) else { break }
            if resubscribeRequested {
                // Deliberate teardown by updateSubscriptions: re-subscribe
                // right away (the connection is still trusted), even if the
                // stream happened to die on its own in the same instant —
                // the subscribe path re-checks the connection anyway.
                resubscribeRequested = false
                continue
            }
            let failure =
                pendingKeepaliveFailure ?? streamFailure
                ?? .channelFailed(detail: "events stream ended unexpectedly")
            pendingKeepaliveFailure = nil
            noteLoss(failure)
            guard failure.isRetryable else {
                recordTerminalTransportFailure(failure)
                failTerminalTransportWaiters(failure, for: generation)
                failTransportWaiters(failure)
                yieldUpdate(.status(.failed(failure)))
                settleLoss(recovered: false)
                return
            }
            failTransportWaiters(failure)
            dropSnapshotSubscriptions()
            attempt += 1
            connectTrigger = .retry
            await emitReconnectingAndBackOff(
                attempt: attempt, failure: failure, generation: generation)
        }
    }

    /// Discards snapshot-derived subscriptions, keeping baseline global ones.
    /// workspace.reordered requires protocol 19; a new connection must prove
    /// that capability again before it is included alongside its Pane set.
    /// Returns whether the set actually changed.
    ///
    /// Pane-scoped entries are derived from a snapshot, and herdr rejects an
    /// entire `events.subscribe` when a single one names a pane that has
    /// exited (verified against 0.7.5). Keeping them across a disconnect
    /// would let one dead pane wedge the Host offline permanently, because
    /// the reconnect loop would resend the same doomed set forever and the
    /// `.connected` that refreshes it would never arrive. Every `.connected`
    /// already obliges the consumer to re-snapshot, and that resync
    /// reinstalls the pane set through `updateSubscriptions`.
    @discardableResult
    private func dropSnapshotSubscriptions() -> Bool {
        subscriptionsAreSeeded = false
        let globalsOnly = subscriptions.filter { subscription in
            switch subscription {
            case .global(.workspaceReordered), .pane: false
            case .global: true
            }
        }
        guard globalsOnly.count != subscriptions.count else { return false }
        subscriptions = globalsOnly
        return true
    }

    private static func namesAMissingPane(_ failure: TransportError) -> Bool {
        guard case .apiRejected(let code, _) = failure else { return false }
        return code == "pane_not_found"
    }

    private static func isRejection(_ failure: TransportError) -> Bool {
        guard case .apiRejected = failure else { return false }
        return true
    }

    /// The Host's live transport: reuses the current one while its SSH
    /// connection is alive and trusted, otherwise closes it and establishes
    /// a fresh one — pinged first, as on every new connection path. A fresh
    /// one is offered to terminals before the ping (attach first, #105) and
    /// installed for RPCs and the events channel, and published as a new
    /// generation, after it. With a protocol remembered at or above the
    /// floor, the first events subscribe starts alongside the ping and is
    /// returned for `run` to finish.
    ///
    /// After a suspension that kept the pooled connection (#105), the Host
    /// is reached through that connection instead (`resumeKept`), unless it
    /// was kept for longer than `LivenessTiming.keptConnectionMaxAge`: then
    /// it is retired unprobed and the Host dialed anew.
    private func ensureTransport(
        for generation: UInt64
    ) async throws -> (transport: any Transport, early: EarlySubscription?) {
        guard activationIsCurrent(generation) else {
            throw TransportError.cancelled
        }
        if let transport = currentTransport {
            if !transportSuspect, await transport.isConnected {
                return (transport, nil)
            }
            guard activationIsCurrent(generation) else {
                throw TransportError.cancelled
            }
            if isSameTransport(currentTransport, transport) {
                currentTransport = nil
                currentConnection = nil
            }
            try? await transport.close()
        }
        let attempt = NetworkInterval("connect")
        let trigger = connectTrigger
        var path = NetworkAnalytics.ConnectPath.fresh
        do {
            let established: (transport: any Transport, early: EarlySubscription?)
            if let kept = await takeKeptConnection() {
                path = .kept
                let resumed = try await resumeKept(kept, for: generation)
                path = resumed.path
                established = (resumed.transport, resumed.early)
            } else {
                established = try await dialFresh(for: generation)
            }
            let elapsed = attempt.end(path.rawValue)
            reportConnect(
                HostConnectReport(outcome: .success, duration: elapsed, path: path, trigger: trigger))
            return established
        } catch {
            let failure = NetworkAnalytics.Failure(error)
            let elapsed = attempt.end("\(path.rawValue) \(failure.rawValue)")
            if failure != .cancelled {
                reportConnect(
                    HostConnectReport(
                        outcome: .failure(failure), duration: elapsed, path: path, trigger: trigger))
            }
            throw error
        }
    }

    /// Installs a new connection its `ping` proved, under the generation
    /// terminals already ride it with: the one path by which a proven
    /// connection becomes current.
    func installProven(
        _ transport: any Transport, on connection: SharedConnection.ID?, generation: UInt64,
        latency: Duration, info: ServerInfo
    ) {
        lastRoundTrip = latency
        // herdr's protocol number only: tmux reports none and herdr-core's
        // generation is no herdr protocol.
        if info.backend == .herdr {
            connectionMemory?.rememberProtocolVersion(info.protocolVersion)
        }
        publishLatency(latency)
        provisional = nil
        transportSuspect = false
        terminalTransportFailure = nil
        noteConnectionActivity()
        currentTransport = transport
        currentConnection = connection
        transportGeneration = generation
        terminalTransportContinuation.yield(transportGeneration)
        resumeTransportWaiters(with: transport)
    }

    /// A server that speaks another protocol voids the remembered one, so
    /// the next connection does not subscribe alongside its ping.
    func forgetProtocolVersion(after error: any Error) {
        if case TransportError.protocolVersionMismatch = error {
            connectionMemory?.rememberProtocolVersion(nil)
        }
    }

    /// `sharing.connect` for the run loop, cancellable by `redialNow()`.
    func dial() async throws -> SharedTransport {
        let sharing = sharing
        let task = Task { try await sharing.connect(nil) }
        nextDialID &+= 1
        let id = nextDialID
        dialInFlight = (id, redialSinceLastDial, task)
        redialSinceLastDial = false
        defer {
            if dialInFlight?.id == id { dialInFlight = nil }
        }
        let connected = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        redialRequested = false
        return connected
    }

    func activationIsCurrent(_ generation: UInt64) -> Bool {
        phase == .active && activationGeneration == generation && !Task.isCancelled
    }

    private func emitReconnectingAndBackOff(
        attempt: Int,
        failure: TransportError,
        generation: UInt64
    ) async {
        let delay = reconnectPolicy.delay(beforeAttempt: attempt)
        yieldUpdate(.status(.reconnecting(attempt: attempt, delay: delay, failure: failure)))
        let sleep = Task { try await Task.sleep(for: delay) }
        backoffSleep = sleep
        backoffGeneration = generation
        try? await sleep.value
        if backoffGeneration == generation {
            backoffSleep = nil
            backoffGeneration = nil
        }
    }

    /// Ends the current activation and closes everything. The run task is
    /// cancelled but deliberately not awaited: a stalled SSH operation may
    /// ignore task cancellation. Generation checks
    /// make any late result harmless, while an installed Transport is still
    /// closed explicitly before lifecycle teardown returns.
    ///
    /// `locally` (a suspension with no background time, #105) waits on
    /// nothing the network decides: the closes run on their own, in the
    /// same order, and terminals are not waited for.
    private func windDown(locally: Bool = false) async {
        isWindingDown = true
        failTerminalTransportWaiters(TransportError.cancelled)
        failTransportWaiters(TransportError.cancelled)
        backoffSleep?.cancel()
        backoffSleep = nil
        backoffGeneration = nil
        stopKeepalive()
        let task = runTask
        runTask = nil
        task?.cancel()
        let stream = liveStream
        liveStream = nil
        let transport = currentTransport
        currentTransport = nil
        currentConnection = nil
        // A connection still awaiting its ping may carry terminals already
        // (attach first): closing it ends them, so the wait below cannot
        // hang on a ping that ignores cancellation.
        let provisionalTransport = provisional?.transport
        provisional = nil
        // End the events channel before closing the transport it rides on.
        // Otherwise close can queue behind the still-running reader on the
        // same SSH session and turn a bounded teardown into an unbounded one.
        let closeAll: @Sendable () async -> Void = {
            await stream?.end()
            try? await transport?.close()
            try? await provisionalTransport?.close()
        }
        if locally {
            Task { await closeAll() }
        } else {
            await closeAll()
            await waitForTerminalIdle()
        }
        transportSuspect = false
        pendingKeepaliveFailure = nil
        resubscribeRequested = false
        redialRequested = false
        lastConnectionActivity = nil
        terminalTransportFailure = nil
        dropSnapshotSubscriptions()
        isWindingDown = false
    }

    // MARK: Keepalive

    private func startKeepalive(stream: HerdrEventStream) {
        guard let keepalive, let transport = currentTransport else { return }
        keepaliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: keepalive.interval)
                if Task.isCancelled { break }
                guard self.connectionIsIdle(within: keepalive.interval) else { continue }
                do {
                    try await self.proveLiveness(on: transport)
                    // A ping answered after this channel was replaced also
                    // means this loop is keeping a connection alive that the
                    // session no longer has. It proves liveness either way;
                    // see `KeepalivePolicy.interval` for why it does not
                    // republish the latency badge.
                    guard self.isLiveStream(stream) else { break }
                    self.noteConnectionActivity()
                } catch is CancellationError {
                    break
                } catch TransportError.cancelled {
                    break
                } catch {
                    await self.keepaliveDidFail(Self.transportFailure(error), on: stream)
                    break
                }
            }
        }
    }

    func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    private func noteConnectionActivity() {
        lastConnectionActivity = .now
    }

    /// Whether `stream` is still this session's live channel — the same
    /// staleness check `publishLatency(_:measuredOn:)` gates on, shared so
    /// the keepalive loop can prove liveness and detect a replaced channel
    /// without publishing a value through it (see `KeepalivePolicy.interval`).
    func isLiveStream(_ stream: HerdrEventStream) -> Bool {
        phase == .active && liveStream === stream
    }

    /// Publishes a measurement taken on `stream`, unless that channel is no
    /// longer the session's live one — and reports which it was. The
    /// keepalive loop proves liveness through `isLiveStream` instead, so
    /// `revalidate()` (the foreground re-proof) and `sampleLatency()` (the
    /// Hosts sheet's re-measure) are this overload's only callers.
    ///
    /// Both await their ping, so a concurrent `windDown()` or a
    /// replacement connection can finish while that await is in flight. Such
    /// an answer describes a connection this session no longer has, so
    /// publishing it would resurrect the value the non-connected status
    /// cleared on the way out — and, once a replacement has connected,
    /// overwrite that connection's own proof with the dead one's.
    ///
    /// The connect path has no channel to name yet and does not need one: it
    /// publishes with no suspension point between its activation check and the
    /// write, and any teardown after that clears the value through the status
    /// it publishes.
    private func publishLatency(
        _ latency: Duration, measuredOn stream: HerdrEventStream
    ) -> Bool {
        guard isLiveStream(stream) else { return false }
        publishLatency(latency)
        return true
    }

    /// The single gate every measurement leaves through: the connection-scoped
    /// value first, then the signal. A consumer woken by the signal reads the
    /// value it was woken for or a newer one, never an older one.
    private func publishLatency(_ latency: Duration) {
        latencyBox.withLock { $0 = latency }
        latencyContinuation.yield(latency)
    }

    /// Measures only the herdr `ping` request on a new connection. The
    /// clock starts after `ensureTransport` has awaited the transport's
    /// first-request prerequisites (`awaitSocketPathReadiness()`), and the
    /// dial itself happens before that, so the connection setup and the
    /// socket-path resolution stay off the badge and Hosts remain comparable
    /// across reconnects and authentication methods.
    func measureLatency(
        on transport: any Transport
    ) async throws -> (latency: Duration, info: ServerInfo) {
        let measured = try await Self.measure(transport, revalidating: false, now: clock.now)
        lastRoundTrip = measured.latency
        return measured
    }

    /// One `ping` (`revalidate()` when `revalidating`, the foreground
    /// re-proof) and how long it took.
    static func measure(
        _ transport: any Transport, revalidating: Bool,
        now: @Sendable () -> ContinuousClock.Instant
    ) async throws -> (latency: Duration, info: ServerInfo) {
        let interval = NetworkInterval("ping")
        let started = now()
        do {
            let info = revalidating ? try await transport.revalidate() : try await transport.ping()
            interval.end("answered")
            return (now() - started, info)
        } catch {
            interval.end(NetworkAnalytics.Failure(error).rawValue)
            throw error
        }
    }

    // MARK: Telemetry (#105)

    /// Whether a terminal on `generation` rides the connection kept across
    /// the last suspension.
    func ridesKeptConnection(generation: UInt64) -> Bool {
        keptTransportGeneration == generation
    }

    /// `events.subscribe`, timed.
    static func subscribe(
        _ transport: any Transport, _ subscriptions: [EventSubscription]
    ) async throws -> HerdrEventStream {
        let interval = NetworkInterval("subscribe")
        do {
            let stream = try await transport.subscribeToEvents(subscriptions)
            interval.end("subscribed")
            return stream
        } catch {
            interval.end(NetworkAnalytics.Failure(error).rawValue)
            throw error
        }
    }

    private func reportConnect(_ report: HostConnectReport) {
        guard recordsNetworkTelemetry else { return }
        NetworkLog.logger.notice(
            "host connect \(report.outcome.value, privacy: .public) via \(report.path.rawValue, privacy: .public) after \(report.trigger.rawValue, privacy: .public) in \(report.duration.wholeMilliseconds, privacy: .public) ms"
        )
        NetworkTelemetry.recordDetached(.hostConnected(report))
    }

    /// The live events channel was lost to `failure`. The first loss stands
    /// until it is settled: the reconnects after it recover that one.
    private func noteLoss(_ failure: TransportError) {
        guard recordsNetworkTelemetry else { return }
        let reason = NetworkAnalytics.Failure(failure)
        NetworkLog.logger.notice("ssh transport lost: \(reason.rawValue, privacy: .public)")
        guard pendingLoss == nil else { return }
        pendingLoss = (reason, clock.now())
    }

    /// Reports the pending loss: recovered now, or given up on.
    private func settleLoss(recovered: Bool) {
        guard let loss = pendingLoss else { return }
        pendingLoss = nil
        let elapsed = clock.now() - loss.at
        NetworkLog.logger.notice(
            "ssh transport \(recovered ? "recovered" : "not recovered", privacy: .public) after \(elapsed.wholeMilliseconds, privacy: .public) ms"
        )
        let recovery = recovered ? elapsed : nil
        NetworkTelemetry.recordDetached(
            .transportLost(TransportLossReport(transport: .ssh, reason: loss.reason, recovery: recovery)))
    }

    /// A keepalive ping under the liveness deadline (#105): one the
    /// connection does not answer within `LivenessTiming.deadline` fails as
    /// `.timedOut`, long before the RPC budget would.
    private func proveLiveness(on transport: any Transport) async throws {
        let clock = clock
        let measured = try await LivenessRace.withDeadline(
            LivenessTiming.deadline(roundTrip: lastRoundTrip), clock: clock
        ) {
            try await Self.measure(transport, revalidating: false, now: clock.now)
        }
        lastRoundTrip = measured.latency
    }

    /// Whether no liveness proof arrived within `interval`, meaning the next
    /// keepalive ping is actually needed.
    private func connectionIsIdle(within interval: Duration) -> Bool {
        guard let last = lastConnectionActivity else { return true }
        return ContinuousClock.now - last >= interval
    }

    /// A keepalive ping failed: the connection cannot be trusted. Tears the
    /// stream down by explicit close; the run loop then reconnects with a
    /// fresh transport and surfaces this failure in `.reconnecting`. A link
    /// failure also retires the pooled connection (#105): a liveness
    /// deadline finds it dead before the SSH layer does, and the redial
    /// must not ride it again.
    private func keepaliveDidFail(_ failure: TransportError, on stream: HerdrEventStream) async {
        guard phase == .active, liveStream === stream else { return }
        transportSuspect = true
        pendingKeepaliveFailure = failure
        if Self.isTransportLinkFailure(failure), let connection = currentConnection {
            await sharing.retire(connection)
        }
        await stream.end()
    }

    static func transportFailure(_ error: any Error) -> TransportError {
        if let failure = error as? TransportError {
            return failure
        }
        if let rejection = error as? HerdrAPIError {
            return .apiRejected(code: rejection.code, message: rejection.message)
        }
        if case DeviceKeyStoreError.storedKeyCorrupt = error {
            return .deviceKeyCorrupt
        }
        if case RSAKeyStoreError.storedKeyCorrupt = error {
            return .rsaKeyCorrupt
        }
        return .channelFailed(detail: String(describing: error))
    }

    // MARK: Terminal admission

    private struct TerminalWaiter {
        let id: UUID
        let target: TerminalAttachTarget?
        let continuation: CheckedContinuation<Void, any Error>
    }

    struct TerminalTransportReady: Sendable {
        let transport: any Transport
        let activationGeneration: UInt64
        let transportGeneration: UInt64
        /// Set for a connection handed over ahead of its `ping`; says
        /// whether that `ping` failed.
        let rejection: ProvisionalRejection?
    }

    private struct TerminalTransportWaiter {
        let id: UUID
        /// Nil means the request arrived while suspended and belongs to the
        /// next activation. Active requests are pinned to their exact
        /// activation so retry, Host replacement, and background invalidation
        /// cannot hand them a later Transport accidentally.
        let activationGeneration: UInt64?
        let continuation: CheckedContinuation<TerminalTransportReady, any Error>
    }

    private struct TransportWaiter {
        let id: UUID
        let continuation: CheckedContinuation<any Transport, any Error>
    }

    private func acquireTerminal(target: TerminalAttachTarget?) async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if !canAcquireTerminal(target) {
                    terminalWaiters.append(
                        TerminalWaiter(id: id, target: target, continuation: continuation))
                } else {
                    terminalsInUse.insert(target)
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { await self.cancelTerminalWaiter(id: id) }
        }
    }

    private func cancelTerminalWaiter(id: UUID) {
        guard let index = terminalWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = terminalWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func awaitTerminalTransport() async throws -> TerminalTransportReady {
        let id = UUID()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<TerminalTransportReady, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if isWindingDown || phase == .ended {
                    continuation.resume(throwing: TransportError.cancelled)
                } else if phase == .active, !transportSuspect,
                    let ready = terminalReady()
                {
                    continuation.resume(returning: ready)
                } else if let terminalTransportFailure {
                    continuation.resume(throwing: terminalTransportFailure)
                } else {
                    terminalTransportWaiters.append(
                        TerminalTransportWaiter(
                            id: id,
                            activationGeneration: phase == .active ? activationGeneration : nil,
                            continuation: continuation))
                    terminalWaiterDidRegister?()
                }
            }
        } onCancel: {
            Task { await self.cancelTerminalTransportWaiter(id: id) }
        }
    }

    private func terminalTransportIsCurrent(_ ready: TerminalTransportReady) -> Bool {
        phase == .active
            && !isWindingDown
            && !transportSuspect
            && activationGeneration == ready.activationGeneration
            && terminalReady()?.transportGeneration == ready.transportGeneration
    }

    /// What a terminal attaching now rides: the installed Transport, else a
    /// new connection still awaiting its `ping`.
    private func terminalReady() -> TerminalTransportReady? {
        if let currentTransport {
            return TerminalTransportReady(
                transport: currentTransport, activationGeneration: activationGeneration,
                transportGeneration: transportGeneration, rejection: nil)
        }
        return provisional?.ready(activationGeneration: activationGeneration)
    }

    func resumeTerminalTransportWaiters(with ready: TerminalTransportReady) {
        let activationGeneration = ready.activationGeneration
        let waiters = terminalTransportWaiters
        terminalTransportWaiters.removeAll()
        for waiter in waiters {
            if let expected = waiter.activationGeneration,
                expected != activationGeneration
            {
                waiter.continuation.resume(throwing: TransportError.cancelled)
            } else {
                waiter.continuation.resume(returning: ready)
            }
        }
    }

    /// Hands the newly installed, ping-proven Transport to waiting RPCs.
    private func resumeTransportWaiters(with transport: any Transport) {
        let rpcWaiters = transportWaiters
        transportWaiters.removeAll()
        for waiter in rpcWaiters {
            waiter.continuation.resume(returning: transport)
        }
    }

    /// Releases `withTransport` waiters with the failure that stopped the run
    /// loop — a `.reconnecting` cycle's cause, a `.failed` activation's cause,
    /// or the teardown's cancellation — so a waiting RPC reports what the
    /// session is actually doing instead of a phantom unreachable Host.
    private func failTransportWaiters(_ failure: any Error) {
        let waiters = transportWaiters
        transportWaiters.removeAll()
        for waiter in waiters {
            waiter.continuation.resume(throwing: failure)
        }
    }

    private func cancelTransportWaiter(id: UUID) {
        guard let index = transportWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = transportWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func failTerminalTransportWaiters(
        _ failure: TransportError,
        for activationGeneration: UInt64? = nil
    ) {
        var retained: [TerminalTransportWaiter] = []
        for waiter in terminalTransportWaiters {
            if let activationGeneration,
                waiter.activationGeneration != nil,
                waiter.activationGeneration != activationGeneration
            {
                retained.append(waiter)
            } else {
                waiter.continuation.resume(throwing: failure)
            }
        }
        terminalTransportWaiters = retained
    }

    private func recordTerminalTransportFailure(_ failure: TransportError) {
        guard currentTransport == nil || transportSuspect else { return }
        terminalTransportFailure = failure
    }

    private func cancelTerminalTransportWaiter(id: UUID) {
        guard let index = terminalTransportWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = terminalTransportWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func canAcquireTerminal(_ target: TerminalAttachTarget?) -> Bool {
        guard terminalsInUse.count < 5, !terminalsInUse.contains(target) else { return false }
        // Legacy callers without a target retain Host-wide exclusivity.
        return target == nil ? terminalsInUse.isEmpty : !terminalsInUse.contains(nil)
    }

    private func releaseTerminal(target: TerminalAttachTarget?) {
        terminalsInUse.remove(target)
        while let index = terminalWaiters.firstIndex(where: { canAcquireTerminal($0.target) }) {
            let waiter = terminalWaiters.remove(at: index)
            terminalsInUse.insert(waiter.target)
            waiter.continuation.resume()
        }
        guard terminalsInUse.isEmpty else { return }
        let waiters = terminalIdleWaiters
        terminalIdleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForTerminalIdle() async {
        guard !terminalsInUse.isEmpty else { return }
        await withCheckedContinuation { terminalIdleWaiters.append($0) }
    }
}
