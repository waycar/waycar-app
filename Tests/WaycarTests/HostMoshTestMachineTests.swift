import Testing

@testable import Waycar

@Suite("Host detail mosh machine")
struct HostMoshTestMachineTests {
    @Test func connectsThenProvesAndCanRetest() {
        var machine = HostMoshTestMachine()
        #expect(machine.handle(.test) == [.connect(1)])
        #expect(machine.support == .testing)
        #expect(machine.handle(.test).isEmpty)
        #expect(machine.handle(.connected(1)) == [.probe(1)])
        #expect(machine.handle(.completed(1, .available)).isEmpty)
        #expect(machine.support == .available)
        #expect(machine.handle(.ended(1)).isEmpty)
        #expect(machine.handle(.test) == [.connect(2)])
        #expect(machine.handle(.completed(1, .unavailable("old"))).isEmpty)
        #expect(machine.state == .connecting(2))
    }

    @Test func disableRetiresConnectingAndProbingWork() {
        let setups: [[HostMoshTestMachine.Event]] = [[.test], [.test, .connected(1)]]
        for setup in setups {
            var machine = HostMoshTestMachine().after(setup)
            #expect(machine.handle(.disabled).isEmpty)
            #expect(machine.state == .invalidated(1))
            #expect(machine.handle(.test).isEmpty)
            #expect(machine.handle(.connected(1)).isEmpty)
            #expect(machine.handle(.completed(1, .available)).isEmpty)
            #expect(machine.handle(.ended(99)).isEmpty)
            #expect(machine.state == .invalidated(1))
            #expect(machine.handle(.ended(1)).isEmpty)
            #expect(machine.support == .unavailable("The test was interrupted."))
        }
    }

    @Test func failuresAndInterruptionUseExistingPresentation() {
        var failed = HostMoshTestMachine().after([.test])
        _ = failed.handle(.completed(1, .unavailable("failure")))
        #expect(failed.support == .unavailable("failure"))
        var interrupted = HostMoshTestMachine().after([.test, .connected(1)])
        _ = interrupted.handle(.ended(1))
        #expect(interrupted.support == .unavailable("The test was interrupted."))
        var idle = HostMoshTestMachine()
        #expect(idle.handle([.disabled, .connected(1), .completed(1, .available), .ended(1)]).isEmpty)
        #expect(idle.state == .idle)
    }
}
