import Testing

@testable import Waycar

/// `EventsLifecycleMachine` (HERDR-01): one test per transition, plus the
/// stale and ignored cases. The owner suites are `EventsSessionSubscriptionsTests`
/// (lifecycle), `EventsSessionResilienceTests` (redials) and the connect flows.
@Suite("EventsLifecycleMachine")
struct EventsLifecycleMachineTests {
    private typealias Dial = EventsLifecycleMachine.Dial
    private let unreachable = TransportError.sshUnreachable(detail: "no route")

    private var active: EventsLifecycleMachine {
        EventsLifecycleMachine().after([.activate(trigger: nil)])
    }

    @Test func aFreshSessionIsSuspended() {
        let machine = EventsLifecycleMachine()
        #expect(machine.stage == .suspended)
        #expect(!machine.acceptsWaiters)
        #expect(!machine.isCurrent(0))
    }

    @Test func activationAnnouncesConnectingAndSpawnsTheRun() {
        var machine = EventsLifecycleMachine()
        #expect(machine.handle(.activate(trigger: nil)) == [.announce(.connecting), .spawnRun(activation: 1)])
        #expect(machine.stage == .connecting)
        #expect(machine.isCurrent(1))
        #expect(machine.acceptsWaiters)
        #expect(machine.state.trigger == .launch)
    }

    @Test func laterActivationsReportTheirTrigger() {
        var machine = active.after([.suspend, .windDownStarted, .runAbandoned, .windDownEnded])
        _ = machine.handle(.activate(trigger: nil))
        #expect(machine.state.trigger == .foreground)
        _ = machine.handle([.suspend, .windDownStarted, .runAbandoned, .windDownEnded])
        _ = machine.handle(.activate(trigger: .retry))
        #expect(machine.state.trigger == .retry)
        #expect(machine.activation == 3)
    }

    @Test func activationIsIgnoredUnlessSuspended() {
        var machine = active
        #expect(machine.handle(.activate(trigger: nil)) == [])
        _ = machine.handle([.end, .windDownStarted, .runAbandoned, .windDownEnded])
        #expect(machine.handle(.activate(trigger: nil)) == [])
        #expect(machine.stage == .ended)
    }

    @Test func aRestartMovesToANewActivationBeforeItsTeardown() {
        var machine = active.after([.wentLive])
        #expect(machine.handle(.restart) == [.announce(.connecting), .windDown])
        #expect(machine.activation == 2)
        #expect(!machine.isCurrent(1))
        #expect(machine.stage == .connecting)
        #expect(machine.state.trigger == .retry)
        _ = machine.handle([.windDownStarted, .backoffAbandoned, .runAbandoned])
        #expect(machine.stage == .windingDown)
        #expect(machine.phase == .active)
        #expect(!machine.acceptsWaiters)
        _ = machine.handle(.windDownEnded)
        #expect(machine.handle(.restartWoundDown(activation: 2)) == [.spawnRun(activation: 2)])
        #expect(machine.acceptsWaiters)
    }

    @Test func aRestartIsIgnoredUnlessActive() {
        var machine = EventsLifecycleMachine()
        #expect(machine.handle(.restart) == [])
    }

    @Test func aRestartWhoseActivationMovedOnSpawnsNothing() {
        var machine = active.after([.restart])
        #expect(machine.handle(.restartWoundDown(activation: 1)) == [])
        _ = machine.handle([.suspend])
        #expect(machine.handle(.restartWoundDown(activation: 2)) == [])
    }

    @Test func aSuspensionIsSuspendedAtOnceAndAnnouncedAfterItsTeardown() {
        var machine = active.after([.wentLive])
        #expect(machine.handle(.suspend) == [.windDown])
        #expect(machine.stage == .suspended)
        #expect(!machine.isCurrent(1))
        // The run loop is not cancelled until the teardown.
        #expect(machine.state.running)
        _ = machine.handle([.windDownStarted, .runAbandoned])
        #expect(machine.stage == .windingDown)
        _ = machine.handle(.windDownEnded)
        #expect(machine.handle(.suspendWoundDown) == [.announce(.suspended)])
        #expect(!machine.state.running)
        #expect(machine.handle(.suspend) == [])
    }

    @Test func endingIsFinal() {
        var machine = active
        #expect(machine.handle(.end) == [.windDown])
        #expect(machine.stage == .ended)
        #expect(machine.handle(.endWoundDown) == [.announce(.ended)])
        #expect(machine.handle(.end) == [])
    }

    @Test func endingWhileSuspendedStillWindsDown() {
        var machine = EventsLifecycleMachine()
        #expect(machine.handle(.end) == [.windDown])
    }

    @Test func theTeardownCancelsTheBackoffAndTheRun() {
        var machine = active.after([.backoffStarted(attempt: 1, delay: .seconds(1), failure: unreachable)])
        #expect(machine.handle(.windDownStarted) == [])
        #expect(machine.isWindingDown)
        #expect(machine.handle(.backoffAbandoned) == [.cancelBackoff])
        #expect(machine.state.backoff == nil)
        #expect(machine.handle(.runAbandoned) == [.cancelRun])
        #expect(machine.handle(.windDownEnded) == [])
        #expect(!machine.isWindingDown)
    }

    @Test func theTeardownForgetsARequestedRedial() {
        var machine = active.after([.dialStarted, .redial(channelLive: false, trigger: .pathChange)])
        #expect(machine.state.redialRequested)
        _ = machine.handle([.windDownStarted, .windDownEnded])
        #expect(!machine.state.redialRequested)
    }

