import Foundation
import Testing

@testable import Waycar

/// Agent Progress (#189): the estimate the Host plugin stores with an Agent
/// Summary, how the app reads it, and what each Agent's bar shows.
@Suite("Agent Progress")
struct AgentProgressTests {
    private static let now = Date(timeIntervalSince1970: 1_766_000_000)

    private static func progress(
        _ done: Int?, of total: Int?, phase: AgentProgress.Phase? = nil
    ) -> AgentProgress? {
        let steps = done.flatMap { done in total.map { AgentProgress.Steps(done: done, total: $0) } }
        return AgentProgress(steps: steps, phase: phase)
    }

    private static func parse(_ line: String) -> AgentSummary? {
        AgentSummary.latestByPane(fromNDJSON: Data(line.utf8))["w1:p1"]
    }

    private static func line(progress: String) -> String {
        #"{"v":1,"pane":"w1:p1","status":"working","summary":"adding retries","ts":1766000000000,"progress":\#(progress)}"#
    }

    // MARK: Estimate

    /// Steps win over phase and never fill the bar; each phase sits at its
    /// fixed share.
    @Test func fractionCapsStepsAndPlacesPhases() throws {
        #expect(try #require(Self.progress(7, of: 7)).fraction == 0.95)
        #expect(try #require(Self.progress(3, of: 6, phase: .wrappingUp)).fraction == 0.5)
        #expect(try #require(Self.progress(0, of: 4)).fraction == 0)
        let phases: [(AgentProgress.Phase, Double)] = [
            (.exploring, 0.25), (.implementing, 0.5), (.verifying, 0.75), (.wrappingUp, 0.9),
        ]
        for (phase, fraction) in phases {
            #expect(try #require(Self.progress(nil, of: nil, phase: phase)).fraction == fraction)
        }
    }

    @Test func labelsReadStepsElseThePhase() throws {
        let steps = try #require(Self.progress(3, of: 7, phase: .verifying))
        #expect(steps.label == "3/7")
        #expect(steps.spokenLabel == "3 of 7 steps done")
        let expected: [(AgentProgress.Phase, String, String)] = [
            (.exploring, "Exploring", "exploring"), (.implementing, "Building", "building"),
            (.verifying, "Verifying", "verifying"), (.wrappingUp, "Wrapping up", "wrapping up"),
        ]
        for (phase, label, spoken) in expected {
            let progress = try #require(Self.progress(nil, of: nil, phase: phase))
            #expect(progress.label == label)
            #expect(progress.spokenLabel == spoken)
        }
    }

    /// The wire rule (0 ≤ done ≤ total, 1 ≤ total ≤ 99): invalid steps are
    /// dropped and the phase kept; nothing left is no estimate.
    @Test func invalidStepsAreDroppedButThePhaseKept() {
        #expect(Self.progress(0, of: 1)?.steps == .init(done: 0, total: 1))
        #expect(Self.progress(99, of: 99)?.steps == .init(done: 99, total: 99))
        for (done, total) in [(0, 0), (1, 100), (8, 7), (-1, 3)] {
            #expect(Self.progress(done, of: total) == nil, "\(done)/\(total)")
            let kept = Self.progress(done, of: total, phase: .implementing)
            #expect(kept?.steps == nil)
            #expect(kept?.phase == .implementing)
        }
        #expect(AgentProgress(steps: nil, phase: nil) == nil)
    }

    // MARK: Store record

