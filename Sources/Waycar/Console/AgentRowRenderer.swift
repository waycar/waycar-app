import Foundation

/// Separators are separate unstyled spans. UI consumers must display `text`
/// as plain text, including plugin values, rather than interpreting Markdown.
struct RenderedToken: Equatable, Sendable {
    let token: AgentRowToken?
    let text: String
    let fg: HexColor?
    let bold: Bool?
    let dim: Bool?

    var isSeparator: Bool { token == nil }

    static let separator = RenderedToken(token: nil, text: " · ", fg: nil, bold: nil, dim: nil)
}

enum AgentRowRenderer {
    /// A value equal (`dedupeKey`) to one already shown earlier in the same
    /// row is dropped with its separator: a herdr worktree Workspace and its
    /// tab both carry the branch name (#190).
    static func render(layout: AgentRowLayout, agent: ConsoleAgent) -> [[RenderedToken]] {
        layout.rows(forAgentKind: agent.agent.kind).compactMap { row in
            var rendered: [RenderedToken] = []
            var shown: Set<String> = []
            for configured in row {
                guard let text = value(for: configured.token, agent: agent),
                    let key = dedupeKey(text), shown.insert(key).inserted
                else { continue }
                if !rendered.isEmpty { rendered.append(.separator) }
                rendered.append(RenderedToken(
                    token: configured.token, text: text, fg: configured.fg,
                    bold: configured.bold, dim: configured.dim))
            }
            return rendered.isEmpty ? nil : rendered
        }
    }

    /// What two shown values are compared by (#190): trimmed of whitespace
    /// and newlines, case-sensitive; nil for a blank value. Swift `String`
    /// equality is canonical equivalence, so composed and decomposed forms
    /// match, as the plugin's NFC-normalized comparison does.
    static func dedupeKey(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// One field's text for `agent`; the Agent Footer reuses it.
    static func value(for token: AgentRowToken, agent row: ConsoleAgent) -> String? {
        switch token {
        case .stateIcon, .stateText: nil // The status column owns both.
        case .workspace: row.workspaceLabel
        case .tab: row.showsTabLabel ? row.tabLabel : nil
        case .pane: row.agent.paneTitle ?? row.paneLabel
        case .agent: row.agent.displayName
        case .terminalTitle: row.agent.terminalTitle
        case .terminalTitleStripped: row.agent.terminalTitleStripped
        case .host: nonempty(row.hostName)
        case .status: nonempty(row.agent.status.rawValue.capitalized)
        case .directory: nonempty(row.displayCwd)
        case .runtime: row.backend.displayName
        case .custom(let name): row.agent.tokens[name]
        }
    }

    private static func nonempty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
