/// Every in-app entry point that links to a help page. Raw values are the
/// pages' slugs (`apps/web/src/content/help/<slug>.md`); a test checks each
/// resolves to a bundled page.
enum HelpTopic: String, CaseIterable, Sendable {
    case chatMode = "chat-mode"
    case notifications
    case icloudSync = "icloud-sync"
    case toolbar
    case aiUsage = "ai-usage"
    case carplay
    case terminalAppearance = "terminal-appearance"
    case agentCardFields = "agent-card-fields"
    case agentFooter = "agent-footer"
    case hostPage = "host-page"
    case addHostManually = "add-host-manually"
    case newAgent = "new-agent"
    case install
    case pairing
}