    @Test func readsProgressFromTheStoreRecord() {
        #expect(
            Self.parse(Self.line(progress: #"{"done":3,"total":7,"phase":"verifying"}"#))?.progress
                == Self.progress(3, of: 7, phase: .verifying))
        #expect(
            Self.parse(Self.line(progress: #"{"phase":"wrapping_up"}"#))?.progress
                == Self.progress(nil, of: nil, phase: .wrappingUp))
        #expect(
            Self.parse(Self.line(progress: #"{"done":2,"total":5,"phase":"debugging"}"#))?.progress
                == Self.progress(2, of: 5))
    }

    /// A bad progress costs only the progress, never the summary.
    @Test func aBadProgressKeepsTheSummary() {
        let bad = [
            "null", #""3/7""#, "[3,7]", "{}", #"{"done":3}"#, #"{"done":3.5,"total":7}"#,
            #"{"done":"3","total":"7"}"#, #"{"done":0,"total":0}"#, #"{"done":8,"total":7}"#,
            #"{"done":1,"total":100}"#, #"{"phase":"debugging"}"#, #"{"phase":7}"#,
        ]
        for progress in bad {
            let summary = Self.parse(Self.line(progress: progress))
            #expect(summary?.text == "adding retries", "\(progress)")
            #expect(summary?.progress == nil, "\(progress)")
        }
        let absent = #"{"v":1,"pane":"w1:p1","status":"working","summary":"adding retries","ts":1}"#
        #expect(Self.parse(absent)?.progress == nil)
    }

    /// The same records the plugin writes, read the way its tests expect.
    @Test(arguments: AgentSummaryStoreVectorFile.shared.cases)
    func readsTheSharedStoreVector(vector: AgentSummaryStoreVectorFile.Case) throws {
        let summaries = AgentSummary.latestByPane(fromNDJSON: Data(vector.line.utf8))
        guard let expected = vector.expected else {
            #expect(summaries.isEmpty)
            return
        }
        let summary = try #require(summaries[expected.pane])
        #expect(summary.status == AgentStatus(rawValue: expected.status))
        #expect(summary.text == expected.summary)
        #expect(summary.timestamp == expected.ts)
        #expect(summary.progress?.steps?.done == expected.progress?.done)
        #expect(summary.progress?.steps?.total == expected.progress?.total)
        #expect(summary.progress?.phase?.rawValue == expected.progress?.phase)
        #expect(summary.progressTimestamp == expected.progressTS)
        #expect(summary.declaresProgress == expected.declaresProgress)
    }

    @Test func theSharedStoreVectorHasCases() {
        #expect(AgentSummaryStoreVectorFile.shared.cases.count >= 10)
    }

    /// `progress_ts` stamps the estimate alone; it is dropped with the
    /// progress it dates.
    @Test func readsTheProgressStampOnlyWithAProgress() {
        let stamped = #"{"v":1,"pane":"w1:p1","status":"working","summary":"s","ts":1000,"progress":{"done":1,"total":2},"progress_ts":5000}"#
        #expect(Self.parse(stamped)?.timestamp == 1000)
        #expect(Self.parse(stamped)?.progressTimestamp == 5000)
        #expect(Self.parse(stamped)?.progressWrittenAt == 5000)
        let unstamped = #"{"v":1,"pane":"w1:p1","status":"working","summary":"s","ts":1000,"progress":{"done":1,"total":2}}"#
        #expect(Self.parse(unstamped)?.progressTimestamp == nil)
        #expect(Self.parse(unstamped)?.progressWrittenAt == 1000)
        let orphan = #"{"v":1,"pane":"w1:p1","status":"working","summary":"s","ts":1000,"progress_ts":5000}"#
        #expect(Self.parse(orphan)?.progressTimestamp == nil)
        let odd = #"{"v":1,"pane":"w1:p1","status":"working","summary":"s","ts":1000,"progress":{"done":1,"total":2},"progress_ts":"5000"}"#
        #expect(Self.parse(odd)?.progress != nil)
        #expect(Self.parse(odd)?.progressTimestamp == nil)
    }

    /// A current plugin writes the `progress` key on every summary, `null`
    /// included; an older one never does. Any value at all declares it.
    @Test func aRecordDeclaresProgressByCarryingTheKey() {
        for progress in ["null", #"{"done":1,"total":2}"#, #""3/7""#, #"{"phase":"deploying"}"#] {
            #expect(Self.parse(Self.line(progress: progress))?.declaresProgress == true, "\(progress)")
        }
        let absent = #"{"v":1,"pane":"w1:p1","status":"working","summary":"s","ts":1}"#
        #expect(Self.parse(absent)?.declaresProgress == false)
    }

    // MARK: Bar

    private static func row(
        _ status: AgentStatus, summary: AgentSummary? = nil, isSummaryPending: Bool = false,
        hostReportsProgress: Bool = false, kind: String = "claude"
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: "mac",
            agent: Agent(
                terminalID: "t", kind: kind, title: "", status: status,
                workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1", cwd: "/", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil, summary: summary,
            isSummaryPending: isSummaryPending, hostReportsProgress: hostReportsProgress)
    }

    private static func summary(
        _ status: AgentStatus, secondsAgo: TimeInterval, progress: AgentProgress?,
        progressSecondsAgo: TimeInterval? = nil
    ) -> AgentSummary {
        AgentSummary(
            paneID: "w1:p1", status: status, text: "adding retries",
            timestamp: Int64((now.timeIntervalSince1970 - secondsAgo) * 1000), progress: progress,
            progressTimestamp: progressSecondsAgo.map { Int64((now.timeIntervalSince1970 - $0) * 1000) })
    }

    /// A Working estimate is fresh on the summary's terms: same status and
    /// under `AgentSummary.freshness`.
    @Test func aWorkingEstimateIsFreshOnlyInItsStatusAndUnderThreeMinutes() throws {
        let estimate = try #require(Self.progress(3, of: 7))
        let fresh = Self.summary(.working, secondsAgo: 60, progress: estimate)
        #expect(Self.row(.working, summary: fresh).progressDisplay(at: Self.now) == .estimate(estimate, isStale: false))

        let old = Self.summary(.working, secondsAgo: AgentSummary.freshness, progress: estimate)
        #expect(Self.row(.working, summary: old).progressDisplay(at: Self.now) == .estimate(estimate, isStale: true))

        let frozen = Self.summary(.blocked, secondsAgo: 60, progress: estimate)
        #expect(Self.row(.working, summary: frozen).progressDisplay(at: Self.now) == .estimate(estimate, isStale: true))
    }

    /// A plan-step push refreshes the estimate without rewriting the
    /// summary: the bar ages from `progress_ts`, the summary line from `ts`.
    @Test func anEstimateAgesFromItsOwnStamp() throws {
        let estimate = try #require(Self.progress(4, of: 7))
        let pushed = Self.summary(.working, secondsAgo: 600, progress: estimate, progressSecondsAgo: 30)
        let row = Self.row(.working, summary: pushed)
        #expect(row.progressDisplay(at: Self.now) == .estimate(estimate, isStale: false))
        #expect(row.summaryLine(at: Self.now) == .summary(text: "adding retries", age: 600, isStale: true))

        let lapsed = Self.summary(.working, secondsAgo: 30, progress: estimate, progressSecondsAgo: 600)
        #expect(Self.row(.working, summary: lapsed).progressDisplay(at: Self.now) == .estimate(estimate, isStale: true))
    }

    /// VoiceOver hears a stale estimate with when it was last refreshed,
    /// never a percent.
    @Test func aStaleEstimateIsSpokenWithItsAge() throws {
        let estimate = try #require(Self.progress(3, of: 7))
        let fresh = Self.summary(.working, secondsAgo: 60, progress: estimate)
        #expect(Self.row(.working, summary: fresh).spokenProgress(at: Self.now) == "3 of 7 steps done")
        let old = Self.summary(.working, secondsAgo: 300, progress: estimate)
        #expect(
            Self.row(.working, summary: old).spokenProgress(at: Self.now)
                == "3 of 7 steps done, as of 5 minutes ago")
        #expect(Self.row(.working, isSummaryPending: true).spokenProgress(at: Self.now) == nil)
    }

    /// Pending only while the Agent's Host reports progress: then a Working
    /// Agent without an estimate — first summary on its way, a summary
    /// without one, or a tombstone — shows the dotted rail. An older plugin
    /// (or summaries off) never reports progress, so it never shows one.
    @Test func aWorkingAgentWithoutAnEstimateIsPendingOnlyWhileItsHostReportsProgress() {
        let bare = Self.summary(.working, secondsAgo: 60, progress: nil)
        #expect(Self.row(.working, isSummaryPending: true, hostReportsProgress: true).progressDisplay(at: Self.now) == .pending)
        #expect(Self.row(.working, summary: bare, hostReportsProgress: true).progressDisplay(at: Self.now) == .pending)
        #expect(Self.row(.working, hostReportsProgress: true).progressDisplay(at: Self.now) == .pending)
        // An older plugin or summaries off: no dotted rail, whatever else holds.
        #expect(Self.row(.working, isSummaryPending: true).progressDisplay(at: Self.now) == nil)
        #expect(Self.row(.working, summary: bare).progressDisplay(at: Self.now) == nil)
        #expect(Self.row(.working).progressDisplay(at: Self.now) == nil)
    }

    /// Blocked freezes the last estimate and never shows pending.
    @Test func aBlockedAgentShowsOnlyAnEstimate() throws {
        let estimate = try #require(Self.progress(nil, of: nil, phase: .verifying))
        let frozen = Self.summary(.blocked, secondsAgo: 60, progress: estimate)
        #expect(Self.row(.blocked, summary: frozen).progressDisplay(at: Self.now) == .estimate(estimate, isStale: false))
        let bare = Self.summary(.blocked, secondsAgo: 60, progress: nil)
        #expect(Self.row(.blocked, summary: bare).progressDisplay(at: Self.now) == nil)
        #expect(Self.row(.blocked, isSummaryPending: true, hostReportsProgress: true).progressDisplay(at: Self.now) == nil)
        #expect(Self.row(.blocked, summary: bare, hostReportsProgress: true).progressDisplay(at: Self.now) == nil)
    }

    @Test func doneIdleAndShellRowsShowNoBar() throws {
        let estimate = try #require(Self.progress(3, of: 7))
        for status in [AgentStatus.done, .idle, .unknown] {
            let summary = Self.summary(status, secondsAgo: 10, progress: estimate)
            #expect(
                Self.row(status, summary: summary, isSummaryPending: true, hostReportsProgress: true)
                    .progressDisplay(at: Self.now) == nil)
        }
        let working = Self.summary(.working, secondsAgo: 10, progress: estimate)
        #expect(Self.row(.done, summary: working).progressDisplay(at: Self.now) == nil)
        // A shell carries no Agent Status of its own; even listed Working it has no bar.
        let shell = Self.row(
            .working, summary: working, isSummaryPending: true, hostReportsProgress: true,
            kind: Agent.shellKind)
        #expect(shell.progressDisplay(at: Self.now) == nil)
        #expect(shell.spokenProgress(at: Self.now) == nil)
    }
}
