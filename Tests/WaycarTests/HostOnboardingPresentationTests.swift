import Foundation
import Testing

@testable import Waycar

@Suite("Host onboarding connection presentation")
struct HostOnboardingPresentationTests {
    /// The Host detail footer shows the Explanation during automatic
    /// `EventsSessionStatus.reconnecting`, and hides it only while a manual
    /// Reconnect request is in flight — including on `.failed` (#160).
    @Test func footerSuppressionFollowsTheManualRequestNotTransportReconnecting() {
        let automatic = HostOnboardingConnectionPresentation(
            status: .reconnecting(
                attempt: 1,
                delay: .seconds(1),
                failure: .timedOut),
            isManualReconnectInFlight: false)
        #expect(automatic.footerMessage == TransportError.timedOut.presentation.explanation)

        let manualDuringReconnect = HostOnboardingConnectionPresentation(
            status: .reconnecting(
                attempt: 1,
                delay: .seconds(1),
                failure: .timedOut),
            isManualReconnectInFlight: true)
        #expect(manualDuringReconnect.footerMessage == nil)

        let manualDuringFailure = HostOnboardingConnectionPresentation(
            status: .failed(.authenticationFailed),
            isManualReconnectInFlight: true)
        #expect(manualDuringFailure.footerMessage == nil)
    }

    @Test func reconnectingFooterIsExplanationAndNeverTheSuggestion() throws {
        let failure = TransportError.sshUnreachable(detail: "connection refused")
        let presentation = HostOnboardingConnectionPresentation(
            status: .reconnecting(
                attempt: 1,
                delay: .seconds(1),
                failure: failure),
            isManualReconnectInFlight: false)
        #expect(presentation.footerMessage == failure.presentation.explanation)
        #expect(presentation.connectionErrorMessage == failure.presentation.explanation)
        let suggestion = try #require(failure.presentation.recoverySuggestion)
        #expect(!(presentation.footerMessage?.contains(suggestion) ?? true))
    }

    @Test func failedFooterIsTheWholePresentation() {
        let failure = TransportError.authenticationFailed
        let presentation = HostOnboardingConnectionPresentation(
            status: .failed(failure),
            isManualReconnectInFlight: false)
        #expect(presentation.footerMessage == failure.presentation.message)
    }

