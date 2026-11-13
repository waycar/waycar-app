import Foundation
import Testing

@testable import Waycar

@Suite("Watch phone activity lease")
struct WatchActivityLeaseMachineTests {
    @Test func requestsShareOneLeaseAndOnlyTheLastReleases() {
        var machine = WatchActivityLeaseMachine()
        let first = UUID(), second = UUID()
        #expect(machine.handle(.acquire(first)) == [.begin(1)])
        #expect(machine.handle(.acquire(second)) == [])
        #expect(machine.handle(.release(UUID())) == [])
        #expect(machine.handle(.release(first)) == [])
        #expect(machine.handle(.release(second)) == [.release])
        #expect(machine.state == .released)
        #expect(machine.handle(.release(second)) == [])
    }

    @Test func reachabilitySharesTheLeaseButIsIdempotent() {
        var machine = WatchActivityLeaseMachine()
        let request = UUID()
        #expect(machine.handle(.reachability(true)) == [.begin(1), .startPublishing])
        #expect(machine.handle(.reachability(true)) == [])
        #expect(machine.handle(.acquire(request)) == [])
        #expect(machine.handle(.reachability(false)) == [])
        #expect(machine.handle(.release(request)) == [.release])
        #expect(machine.handle(.reachability(false)) == [])
        #expect(machine.handle(.acquire(request)) == [.begin(2)])
        #expect(machine.handle(.reachability(true)) == [.startPublishing])
        #expect(machine.handle(.release(request)) == [])
        #expect(machine.handle(.reachability(false)) == [.release])
    }

    @Test func expirationRepliesBeforeReleaseAndInvalidatesOwners() {
        var machine = WatchActivityLeaseMachine()
        let old = UUID(), new = UUID()
        #expect(machine.handle(.expired(1)) == [])
        #expect(machine.handle(.acquire(old)) == [.begin(1)])
        #expect(machine.handle(.reachability(true)) == [.startPublishing])
        #expect(machine.handle(.expired(0)) == [])
        #expect(machine.handle(.expired(1)) == [.expireReplies, .release])
        #expect(machine.handle(.expired(1)) == [])
        #expect(machine.handle(.acquire(new)) == [.begin(2)])
        #expect(machine.handle(.release(old)) == [])
        #expect(machine.handle(.expired(1)) == [])
        #expect(machine.state == .held(generation: 2, owners: [new], reachable: false))
        #expect(machine.handle(.release(new)) == [.release])
    }
}
