import Testing

@testable import Waycar

@Suite("Message jump session machine")
struct MessageJumpSessionMachineTests {
    private typealias Machine = MessageJumpSessionMachine
    private let older = AttachRunningJump(kind: .message, direction: .older)
    private let newer = AttachRunningJump(kind: .message, direction: .newer)
    private let snapshot = HarnessJumpCaptures.transcript(
        kind: "pi", messages: [("turn", .user, "Explain the parser changes")])

    @Test func aJumpRunsOnlyAfterItsEntryCheck() {
        var machine = Machine(jumpUsesTranscript: false)
        #expect(machine.handle(.jumpRequested) == [.startJump(epoch: 1, generation: 0)])
        #expect(machine.hasJumpTask)
        #expect(machine.runningJump == nil)
        #expect(machine.handle(.jumpEntered(epoch: 1, generation: 0, taskCancelled: false, older)) == [
            .publishRunning(older), .runBody,
        ])
        #expect(machine.runningJump == older)
        #expect(machine.handle(.jumpEnded(epoch: 1)) == [.clearJumpTask, .publishRunning(nil)])
        #expect(!machine.hasJumpTask)
    }

    @Test func aCancelledStaleOrResetJumpNeverEnters() {
        var machine = Machine(jumpUsesTranscript: false).after([.jumpRequested])
        #expect(machine.handle(.jumpEntered(epoch: 1, generation: 0, taskCancelled: true, older)).isEmpty)
        _ = machine.handle(.jumpRequested)
        #expect(machine.handle(.jumpEntered(epoch: 1, generation: 0, taskCancelled: false, older)).isEmpty)
        _ = machine.handle(.reset)
        #expect(machine.handle(.jumpEntered(epoch: 2, generation: 0, taskCancelled: false, older)).isEmpty)
        #expect(machine.runningJump == nil)
    }

    @Test func onlyTheLatestJumpsEndClearsTheRunningOne() {
        var machine = Machine(jumpUsesTranscript: false).after([
            .jumpRequested, .jumpEntered(epoch: 1, generation: 0, taskCancelled: false, older),
            .jumpRequested, .jumpEntered(epoch: 2, generation: 0, taskCancelled: false, newer),
        ])
        #expect(machine.handle(.jumpEnded(epoch: 1)).isEmpty)
        #expect(machine.runningJump == newer)
        #expect(machine.handle(.jumpEnded(epoch: 2)) == [.clearJumpTask, .publishRunning(nil)])
    }

    @Test func aJumpThatFailedItsEntryStillEndsAsTheLatest() {
        var machine = Machine(jumpUsesTranscript: false).after([
            .jumpRequested, .jumpEntered(epoch: 1, generation: 0, taskCancelled: true, older),
        ])
        #expect(machine.handle(.jumpEnded(epoch: 1)) == [.clearJumpTask, .publishRunning(nil)])
    }

    @Test func refreshesCoalesceBehindTheReadInFlight() {
        var machine = Machine(jumpUsesTranscript: false)
        #expect(machine.handle(.refreshRequested) == [.startRead(1)])
        #expect(machine.handle(.refreshRequested).isEmpty)
        #expect(machine.handle(.refreshRequested).isEmpty)
        #expect(machine.handle(.readFinished(1, snapshot)) == [
            .clearRead, .deliverTranscript(snapshot), .startRead(2),
        ])
        #expect(machine.handle(.readFinished(2, nil)) == [.clearRead])
        #expect(machine.state.read == .idle)
    }

    @Test func aTranscriptJumpIndexesAtOnceWhileNoWalkRuns() {
        var machine = Machine(jumpUsesTranscript: true).after([.refreshRequested])
        #expect(machine.handle(.readFinished(1, snapshot)) == [
            .clearRead, .indexTranscript(snapshot), .deliverTranscript(snapshot),
        ])
    }

    @Test func aReadDuringAWalkIsHeldUntilTheWalkEnds() {
        var machine = Machine(jumpUsesTranscript: true).after([
            .jumpRequested, .jumpEntered(epoch: 1, generation: 0, taskCancelled: false, older),
            .refreshRequested,
        ])
        #expect(machine.handle(.readFinished(1, snapshot)) == [.clearRead, .deliverTranscript(snapshot)])
        #expect(machine.state.held == snapshot)
        #expect(machine.handle(.jumpEnded(epoch: 1)) == [
            .clearJumpTask, .publishRunning(nil), .indexTranscript(snapshot),
        ])
        #expect(machine.state.held == nil)
    }

    @Test func aResetDropsTheReadItsRereadTheHeldSnapshotAndTheJump() {
        var machine = Machine(jumpUsesTranscript: true).after([
            .jumpRequested, .jumpEntered(epoch: 1, generation: 0, taskCancelled: false, older),
            .refreshRequested, .readFinished(1, snapshot), .refreshRequested, .refreshRequested,
        ])
        #expect(machine.handle(.reset) == [
            .cancelJumpTask, .publishGeneration(1), .publishRunning(nil),
            .resetSessionState, .cancelRead, .resetIndex,
        ])
        #expect(machine.state.held == nil)
        #expect(machine.handle(.readFinished(2, snapshot)).isEmpty)
        #expect(machine.handle(.jumpEnded(epoch: 1)).isEmpty)
        #expect(machine.handle(.refreshRequested) == [.startRead(3)])
        #expect(machine.handle(.jumpRequested) == [.startJump(epoch: 3, generation: 1)])
    }
}
