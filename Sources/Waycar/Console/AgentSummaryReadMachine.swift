/// One summary-store read at a time. A connection change resets capability,
/// but lets its old read drain the coalesced request for the new connection.
struct AgentSummaryReadMachine: StateMachine {
    enum Availability: Equatable, Sendable {
        case available
        case unavailable
    }

    enum State: Equatable, Sendable {
        case idle
        case reading(token: UInt64, epoch: UInt64, availability: Availability)
        case readingAgain(token: UInt64, epoch: UInt64, availability: Availability)
        case unavailable
        case ended
    }

    enum Outcome: Equatable, Sendable {
        case summaries([String: AgentSummary])
        case pluginMissing
        case failed
    }

    enum Event: Equatable, Sendable {
        case request(epoch: UInt64, enabled: Bool)
        case finished(token: UInt64, currentEpoch: UInt64, outcome: Outcome)
        case connectionChanged
        /// The independent refresh action also discovers a missing plugin.
        case pluginMissing
        case end
    }

    enum Effect: Equatable, Sendable {
        case read(token: UInt64)
        case apply([String: AgentSummary])
        /// Re-sample the owner's current gate and epoch after publishing a
        /// result: publication can synchronously end or reconnect the owner.
        case requestFollowUp
        case pluginMissing
        case cancel(token: UInt64)
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    var readToken: UInt64? {
        switch state {
        case .reading(let token, _, _), .readingAgain(let token, _, _): token
        case .idle, .unavailable, .ended: nil
        }
    }

    var isUnavailable: Bool {
        switch state {
        case .unavailable, .reading(_, _, .unavailable), .readingAgain(_, _, .unavailable): true
        case .idle, .reading(_, _, .available), .readingAgain(_, _, .available), .ended: false
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.ended, _):
            return []
        case (_, .end):
            let token = readToken
            state = .ended
            return token.map { [.cancel(token: $0)] } ?? []
        case (.idle, .request(let epoch, true)):
            return start(epoch: epoch)
        case (.reading(let token, let epoch, .available), .request(_, true)):
            state = .readingAgain(token: token, epoch: epoch, availability: .available)
            return []
        case (_, .request):
            return []
        case (.unavailable, .connectionChanged):
            state = .idle
            return []
        case (.reading(let token, let epoch, _), .connectionChanged):
            state = .reading(token: token, epoch: epoch, availability: .available)
            return []
        case (.readingAgain(let token, let epoch, _), .connectionChanged):
            state = .readingAgain(token: token, epoch: epoch, availability: .available)
            return []
        case (.idle, .connectionChanged):
            return []
        case (.reading(let token, let epoch, _), .pluginMissing):
            state = .reading(token: token, epoch: epoch, availability: .unavailable)
            return []
        case (.readingAgain(let token, let epoch, _), .pluginMissing):
            state = .readingAgain(token: token, epoch: epoch, availability: .unavailable)
            return []
        case (.idle, .pluginMissing), (.unavailable, .pluginMissing):
            state = .unavailable
            return []
        case (.reading(let token, let epoch, let availability),
              .finished(let completed, let currentEpoch, let outcome)):
            guard completed == token else { return [] }
            return finish(
                epoch: epoch, currentEpoch: currentEpoch, availability: availability,
                again: false, outcome: outcome)
        case (.readingAgain(let token, let epoch, let availability),
              .finished(let completed, let currentEpoch, let outcome)):
            guard completed == token else { return [] }
            return finish(
                epoch: epoch, currentEpoch: currentEpoch, availability: availability,
                again: true, outcome: outcome)
        case (.idle, .finished), (.unavailable, .finished):
            return []
        }
    }

    private mutating func start(epoch: UInt64) -> [Effect] {
        lastToken &+= 1
        state = .reading(token: lastToken, epoch: epoch, availability: .available)
        return [.read(token: lastToken)]
    }

    private mutating func finish(
        epoch: UInt64, currentEpoch: UInt64, availability: Availability,
        again: Bool, outcome: Outcome
    ) -> [Effect] {
        var availability = availability
        var again = again
        var effects: [Effect] = []
        if epoch == currentEpoch {
            switch outcome {
            case .summaries(let summaries):
                effects.append(.apply(summaries))
            case .pluginMissing:
                availability = .unavailable
                again = false
                effects.append(.pluginMissing)
            case .failed:
                break
            }
        }
        state = availability == .unavailable ? .unavailable : .idle
        // HCP-1: even a stale result releases its read and drains the new
        // connection's request; its capability result is never applied.
        if again { effects.append(.requestFollowUp) }
        return effects
    }
}
