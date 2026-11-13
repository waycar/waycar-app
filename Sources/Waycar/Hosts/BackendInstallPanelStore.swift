import Observation
import SwiftUI

/// One Host's install panel (WAY-338): what the card on New Agent and on the
/// Console banner's sheet offers, and the consent, progress and result
/// sheet those buttons open. The runs themselves belong to
/// `BackendInstallCenter`, so a hidden or dismissed sheet loses nothing and
/// another window sees the same progress.
///
/// The sheet shows, in this order: the run in flight, the consent for a plan
/// the user chose, the last outcome. Consent is asked every time, for every
/// run: Retry and Install Herdr TUI instead go through it again.
@MainActor
@Observable
final class BackendInstallPanelStore: Identifiable {
    /// What the preflight read found, which decides the Install buttons.
    enum PreflightState: Equatable, Sendable {
        case loading
        case ready(HostInstallPreflight)
        /// The Host could not be read; the message is user-facing.
        case failed(String)
    }

    /// What the sheet shows.
    enum Sheet: Equatable {
        case consent(BackendInstallPlan)
        case running(BackendInstallCenter.Run)
        case outcome(BackendInstallCenter.Outcome)
    }

    let host: Host

    private var probes = BackendInstallProbeMachine()
    var preflight: PreflightState { probes.presentation }
    /// A plan the user tapped Install on and has not confirmed.
    private(set) var pendingPlan: BackendInstallPlan?
    /// Why the confirmed plan could not start (credentials missing).
    private(set) var startFailure: String?
    var isChecking: Bool { probes.isChecking }
    /// What the last Check Again said when it found nothing new.
    var checkNote: String? { probes.checkNote }
    /// Whether Copy Command was just tapped, for its "Copied" label.
    private(set) var didCopyCommand = false
    /// Whether the sheet is up. Hide and a swipe down clear it without
    /// touching a run.
    private(set) var isSheetPresented = false

    @ObservationIgnored private let center: BackendInstallCenter
    /// The Host's last detected presence, read each time so the panel
    /// follows the Console.
    @ObservationIgnored private let presence: @MainActor () -> HostBackendPresence?
    /// Records a Check Again that found nothing usable (a newer tmux, say).
    @ObservationIgnored private let recordPresence: @MainActor (HostBackendPresence) -> Void
    /// Reports a backend found by Check Again: records it and reconnects.
    @ObservationIgnored private let foundBackend: @MainActor (HostBackendPresence) -> Void
    @ObservationIgnored private let credentials: HostCredentialsProvider
    @ObservationIgnored private let knownHosts: any KnownHostsStore

    init(
        host: Host,
        center: BackendInstallCenter,
        presence: @escaping @MainActor () -> HostBackendPresence?,
        recordPresence: @escaping @MainActor (HostBackendPresence) -> Void,
        foundBackend: @escaping @MainActor (HostBackendPresence) -> Void,
        credentials: HostCredentialsProvider = HostCredentialsProvider(),
        knownHosts: any KnownHostsStore = UserDefaultsKnownHostsStore.shared
    ) {
        self.host = host
        self.center = center
        self.presence = presence
        self.recordPresence = recordPresence
        self.foundBackend = foundBackend
        self.credentials = credentials
        self.knownHosts = knownHosts
    }

    // MARK: Reading

    var gap: HostBackendGap? { HostBackendGap(presence: presence()) }

    /// The run on this Host, in this window or another.
    var run: BackendInstallCenter.Run? { center.runs[host.id] }

    /// The last finished run's screen, while it is unseen.
    var outcome: BackendInstallCenter.Outcome? { center.outcomes[host.id] }

    var outcomeScreen: BackendInstallOutcomeScreen? {
        outcome.map { BackendInstallOutcomeScreen(outcome: $0, hostName: host.displayName) }
    }

    /// Whether the card has anything to say: the Host lacks a backend, or a
    /// run is still on it.
    var showsCard: Bool { gap != nil || run != nil }

    var sheet: Sheet? {
        guard isSheetPresented else { return nil }
        if let run { return .running(run) }
        if let pendingPlan { return .consent(pendingPlan) }
        if let outcome { return .outcome(outcome) }
        return nil
    }

