import Foundation
import Testing

@testable import Waycar

/// Characterization through the existing owner API; no remote service runs.
@MainActor
@Suite("Host onboarding lifecycles")
struct HostOnboardingLifecycleTests {
    @Test func moshTestIsSingleFlightAndClosesItsPrivateTransport() async throws {
        let transport = ScriptedTransport()
        await transport.setMoshProbeAvailable(true)
        let gate = ScriptedTransportCallGate()
        let connector = HostProbeConnector(transport: transport, connectGate: gate)
        let store = makeStore(connector: connector)
        let test = Task { await store.runMoshSupportCheck() }
        try await waitUntil("mosh test reached connect gate") { await gate.entryCount > 0 }
        #expect(store.moshSupport == .testing)
        await store.runMoshSupportCheck()
        #expect(await connector.connectCount == 1)
        await gate.open()
        await test.value
        #expect(store.moshSupport == .available)
        #expect(await transport.moshProbeCount == 1)
        try await waitUntil("probe transport closed") { await transport.isClosed }
    }

    @Test func hooksFailureClearsBusyAndKeepsThePreviousReport() async throws {
        let transport = FakeTransport(
            pingResult: .success(ServerInfo(version: "3.4", protocolVersion: 0, backend: .tmux)))
        let connector = HostProbeConnector(transport: transport)
        let store = makeStore(connector: connector, presence: connector.presence)
        await store.runChecks()
        let report = store.report
        await store.installStatusHooks()
        #expect(!store.isInstallingStatusHooks)
        #expect(store.statusHooksInstallError != nil)
        #expect(store.report == report)
    }

    @Test func checksNeverStartARuntime() async throws {
        let connector = FakeTransportConnector(
            outcome: .connectFails(.herdrNotRunning(path: "/home/dev/.config/herdr/herdr.sock")))
        let store = makeStore(connector: connector)
        await store.runChecks()
        #expect(await connector.wakeCount == 0)
        #expect(await connector.coreStartCount == 0)
        #expect(await connector.codexStartCount == 0)
        #expect(await connector.openCodeStartCount == 0)
    }

