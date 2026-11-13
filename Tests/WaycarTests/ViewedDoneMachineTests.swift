import Foundation
import Testing

@testable import Waycar

@Suite("Viewed Done machine")
struct ViewedDoneMachineTests {
    private let first = ViewedDoneMachine.Target(
        agentID: .init(hostID: UUID(), paneID: "opaque:Pane/A"),
        terminalID: "terminal-A", transportGeneration: 1)

    @Test func eligibleTargetDwellsSendsAndStaysAttemptedUntilARealBoundary() {
        var machine = ViewedDoneMachine()
        #expect(machine.handle(.update(nil)).isEmpty)
        #expect(machine.handle(.update(first)) == [.startAttempt(1, first)])
        #expect(machine.state == .dwelling(attempt: 1, first))
        #expect(machine.isInFlight)
        #expect(machine.handle(.update(first)).isEmpty)
        #expect(machine.handle(.dwellElapsed(1)).isEmpty)
        #expect(machine.state == .sending(attempt: 1, first))
        #expect(machine.handle(.failure(1)) == [.reportFailure])
        #expect(machine.handle(.finished(1)).isEmpty)
        #expect(machine.state == .attempted(first))
        #expect(!machine.isInFlight)
        #expect(machine.handle([.failure(1), .dwellElapsed(1), .finished(1)]).isEmpty)
        #expect(machine.handle(.update(first)).isEmpty)
        #expect(machine.handle(.update(nil)).isEmpty)
        #expect(machine.state == .ineligible)
        #expect(machine.handle(.update(first)) == [.startAttempt(2, first)])
        machine = machine.after([.finished(2)])
        let replacement = ViewedDoneMachine.Target(
            agentID: first.agentID, terminalID: first.terminalID, transportGeneration: 2)
        #expect(machine.handle(.update(replacement)) == [.startAttempt(3, replacement)])
    }

    @Test func changedEligibilityCancelsDwellOrSendButKeepsTheSlotUntilReturn() {
        for sending in [false, true] {
            var machine = ViewedDoneMachine().after([.update(first)])
            if sending { _ = machine.handle(.dwellElapsed(1)) }
            #expect(machine.handle(.update(nil)) == [.cancelAttempt(1)])
            #expect(machine.state == .draining(attempt: 1, next: nil))
            #expect(machine.isInFlight)
            #expect(machine.handle(.update(nil)).isEmpty)
            #expect(machine.handle([.dwellElapsed(1), .failure(1)]).isEmpty)
            #expect(machine.handle(.finished(1)).isEmpty)
            #expect(machine.state == .ineligible)
            #expect(!machine.isInFlight)
        }
    }

    @Test func replacementWhileDrainingStartsOnlyTheNewestTarget() {
        let second = ViewedDoneMachine.Target(
            agentID: first.agentID, terminalID: "terminal-B", transportGeneration: 1)
        let latest = ViewedDoneMachine.Target(
            agentID: first.agentID, terminalID: "terminal-B", transportGeneration: 2)
        var machine = ViewedDoneMachine().after([.update(first), .dwellElapsed(1)])
        #expect(machine.handle(.update(second)) == [.cancelAttempt(1)])
        #expect(machine.handle(.update(second)).isEmpty)
        #expect(machine.handle(.update(latest)) == [.cancelAttempt(1)])
        #expect(machine.handle(.finished(99)).isEmpty)
        #expect(machine.state == .draining(attempt: 1, next: latest))
        #expect(machine.handle(.finished(1)) == [.startAttempt(2, latest)])
        #expect(machine.state == .dwelling(attempt: 2, latest))
        #expect(machine.handle(.finished(1)).isEmpty)
        #expect(machine.state == .dwelling(attempt: 2, latest))
    }

    @Test func leaveCancelsThePendingSuccessorAndReentryRearmsIt() {
        var machine = ViewedDoneMachine().after([.update(first), .leave, .update(first)])
        #expect(machine.handle(.leave) == [.cancelAttempt(1)])
        #expect(machine.handle(.leave) == [.cancelAttempt(1)])
        #expect(machine.state == .draining(attempt: 1, next: nil))
        #expect(machine.handle(.finished(1)).isEmpty)
        #expect(machine.handle(.update(first)) == [.startAttempt(2, first)])
        #expect(machine.handle(.finished(2)).isEmpty)
        #expect(machine.state == .attempted(first))
        #expect(machine.handle(.leave).isEmpty)
        #expect(machine.state == .ineligible)
        #expect(machine.handle(.leave).isEmpty)
    }

    @Test func staleOrOutOfPhaseCallbacksCannotSendReportOrReleaseTheSlot() {
        let setups: [[ViewedDoneMachine.Event]] = [
            [], [.update(first)], [.update(first), .dwellElapsed(1)],
            [.update(first), .leave], [.update(first), .finished(1)],
        ]
        for events in setups {
            var machine = ViewedDoneMachine().after(events)
            let before = machine.state
            #expect(machine.handle([.dwellElapsed(99), .failure(99), .finished(99)]).isEmpty)
            #expect(machine.state == before)
        }
        var sending = ViewedDoneMachine().after([.update(first), .dwellElapsed(1)])
        #expect(sending.handle(.dwellElapsed(1)).isEmpty)
        #expect(sending.state == .sending(attempt: 1, first))
        var dwelling = ViewedDoneMachine().after([.update(first)])
        #expect(dwelling.handle(.failure(1)) == [.reportFailure])
    }
}
