import CryptoKit
import Foundation
import Testing

@testable import Waycar

/// Owner characterization: these use only the pre-conversion public APIs.
@MainActor
@Suite("Install lifecycle ownership")
struct BackendInstallLifecycleTests {
    private let host = Host.fixture()
    private var settings: SSHTransportSettings {
        SSHTransportSettings(
            host: "host.example", port: 22, username: "dev",
            credentials: .ed25519(Curve25519.Signing.PrivateKey()),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in false },
            socket: .defaultSession)
    }

    private func panel(_ center: BackendInstallCenter) -> BackendInstallPanelStore {
        BackendInstallPanelStore(
            host: host, center: center, presence: { nil }, recordPresence: { _ in },
            foundBackend: { _ in }, credentials: credentials(), knownHosts: InMemoryKnownHostsStore())
    }

    private func credentials() -> HostCredentialsProvider {
        HostCredentialsProvider(
            deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
            rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()), secrets: InMemorySecretStore())
    }

    @Test func runtimeStartKeepsTheRunCheckingAndPublishesOnlyAfterItEnds() async throws {
        let connector = InstallLifecycleConnector()
        let center = BackendInstallCenter(connector: connector)
        var reported = false
        center.onOutcome = { id, outcome in
            #expect(id == self.host.id)
            #expect(center.runs[id] == nil)
            #expect(center.outcomes[id] == outcome)
            reported = true
        }
        center.start(BackendInstallPlan(target: .herdr), on: host.id, settings: settings)
        try await waitUntil("the runtime start is reached") { await connector.startGate.entryCount == 1 }
        #expect(center.runs[host.id]?.phase == .checking)
        #expect(center.outcomes[host.id] == nil)
        #expect(!reported)
        #expect(!center.start(BackendInstallPlan(target: .core), on: host.id, settings: settings))
        await connector.startGate.open()
        try await waitUntil("the outcome is published") { reported }
    }

    @Test func aReadyPreflightIsReusedOnReopen() async {
        let connector = InstallLifecycleConnector()
        let center = BackendInstallCenter(connector: connector)
        let store = panel(center)
        await connector.preflightGate.open()
        await store.loadPreflight()
        await store.loadPreflight()
        #expect(await connector.preflightReads == 1)
        #expect(store.preflight == .ready(InstallLifecycleConnector.facts))
    }

    @Test func updateKeepsItsHostLockWhileVerifyingAndCallbackCannotStartAnotherRun() async throws {
        let connector = InstallLifecycleConnector()
        let activity = WaycarPluginUpdateActivity()
        var store: WaycarPluginUpdateStore?
        var notified = false
        store = WaycarPluginUpdateStore(
            host: host, detection: .notInstalled, connector: connector, credentials: credentials(),
            onUpdated: { _ in
                #expect(store?.isRunning == true)
                #expect(activity.runningHosts == [self.host.id])
                store?.start()
                notified = true
            }, activity: activity)
        store?.start()
        try await waitUntil("verification starts") { await connector.detectionGate.entryCount == 1 }
        #expect(store?.phase == .running(latestLine: "installing"))
        #expect(store?.isRunning == true)
        #expect(activity.runningHosts == [host.id])
        store?.start()
        #expect(await connector.updateRuns == 1)
        await connector.detectionGate.open()
        try await waitUntil("the update completes") { notified && store?.isRunning == false }
        #expect(await connector.updateRuns == 1)
        #expect(activity.runningHosts.isEmpty)
        store = nil
    }
}

/// Gates belong to the test, not the lifecycle. No SSH or wall-clock sleeps.
actor InstallLifecycleConnector: TransportConnector {
    static let facts = HostInstallPreflight(
        operatingSystem: "Linux", architecture: "x86_64", isAndroid: false, hasCurl: true,
        packageManagers: [.aptGet], isRoot: false, sudoWithoutPassword: true)
    let startGate = ScriptedTransportCallGate()
    let detectionGate = ScriptedTransportCallGate()
    let preflightGate = ScriptedTransportCallGate()
    private(set) var preflightReads = 0
    private(set) var updateRuns = 0

    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        throw TransportError.timedOut
    }

    func preflightInstall(settings: SSHTransportSettings) async throws -> HostInstallPreflight {
        preflightReads += 1
        await preflightGate.waitUntilOpen()
        return Self.facts
    }

    func runBackendInstall(
        settings: SSHTransportSettings, plan: BackendInstallPlan,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> BackendInstallRun {
        // This test needs detection immediately, then a held runtime start.
        await detectionGate.open()
        return BackendInstallRun(exitStatus: 0, reason: .ok, output: [])
    }

    func detectBackends(settings: SSHTransportSettings) async throws -> HostBackendPresence {
        await detectionGate.waitUntilOpen()
        return .herdrOnly
    }

    func wakeHerdr(settings: SSHTransportSettings) async throws {
        await startGate.waitUntilOpen()
    }

    func updateWaycarPlugin(
        settings: SSHTransportSettings, request: WaycarPluginUpdateRequest,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> WaycarPluginUpdateResult {
        updateRuns += 1
        progress("installing")
        return WaycarPluginUpdateResult(
            installedVersion: nil, warnings: [], codexHooksNeedReview: false, output: [])
    }
}