    @Test func footerMatrixCoversEveryHostDetailRow() {
        let failure = TransportError.streamLocalOpenFailed(path: "/tmp/herdr.sock")
        let rows: [(
            EventsSessionStatus?, TransportError?, Bool, String?
        )] = [
            (nil, nil, false, nil),
            (.suspended, nil, false, nil),
            (.connected, nil, false, nil),
            (.ended, nil, false, nil),
            (.connecting, nil, false, nil),
            (.connecting, nil, true, nil),
            (.connecting, failure, false, failure.presentation.message),
            (.connecting, failure, true, nil),
            (
                .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut),
                nil, false, TransportError.timedOut.presentation.explanation
            ),
            (
                .reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut),
                nil, true, nil
            ),
            (.failed(failure), nil, false, failure.presentation.message),
            (.failed(failure), nil, true, nil),
        ]
        for (status, standing, inFlight, expected) in rows {
            let presentation = HostOnboardingConnectionPresentation(
                status: status,
                standingFailure: standing,
                isManualReconnectInFlight: inFlight)
            #expect(presentation.footerMessage == expected)
            if inFlight {
                #expect(presentation.footerMessage == nil)
            }
        }
    }

    @Test func aManualRequestDoesNotRewriteStatusDerivedCopy() {
        let failure = TransportError.authenticationFailed
        let suppressed = HostOnboardingConnectionPresentation(
            status: .failed(failure),
            isManualReconnectInFlight: true)
        #expect(suppressed.footerMessage == nil)
        #expect(suppressed.connectionErrorMessage == failure.presentation.message)

        let automatic = HostOnboardingConnectionPresentation(
            status: .reconnecting(
                attempt: 2, delay: .seconds(2), failure: .timedOut),
            isManualReconnectInFlight: false)
        #expect(automatic.footerMessage == TransportError.timedOut.presentation.explanation)
        #expect(automatic.connectionErrorMessage == automatic.footerMessage)

        let connectingStanding = HostOnboardingConnectionPresentation(
            status: .connecting,
            standingFailure: failure,
            isManualReconnectInFlight: true)
        #expect(connectingStanding.footerMessage == nil)
        #expect(connectingStanding.connectionErrorMessage == failure.presentation.message)
    }

    /// The Console never prompts, so Reconnect after a host-key failure
    /// must go through the preflight that asks — and only then.
    @Test func reconnectAsksAboutTheHostKeyOnlyAfterAHostKeyFailure() {
        let untrusted = TransportError.hostKeyRejected(
            presented: HostKeyFingerprint(digest: Data(repeating: 1, count: 32)))
        let changed = TransportError.hostKeyMismatch(
            known: HostKeyFingerprint(digest: Data(repeating: 1, count: 32)),
            presented: HostKeyFingerprint(digest: Data(repeating: 2, count: 32)))
        let rows: [(EventsSessionStatus?, TransportError?, Bool)] = [
            (.failed(untrusted), nil, true),
            (.failed(changed), nil, true),
            (.reconnecting(attempt: 1, delay: .seconds(1), failure: untrusted), nil, true),
            (.connecting, untrusted, true),
            (.failed(.jumpHostFailed(untrusted)), nil, true),
            (.failed(.jumpHostFailed(changed)), nil, true),
            (.failed(.jumpHostFailed(.sshUnreachable(detail: "refused"))), nil, false),
            (.failed(.authenticationFailed), nil, false),
            (.reconnecting(attempt: 1, delay: .seconds(1), failure: .timedOut), nil, false),
            (.connecting, nil, false),
            (.connected, untrusted, false),
            (nil, nil, false),
        ]
        for (status, standing, expected) in rows {
            for inFlight in [false, true] {
                let presentation = HostOnboardingConnectionPresentation(
                    status: status,
                    standingFailure: standing,
                    isManualReconnectInFlight: inFlight)
                #expect(
                    presentation.reconnectNeedsHostKeyDecision == expected,
                    "status \(String(describing: status)), standing \(String(describing: standing))")
            }
        }
    }

    // MARK: Version line (ADR 0026)

    @Test func herdrVersionLineNamesTheTUI() {
        let info = ServerInfo(version: "0.7.5", protocolVersion: 17)
        #expect(
            HostOnboardingVersionLine.text(serverInfo: info, presence: .herdrOnly)
                == "Herdr TUI 0.7.5 · protocol 17")
        #expect(
            HostOnboardingVersionLine.text(serverInfo: info, presence: nil)
                == "Herdr TUI 0.7.5 · protocol 17")

        let newer = ServerInfo(version: "0.9.5", protocolVersion: 23, exceedsGeneratedProtocol: true)
        #expect(
            HostOnboardingVersionLine.text(serverInfo: newer, presence: .herdrOnly)
                == "Herdr TUI 0.9.5 · protocol 23 — newer than this app was built against, "
                + "so features added after protocol \(WaycarSSHTransport.generatedProtocolVersion) "
                + "may be unavailable.")
    }

    @Test func tmuxVersionLineNamesTmuxAndItsVersion() {
        let info = ServerInfo(version: "3.4", protocolVersion: 0, backend: .tmux)
        #expect(
            HostOnboardingVersionLine.text(
                serverInfo: info, presence: HostBackendPresence(herdr: false, tmuxVersion: "3.4"))
                == "tmux 3.4")
    }

    @Test func dualHostShowsBothVersionLines() {
        let info = ServerInfo(version: "0.7.5", protocolVersion: 17)
        #expect(
            HostOnboardingVersionLine.text(
                serverInfo: info, presence: HostBackendPresence(herdr: true, tmuxVersion: "3.7c"))
                == "Herdr TUI 0.7.5 · protocol 17\ntmux 3.7c")
    }

    /// A tmux below 3.2 next to herdr is not a backend, so it gets no line.
    @Test func oldTmuxBesideHerdrGetsNoLine() {
        let info = ServerInfo(version: "0.7.5", protocolVersion: 17)
        #expect(
            HostOnboardingVersionLine.text(
                serverInfo: info, presence: HostBackendPresence(herdr: true, tmuxVersion: "2.7"))
                == "Herdr TUI 0.7.5 · protocol 17")
    }

    @Test func coreVersionLineNamesHerdrCore() {
        let presence = HostBackendPresence(
            herdr: true, tmuxVersion: nil,
            core: CorePresence(version: "0.1.18", path: "/usr/local/bin/herdr-core"))
        #expect(
            HostOnboardingVersionLine.text(serverInfo: nil, presence: presence)
                == "Herdr Core 0.1.18")
    }

    @Test func noVersionLineBeforeAnythingAnswered() {
        #expect(HostOnboardingVersionLine.text(serverInfo: nil, presence: nil) == nil)
        #expect(HostOnboardingVersionLine.text(serverInfo: nil, presence: .herdrOnly) == nil)
    }
}

