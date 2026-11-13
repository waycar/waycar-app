import Foundation

/// Help's **Ask an Agent**: the New Agent sheet prefilled with a help page,
/// handed to the agent as its Launch Prompt File. The user still reviews
/// every field and taps Start.
enum HelpAgentPrompt {
    static func preset(for page: HelpPage) -> AgentLaunchPreset {
        AgentLaunchPreset(
            title: "Ask an Agent",
            hostID: nil,
            suggestedName: suggestedName(slug: page.slug),
            attachmentTitle: "Help: \(page.title)",
            firstMessage: firstMessage(for: page))
    }

    /// `help-<slug>` under the agent-name rule, without the trailing `-`
    /// the 32-character cut can leave.
    static func suggestedName(slug: String) -> String {
        var name = AgentName.normalizingInput("help-\(slug)")
        while name.last == "-" { name.removeLast() }
        return name
    }

    static func firstMessage(for page: HelpPage) -> String {
        let pageURL = HelpWeb.pageURL(page.slug)?.absoluteString ?? "\(siteHelpPrefix)\(page.slug)"
        var parts = [
            """
            The user is reading Waycar's help page "\(page.title)" (\(pageURL)) on their phone and started you from it.
            Waycar is an iPhone and iPad app for checking on coding agents that run in herdr or tmux on this machine.
            Read the page below. Then ask the user what they want to do, and help them with it on this machine.
            Explain what you will change and ask before you change anything.
            """,
            "---",
            "# \(page.title)",
        ]
        if !page.description.isEmpty { parts.append(page.description) }
        parts.append(absoluteSiteLinks(page.body).trimmingCharacters(in: .whitespacesAndNewlines))
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// Root-relative Markdown links (`](/...`) made absolute on waycar.dev,
    /// so the agent can fetch them, as the site's Markdown twin does.
    static func absoluteSiteLinks(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "](/", with: "](\(sitePrefix)")
    }

    private static let sitePrefix: String = {
        let base = HelpWeb.base.absoluteString
        return base.hasSuffix("/") ? base : base + "/"
    }()
    private static let siteHelpPrefix = sitePrefix + "help/"
}
