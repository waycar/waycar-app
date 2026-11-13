/// One dwell and one focus attempt per eligible Done target. A cancelled
/// attempt retains its slot until it returns, even when the RPC ignores
/// cancellation; only then may the newest eligible target start its dwell.
struct ViewedDoneMachine: StateMachine {
    struct Target: Equatable, Sendable {
        let agentID: ConsoleAgent.ID
        let terminalID: String
        let transportGeneration: UInt64
    }

    enum State: Equatable, Sendable {
        case ineligible
        case dwelling(attempt: UInt64, Target)
        case sending(attempt: UInt64, Target)
        case draining(attempt: UInt64, next: Target?)
        case attempted(Target)
    }

    enum Event: Equatable, Sendable {
        case update(Target?)
        case leave
        case dwellElapsed(UInt64)
        case failure(UInt64)
        case finished(UInt64)
    }

    enum Effect: Equatable, Sendable {
        case startAttempt(UInt64, Target)
        case cancelAttempt(UInt64)
        case reportFailure
    }

    private(set) var state: State = .ineligible
    private var lastToken: UInt64 = 0

    var isInFlight: Bool { activeAttempt != nil }

    private var activeAttempt: UInt64? {
        switch state {
        case .dwelling(let attempt, _), .sending(let attempt, _), .draining(let attempt, _): attempt
        case .ineligible, .attempted: nil
        }
    }

    private var target: Target? {
        switch state {
        case .ineligible: nil
        case .dwelling(_, let target), .sending(_, let target), .attempted(let target): target
        case .draining(_, let next): next
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .update(let replacement)):
            guard replacement != target else { return [] }
            if let attempt = activeAttempt {
                state = .draining(attempt: attempt, next: replacement)
                return [.cancelAttempt(attempt)]
            }
            return start(replacement)
        case (_, .leave):
            if let attempt = activeAttempt {
                state = .draining(attempt: attempt, next: nil)
                return [.cancelAttempt(attempt)]
            }
            state = .ineligible
            return []
        case (.dwelling(let attempt, let target), .dwellElapsed(let received)) where attempt == received:
            state = .sending(attempt: attempt, target)
            return []
        case (.dwelling(let attempt, _), .failure(let received)) where attempt == received,
             (.sending(let attempt, _), .failure(let received)) where attempt == received:
            return [.reportFailure]
        case (.dwelling(let attempt, let target), .finished(let received)) where attempt == received,
             (.sending(let attempt, let target), .finished(let received)) where attempt == received:
            state = .attempted(target)
            return []
        case (.draining(let attempt, let next), .finished(let received)) where attempt == received:
            return start(next)
        case (.ineligible, .dwellElapsed), (.ineligible, .failure), (.ineligible, .finished),
             (.attempted, .dwellElapsed), (.attempted, .failure), (.attempted, .finished),
             (.dwelling, .dwellElapsed), (.dwelling, .failure), (.dwelling, .finished),
             (.sending, .dwellElapsed), (.sending, .failure), (.sending, .finished),
             (.draining, .dwellElapsed), (.draining, .failure), (.draining, .finished):
            return []
        }
    }

    private mutating func start(_ target: Target?) -> [Effect] {
        guard let target else {
            state = .ineligible
            return []
        }
        lastToken &+= 1
        state = .dwelling(attempt: lastToken, target)
        return [.startAttempt(lastToken, target)]
    }
}