    @Test func disablingThenReenablingDoesNotReviveDetection() async throws {
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: .success(ServerInfo(version: "0.9.5", protocolVersion: 22))))
        let gate = ScriptedTransportCallGate()
        await connector.gateDetection(gate)
        let store = makeStore(connector: connector)
        let run = Task { await store.runChecks() }
        try await waitUntil("checks reached detection gate") { await gate.entryCount > 0 }
        store.setHostEnabled(false)
        store.setHostEnabled(true)
        await gate.open()
        await run.value
        #expect(store.phase == .finished)
        #expect(store.report == nil)
        #expect(await connector.transports.isEmpty)
    }

    @Test func disablingDuringChecksConnectClosesTheRetiredTransportWithoutPinging() async throws {
        let transport = ScriptedTransport()
        let gate = ScriptedTransportCallGate()
        let connector = HostProbeConnector(
            transport: transport, presence: .herdrOnly, connectGate: gate)
        let store = makeStore(connector: connector)
        let run = Task { await store.runChecks() }
        try await waitUntil("checks reached connect gate") { await gate.entryCount > 0 }
        store.setHostEnabled(false)
        await gate.open()
        await run.value
        #expect(await transport.isClosed)
        #expect(await transport.pingCount == 0)
        #expect(store.phase == .finished && store.report == nil)
    }

    // B-15: both buttons must stop at a connect suspended before disable.
    @Test func disablingDuringConnectDoesNotInstallHooks() async throws {
        let transport = FakeTransport(
            pingResult: .success(ServerInfo(version: "3.4", protocolVersion: 0, backend: .tmux)))
        let gate = ScriptedTransportCallGate()
        let connector = HostProbeConnector(transport: transport, connectGate: gate)
        let store = makeStore(connector: connector, presence: connector.presence)
        let install = Task { await store.installStatusHooks() }
        try await waitUntil("hooks installation reached connect gate") { await gate.entryCount > 0 }
        #expect(store.isInstallingStatusHooks)
        await store.installStatusHooks()
        #expect(await connector.connectCount == 1)
        store.setHostEnabled(false)
        store.setHostEnabled(true)
        await gate.open()
        await install.value
        #expect(await transport.installStatusHooksCount == 0)
        #expect(await transport.isClosed)
        #expect(!store.isInstallingStatusHooks)
        #expect(store.statusHooks == nil && store.statusHooksInstallError == nil)
    }

    @Test func disablingDuringConnectDoesNotRunMoshProof() async throws {
        let transport = ScriptedTransport()
        await transport.setMoshProbeAvailable(true)
        let gate = ScriptedTransportCallGate()
        let connector = HostProbeConnector(transport: transport, connectGate: gate)
        let store = makeStore(connector: connector)
        let run = Task { await store.runMoshSupportCheck() }
        try await waitUntil("mosh test reached connect gate") { await gate.entryCount > 0 }
        store.setHostEnabled(false)
        store.setHostEnabled(true)
        await gate.open()
        await run.value
        #expect(await transport.moshProbeCount == 0)
        #expect(store.moshSupport == .unavailable("The test was interrupted."))
        try await waitUntil("invalidated mosh transport closed") { await transport.isClosed }
    }

    @Test func disablingDuringMoshProofDiscardsItsLateResult() async throws {
        let transport = ScriptedTransport()
        await transport.setMoshProbeAvailable(true)
        let gate = ScriptedTransportCallGate()
        await transport.gateNextMoshProbe(on: gate)
        let store = makeStore(connector: HostProbeConnector(transport: transport))
        let run = Task { await store.runMoshSupportCheck() }
        try await waitUntil("mosh test reached proof gate") { await gate.entryCount > 0 }
        store.setHostEnabled(false)
        await gate.open()
        await run.value
        #expect(store.moshSupport == .unavailable("The test was interrupted."))
        try await waitUntil("late proof transport closed") { await transport.isClosed }
    }

    @Test func anotherProbeCannotReplaceThePendingTrustDecision() async throws {
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: .success(ServerInfo(version: "0.9.5", protocolVersion: 22))),
            presentedKeyBlob: Data("untrusted".utf8))
        let store = makeStore(connector: connector)
        let run = Task { await store.runChecks() }
        try await waitUntil("first trust decision pending") { store.pendingFingerprint != nil }
        let candidate = store.pendingFingerprint
        await store.runMoshSupportCheck()
        #expect(store.pendingFingerprint == candidate)
        store.confirmFingerprint(trusted: false)
        await run.value
        #expect(store.pendingFingerprint == nil)
    }

    /// B-37: a cancelled run's decline reaches the main actor after the
    /// question it was for is already answered and a new one is up. It
    /// declines only its own question, never the new one.
    @Test func aLateCancellationDeclineLeavesTheNextQuestionUp() async throws {
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: .success(Self.healthy)),
            presentedKeyBlob: Data("untrusted".utf8))
        let store = makeStore(connector: connector)
        var hopHeld = false
        var hopReleased: CheckedContinuation<Void, Never>?
        var hopDone = false
        store.cancellationHop = { decline in
            hopHeld = true
            await withCheckedContinuation { hopReleased = $0 }
            decline()
            hopDone = true
        }
        let first = Task { await store.runChecks() }
        try await waitUntil("first question up") { store.pendingFingerprint != nil }
        first.cancel()
        try await waitUntil("cancellation hop held") { hopHeld }
        store.confirmFingerprint(trusted: false)
        await first.value
        #expect(store.pendingFingerprint == nil)

        let second = Task { await store.runChecks() }
        try await waitUntil("second question up") { store.pendingFingerprint != nil }
        let question = store.pendingFingerprint
        hopReleased?.resume()
        try await waitUntil("late decline delivered") { hopDone }
        #expect(store.pendingFingerprint == question)
        store.confirmFingerprint(trusted: true)
        await second.value
        #expect(store.pendingFingerprint == nil)
        #expect(store.report?.isFullyPassed == true)
    }

    /// HOST-02 safety net: checks are allowed while an explicitly approved
    /// replacement awaits persistence. That write is not a checks epoch.
    @Test func checksCanOverlapTheExplicitMismatchPinWrite() async throws {
        let pins = GatedHostPins()
        let old = HostKeyFingerprint(publicKeyBlob: Data("old-key".utf8))
        let blob = Data("new-key".utf8)
        let new = HostKeyFingerprint(publicKeyBlob: blob)
        await pins.setFingerprint(old, host: "host.example", port: 22)
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: .success(ServerInfo(version: "0.9.5", protocolVersion: 22))),
            presentedKeyBlob: blob)
        let store = makeStore(connector: connector, knownHosts: pins)
        await store.runChecks()
        #expect(store.pendingHostKeyReplacement == HostKeyReplacement(known: old, presented: new))
        let gate = ScriptedTransportCallGate()
        await pins.gateNextWrite(gate)
        let trust = Task { await store.trustPresentedHostKey() }
        try await waitUntil("trusted pin reached persistence gate") { await gate.entryCount > 0 }
        await store.runChecks()
        #expect(await pins.fingerprint(host: "host.example", port: 22) == old)
        #expect(store.pendingHostKeyReplacement == HostKeyReplacement(known: old, presented: new))
        #expect(store.report?.isFullyPassed == false)
        await gate.open()
        await trust.value
        #expect(await pins.fingerprint(host: "host.example", port: 22) == new)
        #expect(store.pendingHostKeyReplacement == nil)
        #expect(store.report?.isFullyPassed == true)
    }

    private static let healthy = ServerInfo(version: "0.9.5", protocolVersion: 22)

    /// A Host whose pin no longer matches its key, checked once: the
    /// replacement is offered and the old pin still stands.
    private func mismatchedHost(
        _ pins: GatedHostPins, host: Host = .fixture(), jumpKeyBlob: Data? = nil
    ) async -> (HostOnboardingStore, FakeTransportConnector, HostKeyReplacement) {
        let old = HostKeyFingerprint(publicKeyBlob: Data("old-key".utf8))
        let blob = Data("new-key".utf8)
        await pins.setFingerprint(old, host: host.address, port: host.port)
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: .success(Self.healthy)), presentedKeyBlob: blob,
            presentedJumpKeyBlob: jumpKeyBlob)
        let store = makeStore(connector: connector, knownHosts: pins, host: host)
        await store.runChecks()
        return (store, connector, HostKeyReplacement(
            known: old, presented: HostKeyFingerprint(publicKeyBlob: blob)))
    }

    @Test func trustNewKeyIsRefusedWhileChecksRunAndWhileTheHostIsOff() async throws {
        let pins = GatedHostPins()
        let (store, connector, replacement) = await mismatchedHost(pins)
        #expect(store.pendingHostKeyReplacement == replacement)
        let gate = ScriptedTransportCallGate()
        await connector.gateDetection(gate)
        let run = Task { await store.runChecks() }
        try await waitUntil("checks reached detection gate") { await gate.entryCount > 0 }
        await store.trustPresentedHostKey()
        #expect(await pins.fingerprint(host: "host.example", port: 22) == replacement.known)
        await gate.open()
        await run.value
        #expect(store.pendingHostKeyReplacement == replacement)

        store.setHostEnabled(false)
        await store.trustPresentedHostKey()
        #expect(await pins.fingerprint(host: "host.example", port: 22) == replacement.known)
        #expect(store.pendingHostKeyReplacement == replacement)
        #expect(await connector.detectionCount == 2)
    }

    /// A run that began during the write and finishes after it is followed
    /// by the write's own rerun; both see the new pin.
    @Test func aCheckThatOutlastsThePinWriteIsFollowedByARerunOnTheNewPin() async throws {
        let pins = GatedHostPins()
        let (store, connector, replacement) = await mismatchedHost(pins)
        let write = ScriptedTransportCallGate()
        await pins.gateNextWrite(write)
        let trust = Task { await store.trustPresentedHostKey() }
        try await waitUntil("trusted pin reached persistence gate") { await write.entryCount > 0 }
        let detection = ScriptedTransportCallGate()
        await connector.gateDetection(detection)
        let run = Task { await store.runChecks() }
        try await waitUntil("checks reached detection gate") { await detection.entryCount > 0 }
        #expect(store.pendingHostKeyReplacement == nil)

        await write.open()
        await trust.value
        #expect(await pins.fingerprint(host: "host.example", port: 22) == replacement.presented)
        #expect(store.pendingHostKeyReplacement == nil)
        #expect(store.phase == .running)
        await detection.open()
        await run.value
        #expect(store.phase == .finished)
        #expect(store.report?.isFullyPassed == true)
        #expect(store.pendingHostKeyReplacement == nil)
        #expect(await connector.detectionCount == 3)
    }

    /// The user confirmed the new key before turning the Host off: the pin
    /// is written, but nothing dials the Host afterwards.
    @Test func disablingDuringThePinWriteKeepsTheConfirmedKeyAndDialsNothing() async throws {
        let pins = GatedHostPins()
        let (store, connector, replacement) = await mismatchedHost(pins)
        let dials = await connector.capturedSettings.count
        let write = ScriptedTransportCallGate()
        await pins.gateNextWrite(write)
        let trust = Task { await store.trustPresentedHostKey() }
        try await waitUntil("trusted pin reached persistence gate") { await write.entryCount > 0 }
        store.setHostEnabled(false)
        await write.open()
        await trust.value
        #expect(await pins.fingerprint(host: "host.example", port: 22) == replacement.presented)
        #expect(store.pendingHostKeyReplacement == nil)
        #expect(store.phase == .finished)
        #expect(await connector.detectionCount == 1)
        #expect(await connector.capturedSettings.count == dials)
    }

    /// Only Run Checks offers or clears a replacement: a mosh test that
    /// meets the changed key does neither, and never changes the pin.
    @Test func aMoshTestNeitherOffersNorClearsAReplacement() async throws {
        let pins = GatedHostPins()
        let old = HostKeyFingerprint(publicKeyBlob: Data("old-key".utf8))
        await pins.setFingerprint(old, host: "host.example", port: 22)
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: .success(Self.healthy)),
            presentedKeyBlob: Data("new-key".utf8))
        let store = makeStore(connector: connector, knownHosts: pins)
        await store.runMoshSupportCheck()
        #expect(store.pendingHostKeyReplacement == nil)
        await store.runChecks()
        let replacement = try #require(store.pendingHostKeyReplacement)
        await store.runMoshSupportCheck()
        #expect(store.pendingHostKeyReplacement == replacement)
        #expect(await pins.fingerprint(host: "host.example", port: 22) == old)
    }

    /// A mosh test's first-connect question (its Jump Host's key) can be up
    /// while Trust New Key writes the Host's pin. The two stay separate: the
    /// write lands and clears only the replacement, its rerun cannot ask a
    /// second question and fails, and the first question stays the user's.
    @Test func aFirstConnectQuestionOverlapsTheReplacementWriteAndItsRerun() async throws {
        var host = Host.fixture()
        host.jumpAddress = "jump.example"
        host.jumpPort = 2222
        let jumpBlob = Data("jump-key".utf8)
        let jump = HostKeyFingerprint(publicKeyBlob: jumpBlob)
        let pins = GatedHostPins()
        await pins.setFingerprint(jump, host: "jump.example", port: 2222)
        let (store, _, replacement) = await mismatchedHost(pins, host: host, jumpKeyBlob: jumpBlob)
        #expect(store.pendingHostKeyReplacement == replacement)
        await pins.forget(host: "jump.example", port: 2222)
        let mosh = Task { await store.runMoshSupportCheck() }
        try await waitUntil("the Jump Host question should be up") { store.pendingFingerprint != nil }
        let question = try #require(store.pendingFingerprint)
        #expect(question.host == "jump.example")
        #expect(store.pendingHostKeyReplacement == replacement)

        await store.trustPresentedHostKey()

        #expect(await pins.fingerprint(host: "host.example", port: 22) == replacement.presented)
        #expect(store.pendingHostKeyReplacement == nil)
        #expect(store.pendingFingerprint == question)
        #expect(store.phase == .finished)
        #expect(store.report?.isFullyPassed == false)
        #expect(await pins.fingerprint(host: "jump.example", port: 2222) == nil)
        store.confirmFingerprint(trusted: true)
        await mosh.value
        #expect(store.pendingFingerprint == nil)
        #expect(await pins.fingerprint(host: "jump.example", port: 2222) == jump)
    }

    private func makeStore(
        connector: any TransportConnector, presence: HostBackendPresence? = nil,
        knownHosts: any KnownHostsStore = InMemoryKnownHostsStore(), host: Host = .fixture()
    ) -> HostOnboardingStore {
        HostOnboardingStore(
            host: host, connector: connector, knownHosts: knownHosts,
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()), knownPresence: presence)
    }
}

