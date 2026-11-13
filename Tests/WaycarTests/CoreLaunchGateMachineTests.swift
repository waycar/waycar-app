import Testing

@testable import Waycar

/// `CoreLaunchGateMachine`: a herdr-core launch's first prompt.
@Suite("herdr-core launch gate machine")
struct CoreLaunchGateMachineTests {
    private static let start = ContinuousClock.now
    private static let wait = Duration.seconds(5)

    private func launched(_ kind: String = "claude") -> CoreLaunchGateMachine {
        CoreLaunchGateMachine().after([.launched(address: "t1", kind: kind, at: Self.start)])
    }

    private func gate(_ kind: String = "claude") -> CoreLaunchGate {
        CoreLaunchGate(kind: kind, launchedAt: Self.start)
    }

    private func read(
        _ record: CoreTerminal?, kind: String = "claude", elapsed: Duration = .seconds(1)
    ) -> CoreLaunchGateMachine.Event {
        .recordRead(
            address: "t1", gate: gate(kind), record: record, elapsed: elapsed, unreportedWait: Self.wait)
    }

    private func screen(
        _ text: String, kind: String, elapsed: Duration = .seconds(6)
    ) -> CoreLaunchGateMachine.Event {
        .screenRead(address: "t1", gate: gate(kind), screen: text, elapsed: elapsed, unreportedWait: Self.wait)
    }

    private let silent = CoreTerminal(address: "t1", argv: ["claude"])
    private let reported = CoreTerminal(address: "t1", status: CoreStatus(state: "idle"), reported: true)

    @Test func anUnlaunchedAddressHasNoGate() {
        #expect(CoreLaunchGateMachine().gate(at: "t1") == nil)
    }

    @Test func aLaunchHoldsItsAddressWithItsKindAndTime() {
        let machine = launched("opencode")
        #expect(machine.gate(at: "t1") == CoreLaunchGate(kind: "opencode", launchedAt: Self.start))
        #expect(machine.gate(at: "t2") == nil)
    }

    @Test func aRelaunchReplacesTheGate() {
        let later = Self.start + .seconds(3)
        var machine = launched("claude")
        _ = machine.handle(.launched(address: "t1", kind: "codex", at: later))
        #expect(machine.gate(at: "t1") == CoreLaunchGate(kind: "codex", launchedAt: later))
    }

    @Test func aReportedRecordLetsThroughAndOpens() {
        var machine = launched()
        #expect(machine.handle(read(reported)) == [.letThrough])
        #expect(machine.gate(at: "t1") == nil)
    }

    @Test func aFinishedRecordLetsThroughSoThePromptFailsOnItsOwn() {
        var machine = launched()
        #expect(machine.handle(read(CoreTerminal(address: "t1", state: "finished"))) == [.letThrough])
        #expect(machine.gate(at: "t1") == nil)
    }

    @Test func aSilentOrUnlistedTerminalInsideTheWaitHolds() {
        var machine = launched()
        #expect(machine.handle(read(silent, elapsed: .seconds(4))) == [.hold])
        #expect(machine.handle(read(nil, elapsed: .seconds(1))) == [.hold])
        #expect(machine.gate(at: "t1") != nil)
    }

    @Test func aSilentTerminalPastTheWaitIsReadFirst() {
        var machine = launched()
        #expect(machine.handle(read(silent, elapsed: .seconds(5))) == [.readScreen])
        #expect(machine.gate(at: "t1") != nil)
    }

    @Test func aMarkerKindOpensOnlyWithItsInputOnScreen() {
        var machine = launched("opencode")
        #expect(machine.handle(screen("", kind: "opencode")) == [.hold])
        #expect(machine.gate(at: "t1") != nil)
        #expect(machine.handle(screen("opencode\n┃ Ask anything…\n", kind: "opencode")) == [.letThrough])
        #expect(machine.gate(at: "t1") == nil)
    }

    @Test func aKindWithoutAMarkerNeedsSomethingDrawnAndItsDelay() {
        var machine = launched("gemini")
        #expect(machine.handle(screen("   \n", kind: "gemini", elapsed: .seconds(6))) == [.hold])
        // gemini's own minimum delay is longer than the elapsed time here.
        #expect(machine.handle(screen("gemini ready", kind: "gemini", elapsed: .seconds(2))) == [.hold])
        #expect(machine.handle(screen("gemini ready", kind: "gemini", elapsed: .seconds(6))) == [.letThrough])
    }

    @Test func aCheckThatLetsThroughOpensEvenAGateReplacedWhileItRead() {
        // The kept race: the address is the same terminal either way.
        var machine = launched()
        _ = machine.handle(.launched(address: "t1", kind: "claude", at: Self.start + .seconds(2)))
        #expect(machine.handle(read(reported)) == [.letThrough])
        #expect(machine.gate(at: "t1") == nil)
    }

    @Test func aCheckOnAnAlreadyOpenedAddressStillDecidesFromItsRead() {
        var machine = launched()
        _ = machine.handle(read(reported))
        #expect(machine.handle(read(silent, elapsed: .seconds(1))) == [.hold])
        #expect(machine.gate(at: "t1") == nil)
    }
}
