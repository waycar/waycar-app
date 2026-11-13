import Foundation
import Testing

@testable import Waycar

@Suite("Pairing ceremony machine")
struct PairingCeremonyMachineTests {
    private static let now = Date(timeIntervalSince1970: 1_753_305_500)
    private static let result = PairingResult(
        address: "10.0.0.7", port: 22, username: "lin",
        hostKeyFingerprint: HostKeyFingerprint(publicKeyBlob: Data("host-public-key".utf8)))
    private static let host = Host(address: "10.0.0.7", port: 22, username: "lin", authMethod: .deviceKey)
    private static let localFailure = PairingFailure(step: .parse, message: "test failure", canRetry: false)

    private func code(bootstrap: Bool = true) throws -> PairingCode {
        let vector = try #require(PairingCodeVectorFile.shared.valid.first {
            ($0.payload.bootstrapSeed != nil) == bootstrap
        })
        return try PairingCode.decode(vector.code)
    }

    private func attempting(_ code: PairingCode) -> PairingCeremonyMachine {
        PairingCeremonyMachine().after([.parsed(code, .paste), .pair(now: Self.now)])
    }

    @Test func scanningTracksOnlyTheLatestParseFailureUntilACodeIsReady() throws {
        let code = try code()
        var machine = PairingCeremonyMachine().after([.parseFailed("first"), .parseFailed("second")])
        #expect(machine.scanFailureMessage == "second")
        #expect(machine.stage == .scan)
        #expect(machine.handle(.parsed(code, .paste)).isEmpty)
        #expect(machine.state == .ready(.init(code: code, method: .paste)))
        #expect(machine.scanFailureMessage == nil)
        #expect(machine.method == .paste)
        #expect(machine.stage == .start)
        #expect(machine.handle(.parseFailed("ignored")).isEmpty)
        #expect(machine.handle(.parsed(try self.code(bootstrap: false), .scan)).isEmpty)
        #expect(machine.pairingCode == code)
    }

    @Test func anAttemptOwnsItsStepsAndSavingWaitsForTheFingerprintWrite() throws {
        let code = try code()
        var machine = PairingCeremonyMachine().after([.parsed(code, .scan)])
        #expect(machine.handle(.pair(now: Self.now)) == [.connect(1, code)])
        #expect(machine.isPairing)
        #expect(machine.step == nil)
        #expect(machine.handle(.step(1, .verify)).isEmpty)
        #expect(machine.stage == .verify)
        #expect(machine.handle(.verified(1, Self.result)) == [.save(1, Self.result)])
        #expect(machine.isPairing)
        #expect(machine.pairedHost == nil)
        #expect(machine.handle(.step(1, .enroll)).isEmpty)
        #expect(machine.step == .enroll, "progress callbacks remain admitted while saving")
        #expect(machine.handle(.saved(1, Self.host)).isEmpty)
        #expect(machine.pairedHost == Self.host)
        #expect(!machine.isPairing)
        #expect(machine.step == nil)
        #expect(machine.handle(.pair(now: Self.now)).isEmpty)
        #expect(machine.handle(.step(1, .reach)).isEmpty)
        #expect(machine.pairedHost == Self.host)
    }

    @Test func busyAttemptsIgnoreRescanAndDuplicatePairCalls() throws {
        let code = try code()
        var machine = attempting(code)
        let connecting = machine.state
        #expect(machine.handle([.rescan, .pair(now: Self.now)]).isEmpty)
        #expect(machine.state == connecting)
        _ = machine.handle(.verified(1, Self.result))
        let saving = machine.state
        #expect(machine.handle([.rescan, .pair(now: Self.now), .cancelled(1)]).isEmpty)
        #expect(machine.state == saving)
    }

    @Test func expiryAtTheExactDeadlineNeverConnects() throws {
        let code = try code()
        let expiry = try #require(code.bootstrap?.expiresAt)
        var machine = PairingCeremonyMachine().after([.parsed(code, .scan)])
        #expect(machine.handle(.pair(now: expiry)).isEmpty)
        #expect(machine.failure?.step == .parse)
        #expect(machine.failure?.canRetry == false)
        #expect(!machine.isPairing)
    }

    @Test func verificationFailureRetainsEnrollmentAcrossRetriesAndPastBootstrapExpiry() throws {
        let code = try code()
        var machine = attempting(code)
        #expect(machine.handle(.ceremonyFailed(1, .verificationFailed(detail: "offline"))).isEmpty)
        #expect(machine.failure?.message.contains("enrolled") == true)
        #expect(machine.failure?.canRetry == true)
        let later = try #require(code.bootstrap?.expiresAt).addingTimeInterval(1)
        let retryCode = PairingCode(
            addresses: code.addresses, port: code.port, username: code.username,
            hostKeyFingerprint: code.hostKeyFingerprint, bootstrap: nil)
        #expect(machine.handle(.pair(now: later)) == [.connect(2, retryCode)])
        #expect(machine.pairingCode == code, "the displayed scan keeps its original credential")
        _ = machine.handle(.ceremonyFailed(2, .verificationFailed(detail: "still offline")))
        #expect(machine.failure?.message.contains("enrolled") == true)
        #expect(machine.failure?.canRetry == true)
        #expect(machine.handle(.pair(now: later)) == [.connect(3, retryCode)])
    }

    @Test func configOnlyVerificationFailureKeepsManualAuthorizationGuidance() throws {
        let code = try code(bootstrap: false)
        var machine = attempting(code)
        _ = machine.handle(.ceremonyFailed(1, .verificationFailed(detail: "denied")))
        #expect(machine.failure?.message.contains("authorized_keys") == true)
        #expect(machine.failure?.canRetry == false)
        // Existing public API permits this even when the UI offers only Rescan.
        #expect(machine.handle(.pair(now: Self.now)) == [.connect(2, code)])
    }

    @Test func preEnrollmentFailureRetriesTheOriginalBootstrap() throws {
        let code = try code()
        var machine = attempting(code)
        _ = machine.handle(.ceremonyFailed(1, .enrollmentFailed(detail: "offline")))
        #expect(machine.failure?.step == .enroll)
        #expect(machine.step == nil)
        #expect(machine.handle(.pair(now: Self.now)) == [.connect(2, code)])
    }

    @Test func localAndSaveFailuresEndTheAttemptWithoutPublishingAHost() throws {
        let code = try code()
        var machine = attempting(code)
        _ = machine.handle(.failed(1, Self.localFailure))
        #expect(machine.failure == Self.localFailure)
        #expect(!machine.isPairing)
        #expect(machine.handle(.pair(now: Self.now)) == [.connect(2, code)])
        _ = machine.handle(.verified(2, Self.result))
        let saveFailure = PairingFailure(step: .verify, message: "cannot save", canRetry: false)
        _ = machine.handle(.failed(2, saveFailure))
        #expect(machine.failure == saveFailure)
        #expect(machine.pairedHost == nil)
        #expect(machine.step == nil)
    }

    @Test func cancellationKeepsTheScanAndMakesEveryOldCompletionInert() throws {
        let code = try code()
        var machine = attempting(code).after([.step(1, .enroll), .cancelled(1)])
        #expect(machine.state == .ready(.init(code: code, method: .paste)))
        #expect(machine.failure == nil)
        #expect(machine.handle(.pair(now: Self.now)) == [.connect(2, code)])
        let current = machine.state
        #expect(machine.handle([
            .step(1, .verify), .ceremonyFailed(1, .bootstrapRejected),
            .failed(1, Self.localFailure), .cancelled(1), .verified(1, Self.result),
            .saved(1, Self.host),
        ]).isEmpty)
        #expect(machine.state == current)
        _ = machine.handle(.verified(2, Self.result))
        let saving = machine.state
        #expect(machine.handle([.failed(1, Self.localFailure), .saved(1, Self.host)]).isEmpty)
        #expect(machine.state == saving)
    }

    @Test func rescanClearsFailureSuccessAndProvenanceWithoutReusingTokens() throws {
        let code = try code()
        var machine = attempting(code).after([.ceremonyFailed(1, .bootstrapRejected), .rescan])
        #expect(machine.state == .scanning(failure: nil))
        #expect(machine.method == nil)
        #expect(machine.handle([.parsed(code, .scan), .pair(now: Self.now)]) == [.connect(2, code)])
        _ = machine.handle([.verified(2, Self.result), .saved(2, Self.host), .rescan])
        #expect(machine.pairingCode == nil)
        #expect(machine.pairedHost == nil)
        #expect(machine.failure == nil)
        #expect(machine.handle(.pair(now: Self.now)).isEmpty)
    }
}
