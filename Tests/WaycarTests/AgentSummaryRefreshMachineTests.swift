import Testing

@testable import Waycar

@Suite("Agent summary refresh machine")
struct AgentSummaryRefreshMachineTests {
    private typealias Machine = AgentSummaryRefreshMachine

    /// Started: a periodic wait ended and refresh 1 is in flight.
    private var refreshing: Machine {
        Machine().after([
            .schedule(canRefresh: true),
            .waitEnded(.periodic, canRefresh: true, periodicDue: true),
        ])
    }

    @Test func scheduleArmsThePeriodicWaitOnlyFromIdle() {
        var machine = Machine()
        #expect(machine.handle(.schedule(canRefresh: false)).isEmpty)
        #expect(machine.state == .idle)
        #expect(machine.handle(.schedule(canRefresh: true)) == [.arm(.periodic)])
        #expect(machine.state == .waiting(.periodic))
        #expect(machine.handle(.schedule(canRefresh: true)).isEmpty)
        var running = refreshing
        #expect(running.handle(.schedule(canRefresh: true)).isEmpty)
    }

    @Test func anUnsupportedActionStopsThePeriodicWait() {
        var machine = refreshing
        _ = machine.handle(.finished(token: 1, .unsupported))
        #expect(machine.isUnsupported)
        #expect(machine.handle(.schedule(canRefresh: true)).isEmpty)
        #expect(machine.handle(.waitEnded(.debounce, canRefresh: true, periodicDue: false))
            == [.startRefresh(token: 2, triggers: false)])
    }

    @Test func aWaitEndingStartsTheRefresh() {
        var machine = Machine().after([.schedule(canRefresh: true)])
        #expect(machine.handle(.waitEnded(.periodic, canRefresh: true, periodicDue: true))
            == [.cancelWait, .startRefresh(token: 1, triggers: true)])
        #expect(machine.state == .refreshing(token: 1, restartsClock: true))
    }

    @Test func aWaitEndingWhileTheRefreshIsOffStartsNothing() {
        var machine = Machine().after([.schedule(canRefresh: true)])
        #expect(machine.handle(.waitEnded(.periodic, canRefresh: false, periodicDue: true))
            == [.cancelWait])
        #expect(machine.state == .idle)
    }

    @Test func aStatusTriggeredRefreshRestartsTheClockOnlyOnceThePeriodicOneIsDue() {
        var early = Machine().after([.statusChanged(canRefresh: true)])
        _ = early.handle(.waitEnded(.debounce, canRefresh: true, periodicDue: false))
        #expect(early.state == .refreshing(token: 1, restartsClock: false))
        #expect(early.handle(.finished(token: 1, .refreshed))
            == [.cover, .updateRows, .proceed(readsStore: true)])

        var due = Machine().after([.statusChanged(canRefresh: true)])
        _ = due.handle(.waitEnded(.debounce, canRefresh: true, periodicDue: true))
        #expect(due.state == .refreshing(token: 1, restartsClock: true))
        #expect(due.handle(.finished(token: 1, .refreshed))
            == [.restartClock, .cover, .updateRows, .proceed(readsStore: true)])
    }

    @Test func aStatusChangeReplacesAnyWaitWithTheDebounce() {
        var machine = Machine().after([.schedule(canRefresh: true)])
        #expect(machine.handle(.statusChanged(canRefresh: true)) == [.arm(.debounce)])
        #expect(machine.state == .waiting(.debounce))
        #expect(machine.handle(.statusChanged(canRefresh: true)) == [.arm(.debounce)])
        #expect(machine.handle(.statusChanged(canRefresh: false)).isEmpty)
    }

    @Test func statusChangesDuringARefreshQueueOneFollowUp() {
        var machine = refreshing
        #expect(machine.handle(.statusChanged(canRefresh: true)).isEmpty)
        #expect(machine.handle(.statusChanged(canRefresh: true)).isEmpty)
        _ = machine.handle(.finished(token: 1, .refreshed))
        #expect(machine.state == .idle)
        #expect(machine.handle(.proceed(readsStore: true, canRefresh: true, periodicDue: false))
            == [.startRefresh(token: 2, triggers: true)])
        #expect(machine.state == .refreshing(token: 2, restartsClock: false))
        _ = machine.handle(.finished(token: 2, .refreshed))
        #expect(machine.handle(.proceed(readsStore: true, canRefresh: true, periodicDue: false))
            == [.arm(.periodic)])
    }

    @Test func aFollowUpIsDroppedWhenTheRefreshWasNotWorthAReRead() {
        var machine = refreshing.after([.statusChanged(canRefresh: true)])
        _ = machine.handle(.finished(token: 1, .failed))
        #expect(machine.failures == 1)
        #expect(machine.handle(.proceed(readsStore: false, canRefresh: true, periodicDue: false))
            == [.arm(.periodic)])
    }

    @Test func aPauseBeforeProceedDropsTheFollowUp() {
        var machine = refreshing.after([.statusChanged(canRefresh: true)])
        _ = machine.handle(.finished(token: 1, .refreshed))
        #expect(machine.handle(.paused).isEmpty)
        #expect(machine.handle(.proceed(readsStore: true, canRefresh: false, periodicDue: false))
            .isEmpty)
        #expect(machine.state == .idle)
    }

    @Test func aFailingHostIgnoresStatusChangesUntilARefreshSucceeds() {
        var machine = refreshing
        _ = machine.handle(.finished(token: 1, .failed))
        #expect(machine.handle(.statusChanged(canRefresh: true)).isEmpty)
        _ = machine.handle(.proceed(readsStore: false, canRefresh: true, periodicDue: true))
        _ = machine.handle(.waitEnded(.periodic, canRefresh: true, periodicDue: true))
        _ = machine.handle(.finished(token: 2, .refreshed))
        #expect(machine.failures == 0)
        _ = machine.handle(.proceed(readsStore: true, canRefresh: true, periodicDue: false))
        #expect(machine.handle(.statusChanged(canRefresh: true)) == [.arm(.debounce)])
    }

    @Test func outcomesMoveTheClockAndCoverage() {
        func effects(_ outcome: Machine.Outcome) -> [Machine.Effect] {
            var machine = refreshing
            return machine.handle(.finished(token: 1, outcome))
        }
        #expect(effects(.refreshed) == [.restartClock, .cover, .updateRows, .proceed(readsStore: true)])
        #expect(effects(.unsupported) == [.restartClock, .cover, .updateRows, .proceed(readsStore: true)])
        #expect(effects(.pluginMissing)
            == [.reportPluginMissing, .restartClock, .cover, .updateRows, .proceed(readsStore: false)])
        #expect(effects(.failed) == [.restartClock, .cover, .updateRows, .proceed(readsStore: false)])
        #expect(effects(.interrupted) == [.restartClock, .updateRows, .proceed(readsStore: false)])
        #expect(effects(.cancelled) == [.updateRows, .proceed(readsStore: false)])
    }

    @Test func aCancelledRefreshKeepsItsSlotUntilItReportsBack() {
        var machine = refreshing
        #expect(machine.handle(.paused) == [.cancelRefresh(token: 1)])
        #expect(machine.state == .refreshing(token: 1, restartsClock: true))
        #expect(machine.handle(.schedule(canRefresh: true)).isEmpty)
        #expect(machine.handle(.waitEnded(.periodic, canRefresh: true, periodicDue: true)).isEmpty)
        _ = machine.handle(.finished(token: 1, .cancelled))
        // The follow-up the stale wait asked for needs a re-read worth having.
        #expect(machine.handle(.proceed(readsStore: false, canRefresh: true, periodicDue: true))
            == [.arm(.periodic)])
    }

    @Test func aConnectionChangeForgetsFailuresAndTheMissingActionAndCancels() {
        var machine = refreshing
        _ = machine.handle(.finished(token: 1, .unsupported))
        _ = machine.handle(.proceed(readsStore: true, canRefresh: true, periodicDue: false))
        _ = machine.handle(.statusChanged(canRefresh: true))
        _ = machine.handle(.waitEnded(.debounce, canRefresh: true, periodicDue: false))
        _ = machine.handle(.finished(token: 2, .failed))
        #expect(machine.failures == 1 && machine.isUnsupported)
        _ = machine.handle(.proceed(readsStore: false, canRefresh: true, periodicDue: false))
        #expect(machine.state == .idle)
        _ = machine.handle(.connectionChanged)
        #expect(machine.failures == 0 && !machine.isUnsupported)

        var running = refreshing.after([.statusChanged(canRefresh: true)])
        #expect(running.handle(.connectionChanged) == [.cancelRefresh(token: 1)])
        _ = running.handle(.finished(token: 1, .cancelled))
        #expect(running.handle(.proceed(readsStore: true, canRefresh: true, periodicDue: true))
            == [.arm(.periodic)])

        var waiting = Machine().after([.schedule(canRefresh: true)])
        #expect(waiting.handle(.connectionChanged) == [.cancelWait])
        #expect(waiting.state == .idle)
    }

    @Test func aMissingPluginEndsTheWait() {
        var waiting = Machine().after([.statusChanged(canRefresh: true)])
        #expect(waiting.handle(.pluginMissing) == [.cancelWait])
        #expect(waiting.state == .idle)
        var running = refreshing
        #expect(running.handle(.pluginMissing).isEmpty)
        var idle = Machine()
        #expect(idle.handle(.pluginMissing).isEmpty)
    }

    @Test func aStaleFinishIsIgnored() {
        var machine = refreshing
        #expect(machine.handle(.finished(token: 9, .refreshed)).isEmpty)
        #expect(machine.state == .refreshing(token: 1, restartsClock: true))
        var idle = Machine()
        #expect(idle.handle(.finished(token: 1, .refreshed)).isEmpty)
    }

    @Test func endCancelsWhateverIsPendingAndIgnoresEverythingAfter() {
        var waiting = Machine().after([.schedule(canRefresh: true)])
        #expect(waiting.handle(.end) == [.cancelWait])
        var running = refreshing
        #expect(running.handle(.end) == [.cancelRefresh(token: 1)])
        #expect(running.state == .ended)
        #expect(running.handle(.finished(token: 1, .refreshed)).isEmpty)
        #expect(running.handle(.schedule(canRefresh: true)).isEmpty)
        #expect(running.handle(.statusChanged(canRefresh: true)).isEmpty)
        #expect(running.handle(.end).isEmpty)
    }

    @Test func tokensAreNeverReused() {
        var machine = refreshing
        _ = machine.handle(.paused)
        _ = machine.handle(.finished(token: 1, .cancelled))
        _ = machine.handle(.proceed(readsStore: false, canRefresh: true, periodicDue: true))
        #expect(machine.handle(.waitEnded(.periodic, canRefresh: true, periodicDue: true))
            == [.cancelWait, .startRefresh(token: 2, triggers: true)])
    }
}
