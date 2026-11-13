import Foundation
import Testing

@testable import Waycar

/// `MoshEligibilityMachine`: the Console's mosh eligibility per Host
/// (MOSH-02). Owner suites: `ConsoleMoshProbeTests`,
/// `MoshAvailabilityPerNetworkTests`, `MoshFastPathEdgeTests`.
@Suite("Mosh eligibility machine")
struct MoshEligibilityMachineTests {
    typealias Machine = MoshEligibilityMachine

    private let host = UUID()
    private let otherHost = UUID()
    private var probing: Machine {
        Machine().after([.reconcile(host, generation: 1, remembered: nil, canProbe: true)])
    }
    private var available: Machine {
        probing.after([.connectProbeFinished(host, generation: 1, available: true, cancelled: false)])
    }

    // MARK: Reading

    @Test func nothingIsKnownAtFirst() {
        let machine = Machine()
        #expect(machine.knownAvailability(of: host) == nil)
        #expect(machine.outcomes.isEmpty)
        #expect(!machine.isReprobing(host))
    }

    @Test func theUsersSSHChoiceWinsOverWhatIsKnown() {
        var machine = available
        #expect(machine.knownAvailability(of: host) == true)
        _ = machine.handle(.invalidate(host, generation: 1, cause: .userChoseSSH))
        #expect(machine.knownAvailability(of: host) == false)
    }

    // MARK: Reconcile and connect probes

