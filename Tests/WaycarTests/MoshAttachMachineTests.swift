import Testing

@testable import Waycar

/// `MoshAttachMachine`: one mosh attach session's start, first contact,
/// ending and link (MOSH-01). The owner suite is `MoshAttachSessionTests`.
@Suite("Mosh attach machine")
struct MoshAttachMachineTests {
    typealias Machine = MoshAttachMachine

    private let created = Machine().after([.sessionCreated])
    private var started: Machine { created.after([.startSucceeded]) }
    private var answered: Machine { started.after([.runReady, .firstHostOp]) }

    // MARK: Start

    @Test func aCreatedSessionArmsTheWatchdog() {
        var machine = Machine()
        #expect(machine.handle(.sessionCreated) == [.armWatchdog(token: 1)])
        #expect(machine.state.watchdog == 1)
        #expect(machine.state.start == .starting)
    }

    @Test func anEndBeforeTheSessionSkipsTheRun() {
        var machine = Machine().after([.endRequested(abandoning: false)])
        #expect(machine.handle(.sessionCreated) == [.skipRun])
        #expect(machine.state.watchdog == nil)
    }

    @Test func theStartSettlesOnceAsStarted() {
        var machine = created
        #expect(machine.handle(.startSucceeded) == [.reportStart(.started)])
        #expect(machine.state.start == .started)
    }

    @Test func aStartThatFailsIsReportedAndLeavesThePhase() {
        var machine = created
        #expect(machine.handle(.startFailed) == [.reportStart(.failed)])
        #expect(machine.state.start == .starting)
    }

    @Test func aStartAfterItWasAbandonedShutsItsSessionDown() {
        var machine = created.after([.endRequested(abandoning: true)])
        #expect(machine.handle(.startSucceeded) == [.shutdownStartedSession])
        #expect(machine.state.start == .abandoned)
    }

    @Test func theRunStartsTheRelayAndPumpUnlessEnded() {
        var machine = started
        #expect(machine.handle(.runReady) == [.startRelayAndPump])
        var ended = started.after([.endRequested(abandoning: false)])
        #expect(ended.handle(.runReady).isEmpty)
    }

    // MARK: Ending

    @Test func anEndDuringTheStartAbandonsItAndStopsTheSession() {
        var machine = created
        #expect(
            machine.handle(.endRequested(abandoning: false))
                == [.cancelWatchdog, .reportStart(.abandoned), .stopSession(abandoning: false)])
        #expect(machine.state.endRequested)
        #expect(machine.state.start == .abandoned)
    }

    @Test func anEndOfAStartedSessionStopsIt() {
        var handshake = started
        #expect(handshake.handle(.endRequested(abandoning: false)) == [.cancelWatchdog, .stopSession(abandoning: false)])
        var abandoning = started
        #expect(abandoning.handle(.endRequested(abandoning: true)) == [.cancelWatchdog, .stopSession(abandoning: true)])
    }

    // MARK: First contact

    @Test func theFirstServerStateIsAnAnswer() {
        var machine = started.after([.runReady])
        #expect(machine.handle(.firstHostOp) == [.settleFirstContact(.answered), .cancelWatchdog])
        #expect(machine.state.firstContact == .answered)
        #expect(machine.hostAnswered)
    }

    @Test func aWatchdogDuringTheStartAbandonsItThenTimesOut() {
        var machine = created
        #expect(machine.handle(.watchdogElapsed(token: 1)) == [.timeOutFirstContact(abandonsStart: true)])
        #expect(machine.state.start == .abandoned)
        #expect(
            machine.handle(.firstContactTimedOut(abandonsStart: true))
                == [.settleFirstContact(.timedOut), .failFirstContact, .reportStart(.abandoned), .abandonSession])
        #expect(machine.state.firstContact == .timedOut)
    }

    @Test func aWatchdogAfterTheStartTimesOutWithoutReportingIt() {
        var machine = started
        #expect(machine.handle(.watchdogElapsed(token: 1)) == [.timeOutFirstContact(abandonsStart: false)])
        #expect(machine.state.start == .started)
        #expect(
            machine.handle(.firstContactTimedOut(abandonsStart: false))
                == [.settleFirstContact(.timedOut), .failFirstContact, .abandonSession])
    }

    @Test func aWatchdogAfterAnAnswerOrAnEndDoesNothing() {
        var afterAnswer = answered
        #expect(afterAnswer.handle(.watchdogElapsed(token: 1)).isEmpty)
        var afterEnd = created.after([.endRequested(abandoning: false)])
        #expect(afterEnd.handle(.watchdogElapsed(token: 1)).isEmpty)
        var unknown = created
        #expect(unknown.handle(.watchdogElapsed(token: 2)).isEmpty)
    }

    /// The pre-existing window between the watchdog's two steps: an answer
    /// settled first contact, so the timeout fails nothing.
    @Test func anAnswerBetweenTheWatchdogsStepsWins() {
        var machine = started.after([.watchdogElapsed(token: 1), .runReady, .firstHostOp])
        #expect(machine.handle(.firstContactTimedOut(abandonsStart: false)).isEmpty)
        #expect(machine.state.firstContact == .answered)
    }

    /// A disarmed watchdog already past its sleep still decides by the
    /// state, as before: the run's end has not settled first contact yet.
    @Test func aDisarmedWatchdogPastItsSleepStillDecidesByTheState() {
        var machine = created.after([.startFailed, .disarmWatchdog])
        #expect(machine.handle(.watchdogElapsed(token: 1)) == [.timeOutFirstContact(abandonsStart: true)])
    }

    @Test func aLaterServerStateSettlesNothingAgain() {
        var timedOut = started.after([.watchdogElapsed(token: 1), .firstContactTimedOut(abandonsStart: false)])
        #expect(timedOut.handle(.firstHostOp) == [.cancelWatchdog])
        #expect(timedOut.state.firstContact == .timedOut)
    }

    @Test func theRunsEndSettlesAPendingFirstContactAsEnded() {
        var machine = started
        #expect(machine.handle(.runEnded) == [.settleFirstContact(.ended)])
        #expect(machine.state.firstContact == .ended)
        var settled = answered
        #expect(settled.handle(.runEnded).isEmpty)
        #expect(settled.state.firstContact == .answered)
    }

    @Test func disarmingCancelsTheWatchdogsSleep() {
        var machine = started
        #expect(machine.handle(.disarmWatchdog) == [.cancelWatchdog])
        #expect(machine.state.watchdog == 1)
    }

    // MARK: Link

    @Test func connectivityIsRelayedOnChangeUntilTheLinkEnds() {
        var machine = answered
        #expect(machine.handle(.connectivity(.connected)) == [.relayConnectivity(.connected)])
        #expect(machine.handle(.connectivity(.connected)).isEmpty)
        #expect(machine.handle(.connectivity(.stalled)) == [.relayConnectivity(.stalled)])
        #expect(machine.handle(.linkEnded) == [.endLink])
        #expect(machine.state.linkEnded)
        #expect(machine.handle(.connectivity(.connected)).isEmpty)
        #expect(machine.state.connectivity == .stalled)
    }
}