    /// `account@host`, as the consent sheet's "Runs as" row.
    var account: String { "\(host.username)@\(host.address)" }

    /// The plan an Install Herdr TUI button runs; nil until the preflight says
    /// herdr can be installed there, and why not in `herdrUnavailableReason`.
    var herdrPlan: BackendInstallPlan? { plan(installing: .herdr) }

    /// The plan an Install tmux button runs: only on a Host with no tmux,
    /// and only once the preflight found a manager Waycar can run.
    var tmuxPlan: BackendInstallPlan? {
        guard gap?.offersTmux == true else { return nil }
        return plan(installing: .tmux)
    }

    /// The plan an Install herdr-core button runs (WAY-483): on any Host the
    /// panel offers an install on, once the preflight says core can be
    /// installed there. Its reason is `coreUnavailableReason`.
    var corePlan: BackendInstallPlan? {
        guard gap?.offersCore == true else { return nil }
        return plan(installing: .core)
    }

    /// Why Install Herdr TUI is missing, from the preflight; nil while it
    /// shows or while the preflight has not answered.
    var herdrUnavailableReason: String? {
        guard case .ready(let facts) = preflight,
            case .failure(let failure) = BackendInstallPlan.make(installing: .herdr, preflight: facts)
        else { return nil }
        switch failure {
        case .noCurl: return "\(host.displayName) has no curl. herdr’s installer needs it."
        case .unsupportedSystem: return "herdr does not support the system on \(host.displayName)."
        default: return nil
        }
    }

    /// Why Install herdr-core is missing, from the preflight.
    var coreUnavailableReason: String? {
        guard gap?.offersCore == true, case .ready(let facts) = preflight,
            case .failure(let failure) = BackendInstallPlan.make(installing: .core, preflight: facts)
        else { return nil }
        switch failure {
        case .noCurl: return "\(host.displayName) has no curl. herdr-core’s installer needs it."
        case .unsupportedSystem: return "herdr-core does not support the system on \(host.displayName)."
        default: return nil
        }
    }

    /// Why Install tmux is missing on a Host that has no tmux.
    var tmuxUnavailableReason: String? {
        guard gap?.offersTmux == true, case .ready(let facts) = preflight,
            case .failure(let failure) = BackendInstallPlan.make(installing: .tmux, preflight: facts)
        else { return nil }
        switch failure {
        case .noPackageManager:
            return "Waycar did not find a package manager it can use on \(host.displayName)."
        case .unsupportedSystem: return "herdr does not support the system on \(host.displayName)."
        default: return nil
        }
    }

    private func plan(installing backend: HostBackend) -> BackendInstallPlan? {
        guard case .ready(let facts) = preflight,
            case .success(let plan) = BackendInstallPlan.make(installing: backend, preflight: facts)
        else { return nil }
        return plan
    }

    /// The "On this Host now" rows of the consent sheet.
    var herdrRowValue: String {
        presence()?.herdr == true ? "Found" : "Not found"
    }

    var tmuxRowValue: String {
        presence()?.tmuxVersion.map { "Version \($0)" } ?? "Not found"
    }

    // MARK: Actions

    /// Reads the Host once for the Install buttons. Skipped while a run is
    /// on the Host, which shows its progress instead, and once answered.
    /// A found outcome the user never opened is spent: the Console already
    /// reconnected the Host.
    func loadPreflight() async {
        guard run == nil else { return }
        if case .found? = outcome?.result { center.dismissOutcome(for: host.id) }
        await perform(probes.handle(.load))
    }

    /// Install Herdr TUI, Install tmux or Install herdr-core: opens the
    /// consent sheet. An earlier run's outcome is spent.
    func chooseInstall(_ plan: BackendInstallPlan) {
        center.dismissOutcome(for: host.id)
        startFailure = nil
        didCopyCommand = false
        pendingPlan = plan
        isSheetPresented = true
    }

    /// Install on the consent sheet. Nothing ran before this tap.
    func confirmInstall() {
        guard let plan = pendingPlan else { return }
        let settings: SSHTransportSettings
        do {
            settings = try makeSettings()
        } catch {
            startFailure = WaycarPluginUpdateStore.message(for: error)
            return
        }
        pendingPlan = nil
        startFailure = nil
        // False means another window's run is already on this Host: the
        // sheet shows that run.
        center.start(plan, on: host.id, settings: settings)
    }

