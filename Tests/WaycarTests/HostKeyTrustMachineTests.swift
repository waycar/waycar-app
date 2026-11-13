import Foundation
import Testing

@testable import Waycar

@Suite("Host key trust machine")
struct HostKeyTrustMachineTests {
    private let candidate = HostKeyCandidate(
        host: "host.example", port: 22,
        fingerprint: HostKeyFingerprint(publicKeyBlob: Data("first".utf8)))
    private let replacement = HostKeyReplacement(
        known: HostKeyFingerprint(publicKeyBlob: Data("old".utf8)),
        presented: HostKeyFingerprint(publicKeyBlob: Data("new".utf8)))

    @Test func aQuestionWaitsForTheVerdictAndResolvesItsToken() {
        var machine = HostKeyTrustMachine()
        #expect(machine.handle(.asked(candidate, hostEnabled: true)) == [.wait(1)])
        #expect(machine.pendingCandidate == candidate)
        #expect(machine.handle(.answered(trusted: true)) == [.resolve(1, trusted: true)])
        #expect(machine.pendingCandidate == nil)
        #expect(machine.state == .init())
        #expect(machine.handle(.asked(candidate, hostEnabled: true)) == [.wait(2)])
        #expect(machine.handle(.answered(trusted: false)) == [.resolve(2, trusted: false)])
    }

    @Test func aDisabledHostOrASecondQuestionIsDeclinedAtOnce() {
        var machine = HostKeyTrustMachine()
        #expect(machine.handle(.asked(candidate, hostEnabled: false)) == [.decline])
        #expect(machine.state.question == .none)
        _ = machine.handle(.asked(candidate, hostEnabled: true))
        let other = HostKeyCandidate(
            host: "jump.example", port: 2222, fingerprint: candidate.fingerprint)
        #expect(machine.handle(.asked(other, hostEnabled: true)) == [.decline])
        #expect(machine.pendingCandidate == candidate)
    }

    /// B-37: a cancel declines only the question its probe holds.
    @Test func aCancelDeclinesOnlyItsOwnQuestion() {
        var machine = HostKeyTrustMachine().after([.asked(candidate, hostEnabled: true)])
        #expect(machine.handle(.cancelled(1)) == [.resolve(1, trusted: false)])
        #expect(machine.state == .init())
        #expect(machine.handle(.cancelled(1)).isEmpty)
        _ = machine.handle(.asked(candidate, hostEnabled: true))
        #expect(machine.handle(.cancelled(1)).isEmpty)
        #expect(machine.pendingCandidate == candidate)
        #expect(machine.handle(.cancelled(2)) == [.resolve(2, trusted: false)])
    }

    @Test func anAnswerWithNoQuestionDoesNothing() {
        var machine = HostKeyTrustMachine()
        #expect(machine.handle(.answered(trusted: true)).isEmpty)
        #expect(machine.state == .init())
    }

    @Test func checksOfferAndClearAReplacement() {
        var machine = HostKeyTrustMachine()
        #expect(machine.handle(.mismatched(replacement)).isEmpty)
        #expect(machine.offeredReplacement == replacement)
        #expect(machine.handle(.checksStarted).isEmpty)
        #expect(machine.offeredReplacement == nil)
    }

    @Test func confirmingWritesThePresentedKeyThenClearsAndRerunsChecks() {
        var machine = HostKeyTrustMachine().after([.mismatched(replacement)])
        #expect(
            machine.handle(.replacementConfirmed(hostEnabled: true, checksRunning: false))
                == [.writePin(1, replacement.presented)])
        #expect(machine.state.writes == [1])
        #expect(machine.offeredReplacement == replacement)
        #expect(machine.handle(.pinWritten(1)) == [.runChecks])
        #expect(machine.state == .init())
        #expect(machine.handle(.pinWritten(1)).isEmpty)
    }

    @Test func confirmingIsRefusedWithoutAnOfferWhileChecksRunOrWhileTheHostIsOff() {
        var none = HostKeyTrustMachine()
        #expect(none.handle(.replacementConfirmed(hostEnabled: true, checksRunning: false)).isEmpty)
        var offered = HostKeyTrustMachine().after([.mismatched(replacement)])
        #expect(offered.handle(.replacementConfirmed(hostEnabled: true, checksRunning: true)).isEmpty)
        #expect(offered.handle(.replacementConfirmed(hostEnabled: false, checksRunning: false)).isEmpty)
        #expect(offered.state.writes.isEmpty)
        #expect(offered.offeredReplacement == replacement)
    }

    /// Checks may run during the write; whatever they offered, the landed
    /// write clears it and reruns.
    @Test func checksDuringTheWriteDoNotStopItsClearAndRerun() {
        var machine = HostKeyTrustMachine().after([
            .mismatched(replacement), .replacementConfirmed(hostEnabled: true, checksRunning: false),
            .checksStarted,
        ])
        #expect(machine.offeredReplacement == nil)
        _ = machine.handle(.mismatched(replacement))
        #expect(machine.handle(.pinWritten(1)) == [.runChecks])
        #expect(machine.offeredReplacement == nil)
    }

    @Test func aQuestionAndAReplacementWriteStaySeparate() {
        var machine = HostKeyTrustMachine().after([
            .mismatched(replacement), .asked(candidate, hostEnabled: true),
        ])
        #expect(
            machine.handle(.replacementConfirmed(hostEnabled: true, checksRunning: false))
                == [.writePin(2, replacement.presented)])
        #expect(machine.handle(.pinWritten(2)) == [.runChecks])
        #expect(machine.pendingCandidate == candidate)
        #expect(machine.handle(.asked(candidate, hostEnabled: true)) == [.decline])
        #expect(machine.handle(.answered(trusted: true)) == [.resolve(1, trusted: true)])
    }
}
