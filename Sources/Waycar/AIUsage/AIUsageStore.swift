import Foundation
import Observation

/// Where CodexBar stands on one Host.
enum CodexBarDetection: Sendable, Equatable {
    /// Not probed on the current connection yet (or the Host is offline).
    case unknown
    case probing
    case found(path: String)
    case notFound
    /// The probe failed (it is retried) or the custom path is unusable (it
    /// is not: only the user can fix that).
    case failed(message: String)

    var path: String? {
        if case .found(let path) = self { return path }
        return nil
    }
}

/// One AI Usage report and when it arrived.
struct AIUsageSnapshot: Sendable, Equatable {
    let report: AIUsageReport
    let fetchedAt: Date
}

/// One Host's polling state. Each Host keeps its own, so switching the
/// source shows that Host's last report and fetches only once it is due.
struct AIUsageHostState: Sendable, Equatable {
    var snapshot: AIUsageSnapshot?
    /// Why the Host's most recent fetch failed; nil after a success.
    var lastFailure: String?
    var consecutiveFailures = 0
    /// When the most recent fetch finished; the next is due an interval
    /// (backed off by `consecutiveFailures`) later.
    var lastFinishedAt: Date?
}

/// The Host one Console window reads AI Usage from.
struct AIUsageSource: Sendable, Equatable {
    let hostID: Host.ID
    /// False while that Host cannot answer — reconnecting, suspended, or
    /// having CodexBar looked for again. What it last reported stays on
    /// screen, marked out of date, instead of disappearing.
    let isLive: Bool
}

/// AI Usage: CodexBar's per-provider rate-limit windows, read from a Host
/// over its live Console connection.
///
/// Usage belongs to the AI accounts, not to a Host, so each Console window
/// shows one report: from the Host that window is scoped to when that Host
/// has CodexBar, else from the first connected Host that does. Only the
/// Hosts some open window reads from are polled. CodexBar is probed once per
/// Host connection, again when its custom path changes or the user asks,
/// and a failed probe is retried with backoff. Polling runs only while the
/// app is in the foreground, one fetch at a time, each Host backing off on
/// its own failures.
///
/// A Host whose on/off choice is still undecided is decided the first time
/// CodexBar is found on it: on, unless another Host is already explicitly on
/// and not known to lack CodexBar, since each extra Host asks the same AI
/// accounts again. The user can still turn on as many Hosts as they like.
@MainActor
@Observable
final class AIUsageStore {
    var detections: [Host.ID: CodexBarDetection] {
        detectionMachines.mapValues(\.detection)
    }
    private var detectionMachines: [Host.ID: CodexBarDetectionMachine] = [:]
    private var polling = AIUsagePollingMachine()
    var usage: [Host.ID: AIUsageHostState] { polling.usage }
    /// The Host whose usage is being fetched; one fetch runs at a time.
    var fetchingHostID: Host.ID? { polling.fetchingHostID }
    let preferences: AIUsagePreferences

    private var hosts: [Host] = []
    @ObservationIgnored private let transports: any NotificationTransportProvider
    @ObservationIgnored private let connectionStatus: @MainActor (Host.ID) -> EventsSessionStatus?
    @ObservationIgnored private let connectionGeneration: @MainActor (Host.ID) -> UInt64?
    @ObservationIgnored private let now: @MainActor () -> Date
    /// The first wait before a failed probe runs again; it doubles per
    /// consecutive failure up to `AIUsagePollSchedule.maximumBackoff`.
    @ObservationIgnored private let probeRetryDelay: Duration
    /// The Host each open Console window is scoped to; a nil value is All
    /// Hosts, not an absent window.
    @ObservationIgnored private var windowScopes: [UUID: Host.ID?] = [:]
    @ObservationIgnored private var probeTasks: [CodexBarDetectionMachine.Token: Task<Void, Never>] = [:]
    @ObservationIgnored private var probeRetries: [CodexBarDetectionMachine.Token: Task<Void, Never>] = [:]
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var pollTasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var fetchTasks: [AIUsagePollingMachine.FetchToken: Task<Void, Never>] = [:]

    private var fetchTask: Task<Void, Never>? {
        polling.fetchToken.flatMap { fetchTasks[$0] }
    }

    init(
        preferences: AIUsagePreferences,
        transports: any NotificationTransportProvider,
        connectionStatus: @escaping @MainActor (Host.ID) -> EventsSessionStatus?,
        connectionGeneration: @escaping @MainActor (Host.ID) -> UInt64?,
        now: @escaping @MainActor () -> Date = { Date() },
        probeRetryDelay: Duration = .seconds(30)
    ) {
        self.preferences = preferences
        self.transports = transports
        self.connectionStatus = connectionStatus
        self.connectionGeneration = connectionGeneration
        self.now = now
        self.probeRetryDelay = probeRetryDelay
    }

