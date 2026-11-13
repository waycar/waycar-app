import Foundation

/// One Ultimate project's event stream inside `UltimateTransport`'s pump:
/// every attempt bootstraps afresh (identity first, then the conversation
/// summaries and the shared UI, then the board subscription on conversation
/// 1), a failed attempt is reported to the transport, which decides whether
/// to retry, and retries back off along the configured delays, starting
/// over once the project publishes again.
///
/// `subscribeToEvents` waits for each project's first report: its first
/// published inventory, or its first failure, or the pump ending first
/// (`signalReady`, at most once).
struct UltimateInstanceStreamMachine: StateMachine {
    /// What one attempt has seen.
    struct Bootstrap: Equatable, Sendable {
        var identified = false
        var streamID: String?
        var boardSubscribed = false
        var summaries: [UltimateConversationSummary]?
        var receivedUI = false
    }

    enum Phase: Equatable, Sendable {
        case streaming(Bootstrap)
        /// The attempt failed; the transport is deciding about a retry.
        case reporting
        case backingOff
        case stopped
    }

    struct State: Equatable, Sendable {
        var phase: Phase = .streaming(Bootstrap())
        /// Failed attempts since the project last published.
        var failures = 0
        /// The first report is still owed to `subscribeToEvents`.
        var readinessOwed = true
    }

    enum Event: Equatable, Sendable {
        case streamOpened
        /// A `stream` event named the stream's id (nil when it named none).
        case streamAnnounced(id: String?)
        /// The `system` event passed the identity check.
        case identified
        /// A `conversations` event arrived, before decoding it.
        case listArrived
        case listed([UltimateConversationSummary])
        /// A `ui` or `uiOps` event arrived, before applying it.
        case sharedUIArrived
        /// It was applied; `snapshot` for a `ui` event.
        case sharedUIApplied(snapshot: Bool)
        /// The event is handled; what follows from it is asked for.
        case eventDone
        case boardSubscribed
        /// The transport took the published inventory.
        case published
        case streamFailed
        case retryDecided(Bool)
        case backoffElapsed
        /// The pump ends.
        case stop
    }

    enum Effect: Equatable, Sendable {
        /// Conversations or shared UI before the identity check.
        case refuseMissingIdentity
        /// `POST /api/events/<id>/0` for the board on conversation 1.
        case subscribeBoard(streamID: String)
        case publish([UltimateConversationSummary])
        case signalReady
        /// Tell the transport the attempt failed, and whether it failed
        /// after a retry.
        case report(afterRetry: Bool)
        case backOff(Duration)
    }

    private(set) var state = State()
    private let retryDelays: [Duration]

    init(retryDelays: [Duration]) {
        self.retryDelays = retryDelays.isEmpty ? [.seconds(30)] : retryDelays
    }

    /// Whether the current attempt passed its identity check.
    var isIdentified: Bool {
        if case .streaming(let bootstrap) = state.phase { return bootstrap.identified }
        return false
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state.phase, event) {
        case (.stopped, _):
            return []

        case (_, .streamOpened):
            state.phase = .streaming(Bootstrap())
            return []

        case (.streaming(var bootstrap), .streamAnnounced(let id)):
            bootstrap.streamID = id
            state.phase = .streaming(bootstrap)
            return []
        case (.streaming(var bootstrap), .identified):
            bootstrap.identified = true
            state.phase = .streaming(bootstrap)
            return []
        case (.streaming(let bootstrap), .listArrived), (.streaming(let bootstrap), .sharedUIArrived):
            return bootstrap.identified ? [] : [.refuseMissingIdentity]
        case (.streaming(var bootstrap), .listed(let summaries)):
            bootstrap.summaries = summaries
            state.phase = .streaming(bootstrap)
            return []
        case (.streaming(var bootstrap), .sharedUIApplied(let snapshot)):
            if snapshot { bootstrap.receivedUI = true }
            state.phase = .streaming(bootstrap)
            return []
        case (.streaming(let bootstrap), .eventDone):
            var effects: [Effect] = []
            if bootstrap.identified, !bootstrap.boardSubscribed, let id = bootstrap.streamID {
                effects.append(.subscribeBoard(streamID: id))
            }
            if let summaries = bootstrap.summaries, bootstrap.receivedUI {
                effects.append(.publish(summaries))
            }
            return effects
        case (.streaming(var bootstrap), .boardSubscribed):
            bootstrap.boardSubscribed = true
            state.phase = .streaming(bootstrap)
            return []
        case (.streaming, .published):
            state.failures = 0
            return settleReadiness()

        case (.streaming, .streamFailed):
            state.phase = .reporting
            return [.report(afterRetry: state.failures > 0)]
        case (.reporting, .retryDecided(let retry)):
            let ready = settleReadiness()
            guard retry else {
                state.phase = .stopped
                return ready
            }
            state.phase = .backingOff
            return ready + [.backOff(retryDelays[min(state.failures, retryDelays.count - 1)])]
        case (.backingOff, .backoffElapsed):
            state.failures += 1
            return []

        case (_, .stop):
            state.phase = .stopped
            return settleReadiness()

        case (.streaming, .retryDecided), (.streaming, .backoffElapsed),
            (.reporting, .streamAnnounced), (.reporting, .identified), (.reporting, .listArrived),
            (.reporting, .listed), (.reporting, .sharedUIArrived), (.reporting, .sharedUIApplied),
            (.reporting, .eventDone), (.reporting, .boardSubscribed), (.reporting, .published),
            (.reporting, .streamFailed), (.reporting, .backoffElapsed),
            (.backingOff, .streamAnnounced), (.backingOff, .identified), (.backingOff, .listArrived),
            (.backingOff, .listed), (.backingOff, .sharedUIArrived), (.backingOff, .sharedUIApplied),
            (.backingOff, .eventDone), (.backingOff, .boardSubscribed), (.backingOff, .published),
            (.backingOff, .streamFailed), (.backingOff, .retryDecided):
            return []
        }
    }

    private mutating func settleReadiness() -> [Effect] {
        guard state.readinessOwed else { return [] }
        state.readinessOwed = false
        return [.signalReady]
    }
}
