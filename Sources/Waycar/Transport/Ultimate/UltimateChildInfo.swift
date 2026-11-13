import Foundation

/// A branch remains addressable as a native chat without becoming a Console row.
struct UltimateChildInfo: Sendable, Equatable {
    let conversationId: Int
    let paneID: String
    let name: String
    let busy: Bool
    var openQuestions: Int = 0

    /// Board questions are attention, not a terminal approval dialog.
    var needsUser: Bool { openQuestions > 0 }
    var status: AgentStatus { busy ? .working : .idle }
}

extension UltimateConversationSummary {
    /// Structural fallback for older projects without a named @ultimate.
    var isLeader: Bool { parentConversationId == nil && branchOf == nil }
    var isStandingAgent: Bool { label == "agent" && parentConversationId == nil && ownerTaskId == nil }
    var displayName: String {
        if label == "agent" { return title ?? "Conversation #\(id)" }
        return label ?? title ?? "Conversation #\(id)"
    }
}