private actor GatedHostPins: KnownHostsStore {
    private let pins = InMemoryKnownHostsStore()
    private var nextWriteGate: ScriptedTransportCallGate?
    /// Endpoints whose pins read as absent until written again.
    private var forgotten: Set<String> = []

    func gateNextWrite(_ gate: ScriptedTransportCallGate) { nextWriteGate = gate }

    func forget(host: String, port: Int) { forgotten.insert("\(host):\(port)") }

    func fingerprints(host: String, port: Int) async -> [HostKeyFingerprint] {
        guard !forgotten.contains("\(host):\(port)") else { return [] }
        return await pins.fingerprints(host: host, port: port)
    }

    func fingerprint(host: String, port: Int, algorithm: String) async -> HostKeyFingerprint? {
        guard !forgotten.contains("\(host):\(port)") else { return nil }
        return await pins.fingerprint(host: host, port: port, algorithm: algorithm)
    }

    func setFingerprint(_ fingerprint: HostKeyFingerprint, host: String, port: Int) async {
        let gate = nextWriteGate
        nextWriteGate = nil
        await gate?.waitUntilOpen()
        await pins.setFingerprint(fingerprint, host: host, port: port)
        forgotten.remove("\(host):\(port)")
    }
}

/// A connect boundary held after dialing, before handing its transport back.
actor HostProbeConnector: TransportConnector {
    let transport: any Transport
    nonisolated let presence: HostBackendPresence
    private let connectGate: ScriptedTransportCallGate?
    private let detectionGate: ScriptedTransportCallGate?
    private(set) var connectCount = 0
    private(set) var detectionCount = 0

    init(
        transport: any Transport,
        presence: HostBackendPresence = HostBackendPresence(herdr: false, tmuxVersion: "3.4"),
        connectGate: ScriptedTransportCallGate? = nil,
        detectionGate: ScriptedTransportCallGate? = nil
    ) {
        self.transport = transport
        self.presence = presence
        self.connectGate = connectGate
        self.detectionGate = detectionGate
    }

    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        connectCount += 1
        await connectGate?.waitUntilOpen()
        return transport
    }

    func connect(settings: SSHTransportSettings, backend: HostBackend) async throws -> any Transport {
        try await connect(settings: settings)
    }

    func detectBackends(settings: SSHTransportSettings) async throws -> HostBackendPresence {
        detectionCount += 1
        await detectionGate?.waitUntilOpen()
        return presence
    }
}
