import Foundation
import Testing

@testable import Waycar

@Suite("Terminal input ownership machine")
struct TerminalInputOwnershipMachineTests {
    private typealias Machine = TerminalInputOwnershipMachine
    private let key = Machine.Input(data: Data("a".utf8), source: .keystroke)
    private let report = Machine.Input(data: Data("\u{1B}[I".utf8), source: .keystroke)

    @Test func detachedInputAndCompletionsAreIgnored() {
        let begun = Machine().after([.beginSession])
        var machine = Machine()
        #expect(machine.handle(.input(key, isTerminalReport: false, historyHoldsInput: true)).isEmpty)
        #expect(machine.handle(.historyLeft(begun.latestGeneration)).isEmpty)
        #expect(machine.handle(.endSession(begun.latestGeneration)).isEmpty)
        #expect(machine.liveGeneration == nil)
        #expect(machine.state == .detached)
    }

    @Test func everyBeginMintsANewGenerationAndOnlyItsEndDetaches() {
        var machine = Machine().after([.beginSession])
        let old = machine.latestGeneration
        #expect(machine.state == .live(old))
        #expect(machine.liveGeneration == old)
        #expect(machine.handle(.beginSession).isEmpty)
        let replacement = machine.latestGeneration
        #expect(replacement != old)
        #expect(machine.handle(.endSession(old)).isEmpty)
        #expect(machine.state == .live(replacement))
        #expect(machine.handle(.endSession(replacement)).isEmpty)
        #expect(machine.state == .detached)
        #expect(machine.liveGeneration == nil)
        #expect(machine.handle(.beginSession).isEmpty)
        #expect(machine.latestGeneration != replacement)
    }

    @Test func liveInputGoesStraightThroughUnlessHistoryHoldsIt() {
        var machine = Machine().after([.beginSession])
        let generation = machine.latestGeneration
        #expect(machine.handle(.input(key, isTerminalReport: false, historyHoldsInput: false)) == [.deliver(key)])
        #expect(machine.handle(.input(report, isTerminalReport: true, historyHoldsInput: true)) == [.deliver(report)])
        #expect(machine.handle(.historyLeft(generation)).isEmpty)
        #expect(machine.state == .live(generation))
    }

    @Test func oneLeaveHoldsAllUserInputUntilItsMatchingCompletion() {
        var machine = Machine().after([.beginSession])
        let generation = machine.latestGeneration
        #expect(machine.handle(.input(key, isTerminalReport: false, historyHoldsInput: true)) == [
            .hold(key), .leaveHistory(generation),
        ])
        #expect(machine.state == .releasingHeldInput(generation))
        #expect(machine.liveGeneration == generation)
        // History can already read live while the leave's completion is queued.
        #expect(machine.handle(.input(key, isTerminalReport: false, historyHoldsInput: false)) == [.hold(key)])
        #expect(machine.handle(.input(report, isTerminalReport: true, historyHoldsInput: true)) == [.deliver(report)])
        #expect(machine.state == .releasingHeldInput(generation))
        #expect(machine.handle(.historyLeft(generation)) == [.releaseHeldInput])
        #expect(machine.state == .live(generation))
        #expect(machine.handle(.historyLeft(generation)).isEmpty)
    }

    @Test func anOldLeaveCannotFlushTheReplacementHold() {
        var machine = Machine().after([.beginSession])
        let old = machine.latestGeneration
        _ = machine.handle(.input(key, isTerminalReport: false, historyHoldsInput: true))
        #expect(machine.handle(.detachSession).isEmpty)
        #expect(machine.state == .detached)
        #expect(machine.handle(.historyLeft(old)).isEmpty)
        _ = machine.handle(.beginSession)
        let replacement = machine.latestGeneration
        _ = machine.handle(.input(key, isTerminalReport: false, historyHoldsInput: true))
        #expect(machine.handle(.historyLeft(old)).isEmpty)
        #expect(machine.handle(.endSession(old)).isEmpty)
        #expect(machine.state == .releasingHeldInput(replacement))
        #expect(machine.handle(.historyLeft(replacement)) == [.releaseHeldInput])
    }

    @Test func endingOrReplacingAHoldDropsItsCompletion() {
        var machine = Machine().after([.beginSession])
        let old = machine.latestGeneration
        _ = machine.handle(.input(key, isTerminalReport: false, historyHoldsInput: true))
        _ = machine.handle(.endSession(old))
        #expect(machine.state == .detached)
        #expect(machine.handle(.historyLeft(old)).isEmpty)
        _ = machine.handle(.beginSession)
        let next = machine.latestGeneration
        _ = machine.handle(.input(key, isTerminalReport: false, historyHoldsInput: true))
        _ = machine.handle(.beginSession)
        #expect(machine.state == .live(machine.latestGeneration))
        #expect(machine.handle(.historyLeft(next)).isEmpty)
        #expect(machine.handle(.detachSession).isEmpty)
        #expect(machine.handle(.detachSession).isEmpty)
        #expect(machine.state == .detached)
    }
}
