import Foundation
import Testing

@testable import Waycar

/// The order, headlines and ages CarPlay and the Apple Watch both show.
@MainActor
@Suite("Agent glance list")
struct AgentGlanceListTests {
    private let host = Host.fixture(name: "studio")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func consoleAgent(
        _ paneID: String, _ status: AgentStatus, kind: String = "claude",
        workspace: String? = "iOS App", name: String? = nil, tab: String? = nil, seq: Int? = nil,
        summaryMinutesAgo: Int? = nil, summaryStatus: AgentStatus? = nil,
        backend: HostBackend = .herdr
    ) -> ConsoleAgent {
        let summary = summaryMinutesAgo.map { minutes in
            AgentSummary(
                paneID: paneID, status: summaryStatus ?? status, text: "secret summary text",
                timestamp: Int64((now.timeIntervalSince1970 - Double(minutes * 60)) * 1000))
        }
        return ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(
                .fixture(paneID: paneID, status: status, kind: kind, name: name, stateChangeSeq: seq)),
            workspaceLabel: workspace, repositoryCheckout: nil, summary: summary,
            tabLabel: tab, workspaceTabCount: tab == nil ? 0 : 2, backend: backend)
    }

    // MARK: Order

    @Test func listsBlockedDoneWorkingIdleAndDropsShells() {
        let listed = AgentGlanceList.listed([
            consoleAgent("idle", .idle),
            consoleAgent("shell", .idle, kind: Agent.shellKind),
            consoleAgent("working", .working),
            consoleAgent("done", .done),
            consoleAgent("blocked", .blocked),
        ])
        #expect(listed.map(\.id.paneID) == ["blocked", "done", "working", "idle"])
    }

    @Test func newestStatusChangeLeadsOnlyWithinOneBackend() {
        // tmux counts wall-clock nanoseconds, herdr a small counter: the
        // tmux row must not lead just because its number is bigger.
        let listed = AgentGlanceList.listed([
            consoleAgent("tmux:1", .blocked, seq: 1_800_000_000_000_000_000, backend: .tmux),
            consoleAgent("old", .blocked, seq: 3), consoleAgent("new", .blocked, seq: 9),
        ])
        #expect(listed.map(\.id.paneID) == ["new", "old", "tmux:1"])
    }

    @Test func onlyAListedAgentIsFoundByID() {
        let agents = [consoleAgent("codex", .idle), consoleAgent("shell", .idle, kind: Agent.shellKind)]
        #expect(AgentGlanceList.listedAgent(agents[0].id, in: agents)?.id == agents[0].id)
        #expect(AgentGlanceList.listedAgent(agents[1].id, in: agents) == nil)
        let unknown = ConsoleAgent.ID(hostID: host.id, paneID: "nope")
        #expect(AgentGlanceList.listedAgent(unknown, in: agents) == nil)
    }

    // MARK: Title

    @Test func unsafeWorkspaceFallsBackToKindAlone() {
        let agent = consoleAgent("p", .idle, kind: "codex", workspace: "/etc/passwd")
        #expect(AgentGlanceList.title(for: agent) == "Codex")
    }

    @Test func titleIsWorkspaceAndNameLikeThePhoneCard() {
        let partners = consoleAgent("a", .idle, kind: "omp", workspace: "Data", name: "Partners DO/TO")
        let share = consoleAgent("b", .idle, kind: "omp", workspace: "Data", name: "app-store-rev share")
        #expect(AgentGlanceList.title(for: partners) == "Data · Partners DO/TO")
        #expect(AgentGlanceList.title(for: share) == "Data · app-store-rev share")
        #expect(
            AgentGlanceList.title(for: consoleAgent("c", .idle, workspace: "proxmox", name: "notes"))
                == "proxmox · notes")
    }

    @Test func nameEqualToWorkspaceIsShownOnce() {
        let agent = consoleAgent("p", .idle, kind: "omp", workspace: "apple-carplay", name: "Apple-CarPlay")
        #expect(AgentGlanceList.title(for: agent) == "apple-carplay")
    }

    @Test func noNameFallsBackToKind() {
        let agent = consoleAgent("p", .idle, kind: "omp", workspace: "Data", name: "  ")
        #expect(AgentGlanceList.title(for: agent) == "Data · OMP")
    }

    @Test func herdrTitleUsesTheTabLabelLikeThePhoneHeadline() {
        let partners = consoleAgent(
            "a", .idle, kind: "omp", workspace: "Data", name: "omp", tab: "Partners DO/TO")
        let share = consoleAgent(
            "b", .idle, kind: "omp", workspace: "Data", name: "omp", tab: "app-store-rev share")
        #expect(AgentGlanceList.title(for: partners) == "Data · Partners DO/TO")
        #expect(AgentGlanceList.title(for: share) == "Data · app-store-rev share")
    }

    @Test func tmuxAutoRenameTabLabelFallsBackToKind() {
        let agent = consoleAgent(
            "p", .idle, workspace: "proxmox", name: nil, tab: "2.1.286", backend: .tmux)
        #expect(AgentGlanceList.title(for: agent) == "proxmox · Claude")
        let named = consoleAgent(
            "q", .idle, workspace: "proxmox", name: "notes", tab: "notes", backend: .tmux)
        #expect(AgentGlanceList.title(for: named) == "proxmox · notes")
    }

    @Test func adversarialNamesAreSanitized() {
        let boxed = consoleAgent("a", .idle, workspace: "Data", tab: "╭─ a/b\u{7}\tc ─╮")
        #expect(AgentGlanceList.title(for: boxed) == "Data · a/b c")
        let long = consoleAgent(
            "b", .idle, workspace: "Data", name: "notes",
            tab: "A tab label far too long for any car screen")
        #expect(AgentGlanceList.title(for: long) == "Data · notes")
    }

    @Test(arguments: [
        ("rm `x`", nil),
        ("Checkout", "Checkout"),
        ("~/src/waycar", nil),
        ("  iOS\tApp\u{7} ", "iOS App"),
        ("╭─ box ─╮", "box"),
        (String(repeating: "x", count: AgentGlanceList.maximumWorkspaceLength + 1), nil),
        ("   ", nil),
        ("", nil),
    ] as [(String, String?)])
    func workspaceLabelsAreSanitized(label: String, expected: String?) {
        #expect(AgentGlanceList.sanitizedWorkspace(label) == expected)
    }

    // MARK: Age

    @Test func statusAgeNeedsASummaryWrittenInTheSameStatus() {
        #expect(AgentGlanceList.statusAge(of: consoleAgent("a", .done, summaryMinutesAgo: 4), now: now) == "4m")
        #expect(
            AgentGlanceList.statusAge(
                of: consoleAgent("b", .done, summaryMinutesAgo: 4, summaryStatus: .working), now: now)
                == nil)
        #expect(AgentGlanceList.statusAge(of: consoleAgent("c", .done), now: now) == nil)
    }
}
