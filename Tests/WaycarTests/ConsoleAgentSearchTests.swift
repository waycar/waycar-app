import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Console agent search")
struct ConsoleAgentSearchTests {
    private func makeAgent(
        host: Host,
        paneID: String,
        cwd: String = "/work/w1",
        title: String = "Task",
        name: String? = nil,
        terminalTitle: String? = nil,
        terminalTitleStripped: String? = nil,
        paneTitle: String? = nil,
        workspaceLabel: String? = nil,
        tabLabel: String? = nil,
        paneLabel: String? = nil
    ) -> ConsoleAgent {
        let agent = Agent(
            terminalID: "term_\(paneID)", kind: "codex", title: title, status: .idle,
            workspaceID: "w1", tabID: "w1:t1", paneID: paneID, cwd: cwd, revision: 1,
            name: name, terminalTitle: terminalTitle,
            terminalTitleStripped: terminalTitleStripped, paneTitle: paneTitle)
        return ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: agent,
            workspaceLabel: workspaceLabel,
            repositoryCheckout: nil,
            tabLabel: tabLabel,
            paneLabel: paneLabel)
    }

    @Test func emptyQueryMatchesEveryAgent() {
        let host = Host.fixture(name: "studio")
        let agent = makeAgent(host: host, paneID: "w1:p1")
        #expect(agent.matchesAgentSearch(""))
        #expect(agent.matchesAgentSearch("   "))
    }

    @Test func matchesWorkingDirectorySubstringCaseInsensitively() {
        let host = Host.fixture(name: "studio")
        let agent = makeAgent(host: host, paneID: "w1:p1", cwd: "/work/Waycar-Checkout")
        #expect(agent.matchesAgentSearch("waycar"))
        #expect(agent.matchesAgentSearch("WAYCAR-CHECK"))
        #expect(!agent.matchesAgentSearch("definitely-absent"))
    }

    @Test func matchesEachTitleAndVisibleTextField() {
        let host = Host.fixture(name: "studio")
        let marker = "QuarryQuartz"
        let agents = [
            makeAgent(host: host, paneID: "w1:p1", workspaceLabel: "ws-\(marker)"),
            makeAgent(host: host, paneID: "w1:p2", tabLabel: "tab-\(marker)"),
            makeAgent(host: host, paneID: "w1:p3", paneLabel: "pane-\(marker)"),
            makeAgent(host: host, paneID: "w1:p4", title: "title-\(marker)"),
            makeAgent(host: host, paneID: "w1:p5", paneTitle: "ptitle-\(marker)"),
            makeAgent(host: host, paneID: "w1:p6", name: "name-\(marker)"),
            makeAgent(host: host, paneID: "w1:p7", terminalTitle: "term-\(marker)"),
            makeAgent(
                host: host, paneID: "w1:p8", terminalTitleStripped: "stripped-\(marker)"),
        ]
        for agent in agents {
            #expect(agent.matchesAgentSearch(marker.lowercased()))
        }
    }
    @Test func skipsNilAndEmptyFieldsWithoutMatching() {
        let host = Host.fixture(name: "studio")
        let agent = makeAgent(
            host: host, paneID: "w1:p1", cwd: "", title: "",
            terminalTitle: "", terminalTitleStripped: "", paneTitle: "")
        #expect(!agent.matchesAgentSearch("definitely-absent"))
        #expect(agent.matchesAgentSearch(""))
    }

    @Test func searchComposesWithHostScope() {
        let hostA = Host.fixture(name: "studio")
        let hostB = Host.fixture(name: "laptop")
        let hosts = [hostA, hostB]
        let agents = [
            makeAgent(host: hostA, paneID: "w1:p1", title: "Alpha work"),
            makeAgent(host: hostB, paneID: "w1:p2", title: "Beta work"),
        ]
        func visible(hostID: Host.ID?, query: String) -> [String] {
            let options = ConsoleListProjection.workspaceOptions(
                hosts: hosts, agents: agents, workspacesByHost: [:], hostID: hostID)
            return ConsoleListProjection.visibleAgents(
                workspaceAgents: ConsoleListProjection.workspaceAgents(
                    options: options, selected: .all),
                status: .all, searchQuery: query
            ).map(\.agent.paneID)
        }

        #expect(visible(hostID: hostA.id, query: "alpha") == ["w1:p1"])
        #expect(visible(hostID: hostA.id, query: "beta").isEmpty)
        #expect(visible(hostID: nil, query: "beta") == ["w1:p2"])
        // The query is trimmed; a blank one filters nothing.
        #expect(visible(hostID: nil, query: "  ALPHA ") == ["w1:p1"])
        #expect(visible(hostID: nil, query: "   ") == ["w1:p1", "w1:p2"])
    }

    @Test func surfaceSelectsNoSearchResultsWhileSearching() {
        let searching = ConsoleAgentsSurface(
            hostCount: 2, filteredHostName: nil, filteredAgentCount: 0,
            visibleIssueCount: 0, searchQuery: "alpha")
        #expect(searching == .noSearchResults)
        #expect(searching != .noAgents)

        let idle = ConsoleAgentsSurface(
            hostCount: 2, filteredHostName: nil, filteredAgentCount: 0,
            visibleIssueCount: 0)
        #expect(idle == .noAgents)

        let searchingOnFilteredHost = ConsoleAgentsSurface(
            hostCount: 2, filteredHostName: "studio", filteredAgentCount: 0,
            visibleIssueCount: 0, searchQuery: "alpha")
        #expect(searchingOnFilteredHost == .noSearchResults)

        // A search replaces the Status filter, so its empty state wins.
        let searchingUnderAStatus = ConsoleAgentsSurface(
            hostCount: 2, filteredHostName: nil, filteredAgentCount: 0,
            visibleIssueCount: 0, statusFilter: .blocked, searchQuery: "alpha")
        #expect(searchingUnderAStatus == .noSearchResults)

        let searchingWithVisibleIssues = ConsoleAgentsSurface(
            hostCount: 2, filteredHostName: nil, filteredAgentCount: 0,
            visibleIssueCount: 1, searchQuery: "alpha")
        #expect(searchingWithVisibleIssues == .rows)

        let searchingWithMatches = ConsoleAgentsSurface(
            hostCount: 2, filteredHostName: nil, filteredAgentCount: 1,
            visibleIssueCount: 0, searchQuery: "alpha")
        #expect(searchingWithMatches == .rows)
    }
}
