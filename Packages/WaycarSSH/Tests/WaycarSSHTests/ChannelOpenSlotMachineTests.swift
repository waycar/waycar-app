import Testing

@testable import WaycarSSH

@Suite("Channel open slot machine")
struct ChannelOpenSlotMachineTests {
    private typealias Machine = ChannelOpenSlotMachine

    @Test("opens are admitted up to the limit")
    func opensAreAdmittedUpToTheLimit() {
        var machine = Machine(limit: 2)
        #expect(machine.canAdmit(.pipelined))
        _ = machine.handle(.take(.pipelined))
        _ = machine.handle(.take(.pipelined))
        #expect(!machine.canAdmit(.pipelined))
        #expect(!machine.canAdmit(.stock))
        #expect(machine.state.inFlight == 2)
    }

    @Test("a second stock open waits while one is in flight; pipelined ones do not")
    func aSecondStockOpenWaits() {
        var machine = Machine(limit: 4).after([.take(.stock)])
        #expect(machine.state.stockInFlight)
        #expect(!machine.canAdmit(.stock))
        #expect(machine.canAdmit(.pipelined))
    }

    @Test("a release hands the slot to the first admissible waiter")
    func aReleaseHandsTheSlotOn() {
        var machine = Machine(limit: 1).after([
            .take(.pipelined),
            .park(id: 1, .pipelined, priority: .normal),
            .park(id: 2, .pipelined, priority: .normal),
        ])
        #expect(machine.handle(.release(.pipelined)) == [.grant(id: 1)])
        #expect(machine.state.inFlight == 1)
        #expect(machine.waiterCount == 1)
    }

    @Test("interactive openers go first, in arrival order")
    func interactiveOpenersGoFirst() {
        var machine = Machine(limit: 1).after([
            .take(.pipelined),
            .park(id: 1, .pipelined, priority: .normal),
            .park(id: 2, .pipelined, priority: .interactive),
            .park(id: 3, .pipelined, priority: .interactive),
        ])
        #expect(machine.handle(.release(.pipelined)) == [.grant(id: 2)])
        #expect(machine.handle(.release(.pipelined)) == [.grant(id: 3)])
        #expect(machine.handle(.release(.pipelined)) == [.grant(id: 1)])
    }

    @Test("a stock waiter is passed over while a stock open is in flight")
    func aStockWaiterIsPassedOver() {
        var machine = Machine(limit: 2).after([
            .take(.stock),
            .take(.pipelined),
            .park(id: 1, .stock, priority: .interactive),
            .park(id: 2, .pipelined, priority: .normal),
        ])
        #expect(machine.handle(.release(.pipelined)) == [.grant(id: 2)])
        #expect(machine.handle(.release(.stock)) == [.grant(id: 1)])
        #expect(machine.state.stockInFlight)
    }

    @Test("a higher limit admits every waiter it makes room for")
    func aHigherLimitAdmitsWaiters() {
        var machine = Machine(limit: 1).after([
            .take(.pipelined),
            .park(id: 1, .pipelined, priority: .normal),
            .park(id: 2, .pipelined, priority: .normal),
        ])
        #expect(machine.handle(.setLimit(3)) == [.grant(id: 1), .grant(id: 2)])
        #expect(machine.state.inFlight == 3)
        _ = machine.handle(.setLimit(0))
        #expect(machine.state.limit == 1)
    }

    @Test("a withdrawn waiter leaves the queue; a granted one cannot be withdrawn")
    func withdrawingAWaiter() {
        var machine = Machine(limit: 1).after([
            .take(.pipelined),
            .park(id: 1, .pipelined, priority: .normal),
        ])
        #expect(machine.handle(.withdraw(id: 1, .timedOut)) == [.fail(id: 1, .timedOut)])
        #expect(machine.waiterCount == 0)
        #expect(machine.handle(.release(.pipelined)) == [])

        var granted = Machine(limit: 1).after([
            .take(.pipelined),
            .park(id: 1, .pipelined, priority: .normal),
            .release(.pipelined),
        ])
        #expect(granted.handle(.withdraw(id: 1, .cancelled)) == [])
        #expect(granted.state.inFlight == 1)
    }

    @Test("invalidation fails every waiter in resume order and keeps the slots counted")
    func invalidationFailsEveryWaiter() {
        var machine = Machine(limit: 1).after([
            .take(.pipelined),
            .park(id: 1, .pipelined, priority: .normal),
            .park(id: 2, .stock, priority: .interactive),
        ])
        #expect(machine.handle(.invalidate) == [
            .fail(id: 2, .connectionInvalidated), .fail(id: 1, .connectionInvalidated),
        ])
        #expect(machine.waiterCount == 0)
        #expect(machine.state.inFlight == 1)
    }
}