    /// Cancel on the consent sheet: nothing runs.
    func cancelConsent() {
        pendingPlan = nil
        startFailure = nil
        isSheetPresented = false
    }

    /// Hide on a running install, and a swipe down on any screen of the
    /// sheet. The run goes on; a consent not confirmed is cancelled; an
    /// outcome that was on screen has been seen.
    func hide() {
        isSheetPresented = false
        pendingPlan = nil
        startFailure = nil
        if run == nil, outcome != nil { center.dismissOutcome(for: host.id) }
    }

    /// Show on the progress row, or on the failure row of a run that ended
    /// while the sheet was hidden.
    func show() {
        didCopyCommand = false
        isSheetPresented = true
    }

    /// The result screen's Done or Close.
    func finish() {
        hide()
    }

    /// The sheet is gone with no tap on it: another window took the run's
    /// outcome, or Check Again found the backend. The next run or outcome
    /// must not open it by itself.
    func sheetEnded() {
        isSheetPresented = false
    }

    /// The failure screen's Retry: the same install again, asking again.
    func retry(_ plan: BackendInstallPlan) {
        chooseInstall(plan)
    }

    /// Install Herdr TUI instead, and 6c's Install Herdr TUI: herdr's consent.
    func installHerdr() {
        guard let plan = herdrPlan else { return }
        chooseInstall(plan)
    }

    func copy(_ command: String) {
        UIPasteboard.general.string = command
        didCopyCommand = true
    }

    /// Asks the Host again, with no install: for a user who installed by
    /// another route. A backend found reconnects the Host and closes the
    /// sheet. Otherwise a line says what the check found, and the Install
    /// buttons are read again.
    func checkAgain() async {
        await perform(probes.handle(.checkAgain))
    }

    private func perform(_ effects: [BackendInstallProbeMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .read(let token):
                let event: BackendInstallProbeMachine.Event
                do {
                    let settings = try makeSettings()
                    event = .preflightReady(token, try await center.preflight(settings: settings))
                } catch {
                    event = .preflightFailed(token, WaycarPluginUpdateStore.message(for: error))
                }
                await perform(probes.handle(event))
            case .detect(let token):
                let event: BackendInstallProbeMachine.Event
                do {
                    let settings = try makeSettings()
                    event = .detected(token, try await center.detectBackends(settings: settings))
                } catch {
                    event = .detectionFailed(token, WaycarPluginUpdateStore.message(for: error))
                }
                await perform(probes.handle(event))
                await perform(probes.handle(.checkEnded(token)))
            case .found(let found):
                // Check Again is diagnostic: a stopped runtime stays stopped.
                center.dismissOutcome(for: host.id)
                pendingPlan = nil
                isSheetPresented = false
                foundBackend(found)
                let what = found.herdr ? "herdr" : found.coreFound ? "herdr-core" : "tmux"
                AccessibilityNotification.Announcement("\(what) found on \(host.displayName).").post()
            case .record(let found):
                recordPresence(found)
            case .announce(let note):
                AccessibilityNotification.Announcement(note).post()
            }
        }
    }

    /// The same trusted-credentials settings the plugin update runs with: a
    /// run never prompts for a host key from inside the panel.
    private func makeSettings() throws -> SSHTransportSettings {
        let resolved = try credentials.credentials(for: host)
        return HostOnboardingStore.probeSettings(
            host: host, credentials: resolved, knownHosts: knownHosts
        ) { _ in false }
    }
}

extension BackendInstallPanelStore {
    /// The panel of `host` on `console`: it reads the Host's presence from
    /// the Console, and reports a Check Again's answer back to it.
    convenience init(host: Host, center: BackendInstallCenter, console: ConsoleStore) {
        let hostID = host.id
        self.init(
            host: host, center: center,
            presence: { console.backendPresence(on: hostID) },
            recordPresence: { console.recordDetectedPresence($0, on: hostID) },
            foundBackend: { console.backendFound(on: hostID, presence: $0) })
    }
}
