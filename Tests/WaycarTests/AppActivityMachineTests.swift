import Foundation
import Testing

@testable import Waycar

@Suite("App activity machine")
struct AppActivityMachineTests {
    private let now = ContinuousClock.now
    private var machine: AppActivityMachine { AppActivityMachine(gracePeriod: .seconds(20)) }

    @Test func onlyTheLastSourceLeavingStartsOneGracePeriod() {
        var machine = self.machine
        #expect(machine.state == .foreground([]))
        #expect(machine.handle(.becameActive(.phone, now: now)) == [
            .activated(absence: nil, crossedGrace: false, at: now),
        ])
        #expect(machine.handle(.becameActive(.carPlay, now: now)) == [])
        #expect(machine.handle(.enteredBackground(.phone, now: now)) == [])
        #expect(machine.handle(.enteredBackground(.carPlay, now: now)) == [.beginGrace(1)])
        #expect(machine.state == .grace(startedAt: now, grant: 1))
        #expect(machine.handle(.enteredBackground(.carPlay, now: now)) == [])
        #expect(machine.phase == .active)
    }

    @Test func aPhoneEdgeAlwaysActivatesButAnotherJoiningSourceDoesNot() {
        var machine = self.machine.after([.becameActive(.watch, now: now)])
        #expect(machine.activationCount == 1)
        #expect(machine.handle(.becameActive(.carPlay, now: now)) == [])
        #expect(machine.activationCount == 1)
        #expect(machine.handle(.becameActive(.phone, now: now)) == [
            .activated(absence: nil, crossedGrace: false, at: now),
        ])
        #expect(machine.activationCount == 2)
    }

    @Test func aGraceBounceReleasesItsGrantAndCountsTheAbsence() {
        var machine = self.machine.after([.enteredBackground(.phone, now: now)])
        let returned = now.advanced(by: .seconds(19))
        #expect(machine.handle(.becameActive(.phone, now: returned)) == [
            .cancelGrace(1), .releaseGrant(1),
            .activated(absence: .seconds(19), crossedGrace: false, at: returned),
        ])
        #expect(machine.state == .foreground([.phone]))
        #expect(machine.activationCount == 1)
        #expect(!machine.lastAbsenceMayHaveSuspended)
        #expect(machine.lastAbsenceDuration == .seconds(19))
    }

    @Test func aFrozenAbsenceCrossesTheInclusiveInjectedBoundaryAndResets() {
        var machine = self.machine.after([.enteredBackground(.phone, now: now)])
        _ = machine.handle(.becameActive(.carPlay, now: now.advanced(by: .seconds(20))))
        #expect(machine.lastAbsenceMayHaveSuspended)
        _ = machine.handle(.becameActive(.carPlay, now: now))
        #expect(!machine.lastAbsenceMayHaveSuspended)
        #expect(machine.lastAbsenceDuration == nil)
    }

    @Test func timerSuspensionKeepsTheGrantUntilTeardownFinishes() {
        var machine = self.machine.after([.enteredBackground(.phone, now: now)])
        #expect(machine.handle(.graceElapsed(1)) == [.cancelGrace(1), .suspended])
        #expect(machine.state == .suspending(startedAt: now, grant: 1))
        #expect(machine.phase == .suspended)
        #expect(machine.hasBackgroundTimeForTeardown)
        #expect(machine.handle(.teardownFinished) == [.releaseGrant(1)])
        #expect(machine.state == .suspended(startedAt: now))
        #expect(!machine.hasBackgroundTimeForTeardown)
    }

    @Test func foregroundingDuringTeardownCancelsItWithoutLosingTheAbsence() {
        var machine = self.machine.after([.enteredBackground(.phone, now: now), .graceElapsed(1)])
        let returned = now.advanced(by: .seconds(1))
        #expect(machine.handle(.becameActive(.watch, now: returned)) == [
            .cancelGrace(1), .releaseGrant(1),
            .activated(absence: .seconds(1), crossedGrace: true, at: returned),
        ])
        #expect(machine.handle(.teardownFinished) == [])
        #expect(!machine.hasBackgroundTimeForTeardown)
    }

    @Test func expirationReleasesBeforeSuspendingAndDoesNotSuspendTwice() {
        var machine = self.machine.after([.enteredBackground(.phone, now: now)])
        #expect(machine.handle(.grantExpired(1)) == [.cancelGrace(1), .releaseGrant(1), .suspended])
        #expect(machine.state == .suspended(startedAt: now))
        #expect(!machine.hasBackgroundTimeForTeardown)
        let returned = now.advanced(by: .seconds(1))
        #expect(machine.handle(.becameActive(.phone, now: returned)) == [
            .activated(absence: .seconds(1), crossedGrace: true, at: returned),
        ])
        var tearingDown = self.machine.after([.enteredBackground(.phone, now: now), .graceElapsed(1)])
        #expect(tearingDown.handle(.grantExpired(1)) == [.cancelGrace(1), .releaseGrant(1)])
        #expect(tearingDown.state == .suspended(startedAt: now))
    }

    @Test func refusalSuspendsWithoutLendingAnyTime() {
        var machine = self.machine.after([.enteredBackground(.phone, now: now)])
        #expect(machine.handle(.grantRefused(1)) == [.cancelGrace(1), .suspended])
        #expect(machine.state == .suspended(startedAt: now))
        #expect(!machine.hasBackgroundTimeForTeardown)
    }

    @Test func oldGrantCallbacksAndTimersCannotAffectForegroundOrANewerGrant() {
        var machine = self.machine.after([
            .enteredBackground(.phone, now: now), .becameActive(.phone, now: now),
        ])
        #expect(machine.handle([.grantExpired(1), .grantRefused(1), .graceElapsed(1), .teardownFinished]) == [])
        #expect(machine.state == .foreground([.phone]))
        #expect(machine.handle(.enteredBackground(.phone, now: now)) == [.beginGrace(2)])
        #expect(machine.handle([.grantExpired(1), .grantRefused(1), .graceElapsed(1), .teardownFinished]) == [])
        #expect(machine.state == .grace(startedAt: now, grant: 2))
        _ = machine.handle(.graceElapsed(2))
        #expect(machine.handle([.grantExpired(1), .grantRefused(1), .graceElapsed(1)]) == [])
        #expect(machine.state == .suspending(startedAt: now, grant: 2))
    }

    @Test func redundantBackgroundAndCompletionEventsCannotResuspend() {
        var machine = self.machine.after([.enteredBackground(.phone, now: now), .graceElapsed(1)])
        #expect(machine.handle([.enteredBackground(.phone, now: now), .graceElapsed(1), .grantRefused(1)]) == [])
        _ = machine.handle(.teardownFinished)
        #expect(machine.handle([
            .enteredBackground(.phone, now: now), .graceElapsed(1), .grantRefused(1),
            .grantExpired(1), .teardownFinished,
        ]) == [])
        #expect(machine.state == .suspended(startedAt: now))
    }
}