    // MARK: Presentation

    /// The Host a window scoped to `scope` (nil: All Hosts) reads usage
    /// from: its live source, else — while no Host that could answer is
    /// connected — a Host still known to have CodexBar or holding a report,
    /// so the row keeps its place (showing "No data" without a report)
    /// through a reconnect or suspension instead of the list jumping. A Host
    /// where CodexBar is now definitely absent holds no place. nil hides the
    /// feature: no enabled Host with CodexBar found.
    func source(scopedTo scope: Host.ID?) -> AIUsageSource? {
        if let live = liveSourceHostID(scopedTo: scope) {
            return AIUsageSource(hostID: live, isLive: true)
        }
        let held = enabledHostIDs.filter { hostID in
            let detection = detections[hostID]
            return detection?.path != nil
                || (detection != .notFound && usage[hostID]?.snapshot != nil)
        }
        return Self.preferred(scope, among: held).map { AIUsageSource(hostID: $0, isLive: false) }
    }

    func hostName(_ hostID: Host.ID) -> String? {
        hosts.first { $0.id == hostID }?.displayName
    }

    func isStale(_ hostID: Host.ID, at date: Date) -> Bool {
        guard let snapshot = usage[hostID]?.snapshot else { return false }
        return AIUsagePollSchedule.isStale(
            fetchedAt: snapshot.fetchedAt, now: date, interval: interval(for: hostID))
    }

    func detection(for hostID: Host.ID) -> CodexBarDetection {
        detections[hostID] ?? .unknown
    }

    // MARK: Inputs

    /// Aligns with the Host catalog. An edited Host is forgotten like a
    /// removed one: the Console restarts its connection (generation and
    /// all), and what was found at the old address says nothing about the
    /// new one.
    func setHosts(_ hosts: [Host]) {
        let incoming = Dictionary(hosts.map { ($0.id, $0) }) { _, last in last }
        for host in self.hosts where incoming[host.id] != host { forget(host.id) }
        self.hosts = hosts
        connectionsDidChange()
    }

    /// Records the Host one Console window is scoped to (nil: All Hosts).
    func setScope(_ hostID: Host.ID?, forWindow window: UUID) {
        // `updateValue`, not subscript assignment: a nil scope is a value.
        guard windowScopes.updateValue(hostID, forKey: window) != .some(hostID) else { return }
        reschedule()
    }

    /// A closed window stops asking for its source.
    func removeWindow(_ window: UUID) {
        guard windowScopes.removeValue(forKey: window) != nil else { return }
        reschedule()
    }

    /// Probes Hosts that connected (or reconnected) since their last probe,
    /// then re-evaluates what to poll.
    func connectionsDidChange() {
        for host in hosts where preferences.settings(for: host.id).isEnabled {
            guard connectionStatus(host.id) == .connected,
                let generation = connectionGeneration(host.id),
                detectionMachines[host.id]?.generation != generation
            else { continue }
            probe(host.id, generation: generation)
        }
        reschedule()
    }

    /// Foreground only: polling stops when the app leaves the screen and
    /// resumes, fetching at once if due, when it returns.
    func setForeground(_ isForeground: Bool) {
        guard self.isForeground != isForeground else { return }
        self.isForeground = isForeground
        reschedule()
    }

    /// A change the user makes decides an undecided Host on, as its toggle
    /// shows; only Hosts the user never touched are decided by detection.
    func updateSettings(_ settings: AIUsageHostSettings, for hostID: Host.ID) {
        let previous = preferences.settings(for: hostID)
        var settings = settings
        if settings.enabledChoice == nil { settings.enabledChoice = true }
        preferences.update(settings, for: hostID)
        let current = preferences.settings(for: hostID)
        if !current.isEnabled {
            // Off stops every remote command, a fetch already running too.
            forget(hostID)
        } else if current.customPath != previous.customPath {
            resetDetection(hostID)
        }
        connectionsDidChange()
    }

    /// Check Again: drops what detection found and probes the Host again,
    /// now if it is connected, else when it connects.
    func checkAgain(_ hostID: Host.ID) {
        resetDetection(hostID)
        connectionsDidChange()
    }

    /// Manual refresh for one window: fetches its source now, whatever the
    /// schedule says. A fetch already running for that Host is waited for
    /// instead; one for another Host is let finish first.
    func refresh(scopedTo scope: Host.ID?) async {
        while let running = fetchTask {
            let runningHostID = fetchingHostID
            await running.value
            if runningHostID == liveSourceHostID(scopedTo: scope) { return }
        }
        guard let hostID = liveSourceHostID(scopedTo: scope) else { return }
        startFetch(hostID)
        await fetchTask?.value
    }

