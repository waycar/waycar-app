import Foundation
import Testing

@testable import Waycar

/// What one terminal pipeline reports about its attaches and mosh losses
/// (#105): one report per attempt, losses settled once.
@MainActor
@Suite("Terminal attach telemetry")
struct TerminalAttachTelemetryTests {
    @MainActor
    private final class Harness {
        var now = ContinuousClock.now
        var foregroundReturn: ForegroundReturn?
        private(set) var events: [AnalyticsEvent] = []
        private(set) lazy var telemetry = TerminalAttachTelemetry(
            now: { [unowned self] in now },
            foregroundReturn: { [unowned self] _ in foregroundReturn },
            record: { [unowned self] in events.append($0) })

        func advance(_ duration: Duration) { now += duration }
    }

    private struct LinkLost: Error {}

    @Test func anAttachThatGoesLiveIsReportedOnceWithItsRoute() throws {
        let harness = Harness()
        let back = ForegroundReturn(absence: .seconds(40), crossedGrace: true, at: harness.now)
        harness.foregroundReturn = back

        harness.telemetry.began()
        harness.telemetry.routeResolved(.speculative)
        harness.telemetry.transportReady(.mosh)
        harness.advance(.milliseconds(300))
        harness.telemetry.wentLive()
        harness.telemetry.runEnded(nil, restarting: false)

        #expect(
            harness.events == [
                .terminalAttached(
                    TerminalAttachReport(
                        transport: .mosh, route: .speculative, outcome: .success,
                        duration: .milliseconds(300), foregroundReturn: back))
            ])
    }

    @Test func aSupersededOrStoppedAttemptIsReportedCancelled() {
        let harness = Harness()

        harness.telemetry.began()
        harness.telemetry.began()
        harness.telemetry.stopped()

        #expect(
            harness.events.map(\.properties["outcome"]) == ["cancelled", "cancelled"])
    }

    @Test func anAttemptThatFailsReportsItsFailureClass() {
        let harness = Harness()

        harness.telemetry.began()
        harness.telemetry.transportReady(.ssh)
        harness.telemetry.runEnded(
            TransportError.sshUnreachable(detail: "build.example.com"), restarting: false)
        harness.telemetry.began()
        harness.telemetry.runEnded(nil, restarting: false)

        #expect(
            harness.events.map(\.properties["outcome"]) == ["unreachable", "channel"])
    }

    /// A live mosh session whose link goes is reattached by the store: the
    /// loss is reported when the reattach goes live, with how long it took.
    @Test func aLostMoshLinkIsReportedRecoveredWhenTheReattachGoesLive() {
        let harness = Harness()
        harness.telemetry.began()
        harness.telemetry.transportReady(.mosh)
        harness.telemetry.wentLive()

        harness.telemetry.runEnded(MoshLinkLost(timeoutMs: 15_000), restarting: true)
        harness.telemetry.began()
        harness.telemetry.transportReady(.mosh)
        harness.advance(.milliseconds(1_200))
        harness.telemetry.wentLive()

        #expect(
            harness.events.map(\.name)
                == ["terminal_attach", "terminal_attach", "transport_lost"])
        #expect(
            harness.events.last
                == .transportLost(
                    TransportLossReport(
                        transport: .mosh, reason: .timeout, recovery: .milliseconds(1_200))))
    }

    @Test func aLostMoshLinkTheStoreGivesUpOnNeverRecovers() {
        let harness = Harness()
        harness.telemetry.began()
        harness.telemetry.transportReady(.mosh)
        harness.telemetry.wentLive()

        harness.telemetry.runEnded(MoshLinkLost(timeoutMs: 15_000), restarting: true)
        harness.telemetry.began()
        harness.telemetry.stopped()

        #expect(
            harness.events.last
                == .transportLost(TransportLossReport(transport: .mosh, reason: .timeout, recovery: nil)))
        #expect(harness.events.filter { $0.name == "transport_lost" }.count == 1)
    }

    /// An SSH attach rides the Host's connection, whose session reports
    /// its losses: the pipeline does not count them twice.
    @Test func aLiveSSHSessionEndingIsNotAPipelineLoss() {
        let harness = Harness()
        harness.telemetry.began()
        harness.telemetry.transportReady(.ssh)
        harness.telemetry.wentLive()

        harness.telemetry.runEnded(LinkLost(), restarting: false)

        #expect(harness.events.map(\.name) == ["terminal_attach"])
    }
}
