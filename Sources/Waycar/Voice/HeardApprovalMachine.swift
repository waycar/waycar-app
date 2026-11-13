/// Authorization for one Agent's fully heard car question. Matching is the
/// entire BlockedTurn, not its screen or text alone. Allow consumes the claim
/// synchronously, before the owner can await any transport work.
struct HeardApprovalMachine: StateMachine {
    typealias Question = AgentVoiceService.BlockedTurn
    enum State: Equatable, Sendable {
        case unheard
        case speaking(Question, token: UInt64)
        case heard(Question)
        case consumed
    }
    enum Event: Sendable {
        case announce(Question)
        case completed(UInt64, spoken: Bool)
        case allow(Question)
    }
    enum Effect: Equatable, Sendable {
        case speak(UInt64)
        case authorize(BlockedPromptSnapshot)
    }
    private(set) var state: State = .unheard
    private var lastToken: UInt64 = 0

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .announce(let question)):
            lastToken += 1
            state = .speaking(question, token: lastToken)
            return [.speak(lastToken)]
        case (.speaking(let question, let token), .completed(let current, let spoken)) where current == token:
            state = spoken ? .heard(question) : .unheard
            return []
        case (.heard(let question), .allow(let requested)):
            guard question == requested, requested.buttons == .denyAndAllow,
                  let snapshot = requested.snapshot else { return [] }
            state = .consumed
            return [.authorize(snapshot)]
        case (.unheard, _), (.speaking, _), (.heard, _), (.consumed, _):
            return []
        }
    }
}
