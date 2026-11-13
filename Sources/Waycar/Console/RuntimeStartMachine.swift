import Foundation

/// One user's start per Host/runtime, held through detection and verification.
/// Only a tap admits work. A changed Host rejects the start's outcome, but
/// keeps its single-flight claim until that request returns, as before.
struct RuntimeStartMachine: StateMachine {
    enum State: Equatable, Sendable {
        case idle
        case starting(token: UInt64, host: Host)
        case detecting(token: UInt64, host: Host)
        case verifying(token: UInt64)
        case failed(String)
    }

    enum Event: Sendable {
        case userStart(Host)
        case started(UInt64, current: Host?, error: String?, serverChat: Bool)
        case detected(UInt64, current: Host?, presence: HostBackendPresence?, error: String?)
        case verified(UInt64)
        case clearError
    }

    enum Effect: Equatable, Sendable {
        case start(UInt64, Host)
        case detect(UInt64, Host)
        case record(HostBackendPresence)
        case verify(UInt64, retry: Bool)
        case finish(Bool)
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    var isStarting: Bool {
        switch state {
        case .starting, .detecting, .verifying: true
        case .idle, .failed: false
        }
    }

    var error: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .userStart(let host)), (.failed, .userStart(let host)):
            lastToken += 1
            state = .starting(token: lastToken, host: host)
            return [.start(lastToken, host)]
        case (.starting(let token, let host), .started(let received, let current, let error, let serverChat))
            where token == received:
            // The existing server path detects before rejecting an edited Host.
            if error == nil, serverChat {
                state = .detecting(token: token, host: host)
                return [.detect(token, host)]
            }
            guard current?.recordForm == host.recordForm else {
                state = .idle
                return [.finish(false)]
            }
            if let error {
                state = .failed(error)
                return [.finish(false)]
            }
            state = .verifying(token: token)
            return [.verify(token, retry: true)]
        case (.detecting(let token, let host), .detected(let received, let current, let presence, let error))
            where token == received:
            guard current?.recordForm == host.recordForm else {
                state = .idle
                return [.finish(false)]
            }
            if let error {
                state = .failed(error)
                return [.finish(false)]
            }
            guard let presence else { return [] }
            state = .verifying(token: token)
            return [.record(presence), .verify(token, retry: false)]
        case (.verifying(let token), .verified(let received)) where token == received:
            // Verification failure never changed the successful starter's result.
            state = .idle
            return [.finish(true)]
        case (.failed, .clearError):
            state = .idle
            return []
        case (.starting, .userStart), (.detecting, .userStart), (.verifying, .userStart):
            return [.finish(false)]
        case (.idle, .started), (.idle, .detected), (.idle, .verified), (.idle, .clearError),
             (.starting, .started), (.starting, .detected), (.starting, .verified), (.starting, .clearError),
             (.detecting, .started), (.detecting, .detected), (.detecting, .verified), (.detecting, .clearError),
             (.verifying, .started), (.verifying, .detected), (.verifying, .verified), (.verifying, .clearError),
             (.failed, .started), (.failed, .detected), (.failed, .verified):
            return []
        }
    }
}
