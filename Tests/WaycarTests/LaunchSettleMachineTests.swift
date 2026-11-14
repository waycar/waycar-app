import Testing

@testable import Waycar

/// `LaunchSettleMachine`: the herdr Transport's post-start `agent.get`
/// settle per launched pane.
@Suite("launch settle machine")
struct LaunchSettleMachineTests {
    typealias Machine = LaunchSettleMachine

    private let t0 = ContinuousClock.now
    private let timing = Machine.Timing(
        delay: .milliseconds(3500), interval: .seconds(1), window: .seconds(20))

    private func scheduled(
        _ pane: String = "w1:p1", startedAt: ContinuousClock.Instant? = nil,
        now: ContinuousClock.Instant? = nil, immediately: Bool = false
    ) -> Machine.Event {
        .scheduled(
            pane: pane, startedAt: startedAt ?? t0, now: now ?? t0, immediately: immediately)
    }

    private func start(
        _ pane: String = "w1:p1", token: UInt64, firstPause: Duration,
        startedAt: ContinuousClock.Instant? = nil
    ) -> Machine.Effect {
        .startTask(
            pane: pane, token: token, firstPause: firstPause, interval: .seconds(1),
            windowEnd: (startedAt ?? t0) + .seconds(20))
    }

    // MARK: Scheduling

