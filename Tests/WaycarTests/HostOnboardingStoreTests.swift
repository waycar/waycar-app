import CryptoKit
import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Host onboarding store")
struct HostOnboardingStoreTests {
    private static let healthyPing = Result<ServerInfo, TransportError>.success(
        ServerInfo(version: "0.7.5", protocolVersion: 17))
    private let keyBlob = Data("fake-host-key".utf8)

    private func makeStore(
        host: Host = .fixture(),
        outcome: FakeTransportConnector.Outcome = .connects(pingResult: healthyPing),
        presentedKeyBlob: Data? = nil,
        knownHosts: InMemoryKnownHostsStore = InMemoryKnownHostsStore(),
        password: String? = nil,
        sessions: [HerdrSession] = []
    ) throws -> (HostOnboardingStore, FakeTransportConnector) {
        let connector = FakeTransportConnector(
            outcome: outcome, presentedKeyBlob: presentedKeyBlob, sessions: sessions)
        let secrets = InMemorySecretStore()
        if let password {
            try secrets.write(
                Data(password.utf8), account: HostStore.passwordAccount(for: host.id))
        }
        let store = HostOnboardingStore(
            host: host,
            connector: connector,
            knownHosts: knownHosts,
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: secrets))
        return (store, connector)
    }

    @Test func healthyHostGoesAllGreen() async throws {
        let (store, connector) = try makeStore()

        await store.runChecks()

        #expect(store.phase == .finished)
        #expect(store.report?.isFullyPassed == true)
        #expect(store.serverInfo == ServerInfo(version: "0.7.5", protocolVersion: 17))
        let transport = try #require(await connector.transports.last)
        #expect(await transport.isClosed)
    }

    @Test func aRunRequestedMidRunRunsAgainWhenTheCurrentOneEnds() async throws {
        let (store, connector) = try makeStore()
        await connector.holdDetection()

        let first = Task { await store.runChecks() }
        try await waitUntil("the run started") { store.phase == .running }
        // The runtime pick changed while the run is in flight.
        await store.runChecks()
        #expect(await connector.detectionCount == 1)
        await connector.releaseDetection()
        await first.value

        #expect(await connector.detectionCount == 2)
        #expect(store.phase == .finished)
        #expect(store.report?.isFullyPassed == true)
    }

    @Test func disablingDuringDetectionStopsTheButtonStartedPreflight() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let host = Host.fixture()
        await knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: keyBlob), host: host.address, port: host.port)
        let (store, connector) = try makeStore(
            host: host, presentedKeyBlob: keyBlob, knownHosts: knownHosts)
        let gate = ScriptedTransportCallGate()
        await connector.gateDetection(gate)
        let run = Task { await store.runChecks() }
        await gate.waitForEntry()
        store.setHostEnabled(false)
        await gate.open()
        await run.value

        #expect(await connector.connectedBackends.isEmpty)
        #expect(await connector.transports.isEmpty)
        #expect(store.presence == nil)
        #expect(store.report == nil && store.serverInfo == nil && store.statusHooks == nil)
        #expect(store.phase == .finished)
    }

    @Test func sessionDiscoveryPublishesDefaultAndNamedSessions() async throws {
        let sessions = [
            HerdrSession(name: "default", isDefault: true, isRunning: true),
            HerdrSession(name: "work", isDefault: false, isRunning: true),
        ]
        let (store, _) = try makeStore(sessions: sessions)

        await store.runChecks()

        #expect(store.availableSessions == sessions)
    }

    @Test func selectingADiscoveredSessionUpdatesTheCatalogHost() throws {
        let host = Host.fixture()
        let suiteName = "HostOnboardingStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let catalog = HostStore(defaults: defaults, secrets: InMemorySecretStore())
        try catalog.add(host)
        let (store, _) = try makeStore(host: host)

        try store.selectSession(
            HerdrSession(name: "work", isDefault: false, isRunning: true),
            in: catalog)

        #expect(catalog.hosts.first?.sessionName == "work")
    }

    @Test func connectFailureFailsTheConnectionCheck() async throws {
        let (store, _) = try makeStore(
            outcome: .connectFails(.sshUnreachable(detail: "connection refused")))

        await store.runChecks()

        guard case .failed = try #require(store.report)[.connection] else {
            Issue.record("connection check should fail")
            return
        }
        #expect(store.serverInfo == nil)
    }

    @Test func corruptDeviceKeyExplainsTheReplacementRecovery() async throws {
        let account = "corrupt-device-key"
        let secrets = InMemorySecretStore()
        try secrets.write(Data("not-an-ed25519-key".utf8), account: account)
        let connector = FakeTransportConnector(outcome: .connects(pingResult: Self.healthyPing))
        let store = HostOnboardingStore(
            host: .fixture(authMethod: .deviceKey),
            connector: connector,
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: secrets, account: account), secrets: secrets))

        await store.runChecks()

        guard case .failed(let hint) = try #require(store.report)[.connection] else {
            Issue.record("a corrupt Device Key should fail the connection check")
            return
        }
        #expect(hint.contains("Replace Device Key"))
        #expect(hint.contains("authorized_keys"))
        #expect(await connector.capturedSettings.isEmpty)
    }

    @Test func corruptRSAKeyExplainsThatRegistrationMustBeRepaired() async throws {
        let account = "corrupt-rsa-key"
        let secrets = InMemorySecretStore()
        try secrets.write(Data("not-an-rsa-key".utf8), account: account)
        let connector = FakeTransportConnector(outcome: .connects(pingResult: Self.healthyPing))
        let store = HostOnboardingStore(
            host: .fixture(authMethod: .rsaKey),
            connector: connector,
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                rsaKeys: RSAKeyStore(secrets: secrets, account: account),
                secrets: secrets))

        await store.runChecks()

        guard case .failed(let hint) = try #require(store.report)[.connection] else {
            Issue.record("a corrupt RSA Key should fail the connection check")
            return
        }
        #expect(hint.contains("RSA Key is corrupted"))
        #expect(hint.contains("every Host"))
        #expect(await connector.capturedSettings.isEmpty)
    }

    @Test func pingFailureFailsItsCheckAndStillClosesTheTransport() async throws {
        let (store, connector) = try makeStore(
            outcome: .connects(
                pingResult: .failure(.protocolVersionMismatch(server: 16, supported: 17))))

        await store.runChecks()

        guard case .failed = try #require(store.report)[.protocolCompatible] else {
            Issue.record("protocol check should fail")
            return
        }
        let transport = try #require(await connector.transports.last)
        #expect(await transport.isClosed)
    }

    @Test func firstConnectPublishesTheCandidateAndTrustPersistsTheFingerprint() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let host = Host.fixture(address: "box.example")
        let (store, _) = try makeStore(
            host: host, presentedKeyBlob: keyBlob, knownHosts: knownHosts)

        let run = Task { await store.runChecks() }
        try await waitUntil("candidate should surface") { store.pendingFingerprint != nil }
        let candidate = try #require(store.pendingFingerprint)
        #expect(candidate.host == "box.example")
        #expect(candidate.fingerprint == HostKeyFingerprint(publicKeyBlob: keyBlob))

        store.confirmFingerprint(trusted: true)
        await run.value

        #expect(store.pendingFingerprint == nil)
        #expect(store.report?.isFullyPassed == true)
        #expect(
            await knownHosts.fingerprint(host: "box.example", port: 22)
                == HostKeyFingerprint(publicKeyBlob: keyBlob))
    }

    @Test func decliningTheFingerprintFailsTheRunAndPersistsNothing() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let (store, _) = try makeStore(presentedKeyBlob: keyBlob, knownHosts: knownHosts)

        let run = Task { await store.runChecks() }
        try await waitUntil("candidate should surface") { store.pendingFingerprint != nil }
        store.confirmFingerprint(trusted: false)
        await run.value

        #expect(store.pendingFingerprint == nil)
        guard case .failed = try #require(store.report)[.connection] else {
            Issue.record("connection check should fail")
            return
        }
        #expect(await knownHosts.fingerprint(host: "host.example", port: 22) == nil)
    }

    @Test func cancellingTheRunDeclinesThePendingFingerprint() async throws {
        // No clock declines the prompt, however long it stays up. A page
        // that goes away mid-prompt cancels its run, and that must decline
        // the key rather than leave the run waiting on an answer forever.
        let knownHosts = InMemoryKnownHostsStore()
        let (store, _) = try makeStore(presentedKeyBlob: keyBlob, knownHosts: knownHosts)

        let run = Task { await store.runChecks() }
        try await waitUntil("candidate should surface") { store.pendingFingerprint != nil }
        run.cancel()
        try await waitUntil("the cancelled run should finish") { store.phase == .finished }
        // A regression would leave the run waiting; answer it so the
        // failure above is reported instead of hanging the suite.
        if store.phase != .finished { store.confirmFingerprint(trusted: false) }
        await run.value

        #expect(store.pendingFingerprint == nil)
        guard case .failed = try #require(store.report)[.connection] else {
            Issue.record("connection check should fail")
            return
        }
        #expect(await knownHosts.fingerprint(host: "host.example", port: 22) == nil)
    }

    @Test func aDisabledHostIsNeverDialed() async throws {
        // The Host page outlives turning its Host off, and its buttons call
        // the store directly; none of them may contact a Disabled Host.
        let (store, connector) = try makeStore(
            host: .fixture(authMethod: .deviceKey), presentedKeyBlob: keyBlob)
        store.setHostEnabled(false)

        await store.runChecks()
        await store.runMoshSupportCheck()

        #expect(store.phase == .idle)
        #expect(store.report == nil)
        #expect(store.moshSupport == .idle)
        #expect(await connector.capturedSettings.isEmpty)
    }

    @Test func turningTheHostOffDeclinesThePendingFingerprint() async throws {
        // A run a button started is not cancelled when the Host turns off;
        // declining its prompt is what stops it before the Host is dialed
        // again with a trusted key.
        let knownHosts = InMemoryKnownHostsStore()
        let (store, _) = try makeStore(presentedKeyBlob: keyBlob, knownHosts: knownHosts)

        let run = Task { await store.runChecks() }
        try await waitUntil("candidate should surface") { store.pendingFingerprint != nil }
        store.setHostEnabled(false)
        try await waitUntil("the declined run should finish") { store.phase == .finished }
        if store.phase != .finished { store.confirmFingerprint(trusted: false) }
        await run.value

        #expect(store.pendingFingerprint == nil)
        // The disabled run declined trust, but no longer owns the report.
        #expect(store.report == nil)
        #expect(await knownHosts.fingerprint(host: "host.example", port: 22) == nil)
    }

    @Test func alreadyTrustedFingerprintNeverPrompts() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        await knownHosts.setFingerprint(
            HostKeyFingerprint(publicKeyBlob: keyBlob), host: "host.example", port: 22)
        let (store, _) = try makeStore(presentedKeyBlob: keyBlob, knownHosts: knownHosts)

        await store.runChecks()

        #expect(store.pendingFingerprint == nil)
        #expect(store.report?.isFullyPassed == true)
    }

    @Test func explicitTrustReplacesThePresentedHostKeyAndReconnects() async throws {
        let knownHosts = InMemoryKnownHostsStore()
        let trusted = HostKeyFingerprint(publicKeyBlob: Data("trusted-host-key".utf8))
        let presented = HostKeyFingerprint(publicKeyBlob: keyBlob)
        await knownHosts.setFingerprint(trusted, host: "host.example", port: 22)
        let (store, _) = try makeStore(presentedKeyBlob: keyBlob, knownHosts: knownHosts)

        await store.runChecks()

        #expect(
            store.pendingHostKeyReplacement
                == HostKeyReplacement(known: trusted, presented: presented))
        #expect(await knownHosts.fingerprint(host: "host.example", port: 22) == trusted)

        await store.trustPresentedHostKey()

        #expect(store.pendingHostKeyReplacement == nil)
        #expect(store.report?.isFullyPassed == true)
        #expect(await knownHosts.fingerprint(host: "host.example", port: 22) == presented)
    }

    @Test func settingsCarryTheHostCoordinatesAndStoredPassword() async throws {
        var host = Host.fixture(address: "box.example", username: "dev", authMethod: .password)
        host.port = 2222
        host.sessionName = " work "
        let (store, connector) = try makeStore(host: host, password: "hunter2")

        await store.runChecks()

        let settings = try #require(await connector.capturedSettings.first)
        #expect(settings.host == "box.example")
        #expect(settings.port == 2222)
        #expect(settings.username == "dev")
        #expect(settings.socket == .namedSession("work"))
        guard case .password("hunter2") = settings.credentials else {
            Issue.record("credentials should be the stored password")
            return
        }
    }

    @Test func deviceKeyHostConnectsWithTheDeviceKey() async throws {
        let (store, connector) = try makeStore(host: .fixture(authMethod: .deviceKey))

        await store.runChecks()

        let settings = try #require(await connector.capturedSettings.first)
        guard case .ed25519 = settings.credentials else {
            Issue.record("credentials should be the device key")
            return
        }
    }

    @Test func rsaKeyHostConnectsWithRSASHA512() async throws {
        let (store, connector) = try makeStore(host: .fixture(authMethod: .rsaKey))

        await store.runChecks()

        let settings = try #require(await connector.capturedSettings.first)
        guard case .rsaSHA512(let key) = settings.credentials else {
            Issue.record("credentials should be the RSA-SHA2-512 key")
            return
        }
        #expect(key.keySizeInBits == 3_072)
    }

    @Test func missingPasswordFailsBeforeConnecting() async throws {
        let (store, connector) = try makeStore(
            host: .fixture(authMethod: .password), password: nil)

        await store.runChecks()

        guard case .failed(let hint) = try #require(store.report)[.connection] else {
            Issue.record("connection check should fail")
            return
        }
        #expect(hint.contains("password"))
        #expect(await connector.capturedSettings.isEmpty)
    }

    // MARK: Backends (ADR 0026)

    private static let tmuxPing = Result<ServerInfo, TransportError>.success(
        ServerInfo(version: "3.4", protocolVersion: 0, backend: .tmux))

    private static func hooksReport(codexInstalled: Bool) -> StatusHooksReport {
        StatusHooksReport(
            version: 1,
            hostTools: StatusHooksReport.HostTools(version: "0.9.0", pluginRoot: "/home/dev/.waycar"),
            backends: StatusHooksReport.Backends(herdr: false, tmux: "3.4"),
            configDir: "/home/dev/.config/waycar",
            agents: [
                StatusHooksReport.AgentHooks(
                    agent: "claude", installed: true,
                    configPath: "/home/dev/.claude/settings.json", needsCodexReview: nil),
                StatusHooksReport.AgentHooks(
                    agent: "codex", installed: codexInstalled,
                    configPath: "/home/dev/.codex/hooks.json", needsCodexReview: false),
            ])
    }

    private func makeBackendStore(
        presence: HostBackendPresence,
        statusHooks: Result<StatusHooksReport, TransportError>? = nil,
        sessions: [HerdrSession] = []
    ) -> (HostOnboardingStore, FakeTransportConnector) {
        let connector = FakeTransportConnector(
            outcome: .connects(pingResult: Self.healthyPing),
            sessions: sessions,
            presence: presence,
            backendPings: [.tmux: Self.tmuxPing],
            statusHooks: statusHooks)
        let store = HostOnboardingStore(
            host: .fixture(),
            connector: connector,
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()))
        return (store, connector)
    }

    /// Scenario 2: no herdr, tmux 3.4, so the Host connects as tmux and runs
    /// tmux's checklist; herdr's named sessions are never asked for.
    @Test func tmuxOnlyHostConnectsToTmux() async throws {
        let (store, connector) = makeBackendStore(
            presence: HostBackendPresence(herdr: false, tmuxVersion: "3.4"),
            statusHooks: .success(Self.hooksReport(codexInstalled: true)),
            sessions: [HerdrSession(name: "default", isDefault: true, isRunning: true)])

        await store.runChecks()

        #expect(await connector.connectedBackends == [.tmux])
        let report = try #require(store.report)
        #expect(report.backend == .tmux)
        #expect(report.isFullyPassed)
        #expect(report[.tmuxInstalled] == .passed)
        #expect(report[.statusHooks] == .passed)
        #expect(store.serverInfo?.backend == .tmux)
        #expect(store.availableSessions.isEmpty)
        let transport = try #require(await connector.transports.first)
        #expect(await transport.listSessionsCount == 0)
        #expect(await transport.isClosed)
        #expect(!store.isDualBackend)
    }

    /// Both installed: herdr leads with today's checklist and session
    /// discovery; tmux is dialed only for its hooks.
    @Test func dualHostConnectsToHerdrFirst() async throws {
        let sessions = [HerdrSession(name: "default", isDefault: true, isRunning: true)]
        let (store, connector) = makeBackendStore(
            presence: HostBackendPresence(herdr: true, tmuxVersion: "3.4"),
            statusHooks: .success(Self.hooksReport(codexInstalled: false)),
            sessions: sessions)

        await store.runChecks()

        #expect(await connector.connectedBackends == [.herdr, .tmux])
        #expect(store.report == .allPassed)
        #expect(store.serverInfo?.backend == .herdr)
        #expect(store.availableSessions == sessions)
        #expect(store.isDualBackend)
        #expect(store.statusHooks?.missingAgents == ["Codex"])
        for transport in await connector.transports {
            #expect(await transport.isClosed)
        }
    }

    @Test func herdrOnlyHostNeverDialsTmux() async throws {
        let (store, connector) = makeBackendStore(presence: .herdrOnly)

        await store.runChecks()

        #expect(await connector.connectedBackends == [.herdr])
        #expect(store.report == .allPassed)
        #expect(store.statusHooks == nil)
        #expect(!store.isDualBackend)
    }

    /// Scenario 9: detection already proved the connection, so an old tmux
    /// fails its own check without a control client being dialed.
    @Test func oldTmuxOnlyHostFailsTheTmuxCheck() async throws {
        let (store, connector) = makeBackendStore(
            presence: HostBackendPresence(herdr: false, tmuxVersion: "2.7"))

        await store.runChecks()

        #expect(await connector.connectedBackends.isEmpty)
        let report = try #require(store.report)
        #expect(report.backend == .tmux)
        #expect(report[.connection] == .passed)
        guard case .failed(let hint) = report[.tmuxInstalled] else {
            Issue.record("tmux check should fail")
            return
        }
        #expect(hint.contains("2.7"))
    }

    @Test func tmuxHostWithoutHostToolsWarnsButPasses() async throws {
        let (store, _) = makeBackendStore(
            presence: HostBackendPresence(herdr: false, tmuxVersion: "3.4"), statusHooks: nil)

        await store.runChecks()

        #expect(store.statusHooks == .hostToolsMissing)
        let report = try #require(store.report)
        #expect(report.isFullyPassed)
        guard case .warning = report[.statusHooks] else {
            Issue.record("the hooks row should warn")
            return
        }
    }

    @Test func installingStatusHooksClearsTheWarning() async throws {
        let (store, connector) = makeBackendStore(
            presence: HostBackendPresence(herdr: false, tmuxVersion: "3.4"),
            statusHooks: .success(Self.hooksReport(codexInstalled: false)))
        await store.runChecks()
        guard case .warning = try #require(store.report)[.statusHooks] else {
            Issue.record("missing Codex hooks should warn")
            return
        }

        await store.installStatusHooks()

        #expect(await connector.connectedBackends.last == .tmux)
        let installer = try #require(await connector.transports.last)
        #expect(await installer.installStatusHooksCount == 1)
        #expect(await installer.isClosed)
        #expect(store.statusHooks?.missingAgents == [])
        #expect(store.statusHooksInstallError == nil)
        #expect(try #require(store.report)[.statusHooks] == .passed)
    }

    /// The Console's transports share the Host's pooled connection; the
    /// checks must not, or a tmux check queues behind the Console's control
    /// slot, and Test Mosh would join the Console's reject-only dial of an
    /// untrusted Host and fail without asking "Trust this Host?". Every
    /// probe dials privately (nil pool key), herdr's and Test Mosh's included.
    @Test func checksNeverShareTheConsolesPooledConnection() async throws {
        let (store, connector) = makeBackendStore(
            presence: HostBackendPresence(herdr: true, tmuxVersion: "3.4"),
            statusHooks: .success(Self.hooksReport(codexInstalled: false)))

        await store.runChecks()
        await store.installStatusHooks()
        await store.runMoshSupportCheck()

        #expect(await connector.connectedBackends == [.herdr, .tmux, .tmux])
        let probes = await connector.capturedSettings
        #expect(probes.count == 4)
        #expect(probes.allSatisfy { $0.poolKey == nil })
    }

    // MARK: herdr-core (ADR 0031)

    private static let coreBinary = CorePresence(
        version: "0.1.14", path: "/home/dev/.local/bin/herdr-core")

    private static let corePing = Result<ServerInfo, TransportError>.success(
        ServerInfo(version: "0.1.14", protocolVersion: 1, backend: .core))

    private func makeCoreStore(
        presence: HostBackendPresence,
        corePing: Result<ServerInfo, TransportError> = HostOnboardingStoreTests.corePing,
        coreEvents: Result<Void, TransportError> = .success(()),
        connectFails: TransportError? = nil
    ) -> (HostOnboardingStore, FakeTransportConnector) {
        let connector = FakeTransportConnector(
            outcome: connectFails.map { .connectFails($0) }
                ?? .connects(pingResult: Self.healthyPing),
            presence: presence,
            backendPings: [.tmux: Self.tmuxPing, .core: corePing], coreEvents: coreEvents)
        let store = HostOnboardingStore(
            host: .fixture(),
            connector: connector,
            knownHosts: InMemoryKnownHostsStore(),
            credentials: HostCredentialsProvider(
                deviceKeys: DeviceKeyStore(secrets: InMemorySecretStore()),
                rsaKeys: RSAKeyStore(secrets: InMemorySecretStore()),
                secrets: InMemorySecretStore()))
        return (store, connector)
    }

    /// A core-only Host would otherwise connect, ping as core and end with
    /// no report, and Add Host would never finish.
    @Test func aCoreOnlyHostEndsWithACoreReport() async throws {
        let (store, connector) = makeCoreStore(
            presence: HostBackendPresence(herdr: false, tmuxVersion: nil, core: Self.coreBinary))

        await store.runChecks()

        #expect(store.phase == .finished)
        let report = try #require(store.report)
        #expect(report.backend == .core)
        #expect(report.isFullyPassed)
        #expect(report[.coreInstalled] == .passed && report[.coreVersion] == .passed)
        #expect(report[.coreHello] == .passed && report[.coreEvents] == .passed)
        // One probe connection to herdr-core, none to herdr.
        #expect(await connector.connectedBackends == [.core])
        #expect(store.serverInfo?.backend == .core)
        #expect(store.availableSessions.isEmpty)
        #expect(!store.isDualBackend)
    }

    @Test func aCoreBelowTheFloorFailsTheVersionCheck() async throws {
        let (store, _) = makeCoreStore(
            presence: HostBackendPresence(
                herdr: false, tmuxVersion: nil,
                core: CorePresence(version: "0.1.9", path: "/usr/local/bin/herdr-core")))

        await store.runChecks()

        let report = try #require(store.report)
        #expect(report.backend == .core)
        guard case .failed(let hint) = report[.coreVersion] else {
            Issue.record("the version check should fail")
            return
        }
        #expect(hint.contains("herdr-core update"))
    }

    /// herdr-core with tmux: the checklist is core's, and tmux's side still
    /// gets its hooks check, as for a TUI Host.
    @Test func aCoreHostWithTmuxKeepsTheTmuxControlsAndHooksCheck() async throws {
        let (store, connector) = makeCoreStore(
            presence: HostBackendPresence(herdr: false, tmuxVersion: "3.4", core: Self.coreBinary))

        await store.runChecks()

        #expect(store.report?.backend == .core)
        #expect(store.isDualBackend)
        #expect(await connector.connectedBackends == [.core, .tmux])
    }

    @Test func theTUIAlwaysLeadsChecksWhenBothRuntimesArePresent() async throws {
        let both = HostBackendPresence(herdr: true, tmuxVersion: nil, core: Self.coreBinary)
        let (store, connector) = makeCoreStore(presence: both)
        #expect(store.primaryBackend == .herdr)

        await store.runChecks()
        #expect(await connector.connectedBackends == [.herdr])
        #expect(store.report == .allPassed)

        #expect(store.primaryBackend == .herdr)
    }

    /// Each stage of herdr-core's handshake fails its own check, and the
    /// ones after it are unknown.
    @Test(arguments: [
        (TransportError.coreNotInstalled, PreflightCheck.coreInstalled),
        (.coreNeedsUpdate(detail: "herdr-core 0.1.12 does not offer terminal.keys."), .coreVersion),
        (.coreNeedsWaycarUpdate, .coreHello),
        (.coreRefused(message: "the socket path is too long", hint: "use a shorter session"), .coreHello),
        (.channelFailed(detail: "extra text on login"), .coreHello),
    ])
    func aCoreConnectFailureNamesItsCheck(_ failure: TransportError, _ check: PreflightCheck)
        async throws
    {
        let (store, _) = makeCoreStore(
            presence: HostBackendPresence(herdr: false, tmuxVersion: nil, core: Self.coreBinary),
            connectFails: failure)

        await store.runChecks()

        let report = try #require(store.report)
        #expect(report.backend == .core)
        guard case .failed(let hint) = report[check] else {
            Issue.record("\(check) should fail for \(failure)")
            return
        }
        #expect(!hint.isEmpty)
        let checks = PreflightCheck.checks(for: .core)
        for later in checks.drop(while: { $0 != check }).dropFirst() {
            #expect(report[later] == .blocked)
        }
    }

    @Test func aCoreRefusalShowsItsMessageAndHint() async throws {
        let (store, _) = makeCoreStore(
            presence: HostBackendPresence(herdr: false, tmuxVersion: nil, core: Self.coreBinary),
            connectFails: .coreRefused(
                message: "the socket path is too long", hint: "use a shorter session name"))

        await store.runChecks()

        guard case .failed(let hint)? = store.report?[.coreHello] else {
            Issue.record("the hello check should fail")
            return
        }
        #expect(hint.contains("the socket path is too long"))
        #expect(hint.contains("use a shorter session name"))
    }

    @Test func aCoreThatWillNotStreamFailsTheEventsCheck() async throws {
        let (store, _) = makeCoreStore(
            presence: HostBackendPresence(herdr: false, tmuxVersion: nil, core: Self.coreBinary),
            coreEvents: .failure(.timedOut))

        await store.runChecks()

        let report = try #require(store.report)
        #expect(report[.coreHello] == .passed)
        guard case .failed = report[.coreEvents] else {
            Issue.record("the events check should fail")
            return
        }
    }
}
