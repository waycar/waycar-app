import Foundation
import Testing

@testable import Waycar

@Suite("Agent footer renderer")
struct AgentFooterRendererTests {
    private func agent(
        backend: HostBackend = .herdr, status: AgentStatus = .idle, summary: AgentSummary? = nil,
        isSummaryPending: Bool = false
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: "Studio Mac",
            agent: Agent(
                terminalID: "term", kind: "claude", title: "Fix", status: status,
                workspaceID: "w", tabID: "t", paneID: "p", cwd: "/work/waycar", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil, summary: summary,
            isSummaryPending: isSummaryPending, backend: backend)
    }

    private func layout(_ lines: [[AgentFooterField]], isEnabled: Bool = true) -> AgentFooterLayout {
        AgentFooterLayout(isEnabled: isEnabled, lines: lines, textSize: .medium)
    }

    @Test func joinsValuesAndSkipsEmptyOnesAndLines() {
        let context = AgentFooterContext(agent: agent(), branch: "main", model: "  ", costText: "$0.12")
        let lines = AgentFooterRenderer.render(
            layout: layout([[.row(.host), .model, .branch], [.rate, .context], [.cost]]),
            context: context)
        #expect(lines == ["Studio Mac · main", "$0.12"])
    }

    /// A herdr worktree Workspace carries the branch name: a value equal
    /// (trimmed) to one earlier on the same line is dropped with its
    /// separator, as on the Agent row (#190); another line may repeat it.
    @Test func aValueRepeatedOnALineShowsOnce() {
        let base = agent()
        let row = ConsoleAgent(
            hostID: base.hostID, hostName: base.hostName, agent: base.agent,
            workspaceLabel: "feat/sidebar", repositoryCheckout: nil)
        let context = AgentFooterContext(agent: row, branch: " feat/sidebar")
        let lines = AgentFooterRenderer.render(
            layout: layout([[.row(.workspace), .branch, .row(.host)], [.branch]]), context: context)
        #expect(lines == ["feat/sidebar · Studio Mac", " feat/sidebar"])
    }

    @Test func maximumLinesCapsConfiguredLinesNotRenderedOnes() {
        let context = AgentFooterContext(agent: agent(), branch: "main", costText: "$1")
        let configured = layout([[.rate], [], [.branch], [.cost]])
        // The first configured line has no value yet: nothing, never line 2 promoted.
        #expect(AgentFooterRenderer.render(layout: configured, context: context, maximumLines: 1).isEmpty)
        #expect(AgentFooterRenderer.displayedUsageFields(
            layout: configured, context: context, maximumLines: 1).isEmpty)
        // Empty configured lines are skipped, so `.cost` is the third shown line.
        #expect(AgentFooterRenderer.render(layout: configured, context: context) == ["main", "$1"])
        #expect(AgentFooterRenderer.displayedUsageFields(layout: configured, context: context) == [.cost])
        #expect(AgentFooterRenderer.displayedUsageFields(
            layout: configured, context: context, maximumLines: 2).isEmpty)
    }

    @Test func takesAllUsageNeedsEveryUsageFieldOnShownLines() {
        let all = layout([[.model, .context], [.cost, .rate]])
        #expect(AgentFooterBand.takesAllUsage(layout: all, maximumLines: 3))
        #expect(!AgentFooterBand.takesAllUsage(layout: all, maximumLines: 1))
        #expect(!AgentFooterBand.takesAllUsage(
            layout: layout([[.model, .context, .cost, .rate]], isEnabled: false), maximumLines: 3))
    }

    @Test func lineCapFollowsBandHeightAndCompactHeight() {
        #expect(AgentFooterBand.lineCap(isCompactHeight: false, height: 6) == 0)
        #expect(AgentFooterBand.lineCap(isCompactHeight: true, height: 40) == 1)
        #expect(AgentFooterBand.lineCap(isCompactHeight: false, height: 40) == 3)
    }

    @Test func aDisabledLayoutShowsNothing() {
        let context = AgentFooterContext(agent: agent(), costText: "$1")
        let configured = layout([[.row(.host), .cost]], isEnabled: false)
        #expect(AgentFooterRenderer.render(layout: configured, context: context).isEmpty)
        #expect(AgentFooterRenderer.displayedUsageFields(layout: configured, context: context).isEmpty)
    }

    @Test func backendAndTransportReadAsTheirNames() {
        #expect(AgentFooterRenderer.value(for: .backend, context: .init(agent: agent())) == "Herdr TUI")
        #expect(AgentFooterRenderer.value(for: .backend, context: .init(agent: agent(backend: .tmux))) == "tmux")
        #expect(AgentFooterRenderer.value(for: .transport, context: .init(agent: agent(), transport: .ssh)) == "SSH")
        #expect(AgentFooterRenderer.value(for: .transport, context: .init(agent: agent(), transport: .mosh)) == "mosh")
        #expect(AgentFooterRenderer.value(for: .transport, context: .init(agent: agent())) == nil)
        #expect(AgentFooterRenderer.value(for: .row(.directory), context: .init(agent: agent())) == "/work/waycar")
    }

    /// The footer prints a progress estimate only while it is fresh: a stale
    /// one or a pending bar reads as nothing rather than a misleading figure.
    @Test func progressShowsOnlyAFreshEstimate() throws {
        let now = Date(timeIntervalSince1970: 1_766_000_000)
        func summary(_ status: AgentStatus, secondsAgo: TimeInterval) throws -> AgentSummary {
            AgentSummary(
                paneID: "p", status: status, text: "adding retries",
                timestamp: Int64((now.timeIntervalSince1970 - secondsAgo) * 1000),
                progress: try #require(AgentProgress(steps: .init(done: 3, total: 7), phase: .verifying)))
        }
        func value(_ agent: ConsoleAgent) -> String? {
            AgentFooterRenderer.value(
                for: .progress, context: .init(agent: agent, progress: agent.progressDisplay(at: now)))
        }
        #expect(value(agent(status: .working, summary: try summary(.working, secondsAgo: 30))) == "3/7")
        #expect(value(agent(status: .blocked, summary: try summary(.blocked, secondsAgo: 30))) == "3/7")
        #expect(value(agent(status: .working, summary: try summary(.working, secondsAgo: 600))) == nil)
        #expect(value(agent(status: .working, summary: try summary(.blocked, secondsAgo: 30))) == nil)
        #expect(value(agent(status: .working, isSummaryPending: true)) == nil)
        #expect(value(agent(status: .done, summary: try summary(.working, secondsAgo: 30))) == nil)

        let fresh = agent(status: .working, summary: try summary(.working, secondsAgo: 30))
        let lines = AgentFooterRenderer.render(
            layout: .default, context: .init(agent: fresh, progress: fresh.progressDisplay(at: now)))
        #expect(lines.count == 1)
        #expect(lines.first?.hasSuffix("/work/waycar · 3/7") == true)
    }
}
