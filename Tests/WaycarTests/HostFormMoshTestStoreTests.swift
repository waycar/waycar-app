import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Host form mosh test owner")
struct HostFormMoshTestStoreTests {
    private var draft: HostDraft { HostDraft(host: .fixture()) }

    private func makeStore(connector: any TransportConnector) -> HostFormMoshTestStore {
        HostFormMoshTestStore(
            connector: connector,
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()),
            knownHosts: InMemoryKnownHostsStore())
    }

    @Test func detectsAndProvesOnceThenCloses() async throws {
        let transport = ScriptedTransport()
        await transport.setMoshProbeAvailable(true)
        let gate = ScriptedTransportCallGate()
        let connector = HostProbeConnector(transport: transport, detectionGate: gate)
        let store = makeStore(connector: connector)
        let run = Task { await store.test(draft: draft, editing: nil) }
        try await waitUntil("form test reached detection gate") { await gate.entryCount > 0 }
        #expect(store.result(for: draft) == .testing)
        await store.test(draft: draft, editing: nil)
        #expect(await connector.detectionCount == 1)
        await gate.open()
        await run.value
        #expect(store.result(for: draft) == .available)
        #expect(await transport.moshProbeCount == 1)
        try await waitUntil("form test transport closed") { await transport.isClosed }
    }

    @Test func incompleteDetailsAndMissingPasswordDoNotDial() async throws {
        let connector = HostProbeConnector(transport: ScriptedTransport())
        let store = makeStore(connector: connector)
        let incomplete = HostDraft()
        await store.test(draft: incomplete, editing: nil)
        #expect(store.result(for: incomplete) == .couldNotConnect("The Host details above are incomplete."))
        var passwordDraft = draft
        passwordDraft.authMethod = .password
        await store.test(draft: passwordDraft, editing: nil)
        #expect(store.result(for: passwordDraft) == .couldNotConnect(
            "Enter the password above first — it is not stored until the Host is saved."))
        #expect(await connector.detectionCount == 0)
        #expect(await connector.connectCount == 0)
    }

    @Test func unknownKeysAreDeclinedWithoutAProof() async throws {
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: .success(ServerInfo(version: "0.9.5", protocolVersion: 22))),
            presentedKeyBlob: Data("unknown-key".utf8))
        let store = makeStore(connector: connector)
        await store.test(draft: draft, editing: nil)
        guard case .couldNotConnect = store.result(for: draft) else {
            Issue.record("the form must never auto-trust an unknown key")
            return
        }
        #expect(await connector.transports.isEmpty)
    }

    @Test func disabledHostsAreNotContacted() async throws {
        let connector = HostProbeConnector(transport: ScriptedTransport())
        let store = makeStore(connector: connector)
        var host = Host.fixture()
        host.isEnabled = false
        await store.test(draft: draft, editing: host)
        #expect(store.result(for: draft) == .idle)
        #expect(await connector.detectionCount == 0)
    }

    // B-17: a completed result describes its tested target, not an edited one.
    @Test func editingAddressClearsTheOldResult() async throws {
        let transport = ScriptedTransport()
        await transport.setMoshProbeAvailable(true)
        let store = makeStore(connector: HostProbeConnector(transport: transport))
        await store.test(draft: draft, editing: nil)
        #expect(store.result(for: draft) == .available)
        var edited = draft
        edited.address = "new.example"
        #expect(store.result(for: edited) == .idle)
        store.draftChanged(edited)
        #expect(store.result(for: draft) == .idle)
        try await waitUntil("finished form proof closed") { await transport.isClosed }
    }

    @Test func editingDuringDetectionSkipsTheOldConnection() async throws {
        let gate = ScriptedTransportCallGate()
        let connector = HostProbeConnector(transport: ScriptedTransport(), detectionGate: gate)
        let store = makeStore(connector: connector)
        let run = Task { await store.test(draft: draft, editing: nil) }
        try await waitUntil("form test reached detection gate") { await gate.entryCount > 0 }
        var edited = draft
        edited.port = "2222"
        store.draftChanged(edited)
        await gate.open()
        await run.value
        #expect(await connector.connectCount == 0)
        #expect(store.result(for: edited) == .idle)
    }

    @Test func editingDuringConnectSkipsTheOldProofAndCloses() async throws {
        let transport = ScriptedTransport()
        let gate = ScriptedTransportCallGate()
        let connector = HostProbeConnector(transport: transport, connectGate: gate)
        let store = makeStore(connector: connector)
        let run = Task { await store.test(draft: draft, editing: nil) }
        try await waitUntil("form test reached connect gate") { await gate.entryCount > 0 }
        var edited = draft
        edited.username = "other"
        store.draftChanged(edited)
        await gate.open()
        await run.value
        #expect(await transport.moshProbeCount == 0)
        #expect(store.result(for: edited) == .idle)
        try await waitUntil("retargeted form connection closed") { await transport.isClosed }
    }

    @Test func editingDuringProofRejectsItsLateResult() async throws {
        let transport = ScriptedTransport()
        await transport.setMoshProbeAvailable(true)
        let gate = ScriptedTransportCallGate()
        await transport.gateNextMoshProbe(on: gate)
        let store = makeStore(connector: HostProbeConnector(transport: transport))
        let run = Task { await store.test(draft: draft, editing: nil) }
        try await waitUntil("form test reached proof gate") { await gate.entryCount > 0 }
        var edited = draft
        edited.jumpAddress = "jump.example"
        store.draftChanged(edited)
        await gate.open()
        await run.value
        #expect(store.result(for: edited) == .idle)
        try await waitUntil("retargeted form proof closed") { await transport.isClosed }
    }
}
