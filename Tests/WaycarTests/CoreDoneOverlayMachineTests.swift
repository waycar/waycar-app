import Testing

@testable import Waycar

/// `CoreDoneOverlayMachine`: what the user has seen of a herdr-core Done.
@Suite("herdr-core Done overlay machine")
struct CoreDoneOverlayMachineTests {
    private func done(_ address: String = "t1", turn: Int = 1, word: String = "done") -> CoreTerminal {
        CoreTerminal(
            address: address, argv: ["claude"], status: CoreStatus(state: word, app: "claude-code"),
            reported: true, turn: turn)
    }

    private func presented(_ machine: CoreDoneOverlayMachine, _ terminal: CoreTerminal) -> AgentStatus {
        CoreSnapshotBuilder.agentStatus(of: terminal, overlay: machine)
    }

    // MARK: focused

    @Test func focusingAReportedDoneRemembersItsTurnAndWord() {
        var machine = CoreDoneOverlayMachine()
        #expect(machine.handle(.focused(address: "t1", terminal: done(turn: 3))).isEmpty)
        #expect(machine.state.seen == ["t1": .init(turn: 3, word: "done")])
        #expect(presented(machine, done(turn: 3)) == .idle)
    }

    @Test func onlyAReportedDoneAtTheSameAddressIsRemembered() {
        var machine = CoreDoneOverlayMachine()
        let ignored: [CoreDoneOverlayMachine.Event] = [
            .focused(address: "t1", terminal: done(word: "working")),
            .focused(address: "t1", terminal: CoreTerminal(address: "t1")),
            .focused(address: "t1", terminal: nil),
            .focused(address: "t1", terminal: done("t2")),
            // Never reported: its `done` word means nothing.
            .focused(
                address: "t1",
                terminal: CoreTerminal(
                    address: "t1", status: CoreStatus(state: "done"), reported: false, turn: 1)),
        ]
        #expect(machine.handle(ignored).isEmpty)
        #expect(machine.state == CoreDoneOverlayMachine().state)
        #expect(presented(machine, done()) == .done)
    }

    @Test func focusingAgainMovesTheEntryToTheNewDone() {
        var machine = CoreDoneOverlayMachine().after([.focused(address: "t1", terminal: done(turn: 1))])
        _ = machine.handle(.focused(address: "t1", terminal: done(turn: 2)))
        #expect(presented(machine, done(turn: 2)) == .idle)
        #expect(presented(machine, done(turn: 1)) == .done)
    }

    // MARK: presentation

    @Test func aSeenDoneShowsIdleUntilItsWordOrTurnMoves() {
        let machine = CoreDoneOverlayMachine().after([.focused(address: "t1", terminal: done())])
        #expect(presented(machine, done()) == .idle)
        #expect(CoreSnapshotBuilder.rawStatus(of: done()) == .done)
        #expect(presented(machine, done(word: "working")) == .working)
        #expect(presented(machine, done(word: "blocked")) == .blocked)
        #expect(presented(machine, done(turn: 2)) == .done)
    }

    // MARK: recordMoved

    @Test func aRecordThatMovedPastItsSeenDonePresentsDoneOnce() {
        var machine = CoreDoneOverlayMachine().after([.focused(address: "t1", terminal: done(turn: 3))])
        #expect(machine.handle(.recordMoved(done(turn: 4))) == [.presentDone(address: "t1")])
        #expect(machine.state.seen.isEmpty)
        #expect(machine.handle(.recordMoved(done(turn: 5))).isEmpty)
    }

    @Test func aRecordStillCoveredOrNeverSeenChangesNothing() {
        var machine = CoreDoneOverlayMachine().after([.focused(address: "t1", terminal: done(turn: 3))])
        #expect(machine.handle(.recordMoved(done(turn: 3))).isEmpty)
        #expect(machine.handle(.recordMoved(done("t2", turn: 9))).isEmpty)
        #expect(machine.state.seen == ["t1": .init(turn: 3, word: "done")])
    }

    // MARK: inventoryChanged

    @Test func anInventoryChangeKeepsOnlyEntriesThatStillApply() {
        var machine = CoreDoneOverlayMachine().after([
            .focused(address: "t1", terminal: done("t1")),
            .focused(address: "t2", terminal: done("t2")),
            .focused(address: "t3", terminal: done("t3")),
        ])
        var finished = done("t3")
        finished.state = "finished"
        #expect(machine.handle(.inventoryChanged([done("t1"), done("t2", word: "blocked"), finished])).isEmpty)
        #expect(machine.state.seen.keys.sorted() == ["t1"])
    }

    @Test func aWordThatMovedAndCameBackShowsTheSameTurnDone() {
        var machine = CoreDoneOverlayMachine().after([.focused(address: "t1", terminal: done())])
        _ = machine.handle(.inventoryChanged([done()]))
        #expect(presented(machine, done()) == .idle)
        _ = machine.handle(.inventoryChanged([done(word: "blocked")]))
        #expect(presented(machine, done()) == .done)
    }

    @Test func anInventoryWithoutTheTerminalDropsIt() {
        var machine = CoreDoneOverlayMachine().after([.focused(address: "t1", terminal: done())])
        _ = machine.handle(.inventoryChanged([]))
        #expect(presented(machine, done()) == .done)
    }
}
