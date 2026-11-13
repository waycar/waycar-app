import Foundation
import Testing

@testable import Waycar

/// What CarPlay adds to `AgentGlanceList` (order, titles and ages are
/// tested there): the cap with the Talk row, the `Status · progress · age`
/// detail and the progress ring.
@MainActor
@Suite("CarPlay list model")
struct CarPlayListModelTests {
    private let host = Host.fixture(name: "studio")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func consoleAgent(
        _ paneID: String, _ status: AgentStatus, summaryMinutesAgo: Int? = nil,
        summaryStatus: AgentStatus? = nil, progress: AgentProgress? = nil,
        summaryPending: Bool = false
    ) -> ConsoleAgent {
        let summary = summaryMinutesAgo.map { minutes in
            AgentSummary(
                paneID: paneID, status: summaryStatus ?? status, text: "secret summary text",
                timestamp: Int64((now.timeIntervalSince1970 - Double(minutes * 60)) * 1000),
                progress: progress)
        }
        return ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(.fixture(paneID: paneID, status: status, kind: "claude")),
            workspaceLabel: "iOS App", repositoryCheckout: nil, summary: summary,
            // A pending fixture stands for a current plugin, which reports progress.
            isSummaryPending: summaryPending, hostReportsProgress: summaryPending)
    }

    @Test func capCountsTheTalkRowAndNeverExceedsTwelve() {
        let agents = (0..<20).map { consoleAgent("p\($0)", .working) }
        #expect(CarPlayListModel(agents: agents, maximumItemCount: 6, now: now).rows.count == 5)
        #expect(CarPlayListModel(agents: agents, maximumItemCount: 24, now: now).rows.count == 11)
    }

    @Test func rowShowsIdentityStatusAndAgeButNoSummary() throws {
        let model = CarPlayListModel(
            agents: [consoleAgent("p", .blocked, summaryMinutesAgo: 2)],
            maximumItemCount: 12, now: now)
        let row = try #require(model.rows.first)
        #expect(row.title == "iOS App · Claude")
        #expect(row.detail == "Blocked · 2m")
        #expect(row.symbolName == "hand.raised.fill")
        #expect(!row.title.contains("secret") && !row.detail.contains("secret"))
    }

    @Test func detailIsTheStatusWordAloneWithoutAnAge() {
        let model = CarPlayListModel(
            agents: [consoleAgent("p", .done, summaryMinutesAgo: 5, summaryStatus: .working)],
            maximumItemCount: 12, now: now)
        #expect(model.rows.first?.detail == "Done")
    }

    private func steps(_ done: Int, of total: Int) -> AgentProgress? {
        AgentProgress(steps: .init(done: done, total: total), phase: nil)
    }

    private func onlyRow(_ agent: ConsoleAgent) throws -> CarPlayListModel.Row {
        try #require(CarPlayListModel(agents: [agent], maximumItemCount: 12, now: now).rows.first)
    }

    @Test func workingStepsSitBetweenStatusAndAgeWithOneSegmentPerStep() throws {
        let row = try onlyRow(consoleAgent("p", .working, summaryMinutesAgo: 2, progress: steps(3, of: 7)))
        #expect(row.detail == "Working · 3/7 · 2m")
        #expect(row.ring == CarPlayListModel.Ring(shape: .segments(count: 7, filled: 3), isStale: false))
        #expect(!row.detail.contains("secret"))
    }

    @Test func phaseReadsLowercaseAndFillsFourSegmentsToThePhase() throws {
        let verifying = try onlyRow(
            consoleAgent(
                "p", .working, summaryMinutesAgo: 12,
                progress: AgentProgress(steps: nil, phase: .verifying)))
        #expect(verifying.detail == "Working · verifying · 12m")
        #expect(verifying.ring?.shape == .segments(count: 4, filled: 3))
        let wrapping = try onlyRow(
            consoleAgent(
                "p", .working, summaryMinutesAgo: 1,
                progress: AgentProgress(steps: nil, phase: .wrappingUp)))
        #expect(wrapping.detail == "Working · wrapping up · 1m")
        #expect(wrapping.ring?.shape == .segments(count: 4, filled: 4))
    }

    @Test func blockedShowsItsFrozenSteps() throws {
        let row = try onlyRow(consoleAgent("p", .blocked, summaryMinutesAgo: 4, progress: steps(2, of: 4)))
        #expect(row.detail == "Blocked · 2/4 · 4m")
        #expect(row.ring?.shape == .segments(count: 4, filled: 2))
    }

    @Test func pendingOrNoEstimateKeepsTodaysDetailAndNoRing() throws {
        let pending = try onlyRow(consoleAgent("p", .working, summaryPending: true))
        #expect(pending.progress == .pending)
        #expect(pending.detail == "Working")
        #expect(pending.ring == nil)
        let noEstimate = try onlyRow(consoleAgent("p", .working, summaryMinutesAgo: 2))
        #expect(noEstimate.detail == "Working · 2m")
        #expect(noEstimate.ring == nil)
        let done = try onlyRow(consoleAgent("p", .done, summaryMinutesAgo: 1, progress: steps(7, of: 7)))
        #expect(done.detail == "Done · 1m")
        #expect(done.ring == nil)
    }

    @Test func estimateFromAnotherStatusOrOldIsStale() throws {
        let otherStatus = try onlyRow(
            consoleAgent(
                "p", .working, summaryMinutesAgo: 1, summaryStatus: .blocked,
                progress: steps(1, of: 3)))
        #expect(otherStatus.detail == "Working · 1/3")
        #expect(
            otherStatus.ring == CarPlayListModel.Ring(shape: .segments(count: 3, filled: 1), isStale: true))
        let old = try onlyRow(consoleAgent("p", .working, summaryMinutesAgo: 20, progress: steps(1, of: 3)))
        #expect(old.ring?.isStale == true)
    }

    @Test func moreThanTwelveStepsDrawAContinuousArc() throws {
        let twelve = try onlyRow(consoleAgent("p", .working, summaryMinutesAgo: 1, progress: steps(5, of: 12)))
        #expect(twelve.ring?.shape == .segments(count: 12, filled: 5))
        let twenty = try onlyRow(consoleAgent("p", .working, summaryMinutesAgo: 1, progress: steps(5, of: 20)))
        #expect(twenty.ring?.shape == .arc(fraction: 0.25))
    }

    /// Like the card's rail, finished steps never fill the ring: the turn
    /// is not over until the Agent says so.
    @Test func everyStepDoneStillLeavesTheRingOpen() throws {
        let seven = try onlyRow(consoleAgent("p", .working, summaryMinutesAgo: 1, progress: steps(7, of: 7)))
        #expect(seven.ring?.shape == .segments(count: 7, filled: 6))
        let twenty = try onlyRow(consoleAgent("p", .working, summaryMinutesAgo: 1, progress: steps(20, of: 20)))
        #expect(twenty.ring?.shape == .arc(fraction: 0.95))
    }

    @Test func progressChangeChangesTheModelSoTheListReRenders() {
        func model(_ progress: AgentProgress?) -> CarPlayListModel {
            CarPlayListModel(
                agents: [consoleAgent("p", .working, summaryMinutesAgo: 2, progress: progress)],
                maximumItemCount: 12, now: now)
        }
        #expect(model(steps(3, of: 7)) == model(steps(3, of: 7)))
        #expect(model(steps(3, of: 7)) != model(steps(4, of: 7)))
        #expect(model(steps(3, of: 7)) != model(nil))
    }
}
