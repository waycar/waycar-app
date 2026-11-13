import Foundation

/// Each Agent has no answer, a queued answer with an expiry, or an answer
/// already dispatched. Only dispatch's outcome may settle the last kind.
struct BlockedAnswerQueueMachine: StateMachine {
    typealias Entry = BlockedAnswerQueue.Entry
    typealias Finish = BlockedAnswerQueue.Finish

    enum Answer: Equatable, Sendable {
        case queued(Entry)
        case sending(Entry)

        var entry: Entry {
            switch self {
            case .queued(let entry), .sending(let entry): entry
            }
        }
    }

    struct State: Equatable, Sendable {
        fileprivate var answers: [ConsoleAgent.ID: Answer] = [:]
    }

    enum Event: Equatable, Sendable {
        case enqueue(Entry)
        case withdraw(ConsoleAgent.ID)
        case claim(Entry)
        case finish(Entry, Finish)
    }

    enum Effect: Equatable, Sendable {
        case armExpiry(Entry)
        case cancelExpiry(UUID)
        case claimed(UUID)
        case report(Entry, Finish)
    }

    private(set) var state = State()

    var entries: [ConsoleAgent.ID: Entry] {
        state.answers.mapValues(\.entry)
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .enqueue(let entry):
            let old = state.answers.updateValue(.queued(entry), forKey: entry.agentID)
            return (old.map { [.cancelExpiry($0.entry.id)] } ?? []) + [.armExpiry(entry)]
        case .withdraw(let agentID):
            guard let old = state.answers.removeValue(forKey: agentID) else { return [] }
            return [.cancelExpiry(old.entry.id)]
        case .claim(let entry):
            guard case .queued(let current) = state.answers[entry.agentID], current.id == entry.id
            else { return [] }
            state.answers[entry.agentID] = .sending(current)
            return [.cancelExpiry(entry.id), .claimed(entry.id)]
        case .finish(let entry, let outcome):
            guard let answer = state.answers[entry.agentID], answer.entry.id == entry.id
            else { return [] }
            switch (answer, outcome) {
            case (.sending, .expired):
                return []
            case (.queued, _), (.sending, .sent), (.sending, .promptChanged), (.sending, .notConfirmed):
                state.answers.removeValue(forKey: entry.agentID)
                return [.cancelExpiry(entry.id), .report(entry, outcome)]
            }
        }
    }
}
