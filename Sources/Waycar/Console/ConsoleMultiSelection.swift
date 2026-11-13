import Foundation

/// Selection Mode's checked Agents.
struct ConsoleMultiSelection: Equatable, Sendable {
    private(set) var ids: Set<ConsoleAgent.ID> = []

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    func contains(_ id: ConsoleAgent.ID) -> Bool { ids.contains(id) }

    mutating func toggle(_ id: ConsoleAgent.ID) {
        if ids.remove(id) == nil { ids.insert(id) }
    }

    mutating func insert(_ id: ConsoleAgent.ID) { ids.insert(id) }

    /// Replaces the selection with exactly these ids.
    mutating func selectAll(_ ids: [ConsoleAgent.ID]) { self.ids = Set(ids) }

    /// Drops ids no longer present in the live list.
    mutating func prune(keeping live: Set<ConsoleAgent.ID>) { ids.formIntersection(live) }
}

enum ConsoleBulkPinAction: Equatable, Sendable { case pin, unpin }
enum ConsoleBulkReadAction: Equatable, Sendable { case markRead, markUnread }

enum ConsoleBulkMoveAvailability: Equatable, Sendable {
    /// Empty selection.
    case unavailable
    /// Every selected Agent is on this Host.
    case available(hostID: Host.ID)
    /// One name per distinct Host id, sorted with `localizedStandardCompare`.
    case spansHosts(hostNames: [String])
}

/// Decides which bulk actions apply to a selection.
enum ConsoleBulkActions {
    /// All pinned → `.unpin`; otherwise `.pin`; nil when empty.
    static func pinAction(
        for agents: [ConsoleAgent], isPinned: (ConsoleAgent) -> Bool
    ) -> ConsoleBulkPinAction? {
        guard !agents.isEmpty else { return nil }
        return agents.allSatisfy(isPinned) ? .unpin : .pin
    }

    /// All marked unread → `.markRead`; any can be marked unread → `.markUnread`;
    /// any marked unread → `.markRead`; else nil.
    static func readAction(
        for agents: [ConsoleAgent],
        isMarkedUnread: (ConsoleAgent.ID) -> Bool,
        canMarkUnread: (ConsoleAgent) -> Bool
    ) -> ConsoleBulkReadAction? {
        guard !agents.isEmpty else { return nil }
        if agents.allSatisfy({ isMarkedUnread($0.id) }) { return .markRead }
        if agents.contains(where: canMarkUnread) { return .markUnread }
        if agents.contains(where: { isMarkedUnread($0.id) }) { return .markRead }
        return nil
    }

    static func moveAvailability(for agents: [ConsoleAgent]) -> ConsoleBulkMoveAvailability {
        guard let first = agents.first else { return .unavailable }
        if agents.allSatisfy({ $0.hostID == first.hostID }) {
            return .available(hostID: first.hostID)
        }
        var seenHosts = Set<Host.ID>()
        var names: [String] = []
        for agent in agents where seenHosts.insert(agent.hostID).inserted {
            names.append(agent.hostName)
        }
        names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return .spansHosts(hostNames: names)
    }

    /// "Your selection is on A and B." / "Your selection is on A, B, and C."
    static func spansHostsMessage(hostNames: [String]) -> String {
        let list: String
        switch hostNames.count {
        case 0: list = ""
        case 1: list = hostNames[0]
        case 2: list = "\(hostNames[0]) and \(hostNames[1])"
        default:
            list = hostNames.dropLast().joined(separator: ", ") + ", and " + (hostNames.last ?? "")
        }
        return "Your selection is on \(list)."
    }
}
