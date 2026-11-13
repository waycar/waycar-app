/// One guarded answer, optionally followed by a correction. A dispatched
/// key sequence has exactly one result and no retry transition. The owner
/// shares one instance for car actions; generic answers/replays keep their
/// existing independent admission, each with its own instance.
struct BlockedPromptAnswerMachine: StateMachine {
    enum Mode: Equatable, Sendable {
        case live(queuesOffline: Bool)
        case replay
    }

    enum Kind: Equatable, Sendable {
        case answer
        case correction(String)
    }

    struct Request: Equatable, Sendable {
        let pending: PendingBlockedAnswer
        let mode: Mode
        let kind: Kind
    }

    enum Result: Equatable, Sendable {
        case answer(BlockedPromptAnswerer.Outcome)
        case correction(BlockedPromptAnswerer.CorrectionOutcome)
    }

    enum PromptResult: Equatable, Sendable {
        case sent, refusedUnsent, failed
    }

    enum State: Equatable, Sendable {
        case idle
        case verifying(UInt64, Request)
        case claiming(UInt64, Request)
        case dispatching(UInt64, Request)
        case waitingUnblocked(UInt64, String)
        case promptingCorrection(UInt64, String)
        case drafting(UInt64, String)
        case settling(UInt64, Result)
    }

    enum Event: Equatable, Sendable {
        case begin(Request)
        case read(UInt64, full: String?, unreachable: Bool, stillWanted: Bool, cancelled: Bool)
        case claimed(UInt64, Bool)
        case keysSent(UInt64, succeeded: Bool)
        case unblocked(UInt64, Bool)
        case prompted(UInt64, PromptResult)
        case drafted(UInt64)
        case completed(UInt64)
    }

    enum Effect: Equatable, Sendable {
        case read(UInt64)
        case claim(UInt64)
        case sendKeys(UInt64, [String])
        case queue(PendingBlockedAnswer)
        case waitUnblocked(UInt64)
        case prompt(UInt64, String)
        case draft(UInt64, String)
        case complete(UInt64, Result)
        /// A rejected admission does not release the already-running action.
        case busy(Result)
    }

    private(set) var state: State = .idle
    private var lastToken: UInt64 = 0

    var isActing: Bool { state != .idle }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .begin(let request)):
            lastToken += 1
            state = .verifying(lastToken, request)
            return [.read(lastToken)]
        case (_, .begin(let request)):
            return [.busy(result(.busy, for: request))]
        case (.verifying(let token, let request), .read(let current, let full, let unreachable, let wanted, let cancelled)):
            guard current == token else { return [] }
            guard wanted else { return settle(token, result(.abandoned, for: request)) }
            guard !cancelled else { return settle(token, result(.cancelled, for: request)) }
            if unreachable {
                switch request.mode {
                case .replay:
                    return settle(token, result(.unreachable, for: request))
                case .live(queuesOffline: true):
                    return [.queue(request.pending)] + settle(token, result(.queued, for: request))
                case .live(queuesOffline: false):
                    break
                }
            }
            let screen = full.flatMap(BlockedPromptAnswerer.screenText(from:))
            guard let full, let screen, screen == request.pending.shown,
                request.pending.snapshot.map({
                    BlockedPromptClassifier.classify(kind: $0.kind, screen: full) == $0.prompt
                }) ?? true
            else { return settle(token, result(.promptChanged(current: screen), for: request)) }
            state = .claiming(token, request)
            return [.claim(token)]
        case (.claiming(let token, let request), .claimed(let current, let accepted)):
            guard current == token else { return [] }
            guard accepted else { return settle(token, result(.abandoned, for: request)) }
            state = .dispatching(token, request)
            return [.sendKeys(token, request.pending.keys)]
        case (.dispatching(let token, let request), .keysSent(let current, let succeeded)):
            guard current == token else { return [] }
            guard succeeded else { return settle(token, result(.sendFailed, for: request)) }
            switch request.kind {
            case .answer:
                return settle(token, .answer(.sent))
            case .correction(let text):
                state = .waitingUnblocked(token, text)
                return [.waitUnblocked(token)]
            }
        case (.waitingUnblocked(let token, let text), .unblocked(let current, let unblocked)):
            guard current == token else { return [] }
            if unblocked {
                state = .promptingCorrection(token, text)
                return [.prompt(token, text)]
            }
            state = .drafting(token, text)
            return [.draft(token, text)]
        case (.promptingCorrection(let token, let text), .prompted(let current, let outcome)):
            guard current == token else { return [] }
            switch outcome {
            case .sent:
                return settle(token, .correction(.prompted))
            case .failed:
                return settle(token, .correction(.promptFailed))
            case .refusedUnsent:
                state = .drafting(token, text)
                return [.draft(token, text)]
            }
        case (.drafting(let token, _), .drafted(let current)):
            guard current == token else { return [] }
            return settle(token, .correction(.drafted))
        case (.settling(let token, _), .completed(let current)):
            guard current == token else { return [] }
            state = .idle
            return []
        case (.idle, _), (.verifying, _), (.claiming, _), (.dispatching, _),
            (.waitingUnblocked, _), (.promptingCorrection, _), (.drafting, _), (.settling, _):
            return []
        }
    }

    private func result(_ outcome: BlockedPromptAnswerer.Outcome, for request: Request) -> Result {
        switch request.kind {
        case .answer: .answer(outcome)
        case .correction: .correction(.denyFailed(outcome))
        }
    }

    private mutating func settle(_ token: UInt64, _ result: Result) -> [Effect] {
        state = .settling(token, result)
        return [.complete(token, result)]
    }
}