    @Test func aDialIsTrackedUntilItEnds() {
        var machine = active
        #expect(machine.handle(.dialStarted) == [.dialing(id: 1)])
        #expect(machine.state.dial == Dial(id: 1, afterRedial: false))
        #expect(machine.handle(.dialSucceeded) == [])
        #expect(machine.handle(.dialEnded(id: 1)) == [.forgetDial])
        #expect(machine.state.dial == nil)
    }

    @Test func anOlderDialEndingLeavesTheNewerOneTracked() {
        var machine = active.after([.dialStarted, .dialStarted])
        #expect(machine.handle(.dialEnded(id: 1)) == [])
        #expect(machine.state.dial?.id == 2)
    }

    @Test func aRedialDuringABackoffCutsItShort() {
        var machine = active.after([.backoffStarted(attempt: 1, delay: .seconds(60), failure: unreachable)])
        #expect(machine.handle(.redial(channelLive: false, trigger: .pathChange)) == [.cutBackoff])
        #expect(machine.state.trigger == .pathChange)
        #expect(machine.state.redialSinceLastDial)
        // Cut short, not cleared: the backoff clears itself as it wakes.
        #expect(machine.state.backoff == 1)
        #expect(machine.handle(.dialStarted) == [.dialing(id: 1)])
        #expect(machine.state.dial == Dial(id: 1, afterRedial: true))
        #expect(!machine.state.redialSinceLastDial)
    }

    @Test func aRedialAbandonsAStuckDialAndDialsAgain() {
        var machine = active.after([.dialStarted])
        #expect(machine.handle(.redial(channelLive: false, trigger: .pathChange)) == [.abandonDial(id: 1)])
        #expect(machine.handle(.dialAbandoned(id: 1)) == [.cancelDial, .cutBackoff])
        _ = machine.handle(.dialEnded(id: 1))
        #expect(machine.handle(.connectFailed) == [.dialAgain])
        #expect(machine.handle(.connectFailed) == [])
    }

    @Test func aDialThatEndedWhileThePoolWasAbandonedIsNotCancelled() {
        var machine = active.after([.dialStarted, .redial(channelLive: false, trigger: .pathChange)])
        _ = machine.handle([.dialSucceeded, .dialEnded(id: 1)])
        #expect(machine.handle(.dialAbandoned(id: 1)) == [.cutBackoff])
        #expect(!machine.state.redialRequested)
    }

    @Test func aSecondRedialLeavesTheFirstRedialsDialAlone() {
        var machine = active.after([
            .dialStarted, .redial(channelLive: false, trigger: .pathChange), .dialAbandoned(id: 1),
            .dialEnded(id: 1), .connectFailed, .dialStarted,
        ])
        #expect(machine.state.dial == Dial(id: 2, afterRedial: true))
        #expect(machine.handle(.redial(channelLive: false, trigger: .moshRecovery)) == [])
        #expect(machine.state.trigger == .pathChange)
    }

    @Test func aRedialIsIgnoredWhileLiveSuspendedOrWindingDown() {
        var live = active
        #expect(live.handle(.redial(channelLive: true, trigger: .pathChange)) == [])
        var suspended = EventsLifecycleMachine()
        #expect(suspended.handle(.redial(channelLive: false, trigger: .pathChange)) == [])
        var windingDown = active.after([.restart, .windDownStarted])
        #expect(windingDown.handle(.redial(channelLive: false, trigger: .pathChange)) == [])
        #expect(windingDown.state.trigger == .retry)
    }

    @Test func goingLiveAnnouncesConnectedAndEndsTheRedialWindow() {
        var machine = active.after([.backoffStarted(attempt: 1, delay: .seconds(1), failure: unreachable),
            .redial(channelLive: false, trigger: .pathChange)])
        #expect(machine.handle(.wentLive) == [.announce(.connected)])
        #expect(machine.stage == .connected)
        #expect(!machine.state.redialSinceLastDial)
    }

    @Test func aFailureAnnouncesFailedAndKeepsTheRunForRequests() {
        var machine = active
        #expect(machine.handle(.failed(.authenticationFailed)) == [.announce(.failed(.authenticationFailed))])
        #expect(machine.stage == .failed)
        #expect(machine.acceptsWaiters)
    }

    @Test func aBackoffAnnouncesReconnectingAndSleepsUnderAFreshTimer() {
        var machine = active.after([.wentLive])
        #expect(
            machine.handle(.backoffStarted(attempt: 2, delay: .seconds(2), failure: unreachable))
                == [
                    .announce(.reconnecting(attempt: 2, delay: .seconds(2), failure: unreachable)),
                    .sleep(timer: 1, delay: .seconds(2)),
                ])
        #expect(machine.stage == .backingOff)
        #expect(machine.state.trigger == .retry)
        #expect(machine.handle(.backoffElapsed(timer: 1)) == [.forgetBackoff])
        #expect(machine.state.backoff == nil)
        // The dial after the backoff is still the reconnect.
        #expect(machine.stage == .backingOff)
    }

    @Test func aBackoffAbandonedByATeardownDoesNotClearTheNextOne() {
        var machine = active.after([
            .backoffStarted(attempt: 1, delay: .seconds(1), failure: unreachable),
            .restart, .windDownStarted, .backoffAbandoned, .runAbandoned, .windDownEnded,
            .restartWoundDown(activation: 2),
            .backoffStarted(attempt: 1, delay: .seconds(1), failure: unreachable),
        ])
        #expect(machine.handle(.backoffElapsed(timer: 1)) == [])
        #expect(machine.state.backoff == 2)
    }
}
