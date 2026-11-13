import Foundation
import Testing

@testable import Waycar

@Suite("Host list connection presentation")
struct HostListViewTests {
    @Test func connectedHostShowsRoundedLatency() {
        let presentation = HostConnectionPresentation(
            status: .connected,
            latency: .milliseconds(25) + .microseconds(600))

        #expect(presentation.title == "26 ms")
        #expect(presentation.accessibilityLabel == "Connected, latency 26 ms")
        #expect(presentation.tone == .connected)
    }

    @Test func disconnectedStatesNeverShowStaleLatency() {
        let latency = Duration.milliseconds(42)

        #expect(
            HostConnectionPresentation(
                status: .reconnecting(
                    attempt: 1,
                    delay: .seconds(1),
                    failure: .timedOut),
                latency: latency
            ).title == "Reconnecting…")
        #expect(
            HostConnectionPresentation(
                status: .failed(.authenticationFailed),
                latency: latency
            ).title == "Unavailable")
        #expect(
            HostConnectionPresentation(
                status: .suspended,
                latency: latency
            ).title == "Paused")
        #expect(
            HostConnectionPresentation(
                status: .connecting,
                latency: latency
            ).title == "Connecting…")
        #expect(
            HostConnectionPresentation(
                status: .connecting,
                standingFailure: .socketNotFound(path: "/s"),
                latency: latency
            ).title == "Unavailable")
    }

    /// A runtime installed but stopped is a normal state (#389): the chip
    /// says so in the quiet tone, never the red Unavailable.
    @Test func aStoppedRuntimeIsNotRunningAndQuiet() {
        let cases: [(TransportError, String)] = [
            (.herdrNotRunning(path: "/s"), "Herdr TUI is not running"),
            (.streamLocalOpenFailed(path: "/s"), "Herdr TUI is not running"),
            (.coreNotRunning, "Herdr Core is not running"),
        ]
        for (failure, label) in cases {
            for presentation in [
                HostConnectionPresentation(status: .failed(failure), latency: nil),
                HostConnectionPresentation(
                    status: .connecting, standingFailure: failure, latency: .milliseconds(12)),
            ] {
                #expect(presentation.title == "Not running")
                #expect(presentation.accessibilityLabel == label)
                #expect(presentation.tone == .pending)
            }
        }
        #expect(
            HostConnectionPresentation(
                status: .failed(.herdrSessionNotFound(path: "/s")), latency: nil
            ).tone == .unavailable)
    }

    @Test func nilStatusIsTheConstructionWindowAndSaysConnecting() {
        let presentation = HostConnectionPresentation(status: nil, latency: nil)
        #expect(presentation.title == "Connecting…")
        #expect(presentation.accessibilityLabel == "Connecting")
        #expect(presentation.tone == .pending)
    }

    @Test func connectingWithoutAStandingFailureIsPending() {
        let presentation = HostConnectionPresentation(
            status: .connecting, latency: .milliseconds(12))
        #expect(presentation.title == "Connecting…")
        #expect(presentation.accessibilityLabel == "Connecting")
        #expect(presentation.tone == .pending)
    }

    @Test func connectingWithAStandingFailureStaysUnavailable() {
        let presentation = HostConnectionPresentation(
            status: .connecting,
            standingFailure: .authenticationFailed,
            latency: .milliseconds(12))
        #expect(presentation.title == "Unavailable")
        #expect(presentation.accessibilityLabel == "Unavailable")
        #expect(presentation.tone == .unavailable)
    }

    @Test func connectedPresentationIgnoresInventoryAndStaysLatencyBased() {
        let presentation = HostConnectionPresentation(
            status: .connected,
            standingFailure: .streamLocalOpenFailed(path: "/s"),
            latency: .milliseconds(25))
        #expect(presentation.title == "25 ms")
        #expect(presentation.tone == .connected)
        #expect(presentation.accessibilityLabel == "Connected, latency 25 ms")
    }

    // MARK: tmux badge (ADR 0026)

    @Test func tmuxOnlyHostsCarryTheTmuxBadge() {
        #expect(TmuxBadge.isShown(for: HostBackendPresence(herdr: false, tmuxVersion: "3.4")))
    }

    /// herdr leads on a Host running both; its tmux rows carry their own mark.
    @Test func herdrAndDualHostsShowNoTmuxBadge() {
        #expect(!TmuxBadge.isShown(for: .herdrOnly))
        #expect(!TmuxBadge.isShown(for: HostBackendPresence(herdr: true, tmuxVersion: "3.4")))
        // An OS tmux below 3.2 leaves a herdr Host herdr-only.
        #expect(!TmuxBadge.isShown(for: HostBackendPresence(herdr: true, tmuxVersion: "2.7")))
    }

    @Test func unknownBackendsShowNoTmuxBadge() {
        #expect(!TmuxBadge.isShown(for: nil))
        // Neither installed: herdr's projection reports what is missing.
        #expect(!TmuxBadge.isShown(for: HostBackendPresence(herdr: false, tmuxVersion: nil)))
    }
}
