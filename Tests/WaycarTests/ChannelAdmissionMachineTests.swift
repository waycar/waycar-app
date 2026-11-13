import Testing

@testable import Waycar

@Suite("Channel admission machine")
struct ChannelAdmissionMachineTests {
    private typealias Machine = ChannelAdmissionMachine

    /// One slot per class, two on the connection.
    private static let small = SSHChannelAdmission.Limits(
        ordinaryForwarding: 1, events: 1, ordinarySession: 1, attach: 1, connection: 2)

    private func makeMachine(_ limits: SSHChannelAdmission.Limits = small) -> Machine {
        Machine(limits: limits)
    }

    private func ask(
        _ id: UInt64, _ channelClass: SSHChannelAdmission.ChannelClass,
        deadline: Duration? = nil
    ) -> [Machine.Event] {
        [.requested(id: id), .register(id: id, channelClass, deadline: deadline)]
    }

    @Test func aRequestWithRoomIsGrantedAtOnce() {
        var machine = makeMachine()
        #expect(machine.handle(ask(1, .attach)) == [.grant(id: 1)])
        #expect(machine.state.counts.attach == 1)
        #expect(machine.state.counts.connection == 1)
        #expect(machine.state.waiters.isEmpty)
    }

    @Test func anImmediateGrantArmsNoDeadline() {
        var machine = makeMachine()
        #expect(machine.handle(ask(1, .attach, deadline: .seconds(1))) == [.grant(id: 1)])
    }

    @Test func aFullClassParksAndArmsItsDeadline() {
        var machine = makeMachine().after(ask(1, .attach))
        #expect(machine.handle(ask(2, .attach, deadline: .seconds(3)))
            == [.armDeadline(id: 2, after: .seconds(3))])
        #expect(machine.state.waiters == [.init(id: 2, channelClass: .attach)])
        #expect(machine.handle(ask(3, .attach)) == [])
        #expect(machine.state.waiters.map(\.id) == [2, 3])
    }

    @Test func theConnectionCeilingParksEveryClass() {
        var machine = makeMachine().after(ask(1, .attach) + ask(2, .ordinarySession))
        #expect(machine.handle(ask(3, .events)) == [])
        #expect(machine.state.waiters.map(\.id) == [3])
    }

    @Test func longLivedSessionClassesSpendTheOrdinaryBudget() {
        for held in [SSHChannelAdmission.ChannelClass.control, .core, .zellij] {
            var machine = makeMachine(.production).after(
                ask(1, held) + ask(2, .ordinarySession) + ask(3, .ordinarySession)
                    + ask(4, .ordinarySession))
            #expect(machine.handle(ask(5, .ordinarySession)) == [], "\(held)")
            #expect(machine.handle(ask(6, held)) == [], "\(held)")
        }
        var both = makeMachine(.production).after(ask(1, .control) + ask(2, .core) + ask(3, .zellij))
        #expect(both.handle(ask(4, .ordinarySession)) == [.grant(id: 4)])
        #expect(both.handle(ask(5, .ordinarySession)) == [])
    }

    @Test func aReleaseGrantsTheFirstWaiterItAdmitsInArrivalOrder() {
        var machine = makeMachine(.init(
            ordinaryForwarding: 1, events: 1, ordinarySession: 1, attach: 1, connection: 4))
            .after(ask(1, .ordinarySession) + ask(2, .attach) + ask(3, .attach)
                + ask(4, .ordinarySession) + ask(5, .attach))
        #expect(machine.handle(.release(.ordinarySession)) == [.grant(id: 4)])
        #expect(machine.state.waiters.map(\.id) == [3, 5])
        #expect(machine.handle(.release(.attach)) == [.grant(id: 3)])
        #expect(machine.state.waiters.map(\.id) == [5])
    }

    @Test func aReleaseGrantsOnlyWhatItMakesRoomFor() {
        var machine = makeMachine(.init(
            ordinaryForwarding: 1, events: 1, ordinarySession: 1, attach: 1, connection: 1))
            .after(ask(1, .ordinarySession) + ask(2, .events) + ask(3, .attach))
        #expect(machine.handle(.release(.ordinarySession)) == [.grant(id: 2)])
        #expect(machine.state.waiters.map(\.id) == [3])
        #expect(machine.state.counts.connection == 1)
    }

    @Test func aReleaseWithNoWaiterOnlyCounts() {
        var machine = makeMachine().after(ask(1, .attach))
        #expect(machine.handle(.release(.attach)) == [])
        #expect(machine.state.counts.connection == 0)
    }

    @Test func cancellingAParkedRequestFailsItsWait() {
        var machine = makeMachine().after(ask(1, .attach) + ask(2, .attach) + ask(3, .attach))
        #expect(machine.handle(.cancel(id: 2)) == [.cancelWait(id: 2)])
        #expect(machine.state.waiters.map(\.id) == [3])
        #expect(machine.handle(.release(.attach)) == [.grant(id: 3)])
    }

    @Test func aCancellationAfterTheGrantIsRememberedUntilTheRequestFinishes() {
        var machine = makeMachine().after(ask(1, .attach))
        #expect(machine.handle(.cancel(id: 1)) == [])
        #expect(machine.state.cancelledUnparked == [1])
        #expect(machine.state.counts.attach == 1)
        _ = machine.handle(.finished(id: 1))
        #expect(machine.state.cancelledUnparked.isEmpty)
        #expect(machine.state.pending.isEmpty)
    }

    @Test func aRequestCancelledBeforeItRegistersIsRefused() {
        var machine = makeMachine().after([.requested(id: 1), .cancel(id: 1)])
        #expect(machine.handle(.register(id: 1, .attach, deadline: nil)) == [.refuse(id: 1)])
        #expect(machine.state.counts.connection == 0)
        #expect(machine.state.waiters.isEmpty)
    }

    @Test func aCancellationForAFinishedRequestIsIgnored() {
        var machine = makeMachine().after(ask(1, .attach) + [.finished(id: 1)])
        #expect(machine.handle(.cancel(id: 1)) == [])
        #expect(machine.state.cancelledUnparked.isEmpty)
    }

    @Test func anExpiredWaitTimesOutAndLeavesTheQueue() {
        var machine = makeMachine().after(ask(1, .attach) + ask(2, .attach, deadline: .seconds(1)))
        #expect(machine.handle(.expire(id: 2)) == [.timeOut(id: 2)])
        #expect(machine.state.waiters.isEmpty)
        #expect(machine.handle(.release(.attach)) == [])
    }

    @Test func aDeadlineAfterTheGrantIsIgnored() {
        var machine = makeMachine().after(
            ask(1, .attach) + ask(2, .attach, deadline: .seconds(1)) + [.release(.attach)])
        #expect(machine.handle(.expire(id: 2)) == [])
        #expect(machine.state.counts.attach == 1)
    }
}
