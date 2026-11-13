/// The presentation and unsent words of one CarPlay template. Template tokens
/// survive step replacement; step tokens fence every suspended operation. Only
/// an unclaimed correction can be salvaged on close or replacement.
struct CarPlayTurnMachine: StateMachine {
    struct Turn: Equatable, Sendable {
        let template: UInt64
        var step: UInt64
        let agent: ConsoleAgent.ID?
    }

    enum Kind: Equatable, Sendable { case briefing, conversation, blocked }
    enum State: Equatable, Sendable {
        case none
        case briefing(Turn)
        case conversation(Turn)
        case checking(Turn, AgentVoiceService.BlockedTurn?)
        /// A changed prompt is not answerable until its question finishes.
        case rechecking(Turn, AgentVoiceService.BlockedTurn)
        case awaitingAnswer(Turn, AgentVoiceService.BlockedTurn)
        case confirmingCorrection(Turn, AgentVoiceService.BlockedTurn, String)
        case acting(Turn, AgentVoiceService.BlockedTurn)
        /// The final dwell can still display Deny for an unclaimed prompt.
        case finishing(Turn, answerable: AgentVoiceService.BlockedTurn?)

        var turn: Turn? {
            switch self {
            case .none: nil
            case .briefing(let t), .conversation(let t), .checking(let t, _),
                .rechecking(let t, _), .awaitingAnswer(let t, _),
                .confirmingCorrection(let t, _, _), .acting(let t, _), .finishing(let t, _): t
            }
        }

        func replacingStep(_ step: UInt64) -> State {
            guard var t = turn else { return self }
            t.step = step
            switch self {
            case .none: return .none
            case .briefing: return .briefing(t)
            case .conversation: return .conversation(t)
            case .checking(_, let b): return .checking(t, b)
            case .rechecking(_, let b): return .rechecking(t, b)
            case .awaitingAnswer(_, let b): return .awaitingAnswer(t, b)
            case .confirmingCorrection(_, let b, let text): return .confirmingCorrection(t, b, text)
            case .acting(_, let b): return .acting(t, b)
            case .finishing(_, let b): return .finishing(t, answerable: b)
            }
        }
    }

    enum Event: Sendable {
        case open(Kind, ConsoleAgent.ID?)
        case replaceStep
        case checkpoint(UInt64)
        case announce(UInt64, AgentVoiceService.BlockedTurn)
        case spoken(UInt64)
        case correction(UInt64, String)
        case answer
        case sendCorrection
        case draft
        case hold
        case finish(UInt64)
        case close
        case disappeared(UInt64)
    }
    enum Effect: Equatable, Sendable {
        case proceed
        case answer(AgentVoiceService.BlockedTurn)
        case correct(AgentVoiceService.BlockedTurn, String)
        case draft(ConsoleAgent.ID, String)
        case held
        case closed
    }

    private(set) var state: State = .none
    private var lastToken: UInt64 = 0
    var turn: Turn? { state.turn }
    var pendingText: String? {
        if case .confirmingCorrection(_, _, let text) = state { return text }
        return nil
    }
    var blocked: AgentVoiceService.BlockedTurn? {
        switch state {
        case .checking(_, let b): b
        case .rechecking(_, let b), .awaitingAnswer(_, let b),
            .confirmingCorrection(_, let b, _), .acting(_, let b): b
        case .finishing(_, let b): b
        case .none, .briefing, .conversation: nil
        }
    }

    private var salvage: [Effect] {
        guard let id = turn?.agent, let text = pendingText else { return [] }
        return [.draft(id, text)]
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (_, .open(let kind, let agent)):
            let effects = salvage
            lastToken += 1
            let t = Turn(template: lastToken, step: lastToken, agent: agent)
            switch kind {
            case .briefing: state = .briefing(t)
            case .conversation: state = .conversation(t)
            case .blocked: state = .checking(t, nil)
            }
            return effects
        case (_, .close):
            let effects = salvage
            state = .none
            return effects + [.closed]
        case (_, .disappeared(let template)):
            guard turn?.template == template else { return [] }
            return handle(.close)
        case (_, .replaceStep):
            guard turn != nil else { return [] }
            lastToken += 1
            state = state.replacingStep(lastToken)
            return []
        case (_, .checkpoint(let step)):
            return turn?.step == step ? [.proceed] : []
        case (.checking(let t, _), .announce(let step, let b)),
            (.awaitingAnswer(let t, _), .announce(let step, let b)),
            (.confirmingCorrection(let t, _, _), .announce(let step, let b)):
            guard t.step == step else { return [] }
            state = .checking(t, b)
            return []
        case (.acting(let t, _), .announce(let step, let b)),
            (.rechecking(let t, _), .announce(let step, let b)):
            guard t.step == step else { return [] }
            state = .rechecking(t, b)
            return []
        case (.checking(let t, let b?), .spoken(let step)):
            guard t.step == step else { return [] }
            state = .awaitingAnswer(t, b)
            return []
        case (.rechecking(let t, let b), .spoken(let step)):
            guard t.step == step else { return [] }
            state = .awaitingAnswer(t, b)
            return []
        case (.awaitingAnswer(let t, let b), .correction(let step, let text)):
            guard t.step == step else { return [] }
            state = .confirmingCorrection(t, b, text)
            return []
        case (.checking(let t, let b?), .answer),
            (.awaitingAnswer(let t, let b), .answer),
            (.confirmingCorrection(let t, let b, _), .answer),
            (.finishing(let t, let b?), .answer):
            state = .acting(t, b)
            return [.answer(b)]
        case (.confirmingCorrection(let t, let b, let text), .sendCorrection):
            state = .acting(t, b)
            return [.correct(b, text)]
        case (.confirmingCorrection(let t, let b, _), .draft):
            let effects = salvage
            state = .finishing(t, answerable: b)
            return effects
        case (.checking(let t, _), .hold), (.awaitingAnswer(let t, _), .hold),
            (.confirmingCorrection(let t, _, _), .hold),
            (.finishing(let t, .some(_)), .hold):
            state = .finishing(t, answerable: nil)
            return [.held]
        case (.confirmingCorrection, .finish):
            // Resolve or salvage the words before finishing the template.
            return []
        case (_, .finish(let step)):
            guard let t = turn, t.step == step else { return [] }
            let answerable: AgentVoiceService.BlockedTurn?
            switch state {
            case .checking(_, let b), .finishing(_, let b): answerable = b
            case .awaitingAnswer(_, let b): answerable = b
            case .none, .briefing, .conversation, .rechecking, .confirmingCorrection, .acting:
                answerable = nil
            }
            state = .finishing(t, answerable: answerable)
            return []
        case (.none, _), (.briefing, _), (.conversation, _), (.checking, _),
            (.rechecking, _), (.awaitingAnswer, _), (.confirmingCorrection, _),
            (.acting, _), (.finishing, _):
            return []
        }
    }
}
