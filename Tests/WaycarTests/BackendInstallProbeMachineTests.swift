import Testing

@testable import Waycar

@Suite("Backend install probe machine")
struct BackendInstallProbeMachineTests {
    private let facts = InstallLifecycleConnector.facts
    private let missing = HostBackendPresence(herdr: false, tmuxVersion: nil)

    @Test func loadingCanBeRetriedButAReadyReadIsReused() {
        var machine = BackendInstallProbeMachine()
        #expect(machine.presentation == .loading)
        #expect(machine.handle(.load) == [.read(1)])
        #expect(machine.handle(.preflightFailed(1, "offline")).isEmpty)
        #expect(machine.presentation == .failed("offline"))
        #expect(machine.handle(.load) == [.read(2)])
        #expect(machine.handle(.preflightReady(2, facts)).isEmpty)
        #expect(machine.presentation == .ready(facts))
        #expect(machine.handle(.load).isEmpty)
    }

    @Test func anOlderReadCannotReplaceTheNewerFactsOrFailure() {
        var machine = BackendInstallProbeMachine().after([.load, .load, .preflightReady(2, facts)])
        #expect(machine.handle(.preflightFailed(1, "old failure")).isEmpty)
        #expect(machine.handle(.preflightReady(1, facts)).isEmpty)
        #expect(machine.presentation == .ready(facts))
        machine = BackendInstallProbeMachine().after([.load, .load, .preflightFailed(2, "new failure")])
        #expect(machine.handle(.preflightReady(1, facts)).isEmpty)
        #expect(machine.presentation == .failed("new failure"))
    }

    @Test func checkAgainIsSingleFlightThroughItsFollowupReadAndRetainsItsNote() {
        var machine = BackendInstallProbeMachine().after([.load, .preflightReady(1, facts)])
        #expect(machine.handle(.checkAgain) == [.detect(2)])
        #expect(machine.isChecking)
        #expect(machine.checkNote == nil)
        #expect(machine.presentation == .ready(facts))
        #expect(machine.handle(.checkAgain).isEmpty)
        #expect(machine.handle(.detected(1, .herdrOnly)).isEmpty)
        let note = "Checked just now. \(HostBackendGap(presence: missing)?.foundLabel ?? "")"
        #expect(machine.handle(.detected(2, missing)) == [.record(missing), .announce(note), .read(3)])
        #expect(machine.presentation == .loading)
        #expect(machine.isChecking)
        #expect(machine.handle(.preflightReady(1, facts)).isEmpty)
        #expect(machine.handle(.preflightReady(3, facts)).isEmpty)
        #expect(machine.isChecking)
        #expect(machine.handle(.checkEnded(1)).isEmpty)
        #expect(machine.handle(.checkEnded(2)).isEmpty)
        #expect(!machine.isChecking)
        #expect(machine.checkNote == note)
    }

    @Test func foundAndUnreachableChecksNeverRequestAReadOrStart() {
        var machine = BackendInstallProbeMachine().after([.checkAgain])
        #expect(machine.handle(.detected(1, .herdrOnly)) == [.found(.herdrOnly)])
        #expect(machine.isChecking, "the owner still has to hand off the found backend")
        #expect(machine.handle(.checkEnded(1)).isEmpty)
        #expect(!machine.isChecking)
        #expect(machine.handle(.checkAgain) == [.detect(2)])
        #expect(machine.handle(.detectionFailed(2, "offline")) == [.announce("offline")])
        #expect(machine.checkNote == "offline")
        #expect(machine.handle(.checkEnded(2)).isEmpty)
        #expect(machine.handle(.checkAgain) == [.detect(3)])
        #expect(machine.checkNote == nil)
    }

    @Test func loadMayOverlapCheckWithoutEndingItsSingleFlight() {
        var machine = BackendInstallProbeMachine().after([.checkAgain])
        #expect(machine.handle(.load) == [.read(2)])
        #expect(machine.handle(.preflightFailed(2, "offline")).isEmpty)
        #expect(machine.isChecking)
        #expect(machine.handle(.detected(1, missing)).last == .read(3))
        #expect(machine.handle(.preflightReady(3, facts)).isEmpty)
        #expect(machine.handle(.checkEnded(1)).isEmpty)
        #expect(machine.presentation == .ready(facts))
    }

    @Test func unsolicitedCompletionsAreIgnored() {
        var machine = BackendInstallProbeMachine()
        #expect(machine.handle([.preflightReady(1, facts), .preflightFailed(1, "late"), .detected(1, missing), .detectionFailed(1, "late"), .checkEnded(1)]).isEmpty)
        #expect(machine.state == .idle(.unread, note: nil))
    }
}
