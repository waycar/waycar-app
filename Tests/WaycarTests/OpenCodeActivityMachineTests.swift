import Testing

@testable import Waycar

@Suite("OpenCode activity machine")
struct OpenCodeActivityMachineTests {
    private typealias Machine = OpenCodeActivityMachine
    private typealias Times = OpenCodeActivityMachine.Times

    @Test func aReListReplacesEverythingWithTheServersTimes() {
        var machine = Machine().after([.listed("gone", Times())])
        #expect(machine.handle(.relisted([
            "run": Times(idle: 1, viewed: 1), "done": Times(idle: 200, viewed: 100),
            "seen": Times(idle: 100, viewed: 200), "new": Times(),
        ], running: ["run", "unlisted"])).isEmpty)
        #expect(machine.status("run", blocked: false) == .working && machine.isRunning("run"))
        #expect(machine.status("done", blocked: false) == .done)
        #expect(machine.status("seen", blocked: false) == .idle)
        #expect(machine.status("new", blocked: false) == .idle)
        #expect(machine.status("gone", blocked: false) == nil && machine.status("unlisted", blocked: false) == nil)
    }

    @Test func blockedWinsOverEverything() {
        let machine = Machine().after([.relisted(["a": Times(idle: 2, viewed: 1)], running: ["a"])])
        #expect(machine.status("a", blocked: true) == .blocked)
    }

    @Test func aStartPublishesOnceAndAnEndIsDoneUntilViewed() {
        var machine = Machine().after([.listed("a", Times(idle: 100, viewed: 100))])
        #expect(machine.handle(.started("a")) == [.publish])
        #expect(machine.handle(.started("a")).isEmpty)
        #expect(machine.handle(.ended("a", at: 500, reason: nil)) == [.publish])
        #expect(machine.status("a", blocked: false) == .done && !machine.isRunning("a"))
        #expect(machine.handle(.viewed("a", idle: 500)) == [.publish])
        #expect(machine.status("a", blocked: false) == .idle)
    }

    /// B-38: a rejected permission ends the turn with reason `shutdown` and
    /// OpenCode writes no `idle`, so there is no unseen result to show.
    @Test func aTurnEndedByARejectLeavesNoUnseenResult() {
        var machine = Machine().after([.listed("a", Times(idle: 100, viewed: 100)), .started("a")])
        #expect(machine.handle(.ended("a", at: 500, reason: "shutdown")) == [.publish])
        #expect(machine.state["a"] == .resting(Times(idle: 100, viewed: 100)))
        #expect(machine.status("a", blocked: false) == .idle)
        #expect(machine.handle(.viewRequested("a")).isEmpty)
        // An explicit interrupt writes its idle (reason `user`).
        _ = machine.handle(.started("a"))
        _ = machine.handle(.ended("a", at: 600, reason: "user"))
        #expect(machine.status("a", blocked: false) == .done)
    }

    @Test func anEarlierUnseenResultSurvivesAReject() {
        var machine = Machine().after([.listed("a", Times(idle: 200, viewed: 100)), .started("a")])
        _ = machine.handle(.ended("a", at: 500, reason: "shutdown"))
        #expect(machine.status("a", blocked: false) == .done)
        #expect(machine.handle(.viewRequested("a")) == [.postView(idle: 200)])
    }

    @Test func anEndWithoutAStartStillStampsItsTime() {
        var machine = Machine().after([.listed("a", Times())])
        #expect(machine.handle(.ended("a", at: 7, reason: nil)) == [.publish])
        #expect(machine.status("a", blocked: false) == .done)
    }

    @Test func unlistedSessionsIgnoreTurnEvents() {
        var machine = Machine()
        #expect(machine.handle(.started("x")).isEmpty)
        #expect(machine.handle(.ended("x", at: 1, reason: nil)).isEmpty)
        #expect(machine.handle(.viewed("x", idle: 1)).isEmpty)
        #expect(machine.state.isEmpty)
    }

    @Test func openingAnUnseenResultPostsItsIdleOnce() {
        var machine = Machine().after([.listed("a", Times(idle: 200, viewed: 100))])
        #expect(machine.handle(.viewRequested("a")) == [.postView(idle: 200)])
        #expect(machine.handle(.viewPosted("a", idle: 200)) == [.publish])
        #expect(machine.status("a", blocked: false) == .idle)
        #expect(machine.handle(.viewRequested("a")).isEmpty)
    }

    @Test func aViewEventDuringThePostWins() {
        var machine = Machine().after([.listed("a", Times(idle: 200, viewed: 100)), .viewed("a", idle: 300)])
        #expect(machine.handle(.viewPosted("a", idle: 200)).isEmpty)
        #expect(machine.state["a"] == .resting(Times(idle: 200, viewed: 300)))
    }

    @Test func aSessionGoneDuringThePostStillPublishes() {
        var machine = Machine().after([.listed("a", Times(idle: 200, viewed: 100)), .unlisted("a")])
        #expect(machine.handle(.viewPosted("a", idle: 200)) == [.publish])
        #expect(machine.state["a"] == nil)
    }

    @Test func aViewWhileWorkingKeepsItWorking() {
        var machine = Machine().after([.listed("a", Times(idle: 200, viewed: 100)), .started("a")])
        #expect(machine.handle(.viewed("a", idle: 200)) == [.publish])
        #expect(machine.state["a"] == .working(Times(idle: 200, viewed: 200)))
    }
}
