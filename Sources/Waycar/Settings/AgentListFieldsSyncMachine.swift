import Foundation

/// Plugin field requests are independent per Host. A session boundary clears
/// every request; an edit clears just that Host. Completion tokens never repeat.
struct AgentListFieldsSyncMachine: StateMachine {
    enum DisplayState: Equatable, Sendable {
        case syncing
        case filled(String)
        case failed(String)

        var message: String? {
            switch self {
            case .syncing: nil
            case .filled(let message), .failed(let message): message
            }
        }
    }
    enum Phase: Equatable, Sendable {
        case syncing(UInt64, saveImmediately: Bool)
        case applying(UInt64, message: String)
        case filled(String)
        case failed(String)

        var display: DisplayState {
            switch self {
            case .syncing: .syncing
            case .applying(_, let message), .filled(let message): .filled(message)
            case .failed(let message): .failed(message)
            }
        }
    }
    struct State: Equatable, Sendable {
        var hosts: [Host.ID: Phase] = [:]
    }
    enum Outcome: Equatable, Sendable {
        case replacement(AgentRowLayout, message: String)
        case failed(String)
    }
    enum Event: Equatable, Sendable {
        case start(Host.ID, saveImmediately: Bool)
        case received(Host.ID, UInt64, Outcome)
        case applied(Host.ID, UInt64)
        case applyFailed(Host.ID, UInt64, String)
        case invalidate(Host.ID)
        case invalidateAll
    }
    enum Effect: Equatable, Sendable {
        case fetch(UInt64)
        case applyLayout(Host.ID, UInt64, AgentRowLayout, saveImmediately: Bool)
        case clearError
        case reportError(String)
    }

    private(set) var state = State()
    private var lastToken: UInt64 = 0
    var displays: [Host.ID: DisplayState] { state.hosts.mapValues(\.display) }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .start(let host, let saveImmediately):
            lastToken += 1
            state.hosts[host] = .syncing(lastToken, saveImmediately: saveImmediately)
            return [.fetch(lastToken)]
        case .received(let host, let token, let outcome):
            guard case .syncing(let current, let saveImmediately) = state.hosts[host],
                current == token else { return [] }
            switch outcome {
            case .replacement(let layout, let message):
                state.hosts[host] = .applying(token, message: message)
                return [.applyLayout(host, token, layout, saveImmediately: saveImmediately)]
            case .failed(let message):
                state.hosts[host] = .failed(message)
                return [.clearError]
            }
        case .applied(let host, let token):
            guard case .applying(let current, let message) = state.hosts[host],
                current == token else { return [] }
            state.hosts[host] = .filled(message)
            return [.clearError]
        case .applyFailed(let host, let token, let message):
            guard case .applying(let current, _) = state.hosts[host],
                current == token else { return [] }
            state.hosts[host] = .failed(message)
            return [.reportError(message)]
        case .invalidate(let host):
            state.hosts[host] = nil
            return []
        case .invalidateAll:
            state.hosts = [:]
            return []
        }
    }
}
