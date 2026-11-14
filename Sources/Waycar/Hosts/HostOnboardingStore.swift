import Foundation
import Observation

/// A verified mismatch awaiting the user's explicit decision to replace the
/// trusted pin. Merely observing a mismatch never mutates the known-hosts store.
struct HostKeyReplacement: Equatable, Sendable {
    let known: HostKeyFingerprint
    let presented: HostKeyFingerprint
}

/// Drives one Host's onboarding preflight (#14): resolve credentials,
/// connect (surfacing the TOFU first-connect prompt), discover sessions,
/// ping the selected session, and render the outcome as the checklist.
/// Tap-to-test state for the Host detail page's mosh handshake proof.
enum MoshSupportState: Equatable, Sendable {
    case idle
    case testing
    case available
    /// Carries the concrete failure reason so the row can show it.
    case unavailable(String)
}

@MainActor
@Observable
final class HostOnboardingStore {
    enum Phase: Equatable {
        case idle
        case running
        case finished
    }

    private var checks: HostChecksMachine
    var phase: Phase { checks.isRunning ? .running : (checks.hasFinished ? .finished : .idle) }
    private var trust = HostKeyTrustMachine()
    /// Set while the transport waits on the user's first-connect trust
    /// decision; the UI renders it as the fingerprint confirmation sheet.
    var pendingFingerprint: HostKeyCandidate? { trust.pendingCandidate }
    /// Set only after a hard-failed mismatch, for the UI's explicit re-trust
    /// flow. The old pin remains authoritative until the user confirms.
    var pendingHostKeyReplacement: HostKeyReplacement? { trust.offeredReplacement }
    private(set) var report: PreflightReport? {
        get { checks.facts.report }
        set { updateChecksFacts { $0.report = newValue } }
    }
    private(set) var serverInfo: ServerInfo? {
        get { checks.facts.serverInfo }
        set { updateChecksFacts { $0.serverInfo = newValue } }
    }
    /// Which backends the Host has, from the run's detection exec. Starts as
    /// the Console's last known presence so the right checklist shows while
    /// the first run is in flight.
    var presence: HostBackendPresence? { checks.facts.presence }
    /// The soft Status hooks check on a Host with usable tmux or herdr-core;
    /// nil on a herdr-only Host or before it ran.
    private(set) var statusHooks: StatusHooksState? {
        get { checks.facts.statusHooks }
        set { updateChecksFacts { $0.statusHooks = newValue } }
    }
    private var hooksInstall = StatusHooksInstallMachine()
    var isInstallingStatusHooks: Bool { hooksInstall.isInstalling }
    /// Why the last Install Status Hooks press failed; nil after a success.
    var statusHooksInstallError: String? { hooksInstall.error }
    private(set) var availableSessions: [HerdrSession] {
        get { checks.facts.sessions }
        set { updateChecksFacts { $0.sessions = newValue } }
    }
    private(set) var sessionDiscoveryError: String? {
        get { checks.facts.discoveryError }
        set { updateChecksFacts { $0.discoveryError = newValue } }
    }
    private var moshTest = HostMoshTestMachine()
    var moshSupport: MoshSupportState { moshTest.support }

    let host: Host

    @ObservationIgnored private let connector: any TransportConnector
    @ObservationIgnored private let knownHosts: any KnownHostsStore
    @ObservationIgnored private let credentials: HostCredentialsProvider
    /// The pending first-connect decision. It waits for the user however long
    /// they take: the transport dials again once they trust the key, so the
    /// connection that presented it may expire meanwhile. Only the page going
    /// away or the Host turning off declines it for them: a cancelled run,
    /// the page's `onDisappear` for a run a button started, or
    /// `setHostEnabled(false)`.
    @ObservationIgnored private var fingerprintDecision:
        (token: UInt64, continuation: CheckedContinuation<Bool, Never>)?
    /// Test seam: when set, a cancelled probe's decline runs through it on
    /// the main actor (the hook calls `decline` when it chooses), so a test
    /// can hold the cancellation hop while a new question appears. Nil in
    /// production, where the hop declines at once, as before.
    @ObservationIgnored var cancellationHop: (@MainActor (_ decline: @MainActor () -> Void) async -> Void)?
    /// Whether the Host is enabled now; `host` keeps the value at creation.
    /// While false nothing here dials it. See `setHostEnabled`.
    var isHostEnabled: Bool { checks.isEnabled }

