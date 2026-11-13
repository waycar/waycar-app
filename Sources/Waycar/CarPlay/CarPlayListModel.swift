import Foundation

/// The CarPlay root list as plain values (docs/design/carplay.md §4):
/// a "Talk to Waycar" row, then the Agents in `AgentGlanceList` order,
/// capped at what a head unit is guaranteed to show. Rows carry identity,
/// status, progress and age only, never message content (CPG p.4 #6).
struct CarPlayListModel: Equatable {
    struct Row: Equatable, Identifiable {
        let id: ConsoleAgent.ID
        /// `workspace · name`, as the phone's Agent card reads.
        let title: String
        /// `Status · progress · age`, the status word first so it is
        /// never truncated.
        let detail: String
        let status: AgentStatus
        /// The shared status symbol (`AgentActivityStatusVocabulary`).
        let symbolName: String
        /// Working/Blocked progress (`ConsoleAgent.progressDisplay`); part
        /// of equality so a progress change re-renders the list.
        let progress: AgentProgressDisplay?

        /// The ring drawn around the status glyph, nil without an estimate.
        var ring: Ring? { CarPlayListModel.ring(for: progress) }
    }

    /// A segmented ring around the row's status glyph: one segment per
    /// plan step (a continuous arc at `AgentProgress.fraction` past
    /// `maximumRingSegments`), or one per phase. Segments say "steps",
    /// never percent. Plan steps never fill the ring, like the card's rail:
    /// the last step segment (or the arc past 0.95) would fill only as the
    /// turn ends, which ends the ring. Phases are coarse and do fill it:
    /// wrapping up lights all four.
    struct Ring: Equatable {
        enum Shape: Equatable {
            case segments(count: Int, filled: Int)
            case arc(fraction: Double)
        }

        let shape: Shape
        /// Drawn dimmed: the estimate predates the current status or is old.
        let isStale: Bool
    }

    /// More plan steps than this draw as a continuous arc.
    static let maximumRingSegments = 12

    static func ring(for display: AgentProgressDisplay?) -> Ring? {
        guard case .estimate(let progress, let isStale) = display else { return nil }
        if let steps = progress.steps {
            let shape: Ring.Shape =
                steps.total > maximumRingSegments
                ? .arc(fraction: progress.fraction)
                : .segments(count: steps.total, filled: min(steps.done, steps.total - 1))
            return Ring(shape: shape, isStale: isStale)
        }
        guard let phase = progress.phase,
            let index = AgentProgress.Phase.allCases.firstIndex(of: phase)
        else { return nil }
        return Ring(
            shape: .segments(count: AgentProgress.Phase.allCases.count, filled: index + 1),
            isStale: isStale)
    }

    static let talkTitle = "Talk to Waycar"
    /// CPG p.18: be prepared for a head unit that shows only 12 items.
    static let guaranteedItemCount = 12

    let rows: [Row]

    /// - Parameter maximumItemCount: `CPListTemplate.maximumItemCount`;
    ///   the Talk row counts against it.
    init(agents: [ConsoleAgent], maximumItemCount: Int, now: Date) {
        let capacity = max(0, min(maximumItemCount, Self.guaranteedItemCount) - 1)
        rows = AgentGlanceList.listed(agents)
            .prefix(capacity)
            .map { Self.row(for: $0, now: now) }
    }

    /// `Working · 3/7 · 6m`, `Working · verifying · 12m`: the estimate's
    /// label (lowercase, so a phase reads as a word in the sentence)
    /// between the status word and the age (`AgentGlanceList.statusAge`).
    /// Pending or no estimate: the status word and age alone.
    static func detail(
        for agent: ConsoleAgent, progress: AgentProgressDisplay?, now: Date
    ) -> String {
        var parts = [AgentActivityStatusVocabulary.word(for: agent.agent.status.rawValue)]
        if case .estimate(let estimate, _) = progress {
            parts.append(estimate.label.lowercased())
        }
        if let age = AgentGlanceList.statusAge(of: agent, now: now) {
            parts.append(age)
        }
        return parts.joined(separator: " · ")
    }

    private static func row(for agent: ConsoleAgent, now: Date) -> Row {
        let progress = agent.progressDisplay(at: now)
        return Row(
            id: agent.id,
            title: AgentGlanceList.title(for: agent),
            detail: detail(for: agent, progress: progress, now: now),
            status: agent.agent.status,
            symbolName: AgentActivityStatusVocabulary.symbol(for: agent.agent.status.rawValue),
            progress: progress)
    }
}
