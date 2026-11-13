import Foundation
import Testing

@testable import Waycar

/// Public-API characterization of the scan owner's admission and cancellation
/// rules. The existing PairingScanStoreTests pin the ceremony's failure copy,
/// bootstrap-less retries, TTL and verified-before-persistence behavior.
@MainActor
@Suite("Pairing scan lifecycle")
struct PairingScanLifecycleTests {
    private struct Environment {
        let store: PairingScanStore
        let catalog: HostStore
        let connector: SuspendedPairingConnector
        let cleanup: () -> Void
    }

    private func makeEnvironment() throws -> Environment {
        let suite = "pairing-lifecycle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let secrets = InMemorySecretStore()
        let catalog = HostStore(defaults: defaults, secrets: secrets)
        let connector = SuspendedPairingConnector()
        let store = PairingScanStore(
            catalog: catalog, connector: connector, knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: secrets), secrets: secrets))
        return Environment(
            store: store, catalog: catalog, connector: connector,
            cleanup: { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func anInFlightAttemptRejectsPairRescanAndFurtherScans() async throws {
        let env = try makeEnvironment()
        defer { env.cleanup() }
        let code = PairingCodeVectorFile.shared.valid[0].code
        env.store.submit(scannedCode: code, method: .paste)
        let parsed = env.store.pairingCode
        let attempt = Task { await env.store.pair() }
        try await waitUntil { await env.connector.calls == 1 }

        await env.store.pair()
        env.store.rescan()
        env.store.submit(scannedCode: "not a code")

        #expect(env.store.isPairing)
        #expect(env.store.pairingCode == parsed)
        #expect(env.store.method == .paste)
        #expect(env.store.scanFailureMessage == nil)
        #expect(env.catalog.hosts.isEmpty)
        #expect(await env.connector.calls == 1)
        await env.connector.finish(.cancelled)
        await attempt.value
    }

    @Test func cancellationReturnsToTheSameCodeWithoutAFailureAndAllowsRetry() async throws {
        let env = try makeEnvironment()
        defer { env.cleanup() }
        env.store.submit(scannedCode: PairingCodeVectorFile.shared.valid[0].code)
        let parsed = env.store.pairingCode
        let first = Task { await env.store.pair() }
        try await waitUntil { await env.connector.calls == 1 }
        await env.connector.finish(.cancelled)
        await first.value

        #expect(!env.store.isPairing)
        #expect(env.store.step == nil)
        #expect(env.store.failure == nil)
        #expect(env.store.pairingCode == parsed)
        #expect(env.store.stage == .start)
        #expect(env.catalog.hosts.isEmpty)
        let retry = Task { await env.store.pair() }
        try await waitUntil { await env.connector.calls == 2 }
        await env.connector.finish(.cancelled)
        await retry.value
    }

    /// canRetry controls the recovery button, not the public method's admission.
    /// The conversion must not silently add a new guard to pair().
    @Test func aNonretryableFailureStillAllowsADirectPairCall() async throws {
        let env = try makeEnvironment()
        defer { env.cleanup() }
        env.store.submit(scannedCode: PairingCodeVectorFile.shared.valid[0].code)
        let first = Task { await env.store.pair() }
        try await waitUntil { await env.connector.calls == 1 }
        await env.connector.finish(.failed(.bootstrapRejected))
        await first.value
        #expect(try #require(env.store.failure).canRetry == false)

        let retry = Task { await env.store.pair() }
        try await waitUntil { await env.connector.calls == 2 }
        #expect(env.store.failure == nil)
        await env.connector.finish(.cancelled)
        await retry.value
    }
}

private actor SuspendedPairingConnector: PairingConnector {
    enum Outcome: Sendable {
        case cancelled
        case failed(PairingCeremonyError)
    }

    private(set) var calls = 0
    private var answer: CheckedContinuation<Outcome, Never>?

    func pair(
        code: PairingCode, deviceKey: DeviceKey,
        onStep: @escaping @Sendable (PairingStep) -> Void
    ) async throws -> PairingResult {
        let outcome = await withCheckedContinuation { continuation in
            answer = continuation
            calls += 1
        }
        switch outcome {
        case .cancelled: throw CancellationError()
        case .failed(let error): throw error
        }
    }

    func finish(_ outcome: Outcome) {
        let continuation = answer
        answer = nil
        continuation?.resume(returning: outcome)
    }
}
