import Foundation
import Testing

@testable import Waycar

/// What a confirmed mutation does to a snapshot (#105): the state herdr
/// reports once it has landed.
@Suite("Console local edit")
struct ConsoleLocalEditTests {
    private static let snapshot = SessionSnapshot(
        agents: [
            .fixture(paneID: "w1:p1", name: "old"),
            .fixture(paneID: "w2:p1", workspaceID: "w2"),
        ],
        layouts: [], panes: [], protocolVersion: 22,
        tabs: [
            TabInfo(
                agentStatus: .idle, focused: false, label: "1", number: 1, paneCount: 1,
                tabID: "w1:t1", workspaceID: "w1"),
            TabInfo(
                agentStatus: .idle, focused: false, label: "1", number: 1, paneCount: 1,
                tabID: "w2:t1", workspaceID: "w2"),
            TabInfo(
                agentStatus: .idle, focused: false, label: "2", number: 2, paneCount: 1,
                tabID: "w2:t2", workspaceID: "w2"),
        ],
        version: "0.9.3",
        workspaces: [
            .fixture(workspaceID: "w1", label: "Proj"), .fixture(workspaceID: "w2", label: "Api"),
        ])

    @Test func renamesLandWhereHerdrReportsThem() {
        let agent = ConsoleLocalEdit.renameAgent(paneID: "w1:p1", name: "reviewer")
            .applied(to: Self.snapshot)
        #expect(Agent(agent.agents[0]).displayName == "reviewer")
        #expect(agent.agents[1] == Self.snapshot.agents[1])

        let cleared = ConsoleLocalEdit.renameAgent(paneID: "w1:p1", name: nil)
            .applied(to: Self.snapshot)
        #expect(Agent(cleared.agents[0]).displayName == "claude")

        let workspace = ConsoleLocalEdit.renameWorkspace(workspaceID: "w2", label: "Backend")
            .applied(to: Self.snapshot)
        #expect(workspace.workspaces.map(\.label) == ["Proj", "Backend"])

        let tab = ConsoleLocalEdit.renameTab(tabID: "w2:t2", label: "logs")
            .applied(to: Self.snapshot)
        #expect(tab.tabs.map(\.label) == ["1", "1", "logs"])
    }

    @Test func closingAWorkspacesLastTabClosesTheWorkspace() {
        let last = ConsoleLocalEdit.closeTab(tabID: "w1:t1").applied(to: Self.snapshot)
        #expect(last.agents.map(\.paneID) == ["w2:p1"])
        #expect(last.tabs.map(\.tabID) == ["w2:t1", "w2:t2"])
        #expect(last.workspaces.map(\.workspaceID) == ["w2"])

        let notLast = ConsoleLocalEdit.closeTab(tabID: "w2:t2").applied(to: Self.snapshot)
        #expect(notLast.workspaces.map(\.workspaceID) == ["w1", "w2"])

        let pane = ConsoleLocalEdit.closePane(paneID: "w2:p1").applied(to: Self.snapshot)
        #expect(pane.agents.map(\.paneID) == ["w1:p1"])
    }
}
