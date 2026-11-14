import Testing

@testable import Waycar

/// `RequestRecoveryMachine` (HERDR-05): one test per transition, plus the
/// ignored cases. The owner suite is `EventsSessionSubscriptionsTests`
/// (silent replacement and request recovery).
@Suite("RequestRecoveryMachine")
struct RequestRecoveryMachineTests {
    private func executing(replays: Bool = true) -> RequestRecoveryMachine {
        RequestRecoveryMachine(replaysLinkFailures: replays).after([.connected])
    }

    private func replaying() -> RequestRecoveryMachine {
        executing().after([
            .failed(linkFailure: true, timedOut: false, stillInstalled: true), .connected,
        ])
    }

    @Test func aRequestWaitsForAConnectionThenRuns() {
        var machine = RequestRecoveryMachine(replaysLinkFailures: true)
        #expect(machine.state == .awaitingConnection)
        #expect(machine.handle(.connected) == [])
        #expect(machine.state == .executing)
    }

    @Test func aSuccessNotesActivity() {
        var machine = executing()
        #expect(machine.handle(.succeeded) == [.noteActivity])
        #expect(machine.state == .completed(.succeeded))
    }

    @Test func aServerAnswerIsThrownAsItIs() {
        var machine = executing()
        #expect(
            machine.handle(.failed(linkFailure: false, timedOut: false, stillInstalled: true))
                == [.throwFirstFailure])
        #expect(machine.state == .completed(.firstFailure))
    }

    @Test func aLinkFailureDistrustsTheInstalledConnectionAndAwaitsItsReplacement() {
        var machine = executing()
        #expect(
            machine.handle(.failed(linkFailure: true, timedOut: false, stillInstalled: true))
                == [.distrust, .awaitReplacement])
        #expect(machine.state == .replacing)
    }

    @Test func aLinkFailureOnAReplacedTransportDistrustsNothing() {
        var machine = executing()
        #expect(
            machine.handle(.failed(linkFailure: true, timedOut: true, stillInstalled: false))
                == [.awaitReplacement])
    }

    @Test func aRequestThatMustNotReplayDistrustsAndThrows() {
        var machine = executing(replays: false)
        #expect(
            machine.handle(.failed(linkFailure: true, timedOut: false, stillInstalled: true))
                == [.distrust, .throwFirstFailure])
        #expect(machine.state == .completed(.firstFailure))
        var raced = executing(replays: false)
        #expect(
            raced.handle(.failed(linkFailure: true, timedOut: false, stillInstalled: false))
                == [.throwFirstFailure])
    }

    @Test func theReplacementRunsTheReplay() {
        var machine = executing().after([
            .failed(linkFailure: true, timedOut: false, stillInstalled: true)
        ])
        #expect(machine.handle(.connected) == [])
        #expect(machine.state == .replaying)
    }

    @Test func aSuccessfulReplayNotesActivity() {
        var machine = replaying()
        #expect(machine.handle(.succeeded) == [.noteActivity])
        #expect(machine.state == .completed(.succeeded))
    }

    @Test func aFailedReplayThrowsItsOwnFailureAndIsNotReplayed() {
        var machine = replaying()
        #expect(
            machine.handle(.failed(linkFailure: true, timedOut: false, stillInstalled: true))
                == [.throwReplayFailure])
        #expect(machine.state == .completed(.replayFailure))
    }

    @Test func aReplayThatTimesOutThrowsTheFirstFailure() {
        var machine = replaying()
        #expect(
            machine.handle(.failed(linkFailure: true, timedOut: true, stillInstalled: true))
                == [.throwFirstFailure])
        #expect(machine.state == .completed(.firstFailure))
    }

    @Test func eventsOutOfTurnAreIgnored() {
        var waiting = RequestRecoveryMachine(replaysLinkFailures: true)
        #expect(waiting.handle(.succeeded) == [])
        #expect(waiting.handle(.failed(linkFailure: true, timedOut: false, stillInstalled: true)) == [])
        #expect(waiting.state == .awaitingConnection)
        var running = executing()
        #expect(running.handle(.connected) == [])
        #expect(running.state == .executing)
        var done = executing().after([.succeeded])
        #expect(done.handle(.connected) == [])
        #expect(done.handle(.failed(linkFailure: true, timedOut: false, stillInstalled: true)) == [])
        #expect(done.state == .completed(.succeeded))
    }
}
