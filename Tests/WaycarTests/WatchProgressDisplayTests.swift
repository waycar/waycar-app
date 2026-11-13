import Foundation
import Testing

@testable import Waycar

/// Agent Progress on the watch (#199): which rows draw a bar, when an
/// estimate dims, and what VoiceOver hears.
@Suite("Watch progress display")
struct WatchProgressDisplayTests {
    // MARK: Fixtures

    /// The clock the rows are read at.
    private static let now = Date(timeIntervalSince1970: 1_791_800_000)

    /// A row with the given status and progress.
    private static func row(_ status: String, _ progress: WatchProgress?) -> WatchAgentRow {
        WatchAgentRow(
            id: WatchAgentID(hostID: UUID(), paneID: "p"), title: "site · codex", status: status,
            statusSince: now, hostName: "studio", isChatMode: false, progress: progress)
    }

    /// Plan steps, fresh for three minutes from `now`.
    private static let steps = WatchProgress(
        done: 3, total: 7, phase: nil, staleAfter: now.addingTimeInterval(180))
    /// No estimate yet.
    private static let pending = WatchProgress(done: nil, total: nil, phase: nil, staleAfter: nil)

    /// The estimate `steps` stands for.
    private static func threeOfSeven() throws -> AgentProgress {
        try #require(AgentProgress(steps: AgentProgress.Steps(done: 3, total: 7), phase: nil))
    }

    // MARK: Which rows draw a bar

    @Test func workingEstimateIsFreshUntilStaleAfterThenStale() throws {
        let row = Self.row("working", Self.steps)
        let progress = try Self.threeOfSeven()
        #expect(row.progressDisplay(at: Self.now) == .estimate(progress, isStale: false))
        #expect(row.progressDisplay(at: Self.now.addingTimeInterval(179)) == .estimate(progress, isStale: false))
        #expect(row.progressDisplay(at: Self.now.addingTimeInterval(180)) == .estimate(progress, isStale: true))
    }

    @Test func pendingShowsOnlyForWorking() {
        #expect(Self.row("working", Self.pending).progressDisplay(at: Self.now) == .pending)
        #expect(Self.row("blocked", Self.pending).progressDisplay(at: Self.now) == nil)
    }

    @Test func blockedKeepsItsFrozenEstimate() throws {
        let progress = try Self.threeOfSeven()
        let display = Self.row("blocked", Self.steps).progressDisplay(at: Self.now)
        #expect(display == .estimate(progress, isStale: false))
        #expect(Self.row("blocked", nil).progressDisplay(at: Self.now) == nil)
    }

    @Test(arguments: ["done", "idle", "unknown", "shell"])
    func otherStatusesDrawNothing(status: String) {
        #expect(Self.row(status, Self.steps).progressDisplay(at: Self.now) == nil)
        #expect(Self.row(status, Self.pending).progressDisplay(at: Self.now) == nil)
    }

    @Test func noProgressDrawsNothing() {
        #expect(Self.row("working", nil).progressDisplay(at: Self.now) == nil)
    }

    // MARK: Degrading

    @Test func invalidStepsFallBackToPhase() throws {
        let progress = WatchProgress(done: 9, total: 7, phase: "verifying", staleAfter: nil)
        let estimate = try #require(progress.estimate)
        #expect(estimate.steps == nil)
        #expect(estimate.phase == .verifying)
        #expect(Self.row("working", progress).progressDisplay(at: Self.now) == .estimate(estimate, isStale: false))
    }

    @Test func invalidStepsAndUnknownPhaseArePending() {
        let progress = WatchProgress(done: 3, total: nil, phase: "dreaming", staleAfter: nil)
        #expect(progress.estimate == nil)
        #expect(progress.isPending)
        #expect(Self.row("working", progress).progressDisplay(at: Self.now) == .pending)
    }

    @Test func labelsShowStepsOrPhase() throws {
        let steps = try Self.threeOfSeven()
        #expect(AgentProgressDisplay.estimate(steps, isStale: false).watchLabel == "3/7")
        let exploring = try #require(AgentProgress(steps: nil, phase: .exploring))
        #expect(AgentProgressDisplay.estimate(exploring, isStale: true).watchLabel == "Exploring")
        #expect(AgentProgressDisplay.pending.watchLabel == nil)
    }

    @Test func spokenTextSaysStepsAndOutOfDateNeverPercent() throws {
        let progress = try Self.threeOfSeven()
        let fresh = try #require(AgentProgressDisplay.estimate(progress, isStale: false).watchSpokenLabel)
        let stale = try #require(AgentProgressDisplay.estimate(progress, isStale: true).watchSpokenLabel)
        #expect(fresh == "3 of 7 steps done")
        #expect(stale == "3 of 7 steps done, out of date")
        #expect(!fresh.contains("%") && !stale.contains("%"))
        #expect(!fresh.contains("percent") && !stale.contains("percent"))
        #expect(AgentProgressDisplay.pending.watchSpokenLabel == nil)
    }
}
