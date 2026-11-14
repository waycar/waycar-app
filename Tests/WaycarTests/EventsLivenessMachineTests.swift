import Foundation
import Testing

@testable import Waycar

/// `EventsLivenessMachine` (HERDR-04): one test per transition, plus the
/// ignored cases. The owner suites are `EventsSessionKeepaliveTests`,
/// `EventsSessionLatencyTests`, `EventsSessionSampleLatencyTests` and
/// `EventsSessionResilienceTests` (liveness deadlines).
@Suite("EventsLivenessMachine")
struct EventsLivenessMachineTests {
    private let start = ContinuousClock.now
    private let interval = Duration.seconds(30)

    @Test func aFreshSessionIsUnproven() {
        let machine = EventsLivenessMachine()
        #expect(machine.stage == .unproven)
        #expect(machine.roundTrip == nil)
        #expect(machine.revalidateRoundTrip == nil)
        #expect(machine.isIdle(now: start, within: interval))
    }

    @Test func aMeasuredPingTimesTheNextCheckWithoutShowingIt() {
        var machine = EventsLivenessMachine()
        #expect(machine.handle(.measured(.milliseconds(40))) == [])
        #expect(machine.roundTrip == .milliseconds(40))
        #expect(machine.stage == .unproven)
    }

    @Test func aRevalidationKeepsItsOwnRoundTrip() {
        var machine = EventsLivenessMachine().after([.measured(.milliseconds(40))])
        #expect(machine.handle(.revalidated(.milliseconds(90))) == [])
        #expect(machine.revalidateRoundTrip == .milliseconds(90))
        #expect(machine.roundTrip == .milliseconds(40))
    }

    @Test func theConnectPathShowsItsRoundTrip() {
        var machine = EventsLivenessMachine()
        #expect(machine.handle(.show(.milliseconds(40))) == [.show(.milliseconds(40))])
        #expect(machine.stage == .healthy)
    }

    @Test func aMeasurementOnTheLiveChannelIsShown() {
        var machine = EventsLivenessMachine()
        #expect(
            machine.handle(.showIfLive(.milliseconds(50), channelLive: true))
                == [.show(.milliseconds(50))])
        #expect(machine.state.shown == .milliseconds(50))
    }

    @Test func aMeasurementOnAReplacedChannelIsNotShown() {
        var machine = EventsLivenessMachine().after([.show(.milliseconds(40))])
        #expect(machine.handle(.showIfLive(.milliseconds(50), channelLive: false)) == [])
        #expect(machine.state.shown == .milliseconds(40))
    }

    @Test func connectedLeavesTheShownValueAndAnyOtherStatusHidesIt() {
        var machine = EventsLivenessMachine().after([.show(.milliseconds(40))])
        #expect(machine.handle(.announced(connected: true)) == [])
        #expect(machine.stage == .healthy)
        #expect(machine.handle(.announced(connected: false)) == [.hide])
        #expect(machine.stage == .unproven)
        // Hidden again for every non-connected status, as before.
        #expect(machine.handle(.announced(connected: false)) == [.hide])
    }

    @Test func activityPostponesTheKeepalive() {
        var machine = EventsLivenessMachine()
        #expect(machine.handle(.activity(now: start)) == [])
        #expect(!machine.isIdle(now: start + .seconds(29), within: interval))
        #expect(machine.isIdle(now: start + interval, within: interval))
    }

    @Test func theKeepaliveStartsAndStops() {
        var machine = EventsLivenessMachine()
        #expect(machine.handle(.keepaliveStarted) == [.runKeepalive])
        #expect(machine.state.keepaliveRunning)
        #expect(machine.handle(.keepaliveStopped) == [.cancelKeepalive])
        #expect(!machine.state.keepaliveRunning)
        // Stopping is idempotent and always cancels, as before.
        #expect(machine.handle(.keepaliveStopped) == [.cancelKeepalive])
    }

    @Test func aKeepaliveFailureIsWhatTheLostChannelReports() {
        var machine = EventsLivenessMachine().after([.show(.milliseconds(40))])
        #expect(machine.handle(.keepaliveFailed(.timedOut)) == [])
        #expect(machine.stage == .suspect)
        #expect(
            machine.handle(.streamEnded(failure: .channelFailed(detail: "closed")))
                == [.lost(.timedOut)])
        #expect(machine.state.pendingFailure == nil)
    }

    @Test func aChannelLostOnItsOwnReportsItsFailure() {
        var machine = EventsLivenessMachine()
        #expect(
            machine.handle(.streamEnded(failure: .channelFailed(detail: "closed")))
                == [.lost(.channelFailed(detail: "closed"))])
    }

    @Test func aChannelThatEndedGracefullyForNoReasonIsUnexpected() {
        var machine = EventsLivenessMachine()
        #expect(
            machine.handle(.streamEnded(failure: nil))
                == [.lost(.channelFailed(detail: "events stream ended unexpectedly"))])
    }

    @Test func goingLiveForgetsAnOlderKeepaliveFailure() {
        var machine = EventsLivenessMachine().after([.keepaliveFailed(.timedOut)])
        #expect(machine.handle(.wentLive) == [])
        #expect(machine.state.pendingFailure == nil)
    }

    @Test func theTeardownForgetsTheFailureAndTheActivity() {
        var machine = EventsLivenessMachine().after([
            .measured(.milliseconds(40)), .activity(now: start), .keepaliveFailed(.timedOut),
        ])
        #expect(machine.handle(.woundDown) == [])
        #expect(machine.state.pendingFailure == nil)
        #expect(machine.isIdle(now: start, within: interval))
        // Round trips outlive the teardown: the return's checks are timed by them.
        #expect(machine.roundTrip == .milliseconds(40))
    }
}
