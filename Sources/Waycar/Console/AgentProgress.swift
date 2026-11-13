import Foundation

/// How far along an Agent's current turn looks (#189): the plan steps the
/// Agent wrote this turn, else the coarse phase the Host plugin read off its
/// screen. An estimate only — never a percentage or a time left. Foundation
/// only: the WaycarWidgets extension compiles this file too.
struct AgentProgress: Sendable, Equatable, Hashable {
    struct Steps: Sendable, Equatable, Hashable {
        let done: Int
        let total: Int

        /// The wire rule: 0 ≤ done ≤ total, 1 ≤ total ≤ 99.
        var isValid: Bool { (1...99).contains(total) && (0...total).contains(done) }
    }

    enum Phase: String, Sendable, CaseIterable {
        case exploring, implementing, verifying
        case wrappingUp = "wrapping_up"
    }

    let steps: Steps?
    let phase: Phase?

    /// Nil when there is nothing to show: no phase and no valid steps.
    /// Invalid steps are dropped, keeping the phase.
    init?(steps: Steps?, phase: Phase?) {
        let steps = steps.flatMap { $0.isValid ? $0 : nil }
        guard steps != nil || phase != nil else { return nil }
        self.steps = steps
        self.phase = phase
    }

    /// The share of the bar to fill. Never full: the turn is not over until
    /// the Agent says so, so finished steps stop at 0.95.
    var fraction: Double {
        if let steps { return min(Double(steps.done) / Double(steps.total), 0.95) }
        switch phase {
        case .exploring: return 0.25
        case .implementing: return 0.5
        case .verifying: return 0.75
        case .wrappingUp: return 0.9
        case nil: return 0
        }
    }

    /// "3/7", else the phase: "Exploring", "Building", "Verifying", "Wrapping up".
    var label: String {
        if let steps { return "\(steps.done)/\(steps.total)" }
        switch phase {
        case .exploring: return "Exploring"
        case .implementing: return "Building"
        case .verifying: return "Verifying"
        case .wrappingUp: return "Wrapping up"
        case nil: return ""
        }
    }

    /// What VoiceOver and Siri read: "3 of 7 steps done", else the phase.
    var spokenLabel: String {
        if let steps { return "\(steps.done) of \(steps.total) steps done" }
        return label.lowercased()
    }
}

/// What an Agent's progress bar shows (`ConsoleAgent.progressDisplay(at:)`).
enum AgentProgressDisplay: Sendable, Equatable {
    /// The latest estimate; stale when its summary was written in another
    /// status or is older than `AgentSummary.freshness`.
    case estimate(AgentProgress, isStale: Bool)
    /// A Working Agent with summaries on and no estimate yet.
    case pending
}
