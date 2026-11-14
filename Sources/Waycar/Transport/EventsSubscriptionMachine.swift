import Foundation

/// The herdr events channel's subscription set and live channel
/// (HERDR-03): what the next `events.subscribe` asks for, whether that set
/// is a seed, which channel is live, and whether a deliberate teardown has
/// asked the run loop to subscribe again at once.
///
/// `events.subscribe` is all-or-nothing (one pane-scoped entry naming an
/// exited pane fails the whole request), so pane-scoped entries never
/// outlive the connection they were derived on: every disconnect cuts the
/// set back to its global entries (`dropSnapshotSubscriptions`). A seed
/// (#105) is a set derived from a cached snapshot that no subscribe has
/// accepted yet; any rejection of it, like `pane_not_found` for any set,
/// falls back to the global set once, at once, without a reconnect. A
/// subscribe answered for a set that is no longer the requested one is
/// ended and sent again. A replacement (an update while live, a distrusted
/// link, a hedge that won) ends the live channel and re-subscribes without
/// leaving Connected.
///
/// The re-subscribe request is a flag beside the stage: it is made only
/// while a channel is live (an update, a distrusted link, a hedge that
/// won) and taken by that channel's end. A link failure a request finds
/// while no channel is live (during a backoff) requests nothing, so the
/// next channel's loss shows `.reconnecting` like any other (B-46).
struct EventsSubscriptionMachine: StateMachine {
    enum Stage: Equatable, Sendable {
        /// The set is a seed no subscribe has accepted; no channel is live.
        case seeded
        /// No channel is live; the set came from a live snapshot, or a
        /// subscribe accepted it.
        case subscribing
        /// No channel is live; the set was cut back to its global entries
        /// (a rejection's one fallback, or a disconnect).
        case globalFallback
        /// The channel kept under `channel` is live.
        case live(channel: UInt64)
    }

    struct State: Equatable, Sendable {
        /// What the next subscribe asks for (`subscriptions`).
        var requested: [EventSubscription]
        var stage: Stage
        /// A deliberate teardown asked the run loop to subscribe again at
        /// once, with no backoff and no `.reconnecting` (replacing).
        var replacing = false
    }

    enum Event: Equatable, Sendable {
        /// `resume(seeding:)` activates the session with a seed.
        case seed([EventSubscription])
        /// `updateSubscriptions`; `active` while the session is active.
        case update([EventSubscription], active: Bool)
        /// A subscribe for `asked` answered with a stream.
        case answered(asked: [EventSubscription])
        /// The answer came on a Transport that is no longer installed, or
        /// was distrusted meanwhile; `activationCurrent` when the run loop
        /// that asked is still the session's.
        case answeredOnReplacedTransport(activationCurrent: Bool)
        /// The server accepted the requested set.
        case accepted
        /// The accepted stream becomes the live channel.
        case goLive
        /// The stream of `channel` finished, gracefully or failing.
        case channelEnded(channel: UInt64)
        /// The current run loop asks why its stream finished.
        case streamFinished
        /// The connect or subscribe failed with `failure`.
        case connectFailed(TransportError)
        /// The run loop goes on to back off after a retryable failure.
        case disconnected
        /// A deliberate replacement of the live channel (a distrusted link,
        /// a hedge that won): subscribe again on the next Transport.
        case replace
        /// Teardown begins: the live channel is taken to be ended.
        case windDownStarted
        /// Teardown ends.
        case woundDown
    }

    enum Effect: Equatable, Sendable {
        /// End the live channel's stream (it stays the owner's until its
        /// end is seen).
        case endChannel(UInt64)
        /// End the stream that just answered and subscribe again at once.
        case subscribeAgain
        /// Keep the stream that just answered under `channel`.
        case retain(channel: UInt64)
        /// Stop the keepalive that rode the live channel.
        case stopKeepalive
        /// Forget the stream kept under `channel`.
        case forget(channel: UInt64)
        /// Forget the stream kept under `channel` and end it with the
        /// teardown.
        case take(channel: UInt64)
        /// The failure was a rejection the fallback answers: connect again
        /// at once with the global set.
        case retryAtOnce
    }

    private(set) var state: State
    private var lastChannel: UInt64 = 0

    /// A fresh session's set counts as a seed until a subscribe accepts it.
    init(subscriptions: [EventSubscription]) {
        state = State(requested: subscriptions, stage: .seeded)
    }

    var requested: [EventSubscription] { state.requested }

    /// The live channel, if one is.
    var liveChannel: UInt64? {
        guard case .live(let channel) = state.stage else { return nil }
        return channel
    }

    func isLive(_ channel: UInt64) -> Bool { liveChannel == channel }

    var isSeeded: Bool { state.stage == .seeded }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .seed(let subscriptions):
            state.requested = subscriptions
            // Activation runs only from suspended, and every suspension
            // winds the live channel down first.
            if liveChannel == nil { state.stage = .seeded }
            return []

        case .update(let subscriptions, let active):
            guard subscriptions != state.requested else { return [] }
            state.requested = subscriptions
            guard let channel = liveChannel else {
                state.stage = .subscribing
                return []
            }
            guard active else { return [] }
            state.replacing = true
            return [.endChannel(channel)]

        case .answered(let asked):
            return asked == state.requested ? [] : [.subscribeAgain]

        case .answeredOnReplacedTransport(let activationCurrent):
            if activationCurrent { state.replacing = false }
            return [.subscribeAgain]

        case .accepted:
            switch state.stage {
            case .seeded, .globalFallback: state.stage = .subscribing
            case .subscribing, .live: break
            }
            return []

        case .goLive:
            lastChannel &+= 1
            let previous = liveChannel
            state.stage = .live(channel: lastChannel)
            return (previous.map { [Effect.forget(channel: $0)] } ?? [])
                + [.retain(channel: lastChannel)]

        case .channelEnded(let channel):
            guard isLive(channel) else { return [] }
            state.stage = .subscribing
            return [.stopKeepalive, .forget(channel: channel)]

        case .streamFinished:
            guard state.replacing else { return [] }
            state.replacing = false
            return [.subscribeAgain]

        case .connectFailed(let failure):
            guard Self.namesAMissingPane(failure) || (isSeeded && Self.isRejection(failure))
            else { return [] }
            return dropSnapshotSubscriptions() ? [.retryAtOnce] : []

        case .disconnected:
            dropSnapshotSubscriptions()
            return []

        case .replace:
            // A replacement is of the live channel: with none live the run
            // loop subscribes afresh anyway, and a request left standing
            // would make the next channel's loss silent (B-46).
            guard let channel = liveChannel else { return [] }
            state.replacing = true
            return [.endChannel(channel)]

        case .windDownStarted:
            guard let channel = liveChannel else { return [] }
            state.stage = .subscribing
            return [.take(channel: channel)]

        case .woundDown:
            state.replacing = false
            dropSnapshotSubscriptions()
            return []
        }
    }

    /// Discards snapshot-derived subscriptions, keeping baseline global ones.
    /// workspace.reordered requires protocol 19; a new connection must prove
    /// that capability again before it is included alongside its Pane set.
    /// The set is a seed no more either way. Returns whether the set changed.
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
    private mutating func dropSnapshotSubscriptions() -> Bool {
        if state.stage == .seeded { state.stage = .subscribing }
        let globalsOnly = state.requested.filter { subscription in
            switch subscription {
            case .global(.workspaceReordered), .pane: false
            case .global: true
            }
        }
        guard globalsOnly.count != state.requested.count else { return false }
        state.requested = globalsOnly
        if liveChannel == nil { state.stage = .globalFallback }
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
}
