import Testing

@testable import Waycar

@Suite("Host session lifetime machine")
struct HostSessionLifetimeMachineTests {
    private typealias Machine = HostSessionLifetimeMachine

    @Test func aNewSessionIsOpenWithItsCreatorsHold() {
        let machine = Machine()
        #expect(machine.state == .open(holds: 1))
        #expect(machine.isOpen)
        #expect(!machine.isClosed)
    }

    @Test func everyRetainIsOneMoreHold() {
        var machine = Machine()
        #expect(machine.handle(.retain) == [.retained])
        #expect(machine.handle(.retain) == [.retained])
        #expect(machine.state == .open(holds: 3))
    }

    @Test func onlyTheLastReleaseTearsAnOpenSessionDown() {
        var machine = Machine().after([.retain])
        #expect(machine.handle(.release) == [])
        #expect(machine.state == .open(holds: 1))
        #expect(machine.handle(.release) == [.tearDown])
        #expect(machine.state == .closed)
        #expect(!machine.isOpen)
    }

    @Test func aClosedSessionRefusesHoldsAndIgnoresReleases() {
        var machine = Machine().after([.release])
        #expect(machine.handle(.retain) == [.refused])
        #expect(machine.handle(.release) == [])
        #expect(machine.handle(.connectionInvalidated) == [])
        #expect(machine.state == .closed)
    }

    @Test func anInvalidatedSessionStillTakesHoldsButStartsNothing() {
        var machine = Machine()
        #expect(machine.handle(.connectionInvalidated) == [])
        #expect(machine.state == .invalidated(holds: 1))
        #expect(!machine.isOpen)
        #expect(machine.handle(.retain) == [.retained])
        #expect(machine.state == .invalidated(holds: 2))
        #expect(machine.handle(.connectionInvalidated) == [])
        #expect(machine.state == .invalidated(holds: 2))
    }

    /// The last release of an invalidated session leaves the connection as
    /// the SSH layer left it.
    @Test func theLastReleaseOfAnInvalidatedSessionClosesWithoutTeardown() {
        var machine = Machine().after([.retain, .connectionInvalidated])
        #expect(machine.handle(.release) == [])
        #expect(machine.state == .invalidated(holds: 1))
        #expect(machine.handle(.release) == [])
        #expect(machine.state == .closed)
    }
}
