import Testing

@testable import Waycar

/// `TmuxInventoryPublicationMachine`: only a refresh newer than the
/// inventory in force publishes.
@Suite("tmux inventory publication machine")
struct TmuxInventoryPublicationMachineTests {
    typealias Machine = TmuxInventoryPublicationMachine

    @Test func everyRefreshListsUnderAFreshToken() {
        var machine = Machine()
        #expect(machine.handle(.refreshRequested) == [.list(token: 1)])
        #expect(machine.handle(.refreshRequested) == [.list(token: 2)])
        #expect(machine.state == .empty)
    }

    @Test func theFirstRefreshToFinishPublishes() {
        var machine = Machine().after([.refreshRequested])
        #expect(machine.handle(.listed(token: 1)) == [.publish(token: 1)])
        #expect(machine.state == .current(token: 1))
    }

    @Test func refreshesFinishingInOrderEachPublish() {
        var machine = Machine().after([.refreshRequested, .refreshRequested])
        #expect(machine.handle(.listed(token: 1)) == [.publish(token: 1)])
        #expect(machine.handle(.listed(token: 2)) == [.publish(token: 2)])
        #expect(machine.state == .current(token: 2))
    }

    @Test func anOlderRefreshFinishingLastOnlyAnswersItsCaller() {
        var machine = Machine().after([.refreshRequested, .refreshRequested, .listed(token: 2)])
        #expect(machine.handle(.listed(token: 1)).isEmpty)
        #expect(machine.state == .current(token: 2))
        #expect(machine.handle(.listed(token: 2)).isEmpty)
    }

    @Test func aRefreshStartedAfterTheOneInForcePublishes() {
        var machine = Machine().after([
            .refreshRequested, .refreshRequested, .listed(token: 2), .refreshRequested,
        ])
        #expect(machine.handle(.listed(token: 1)).isEmpty)
        #expect(machine.handle(.listed(token: 3)) == [.publish(token: 3)])
        #expect(machine.state == .current(token: 3))
    }
}
