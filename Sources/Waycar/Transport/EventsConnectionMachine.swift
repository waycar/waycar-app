import Foundation

/// Which connection the herdr events session rides (HERDR-02, #105): the
/// Transport its `ping` proved, one offered to terminals ahead of that
/// `ping` (attach first), the pooled connection held across a suspension
/// and its probe, whether the connection can still be trusted, and the
/// generations terminals ride.
///
/// Generations: every new connection reserves the next one (the first is
/// 0) when it is offered to terminals or, for a hedge's replacement, when
/// it is installed. A reservation whose `ping` fails is burned, so
/// terminals that rode it never share a generation with the next
/// connection. Observers see a generation (`published`) only once its
/// connection is proven and installed.
///
/// A distrusted connection (a request or keepalive the link swallowed)
/// stays distrusted until a new connection is offered or proven, or the
/// teardown ends: it is never kept across a suspension, never handed to
/// terminals, and the next connect replaces it. A connection kept longer
/// than `LivenessTiming.keptConnectionMaxAge` is retired unprobed.
///
/// The owner keeps the objects (the installed Transport, the provisional
/// one and its rejection, the kept probe's handout) under the generation
/// the machine names; the machine says when each is set and dropped.
struct EventsConnectionMachine: StateMachine {
    struct Installed: Equatable, Sendable {
        let generation: UInt64
        /// The pooled connection it rides; nil when unpooled.
        let connection: PooledConnectionID?
    }

    /// A pooled connection held open across a suspension, and since when.
    struct Kept: Equatable, Sendable {
        let id: PooledConnectionID
        let since: ContinuousClock.Instant
    }

    enum Stage: Equatable, Sendable {
        /// No connection: nothing installed, offered or kept.
        case absent
        /// A connection held across a suspension, waiting for the return.
        case kept
        /// A new connection offered to terminals, its `ping` outstanding.
        case provisional
        /// The installed connection its `ping` proved.
        case proven
        /// The connection swallowed a request: the next connect replaces it.
        case distrusted
    }

    struct State: Equatable, Sendable {
        /// The installed Transport's generation and connection
        /// (`currentTransport`, `currentConnection`).
        var installed: Installed?
        /// `transportSuspect`.
        var distrusted = false
        /// The generation offered to terminals ahead of its `ping`.
        var provisional: UInt64?
        /// `keptConnection`.
        var kept: Kept?
        /// The generation the kept connection's probe handed out, while it
        /// runs (`keptProbe`).
        var probe: UInt64?
        /// The generation the kept connection's last probe offered
        /// terminals (`keptTransportGeneration`).
        var keptGeneration: UInt64?
        /// The proven generation observers see (`transportGeneration`).
        var published: UInt64 = 0
        /// The last reserved generation; nil before the first.
        var reserved: UInt64?
    }

    enum Event: Equatable, Sendable {
        /// A new connection is offered to terminals ahead of its `ping`.
        case offer
        /// A hedge's replacement needs a generation of its own.
        case reserve
        /// A connection its `ping` proved is installed under `generation`.
        case install(generation: UInt64, connection: PooledConnectionID?)
        /// The `ping` of the connection offered under `generation` failed,
        /// or the probe that offered it lost.
        case provisionalFailed(generation: UInt64)
        /// A request found the installed connection dead: distrusted and
        /// dropped without a close (terminals may still use it).
        case distrust
        /// The connection swallowed a request or a keepalive: distrusted,
        /// still installed.
        case suspect
        /// The connect found the installed connection dead or distrusted.
        case drop
        /// The suspension holds the installed connection `id` open.
        case keep(id: PooledConnectionID, since: ContinuousClock.Instant)
        /// The activation claims the kept connection at `now`.
        case takeKept(now: ContinuousClock.Instant)
        /// The kept connection's probe handed out the connection offered
        /// under `generation`.
        case probeOffered(generation: UInt64)
        /// The probe proved the kept connection.
        case probeSettled
        /// The probe lost or failed.
        case probeAbandoned
        /// The session ends: the kept connection goes back.
        case end
        /// Teardown begins: the installed and provisional connections go.
        case windDownStarted
        /// Teardown ends.
        case woundDown
    }

