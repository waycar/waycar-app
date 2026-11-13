import Foundation
import Observation

/// Runs "Install herdr" and "Install tmux" on Hosts (WAY-338) and remembers
/// how each Host's last run went. One instance lives on the app model, so
/// every window and screen sees the same runs: a second window, the Console
/// banner or a reopened New Agent cannot start a second install on a Host
/// that has one, and shows its progress instead.
///
/// The center owns each run's task. Hiding or dismissing the sheet that
/// started it neither cancels it nor loses its outcome: the installer keeps
/// going on the Host either way, and `outcomes` keeps the result until
/// someone dismisses it.
///
/// A run is the install, then a fresh backend detection. It is found only
/// when that detection finds the tool (ADR 0023); a failed install is never
/// reported as installed. After a Herdr TUI or Core install the center
/// starts that server once. That start answers the user's Install tap;
/// otherwise only Start Herdr TUI / Start Herdr Core may start it (#389).
@MainActor
@Observable
final class BackendInstallCenter {
    enum Phase: Equatable, Sendable {
        /// The installer runs; the latest line it printed, if any yet.
        case installing(latestLine: String?)
        /// The installer exited cleanly; the Host is being detected again.
        case checking
    }

    /// An install in flight on one Host.
    struct Run: Equatable, Sendable {
        /// How many of the installer's latest lines `output` keeps, for the
        /// progress sheet's log.
        static let outputLimit = 40

        let plan: BackendInstallPlan
        var phase: Phase
        /// The installer's latest lines, oldest first.
        var output: [String] = []
    }

    /// A finished install, kept until `dismissOutcome(for:)` or the next
    /// run on the Host.
    struct Outcome: Equatable, Sendable {
        let plan: BackendInstallPlan
        let result: BackendInstallResult
    }

    /// Hosts with a run in flight. At most one per Host.
    var runs: [Host.ID: Run] { machines.compactMapValues(\.run) }
    /// Each Host's last finished run.
    var outcomes: [Host.ID: Outcome] { machines.compactMapValues(\.outcome) }

    private var machines: [Host.ID: BackendInstallRunMachine] = [:]

    @ObservationIgnored private let connector: any TransportConnector
    /// Called on the main actor each time a run ends, after `outcomes` holds
    /// the result. The app model wires it to the Console, so a Host found
    /// by an install the user hid still reconnects.
    @ObservationIgnored var onOutcome: (@MainActor (Host.ID, Outcome) -> Void)?

    init(connector: any TransportConnector = SSHTransportConnector()) {
        self.connector = connector
    }

    /// Asks the Host which backends it has now: Check Again.
    func detectBackends(settings: SSHTransportSettings) async throws -> HostBackendPresence {
        try await connector.detectBackends(settings: settings)
    }

    /// What the Host has that decides which Install buttons to offer. Run
    /// when the panel opens, not on every backend detection.
    func preflight(settings: SSHTransportSettings) async throws -> HostInstallPreflight {
        try await connector.preflightInstall(settings: settings)
    }

    /// Starts `plan` on `hostID`. False, and nothing starts, when a run is
    /// already in flight there. `settings` must already hold trusted
    /// credentials: a run never prompts for a host key.
    @discardableResult
    func start(
        _ plan: BackendInstallPlan, on hostID: Host.ID, settings: SSHTransportSettings
    ) -> Bool {
        let effects = handle(.start(plan), on: hostID)
        guard !effects.isEmpty else { return false }
        Task { [self] in await perform(effects, on: hostID, settings: settings) }
        return true
    }

    /// The user saw the outcome.
    func dismissOutcome(for hostID: Host.ID) {
        _ = handle(.dismiss, on: hostID)
    }

    private func handle(
        _ event: BackendInstallRunMachine.Event, on hostID: Host.ID
    ) -> [BackendInstallRunMachine.Effect] {
        var machine = machines[hostID] ?? BackendInstallRunMachine()
        let effects = machine.handle(event)
        machines[hostID] = machine
        return effects
    }

    private func perform(
        _ effects: [BackendInstallRunMachine.Effect], on hostID: Host.ID, settings: SSHTransportSettings
    ) async {
        for effect in effects {
            let next: [BackendInstallRunMachine.Effect]
            switch effect {
            case .install(let token, let plan):
                let result = await install(plan, token: token, on: hostID, settings: settings)
                next = handle(.installerEnded(token, result), on: hostID)
            case .detect(let token):
                let result: Result<HostBackendPresence, TransportError>
                do { result = .success(try await connector.detectBackends(settings: settings)) }
                catch { result = .failure(Self.transportError(error)) }
                next = handle(.detected(token, result), on: hostID)
            case .startRuntime(let token, let target):
                // Recovery, not a diagnostic: installed even if start fails.
                switch target {
                case .herdr: try? await connector.wakeHerdr(settings: settings)
                case .core: try? await connector.startCore(settings: settings)
                case .tmux: break
                }
                next = handle(.runtimeEnded(token), on: hostID)
            case .report(let outcome):
                onOutcome?(hostID, outcome)
                next = []
            }
            await perform(next, on: hostID, settings: settings)
        }
    }

    private func install(
        _ plan: BackendInstallPlan, token: UInt64, on hostID: Host.ID, settings: SSHTransportSettings
    ) async -> Result<BackendInstallRun, TransportError> {
        // Drain every line before advancing the machine to detection.
        let (lines, sink) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        let follower = Task { [self] in
            for await line in lines { _ = handle(.output(token, line), on: hostID) }
        }
        let result: Result<BackendInstallRun, TransportError>
        do {
            result = .success(try await connector.runBackendInstall(
                settings: settings, plan: plan, progress: { line in sink.yield(line) }))
        } catch {
            result = .failure(Self.transportError(error))
        }
        sink.finish()
        await follower.value
        return result
    }

    private nonisolated static func transportError(_ error: any Error) -> TransportError {
        error as? TransportError ?? .channelFailed(detail: "\(error)")
    }
}
