import Foundation

/// CodexBar detection on one Host connection. A known path survives probes
/// and retry waits. Request UUIDs survive Host removal/re-addition; the
/// machine's sequence owns each probe and its retry across suspension.
struct CodexBarDetectionMachine: StateMachine {
    struct Token: Hashable, Sendable {
        let requestID: UUID
        let sequence: UInt64
    }

    enum State: Equatable, Sendable {
        case unknown(previous: CodexBarDetection, failures: Int)
        case probing(previous: CodexBarDetection, generation: UInt64, token: Token, failures: Int)
        case found(path: String, generation: UInt64)
        case missing(generation: UInt64)
        case retryWaiting(previous: CodexBarDetection, generation: UInt64, token: Token, failures: Int)
        case invalidPath(generation: UInt64, failures: Int)
    }

    enum Outcome: Equatable, Sendable {
        case located(String?)
        case failed(String)
    }

    enum Event: Equatable, Sendable {
        case probe(generation: UInt64, requestID: UUID, customPath: String?)
        case finished(Token, Outcome)
        case retryElapsed(Token)
        case reset
    }

    enum Effect: Equatable, Sendable {
        case locate(Token, customPath: String?)
        case cancelRetry(Token)
        case armRetry(Token, after: Duration)
        case retireRetry(Token)
        case didFind(String?)
        case reschedulePolling
        case connectionsChanged
    }

    private(set) var state: State = .unknown(previous: .unknown, failures: 0)
    private var lastToken: UInt64 = 0
    let retryDelay: Duration

    init(retryDelay: Duration) {
        self.retryDelay = retryDelay
    }

    var detection: CodexBarDetection {
        switch state {
        case .unknown(let previous, _), .retryWaiting(let previous, _, _, _): previous
        case .probing(let previous, _, _, _): previous.path == nil ? .probing : previous
        case .found(let path, _): .found(path: path)
        case .missing: .notFound
        case .invalidPath: .failed(message: CodexBarError.invalidPath.message)
        }
    }

    var generation: UInt64? {
        switch state {
        case .unknown: nil
        case .probing(_, let generation, _, _), .found(_, let generation),
             .missing(let generation), .retryWaiting(_, let generation, _, _),
             .invalidPath(let generation, _): generation
        }
    }

    private var failures: Int {
        switch state {
        case .unknown(_, let failures), .probing(_, _, _, let failures),
             .retryWaiting(_, _, _, let failures), .invalidPath(_, let failures): failures
        case .found, .missing: 0
        }
    }

    private var cancelRetry: [Effect] {
        if case .retryWaiting(_, _, let token, _) = state { [.cancelRetry(token)] } else { [] }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .probe(let generation, let requestID, let customPath)):
            let effects = cancelRetry
            let previous = detection
            let failures = self.failures
            lastToken &+= 1
            let token = Token(requestID: requestID, sequence: lastToken)
            if let customPath, !CodexBarCommand.isValidCustomPath(customPath) {
                state = .invalidPath(generation: generation, failures: failures)
                return effects
            }
            state = .probing(previous: previous, generation: generation, token: token, failures: failures)
            return effects + [.locate(token, customPath: customPath)]
        case (.probing(let previous, let generation, let current, let failures), .finished(let token, let outcome)):
            guard current == token else { return [] }
            switch outcome {
            case .located(let path):
                state = path.map { .found(path: $0, generation: generation) } ?? .missing(generation: generation)
                return [.didFind(path)]
            case .failed(let message):
                let retained = previous.path == nil ? .failed(message: message) : previous
                state = .retryWaiting(previous: retained, generation: generation, token: token, failures: failures + 1)
                return [.armRetry(token, after: AIUsagePollSchedule.delay(
                    interval: retryDelay, consecutiveFailures: failures)), .reschedulePolling]
            }
        case (.retryWaiting(let previous, _, let current, let failures), .retryElapsed(let token)):
            guard current == token else { return [] }
            state = .unknown(previous: previous, failures: failures)
            return [.retireRetry(token), .connectionsChanged]
        case (_, .reset):
            let effects = cancelRetry
            state = .unknown(previous: .unknown, failures: 0)
            return effects
        case (.unknown, .finished), (.found, .finished), (.missing, .finished),
             (.retryWaiting, .finished), (.invalidPath, .finished),
             (.unknown, .retryElapsed), (.probing, .retryElapsed),
             (.found, .retryElapsed), (.missing, .retryElapsed), (.invalidPath, .retryElapsed):
            return []
        }
    }
}
