import Foundation

enum ConsoleCommandAction: Hashable, Sendable {
    /// One-based position in the visible sidebar rows.
    case selectAgent(Int)
    case previousAgent, nextAgent, focusSearch, newAgent, settings, hosts, help
    case toggleInputMode, sendDraft, closeAgent
}

struct ConsoleCommandShortcut: Identifiable, Equatable, Sendable {
    let action: ConsoleCommandAction
    let title: String
    let key: Character
    var requiresShift = false

    var id: ConsoleCommandAction { action }

    /// Every entry implicitly requires Command. Help has no entry: iPadOS keeps
    /// ⌘? for the Help menu's search, which lists Waycar Help.
    /// Terminal zoom belongs to Ghostty's adapter.
    static let all: [Self] =
        (1...9).map {
            Self(action: .selectAgent($0), title: "Select Agent \($0)", key: Character(String($0)))
        } + [
            Self(action: .previousAgent, title: "Previous Agent", key: "["),
            Self(action: .nextAgent, title: "Next Agent", key: "]"),
            Self(action: .focusSearch, title: "Search Agents", key: "f"),
            Self(action: .newAgent, title: "New Agent", key: "n"),
            Self(action: .settings, title: "Settings…", key: ","),
            Self(action: .hosts, title: "Hosts…", key: "h", requiresShift: true),
            Self(action: .toggleInputMode, title: "Toggle Message Agent", key: "e"),
            Self(action: .sendDraft, title: "Send", key: "\r"),
            Self(action: .closeAgent, title: "Close Agent View", key: "w"),
        ]
}

enum ConsoleCommandFocus: CaseIterable, Sendable {
    case terminal, composer, sidebar, none
}

/// Policy only. Registration and scene ownership are checked separately by the target.
struct ConsoleCommandAvailability {
    let focus: ConsoleCommandFocus
    let hasSelection: Bool
    let agentCount: Int
    let hasDraft: Bool

    func allows(_ action: ConsoleCommandAction) -> Bool {
        switch action {
        case .selectAgent(let position):
            (1...9).contains(position) && position <= agentCount
        case .previousAgent, .nextAgent:
            agentCount > 0
        case .toggleInputMode, .closeAgent:
            hasSelection
        case .sendDraft:
            // Composer focus implies Message Agent is open. With the terminal
            // holding the keyboard ⌘Return presses Return there instead.
            hasSelection && ((focus == .composer && hasDraft) || focus == .terminal)
        case .focusSearch, .newAgent, .settings, .hosts, .help:
            true
        }
    }
}

enum ConsoleCommandNavigation {
    /// Previous/next wrap. With no visible selection they start at the last/first row.
    static func destination<ID: Equatable>(
        for action: ConsoleCommandAction, in agents: [ID], selection: ID?
    ) -> ID? {
        guard !agents.isEmpty else { return nil }
        switch action {
        case .selectAgent(let position):
            guard (1...9).contains(position), position <= agents.count else { return nil }
            return agents[position - 1]
        case .previousAgent, .nextAgent:
            guard let selection, let index = agents.firstIndex(of: selection) else {
                return action == .previousAgent ? agents.last : agents.first
            }
            let step = action == .previousAgent ? -1 : 1
            return agents[(index + step + agents.count) % agents.count]
        default:
            return nil
        }
    }
}
