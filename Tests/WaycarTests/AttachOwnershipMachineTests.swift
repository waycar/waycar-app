import Testing

@testable import Waycar

/// `AttachOwnershipMachine`: which herdr Attach targets one Transport owns,
/// and whether it still takes Attaches.
@Suite("herdr attach ownership machine")
struct AttachOwnershipMachineTests {
    typealias Machine = AttachOwnershipMachine

    private let pane = TerminalAttachTarget.agentPane("w1:p1")
    private let terminal = TerminalAttachTarget.terminal("t1")

    // MARK: Opening

    @Test func aFreeTargetOpensUnderANewReader() {
        var machine = Machine()
        #expect(machine.handle(.attachRequested(pane)) == [.open(reader: 1)])
        #expect(machine[pane] == .opening(reader: 1, endedEarly: false))
        #expect(machine.handle(.attachRequested(terminal)) == [.open(reader: 2)])
    }

    @Test func aTakenTargetIsRefusedWhileOpeningOrLive() {
        var machine = Machine().after([.attachRequested(pane)])
        #expect(machine.handle(.attachRequested(pane)) == [.refuse(.terminalChannelAlreadyOpen)])
        _ = machine.handle(.opened(pane, reader: 1))
        #expect(machine.handle(.attachRequested(pane)) == [.refuse(.terminalChannelAlreadyOpen)])
    }

    @Test func anOpenedChannelIsRecordedLive() {
        var machine = Machine().after([.attachRequested(pane)])
        #expect(machine.handle(.opened(pane, reader: 1)) == [.keep(reader: 1)])
        #expect(machine[pane] == .live(reader: 1))
    }

    @Test func aFailedOpenFreesTheTarget() {
        var machine = Machine().after([.attachRequested(pane)])
        #expect(machine.handle(.openFailed(pane, reader: 1)).isEmpty)
        #expect(machine[pane] == nil)
        #expect(machine.handle(.attachRequested(pane)) == [.open(reader: 2)])
    }

    // MARK: Channel end

    @Test func aLiveChannelsEndFreesTheTarget() {
        var machine = Machine().after([.attachRequested(pane), .opened(pane, reader: 1)])
        #expect(machine.handle(.channelEnded(pane, reader: 1)) == [.forget(reader: 1)])
        #expect(machine[pane] == nil)
    }

    @Test func aChannelEndingBeforeItsOpenIsRecordedFreesTheTargetAtTheOpen() {
        var machine = Machine().after([.attachRequested(pane)])
        #expect(machine.handle(.channelEnded(pane, reader: 1)) == [.forget(reader: 1)])
        #expect(machine[pane] == .opening(reader: 1, endedEarly: true))
        // Nothing is recorded for the dead channel.
        #expect(machine.handle(.opened(pane, reader: 1)).isEmpty)
        #expect(machine[pane] == nil)
    }

    @Test func anotherReadersEndLeavesTheTarget() {
        var machine = Machine().after([
            .attachRequested(pane), .opened(pane, reader: 1), .channelEnded(pane, reader: 1),
            .attachRequested(pane),
        ])
        #expect(machine.handle(.channelEnded(pane, reader: 1)) == [.forget(reader: 1)])
        #expect(machine[pane] == .opening(reader: 2, endedEarly: false))
        #expect(machine.handle(.opened(pane, reader: 1)).isEmpty)
        #expect(machine.handle(.openFailed(pane, reader: 1)).isEmpty)
        #expect(machine[pane] == .opening(reader: 2, endedEarly: false))
    }

    // MARK: Close

    @Test func closingTakesTheLiveAttachesAndRefusesNewOnes() {
        var machine = Machine().after([
            .attachRequested(pane), .opened(pane, reader: 1), .attachRequested(terminal),
        ])
        #expect(!machine.isClosed)
        #expect(machine.handle(.closeRequested) == [.takeLiveAttaches])
        #expect(machine.isClosed)
        #expect(machine.state.owner == .closing)
        #expect(machine[pane] == .closing(reader: 1))
        #expect(
            machine.handle(.attachRequested(.agentPane("w2:p1")))
                == [.refuse(Machine.closedError)])
        #expect(machine.handle(.closeFinished).isEmpty)
        #expect(machine.state.owner == .closed)
        #expect(machine.handle(.attachRequested(pane)) == [.refuse(Machine.closedError)])
    }

    @Test func aClosedTransportRefusesBeforeTheAlreadyOpenCheck() {
        var machine = Machine().after([
            .attachRequested(pane), .opened(pane, reader: 1), .closeRequested,
        ])
        #expect(machine.handle(.attachRequested(pane)) == [.refuse(Machine.closedError)])
        #expect(
            Machine.closedError
                == TransportError.sshUnreachable(detail: "the SSH connection is closed"))
    }

    @Test func anEndedAttachFreesItsTargetAfterTheClose() {
        var machine = Machine().after([
            .attachRequested(pane), .opened(pane, reader: 1), .closeRequested, .closeFinished,
        ])
        #expect(machine.handle(.channelEnded(pane, reader: 1)) == [.forget(reader: 1)])
        #expect(machine[pane] == nil)
    }

    @Test func anOpeningThatCompletesAfterTheCloseIsStillRecorded() {
        // Kept as it was: close takes only the Attaches already live.
        var machine = Machine().after([.attachRequested(pane), .closeRequested])
        #expect(machine.handle(.opened(pane, reader: 1)) == [.keep(reader: 1)])
        #expect(machine[pane] == .live(reader: 1))
    }

    @Test func aRepeatedCloseDoesNothing() {
        var machine = Machine().after([.closeRequested])
        #expect(machine.handle(.closeRequested).isEmpty)
        _ = machine.handle(.closeFinished)
        #expect(machine.handle(.closeRequested).isEmpty)
        #expect(machine.handle(.closeFinished).isEmpty)
        #expect(machine.state.owner == .closed)
    }
}
