/// Host-detail handshake proof, never a binary-presence check or an
/// availability cache. The Console's Host/network cache remains separate.
struct HostMoshTestMachine: StateMachine {
    enum Outcome: Equatable, Sendable {
        case available
        case unavailable(String)
    }

    enum State: Equatable, Sendable {
        case idle
        case connecting(UInt64)
        case probing(UInt64)
        case finished(Outcome)
        case invalidated(UInt64)
    }

    enum Event: Equatable, Sendable {
        case test
        case connected(UInt64)
        case completed(UInt64, Outcome)
        case ended(UInt64)
        case disabled
    }

    enum Effect: Equatable, Sendable {
        case connect(UInt64)
        case probe(UInt64)
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    var support: MoshSupportState {
        switch state {
        case .idle: .idle
        case .connecting, .probing, .invalidated: .testing
        case .finished(.available): .available
        case .finished(.unavailable(let reason)): .unavailable(reason)
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .test), (.finished, .test):
            lastToken += 1
            state = .connecting(lastToken)
            return [.connect(lastToken)]
        case (.connecting(let token), .connected(let completed)) where token == completed:
            state = .probing(token)
            return [.probe(token)]
        case (.connecting(let token), .completed(let completed, let result)),
             (.probing(let token), .completed(let completed, let result)):
            guard token == completed else { return [] }
            state = .finished(result)
            return []
        case (.connecting(let token), .disabled), (.probing(let token), .disabled):
            state = .invalidated(token)
            return []
        case (.connecting(let token), .ended(let completed)),
             (.probing(let token), .ended(let completed)),
             (.invalidated(let token), .ended(let completed)):
            guard token == completed else { return [] }
            state = .finished(.unavailable("The test was interrupted."))
            return []
        case (.idle, _), (.connecting, _), (.probing, _), (.finished, _), (.invalidated, _):
            return []
        }
    }
}