/// The connection card's Start for a runtime installed but stopped (#389).
@Suite("Host onboarding runtime start")
struct HostOnboardingRuntimeStartPresentationTests {
    private typealias Presentation = HostOnboardingRuntimeStartPresentation
    private typealias Runtime = HostOnboardingRuntimeStartPresentation.Runtime

    private static let stoppedHerdr = TransportError.herdrNotRunning(path: "/s")

    @Test func nothingStoppedKeepsReconnect() {
        let presentation = Presentation(
            runtimes: [.herdr: Runtime(isConnected: true), .core: Runtime()], report: .allPassed)
        #expect(presentation.offers.isEmpty)
        #expect(presentation.footerMessage == nil)
        #expect(Presentation().offers.isEmpty)
    }

    /// The Console's stopped runtime gets its Start and its own words.
    @Test func theConsolesStoppedRuntimeIsOfferedItsStart() {
        for (failure, runtime) in [
            (Self.stoppedHerdr, HostBackend.herdr),
            (.streamLocalOpenFailed(path: "/s"), .herdr),
            (.coreNotRunning, .core),
        ] as [(TransportError, HostBackend)] {
            let presentation = Presentation(runtimes: [runtime: Runtime(failure: failure)])
            #expect(presentation.offers.map(\.runtime) == [runtime])
            #expect(presentation.offers.map(\.title) == [runtime.startActionTitle])
            #expect(presentation.offers.first?.isStarting == false)
            #expect(presentation.footerMessage == failure.presentation.message)
        }
    }

    /// Another failure is the Console's word on that runtime, so a stale
    /// stopped preflight offers nothing; so does a runtime that serves.
    @Test func theConsoleOutranksThePagesPreflight() {
        let stoppedReport = PreflightReport.failure(Self.stoppedHerdr, authMethod: .deviceKey)
        for state in [
            Runtime(failure: .sshUnreachable(detail: "down")),
            Runtime(failure: .socketNotFound(path: "/s")),
            Runtime(isConnected: true),
        ] {
            #expect(Presentation(runtimes: [.herdr: state], report: stoppedReport).offers.isEmpty)
        }
        // With nothing from the Console, the page's own checks decide.
        let fromPage = Presentation(runtimes: [.herdr: Runtime()], report: stoppedReport)
        #expect(fromPage.offers.map(\.runtime) == [.herdr])
        #expect(fromPage.footerMessage == "Herdr TUI is not running on this Host.")
        let coreReport = PreflightReport.failure(
            .coreNotRunning, authMethod: .deviceKey, backend: .core)
        #expect(Presentation(report: coreReport).offers.map(\.runtime) == [.core])
    }

    /// A start in flight keeps its offer and hides its line, as a Reconnect
    /// press hides the footer; a failed one shows what it said.
    @Test func aStartInFlightAndAFailedStart() {
        let starting = Presentation(
            runtimes: [.herdr: Runtime(failure: Self.stoppedHerdr, isStarting: true)])
        #expect(starting.offers == [.init(runtime: .herdr, isStarting: true)])
        #expect(starting.footerMessage == nil)
        // The reconnect after a start that worked: the failure has cleared.
        let reconnecting = Presentation(runtimes: [.herdr: Runtime(isStarting: true)])
        #expect(reconnecting.offers == [.init(runtime: .herdr, isStarting: true)])

        let words = "Herdr TUI did not start: herdr: config.toml: invalid key"
        let failed = Presentation(
            runtimes: [.herdr: Runtime(failure: Self.stoppedHerdr, startError: words)])
        #expect(failed.offers == [.init(runtime: .herdr, isStarting: false)])
        #expect(failed.footerMessage == words)
    }

    /// Both runtimes stopped on one Host: a Start each, Herdr TUI first.
    @Test func bothRuntimesStoppedOfferBothStarts() {
        let presentation = Presentation(runtimes: [
            .core: Runtime(failure: .coreNotRunning),
            .herdr: Runtime(failure: Self.stoppedHerdr),
        ])
        #expect(presentation.offers.map(\.title) == ["Start Herdr TUI", "Start Herdr Core"])
        #expect(
            presentation.footerMessage
                == "Herdr TUI is not running on this Host.\nHerdr Core is not running on this Host.")
    }
}
