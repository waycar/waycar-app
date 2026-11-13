import Testing

@testable import Waycar

@Suite("Codex call machine")
struct CodexCallMachineTests {
    private typealias Machine = CodexCallMachine
    private let one = CodexRPCID.string("one")
    private let two = CodexRPCID.string("two")

    @Test func aQueuedCallCommitsWhenItsWriteBegins() {
        var machine = Machine()
        #expect(machine.handle(.enqueued(one)).isEmpty)
        #expect(machine.phase(of: one) == .queued)
        #expect(machine.handle(.writeBegan(one)) == [.write(one)])
        #expect(machine.phase(of: one) == .committed)
    }

    @Test func anAnswerSettlesOnceWithoutWithdrawing() {
        var machine = Machine().after([.enqueued(one), .writeBegan(one)])
        #expect(machine.handle(.answered(one)) == [.settle(one, withdraw: false)])
        #expect(machine.phase(of: one) == nil)
        #expect(machine.handle(.answered(one)).isEmpty)
        #expect(machine.handle(.failed(one)).isEmpty)
    }

    @Test func aQueuedFailureWithdrawsItsSend() {
        var machine = Machine().after([.enqueued(one)])
        #expect(machine.handle(.failed(one)) == [.settle(one, withdraw: true)])
        // Its write never begins: the frame stays off the wire.
        #expect(machine.handle(.writeBegan(one)).isEmpty)
    }

    @Test func aCommittedFailureKeepsItsSend() {
        var machine = Machine().after([.enqueued(one), .writeBegan(one)])
        #expect(machine.handle(.failed(one)) == [.settle(one, withdraw: false)])
        #expect(machine.handle(.answered(one)).isEmpty)
    }

    @Test func unknownIdsAreIgnored() {
        var machine = Machine().after([.enqueued(one)])
        #expect(machine.handle(.writeBegan(two)).isEmpty)
        #expect(machine.handle(.answered(two)).isEmpty)
        #expect(machine.handle(.failed(two)).isEmpty)
        #expect(machine.phase(of: one) == .queued)
    }

    @Test func endingSettlesEveryCallByItsPhase() {
        var machine = Machine().after([.enqueued(one), .enqueued(two), .writeBegan(two)])
        let effects = machine.handle(.ended)
        #expect(effects.first == .stopReader && effects.last == .finishEvents)
        #expect(effects.count == 4)
        #expect(effects.contains(.settle(one, withdraw: true)) && effects.contains(.settle(two, withdraw: false)))
        #expect(machine.isEnded)
    }

    @Test func anEndedClientIgnoresEverything() {
        var machine = Machine().after([.ended])
        #expect(machine.handle(.enqueued(one)).isEmpty)
        #expect(machine.phase(of: one) == nil)
        #expect(machine.handle(.writeBegan(one)).isEmpty)
        #expect(machine.handle(.answered(one)).isEmpty)
        #expect(machine.handle(.failed(one)).isEmpty)
        #expect(machine.handle(.ended).isEmpty)
    }
}
