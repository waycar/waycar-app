import Testing

@testable import Waycar

@Suite("Codex active turn machine")
struct CodexActiveTurnMachineTests {
    private typealias Machine = CodexActiveTurnMachine

    @Test func anInactiveThreadHasNoTurnToRead() {
        var machine = Machine()
        #expect(machine.handle(.needed("t", active: false)) == [.use(nil)])
        #expect(machine.state.isEmpty)
    }

    @Test func anActiveThreadWithNoKnownTurnIsReadAndItsAnswerKnown() {
        var machine = Machine()
        #expect(machine.handle(.needed("t", active: true)) == [.lookUp(token: 1)])
        #expect(machine.handle(.lookedUp("t", token: 1, running: "run")) == [.use("run")])
        #expect(machine.state["t"]?.known == "run")
        #expect(machine.handle(.needed("t", active: true)) == [.use("run")])
    }

    @Test func aReadThatFindsNoRunningTurnKnowsNothing() {
        var machine = Machine().after([.needed("t", active: true)])
        #expect(machine.handle(.lookedUp("t", token: 1, running: nil)) == [.use(nil)])
        #expect(machine.state["t"]?.known == nil)
    }

    @Test func aTrackedStartIsKnownAndAnUntrackedOneIsNot() {
        var machine = Machine()
        #expect(machine.handle(.started("t", turn: "desk", tracked: false)).isEmpty)
        #expect(machine.state["t"] == nil)
        #expect(machine.handle(.started("t", turn: "run", tracked: true)).isEmpty)
        #expect(machine.handle(.needed("t", active: false)) == [.use("run")])
        // A tracked start without an id forgets the turn.
        #expect(machine.handle(.started("t", turn: nil, tracked: true)).isEmpty)
        #expect(machine.handle(.needed("t", active: false)) == [.use(nil)])
    }

    @Test func onlyTheKnownTurnsCompletionForgetsIt() {
        var machine = Machine().after([.started("t", turn: "run", tracked: true)])
        #expect(machine.handle(.completed("t", turn: "other")).isEmpty)
        #expect(machine.state["t"]?.known == "run")
        #expect(machine.handle(.completed("t", turn: "run")).isEmpty)
        #expect(machine.state["t"]?.known == nil)
    }

    @Test func endingForgetsTheKnownTurn() {
        var machine = Machine().after([.started("t", turn: "run", tracked: true)])
        #expect(machine.handle(.ended("t")).isEmpty)
        #expect(machine.handle(.needed("t", active: true)) == [.lookUp(token: 1)])
    }

    // MARK: Each read answers its own caller (review 177084)

    @Test func overlappingReadsEachAnswerWithTheirOwnResult() {
        var machine = Machine()
        #expect(machine.handle(.needed("t", active: true)) == [.lookUp(token: 1)])
        #expect(machine.handle(.needed("t", active: true)) == [.lookUp(token: 2)])
        #expect(machine.handle(.lookedUp("t", token: 1, running: "a")) == [.use("a")])
        // The first read's answer is no broadcast: the second keeps its own.
        #expect(machine.handle(.lookedUp("t", token: 2, running: nil)) == [.use(nil)])
        #expect(machine.state["t"]?.known == "a")
    }

    @Test func aLaterReadOfAnotherTurnReplacesTheKnownOne() {
        var machine = Machine().after([.needed("t", active: true), .needed("t", active: true)])
        _ = machine.handle(.lookedUp("t", token: 1, running: "a"))
        #expect(machine.handle(.lookedUp("t", token: 2, running: "b")) == [.use("b")])
        #expect(machine.state["t"]?.known == "b")
    }

    /// B-30: the thread went idle, or the read's turn completed, while it was out.
    @Test(arguments: [CodexActiveTurnMachine.Event.ended("t"), .completed("t", turn: "run")])
    func aReadAnsweredAfterItsTurnEndedNamesNoTurn(end: CodexActiveTurnMachine.Event) {
        var machine = Machine().after([.needed("t", active: true)])
        _ = machine.handle(end)
        #expect(machine.handle(.lookedUp("t", token: 1, running: "run")) == [.use(nil)])
        #expect(machine.handle(.needed("t", active: false)) == [.use(nil)])
    }

