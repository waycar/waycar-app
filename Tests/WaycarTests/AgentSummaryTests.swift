import Foundation
import Testing

@testable import Waycar

/// The Host's `summaries/` directory arrives as NDJSON, one plugin-written
/// file per line (`plugin/README.md`). A broken or future line must cost only
/// itself, never the other panes' summaries.
@Suite("Agent Summary NDJSON")
struct AgentSummaryTests {
    private static func parse(_ lines: [String]) -> [String: AgentSummary] {
        AgentSummary.latestByPane(fromNDJSON: Data(lines.joined(separator: "\n").utf8))
    }

    @Test func readsOneSummaryPerPane() {
        let summaries = Self.parse([
            #"{"v":1,"pane":"w1:p1","status":"blocked","summary":"approve merge of PR #512","ts":1766000000123}"#,
            #"{"v":1,"pane":"wV:p1H","status":"done","summary":"added upload retries","ts":1766000000456}"#,
        ])

        #expect(
            summaries["w1:p1"]
                == AgentSummary(
                    paneID: "w1:p1", status: .blocked, text: "approve merge of PR #512",
                    timestamp: 1_766_000_000_123, declaresProgress: false))
        #expect(summaries["wV:p1H"]?.status == .done)
        #expect(summaries["wV:p1H"]?.timestamp == 1_766_000_000_456)
    }

    @Test func skipsBrokenFutureAndIncompleteLinesButKeepsTheRest() {
        let summaries = Self.parse([
            "",
            "not json",
            #"{"v":2,"pane":"w1:p2","status":"done","summary":"future shape","ts":1}"#,
            #"{"v":1,"pane":"","status":"done","summary":"no pane","ts":1}"#,
            #"{"v":1,"pane":"w1:p3","status":"done","summary":"   ","ts":1}"#,
            #"{"v":1,"pane":"w1:p4","summary":"no status","ts":1}"#,
            #"{"v":1,"pane":"w1:p5","status":"done","summary":42,"ts":1}"#,
            #"{"v":1,"pane":"w1:p1","status":"done","summary":"kept","ts":"soon","extra":true}"#,
        ])

        #expect(Array(summaries.keys) == ["w1:p1"])
        #expect(summaries["w1:p1"]?.text == "kept")
        #expect(summaries["w1:p1"]?.timestamp == 0)
    }

    /// Two lines for one pane (a rename raced a write) resolve to the newest,
    /// whichever order the shell listed the files in.
    @Test func theNewestSummaryForAPaneWins() {
        let older = #"{"v":1,"pane":"w1:p1","status":"done","summary":"older","ts":100}"#
        let newer = #"{"v":1,"pane":"w1:p1","status":"blocked","summary":"newer","ts":200}"#

        #expect(Self.parse([older, newer])["w1:p1"]?.text == "newer")
        #expect(Self.parse([newer, older])["w1:p1"]?.text == "newer")
    }

    /// A turn that produced no summary leaves a tombstone: it retires an
    /// older summary for its pane, but never one written after it.
    @Test func aTombstoneRetiresOnlyOlderSummaries() {
        let lastTurn = #"{"v":1,"pane":"w1:p1","status":"done","summary":"last turn","ts":100}"#
        let tombstone = #"{"v":1,"pane":"w1:p1","status":"done","summary":null,"ts":200}"#
        let nextTurn = #"{"v":1,"pane":"w1:p1","status":"blocked","summary":"next turn","ts":300}"#

        #expect(Self.parse([lastTurn, tombstone])["w1:p1"] == nil)
        #expect(Self.parse([tombstone, lastTurn])["w1:p1"] == nil)
        #expect(Self.parse([tombstone, nextTurn])["w1:p1"]?.text == "next turn")
    }

    /// A row lays out one line: embedded newlines fold into spaces and an
    /// oversized summary is bounded.
    @Test func foldsSummaryTextOntoOneBoundedLine() throws {
        let long = String(repeating: "x", count: 500)
        let summaries = Self.parse([
            #"{"v":1,"pane":"w1:p1","status":"done","summary":"  fixed it\n\n  tests pass ","ts":1}"#,
            #"{"v":1,"pane":"w1:p2","status":"done","summary":"\#(long)","ts":1}"#,
        ])

        #expect(summaries["w1:p1"]?.text == "fixed it tests pass")
        let bounded = try #require(summaries["w1:p2"]?.text)
        #expect(bounded.count == AgentSummary.maximumTextLength)
    }

    /// Every status an Agent can be in gets a summary; a line for anything
    /// else (a future or broken status) is skipped, and its case and
    /// padding do not matter.
    @Test func readsSummariesForEveryAgentStatusAndSkipsOthers() {
        let summaries = Self.parse([
            #"{"v":1,"pane":"w1:p1","status":"working","summary":"adding retries","ts":1}"#,
            #"{"v":1,"pane":"w1:p2","status":"idle","summary":"waiting for a prompt","ts":1}"#,
            #"{"v":1,"pane":"w1:p3","status":" Blocked ","summary":"approve","ts":1}"#,
            #"{"v":1,"pane":"w1:p4","status":"unknown","summary":"exited","ts":1}"#,
            #"{"v":1,"pane":"w1:p5","status":"sleeping","summary":"future","ts":1}"#,
        ])

        #expect(summaries["w1:p1"]?.status == .working)
        #expect(summaries["w1:p2"]?.status == .idle)
        #expect(summaries["w1:p3"]?.status == .blocked)
        #expect(summaries["w1:p4"] == nil)
        #expect(summaries["w1:p5"] == nil)
    }

    /// An unknown-status line cannot retire a known one for its pane.
    @Test func aSkippedStatusLineDoesNotTombstoneTheLastSummary() {
        let known = #"{"v":1,"pane":"w1:p1","status":"done","summary":"shipped","ts":100}"#
        let odd = #"{"v":1,"pane":"w1:p1","status":"sleeping","summary":null,"ts":200}"#

        #expect(Self.parse([known, odd])["w1:p1"]?.text == "shipped")
    }

    private static let now = Date(timeIntervalSince1970: 1_766_000_000)

    private static func row(
        _ status: AgentStatus, kind: String = "claude", summary: AgentSummary?,
        isSummaryPending: Bool = false
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: "mac",
            agent: Agent(
                terminalID: "t", kind: kind, title: "", status: status,
                workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1", cwd: "/", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil, summary: summary,
            isSummaryPending: isSummaryPending)
    }

    private static func summary(_ status: AgentStatus, secondsAgo: TimeInterval) -> AgentSummary {
        AgentSummary(
            paneID: "w1:p1", status: status, text: "approve",
            timestamp: Int64((now.timeIntervalSince1970 - secondsAgo) * 1000))
    }

    /// Fresh while the Agent is still in the status the summary was written
    /// in and for three minutes after; stale otherwise, never hidden.
    @Test func aSummaryIsFreshOnlyInItsStatusAndUnderThreeMinutes() {
        let recent = Self.summary(.blocked, secondsAgo: 70)
        #expect(
            Self.row(.blocked, summary: recent).summaryLine(at: Self.now)
                == .summary(text: "approve", age: 70, isStale: false))
        #expect(
            Self.row(.working, summary: recent).summaryLine(at: Self.now)
                == .summary(text: "approve", age: 70, isStale: true))

        let old = Self.summary(.blocked, secondsAgo: 180)
        #expect(
            Self.row(.blocked, summary: old).summaryLine(at: Self.now)
                == .summary(text: "approve", age: 180, isStale: true))

        // A Host clock running ahead reads as just written, not the future.
        let ahead = Self.summary(.blocked, secondsAgo: -30)
        #expect(
            Self.row(.blocked, summary: ahead).summaryLine(at: Self.now)
                == .summary(text: "approve", age: 0, isStale: false))
    }

    /// The index lists a marked-unread Idle Agent as Done, but its Idle
    /// summary was written for herdr's status and stays fresh.
    @MainActor
    @Test func aMarkedUnreadIdleAgentKeepsItsIdleSummaryFresh() throws {
        let suite = "agent-summary-unread-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let unread = UnreadAgentsStore(defaults: defaults)
        let idle = Self.row(.idle, summary: Self.summary(.idle, secondsAgo: 20))
        #expect(unread.markUnread(idle))

        let listed = unread.displayed(idle)
        #expect(listed.agent.status == .done)
        #expect(
            listed.summaryLine(at: Self.now)
                == .summary(text: "approve", age: 20, isStale: false))
    }

    @Test func loadingShowsOnlyWithoutASummaryAndNeverOnAShell() {
        let recent = Self.summary(.working, secondsAgo: 10)
        #expect(
            Self.row(.working, summary: nil, isSummaryPending: true).summaryLine(at: Self.now)
                == .loading)
        #expect(Self.row(.working, summary: nil).summaryLine(at: Self.now) == nil)
        #expect(
            Self.row(.working, kind: Agent.shellKind, summary: recent, isSummaryPending: true)
                .summaryLine(at: Self.now) == nil)
    }

    @Test func agesReadShortOnTheCardAndSpelledOutForVoiceOver() {
        #expect(AgentSummaryLine.shortAge(59) == "now")
        #expect(AgentSummaryLine.shortAge(61) == "1m")
        #expect(AgentSummaryLine.shortAge(3 * 3600 + 5) == "3h")
        #expect(
            AgentSummaryLine.summary(text: "approve", age: 65, isStale: false).accessibilityLabel
                == "approve. 1 minute ago")
        #expect(
            AgentSummaryLine.summary(text: "approve", age: 125, isStale: true).accessibilityLabel
                == "approve. Updated 2 minutes ago")
    }

    /// herdr 0.9.1 parses the action id before `--plugin`; the other order
    /// fails as an unknown option.
    @Test func theRefreshCommandNamesTheActionBeforeThePlugin() {
        #expect(
            AgentSummary.refreshCommand(pluginID: SSHTransportSettings.notificationPluginID)
                == "herdr plugin action invoke refresh-summaries --plugin 'waycar'")
    }

    @Test func refreshFailuresSeparateAnOldPluginFromAMissingOneAndATransientFailure() {
        func failure(_ exit: Int32, _ stderr: String) -> any Error {
            AgentSummary.refreshFailure(exitStatus: exit, stderr: Data(stderr.utf8))
        }
        #expect(
            failure(1, #"{"error":{"code":"plugin_action_not_found","message":"x"}}"#)
                as? AgentSummaryRefreshError == .actionUnavailable)
        #expect(
            failure(2, "error: unrecognized subcommand 'action'")
                as? AgentSummaryRefreshError == .actionUnavailable)
        #expect(
            failure(1, "warning: noise\n" + #"{"error":{"code":"plugin_not_found"}}"#)
                as? NotificationRegistrationError == .pluginNotInstalled)
        #expect(failure(1, "boom") is TransportError)
    }
}
