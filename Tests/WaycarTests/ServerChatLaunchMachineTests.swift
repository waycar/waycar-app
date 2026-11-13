import Testing

@testable import Waycar

@Suite("Server chat launch transitions")
struct ServerChatLaunchMachineTests {
    private let session = Agent(.fixture(paneID: "codex:session"))
    private let pane = Agent(.fixture(paneID: "tmux:%1"))

    @Test func sessionThenTerminalThenMarker() {
        var machine = ServerChatLaunchMachine()
        #expect(machine.handle(.begin) == [.startSession(1)])
        #expect(machine.handle(.begin).isEmpty)
        #expect(machine.handle(.sessionStarted(1, session)) == [.chooseTerminal(2, session)])
        #expect(machine.handle(.terminalChosen(2, .open(.tmux))) == [.openTerminal(3, session, .tmux)])
        #expect(machine.handle(.terminalOpened(3, pane)) == [.recordMarker(4, session, pane, .tmux)])
        #expect(machine.handle(.markerRecorded(4)).isEmpty)
        #expect(machine.state == .ready(session, .linked))
        #expect(machine.handle(.begin).isEmpty)
    }

    @Test func chatOnlyOrExistingTerminalNeedsNoNewPane() {
        let choosing = ServerChatLaunchMachine().after([.begin, .sessionStarted(1, session)])
        var existing = choosing
        #expect(existing.handle(.terminalChosen(2, .existing)).isEmpty)
        #expect(existing.state == .ready(session, .existing))
        var unavailable = choosing
        #expect(unavailable.handle(.terminalChosen(2, .unavailable)).isEmpty)
        #expect(unavailable.state == .ready(session, .unavailable))
    }

    @Test func onlyDefinitiveTerminalFailureBecomesChatOnly() {
        let opening = ServerChatLaunchMachine().after([
            .begin, .sessionStarted(1, session), .terminalChosen(2, .open(.herdr))
        ])
        var failed = opening
        #expect(failed.handle(.failed(3, .definitive)) == [.showTerminalFailure(session)])
        #expect(failed.state == .ready(session, .failed))
        var uncertain = opening
        #expect(uncertain.handle(.failed(3, .uncertain)).isEmpty)
        #expect(uncertain.state == .uncertain(session))
        var cancelled = opening
        #expect(cancelled.handle(.failed(3, .cancelled)).isEmpty)
        #expect(cancelled.state == .cancelled(session))
        let marking = opening.after([.terminalOpened(3, pane)])
        #expect(marking.after([.failed(4, .cancelled)]).state == .cancelled(session))
        #expect(marking.after([.failed(4, .uncertain)]).state == .uncertain(session))
        #expect(marking.after([.failed(4, .definitive)]).state == .ready(session, .failed))
    }

    @Test func nativeFailuresNeverOfferChatOnlyAndStaleStepsAreIgnored() {
        let starting = ServerChatLaunchMachine().after([.begin])
        #expect(starting.after([.failed(1, .definitive)]).state == .failed)
        #expect(starting.after([.failed(1, .uncertain)]).state == .uncertain(nil))
        #expect(starting.after([.failed(1, .cancelled)]).state == .cancelled(nil))
        var machine = starting.after([.sessionStarted(1, session), .terminalChosen(2, .open(.core))])
        #expect(machine.handle(.sessionStarted(1, pane)).isEmpty)
        #expect(machine.handle(.terminalOpened(2, pane)).isEmpty)
        #expect(machine.handle(.failed(2, .uncertain)).isEmpty)
        #expect(machine.handle(.markerRecorded(3)).isEmpty)
        #expect(machine.state == .openingTerminal(3, session, .core))
    }
}
