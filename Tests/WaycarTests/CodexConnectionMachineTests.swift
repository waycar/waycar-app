import Testing

@testable import Waycar

@Suite("Codex connection machine")
struct CodexConnectionMachineTests {
    private typealias Machine = CodexConnectionMachine

    @Test func anOpenConnectionAdmitsEverything() {
        let machine = Machine()
        #expect(machine.isLive && machine.refusal == nil && machine.releasesOnDeinit)
    }

    @Test func anEndedConnectionIsLostOnce() {
        var machine = Machine()
        #expect(machine.handle(.connectionEnded) == [.failEvents])
        #expect(machine.state == .lost && !machine.isLive)
        #expect(machine.refusal == Machine.ended)
        #expect(machine.handle(.connectionEnded).isEmpty)
        #expect(machine.releasesOnDeinit)
    }

    @Test(arguments: [[], [CodexConnectionMachine.Event.connectionEnded], [.distrust]])
    func closeReleasesOnceFromAnyLiveOrEndedState(before: [CodexConnectionMachine.Event]) {
        var machine = Machine().after(before)
        #expect(machine.handle(.close) == [.stopReader, .cancelResumes, .endEvents, .closeRPC, .release])
        #expect(machine.state == .closed && machine.refusal == .cancelled && !machine.releasesOnDeinit)
        #expect(machine.handle(.close).isEmpty)
        #expect(machine.handle(.connectionEnded).isEmpty)
    }

    @Test(arguments: [[], [CodexConnectionMachine.Event.connectionEnded], [.distrust]])
    func distrustKeepsTheHold(before: [CodexConnectionMachine.Event]) {
        var machine = Machine().after(before)
        #expect(machine.handle(.distrust) == [.stopReader, .endEvents, .closeRPC])
        #expect(machine.state == .distrusted && machine.refusal == .cancelled)
        #expect(machine.releasesOnDeinit)
        #expect(machine.handle(.connectionEnded).isEmpty)
    }

    @Test func distrustAfterCloseStaysClosed() {
        var machine = Machine().after([.close])
        #expect(machine.handle(.distrust) == [.stopReader, .endEvents, .closeRPC])
        #expect(machine.state == .closed && !machine.releasesOnDeinit)
    }

    @Test func aFailedOpenIsAbandonedWithoutRelease() {
        var machine = Machine()
        #expect(machine.handle(.abandon) == [.closeRPC])
        #expect(machine.state == .closed && !machine.releasesOnDeinit)
        #expect(machine.handle(.close).isEmpty)
    }
}
