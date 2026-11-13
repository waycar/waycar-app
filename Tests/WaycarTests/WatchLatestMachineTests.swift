import Testing
@testable import Waycar

struct WatchLatestMachineTests {
    let stale = WatchLatest(source: .summary, text: "cached", lastReply: nil, isStale: true)

    @Test func singleFlightAndOneFollowUp() {
        var machine = WatchLatestMachine()
        #expect(machine.handle(.load) == [.read(1)])
        #expect(machine.read == .loading)
        #expect(machine.handle(.load).isEmpty)
        #expect(machine.handle(.finished(99, .loaded(nil))).isEmpty)
        #expect(machine.read == .loading)
        #expect(machine.handle(.finished(1, .loaded(stale))) == [.scheduleRecheck(2)])
        #expect(machine.read == .loaded(stale))
        #expect(machine.handle(.recheckElapsed(99)).isEmpty)
        #expect(machine.handle(.recheckElapsed(2)) == [.read(3)])
        #expect(machine.handle(.finished(3, .loaded(stale))).isEmpty)
        #expect(machine.state == .resting(.loaded(stale)))
        #expect(machine.handle(.recheckElapsed(2)).isEmpty)
    }

    /// The read in flight answers for a timer that elapses meanwhile.
    @Test func aTimerElapsingDuringAReloadIsDroppedAndTextKeptOnFailure() {
        var machine = WatchLatestMachine().after([.load, .finished(1, .loaded(stale))])
        #expect(machine.handle(.load) == [.read(3)])
        #expect(machine.handle(.recheckElapsed(2)).isEmpty)
        #expect(machine.read == .loaded(stale))
        #expect(machine.handle(.finished(3, .failed("offline"))).isEmpty)
        #expect(machine.read == .loaded(stale))
        #expect(!machine.isChecking)
        #expect(machine.handle(.recheckElapsed(2)).isEmpty)
    }

    /// A reload that fails before the follow-up's timer fires leaves that
    /// follow-up scheduled, so stale text is still asked for again.
    @Test func aReloadFailingBeforeTheTimerKeepsTheFollowUp() {
        var machine = WatchLatestMachine().after([.load, .finished(1, .loaded(stale))])
        #expect(machine.handle(.load) == [.read(3)])
        #expect(machine.handle(.finished(3, .failed("offline"))).isEmpty)
        #expect(machine.read == .loaded(stale))
        #expect(machine.isChecking)
        #expect(machine.handle(.recheckElapsed(2)) == [.read(4)])
    }

    /// A fresh answer to the reload makes the old follow-up moot.
    @Test func aFreshReloadDropsTheFollowUp() {
        let fresh = WatchLatest(source: .summary, text: "new", lastReply: nil, isStale: false)
        var machine = WatchLatestMachine().after([.load, .finished(1, .loaded(stale)), .load])
        #expect(machine.handle(.finished(3, .loaded(fresh))).isEmpty)
        #expect(!machine.isChecking)
        #expect(machine.handle(.recheckElapsed(2)).isEmpty)
        #expect(machine.read == .loaded(fresh))
    }

    /// B-08: retained stale text does not imply a request still exists.
    @Test func failedRecheckEndsCheckingWithoutDiscardingText() {
        var machine = WatchLatestMachine().after([.load, .finished(1, .loaded(stale))])
        #expect(machine.isChecking)
        #expect(machine.handle(.recheckElapsed(2)) == [.read(3)])
        #expect(machine.isChecking)
        #expect(machine.handle(.finished(3, .failed("offline"))).isEmpty)
        #expect(machine.read == .loaded(stale))
        #expect(!machine.isChecking)
    }

    @Test func stillStaleRecheckAlsoEndsChecking() {
        let machine = WatchLatestMachine().after([
            .load, .finished(1, .loaded(stale)), .recheckElapsed(2), .finished(3, .loaded(stale)),
        ])
        #expect(!machine.isChecking)
    }

    @Test func failuresWithoutTextAndEmptySuccess() {
        var machine = WatchLatestMachine().after([.load])
        #expect(machine.handle(.finished(1, .failed("offline"))).isEmpty)
        #expect(machine.read == .failed("offline"))
        #expect(machine.handle(.load) == [.read(2)])
        #expect(machine.handle(.finished(2, .loaded(nil))).isEmpty)
        #expect(machine.read == .loaded(nil))
        #expect(machine.handle(.finished(2, .failed("late"))).isEmpty)
    }
}