    @Test func anUnsettledGenerationIsProbed() {
        var machine = Machine()
        #expect(
            machine.handle(.reconcile(host, generation: 1, remembered: nil, canProbe: true))
                == [.startProbe(host, .connect(generation: 1))])
        #expect(machine.isSettled(host, generation: 1))
        #expect(machine.handle(.reconcile(host, generation: 1, remembered: nil, canProbe: true)).isEmpty)
    }

    @Test func aGenerationThatCannotBeProbedYetStaysUnsettled() {
        var machine = Machine()
        #expect(machine.handle(.reconcile(host, generation: 1, remembered: nil, canProbe: false)).isEmpty)
        #expect(!machine.isSettled(host, generation: 1))
        #expect(machine.state[host] == nil)
    }

    @Test func theUsersSSHChoiceIsNeverProbed() {
        var machine = Machine().after([.invalidate(host, generation: 0, cause: .userChoseSSH)])
        #expect(machine.handle(.reconcile(host, generation: 1, remembered: nil, canProbe: true)).isEmpty)
        #expect(!machine.isSettled(host, generation: 1))
    }

    @Test func aRememberedOutcomeAnswersWithoutAProbe() {
        var machine = Machine()
        #expect(machine.handle(.reconcile(host, generation: 1, remembered: true, canProbe: true)).isEmpty)
        #expect(machine.outcome(of: host) == Machine.Outcome(generation: 1, available: true))
        #expect(machine.isSettled(host, generation: 1))
    }

    @Test func aRememberedOutcomeDoesNotLiftAnInvalidation() {
        var machine = Machine().after([.invalidate(host, generation: 1, cause: .automaticFallback)])
        _ = machine.handle(.reconcile(host, generation: 1, remembered: true, canProbe: true))
        #expect(machine.outcome(of: host) == Machine.Outcome(generation: 1, available: false))
        #expect(machine.isSettled(host, generation: 1))
        var chosen = Machine().after([.invalidate(host, generation: 0, cause: .userChoseSSH)])
        _ = chosen.handle(.reconcile(host, generation: 1, remembered: true, canProbe: true))
        #expect(chosen.isSettled(host, generation: 1))
        #expect(chosen.knownAvailability(of: host) == false)
    }

    @Test func anAvailableConnectProbeUpgradesConnectingAttaches() {
        var machine = probing
        #expect(
            machine.handle(.connectProbeFinished(host, generation: 1, available: true, cancelled: false))
                == [.upgrade(host, connectingOnly: true)])
        #expect(machine.outcome(of: host) == Machine.Outcome(generation: 1, available: true))
        var failed = probing
        #expect(failed.handle(.connectProbeFinished(host, generation: 1, available: false, cancelled: false)).isEmpty)
        #expect(failed.outcome(of: host) == Machine.Outcome(generation: 1, available: false))
    }

    @Test func aDiscardedAnswerGivesTheGenerationBackUnlessCancelled() {
        var machine = probing
        #expect(machine.handle(.connectProbeFinished(host, generation: 1, available: nil, cancelled: false)).isEmpty)
        #expect(!machine.isSettled(host, generation: 1))
        var cancelled = probing
        _ = cancelled.handle(.connectProbeFinished(host, generation: 1, available: nil, cancelled: true))
        #expect(cancelled.isSettled(host, generation: 1))
        var moved = probing.after([.reconcile(host, generation: 2, remembered: nil, canProbe: true)])
        _ = moved.handle(.connectProbeFinished(host, generation: 1, available: nil, cancelled: false))
        #expect(moved.isSettled(host, generation: 2), "only its own generation is given back")
    }

    @Test func anAnswerForAnOlderGenerationIsDropped() {
        var machine = probing.after([
            .reconcile(host, generation: 2, remembered: nil, canProbe: true),
            .connectProbeFinished(host, generation: 2, available: false, cancelled: false),
        ])
        #expect(machine.handle(.connectProbeFinished(host, generation: 1, available: true, cancelled: false)).isEmpty)
        #expect(machine.outcome(of: host) == Machine.Outcome(generation: 2, available: false))
    }

    @Test func anAnswerForAnInvalidatedGenerationIsDropped() {
        var machine = probing.after([.invalidate(host, generation: 1, cause: .automaticFallback)])
        #expect(machine.handle(.connectProbeFinished(host, generation: 1, available: true, cancelled: false)).isEmpty)
        #expect(machine.outcome(of: host) == Machine.Outcome(generation: 1, available: false))
    }

    // MARK: Invalidation and proofs

    @Test func anInvalidationMarksTheGenerationUnavailable() {
        var machine = available
        #expect(machine.handle(.invalidate(host, generation: 1, cause: .automaticFallback)).isEmpty)
        #expect(machine.outcome(of: host) == Machine.Outcome(generation: 1, available: false))
        #expect(machine.invalidation(of: host) == Machine.Invalidation(generation: 1, cause: .automaticFallback))
    }

    @Test func anAutomaticFallbackNeverDowngradesTheUsersChoice() {
        var machine = Machine().after([.invalidate(host, generation: 1, cause: .userChoseSSH)])
        _ = machine.handle(.invalidate(host, generation: 2, cause: .automaticFallback))
        #expect(machine.invalidation(of: host) == Machine.Invalidation(generation: 1, cause: .userChoseSSH))
        #expect(machine.outcome(of: host) == Machine.Outcome(generation: 2, available: false))
    }

    @Test func aProofIsRecordedUnlessItWouldLiftAnInvalidation() {
        var machine = Machine()
        _ = machine.handle(.recordOutcome(host, generation: 1, available: true))
        #expect(machine.outcome(of: host) == Machine.Outcome(generation: 1, available: true))
        _ = machine.handle(.invalidate(host, generation: 1, cause: .automaticFallback))
        _ = machine.handle(.recordOutcome(host, generation: 1, available: true))
        #expect(machine.outcome(of: host) == Machine.Outcome(generation: 1, available: false))
        _ = machine.handle(.recordOutcome(host, generation: 2, available: true))
        #expect(machine.outcome(of: host) == Machine.Outcome(generation: 2, available: true), "a later generation's proof counts")
    }

    // MARK: Capsule re-probe

    @Test func aReprobeClearsTheInvalidationAndClaimsTheGeneration() {
        var machine = available.after([.invalidate(host, generation: 1, cause: .userChoseSSH)])
        #expect(
            machine.handle(.reprobe(host, generation: 1))
                == [.startProbe(host, .reprobe(token: 1, generation: 1))])
        #expect(machine.isReprobing(host))
        #expect(machine.invalidation(of: host) == nil)
        #expect(machine.isSettled(host, generation: 1))
        #expect(machine.handle(.reprobe(host, generation: 1)).isEmpty, "a second tap is a no-op")
    }

    @Test func aReprobeAnswerUpgradesEveryAttachAndEndsTesting() {
        var machine = Machine().after([.reprobe(host, generation: 1)])
        #expect(
            machine.handle(.reprobeEnded(host, token: 1, generation: 1, available: true))
                == [.upgrade(host, connectingOnly: false)])
        #expect(!machine.isReprobing(host))
        #expect(machine.outcome(of: host) == Machine.Outcome(generation: 1, available: true))
        var unanswered = Machine().after([.reprobe(host, generation: 1)])
        #expect(unanswered.handle(.reprobeEnded(host, token: 1, generation: 1, available: nil)).isEmpty)
        #expect(!unanswered.isReprobing(host))
        #expect(unanswered.outcome(of: host) == nil)
    }

    @Test func anInvalidationDuringAReprobeStillWins() {
        var machine = Machine().after([
            .reprobe(host, generation: 1), .invalidate(host, generation: 1, cause: .automaticFallback),
        ])
        #expect(machine.handle(.reprobeEnded(host, token: 1, generation: 1, available: true)).isEmpty)
        #expect(machine.outcome(of: host) == Machine.Outcome(generation: 1, available: false))
        #expect(!machine.isReprobing(host))
    }

    @Test func aStaleReprobeLeavesTheNewOne() {
        var machine = Machine().after([
            .reprobe(host, generation: 1), .hostChanged(host, keepsTarget: true), .reprobe(host, generation: 1),
        ])
        #expect(machine.handle(.reprobeEnded(host, token: 1, generation: 1, available: nil)).isEmpty)
        #expect(machine.isReprobing(host))
        _ = machine.handle(.reprobeEnded(host, token: 2, generation: 1, available: false))
        #expect(!machine.isReprobing(host))
    }

    // MARK: Network and Host changes

    @Test func aNewNetworkForgetsAllButTheUsersChoice() {
        var machine = available.after([
            .reconcile(otherHost, generation: 1, remembered: true, canProbe: true),
            .invalidate(otherHost, generation: 1, cause: .userChoseSSH),
            .reprobe(host, generation: 1),
        ])
        #expect(machine.handle(.networkChanged(hasPath: true)) == [.cancelAllProbes, .reconcileAll])
        #expect(machine.outcome(of: host) == nil)
        #expect(!machine.isSettled(host, generation: 1))
        #expect(machine.isReprobing(host), "the re-probe ends on its own")
        #expect(machine.outcome(of: otherHost) == Machine.Outcome(generation: 1, available: false))
        #expect(machine.isSettled(otherHost, generation: 1))
        #expect(machine.invalidation(of: otherHost)?.cause == .userChoseSSH)
    }

    @Test func losingThePathOnlyCancelsProbes() {
        var machine = available
        #expect(machine.handle(.networkChanged(hasPath: false)) == [.cancelAllProbes])
        #expect(machine.outcome(of: host) == Machine.Outcome(generation: 1, available: true))
    }

    @Test func aChangedHostForgetsItsConnectionFacts() {
        var renamed = available.after([.invalidate(host, generation: 1, cause: .userChoseSSH), .reprobe(host, generation: 1)])
        _ = renamed.handle(.invalidate(host, generation: 1, cause: .userChoseSSH))
        #expect(renamed.handle(.hostChanged(host, keepsTarget: true)) == [.cancelProbe(host)])
        #expect(renamed.outcome(of: host) == nil)
        #expect(!renamed.isReprobing(host))
        #expect(renamed.invalidation(of: host)?.cause == .userChoseSSH, "a rename keeps the user's choice")
        var retargeted = available.after([.invalidate(host, generation: 1, cause: .userChoseSSH)])
        _ = retargeted.handle(.hostChanged(host, keepsTarget: false))
        #expect(retargeted.state[host] == nil)
    }

    @Test func theEndOfTheHerdrProjectionKeepsTheInvalidation() {
        var machine = available.after([.invalidate(host, generation: 1, cause: .automaticFallback), .reprobe(host, generation: 1)])
        _ = machine.handle(.invalidate(host, generation: 1, cause: .automaticFallback))
        #expect(machine.handle(.primaryProjectionEnded(host)).isEmpty)
        #expect(machine.outcome(of: host) == nil)
        #expect(!machine.isReprobing(host))
        #expect(!machine.isSettled(host, generation: 1))
        #expect(machine.invalidation(of: host) == Machine.Invalidation(generation: 1, cause: .automaticFallback))
    }
}
