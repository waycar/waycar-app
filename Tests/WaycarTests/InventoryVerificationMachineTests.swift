import Testing

@testable import Waycar

@Suite("Inventory verification transitions")
struct InventoryVerificationMachineTests {
    @Test(arguments: [
        InventoryVerificationMachine.Patience.failsFast, .ridesOutRecovery, .failsFastOffline,
    ])
    func boundedWaitArmsOneTimeoutAndSettlesOnce(
        _ patience: InventoryVerificationMachine.Patience
    ) {
        var machine = InventoryVerificationMachine()
        #expect(machine.handle(.begin(patience)) == [.armTimeout(1)])
        #expect(machine.state == .waiting(token: 1, patience: patience))
        #expect(machine.handle(.begin(.waitsOutFailure)).isEmpty)
        #expect(machine.handle(.timedOut(2)).isEmpty)
        #expect(machine.handle(.resolved(2)).isEmpty)
        #expect(machine.handle(.resolved(1)) == [.settle])
        #expect(machine.state == .finished)
        #expect(machine.handle([.timedOut(1), .cancel, .resolved(1), .begin(patience)]).isEmpty)
    }

    @Test func attachHasNoTimeoutEvenWhenAForeignTimerReturns() {
        var machine = InventoryVerificationMachine().after([.begin(.waitsOutFailure)])
        #expect(machine.patience == .waitsOutFailure)
        #expect(machine.token == 1)
        #expect(machine.handle(.timedOut(1)).isEmpty)
        #expect(machine.handle(.resolved(1)) == [.settle])
        #expect(machine.patience == nil)
        #expect(machine.token == nil)
    }

    @Test func timeoutAndCancellationCompeteForOneSettlement() {
        var timeout = InventoryVerificationMachine().after([.begin(.ridesOutRecovery)])
        #expect(timeout.handle(.timedOut(1)) == [.settle])
        #expect(timeout.handle(.cancel).isEmpty)
        var cancelled = InventoryVerificationMachine().after([.begin(.waitsOutFailure)])
        #expect(cancelled.handle(.cancel) == [.settle])
        #expect(cancelled.handle([.resolved(1), .timedOut(1), .cancel]).isEmpty)
    }

    @Test func nothingCanSettleBeforeRegistration() {
        var machine = InventoryVerificationMachine()
        #expect(machine.handle([.resolved(1), .timedOut(1), .cancel]).isEmpty)
        #expect(machine.state == .idle)
        #expect(machine.handle(.begin(.waitsOutFailure)).isEmpty)
        #expect(machine.state == .waiting(token: 1, patience: .waitsOutFailure))
    }
}