    /// The sheet opening, or the Console's AI Usage card showing (expanded,
    /// or already expanded at launch, on return to the foreground, or after
    /// a scope change): refreshes its source when the user asked for that,
    /// the source is live, and no report arrived from it recently. A failed attempt does not count: the
    /// usage would still show old numbers.
    func sheetDidOpen(scopedTo scope: Host.ID?) async {
        guard preferences.display.refreshesWhenOpened,
            let hostID = liveSourceHostID(scopedTo: scope)
        else { return }
        if let last = usage[hostID]?.snapshot?.fetchedAt,
            now().timeIntervalSince(last) < AIUsageDisplayOptions.openRefreshThreshold
        {
            return
        }
        await refresh(scopedTo: scope)
    }

    /// Every provider in the Hosts' latest reports, as (id, name), by name.
    var reportedProviders: [(id: String, name: String)] {
        var names: [String: String] = [:]
        for state in usage.values {
            for provider in state.snapshot?.report.providers ?? [] {
                names[provider.providerID] = provider.displayName
            }
        }
        return names.map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: Sources

    private var enabledHostIDs: [Host.ID] {
        hosts.map(\.id).filter { preferences.settings(for: $0).isEnabled }
    }

    private func liveSourceHostID(scopedTo scope: Host.ID?) -> Host.ID? {
        let candidates = enabledHostIDs.filter {
            detections[$0]?.path != nil && connectionStatus($0) == .connected
        }
        return Self.preferred(scope, among: candidates)
    }

    private static func preferred(_ scope: Host.ID?, among candidates: [Host.ID]) -> Host.ID? {
        if let scope, candidates.contains(scope) { return scope }
        return candidates.first
    }

    private func interval(for hostID: Host.ID) -> Duration {
        preferences.settings(for: hostID).refreshInterval.duration
    }

    // MARK: Detection

    /// Drops what detection knew, so the Host is probed again on its
    /// current connection. Its usage stays on screen meanwhile.
    private func resetDetection(_ hostID: Host.ID) {
        guard var machine = detectionMachines.removeValue(forKey: hostID) else { return }
        performDetection(machine.handle(.reset), hostID: hostID)
    }

    /// Everything held for a Host. A fetch still running for it is
    /// cancelled; it counts as no failure and whatever it returns is dropped.
    private func forget(_ hostID: Host.ID) {
        resetDetection(hostID)
        sendPolling(.forget(hostID))
    }

    private func probe(_ hostID: Host.ID, generation: UInt64) {
        if detectionMachines[hostID] == nil {
            detectionMachines[hostID] = CodexBarDetectionMachine(retryDelay: probeRetryDelay)
        }
        sendDetection(.probe(
            generation: generation, requestID: UUID(),
            customPath: preferences.settings(for: hostID).customPath), hostID: hostID)
    }

    private func sendDetection(_ event: CodexBarDetectionMachine.Event, hostID: Host.ID) {
        // Completions for a forgotten Host never recreate its detection.
        guard var machine = detectionMachines[hostID] else { return }
        let effects = machine.handle(event)
        detectionMachines[hostID] = machine
        performDetection(effects, hostID: hostID)
    }

    private func performDetection(_ effects: [CodexBarDetectionMachine.Effect], hostID: Host.ID) {
        for effect in effects {
            switch effect {
            case .locate(let token, let customPath):
                probeTasks[token] = Task { [weak self, transports] in
                    let outcome: CodexBarDetectionMachine.Outcome
                    do {
                        outcome = .located(try await transports.withNotificationTransport(for: hostID) {
                            try await $0.locateCodexBar(customPath: customPath)
                        })
                    } catch {
                        outcome = .failed(Self.message(for: error))
                    }
                    self?.probeTasks[token] = nil
                    self?.sendDetection(.finished(token, outcome), hostID: hostID)
                }
            case .cancelRetry(let token):
                probeRetries.removeValue(forKey: token)?.cancel()
            case .retireRetry(let token):
                probeRetries[token] = nil
            case .armRetry(let token, let delay):
                probeRetries[token] = Task { [weak self] in
                    do { try await Task.sleep(for: delay) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.sendDetection(.retryElapsed(token), hostID: hostID)
                }
            case .didFind(let path):
                if path != nil, preferences.settings(for: hostID).enabledChoice == nil {
                    // Each extra Host asks the same accounts again: only the
                    // first undecided Host found with CodexBar starts on.
                    let anotherIsOn = hosts.contains {
                        $0.id != hostID
                            && preferences.settings(for: $0.id).enabledChoice == true
                            && detections[$0.id] != .notFound
                    }
                    var decided = preferences.settings(for: hostID)
                    decided.enabledChoice = !anotherIsOn
                    if anotherIsOn {
                        updateSettings(decided, for: hostID)
                        return
                    }
                    preferences.update(decided, for: hostID)
                }
                reschedule()
            case .reschedulePolling:
                reschedule()
            case .connectionsChanged:
                connectionsDidChange()
            }
        }
    }

    // MARK: Polling

    /// Restarts the poll loop. Cheap and idempotent: each Host's next fetch
    /// time comes from its own last one, so restarting never fetches early,
    /// and an in-flight fetch reschedules when it finishes.
    private func reschedule() {
        sendPolling(.schedule(nextFetch().map {
            AIUsagePollingMachine.Due(hostID: $0.hostID, delay: $0.delay, isFollowUp: $0.isFollowUp)
        }))
    }

    /// The due-soonest source among those an open window reads from — its
    /// interval, or an earlier server follow-up; nil in the background,
    /// while a fetch runs, or with nothing to poll.
    private func nextFetch() -> (hostID: Host.ID, delay: Duration, isFollowUp: Bool)? {
        guard isForeground, polling.fetchToken == nil else { return nil }
        let date = now()
        return windowScopes.values
            .compactMap { liveSourceHostID(scopedTo: $0) }
            .map { hostID in
                let state = usage[hostID]
                let due = AIUsagePollSchedule.delayUntilDue(
                    lastFinishedAt: state?.lastFinishedAt,
                    interval: interval(for: hostID),
                    consecutiveFailures: state?.consecutiveFailures ?? 0,
                    now: date)
                if let followUp = polling.followUp(for: hostID) {
                    let early = AIUsagePollSchedule.delay(until: followUp, now: date)
                    if early < due { return (hostID: hostID, delay: early, isFollowUp: true) }
                }
                return (hostID: hostID, delay: due, isFollowUp: false)
            }
            .min { $0.delay < $1.delay }
    }

    /// `isScheduledPoll`: the Host's interval came due, which allows it
    /// another server follow-up.
    private func startFetch(_ hostID: Host.ID, isScheduledPoll: Bool = false) {
        guard let path = detections[hostID]?.path else { return }
        sendPolling(.fetch(hostID, path: path, scheduled: isScheduledPoll, requestID: UUID()))
    }

    private func sendPolling(_ event: AIUsagePollingMachine.Event) {
        for effect in polling.handle(event) {
            switch effect {
            case .armPoll(let token, let delay):
                pollTasks[token] = Task { [weak self] in
                    if delay > .zero {
                        do { try await Task.sleep(for: delay) } catch { return }
                    }
                    guard !Task.isCancelled else { return }
                    self?.sendPolling(.pollElapsed(token))
                }
            case .cancelPoll(let token):
                pollTasks.removeValue(forKey: token)?.cancel()
            case .retirePoll(let token):
                pollTasks[token] = nil
            case .checkSchedule:
                // Sources, settings and the clock may have moved during the wait.
                if let next = nextFetch(), next.delay <= .zero {
                    startFetch(next.hostID, isScheduledPoll: !next.isFollowUp)
                } else {
                    reschedule()
                }
            case .fetch(let hostID, let path, let token):
                fetchTasks[token] = Task { [weak self, transports] in
                    let outcome: AIUsagePollingMachine.Outcome
                    do {
                        outcome = .success(try await transports.withNotificationTransport(for: hostID) {
                            try await $0.codexBarUsage(executablePath: path)
                        })
                    } catch where Self.isInterruption(error) {
                        outcome = .interrupted
                    } catch {
                        outcome = .failed(Self.message(for: error), executableMissing: error as? CodexBarError == .executableMissing)
                    }
                    self?.finishFetch(outcome, hostID: hostID, token: token)
                }
            case .cancelFetch(let token):
                fetchTasks.removeValue(forKey: token)?.cancel()
            case .retireFetch(let token):
                fetchTasks[token] = nil
            case .redetect(let hostID):
                resetDetection(hostID)
                connectionsDidChange()
            case .reschedule:
                reschedule()
            }
        }
    }

    private func finishFetch(
        _ outcome: AIUsagePollingMachine.Outcome, hostID: Host.ID, token: AIUsagePollingMachine.FetchToken
    ) {
        sendPolling(.finished(token, outcome, at: now(), hostIsEnabled:
            hosts.contains(where: { $0.id == hostID }) && preferences.settings(for: hostID).isEnabled))
    }

    /// Failures that say the connection went away under a run — the app
    /// suspending, a redial, the Host dropping — not that CodexBar failed.
    /// They do not back the Host off.
    private static func isInterruption(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        switch error as? TransportError {
        case .cancelled, .sshUnreachable: return true
        default: return false
        }
    }

    private static func message(for error: any Error) -> String {
        if let error = error as? CodexBarError { return error.message }
        if let error = error as? TransportError { return error.presentation.explanation }
        return String(describing: error)
    }
}