    init(
        host: Host,
        connector: any TransportConnector = SSHTransportConnector(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        knownPresence: HostBackendPresence? = nil
    ) {
        self.host = host
        self.connector = connector
        self.knownHosts = knownHosts
        self.credentials = credentials
        checks = HostChecksMachine(enabled: host.isEnabled, presence: knownPresence)
    }

    /// The backend preflight connects to: the herdr slot whenever a herdr
    /// runtime is installed (its failures stay that runtime's), else tmux
    /// (design §4.1). With both runtimes installed the TUI leads.
    var primaryBackend: HostBackend {
        Self.primaryBackend(for: presence)
    }

    /// The one rule for which backend a Host's checks dial; unknown
    /// presence means herdr, as before tmux support. With both runtimes,
    /// a Host always dials the TUI.
    nonisolated static func primaryBackend(
        for presence: HostBackendPresence?
    ) -> HostBackend {
        presence?.herdrSlot ?? presence?.backends.first ?? .herdr
    }

    /// The Host's installed backends, nil before any detection.
    var resolvedBackends: [HostBackend]? {
        presence?.backends
    }

    /// A herdr runtime and tmux are both present, so Host detail offers the
    /// tmux controls.
    var isDualBackend: Bool {
        guard let backends = resolvedBackends else { return false }
        return backends.contains(.tmux)
            && (backends.contains(where: \.fillsHerdrSlot) || backends.contains(.zellij))
    }

    var hasZellij: Bool { presence?.zellij?.meetsFloor == true }

    /// The Host has a usable tmux.
    var hasTmux: Bool {
        presence?.tmuxUsable ?? false
    }

    /// Waycar's status hooks apply here: tmux Agents report through them,
    /// and so do herdr-core's (notifications and Chat Mode; core's own
    /// status needs none).
    var hasStatusHooks: Bool {
        hasTmux || hasZellij || resolvedBackends?.contains(.core) == true
    }

    /// Runs the preflight once: detect backends, connect to the primary one
    /// and ping, rendered into `report`.
    func runChecks() async {
        var effects = checks.handle(.request)
        while !effects.isEmpty {
            let effect = effects.removeFirst()
            switch effect {
            case .run(let token):
                await runChecksOnce(epoch: token)
                effects += checks.handle(.ended(token))
            }
        }
    }

    private func updateChecksFacts(_ update: (inout HostChecksMachine.Facts) -> Void) {
        var facts = checks.facts
        update(&facts)
        _ = checks.handle(.factsChanged(facts))
    }

    private func runChecksOnce(epoch: UInt64) async {
        _ = hooksInstall.handle(.checksStarted)
        _ = trust.handle(.checksStarted)

        let resolved: SSHCredentials
        do {
            resolved = try credentials.credentials(for: host)
        } catch HostCredentialsError.passwordNotSet {
            report = .failure(
                check: .connection,
                hint: "No password is saved for this Host. Edit the Host and enter one.",
                backend: primaryBackend)
            return
        } catch DeviceKeyStoreError.storedKeyCorrupt {
            report = .failure(.deviceKeyCorrupt, authMethod: host.authMethod, backend: primaryBackend)
            return
        } catch RSAKeyStoreError.storedKeyCorrupt {
            report = .failure(.rsaKeyCorrupt, authMethod: host.authMethod, backend: primaryBackend)
            return
        } catch {
            report = .failure(
                check: .connection,
                hint: "Could not load this Host's credentials. (\(error))",
                backend: primaryBackend)
            return
        }

        let settings = transportSettings(with: resolved)
        do {
            let detected = try await connector.detectBackends(settings: settings)
            guard checksAreCurrent(epoch) else { return }
            _ = checks.handle(.detected(epoch, detected))
        } catch {
            guard checksAreCurrent(epoch) else { return }
            captureHostKeyReplacement(error)
            report = failureReport(error, backend: primaryBackend)
            return
        }
        let backend = primaryBackend
        // tmux alone but below the floor: detection already proved the
        // connection, so fail the tmux check without dialing a control client.
        if backend == .tmux, let presence, let found = presence.tmuxVersion, !presence.tmuxUsable {
            report = .failure(.tmuxTooOld(found: found), authMethod: host.authMethod, backend: .tmux)
            return
        }
        // herdr-core's checks: found and at or above the floor (from the
        // detection that just ran), then hello and one events.subscribe over
        // its transport.
        if backend == .core, let presence {
            let found = PreflightReport.core(presence: presence)
            let result: PreflightReport? = found.isFullyPassed
                ? await runCoreChecks(settings: settings, epoch: epoch) : found
            guard checksAreCurrent(epoch) else { return }
            report = result
            await readStatusHooksBesideHerdrSlot(backend: backend, epoch: epoch)
            return
        }

        do {
            let transport = try await connector.connect(settings: settings, backend: backend)
            guard checksAreCurrent(epoch) else {
                try? await transport.close()
                return
            }
            // Ping first: it is the check, and the first message a new
            // connection should carry. A request that runs out of time
            // leaves the SSH connection unusable, so session discovery runs
            // only on a connection that is still up, and nothing is sent on
            // one an earlier request already lost.
            var answered: ServerInfo?
            do {
                let info = try await transport.ping()
                guard checksAreCurrent(epoch) else {
                    try? await transport.close()
                    return
                }
                serverInfo = info
                answered = info
                if info.backend == .herdr {
                    report = .allPassed
                } else if !info.backend.hasTerminal {
                    report = .passed(on: info.backend)
                }
            } catch {
                guard checksAreCurrent(epoch) else {
                    try? await transport.close()
                    return
                }
                captureHostKeyReplacement(error)
                report = failureReport(error, backend: backend)
            }
            let isConnected = await transport.isConnected
            guard checksAreCurrent(epoch) else {
                try? await transport.close()
                return
            }
            if isConnected {
                if backend == .herdr {
                    // Named sessions are herdr's alone.
                    do {
                        let sessions = try await transport.listSessions()
                        guard checksAreCurrent(epoch) else {
                            try? await transport.close()
                            return
                        }
                        availableSessions = sessions
                    } catch {
                        guard checksAreCurrent(epoch) else {
                            try? await transport.close()
                            return
                        }
                        sessionDiscoveryError = "Could not discover herdr sessions. You can still enter a session name manually."
                    }
                } else if answered?.backend == .tmux || answered?.backend == .zellij {
                    let hooks = await Self.statusHooks(from: transport)
                    guard checksAreCurrent(epoch) else {
                        try? await transport.close()
                        return
                    }
                    statusHooks = hooks
                }
            }
            // Preflight only probes; the Console owns long-lived connections.
            try? await transport.close()
            guard checksAreCurrent(epoch) else { return }
            if let answered, answered.backend == .tmux || answered.backend == .zellij {
                report = .passed(on: answered.backend, statusHooks: statusHooks)
            }
        } catch {
            guard checksAreCurrent(epoch) else { return }
            captureHostKeyReplacement(error)
            report = failureReport(error, backend: backend)
            return
        }

        await readStatusHooksBesideHerdrSlot(backend: backend, epoch: epoch)
    }

    private func checksAreCurrent(_ epoch: UInt64) -> Bool {
        checks.accepts(epoch)
    }

    /// herdr-core's transport checks: the connect line and `hello`, a
    /// `server.status` round trip, and one `events.subscribe`. Probes only;
    /// the Console owns long-lived connections.
    private func runCoreChecks(
        settings: SSHTransportSettings, epoch: UInt64
    ) async -> PreflightReport? {
        let transport: any Transport
        do {
            transport = try await connector.connect(settings: settings, backend: .core)
        } catch {
            guard checksAreCurrent(epoch) else { return nil }
            captureHostKeyReplacement(error)
            return failureReport(error, backend: .core)
        }
        guard checksAreCurrent(epoch) else {
            try? await transport.close()
            return nil
        }
        let result: PreflightReport
        do {
            let info = try await transport.ping()
            guard checksAreCurrent(epoch) else {
                try? await transport.close()
                return nil
            }
            serverInfo = info
            do {
                let events = try await transport.subscribeToEvents([])
                await events.end()
                guard checksAreCurrent(epoch) else {
                    try? await transport.close()
                    return nil
                }
                result = .passed(on: .core)
                // Waycar's status hooks are the Host tools' too: a core Host
                // with no tmux reads them here, over the same connection.
                if hasStatusHooks, !hasTmux {
                    let hooks = await Self.statusHooks(from: transport)
                    guard checksAreCurrent(epoch) else {
                        try? await transport.close()
                        return nil
                    }
                    statusHooks = hooks
                }
            } catch {
                guard checksAreCurrent(epoch) else {
                    try? await transport.close()
                    return nil
                }
                result = .failure(
                    check: .coreEvents,
                    hint: "herdr-core answered but would not stream its terminals. "
                        + Self.explanation(of: error),
                    backend: .core)
            }
        } catch {
            try? await transport.close()
            guard checksAreCurrent(epoch) else { return nil }
            captureHostKeyReplacement(error)
            return failureReport(error, backend: .core)
        }
        try? await transport.close()
        guard checksAreCurrent(epoch) else { return nil }
        return result
    }

    /// A dual Host's checklist is its herdr runtime's; its tmux side still
    /// gets the soft hooks check for Host detail's Status hooks section. (A
    /// herdr-core Host with no tmux reads it over the checks' own core
    /// connection, `runCoreChecks`.)
    private func readStatusHooksBesideHerdrSlot(backend: HostBackend, epoch: UInt64) async {
        guard checksAreCurrent(epoch), backend.fillsHerdrSlot, hasTmux || hasZellij,
            report?.isFullyPassed == true
        else { return }
        do {
            let hooks = try await withStatusHooksTransport(checksEpoch: epoch) {
                await Self.statusHooks(from: $0)
            }
            guard checksAreCurrent(epoch) else { return }
            statusHooks = hooks
        } catch {
            guard checksAreCurrent(epoch) else { return }
            statusHooks = .unreadable(Self.explanation(of: error))
        }
    }

    /// Install Status Hooks on Host detail: runs `waycar hooks install` over a
    /// tmux connection (herdr-core's on a Host with no tmux) and shows the
    /// Host tools' fresh report.
    func installStatusHooks() async {
        guard isHostEnabled, !isInstallingStatusHooks, hasStatusHooks else { return }
        for effect in hooksInstall.handle(.install) {
            switch effect {
            case .connect(let token):
                await installStatusHooks(token: token)
            case .install, .publish:
                break // Only a connected/completed event can emit these.
            }
        }
    }

    private func installStatusHooks(token: UInt64) async {
        defer { _ = hooksInstall.handle(.ended(token)) }
        do {
            let installed = try await withStatusHooksTransport { transport in
                guard self.hooksInstall.handle(.connected(token)) == [.install(token)] else {
                    throw CancellationError()
                }
                return try await transport.installStatusHooks()
            }
            for effect in hooksInstall.handle(.completed(token, installed)) {
                switch effect {
                case .publish(let fresh):
                    statusHooks = .reported(fresh)
                    if let current = report, current.backend == .tmux || current.backend == .zellij, current.isFullyPassed {
                        report = .passed(on: current.backend, statusHooks: statusHooks)
                    }
                case .connect, .install:
                    break
                }
            }
        } catch {
            _ = hooksInstall.handle(.failed(
                token, "Could not install the status hooks. \(Self.explanation(of: error))"))
        }
    }

    /// Reads the soft Status hooks check. A link failure says so; any other
    /// failure means the Host tools that answer it are not there.
    static func statusHooks(from transport: any Transport) async -> StatusHooksState {
        do {
            return .reported(try await transport.statusHooksReport())
        } catch let error as TransportError {
            switch error {
            case .timedOut, .cancelled, .sshUnreachable, .jumpHostFailed:
                return .unreadable(error.presentation.explanation)
            default:
                return .hostToolsMissing
            }
        } catch {
            return .hostToolsMissing
        }
    }

    private static func explanation(of error: any Error) -> String {
        (error as? TransportError)?.presentation.explanation ?? "\(error)"
    }

    /// Dials the Host's tmux backend for one operation, closing it after;
    /// herdr-core's when the Host has no usable tmux. The status hooks are the
    /// Host tools' either way.
    private func withStatusHooksTransport<Value: Sendable>(
        checksEpoch epoch: UInt64? = nil,
        _ operation: @MainActor (any Transport) async throws -> Value
    ) async throws -> Value {
        let settings = transportSettings(with: try credentials.credentials(for: host))
        let transport = try await connector.connect(
            settings: settings, backend: hasTmux ? .tmux : (hasZellij ? .zellij : .core))
        do {
            if let epoch, !checksAreCurrent(epoch) { throw CancellationError() }
            let value = try await operation(transport)
            try? await transport.close()
            return value
        } catch {
            try? await transport.close()
            throw error
        }
    }

    /// The checks' settings. They never share the Console's pooled
    /// connection (nil `poolKey`): each probe dials its own, as before
    /// pooling, so a check cannot queue behind the Console's channels, such
    /// as the one tmux control slot its live transport holds.
    private func transportSettings(with resolved: SSHCredentials) -> SSHTransportSettings {
        Self.probeSettings(host: host, credentials: resolved, knownHosts: knownHosts) {
            [weak self] candidate in
            await self?.awaitFingerprintDecision(for: candidate) ?? false
        }
    }

    /// Settings for one Host-detail probe or action on its own connection
    /// (nil `poolKey`), shared with the plugin update sheet.
    nonisolated static func probeSettings(
        host: Host,
        credentials resolved: SSHCredentials,
        knownHosts: any KnownHostsStore,
        confirmFirstConnect: @escaping @Sendable (HostKeyCandidate) async -> Bool
    ) -> SSHTransportSettings {
        let policy = HostKeyPolicy(knownHosts: knownHosts, confirmFirstConnect: confirmFirstConnect)
        var settings = SSHTransportSettings(host: host, credentials: resolved, hostKeyPolicy: policy)
        settings.poolKey = nil
        return settings
    }

    /// The user's verdict on the pending fingerprint.
    func confirmFingerprint(trusted: Bool) {
        sendTrust(.answered(trusted: trusted))
    }

    /// Keeps the store in step with the page's Host: the page outlives an
    /// enablement change, and a run a button started is not cancelled with
    /// it. Turning the Host off invalidates pending checks and declines a
    /// pending fingerprint; their next remote step must not dial this Host.
    func setHostEnabled(_ isEnabled: Bool) {
        _ = checks.handle(.enabled(isEnabled))
        if !isEnabled {
            _ = hooksInstall.handle(.disabled)
            _ = moshTest.handle(.disabled)
            sendTrust(.answered(trusted: false))
        }
    }

    /// Tap-to-test on the Host detail page: connects with this Host's
    /// credentials and runs the REAL mosh handshake proof (bootstrap +
    /// live UDP session attempt), not just a binary-presence check.
    func runMoshSupportCheck() async {
        guard isHostEnabled, moshSupport != .testing else { return }
        for effect in moshTest.handle(.test) {
            switch effect {
            case .connect(let token): await runMoshSupportCheck(token: token)
            case .probe: break // Emitted only after connecting.
            }
        }
    }

    private func runMoshSupportCheck(token: UInt64) async {
        defer { _ = moshTest.handle(.ended(token)) }
        let resolved: SSHCredentials
        do {
            resolved = try credentials.credentials(for: host)
        } catch {
            _ = moshTest.handle(.completed(token, .unavailable("The Host probe could not run.")))
            return
        }
        let settings = transportSettings(with: resolved)
        do {
            let transport = try await connector.connect(settings: settings)
            defer { Task { try? await transport.close() } }
            guard moshTest.handle(.connected(token)) == [.probe(token)] else { return }
            let available = try await transport.probeMoshServer()
            _ = moshTest.handle(.completed(token, available
                ? .available
                : .unavailable(
                    "The Host has mosh-server but the UDP handshake did not "
                        + "complete — sessions will use SSH.")))
        } catch let error as TransportError {
            _ = moshTest.handle(.completed(token, .unavailable(Self.moshFailureDetail(error))))
        } catch {
            _ = moshTest.handle(.completed(token, .unavailable("The mosh probe could not run. (\(error))")))
        }
    }

    /// Renders a probe failure for the Host detail row: mosh session
    /// failures carry the library's own output tail (the concrete reason).
    nonisolated static func moshFailureDetail(_ error: TransportError) -> String {
        switch error {
        case .moshSessionFailed(let detail):
            detail
        case .timedOut:
            "The mosh handshake timed out."
        case .sshUnreachable(let detail):
            "Could not reach the Host over SSH. (\(detail))"
        default:
            error.presentation.explanation
        }
    }

    /// The public-key command only. Corrupt keys are never replaced here.
    func deviceKeyInstallCommand() throws -> String {
        let line = try credentials.deviceKey().authorizedKeysLine(comment: "waycar")
        return Self.deviceKeyInstallCommand(authorizedKeysLine: line)
    }

    nonisolated static func deviceKeyInstallCommand(authorizedKeysLine line: String) -> String {
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo \(ShellWord.quoted(line))"
            + " >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    }

    /// Like Edit Host and session selection, changing the saved record
    /// recreates this page's store and its arrival task reruns the checks.
    /// HostStore removes the saved password when authentication changes.
    func useDeviceKey(in catalog: HostStore) throws {
        guard isHostEnabled, phase != .running, report?.needsDeviceKey == true else { return }
        _ = try credentials.deviceKey()
        var updated = host
        updated.authMethod = .deviceKey
        try catalog.update(updated)
    }

    /// Persists a discovered session through the Host catalog. The enclosing
    /// navigation destination is keyed by the Host value, so this recreates
    /// onboarding and immediately checks the selected socket.
    func selectSession(_ session: HerdrSession, in catalog: HostStore) throws {
        var updated = host
        updated.sessionName = session.isDefault ? "" : session.name
        try catalog.update(updated)
    }

    /// Replaces a mismatched pin only after the UI has obtained an explicit
    /// confirmation, then immediately proves the new pin by rerunning preflight.
    func trustPresentedHostKey() async {
        await performTrust(trust.handle(
            .replacementConfirmed(hostEnabled: isHostEnabled, checksRunning: phase == .running)))
    }

    private func captureHostKeyReplacement(_ error: any Error) {
        guard case let TransportError.hostKeyMismatch(known, presented) = error else { return }
        _ = trust.handle(.mismatched(HostKeyReplacement(known: known, presented: presented)))
    }

    private func failureReport(_ error: any Error, backend: HostBackend) -> PreflightReport {
        if let transportError = error as? TransportError {
            .failure(
                transportError, authMethod: host.authMethod, backend: backend,
                hostName: host.displayName)
        } else {
            .failure(
                check: .connection,
                hint: "The connection failed unexpectedly. (\(error))",
                backend: backend)
        }
    }

    private func awaitFingerprintDecision(for candidate: HostKeyCandidate) async -> Bool {
        // One connect per run means one candidate at a time; decline a
        // second defensively instead of leaking the first continuation.
        // A Disabled Host is never contacted: decline rather than ask.
        guard case .wait(let token) = trust.handle(.asked(candidate, hostEnabled: isHostEnabled)).first
        else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                fingerprintDecision = (token, continuation)
                if Task.isCancelled { sendTrust(.cancelled(token)) }
            }
        } onCancel: {
            Task { @MainActor in
                if let hop = self.cancellationHop {
                    await hop { self.sendTrust(.cancelled(token)) }
                } else {
                    self.sendTrust(.cancelled(token))
                }
            }
        }
    }

    private func sendTrust(_ event: HostKeyTrustMachine.Event) {
        for effect in trust.handle(event) {
            switch effect {
            case .resolve(let token, let trusted):
                guard let decision = fingerprintDecision, decision.token == token else { continue }
                fingerprintDecision = nil
                decision.continuation.resume(returning: trusted)
            case .wait, .decline, .writePin, .runChecks:
                break // Only a question or a confirmed replacement emits these.
            }
        }
    }

    private func performTrust(_ effects: [HostKeyTrustMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .writePin(let token, let fingerprint):
                await knownHosts.setFingerprint(fingerprint, host: host.address, port: host.port)
                await performTrust(trust.handle(.pinWritten(token)))
            case .runChecks:
                await runChecks()
            case .wait, .decline, .resolve:
                break // Only a question or an answer emits these.
            }
        }
    }
}
