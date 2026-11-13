import Foundation

/// The client-side `focusAgent` for herdr-core (design §6, Status).
///
/// herdr turns Done into Idle when the user opens the Agent. Core never
/// clears `done` on its own and has no call that would, so Waycar remembers
/// what the user has seen: the terminal's `turn` and status word when it was
/// opened in Done. While both still match, the terminal presents Idle. A new
/// status word (the agent went back to work) or a new `turn` (it finished
/// another one) makes the entry stale: it stops applying at once and the
/// next inventory change drops it. No RPC is involved.
///
/// Each address is unseen (no entry) or seen in Done at a `turn` and word.
/// `presented(_:for:)` is the derived presentation.
struct CoreDoneOverlayMachine: StateMachine {
    struct Seen: Equatable, Sendable {
        var turn: Int
        var word: String
    }

    struct State: Equatable, Sendable {
        fileprivate(set) var seen: [String: Seen] = [:]
    }

    enum Event: Sendable {
        /// The user opened the Agent at `address`; `terminal` is its record.
        /// Only a reported Done at that address is remembered, so opening a
        /// Working agent never hides its next Done.
        case focused(address: String, terminal: CoreTerminal?)
        /// A notification moved `terminal` without changing any status the
        /// inventory reports (a new `turn`, say).
        case recordMoved(CoreTerminal)
        /// The inventory changed what it reports: entries of terminals that
        /// are gone or finished, or whose word or `turn` moved on, are
        /// dropped.
        case inventoryChanged([CoreTerminal])
    }

    enum Effect: Equatable, Sendable {
        /// The terminal at `address` presents Done again, though nothing the
        /// inventory reports changed (B-23).
        case presentDone(address: String)
    }

    private(set) var state = State()

    init() {}

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .focused(let address, let terminal):
            guard let terminal, terminal.address == address,
                CoreSnapshotBuilder.rawStatus(of: terminal) == .done,
                let word = terminal.status?.state
            else { return [] }
            state.seen[address] = Seen(turn: terminal.turn, word: word)
            return []
        case .recordMoved(let terminal):
            guard state.seen[terminal.address] != nil, !covers(terminal) else { return [] }
            state.seen[terminal.address] = nil
            return [.presentDone(address: terminal.address)]
        case .inventoryChanged(let terminals):
            guard !state.seen.isEmpty else { return [] }
            let live = Dictionary(
                terminals.filter { !$0.isFinished }.map { ($0.address, $0) },
                uniquingKeysWith: { _, latest in latest })
            state.seen = state.seen.filter { address, _ in
                guard let terminal = live[address] else { return false }
                return covers(terminal)
            }
            return []
        }
    }

    /// `status`, or Idle when `status` is Done and the user has seen exactly
    /// this Done. Any other status passes through unchanged.
    func presented(_ status: AgentStatus, for terminal: CoreTerminal) -> AgentStatus {
        guard status == .done, covers(terminal) else { return status }
        return .idle
    }

    /// Whether the user has seen this terminal's current Done.
    private func covers(_ terminal: CoreTerminal) -> Bool {
        guard let entry = state.seen[terminal.address] else { return false }
        return entry.turn == terminal.turn && entry.word == terminal.status?.state
    }
}
