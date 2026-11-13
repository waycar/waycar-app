import Testing

@testable import Waycar

@Suite("Composer drain machine")
struct ComposerDrainMachineTests {
    private let wake = ComposerDrainMachine.Event.wake(resetBackoff: false, hasQueuedRecord: true)
    private let reconnect = ComposerDrainMachine.Event.wake(resetBackoff: true, hasQueuedRecord: true)
    private func running() -> ComposerDrainMachine { ComposerDrainMachine().after([wake]) }
    private func finished(_ token: UInt64, _ outcome: ComposerDrainMachine.Outcome) -> ComposerDrainMachine.Event {
        .attemptFinished(token, outcome, launchDelay: .milliseconds(500))
    }

    @Test func startsOnlyWhenThereIsAQueuedRecordAndFinishesWhenEmpty() {
        var machine = ComposerDrainMachine()
        #expect(machine.handle(.wake(resetBackoff: false, hasQueuedRecord: false)) == [])
        #expect(machine.handle(wake) == [.start(1)])
        #expect(machine.handle(finished(1, .settled)) == [.continueDrain(1)])
        #expect(machine.handle(.ended(1, clearFailures: true)) == [.finish(1)])
        #expect(machine.state == .idle(failures: 0))
    }

    @Test func agentWakeIsConsumedOnceAndDoesNotResetLinkFailures() {
        var machine = running()
        #expect(machine.handle(wake) == [])
        #expect(machine.handle(finished(1, .waitsForAgent)) == [.continueDrain(1)])
        #expect(machine.handle(.iterationStarted(1)) == [])
        #expect(machine.handle(finished(1, .waitsForAgent)) == [.finish(1)])
        #expect(machine.state == .waitingForAgent(failures: 0))
        #expect(machine.handle(wake) == [.start(2)])
        #expect(machine.handle(wake) == [])
        #expect(machine.handle(finished(2, .notSent)) == [.finish(2), .armRetry(3, after: .seconds(2))])
    }

    @Test func reconnectWakeContinuesOneUnsentAttemptThenBacksOffAgain() {
        var machine = running()
        #expect(machine.handle(reconnect) == [])
        #expect(machine.handle(wake) == []) // An Agent wake cannot downgrade a reconnect.
        #expect(machine.handle(finished(1, .notSent)) == [.continueDrain(1)])
        #expect(machine.handle(.iterationStarted(1)) == [])
        #expect(machine.handle(finished(1, .notSent)) == [.finish(1), .armRetry(2, after: .seconds(2))])
        #expect(machine.handle(wake) == [])
        #expect(machine.handle(reconnect) == [.cancelRetry(2), .start(3)])
        #expect(machine.state == .draining(3, failures: 0, wake: .none, retry: nil))
    }

    @Test func retryTimersBackOffAndStaleTimersCannotRestartAnything() {
        var machine = ComposerDrainMachine()
        #expect(machine.handle(.unsent) == [.armRetry(1, after: .seconds(2))])
        #expect(machine.handle(.timerElapsed(9, mayWake: true, hasQueuedRecord: true)) == [])
        #expect(machine.handle(.timerElapsed(1, mayWake: true, hasQueuedRecord: true)) == [.cancelRetry(1), .start(2)])
        #expect(machine.handle(finished(2, .notSent)) == [.finish(2), .armRetry(3, after: .seconds(4))])
        #expect(machine.handle(.unsent) == [.cancelRetry(3), .armRetry(4, after: .seconds(8))])
        #expect(machine.handle(.timerElapsed(3, mayWake: true, hasQueuedRecord: true)) == [])
        #expect(machine.handle(.timerElapsed(4, mayWake: false, hasQueuedRecord: true)) == [.cancelRetry(4)])
        #expect(machine.state == .idle(failures: 3))
        #expect(machine.handle(wake) == [.start(5)])
        #expect(machine.handle(.ended(5, clearFailures: false)) == [.finish(5)])
        #expect(machine.state == .idle(failures: 3))
        #expect(ComposerDrainMachine.retryDelay(afterFailures: -1) == .seconds(2))
        #expect(ComposerDrainMachine.retryDelay(afterFailures: 20) == .seconds(300))
    }

    @Test func launchWaitUsesItsOwnDelayAndDoesNotIncreaseFailures() {
        var machine = running()
        #expect(machine.handle(finished(1, .waitsForLaunch)) == [.finish(1), .armRetry(2, after: .milliseconds(500))])
        #expect(machine.state == .waitingForLaunch(.init(token: 2), failures: 0))
        #expect(machine.handle(wake) == [])
        #expect(machine.handle(.timerElapsed(2, mayWake: true, hasQueuedRecord: false)) == [.cancelRetry(2)])
        #expect(machine.state == .idle(failures: 0))
    }

    @Test func directSendFailureMayArmATimerDuringAnActiveDrain() {
        var machine = running()
        #expect(machine.handle(.unsent) == [.armRetry(2, after: .seconds(2))])
        #expect(machine.state == .draining(1, failures: 1, wake: .none, retry: .init(token: 2)))
        #expect(machine.handle(wake) == []) // Pending backoff suppresses ordinary wakes.
        #expect(machine.handle(.timerElapsed(2, mayWake: true, hasQueuedRecord: true)) == [.cancelRetry(2)])
        #expect(machine.handle(finished(1, .waitsForAgent)) == [.continueDrain(1)])
        #expect(machine.handle(.iterationStarted(1)) == [])
        #expect(machine.handle(finished(1, .notSent)) == [.finish(1), .armRetry(3, after: .seconds(4))])
    }

    @Test func existingTimerSurvivesDrainFinishingOrWaitingOnTheAgent() {
        var machine = running().after([.unsent])
        #expect(machine.handle(.ended(1, clearFailures: true)) == [.finish(1)])
        #expect(machine.state == .backingOff(.init(token: 2), failures: 0))
        machine = running().after([.unsent])
        #expect(machine.handle(finished(1, .waitsForAgent)) == [.finish(1)])
        #expect(machine.state == .backingOff(.init(token: 2), failures: 1))
        machine = running().after([.unsent])
        #expect(machine.handle(reconnect) == [.cancelRetry(2)])
        #expect(machine.state == .draining(1, failures: 0, wake: .reconnect, retry: nil))
    }

    @Test func cancelStopsBothWorkersAndRejectsEveryLateCompletionOrWake() {
        var machine = running().after([.unsent])
        #expect(machine.handle(.cancel) == [.cancelDrain(1), .cancelRetry(2)])
        #expect(machine.isCancelled)
        #expect(machine.handle([wake, reconnect, .unsent, .iterationStarted(1), finished(1, .settled),
            .timerElapsed(2, mayWake: true, hasQueuedRecord: true), .ended(1, clearFailures: true), .cancel]) == [])
    }

    @Test func staleDrainResultsCannotFinishItsSuccessor() {
        var machine = running().after([.ended(1, clearFailures: true), wake])
        let before = machine.state
        #expect(machine.handle([.iterationStarted(1), finished(1, .notSent), .ended(1, clearFailures: true)]) == [])
        #expect(machine.state == before)
        machine = ComposerDrainMachine()
        #expect(machine.handle([.iterationStarted(1), finished(1, .settled), .ended(1, clearFailures: true)]) == [])
    }
}
