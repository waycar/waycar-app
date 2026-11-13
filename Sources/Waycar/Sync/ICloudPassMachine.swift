import Foundation

/// Serializes passes and invalidates their publication on disable, without
/// losing a new request made while an invalidated pass is still unwinding.
struct ICloudPassMachine: StateMachine {
    enum State: Equatable, Sendable {
        case disabled
        case idle
        case syncing(token: UInt64, rerun: Bool)
        case draining(token: UInt64, enabled: Bool, rerun: Bool)
    }

    enum Event: Equatable, Sendable {
        case enable
        case disable
        case request
        case began(UInt64)
        case result(UInt64, completedAt: Date, error: String?, retry: Bool, identities: [String?] = [])
        case failed(UInt64, String)
        case finished(UInt64)
    }

    enum Effect: Equatable, Sendable {
        case run(UInt64)
        case publish(Date, error: String?, identities: [String?] = [])
        case retryConnections
        case reportError(String)
    }

    private(set) var state: State
    private var lastToken: UInt64 = 0

    init(enabled: Bool) { state = enabled ? .idle : .disabled }

    var isEnabled: Bool {
        switch state {
        case .disabled: false
        case .idle, .syncing: true
        case .draining(_, let enabled, _): enabled
        }
    }

    func accepts(_ token: UInt64) -> Bool {
        if case .syncing(let current, _) = state { current == token } else { false }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.disabled, .enable):
            state = .idle
        case (.idle, .disable):
            state = .disabled
        case (.syncing(let token, _), .disable):
            state = .draining(token: token, enabled: false, rerun: false)
        case (.draining(let token, _, _), .disable):
            state = .draining(token: token, enabled: false, rerun: false)
        case (.draining(let token, _, let rerun), .enable):
            state = .draining(token: token, enabled: true, rerun: rerun)
        case (.idle, .request):
            return begin()
        case (.syncing(let token, _), .request):
            state = .syncing(token: token, rerun: true)
        case (.draining(let token, true, _), .request):
            state = .draining(token: token, enabled: true, rerun: true)
        case (.syncing(let current, _), .began(let token)) where current == token:
            // The old serial Task cleared demand at the start of a pass:
            // requests queued before it actually begins join that pass.
            state = .syncing(token: token, rerun: false)
        case (.syncing(let current, _), .result(let token, let date, let error, let retry, let identities))
            where current == token:
            return [.publish(date, error: error, identities: identities)] + (retry ? [.retryConnections] : [])
        case (.syncing(let current, _), .failed(let token, let error)) where current == token:
            return [.reportError(error)]
        case (.syncing(let current, let rerun), .finished(let token)) where current == token:
            if rerun { return begin() }
            state = .idle
        case (.draining(let current, let enabled, let rerun), .finished(let token))
            where current == token:
            if enabled && rerun { return begin() }
            state = enabled ? .idle : .disabled
        case (.disabled, _), (.idle, _), (.syncing, _), (.draining, _):
            break
        }
        return []
    }

    private mutating func begin() -> [Effect] {
        lastToken &+= 1
        state = .syncing(token: lastToken, rerun: false)
        return [.run(lastToken)]
    }
}
