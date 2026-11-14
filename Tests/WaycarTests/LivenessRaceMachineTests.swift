import Testing

@testable import Waycar

/// `LivenessRaceMachine` (HERDR-14): one test per transition, plus the
/// ignored cases. The owner suite is `LivenessRaceTests`; `EventsSessionResilienceTests`
/// drives the race through kept-connection probes and revalidations.
@Suite("LivenessRaceMachine")
struct LivenessRaceMachineTests {
    private var hedged: LivenessRaceMachine { LivenessRaceMachine(hedged: true) }

    @Test func aRaceStartsWithTheProofAlone() {
        let machine = hedged
        #expect(machine.state == .proving)
        #expect(!machine.isSettled)
    }

    @Test func theHedgeTimerStartsTheHedgeOnce() {
        var machine = hedged
        #expect(machine.handle(.hedgeTimerElapsed) == [.launchHedge])
        #expect(machine.state == .racing)
        #expect(machine.handle(.hedgeTimerElapsed) == [])
    }

    @Test func aProofThatFailsOnTheLinkStartsTheHedgeAtOnce() {
        var machine = hedged
        #expect(machine.handle(.proofFailed(startsHedge: true)) == [.launchHedge])
        #expect(machine.state == .proofFailedAwaitingHedge(hedgeStarted: true))
        #expect(machine.handle(.hedgeTimerElapsed) == [])
    }

    @Test func aProofThatFailsOtherwiseFailsTheRace() {
        var machine = hedged
        #expect(machine.handle(.proofFailed(startsHedge: false)) == [.failWithProofFailure])
        #expect(machine.state == .proofFailedAwaitingHedge(hedgeStarted: false))
    }

    @Test func theTimerFiringBeforeAFailureSettlesStillStartsTheHedge() {
        var machine = hedged.after([.proofFailed(startsHedge: false)])
        #expect(machine.handle(.hedgeTimerElapsed) == [.launchHedge])
        #expect(machine.state == .proofFailedAwaitingHedge(hedgeStarted: true))
        #expect(machine.handle(.settle) == [.settle])
    }

    @Test func withoutAHedgeEveryProofFailureFailsTheRace() {
        var machine = LivenessRaceMachine(hedged: false)
        #expect(machine.handle(.proofFailed(startsHedge: true)) == [.failWithProofFailure])
    }

    @Test func aProofFailingOnTheLinkWhileTheHedgeRunsLeavesItToTheHedge() {
        var machine = hedged.after([.hedgeTimerElapsed])
        #expect(machine.handle(.proofFailed(startsHedge: true)) == [])
        #expect(machine.state == .proofFailedAwaitingHedge(hedgeStarted: true))
    }

    @Test func aProofFailingOtherwiseWhileTheHedgeRunsFailsTheRace() {
        var machine = hedged.after([.hedgeTimerElapsed])
        #expect(machine.handle(.proofFailed(startsHedge: false)) == [.failWithProofFailure])
    }

    @Test func aHedgeFailingWhileTheProofIsOutWaitsForTheProof() {
        var machine = hedged.after([.hedgeTimerElapsed])
        #expect(machine.handle(.hedgeFailed) == [])
        #expect(machine.state == .hedgeFailedAwaitingProof)
        #expect(machine.handle(.hedgeTimerElapsed) == [])
    }

    @Test func theHedgeFailureOutranksAProofThatThenFailsOnTheLink() {
        var machine = hedged.after([.hedgeTimerElapsed, .hedgeFailed])
        #expect(machine.handle(.proofFailed(startsHedge: true)) == [.failWithHedgeFailure])
    }

    @Test func aProofThatThenFailsOnTheServerFailsWithItsOwnFailure() {
        var machine = hedged.after([.hedgeTimerElapsed, .hedgeFailed])
        #expect(machine.handle(.proofFailed(startsHedge: false)) == [.failWithProofFailure])
    }

    /// A server answer is decided in a second locked step: a hedge failure
    /// landing in between asks to decide too, and the first to settle wins
    /// (as before the conversion).
    @Test func aServerFailureNotYetDecidedCanBeOvertakenByTheHedgesFailure() {
        var machine = hedged.after([.hedgeTimerElapsed])
        #expect(machine.handle(.proofFailed(startsHedge: false)) == [.failWithProofFailure])
        #expect(machine.handle(.hedgeFailed) == [.failWithHedgeFailure])
        #expect(machine.handle(.settle) == [.settle])
        #expect(machine.handle(.settle) == [])
    }

    @Test func aHedgeFailingAfterTheProofFailedFailsTheRaceWithIt() {
        var machine = hedged.after([.proofFailed(startsHedge: true)])
        #expect(machine.handle(.hedgeFailed) == [.failWithHedgeFailure])
    }

    @Test func theRaceIsDecidedOnce() {
        for start in [
            hedged, hedged.after([.hedgeTimerElapsed]),
            hedged.after([.proofFailed(startsHedge: true)]),
            hedged.after([.hedgeTimerElapsed, .hedgeFailed]),
        ] {
            var machine = start
            #expect(machine.handle(.settle) == [.settle])
            #expect(machine.isSettled)
            #expect(machine.handle(.settle) == [])
        }
    }

    @Test func aDecidedRaceIgnoresEverything() {
        var machine = hedged.after([.settle])
        #expect(machine.handle(.hedgeTimerElapsed) == [])
        #expect(machine.handle(.proofFailed(startsHedge: true)) == [])
        #expect(machine.handle(.hedgeFailed) == [])
        #expect(machine.state == .settled)
    }
}
