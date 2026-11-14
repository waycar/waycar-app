import Testing

@testable import Waycar

@Suite("Message jump frame wait machine")
struct MessageJumpFrameWaitMachineTests {
    private typealias Machine = MessageJumpFrameWaitMachine

    /// A run with a step whose continuation is held under token 1.
    private func held() -> Machine {
        Machine().after([
            .start, .beginAwaiting, .prepareWait(taskCancelled: false),
            .continuationArmed(1, taskCancelled: false),
        ])
    }

    @Test func oneRunAtATime() {
        var machine = Machine()
        #expect(machine.handle(.start) == [.started])
        #expect(machine.isRunning)
        #expect(machine.handle(.start) == [.refused])
        #expect(machine.handle(.finish) == [.cancelTimer])
        #expect(!machine.isRunning)
        #expect(machine.handle(.start) == [.started])
    }

    @Test func framesWhileIdleOnlyUpdateTheLatest() {
        var machine = Machine()
        #expect(machine.handle(.frameChanged("a")).isEmpty)
        #expect(machine.latestFrame == "a")
        #expect(machine.state.bufferedFrame == nil)
    }

    @Test func aFrameBeforeTheWaitArmsAnswersAtOnce() {
        var machine = Machine().after([.start, .beginAwaiting, .frameChanged("early")])
        #expect(machine.handle(.prepareWait(taskCancelled: false)) == [.answer(.frame("early"))])
        #expect(!machine.state.isAwaitingFrame)
        #expect(machine.state.wait == .none)
    }

    @Test func aCancelBeforeTheWaitWinsOverABufferedFrame() {
        var machine = Machine().after([.start, .beginAwaiting, .frameChanged("early"), .cancel])
        #expect(machine.handle(.prepareWait(taskCancelled: false)) == [.answer(.cancelled)])
        var taskCancelled = Machine().after([.start, .beginAwaiting])
        #expect(taskCancelled.handle(.prepareWait(taskCancelled: true)) == [.answer(.cancelled)])
    }

    @Test func anArmedWaitHoldsItsContinuationAndArmsItsTimer() {
        var machine = Machine().after([.start, .beginAwaiting])
        #expect(machine.handle(.prepareWait(taskCancelled: false)) == [.armWait(1)])
        #expect(machine.handle(.continuationArmed(1, taskCancelled: false)) == [
            .hold(1), .cancelTimer, .armTimer(1),
        ])
        #expect(machine.state.wait == .active(token: 1, held: true))
    }

    @Test func aCancelAtArmingAnswersWithoutHoldingAndKeepsTheTokenActive() {
        var machine = Machine().after([.start, .beginAwaiting, .prepareWait(taskCancelled: false)])
        #expect(machine.handle(.continuationArmed(1, taskCancelled: true)) == [.answer(.cancelled)])
        #expect(machine.state.wait == .active(token: 1, held: false))
        #expect(machine.handle(.timerFired(1)).isEmpty, "nothing is held to time out")
        #expect(machine.handle(.enclosingCancelled(1)).isEmpty)
        #expect(machine.state.cancelRequested, "a live handler still marks the run cancelled")
    }

    @Test func theFirstFrameWakesTheWaiterAndTheLatestDecides() {
        var machine = held()
        #expect(machine.handle(.frameChanged("partial")) == [.cancelTimer, .resume(1, .frame("partial"))])
        #expect(machine.handle(.frameChanged("whole")).isEmpty)
        #expect(machine.handle(.waitReturned(1, .frame("partial"), taskCancelled: false)) == [
            .answer(.frame("whole")),
        ])
        #expect(!machine.state.isAwaitingFrame)
        #expect(machine.state.bufferedFrame == nil)
    }

    @Test func aCancelWinsOverAFrameThatAlreadyResumed() {
        var machine = held()
        _ = machine.handle(.frameChanged("match"))
        #expect(machine.handle(.cancel).isEmpty)
        #expect(machine.handle(.waitReturned(1, .frame("match"), taskCancelled: false)) == [
            .answer(.cancelled),
        ])
    }

    @Test func theLiveTimerTimesOutItsWait() {
        var machine = held()
        #expect(machine.handle(.timerFired(1)) == [.cancelTimer, .resume(1, .timedOut)])
        #expect(machine.handle(.timerFired(1)).isEmpty)
        #expect(machine.handle(.waitReturned(1, .timedOut, taskCancelled: false)) == [.answer(.timedOut)])
    }

    @Test func aStaleTimerOrHandlerCannotTouchALaterWait() {
        var machine = held().after([
            .frameChanged("one"), .waitReturned(1, .frame("one"), taskCancelled: false),
            .beginAwaiting, .prepareWait(taskCancelled: false), .continuationArmed(2, taskCancelled: false),
        ])
        #expect(machine.state.wait == .active(token: 2, held: true))
        #expect(machine.handle(.timerFired(1)).isEmpty)
        #expect(machine.handle(.enclosingCancelled(1)).isEmpty)
        #expect(!machine.state.cancelRequested)
        #expect(machine.handle(.enclosingCancelled(2)) == [.cancelTimer, .resume(2, .cancelled)])
        #expect(machine.state.cancelRequested)
    }

    @Test func aHandlerLandingAfterItsRunEndedChangesNothing() {
        var machine = held().after([.finish])
        #expect(machine.handle(.enclosingCancelled(1)).isEmpty)
        #expect(!machine.state.cancelRequested)
        #expect(machine.handle(.start) == [.started])
    }

    @Test func cancelResumesTheHeldWaitOnce() {
        var machine = held()
        #expect(machine.handle(.cancel) == [.cancelTimer, .resume(1, .cancelled)])
        #expect(machine.handle(.cancel).isEmpty)
    }

    @Test func finishingAnswersAStrandedWaiterAndClearsTheRun() {
        var machine = held()
        #expect(machine.handle(.finish) == [.cancelTimer, .resume(1, .cancelled)])
        #expect(machine.state == Machine.State(latestFrame: ""))
        #expect(machine.handle(.waitReturned(1, .cancelled, taskCancelled: false)) == [.answer(.cancelled)])
    }

    @Test func aReturningWaitClearsOnlyItsOwnToken() {
        var machine = Machine().after([
            .start, .beginAwaiting, .prepareWait(taskCancelled: false),
            .continuationArmed(1, taskCancelled: true),
        ])
        #expect(machine.handle(.waitReturned(9, .cancelled, taskCancelled: true)) == [.answer(.cancelled)])
        #expect(machine.state.wait == .active(token: 1, held: false))
        _ = machine.handle(.waitReturned(1, .cancelled, taskCancelled: true))
        #expect(machine.state.wait == .none)
    }
}
