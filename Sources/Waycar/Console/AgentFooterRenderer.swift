import Foundation

/// Everything the Agent Footer can show beyond the Agent's own row fields:
/// figures only the Agent screen knows.
struct AgentFooterContext: Sendable {
    let agent: ConsoleAgent
    var branch: String? = nil
    var model: String? = nil
    var contextText: String? = nil
    var costText: String? = nil
    var rateText: String? = nil
    var transport: TerminalSessionFlavor? = nil
    /// The Agent's progress bar state when the footer was built
    /// (`ConsoleAgent.progressDisplay(at:)`); the footer prints only a
    /// fresh estimate.
    var progress: AgentProgressDisplay? = nil
}

enum AgentFooterRenderer {
    /// The layout's shown lines (``AgentFooterLayout/shownLines(maximumLines:)``)
    /// → non-empty values joined " · ", a value equal to one earlier on its
    /// line dropped as the Agent row drops it (#190); a line with no values
    /// yet is dropped, never replaced by a later one (landscape iPhone shows
    /// the first configured line only).
    static func render(
        layout: AgentFooterLayout, context: AgentFooterContext,
        maximumLines: Int = AgentFooterLayout.maximumLines
    ) -> [String] {
        shownLines(layout: layout, context: context, maximumLines: maximumLines).map {
            $0.map(\.text).joined(separator: " · ")
        }
    }

    /// The usage fields in the lines `render` would show, so the top strip
    /// can omit the figures that moved down here.
    static func displayedUsageFields(
        layout: AgentFooterLayout, context: AgentFooterContext,
        maximumLines: Int = AgentFooterLayout.maximumLines
    ) -> Set<AgentFooterField> {
        Set(shownLines(layout: layout, context: context, maximumLines: maximumLines)
            .flatMap { $0.map(\.field) }
            .filter(\.isUsage))
    }

    static func value(for field: AgentFooterField, context: AgentFooterContext) -> String? {
        let text: String? = switch field {
        case .row(let token): AgentRowRenderer.value(for: token, agent: context.agent)
        case .branch: context.branch
        case .model: context.model
        case .context: context.contextText
        case .cost: context.costText
        case .rate: context.rateText
        case .backend:
            context.agent.backend.displayName
        case .transport:
            switch context.transport {
            case .ssh: "SSH"
            case .mosh: "mosh"
            case nil: nil
            }
        case .progress:
            switch context.progress {
            case .estimate(let progress, isStale: false): progress.label
            case .estimate, .pending, nil: nil
            }
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func shownLines(
        layout: AgentFooterLayout, context: AgentFooterContext, maximumLines: Int
    ) -> [[(field: AgentFooterField, text: String)]] {
        guard layout.isEnabled else { return [] }
        return layout.shownLines(maximumLines: maximumLines).compactMap { line in
            var shown: Set<String> = []
            let values = line.compactMap { field -> (field: AgentFooterField, text: String)? in
                guard let text = value(for: field, context: context),
                    let key = AgentRowRenderer.dedupeKey(text), shown.insert(key).inserted
                else { return nil }
                return (field, text)
            }
            return values.isEmpty ? nil : values
        }
    }
}
