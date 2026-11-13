import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Install panel probe ordering")
struct BackendInstallPanelProbeTests {
    @Test(arguments: [false, true])
    func olderPreflightCannotOverwriteTheNewerAnswer(olderFails: Bool) async throws {
        let connector = PanelProbeConnector(olderFails: olderFails)
        let store = makePanel(connector)
        let older = Task { await store.loadPreflight() }
        try await waitUntil("the older preflight starts") { await connector.older.entryCount == 1 }
        await store.loadPreflight()
        #expect(store.preflight == .ready(PanelProbeConnector.newerFacts))
        await connector.older.open()
        await older.value
        #expect(store.preflight == .ready(PanelProbeConnector.newerFacts))
    }

    @Test func checkAgainRefreshCannotBeOverwrittenByTheOpeningProbe() async throws {
        let connector = PanelProbeConnector(olderFails: false)
        let store = makePanel(connector)
        let opening = Task { await store.loadPreflight() }
        try await waitUntil("the opening probe starts") { await connector.older.entryCount == 1 }
        await store.checkAgain()
        #expect(store.preflight == .ready(PanelProbeConnector.newerFacts))
        #expect(!store.isChecking)
        await connector.older.open()
        await opening.value
        #expect(store.preflight == .ready(PanelProbeConnector.newerFacts))
    }

    private func makePanel(_ connector: PanelProbeConnector) -> BackendInstallPanelStore {
        BackendInstallPanelStore(
            host: .fixture(), center: BackendInstallCenter(connector: connector), presence: { nil },
            recordPresence: { _ in }, foundBackend: { _ in },
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()), secrets: InMemorySecretStore()),
            knownHosts: InMemoryKnownHostsStore())
    }
}

private actor PanelProbeConnector: TransportConnector {
    static let newerFacts = HostInstallPreflight(
        operatingSystem: "Darwin", architecture: "arm64", isAndroid: false, hasCurl: true,
        packageManagers: [.brew], isRoot: false, sudoWithoutPassword: false)
    let older = ScriptedTransportCallGate()
    let olderFails: Bool
    private var reads = 0

    init(olderFails: Bool) { self.olderFails = olderFails }

    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        throw TransportError.timedOut
    }

    func detectBackends(settings: SSHTransportSettings) async throws -> HostBackendPresence {
        HostBackendPresence(herdr: false, tmuxVersion: nil)
    }

    func preflightInstall(settings: SSHTransportSettings) async throws -> HostInstallPreflight {
        reads += 1
        if reads == 1 {
            await older.waitUntilOpen()
            if olderFails { throw TransportError.timedOut }
            return InstallLifecycleConnector.facts
        }
        return Self.newerFacts
    }
}
