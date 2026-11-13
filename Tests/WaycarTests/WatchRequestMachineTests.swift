import Foundation
import Testing
@testable import Waycar

struct WatchRequestMachineTests {
    let now = ContinuousClock.now
    private func machine() -> WatchRequestMachine { .init(budget: .seconds(20), maxSends: 2) }

    @Test func pauseResumesBudgetAndRejectsOldDeadline() {
        var machine = self.machine()
        #expect(machine.handle(.transmit(now: now)) == [.send(1), .arm(1, .seconds(20))])
        #expect(machine.handle(.pause(now: now + .seconds(3))) == [.stopTimer])
        #expect(machine.isPaused)
        #expect(machine.handle(.deadline(1)).isEmpty)
        #expect(machine.handle(.resume(now: now + .seconds(100))) == [.arm(2, .seconds(17))])
        #expect(machine.handle(.deadline(1)).isEmpty)
        #expect(machine.handle(.deadline(2)) == [.cancelWork, .stopTimer, .forgetWork, .complete(.noAnswer)])
        #expect(machine.state == .finished)
        #expect(machine.handle(.reply).isEmpty)
    }

    @Test func lossAndResendSpendOneSharedBudget() {
        var machine = self.machine().after([.transmit(now: now)])
        #expect(machine.handle(.lose(now: now + .seconds(4))) == [.stopTimer, .cancelWork, .forgetWork])
        #expect(machine.handle(.transmit(now: now + .seconds(100))) == [.send(2), .arm(2, .seconds(16))])
        #expect(machine.handle(.error(attempt: 1, unreachable: false, now: now)).isEmpty)
        #expect(machine.handle(.reply) == [.stopTimer, .forgetWork, .complete(.reply)])
    }

    @Test func earlierSuccessWinsEvenWhileWaitingOrPaused() {
        var waiting = machine().after([.transmit(now: now), .lose(now: now)])
        #expect(waiting.handle(.reply) == [.stopTimer, .forgetWork, .complete(.reply)])
        var paused = machine().after([.transmit(now: now), .pause(now: now)])
        #expect(paused.handle(.reply) == [.stopTimer, .forgetWork, .complete(.reply)])
    }

    @Test func pausedErrorLosesButReadyErrorFailsOrRaisesDoubt() {
        var paused = machine().after([.transmit(now: now), .pause(now: now + .seconds(2))])
        #expect(paused.handle(.error(attempt: 99, unreachable: true, now: now)).isEmpty)
        #expect(paused.handle(.error(attempt: 1, unreachable: true, now: now)) == [.cancelWork, .forgetWork])
        #expect(paused.state == .waiting(sends: 1, budget: .seconds(18)))
        var ready = machine().after([.transmit(now: now)])
        #expect(ready.handle(.error(attempt: 1, unreachable: false, now: now)) == [.stopTimer, .forgetWork, .complete(.error)])
        var doubt = machine().after([.transmit(now: now)])
        #expect(doubt.handle(.error(attempt: 1, unreachable: true, now: now)) == [.stopTimer, .cancelWork, .forgetWork, .doubtLink])
    }

    @Test func sendLimitAndSpentBudgetFailWithoutSending() {
        var exhausted = machine().after([
            .transmit(now: now), .lose(now: now), .transmit(now: now), .lose(now: now),
        ])
        #expect(exhausted.handle(.transmit(now: now)) == [.stopTimer, .forgetWork, .complete(.noAnswer)])
        var spent = machine().after([.transmit(now: now), .lose(now: now + .seconds(20))])
        #expect(spent.handle(.transmit(now: now)) == [.stopTimer, .forgetWork, .complete(.noAnswer)])
    }

    @Test func waitingIgnoresUnrelatedWorkAndDownCompletes() {
        var machine = self.machine()
        #expect(machine.handle([.pause(now: now), .resume(now: now), .lose(now: now),
                                .deadline(1), .error(attempt: 1, unreachable: false, now: now)]).isEmpty)
        #expect(machine.handle(.unreachable) == [.stopTimer, .forgetWork, .complete(.unreachable)])
        #expect(machine.handle(.transmit(now: now)).isEmpty)
    }
}
