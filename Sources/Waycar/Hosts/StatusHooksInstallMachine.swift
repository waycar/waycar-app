/// One explicit Install Status Hooks tap. Disabling invalidates its remote
/// steps and publication, but keeps it single-flight until the dial returns.
struct StatusHooksInstallMachine: StateMachine {
    enum State: Equatable, Sendable {
        case idle(error: String?)
        case connecting(UInt64)
        case installing(UInt64)
        case invalidated(UInt64)
    }

    enum Event: Equatable, Sendable {
        case install
        case connected(UInt64)
        case completed(UInt64, StatusHooksReport)
        case failed(UInt64, String)
        case ended(UInt64)
        case checksStarted
        case disabled
    }

    enum Effect: Equatable, Sendable {
        case connect(UInt64)
        case install(UInt64)
        case publish(StatusHooksReport)
    }

    private(set) var state: State = .idle(error: nil)
    private var lastToken: UInt64 = 0

    var isInstalling: Bool {
        if case .idle = state { return false }
        return true
    }

    var error: String? {
        if case .idle(let error) = state { return error }
        return nil
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .install):
            lastToken += 1
            state = .connecting(lastToken)
            return [.connect(lastToken)]
        case (.connecting(let token), .connected(let completed)) where token == completed:
            state = .installing(token)
            return [.install(token)]
        case (.installing(let token), .completed(let completed, let report)) where token == completed:
            state = .idle(error: nil)
            return [.publish(report)]
        case (.connecting(let token), .failed(let completed, let error)),
             (.installing(let token), .failed(let completed, let error)):
            guard token == completed else { return [] }
            state = .idle(error: error)
            return []
        case (.connecting(let token), .disabled), (.installing(let token), .disabled):
            state = .invalidated(token)
            return []
        case (.invalidated(let token), .ended(let completed)) where token == completed:
            state = .idle(error: nil)
            return []
        case (.idle, .checksStarted):
            state = .idle(error: nil)
            return []
        case (.idle, _), (.connecting, _), (.installing, _), (.invalidated, _):
            return []
        }
    }
}
