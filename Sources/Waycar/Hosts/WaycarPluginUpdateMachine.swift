/// Consent through Host-lock release. Verification is still displayed as
/// running; an unreadable success is intentionally not called outdated.
/// The finishing state prevents a callback from re-entering Start before
/// this run has released its Host, without a separate running flag.
struct WaycarPluginUpdateMachine: StateMachine {
    enum Verification: Equatable, Sendable {
        case installed(WaycarPluginUpdateResult)
        case failed(message: String, lastLine: String?)
    }

    struct Failure: Error, Equatable, Sendable {
        let message: String
        let includesLastLine: Bool
    }

    enum State: Equatable, Sendable {
        case confirm
        case acquiring(UInt64)
        case installing(token: UInt64, latestLine: String?)
        case verifying(token: UInt64, latestLine: String?, result: Verification)
        case finishing(token: UInt64, phase: WaycarPluginUpdateStore.Phase)
        case finished(WaycarPluginUpdateStore.Phase)
    }

    enum Event: Sendable {
        case start
        case acquired(UInt64, Bool)
        case credentialsFailed(UInt64, String)
        case output(UInt64, String)
        case installerEnded(UInt64, Result<WaycarPluginUpdateResult, Failure>)
        case verified(UInt64, presence: HostBackendPresence?, stillOutdated: Bool, keptVersion: String?)
        case released(UInt64)
    }

    enum Effect: Equatable, Sendable {
        case acquire(UInt64)
        case install(UInt64)
        case verify(UInt64, Verification)
        case notify(HostBackendPresence?)
        case release(UInt64)
    }

    private(set) var state: State = .confirm
    private var lastToken: UInt64 = 0

    var phase: WaycarPluginUpdateStore.Phase {
        switch state {
        case .confirm: .confirm
        case .acquiring: .running(latestLine: nil)
        case .installing(_, let line), .verifying(_, let line, _): .running(latestLine: line)
        case .finishing(_, let phase), .finished(let phase): phase
        }
    }

    var isRunning: Bool {
        switch state {
        case .confirm, .finished: false
        case .acquiring, .installing, .verifying, .finishing: true
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.confirm, .start), (.finished, .start):
            lastToken += 1
            state = .acquiring(lastToken)
            return [.acquire(lastToken)]
        case (.acquiring(let current), .acquired(let token, let acquired)) where current == token:
            guard acquired else {
                state = .finished(.failed(
                    message: "An update is already running on this Host.", lastLine: nil, keptVersion: nil))
                return []
            }
            state = .installing(token: token, latestLine: nil)
            return [.install(token)]
        case (.installing(let current, _), .credentialsFailed(let token, let message)) where current == token:
            state = .finishing(token: token, phase: .failed(message: message, lastLine: nil, keptVersion: nil))
            return [.release(token)]
        case (.installing(let current, _), .output(let token, let line)) where current == token:
            state = .installing(token: token, latestLine: line)
            return []
        case (.installing(let current, let line), .installerEnded(let token, let result)) where current == token:
            let verification: Verification
            switch result {
            case .success(let installed): verification = .installed(installed)
            case .failure(let error):
                verification = .failed(message: error.message, lastLine: error.includesLastLine ? nil : line)
            }
            state = .verifying(token: token, latestLine: line, result: verification)
            return [.verify(token, verification)]
        case (.verifying(let current, _, let result), .verified(let token, let presence, let outdated, let kept)) where current == token:
            switch result {
            case .installed(let installed):
                state = .finishing(token: token, phase: .succeeded(installed, stillOutdated: outdated))
                return [.notify(presence), .release(token)]
            case .failed(let message, let line):
                state = .finishing(token: token, phase: .failed(message: message, lastLine: line, keptVersion: kept))
                return [.release(token)]
            }
        case (.finishing(let current, let phase), .released(let token)) where current == token:
            state = .finished(phase)
            return []
        case (.confirm, _), (.acquiring, _), (.installing, _), (.verifying, _), (.finishing, _), (.finished, _):
            return []
        }
    }
}
