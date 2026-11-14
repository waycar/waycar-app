import Foundation

/// What the herdr events session knows about its connection's liveness
/// (HERDR-04, #18, #105): the round trip its badge shows, the round trips
/// that time the next liveness checks, when the connection last proved
/// itself alive, whether the keepalive runs, and the keepalive failure that
/// forced a teardown.
///
/// The badge (`currentLatency`) is connection-scoped: it is shown by the
/// connect path's `ping`, by a `revalidate()` or `sampleLatency()` answered
/// on the channel that is still live, and hidden before any status but
/// `.connected` leaves, so a value never outlives the connection that
/// measured it. A measurement still times the next check even when its
/// channel was replaced meanwhile: the round trip is kept before the stale
/// check refuses to show it. Any proof of life (a ping, a successful
/// request, an event) postpones the keepalive's next ping; a keepalive
/// failure is what the teardown it forces reports.
struct EventsLivenessMachine: StateMachine {
    enum Stage: Equatable, Sendable {
        /// Nothing shown: no ping proved the current connection yet.
        case unproven
        /// A proven round trip is shown.
        case healthy
        /// A keepalive failed: the channel is being ended on its account.
        case suspect
    }

    struct State: Equatable, Sendable {
        /// The round trip the badge shows (`currentLatency`).
        var shown: Duration?
        /// The latest `ping` round trip (`lastRoundTrip`): liveness
        /// deadlines and the hedge delay derive from it.
        var roundTrip: Duration?
        /// The latest `revalidate()` round trip (`lastRevalidateLatency`),
        /// kept apart from the ping's.
        var revalidateRoundTrip: Duration?
        /// The latest proof of life (`lastConnectionActivity`).
        var lastActivity: ContinuousClock.Instant?
        /// The keepalive failure that forced the current teardown
        /// (`pendingKeepaliveFailure`).
        var pendingFailure: TransportError?
        /// The keepalive loop runs.
        var keepaliveRunning = false
    }

    enum Event: Equatable, Sendable {
        /// A `ping` (the connect path's, a sample's, a keepalive's) took
        /// `roundTrip`.
        case measured(Duration)
        /// A `revalidate()` took `roundTrip`.
        case revalidated(Duration)
        /// The connect path shows its round trip.
        case show(Duration)
        /// A sample or revalidation shows its round trip if the channel it
        /// was measured on is still live.
        case showIfLive(Duration, channelLive: Bool)
        /// The connection proved itself alive at `now`.
        case activity(now: ContinuousClock.Instant)
        /// A status leaves; `connected` for `.connected`.
        case announced(connected: Bool)
        case keepaliveStarted
        case keepaliveStopped
        /// A keepalive, revalidation or sample on the live channel failed.
        case keepaliveFailed(TransportError)
        /// The events channel went live.
        case wentLive
        /// The live channel ended with `failure` (nil when it ended
        /// gracefully).
        case streamEnded(failure: TransportError?)
        /// Teardown ends.
        case woundDown
    }

    enum Effect: Equatable, Sendable {
        /// Show `roundTrip` (box first, then the signal).
        case show(Duration)
        /// Hide the shown round trip.
        case hide
        /// Run the keepalive loop.
        case runKeepalive
        /// Cancel the keepalive loop.
        case cancelKeepalive
        /// The channel was lost to `failure`.
        case lost(TransportError)
    }

    private(set) var state = State()

    init() {}

    var stage: Stage {
        if state.pendingFailure != nil { return .suspect }
        return state.shown == nil ? .unproven : .healthy
    }

    var roundTrip: Duration? { state.roundTrip }
    var revalidateRoundTrip: Duration? { state.revalidateRoundTrip }

    /// Whether no proof of life arrived within `interval` before `now`,
    /// meaning the next keepalive ping is actually needed.
    func isIdle(now: ContinuousClock.Instant, within interval: Duration) -> Bool {
        guard let last = state.lastActivity else { return true }
        return now - last >= interval
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .measured(let roundTrip):
            state.roundTrip = roundTrip
            return []

        case .revalidated(let roundTrip):
            state.revalidateRoundTrip = roundTrip
            return []

        case .show(let roundTrip):
            state.shown = roundTrip
            return [.show(roundTrip)]

        case .showIfLive(let roundTrip, let channelLive):
            guard channelLive else { return [] }
            state.shown = roundTrip
            return [.show(roundTrip)]

        case .activity(let now):
            state.lastActivity = now
            return []

        case .announced(let connected):
            guard !connected else { return [] }
            state.shown = nil
            return [.hide]

        case .keepaliveStarted:
            state.keepaliveRunning = true
            return [.runKeepalive]

        case .keepaliveStopped:
            state.keepaliveRunning = false
            return [.cancelKeepalive]

        case .keepaliveFailed(let failure):
            state.pendingFailure = failure
            return []

        case .wentLive:
            state.pendingFailure = nil
            return []

        case .streamEnded(let failure):
            let lost =
                state.pendingFailure ?? failure
                ?? .channelFailed(detail: "events stream ended unexpectedly")
            state.pendingFailure = nil
            return [.lost(lost)]

        case .woundDown:
            state.pendingFailure = nil
            state.lastActivity = nil
            return []
        }
    }
}
