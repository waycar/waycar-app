import Foundation
import Testing

@testable import Waycar

/// Agent Progress in the terminal screen's status row (#210): only a
/// Working Agent adds its label and short bar; every other row is unchanged.
@Suite("Agent status row progress")
struct AgentStatusRowProgressTests {
    private static func estimate() throws -> AgentProgress {
        try #require(AgentProgress(steps: .init(done: 3, total: 7), phase: nil))
    }

    private static let now = Date(timeIntervalSince1970: 1_766_000_000)

    private static func agent(
        _ status: AgentStatus, progress: AgentProgress?, hostReportsProgress: Bool = true
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: "mac",
            agent: Agent(
                terminalID: "t", kind: "claude", title: "", status: status,
                workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1", cwd: "/", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil,
            summary: AgentSummary(
                paneID: "w1:p1", status: status, text: "adding retries",
                timestamp: Int64(now.timeIntervalSince1970 * 1000), progress: progress,
                progressTimestamp: nil),
            isSummaryPending: false, hostReportsProgress: hostReportsProgress)
    }

    /// The chrome's composition from a live Agent: fresh, then stale once
    /// the summary is older than `AgentSummary.freshness`, without a new read.
    @Test func aWorkingAgentTurnsStaleOverTime() throws {
        let progress = try Self.estimate()
        let agent = Self.agent(.working, progress: progress)

        let fresh = AgentStatusRowProgress.resolve(agent: agent, status: .working, at: Self.now.addingTimeInterval(30))
        #expect(fresh.label == "3/7")
        #expect(fresh.isLabelStale == false)
        #expect(fresh.bar == .estimate)
        #expect(fresh.spokenValue == "Working, 3 of 7 steps done")

        let later = Self.now.addingTimeInterval(max(AgentSummary.freshness, 300) + 1)
        let stale = AgentStatusRowProgress.resolve(agent: agent, status: .working, at: later)
        #expect(stale.label == "3/7")
        #expect(stale.isLabelStale)
        #expect(stale.bar == .estimate)
        #expect(stale.spokenValue.hasPrefix("Working, 3 of 7 steps done, as of "))
        #expect(!stale.spokenValue.contains("%"))
    }

    @Test func aLiveAgentReadsPlainOutsideWorking() throws {
        let progress = try Self.estimate()
        let blocked = AgentStatusRowProgress.resolve(
            agent: Self.agent(.blocked, progress: progress), status: .blocked, at: Self.now)
        #expect(blocked.isPlain)
        #expect(blocked.spokenValue == "Blocked")
        let pending = AgentStatusRowProgress.resolve(
            agent: Self.agent(.working, progress: nil), status: .working, at: Self.now)
        #expect(pending.bar == .pending)
        #expect(pending.spokenValue == "Working")
        let none = AgentStatusRowProgress.resolve(agent: nil, status: .working, at: Self.now)
        #expect(none.isPlain)
    }

    @Test func workingFreshEstimateShowsLabelBarAndSpokenValue() throws {
        let progress = try Self.estimate()
        let row = AgentStatusRowProgress.resolve(
            status: .working, display: .estimate(progress, isStale: false),
            spokenProgress: "3 of 7 steps done")
        #expect(row.label == "3/7")
        #expect(row.isLabelStale == false)
        #expect(row.bar == .estimate)
        #expect(row.spokenValue == "Working, 3 of 7 steps done")
        #expect(row.display == .estimate(progress, isStale: false))
    }

    @Test func workingStaleEstimateKeepsLabelMarkedStale() throws {
        let progress = try Self.estimate()
        let row = AgentStatusRowProgress.resolve(
            status: .working, display: .estimate(progress, isStale: true),
            spokenProgress: "3 of 7 steps done, as of 5 minutes ago")
        #expect(row.label == "3/7")
        #expect(row.isLabelStale)
        #expect(row.bar == .estimate)
        #expect(row.spokenValue == "Working, 3 of 7 steps done, as of 5 minutes ago")
    }

    @Test func workingPendingShowsDottedBarOnly() {
        let row = AgentStatusRowProgress.resolve(status: .working, display: .pending, spokenProgress: nil)
        #expect(row.label == nil)
        #expect(row.bar == .pending)
        #expect(row.spokenValue == "Working")
    }

    @Test func workingWithoutProgressIsPlain() {
        let row = AgentStatusRowProgress.resolve(status: .working, display: nil, spokenProgress: nil)
        #expect(row.label == nil)
        #expect(row.bar == .none)
        #expect(row.spokenValue == "Working")
    }

    /// Blocked keeps a frozen estimate on its card, but the status row
    /// shows progress only while Working.
    @Test func otherStatusesShowNothing() throws {
        let progress = try Self.estimate()
        for status in [AgentStatus.blocked, .done, .idle, .unknown, .shellTerminal] {
            for display in [AgentProgressDisplay.estimate(progress, isStale: false), .pending] {
                let row = AgentStatusRowProgress.resolve(
                    status: status, display: display, spokenProgress: "3 of 7 steps done")
                #expect(row.label == nil)
                #expect(row.bar == .none)
                #expect(row.display == nil)
                #expect(row.spokenValue == status.rawValue.capitalized)
            }
        }
    }

    @Test func spokenValueNeverHasAPercent() throws {
        let progress = try Self.estimate()
        let phase = try #require(AgentProgress(steps: nil, phase: .verifying))
        for display in [
            AgentProgressDisplay.estimate(progress, isStale: false), .estimate(phase, isStale: true), .pending,
        ] {
            let spoken: String? =
                if case .estimate(let estimate, _) = display { estimate.spokenLabel } else { nil }
            let row = AgentStatusRowProgress.resolve(
                status: .working, display: display, spokenProgress: spoken)
            #expect(!row.spokenValue.contains("%"))
        }
    }
}
