import Foundation

/// The greeting a Chat Mode chat opens with: a local bubble from the Agent.
/// It is never sent to the Agent and never read from its transcript.
enum ChatGreeting {
    static let anytime: [String] = [
        "What are we working on today?",
        "Hey! What's on your mind?",
        "What can I help with?",
        "Hi there. What do you need?",
        "What are we digging into?",
        "Ready when you are. What's up?",
        "Got a question? Fire away.",
        "What do you want to tackle?",
        "Hey, what's going on?",
        "What should we figure out?",
        "How can I help?",
        "What's on the list?",
        "Ask me anything.",
        "What are you curious about?",
        "Hey! What can I do for you?",
        "What's the plan?",
        "Here to help. What's up?",
        "What are we building?",
        "Hi! Where should we start?",
        "What's the question?",
    ]

    /// Started 05:00–11:59.
    static let morning: [String] = [
        "Morning! What are we working on today?",
        "Good morning. What's first?",
        "Morning! What's on your mind?",
        "Good morning! How can I help?",
        "Good morning. Where do we start?",
    ]

    /// Started 12:00–16:59.
    static let afternoon: [String] = [
        "Afternoon! What are we working on?",
        "Hey, good afternoon. What's up?",
        "Afternoon! What can I help with?",
        "Good afternoon. What's next?",
    ]

    /// Started 17:00–21:59.
    static let evening: [String] = [
        "Evening! What are we working on?",
        "Good evening. What's on your mind?",
        "Evening! How can I help?",
        "Hey, good evening. What do you need?",
    ]

    /// Started 22:00–04:59.
    static let lateNight: [String] = [
        "Burning the midnight oil? What's up?",
        "Late one, huh? What do you need?",
        "Still at it? What can I help with?",
        "Night owl mode. What are we working on?",
    ]

    /// Same chat, same greeting. The pool is `anytime` plus the pool for the
    /// hour `startedAt` falls in (calendar's time zone), or `anytime` alone
    /// when `startedAt` is nil. The index is a stable FNV-1a 64-bit hash of
    /// `seed`'s UTF-8 modulo the pool count. Never `hashValue`, which is
    /// randomized per launch.
    static func text(seed: String, startedAt: Date?, calendar: Calendar = .current) -> String {
        let pool = anytime + timeOfDay(startedAt, calendar: calendar)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return pool[Int(hash % UInt64(pool.count))]
    }

    /// The seed one chat's greeting hashes: its Agent, its terminal, and the
    /// marker's wire form of `launchedAt` (milliseconds), so the local copy
    /// recorded at launch and the Host's copy give the same greeting. Empty
    /// time when there is no marker. The demo fixture uses it too, so its
    /// screenshots keep their greeting.
    static func seed(agentID: ConsoleAgent.ID, terminalID: String, launchedAt: Date?) -> String {
        let launched = launchedAt.map { ChatModeTimestamp.string(from: $0) } ?? ""
        return "\(agentID.hostID.uuidString)|\(agentID.paneID)|\(terminalID)|\(launched)"
    }

    private static func timeOfDay(_ date: Date?, calendar: Calendar) -> [String] {
        guard let date else { return [] }
        switch calendar.component(.hour, from: date) {
        case 5..<12: return morning
        case 12..<17: return afternoon
        case 17..<22: return evening
        default: return lateNight
        }
    }
}
