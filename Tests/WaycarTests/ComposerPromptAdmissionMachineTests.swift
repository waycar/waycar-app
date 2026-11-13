import Foundation
import Testing

@testable import Waycar

@Suite("Composer prompt admission machine")
struct ComposerPromptAdmissionMachineTests {
    private let now = ContinuousClock.now
    private func attempting(queued: Bool = false) -> ComposerPromptAdmissionMachine {
        ComposerPromptAdmissionMachine(retryDelay: .seconds(1), queued: queued)
            .after([.begin(now: now, budget: .seconds(5))])
    }
    private func registration(queued: Bool = false) -> ComposerPromptAdmissionMachine {
        attempting(queued: queued).after([.response(1, .registration(stillLaunching: true), now: now, blocked: false)])
    }
    private func input() -> ComposerPromptAdmissionMachine {
        attempting().after([.response(1, .inputHold(opensAt: now + .seconds(60)), now: now, blocked: false)])
    }

    @Test func beginsAndAcceptsOneAttempt() {
        var machine = ComposerPromptAdmissionMachine(retryDelay: .seconds(1), queued: false)
        #expect(machine.handle(.begin(now: now, budget: .seconds(5))) == [.attempt(1)])
        #expect(machine.state == .attempting(1, deadline: now + .seconds(5)))
        #expect(machine.handle(.response(1, .accepted, now: now, blocked: false)) == [])
        #expect(machine.state == .accepted)
        #expect(machine.handle(.begin(now: now, budget: .seconds(5))) == [])
    }

    @Test func registrationWaitsOnceThenAttemptsWithANewToken() {
        var machine = attempting()
        #expect(machine.handle(.response(1, .registration(stillLaunching: false), now: now, blocked: false)) == [.wait(2, after: .seconds(1))])
        #expect(machine.state == .waitingForRegistration(2, deadline: now + .seconds(5)))
        #expect(machine.handle(.retryElapsed(2, blocked: false, stillAddressed: true)) == [.attempt(3)])
        #expect(machine.state == .attempting(3, deadline: now + .seconds(5)))
    }

    @Test func queuedNotFoundIsNotALaunchButNotReadyStillWaits() {
        var machine = attempting(queued: true)
        #expect(machine.handle(.response(1, .registration(stillLaunching: false), now: now, blocked: false)) == [])
        #expect(machine.state == .refused(.response))
        machine = attempting(queued: true)
        #expect(machine.handle(.response(1, .registration(stillLaunching: true), now: now, blocked: false)) == [.wait(2, after: .seconds(1))])
    }

    @Test func inputGateExtendsTheDeadlineButRegistrationDoesNot() {
        var machine = attempting()
        #expect(machine.handle(.response(1, .inputHold(opensAt: now + .seconds(60)), now: now, blocked: false)) == [.wait(2, after: .seconds(1))])
        #expect(machine.state == .waitingForInput(2, deadline: now + .seconds(62)))
        #expect(machine.handle(.retryElapsed(2, blocked: false, stillAddressed: true)) == [.attempt(3)])
        #expect(machine.handle(.response(3, .registration(stillLaunching: true), now: now + .seconds(61), blocked: false)) == [])
        #expect(machine.state == .refused(.response)) // Strictly before, not at the deadline.
    }

    @Test(arguments: [false, true]) func blockedOrExpiredResponseNeverArmsARetry(input: Bool) {
        let response: ComposerPromptAdmissionMachine.Response = input ? .inputHold(opensAt: now) : .registration(stillLaunching: true)
        var machine = attempting()
        #expect(machine.handle(.response(1, response, now: now, blocked: true)) == [])
        #expect(machine.state == .refused(.blocked))
        machine = attempting()
        #expect(machine.handle(.response(1, response, now: now + .seconds(5), blocked: false)) == [])
        #expect(machine.state == .refused(.response))
    }

    @Test(arguments: [false, true]) func retryChecksBlockedBeforeIdentity(input: Bool) {
        var machine = input ? self.input() : registration()
        #expect(machine.handle(.retryElapsed(2, blocked: true, stillAddressed: false)) == [])
        #expect(machine.state == .refused(.blocked))
        machine = input ? self.input() : registration()
        #expect(machine.handle(.retryElapsed(2, blocked: false, stillAddressed: false)) == [])
        #expect(machine.state == .refused(.agentChanged))
    }

    @Test func refusalsAndCancellationAreTerminal() {
        var machine = attempting()
        #expect(machine.handle(.response(1, .refusal, now: now, blocked: false)) == [])
        #expect(machine.state == .refused(.response))
        for initial in [attempting(), registration(), input()] {
            var value = initial
            let token: UInt64 = initial.state == attempting().state ? 1 : 2
            #expect(value.handle(.cancelled(token)) == [])
            #expect(value.state == .cancelled)
            #expect(value.handle([.begin(now: now, budget: .seconds(5)), .retryElapsed(2, blocked: false, stillAddressed: true)]) == [])
        }
    }

    @Test func staleTokensAndEventsInTheWrongPhaseAreIgnored() {
        let events: [ComposerPromptAdmissionMachine.Event] = [
            .response(99, .accepted, now: now, blocked: false), .retryElapsed(99, blocked: false, stillAddressed: true), .cancelled(99),
        ]
        for initial in [attempting(), registration(), input()] {
            var machine = initial
            #expect(machine.handle(events) == [])
            #expect(machine.state == initial.state)
        }
        var machine = ComposerPromptAdmissionMachine(retryDelay: .seconds(1), queued: false)
        #expect(machine.handle(events) == [])
        machine = attempting().after([.response(1, .accepted, now: now, blocked: false)])
        #expect(machine.handle(events) == [])
    }
}
