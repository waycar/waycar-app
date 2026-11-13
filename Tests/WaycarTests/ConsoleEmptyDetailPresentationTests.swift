import Testing

@testable import Waycar

@Suite("Console empty detail presentation")
struct ConsoleEmptyDetailPresentationTests {
    @Test func configuredConsoleOffersShowAgentsAndExistingActions() {
        let presentation = ConsoleEmptyDetailPresentation()
        #expect(presentation.title == "No Agent Selected")
        #expect(!presentation.systemImage.isEmpty)
        #expect(presentation.actions == [.showAgents, .newAgent, .hosts])
        #expect(presentation.actions.map(\.title) == ["Show Agents", "New Agent", "Hosts"])
        #expect(presentation.actions.compactMap(\.shortcutHint) == ["⌘N", "⌘⇧H"])
    }

    @Test func visibleSidebarOmitsShowAgentsWithoutChangingOtherActions() {
        let presentation = ConsoleEmptyDetailPresentation(showsAgentsAction: false)
        #expect(presentation.actions == [.newAgent, .hosts])
    }

    /// Every Host disabled: New Agent would open a sheet with no Host to
    /// pick, and Hosts is where the user turns one back on, so it leads.
    @Test func noEnabledHostLeadsWithHostsAndOmitsNewAgent() {
        let presentation = ConsoleEmptyDetailPresentation(hostCount: 2, enabledHostCount: 0)
        #expect(presentation.actions == [.hosts, .showAgents])
        #expect(
            ConsoleEmptyDetailPresentation(
                showsAgentsAction: false, hostCount: 2, enabledHostCount: 0
            ).actions == [.hosts])
    }

    /// One enabled Host among disabled ones is enough to start an Agent.
    @Test func anyEnabledHostKeepsNewAgent() {
        let presentation = ConsoleEmptyDetailPresentation(hostCount: 3, enabledHostCount: 1)
        #expect(presentation.actions == [.showAgents, .newAgent, .hosts])
    }

    @Test func showAgentsHasNoInventedKeyboardShortcut() {
        #expect(ConsoleEmptyDetailPresentation.Action.showAgents.title == "Show Agents")
        #expect(ConsoleEmptyDetailPresentation.Action.showAgents.systemImage == "sidebar.left")
        #expect(ConsoleEmptyDetailPresentation.Action.showAgents.shortcutHint == nil)
    }
}