    enum Effect: Equatable, Sendable {
        /// Offer the new connection under `generation`.
        case offer(generation: UInt64)
        /// The generation reserved for a replacement.
        case reserved(generation: UInt64)
        /// Install the proven connection and publish `generation`.
        case publish(generation: UInt64)
        /// Drop the installed Transport.
        case uninstall
        /// Drop the provisional Transport.
        case forgetProvisional
        /// Probe the kept connection `id`.
        case probeKept(PooledConnectionID)
        /// Retire the kept connection `id`, kept too long, unprobed.
        case retireKept(PooledConnectionID)
        /// Give the kept connection `id`'s hold back.
        case releaseKept(PooledConnectionID)
        /// Hold the probe's handout.
        case holdProbe
        /// Drop the probe's handout.
        case forgetProbe
    }

    private(set) var state = State()

    init() {}

    var stage: Stage {
        if state.distrusted { return .distrusted }
        if state.installed != nil { return .proven }
        if state.provisional != nil { return .provisional }
        if state.kept != nil { return .kept }
        return .absent
    }

    var isDistrusted: Bool { state.distrusted }

    /// Whether a terminal on `generation` rides the connection kept across
    /// the last suspension.
    func ridesKept(generation: UInt64) -> Bool { state.keptGeneration == generation }

    /// The installed connection that a suspension may keep: trusted, and
    /// pooled.
    var keepable: PooledConnectionID? {
        guard let installed = state.installed, !state.distrusted else { return nil }
        return installed.connection
    }

    /// Whether a terminal or request failure leaves no trusted connection
    /// standing (`recordTerminalTransportFailure`).
    var hasNoTrustedConnection: Bool { state.installed == nil || state.distrusted }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .offer:
            let generation = reserve()
            state.provisional = generation
            state.distrusted = false
            return [.offer(generation: generation)]

        case .reserve:
            return [.reserved(generation: reserve())]

        case .install(let generation, let connection):
            let forgets: [Effect] = state.provisional != nil ? [.forgetProvisional] : []
            state.provisional = nil
            state.distrusted = false
            state.installed = Installed(generation: generation, connection: connection)
            state.published = generation
            return forgets + [.publish(generation: generation)]

        case .provisionalFailed(let generation):
            guard state.provisional == generation else { return [] }
            state.provisional = nil
            return [.forgetProvisional]

        case .distrust:
            state.distrusted = true
            state.installed = nil
            return [.uninstall]

        case .suspect:
            state.distrusted = true
            return []

        case .drop:
            state.installed = nil
            return [.uninstall]

        case .keep(let id, let since):
            state.kept = Kept(id: id, since: since)
            return []

        case .takeKept(let now):
            guard let kept = state.kept else { return [] }
            state.kept = nil
            guard now - kept.since <= LivenessTiming.keptConnectionMaxAge else {
                return [.retireKept(kept.id)]
            }
            return [.probeKept(kept.id)]

        case .probeOffered(let generation):
            state.keptGeneration = generation
            state.probe = generation
            return [.holdProbe]

        case .probeSettled:
            state.probe = nil
            return [.forgetProbe]

        case .probeAbandoned:
            guard state.probe != nil else { return [] }
            state.probe = nil
            return [.forgetProbe]

        case .end:
            guard let kept = state.kept else { return [] }
            state.kept = nil
            return [.releaseKept(kept.id)]

        case .windDownStarted:
            let effects: [Effect] =
                (state.installed != nil ? [.uninstall] : [])
                + (state.provisional != nil ? [.forgetProvisional] : [])
            state.installed = nil
            state.provisional = nil
            return effects

        case .woundDown:
            state.distrusted = false
            return []
        }
    }

    /// The next generation for a new connection: the first connection's is
    /// 0, and each later one's is one past the last reserved.
    private mutating func reserve() -> UInt64 {
        let next = state.reserved.map { $0 &+ 1 } ?? 0
        state.reserved = next
        return next
    }
}
