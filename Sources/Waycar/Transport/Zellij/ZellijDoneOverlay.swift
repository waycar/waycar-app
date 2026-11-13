import Foundation

/// Client-only Done acknowledgement, scoped to a terminal generation and the report's sequence.
struct ZellijDoneOverlay: Sendable, Equatable {
    private var seen: [String: ZellijResolvedStatus] = [:]

    mutating func markSeen(terminalID: String, status: ZellijResolvedStatus) {
        guard status.status == .done else { return }
        seen[terminalID] = status
    }

    func presented(_ status: ZellijResolvedStatus, terminalID: String) -> AgentStatus {
        status.status == .done && seen[terminalID] == status ? .idle : status.status
    }

    mutating func prune(keeping statuses: [String: ZellijResolvedStatus]) {
        seen = seen.filter { statuses[$0.key] == $0.value }
    }
}

struct ZellijResolvedStatus: Sendable, Equatable {
    enum Source: Sendable { case program, hook, screen, unknown }
    var status: AgentStatus
    var source: Source
    var sequence: Int? = nil
    var updatedMs: Int64? = nil
}
