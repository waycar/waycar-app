import Testing

@testable import Waycar

@Suite("Snapshot authority machine")
struct SnapshotAuthorityMachineTests {
    private typealias Machine = SnapshotAuthorityMachine

    @Test func rowsAwaitVerificationUntilAnAnswerLands() {
        var machine = Machine()
        #expect(machine.isAwaitingSnapshot)
        #expect(machine.handle(.requested(connected: true)) == [.run(token: 1)])
        #expect(machine.handle(.landed(epoch: 0, connected: true)) == [.apply])
        #expect(machine.isAwaitingSnapshot)
        #expect(machine.handle(.verified).isEmpty)
        #expect(!machine.isAwaitingSnapshot)
        #expect(machine.handle(.resyncEnded(token: 1, connected: true)) == [.release])
        #expect(machine.state.resync == .idle)
    }

    @Test func nothingResyncsWhileDisconnected() {
        var machine = Machine()
        #expect(machine.handle(.requested(connected: false)).isEmpty)
        #expect(machine.state.resync == .idle)
    }

    @Test func requestsDuringAResyncCoalesceIntoOneFollowUp() {
        var machine = Machine().after([.requested(connected: true)])
        #expect(machine.handle(.requested(connected: true)).isEmpty)
        #expect(machine.handle(.requested(connected: true)).isEmpty)
        #expect(machine.state.resync == .running(token: 1, followUp: true))
        #expect(machine.handle(.resyncEnded(token: 1, connected: true))
            == [.release, .run(token: 2)])
        #expect(machine.handle(.resyncEnded(token: 2, connected: true)) == [.release])
    }

    @Test func aFollowUpIsDroppedWhenTheConnectionIsGoneByThen() {
        var machine = Machine().after([.requested(connected: true), .requested(connected: true)])
        #expect(machine.handle(.resyncEnded(token: 1, connected: false)) == [.release])
        #expect(machine.state.resync == .idle)
    }

    @Test func aConnectionChangeFencesTheResyncInFlightWithoutStoppingIt() {
        var machine = Machine().after([
            .requested(connected: true), .landed(epoch: 0, connected: true), .verified,
            .requested(connected: true), .requested(connected: true),
        ])
        #expect(machine.handle(.connectionChanged).isEmpty)
        #expect(machine.epoch == 1 && machine.isAwaitingSnapshot)
        #expect(machine.state.resync == .running(token: 1, followUp: false))
        // Its answer is refused, success or failure.
        #expect(machine.handle(.landed(epoch: 0, connected: true)).isEmpty)
        #expect(machine.handle(.refused(epoch: 0, connected: true)).isEmpty)
        // The new connection's request waits for it as the follow-up.
        #expect(machine.handle(.requested(connected: true)).isEmpty)
        #expect(machine.handle(.resyncEnded(token: 1, connected: true))
            == [.release, .run(token: 2)])
        #expect(machine.handle(.landed(epoch: 1, connected: true)) == [.apply])
    }

    @Test func anAnswerWhileDisconnectedIsRefused() {
        var machine = Machine().after([.requested(connected: true)])
        #expect(machine.handle(.landed(epoch: 0, connected: false)).isEmpty)
        #expect(machine.handle(.refused(epoch: 0, connected: false)).isEmpty)
    }

    @Test func aFailedSnapshotRetriesOnceAfterItsFailureIsPublished() {
        var machine = Machine().after([.requested(connected: true)])
        #expect(machine.handle(.refused(epoch: 0, connected: true)) == [.reportFailure])
        #expect(machine.handle(.retryRequested(connected: true)) == [.armRetry])
        #expect(machine.handle(.retryRequested(connected: true)).isEmpty)
        _ = machine.handle(.resyncEnded(token: 1, connected: true))
        #expect(machine.handle(.retryElapsed(connected: true)) == [.releaseRetry, .run(token: 2)])
        #expect(!machine.state.isRetryArmed)
    }

    @Test func aRetryWakingDisconnectedStaysArmed() {
        var machine = Machine().after([
            .requested(connected: true), .refused(epoch: 0, connected: true),
            .retryRequested(connected: true),
        ])
        #expect(machine.handle(.retryElapsed(connected: false)).isEmpty)
        #expect(machine.state.isRetryArmed)
        #expect(machine.handle(.retryRequested(connected: true)).isEmpty)
    }

    @Test func noRetryIsArmedWhileDisconnected() {
        var machine = Machine()
        #expect(machine.handle(.retryRequested(connected: false)).isEmpty)
    }

    @Test func aLandedAnswerOrAConnectionChangeCancelsTheRetry() {
        var landed = Machine().after([
            .requested(connected: true), .refused(epoch: 0, connected: true),
            .retryRequested(connected: true), .resyncEnded(token: 1, connected: true),
            .requested(connected: true),
        ])
        #expect(landed.handle(.landed(epoch: 0, connected: true)) == [.cancelRetry, .apply])
        var changed = Machine().after([
            .requested(connected: true), .refused(epoch: 0, connected: true),
            .retryRequested(connected: true),
        ])
        #expect(changed.handle(.connectionChanged) == [.cancelRetry])
    }

    /// A retry wait whose sleep ended after it was cancelled still lands.
    @Test func aStaleRetryStillReleasesAndRequests() {
        var machine = Machine()
        #expect(machine.handle(.retryElapsed(connected: true)) == [.releaseRetry, .run(token: 1)])
    }

    @Test func endCancelsEverythingAndIgnoresWhatFollows() {
        var machine = Machine().after([
            .requested(connected: true), .refused(epoch: 0, connected: true),
            .retryRequested(connected: true),
        ])
        #expect(machine.handle(.end) == [.cancelRun(token: 1), .cancelRetry])
        #expect(machine.state.isEnded)
        #expect(machine.handle(.resyncEnded(token: 1, connected: true)).isEmpty)
        #expect(machine.handle(.requested(connected: true)).isEmpty)
        #expect(machine.handle(.landed(epoch: 0, connected: true)).isEmpty)
        #expect(machine.handle(.verified).isEmpty)
        #expect(machine.isAwaitingSnapshot)
        // Verified rows stay verified once their projection ends.
        var verified = Machine().after([
            .requested(connected: true), .landed(epoch: 0, connected: true), .verified,
        ])
        _ = verified.handle(.end)
        #expect(!verified.isAwaitingSnapshot)
        #expect(verified.handle(.connectionChanged).isEmpty)
        #expect(!verified.isAwaitingSnapshot)
        var idle = Machine()
        #expect(idle.handle(.end).isEmpty)
    }

    @Test func aStaleResyncEndIsIgnored() {
        var machine = Machine().after([.requested(connected: true)])
        #expect(machine.handle(.resyncEnded(token: 9, connected: true)).isEmpty)
        #expect(machine.state.resync == .running(token: 1, followUp: false))
    }
}
