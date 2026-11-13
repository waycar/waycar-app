import Testing

@testable import Waycar

@Suite("Codex subscription machine")
struct CodexSubscriptionMachineTests {
    private typealias Machine = CodexSubscriptionMachine

    @Test func theFirstNeedResumesAndLaterNeedsWaitForIt() {
        var machine = Machine()
        #expect(machine.handle(.needed("t")) == [.resume("t", token: 1), .wait("t", token: 1)])
        #expect(machine.state["t"] == .resuming(token: 1) && machine.isTracked("t"))
        #expect(machine.handle(.needed("t")) == [.wait("t", token: 1)])
        #expect(machine.handle(.needed("u")) == [.resume("u", token: 2), .wait("u", token: 2)])
    }

    @Test func anAnswerSubscribesAndLaterNeedsDoNothing() {
        var machine = Machine().after([.needed("t")])
        #expect(machine.handle(.resumed("t", token: 1)) == [.forget("t")])
        #expect(machine.state["t"] == .subscribed && machine.isTracked("t"))
        #expect(machine.handle(.needed("t")).isEmpty)
        // A second waiter's answer for the same resume.
        #expect(machine.handle(.resumed("t", token: 1)) == [.forget("t")])
        #expect(machine.state["t"] == .subscribed)
    }

    @Test func aFailureLetsTheNextNeedResumeAgain() {
        var machine = Machine().after([.needed("t")])
        #expect(machine.handle(.resumeFailed("t", token: 1)) == [.forget("t")])
        #expect(machine.state["t"] == nil && !machine.isTracked("t"))
        #expect(machine.handle(.needed("t")) == [.resume("t", token: 2), .wait("t", token: 2)])
    }

    /// B-29: two waiters share resume 1; the first learns it failed and a
    /// retry starts resume 2 before the second waiter learns of it.
    @Test func aLateFailureOfAnOlderResumeKeepsTheRetryThatReplacedIt() {
        var machine = Machine().after([
            .needed("t"), .needed("t"), .resumeFailed("t", token: 1), .needed("t"),
        ])
        #expect(machine.state["t"] == .resuming(token: 2))
        #expect(machine.handle(.resumeFailed("t", token: 1)).isEmpty)
        #expect(machine.state["t"] == .resuming(token: 2) && machine.isTracked("t"))
        // A third need waits for the retry instead of sending another resume.
        #expect(machine.handle(.needed("t")) == [.wait("t", token: 2)])
    }

    @Test func aFailureForASubscribedOrUnknownThreadChangesNothing() {
        var machine = Machine().after([.needed("t"), .resumed("t", token: 1)])
        #expect(machine.handle(.resumeFailed("t", token: 1)).isEmpty)
        #expect(machine.state["t"] == .subscribed)
        #expect(machine.handle(.resumeFailed("u", token: 9)).isEmpty)
        #expect(machine.state["u"] == nil)
    }

    @Test func aStartedThreadIsSubscribed() {
        var machine = Machine()
        #expect(machine.handle(.started("t")).isEmpty)
        #expect(machine.state["t"] == .subscribed)
        #expect(machine.handle(.needed("t")).isEmpty)
    }

    @Test func closingUnsubscribesButLeavesAResumeInFlight() {
        var machine = Machine().after([.started("t"), .needed("u")])
        #expect(machine.handle(.closed("t")).isEmpty)
        #expect(machine.state["t"] == nil)
        #expect(machine.handle(.closed("u")).isEmpty)
        #expect(machine.state["u"] == .resuming(token: 1))
        #expect(machine.handle(.resumed("u", token: 1)) == [.forget("u")])
        #expect(machine.state["u"] == .subscribed)
    }
}
