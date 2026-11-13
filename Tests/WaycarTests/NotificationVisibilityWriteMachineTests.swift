import Testing

@testable import Waycar

@Suite("Notification visibility write transitions")
struct NotificationVisibilityWriteMachineTests {
    @Test func everyFlagWaitsForTheImmediatelyPrecedingWrite() {
        var machine = NotificationVisibilityWriteMachine()
        #expect(machine.handle(.enqueue(.tmux(false))) == [.enqueue(1, after: nil, .tmux(false))])
        #expect(machine.handle(.enqueue(.core(true))) == [.enqueue(2, after: 1, .core(true))])
        #expect(machine.handle(.enqueue(.tmux(true))) == [.enqueue(3, after: 2, .tmux(true))])
        #expect(machine.handle(.finished(2, succeeded: true)).isEmpty)
        #expect(machine.handle(.finished(1, succeeded: false)) == [.release(1)])
        #expect(machine.state == .writing(tokens: [2, 3], coreDefault: .needed))
        #expect(machine.handle(.finished(2, succeeded: true)) == [.release(2)])
        #expect(machine.handle(.finished(3, succeeded: true)) == [.release(3)])
        #expect(machine.state == .idle(.needed))
        #expect(machine.handle(.finished(3, succeeded: false)).isEmpty)
    }

    @Test func zellijQueuesFIFOAfterPendingTmuxWithoutClaimingCoreDefault() {
        var machine = NotificationVisibilityWriteMachine()
        #expect(machine.handle(.enqueue(.tmux(false))) == [.enqueue(1, after: nil, .tmux(false))])
        #expect(machine.handle(.enqueue(.zellij(false))) == [.enqueue(2, after: 1, .zellij(false))])
        #expect(machine.handle(.finished(2, succeeded: true)).isEmpty)
        #expect(machine.handle(.finished(1, succeeded: true)) == [.release(1)])
        #expect(machine.state == .writing(tokens: [2], coreDefault: .needed))
        #expect(machine.handle(.finished(2, succeeded: true)) == [.release(2)])
        #expect(machine.state == .idle(.needed))
    }

    @Test func defaultIsClaimedWhileQueuedAndAfterSuccess() {
        var machine = NotificationVisibilityWriteMachine().after([.enqueue(.tmux(false))])
        #expect(machine.handle(.enqueue(.coreDefault)) == [.enqueue(2, after: 1, .coreDefault)])
        #expect(machine.handle(.enqueue(.coreDefault)).isEmpty)
        #expect(machine.handle(.finished(1, succeeded: true)) == [.release(1)])
        #expect(machine.handle(.finished(2, succeeded: true)) == [.release(2)])
        #expect(machine.state == .idle(.settled))
        #expect(machine.handle(.enqueue(.coreDefault)).isEmpty)
        #expect(machine.handle(.enqueue(.core(false))) == [.enqueue(3, after: nil, .core(false))])
        #expect(machine.handle(.finished(3, succeeded: false)) == [.release(3)])
        #expect(machine.state == .idle(.settled))
    }

    @Test func failedDefaultBecomesEligibleWithoutReplayingExplicitWrites() {
        var machine = NotificationVisibilityWriteMachine()
        #expect(machine.handle(.enqueue(.coreDefault)) == [.enqueue(1, after: nil, .coreDefault)])
        #expect(machine.handle(.enqueue(.core(false))) == [.enqueue(2, after: 1, .core(false))])
        #expect(machine.handle(.finished(1, succeeded: false)) == [.release(1)])
        #expect(machine.handle(.enqueue(.coreDefault)) == [.enqueue(3, after: 2, .coreDefault)])
        #expect(machine.handle(.finished(1, succeeded: true)).isEmpty)
        #expect(machine.handle(.finished(2, succeeded: true)) == [.release(2)])
        #expect(machine.handle(.finished(3, succeeded: true)) == [.release(3)])
        #expect(machine.state == .idle(.settled))
    }

    @Test func completionWithoutAWriteIsIgnored() {
        var machine = NotificationVisibilityWriteMachine()
        #expect(machine.handle(.finished(1, succeeded: true)).isEmpty)
        #expect(machine.state == .idle(.needed))
        #expect(machine.handle(.enqueue(.core(true))) == [.enqueue(1, after: nil, .core(true))])
    }
}
