import SwiftUI

/// Console preview for a Host's current rows.
///
/// Draws the same `AgentCardView` the Agent list uses, with sample values, so
/// typography, status, Host footer, and field emphasis cannot drift. The Host
/// section owns the strip label, tint, and padding.
struct AgentListFieldsPreview: View {
    let layout: AgentRowLayout
    let hostName: String

    var body: some View {
        AgentCardView(agent: Self.sampleAgent(hostName: hostName), layout: layout)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityRespondsToUserInteraction(false)
    }

    /// Same presentation the Console card uses for this sample.
    /// `nonisolated`: pure, and called off the main actor (AGENTS.md, Conventions).
    nonisolated static func presentation(layout: AgentRowLayout, hostName: String) -> AgentCardPresentation {
        AgentCardPresentation(agent: sampleAgent(hostName: hostName), layout: layout)
    }

    /// Deterministic sample values for built-in and custom tokens; not a live
    /// Agent. Its Agent Summary is a minute old whenever the preview draws.
    /// `nonisolated`: pure, and called off the main actor (AGENTS.md, Conventions).
    nonisolated static func sampleAgent(hostName: String) -> ConsoleAgent {
        ConsoleAgent(
            hostID: sampleHostID,
            hostName: hostName,
            agent: Agent(
                terminalID: "preview-terminal",
                kind: "claude",
                title: "fix sidebar sync",
                status: .idle,
                workspaceID: "preview-workspace",
                tabID: "preview-tab",
                paneID: "preview-pane",
                cwd: "/work/waycar",
                revision: 1,
                name: "claude",
                terminalTitle: "fix sidebar sync",
                terminalTitleStripped: "fix sidebar sync",
                paneTitle: "claude",
                tokens: ["branch": "feat/sidebar"]),
            workspaceLabel: "waycar",
            repositoryCheckout: nil,
            summary: AgentSummary(
                paneID: "preview-pane", status: .idle,
                text: "Fixed the sidebar sync race; waiting for your next prompt",
                timestamp: Int64(Date.now.addingTimeInterval(-60).timeIntervalSince1970 * 1000)),
            tabLabel: "1",
            tabPosition: 1,
            workspaceTabCount: 2)
    }

    private nonisolated static let sampleHostID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
    ))
}