    @Test func anAckStartsTheSettleAfterTheDelayFromTheStart() {
        var machine = Machine(timing: timing)
        #expect(
            machine.handle(scheduled(now: t0 + .milliseconds(500)))
                == [.cancelTask(pane: "w1:p1"), start(token: 1, firstPause: .seconds(3))])
        #expect(machine["w1:p1"] == Machine.PaneSettle(token: 1, phase: .delayed))
    }

    @Test func aStartLongerAgoThanTheDelayPollsAtOnce() {
        var machine = Machine(timing: timing)
        #expect(
            machine.handle(scheduled(now: t0 + .seconds(5)))
                == [.cancelTask(pane: "w1:p1"), start(token: 1, firstPause: .zero)])
    }

    @Test func aRecoverySkipsTheDelayAndItsWindowRunsFromRecovery() {
        let recoveredAt = t0 + .seconds(40)
        var machine = Machine(timing: timing)
        #expect(
            machine.handle(scheduled(startedAt: recoveredAt, now: recoveredAt, immediately: true))
                == [
                    .cancelTask(pane: "w1:p1"),
                    start(token: 1, firstPause: .zero, startedAt: recoveredAt),
                ])
    }

    @Test func aNewSettleReplacesThePanesSettleUnderANewToken() {
        var machine = Machine(timing: timing).after([scheduled()])
        #expect(
            machine.handle(scheduled(now: t0 + .seconds(1)))
                == [.cancelTask(pane: "w1:p1"), start(token: 2, firstPause: .milliseconds(2500))])
        #expect(machine["w1:p1"] == Machine.PaneSettle(token: 2, phase: .delayed))
    }

    @Test func settlesOfDifferentPanesAreIndependent() {
        var machine = Machine(timing: timing).after([scheduled("w1:p1")])
        _ = machine.handle(scheduled("w1:p2"))
        #expect(machine["w1:p1"]?.token == 1)
        #expect(machine["w1:p2"]?.token == 2)
        _ = machine.handle([.pollStarted(pane: "w1:p2", token: 2)])
        #expect(machine["w1:p1"]?.phase == .delayed)
        #expect(machine["w1:p2"]?.phase == .polling)
    }

    // MARK: Polling

    @Test func aPendingPollAsksForAnotherAfterTheInterval() {
        var machine = Machine(timing: timing).after([
            scheduled(), .pollStarted(pane: "w1:p1", token: 1),
        ])
        #expect(machine["w1:p1"]?.phase == .polling)
        #expect(machine.handle(.polled(pane: "w1:p1", token: 1, .pending)) == [.pollAgain])
        #expect(machine["w1:p1"]?.phase == .delayed)
    }

    @Test func aPollThatFindsTheLaunchPromotedSettlesIt() {
        var machine = Machine(timing: timing).after([
            scheduled(), .pollStarted(pane: "w1:p1", token: 1),
        ])
        #expect(machine.handle(.polled(pane: "w1:p1", token: 1, .notPending)).isEmpty)
        #expect(machine["w1:p1"]?.phase == .settled)
        #expect(
            machine.handle(.ended(pane: "w1:p1", token: 1, .stopped))
                == [.releaseSlot(pane: "w1:p1")])
        #expect(machine["w1:p1"]?.phase == .settled)
    }

    @Test func aFailedPollEndsTheSettle() {
        var machine = Machine(timing: timing).after([
            scheduled(), .pollStarted(pane: "w1:p1", token: 1),
        ])
        #expect(machine.handle(.polled(pane: "w1:p1", token: 1, .failed)).isEmpty)
        #expect(machine["w1:p1"]?.phase == .failed)
        #expect(
            machine.handle(.ended(pane: "w1:p1", token: 1, .stopped))
                == [.releaseSlot(pane: "w1:p1")])
    }

    @Test func theWindowEndingBeforeThePollExpiresTheSettle() {
        var machine = Machine(timing: timing).after([
            scheduled(), .pollStarted(pane: "w1:p1", token: 1),
            .polled(pane: "w1:p1", token: 1, .pending),
        ])
        #expect(
            machine.handle(.ended(pane: "w1:p1", token: 1, .expired))
                == [.releaseSlot(pane: "w1:p1")])
        #expect(machine["w1:p1"]?.phase == .expired)
    }

    // MARK: Stale tokens

    @Test func aReplacedSettlesPollAndEndChangeNothing() {
        var machine = Machine(timing: timing).after([
            scheduled(), .pollStarted(pane: "w1:p1", token: 1), scheduled(),
        ])
        // The replaced settle's in-flight poll answers pending: no repeat.
        #expect(machine.handle(.polled(pane: "w1:p1", token: 1, .pending)).isEmpty)
        #expect(machine.handle(.pollStarted(pane: "w1:p1", token: 1)).isEmpty)
        // Its end never clears its replacement's slot.
        #expect(machine.handle(.ended(pane: "w1:p1", token: 1, .cancelled)).isEmpty)
        #expect(machine["w1:p1"] == Machine.PaneSettle(token: 2, phase: .delayed))
    }

    @Test func aSettleReplacedAfterItsLastPollDoesNotClearItsReplacement() {
        var machine = Machine(timing: timing).after([
            scheduled(), .pollStarted(pane: "w1:p1", token: 1),
            .polled(pane: "w1:p1", token: 1, .notPending), scheduled(),
        ])
        #expect(machine.handle(.ended(pane: "w1:p1", token: 1, .stopped)).isEmpty)
        #expect(machine["w1:p1"] == Machine.PaneSettle(token: 2, phase: .delayed))
    }

    @Test func aPollForAnotherPhaseIsIgnored() {
        var machine = Machine(timing: timing).after([scheduled()])
        // No poll started: an answer is not this settle's.
        #expect(machine.handle(.polled(pane: "w1:p1", token: 1, .pending)).isEmpty)
        #expect(machine["w1:p1"]?.phase == .delayed)
        #expect(machine.handle(.pollStarted(pane: "w9", token: 1)).isEmpty)
        #expect(machine["w9"] == nil)
    }

    // MARK: Close

    @Test func closingCancelsEveryRunningSettleAndTheirEndsAreIgnored() {
        var machine = Machine(timing: timing).after([
            scheduled("w1:p1"), scheduled("w1:p2"), .pollStarted(pane: "w1:p2", token: 2),
        ])
        #expect(machine.handle(.closed) == [.cancelAllTasks])
        #expect(machine.state.isClosed)
        #expect(machine["w1:p1"]?.phase == .cancelled)
        #expect(machine["w1:p2"]?.phase == .cancelled)
        #expect(machine.handle(.polled(pane: "w1:p2", token: 2, .pending)).isEmpty)
        #expect(machine.handle(.ended(pane: "w1:p1", token: 1, .cancelled)).isEmpty)
    }

    @Test func aSettleScheduledAfterTheCloseStillStarts() {
        var machine = Machine(timing: timing).after([.closed])
        #expect(
            machine.handle(scheduled())
                == [.cancelTask(pane: "w1:p1"), start(token: 1, firstPause: .milliseconds(3500))])
    }
}
