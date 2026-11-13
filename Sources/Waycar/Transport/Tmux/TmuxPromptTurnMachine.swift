import Foundation

/// Who holds each pane's prompt turn and who waits for it (design §4.3
/// Input): prompts to one pane go one at a time, each through its Enter, a
/// delayed one included, since a second paste inside a delayed Enter's gap
/// would land in the first draft and go with it. Panes never wait for each
/// other.
///
/// A prompt is named by the id its caller made before asking. Only the
/// holder's release hands the turn on, first come first served; a waiting
/// prompt that is cancelled gives its place up, and a release or
/// withdrawal that names no holder or waiter changes nothing.
struct TmuxPromptTurnMachine: StateMachine {
    /// One pane's turn: the prompt delivering now, and the ones waiting
    /// behind it in the order they came.
    struct Turn: Equatable, Sendable {
        var holder: UUID
        var waiting: [UUID] = []
    }

    enum Event: Equatable, Sendable {
        /// The prompt `id` asks for `pane`'s turn.
        case request(UUID, pane: String)
        /// The waiting prompt `id` was cancelled.
        case withdraw(UUID, pane: String)
        /// The holder `id` finished delivering.
        case release(UUID, pane: String)
    }

    enum Effect: Equatable, Sendable {
        /// The prompt `id` holds its pane's turn now: resume it.
        case grant(UUID)
        /// The waiting prompt `id` gave its place up: fail it as cancelled.
        case cancel(UUID)
    }

    /// Per raw pane id; a pane no prompt holds or waits for has no entry.
    private(set) var state: [String: Turn] = [:]

    init() {}

    /// `pane`'s turn, nil while no prompt holds it.
    subscript(_ pane: String) -> Turn? { state[pane] }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .request(let id, let pane):
            guard var turn = state[pane] else {
                state[pane] = Turn(holder: id)
                return [.grant(id)]
            }
            turn.waiting.append(id)
            state[pane] = turn
            return []

        case .withdraw(let id, let pane):
            guard var turn = state[pane], let index = turn.waiting.firstIndex(of: id) else {
                return []
            }
            turn.waiting.remove(at: index)
            state[pane] = turn
            return [.cancel(id)]

        case .release(let id, let pane):
            guard var turn = state[pane], turn.holder == id else { return [] }
            guard !turn.waiting.isEmpty else {
                state[pane] = nil
                return []
            }
            turn.holder = turn.waiting.removeFirst()
            state[pane] = turn
            return [.grant(turn.holder)]
        }
    }
}
