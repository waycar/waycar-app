import Testing

@testable import Waycar

@Suite("Host form mosh machine")
struct HostFormMoshTestMachineTests {
    private var draft: HostDraft { HostDraft(host: .fixture()) }

    @Test func detectionConnectionAndRealProofAreOrdered() {
        let target = HostFormMoshTestMachine.Target(draft)
        var machine = HostFormMoshTestMachine()
        #expect(machine.handle(.test(target)) == [.detect(1)])
        #expect(machine.result == .testing)
        #expect(machine.handle(.test(target)).isEmpty)
        #expect(machine.handle(.connected(1)).isEmpty)
        #expect(machine.handle(.detected(99)).isEmpty)
        #expect(machine.handle(.detected(1)) == [.connect(1)])
        #expect(machine.handle(.connected(1)) == [.probe(1)])
        #expect(machine.handle(.completed(1, .available)).isEmpty)
        #expect(machine.result == .available)
        #expect(machine.handle(.ended(1)).isEmpty)
        #expect(machine.handle(.test(target)) == [.detect(2)])
        #expect(machine.handle(.completed(1, .unavailable)).isEmpty)
        #expect(machine.state == .detecting(2, target))
    }

    @Test func changingAddressDropsFinishedAndInFlightResults() {
        let target = HostFormMoshTestMachine.Target(draft)
        var edited = draft
        edited.address = "other.example"
        let newTarget = HostFormMoshTestMachine.Target(edited)
        let setups: [[HostFormMoshTestMachine.Event]] = [
            [.test(target)], [.test(target), .detected(1)],
            [.test(target), .detected(1), .connected(1)],
            [.test(target), .completed(1, .available)],
        ]
        for setup in setups {
            var machine = HostFormMoshTestMachine().after(setup)
            #expect(machine.handle(.draftChanged(newTarget)).isEmpty)
            #expect(machine.state == .idle)
            #expect(machine.handle([.detected(1), .connected(1), .completed(1, .available), .ended(1)]).isEmpty)
            #expect(machine.handle(.test(newTarget)) == [.detect(2)])
            #expect(machine.handle(.ended(1)).isEmpty)
            #expect(machine.result == .testing)
        }
    }

    @Test func cosmeticEditsKeepResultsButConnectionEditsDoNot() {
        let target = HostFormMoshTestMachine.Target(draft)
        var machine = HostFormMoshTestMachine().after([.test(target), .completed(1, .unavailable)])
        var edited = draft
        edited.name = "Renamed"
        _ = machine.handle(.draftChanged(.init(edited)))
        #expect(machine.result == .unavailable)
        edited.jumpAddress = "jump.example"
        _ = machine.handle(.draftChanged(.init(edited)))
        #expect(machine.result == .idle)
    }

    @Test func interruptionAndValidationFailuresKeepExistingCopy() {
        let target = HostFormMoshTestMachine.Target(draft)
        var machine = HostFormMoshTestMachine().after([.test(target), .ended(1)])
        #expect(machine.result == .couldNotConnect("The test was interrupted."))
        _ = machine.handle([.test(target), .completed(2, .couldNotConnect("incomplete"))])
        #expect(machine.result == .couldNotConnect("incomplete"))
    }
}