    @Test func anotherTurnsCompletionLeavesARunningReadItsAnswer() {
        var machine = Machine().after([.needed("t", active: true), .completed("t", turn: "old")])
        #expect(machine.handle(.lookedUp("t", token: 1, running: "run")) == [.use("run")])
    }

    @Test func aTrackedStartDuringAReadIsNewerThanItsAnswer() {
        var machine = Machine().after([.needed("t", active: true), .started("t", turn: "new", tracked: true)])
        #expect(machine.handle(.lookedUp("t", token: 1, running: "old")) == [.use("new")])
        #expect(machine.state["t"]?.known == "new")
    }

    @Test func theNewestBroadcastDuringAReadWins() {
        var started = Machine().after([.needed("t", active: true), .ended("t"),
                                       .started("t", turn: "new", tracked: true)])
        #expect(started.handle(.lookedUp("t", token: 1, running: "old")) == [.use("new")])
        var ended = Machine().after([.needed("t", active: true), .started("t", turn: "new", tracked: true),
                                     .ended("t")])
        #expect(ended.handle(.lookedUp("t", token: 1, running: "new")) == [.use(nil)])
        var completed = Machine().after([.needed("t", active: true), .started("t", turn: "new", tracked: true),
                                         .completed("t", turn: "new")])
        #expect(completed.handle(.lookedUp("t", token: 1, running: "new")) == [.use(nil)])
    }

    @Test func aStaleTokenNamesNoTurn() {
        var machine = Machine().after([.needed("t", active: true)])
        _ = machine.handle(.lookedUp("t", token: 1, running: "run"))
        #expect(machine.handle(.lookedUp("t", token: 1, running: "run")) == [.use(nil)])
    }

    /// Review 177084: with no read outstanding, forgetting a thread (closed,
    /// inactive, its turn completed) keeps nothing, as base removed it.
    @Test func aForgottenThreadWithNoReadOutstandingLeavesNoEntry() {
        var machine = Machine().after([.started("t", turn: "run", tracked: true)])
        _ = machine.handle(.ended("t"))
        #expect(machine.state["t"] == nil)
        _ = machine.handle(.started("t", turn: "next", tracked: true))
        _ = machine.handle(.completed("t", turn: "next"))
        #expect(machine.state["t"] == nil)
        _ = machine.handle(.completed("u", turn: nil))
        #expect(machine.state["u"] == nil)
        _ = machine.handle(.started("v", turn: nil, tracked: true))
        #expect(machine.state.isEmpty)
    }

    /// Review 177084 round 2: a read that threw releases its token, so the
    /// thread closing afterwards leaves no entry.
    @Test func aFailedReadIsReleasedAndAClosedThreadLeavesNoEntry() {
        var machine = Machine().after([.needed("t", active: true)])
        #expect(machine.handle(.lookupFailed("t", token: 1)).isEmpty)
        #expect(machine.state.isEmpty)
        // Closed while it was out, then it failed.
        machine = Machine().after([.needed("t", active: true), .needed("t", active: true), .ended("t")])
        _ = machine.handle(.lookupFailed("t", token: 1))
        #expect(machine.state["t"]?.reads == [2: .ended])
        _ = machine.handle(.lookupFailed("t", token: 2))
        #expect(machine.state.isEmpty)
        // A failed read leaves a known turn and other reads alone.
        machine = Machine().after([.started("u", turn: "run", tracked: true), .ended("u"),
                                   .needed("u", active: true), .needed("u", active: true)])
        _ = machine.handle(.lookupFailed("u", token: 1))
        #expect(machine.handle(.lookedUp("u", token: 2, running: "next")) == [.use("next")])
        #expect(machine.state["u"] == .init(known: "next", reads: [:]))
    }

    @Test func aClosedThreadKeepsItsFenceOnlyUntilItsReadAnswers() {
        var machine = Machine().after([.needed("t", active: true), .ended("t")])
        #expect(machine.state["t"]?.reads == [1: .ended])
        #expect(machine.handle(.lookedUp("t", token: 1, running: "run")) == [.use(nil)])
        #expect(machine.state.isEmpty)
        // A read that found nothing leaves nothing either.
        _ = machine.handle(.needed("u", active: true))
        _ = machine.handle(.lookedUp("u", token: 2, running: nil))
        #expect(machine.state.isEmpty)
    }
}
