import Foundation
import Testing

@testable import Waycar

@Suite("Console host status presentation")
struct ConsoleHostStatusPresentationTests {
    private let host = Host.fixture(name: "studio")

    @Test func reconnectingRowsUseTheStandaloneSummary() throws {
        let cases: [(TransportError, String)] = [
            (.sshUnreachable(detail: "down"), "SSH unavailable"),
            (.timedOut, "Connection timed out"),
            (.cancelled, "Connection cancelled"),
            (.channelFailed(detail: "reset"), "Connection dropped"),
            (.apiRejected(code: "busy", message: "later"), "herdr rejected the request"),
        ]
        for (failure, summary) in cases {
            let presentation = try #require(
                ConsoleHostStatusPresentation(
                    host: host,
                    status: .reconnecting(attempt: 1, delay: .seconds(1), failure: failure),
                    syncError: nil))
            #expect(presentation.message == "Reconnecting to studio: \(summary)")
            #expect(presentation.systemImage == "wifi.exclamationmark")
            #expect(presentation.severity == .warning)
            #expect(presentation.navigates)
            #expect(presentation.hostName == "studio")
        }
    }

    @Test func aTrustHoldAsksForTheKeyAndOpensTheHostPage() throws {
        let held = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .connecting, trustHold: .host, syncError: nil))
        #expect(held.message == "Waiting for you to trust studio's host key")
        #expect(held.navigates)
        #expect(held.severity == .informational)

        let jumpHeld = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .connecting, trustHold: .jumpHost, syncError: nil))
        #expect(jumpHeld.message == "Waiting for you to trust the Jump Host's host key for studio")
        #expect(jumpHeld.navigates)

        // The user must act, so the hold shows even inside reconnect grace.
        #expect(
            ConsoleHostStatusPresentation(
                host: host, status: .connecting, isWithinReconnectGrace: true,
                trustHold: .host, syncError: nil) != nil)

        // A changed key is a hard failure, never a wait.
        let mismatch = TransportError.hostKeyMismatch(
            known: HostKeyFingerprint(publicKeyBlob: Data("a".utf8)),
            presented: HostKeyFingerprint(publicKeyBlob: Data("b".utf8)))
        let failed = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .failed(mismatch), trustHold: .host, syncError: nil))
        #expect(failed.isCritical)

        let plain = try #require(
            ConsoleHostStatusPresentation(host: host, status: .connecting, syncError: nil))
        #expect(plain.message == "Connecting to studio…")
        #expect(!plain.navigates)
    }

    @Test func aTrustHoldOutranksTheFailureOfAnEarlierDial() throws {
        // A hold means the latest dial reached the Host and waits on the
        // user, so an older failure no longer describes the connection.
        let older = TransportError.sshUnreachable(detail: "no route")
        let holdRow = ConsoleHostStatusPresentation(
            host: host, status: .connecting, trustHold: .host, syncError: nil)
        for grace in [false, true] {
            #expect(
                ConsoleHostStatusPresentation(
                    host: host, status: .connecting, standingFailure: older,
                    isWithinReconnectGrace: grace, trustHold: .host, syncError: nil) == holdRow)
            #expect(
                ConsoleHostStatusPresentation(
                    host: host,
                    status: .reconnecting(attempt: 1, delay: .seconds(1), failure: older),
                    isWithinReconnectGrace: grace, trustHold: .host, syncError: nil) == holdRow)
        }
    }

    @Test func aJumpHostOutageNamesTheJumpHostRatherThanConnectionFailed() throws {
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .reconnecting(
                    attempt: 2, delay: .seconds(2),
                    failure: .jumpHostFailed(.timedOut)),
                syncError: nil))
        #expect(presentation.message == "Reconnecting to studio: The Jump Host did not answer in time")
        #expect(!presentation.message.contains("connection failed"))
        #expect(presentation.navigates)
        #expect(presentation.severity == .warning)
    }

    @Test func aFailedHostRendersTheWholePresentation() throws {
        let failure = TransportError.socketNotFound(path: "/tmp/herdr.sock")
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .failed(failure),
                syncError: nil))
        #expect(presentation.message == "studio: \(failure.presentation.message)")
        #expect(presentation.systemImage == "exclamationmark.triangle.fill")
        #expect(presentation.severity == .warning)
        #expect(presentation.navigates)
    }

    // MARK: A stopped runtime (#389)

    private static let stopped: [(TransportError, HostBackend)] = [
        (.herdrNotRunning(path: "/tmp/herdr.sock"), .herdr),
        (.streamLocalOpenFailed(path: "/tmp/herdr.sock"), .herdr),
        (.coreNotRunning, .core),
    ]

    /// A stopped runtime is a normal state: the row says what is stopped,
    /// quietly, keeps any suggestion for its second line, and offers the
    /// Start in place, so it does not navigate. Failed, or Connecting with
    /// it standing, the row is the same, inside reconnect grace too.
    @Test func aStoppedRuntimeReadsCalmAndOffersItsStart() throws {
        for (failure, runtime) in Self.stopped {
            for (status, standing, grace) in [
                (EventsSessionStatus.failed(failure), nil, false),
                (.connecting, failure, false),
                (.connecting, failure, true),
            ] as [(EventsSessionStatus, TransportError?, Bool)] {
                let row = try #require(
                    ConsoleHostStatusPresentation(
                        host: host, status: status, standingFailure: standing,
                        isWithinReconnectGrace: grace, syncError: nil))
                #expect(row.message == "studio: \(failure.presentation.explanation)")
                #expect(row.detail == failure.presentation.recoverySuggestion)
                #expect(row.systemImage == "power.circle")
                #expect(row.severity == .informational)
                #expect(!row.isCritical)
                #expect(!row.navigates)
                #expect(row.startsRuntime == runtime)
                #expect(!row.startFailed)
                #expect(row.retryScope == nil)
            }
        }
        let tui = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .failed(.herdrNotRunning(path: "/s")), syncError: nil))
        #expect(tui.message == "studio: Herdr TUI is not running on this Host.")
        #expect(tui.detail == nil)
        let core = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .failed(.coreNotRunning), syncError: nil))
        #expect(core.message == "studio: Herdr Core is not running on this Host.")
        let socket = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .failed(.streamLocalOpenFailed(path: "/s")), syncError: nil))
        #expect(socket.detail == "If it is running, check SSH stream-local forwarding.")
    }

    @Test func theStartIsNamedForItsRuntime() {
        #expect(HostBackend.herdr.startActionTitle == "Start Herdr TUI")
        #expect(HostBackend.core.startActionTitle == "Start Herdr Core")
    }

    /// After a failed start the second line is what the start said, for the
    /// runtime that failed only.
    @Test func aFailedStartsWordsTakeTheSecondLine() throws {
        let words = "Herdr TUI did not start: herdr: config.toml: invalid key"
        let row = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .failed(.streamLocalOpenFailed(path: "/s")),
                startErrors: [.herdr: words], syncError: nil))
        #expect(row.detail == words)
        #expect(row.startFailed)
        #expect(row.severity == .informational)
        #expect(row.startsRuntime == .herdr)

        let other = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .failed(.coreNotRunning),
                startErrors: [.herdr: words], syncError: nil))
        #expect(other.detail == nil)
        #expect(!other.startFailed)
    }

    /// A stopped runtime beside one that serves gets its own row with its
    /// Start in place of Retry; the message already names the runtime.
    @Test func aStoppedSecondaryRuntimeOffersItsStartOnItsOwnRow() {
        for (failure, runtime) in Self.stopped {
            let scope = ConsoleScope(hostID: host.id, backend: runtime)
            let row = ConsoleHostStatusPresentation(
                host: host, failedScope: scope, failure: failure,
                startErrors: [runtime: "did not start"])
            #expect(row.message == "studio: \(failure.presentation.explanation)")
            #expect(row.startsRuntime == runtime)
            #expect(row.retryScope == scope)
            #expect(row.detail == "did not start")
            #expect(row.severity == .informational)
            #expect(!row.navigates)
            #expect(row.id == "\(host.id.uuidString)/\(runtime.rawValue)")
        }
        let plain = ConsoleHostStatusPresentation(
            host: host, failedScope: ConsoleScope(hostID: host.id, backend: .tmux),
            failure: .tmuxNotInstalled)
        #expect(plain.startsRuntime == nil)
        #expect(plain.message.hasPrefix("tmux on studio: "))
    }

    /// herdr missing, or a named session that does not exist, is no stopped
    /// server: the ordinary failure row, with no Start.
    @Test func aMissingHerdrOrSessionOffersNoStart() throws {
        for failure in [
            TransportError.socketNotFound(path: "/s"),
            .herdrSessionNotFound(path: "/s"),
            .coreNotInstalled,
        ] {
            let row = try #require(
                ConsoleHostStatusPresentation(host: host, status: .failed(failure), syncError: nil))
            #expect(row.startsRuntime == nil)
            #expect(row.severity == .warning)
            #expect(row.navigates)
            #expect(row.message == "studio: \(failure.presentation.message)")
        }
    }

    @Test func aHostKeyMismatchIsCritical() throws {
        let failure = TransportError.hostKeyMismatch(
            known: HostKeyFingerprint(publicKeyBlob: Data("known".utf8)),
            presented: HostKeyFingerprint(publicKeyBlob: Data("presented".utf8)))
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .failed(failure),
                syncError: nil))
        #expect(presentation.systemImage == "exclamationmark.shield.fill")
        #expect(presentation.severity == .critical)
        #expect(presentation.navigates)
    }

    @Test func aJumpHostKeyMismatchIsCritical() throws {
        let failure = TransportError.jumpHostFailed(
            .hostKeyMismatch(
                known: HostKeyFingerprint(publicKeyBlob: Data("known".utf8)),
                presented: HostKeyFingerprint(publicKeyBlob: Data("presented".utf8))))
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .failed(failure),
                syncError: nil))
        #expect(presentation.systemImage == "exclamationmark.shield.fill")
        #expect(presentation.severity == .critical)
        #expect(presentation.navigates)
    }

    @Test func aConnectedHostWithASyncErrorKeepsTheSnapshotRow() throws {
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .connected,
                syncError: "Could not sync this Host's Agents. Retrying…"))
        #expect(presentation.message == "studio: Could not sync this Host's Agents. Retrying…")
        #expect(presentation.systemImage == "arrow.trianglehead.2.clockwise")
        #expect(presentation.severity == .warning)
        #expect(presentation.navigates)
    }

    @Test func endedOrUnknownStatusesWithoutASyncErrorProduceNoRow() {
        let quiet: [EventsSessionStatus?] = [.ended, nil]
        for status in quiet {
            #expect(
                ConsoleHostStatusPresentation(
                    host: host,
                    status: status,
                    syncError: nil) == nil)
        }
    }

    @Test func quietConditionRowsAreInformationalAndDoNotNavigate() throws {
        let paused = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .suspended, syncError: nil))
        #expect(paused.message == "Connection to studio is paused.")
        #expect(paused.severity == .informational)
        #expect(!paused.navigates)

        let connecting = try #require(
            ConsoleHostStatusPresentation(
                host: host, status: .connecting, syncError: nil))
        #expect(connecting.message == "Connecting to studio…")
        #expect(connecting.severity == .informational)
        #expect(!connecting.navigates)

        let loading = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .connected,
                isAwaitingSnapshot: true,
                syncError: nil))
        #expect(loading.message == "Loading Agents from studio…")
        #expect(loading.severity == .informational)
        #expect(!loading.navigates)
    }

    @Test func connectingWithAStandingFailureLooksLikeFailure() throws {
        let failure = TransportError.socketNotFound(path: "/tmp/herdr.sock")
        let presentation = try #require(
            ConsoleHostStatusPresentation(
                host: host,
                status: .connecting,
                standingFailure: failure,
                syncError: nil))
        #expect(presentation.message == "studio: \(failure.presentation.message)")
        #expect(presentation.severity == .warning)
        #expect(presentation.navigates)
    }

    @Test func aConnectedHostWithKnownInventoryAndNoSyncErrorProducesNoRow() {
        #expect(
            ConsoleHostStatusPresentation(
                host: host,
                status: .connected,
                isAwaitingSnapshot: false,
                syncError: nil) == nil)
    }

    @Test func unknownInventoryNeverClaimsNoAgents() {
        let conditions: [EventsSessionStatus] = [
            .connecting,
            .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut),
            .suspended,
            .failed(.streamLocalOpenFailed(path: "/s")),
        ]
        for status in conditions {
            let row = ConsoleHostStatusPresentation(
                host: host, status: status, syncError: nil)
            #expect(row != nil)
            #expect(
                ConsoleAgentsSurface(
                    hostCount: 1,
                    filteredHostName: nil,
                    filteredAgentCount: 0,
                    visibleIssueCount: 1) == .rows)
            #expect(
                ConsoleAgentsSurface(
                    hostCount: 1,
                    filteredHostName: "studio",
                    filteredAgentCount: 0,
                    visibleIssueCount: 1) == .rows)
        }
        #expect(
            ConsoleHostStatusPresentation(
                host: host,
                status: .connected,
                isAwaitingSnapshot: true,
                syncError: nil) != nil)
    }

    @Test func knownEmptyInventoryMayClaimNoAgents() {
        #expect(
            ConsoleAgentsSurface(
                hostCount: 0,
                filteredHostName: nil,
                filteredAgentCount: 0,
                visibleIssueCount: 0) == .noHosts)
        #expect(
            ConsoleAgentsSurface(
                hostCount: 1,
                filteredHostName: nil,
                filteredAgentCount: 0,
                visibleIssueCount: 0) == .noAgents)
        #expect(
            ConsoleAgentsSurface(
                hostCount: 2,
                filteredHostName: "studio",
                filteredAgentCount: 0,
                visibleIssueCount: 0) == .noAgentsOnHost("studio"))
        #expect(
            ConsoleAgentsSurface(
                hostCount: 2,
                filteredHostName: nil,
                filteredAgentCount: 1,
                visibleIssueCount: 1) == .rows)
    }

    /// Every Host disabled outranks the search and Status pill states: no
    /// query or pill can find an Agent until a Host is turned on. The case
    /// carries the Host count its count-aware explanation reads.
    @Test func everyHostDisabledIsItsOwnSurface() {
        #expect(
            ConsoleAgentsSurface(
                hostCount: 2, enabledHostCount: 0, filteredHostName: nil,
                filteredAgentCount: 0, visibleIssueCount: 0,
                statusFilter: .blocked, searchQuery: "deploy") == .allHostsDisabled(hostCount: 2))
        #expect(
            ConsoleAgentsSurface(
                hostCount: 1, enabledHostCount: 0, filteredHostName: nil,
                filteredAgentCount: 0, visibleIssueCount: 0) == .allHostsDisabled(hostCount: 1))
        #expect(
            ConsoleAgentsSurface(
                hostCount: 0, enabledHostCount: 0, filteredHostName: nil,
                filteredAgentCount: 0, visibleIssueCount: 0) == .noHosts)
        // One enabled Host is enough for the ordinary empty claim.
        #expect(
            ConsoleAgentsSurface(
                hostCount: 3, enabledHostCount: 1, filteredHostName: nil,
                filteredAgentCount: 0, visibleIssueCount: 0) == .noAgents)
    }

    @Test func anEmptyStatusPillNamesItsStatusBeforeTheHost() {
        // Under a Status pill, "nothing Blocked" is the accurate claim even
        // on a filtered Host: that Host may well have other Agents.
        #expect(
            ConsoleAgentsSurface(
                hostCount: 2,
                filteredHostName: "studio",
                filteredAgentCount: 0,
                visibleIssueCount: 0,
                statusFilter: .blocked) == .noAgentsWithStatus(.blocked))
        #expect(
            ConsoleAgentsSurface(
                hostCount: 1,
                filteredHostName: nil,
                filteredAgentCount: 0,
                visibleIssueCount: 0,
                statusFilter: .done) == .noAgentsWithStatus(.done))
        #expect(
            ConsoleAgentsSurface(
                hostCount: 1,
                filteredHostName: nil,
                filteredAgentCount: 0,
                visibleIssueCount: 0,
                statusFilter: .closed) == .noAgentsWithStatus(.closed))
        // No Hosts, a condition row, or a match still take precedence.
        #expect(
            ConsoleAgentsSurface(
                hostCount: 0,
                filteredHostName: nil,
                filteredAgentCount: 0,
                visibleIssueCount: 0,
                statusFilter: .blocked) == .noHosts)
        #expect(
            ConsoleAgentsSurface(
                hostCount: 1,
                filteredHostName: nil,
                filteredAgentCount: 0,
                visibleIssueCount: 1,
                statusFilter: .working) == .rows)
        #expect(
            ConsoleAgentsSurface(
                hostCount: 1,
                filteredHostName: nil,
                filteredAgentCount: 1,
                visibleIssueCount: 0,
                statusFilter: .working) == .rows)
    }
}
