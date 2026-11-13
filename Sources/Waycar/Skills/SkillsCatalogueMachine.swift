/// One Skills catalogue. The previous list survives refresh, failure and
/// cancellation; only a successful fetch replaces it. Loading owns the one
/// fetch slot synchronously, before the owner can cross an await.
struct SkillsCatalogueMachine: StateMachine {
    enum State: Equatable, Sendable {
        case idle(previous: [AgentSkill])
        case loading(previous: [AgentSkill], token: UInt64)
        case loaded([AgentSkill])
        case failed(previous: [AgentSkill], message: String)
    }

    enum Outcome: Equatable, Sendable {
        case loaded([AgentSkill])
        case failed(String)
        case cancelled
    }

    enum Event: Equatable, Sendable {
        case loadIfNeeded
        case refresh
        case finished(UInt64, Outcome)
    }

    enum Effect: Equatable, Sendable {
        case fetch(UInt64, forceRefresh: Bool)
    }

    private(set) var state: State = .idle(previous: [])
    private var lastToken: UInt64 = 0

    var skills: [AgentSkill] {
        switch state {
        case .idle(let previous), .loading(let previous, _), .failed(let previous, _): previous
        case .loaded(let skills): skills
        }
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.idle, .loadIfNeeded), (.idle, .refresh), (.loaded, .refresh), (.failed, .refresh):
            let previous = skills
            lastToken &+= 1
            state = .loading(previous: previous, token: lastToken)
            return [.fetch(lastToken, forceRefresh: event == .refresh)]
        case (.loading(let previous, let current), .finished(let token, let outcome)):
            guard token == current else { return [] }
            switch outcome {
            case .loaded(let skills): state = .loaded(skills)
            case .failed(let message): state = .failed(previous: previous, message: message)
            case .cancelled: state = .idle(previous: previous)
            }
            return []
        case (.idle, .finished), (.loaded, .finished), (.failed, .finished),
             (.loaded, .loadIfNeeded), (.failed, .loadIfNeeded),
             (.loading, .loadIfNeeded), (.loading, .refresh):
            return []
        }
    }
}
