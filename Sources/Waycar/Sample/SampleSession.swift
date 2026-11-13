import Foundation

/// A disposable Console for the virtual Host. The app's console and catalog
/// remain real-only, so sample rows never enter per-Host background consumers.
@MainActor
final class SampleSession: Identifiable {
    enum CreationError: Error { case defaultsUnavailable }

    let id = UUID()
    let hostStore: HostStore
    let console: ConsoleStore
    let defaults: UserDefaults
    let agentSummaries: AgentSummarySettings
    let aiUsage: AIUsageStore
    let bannerStore: AgentNotificationBannerStore
    private let suiteName: String
    private var stopped = false

    init() throws {
        let suiteName = "com.otreva.waycar.sample.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CreationError.defaultsUnavailable
        }
        self.suiteName = suiteName
        self.defaults = defaults
        defaults.removePersistentDomain(forName: suiteName)
        hostStore = HostStore(volatileHosts: [SampleHost.host])
        let console = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults),
            closedSessions: ClosedSessionsStore(),
            chatMode: ChatModeStore(defaults: defaults),
            rowLayouts: AgentRowLayoutStore(defaults: defaults),
            backendPreferences: HostBackendPreferences(defaults: defaults),
            detectBackends: ConsoleStore.sshBackendDetector(),
            probeServerRuntime: ConsoleStore.sshServerRuntimeProbe(),
            startRuntime: ConsoleStore.sshRuntimeStarter())
        self.console = console
        defaults.set(true, forKey: AgentSummarySettings.defaultsKey)
        agentSummaries = AgentSummarySettings(defaults: defaults)
        aiUsage = AIUsageStore(
            preferences: AIUsagePreferences(defaults: defaults),
            transports: console,
            connectionStatus: { _ in nil },
            connectionGeneration: { _ in nil })
        // No host list is supplied to AI Usage, notification registrations,
        // or Live Activities. No Launch gate, detector, review counter,
        // network monitor or standby-mosh factory is installed here.
        bannerStore = AgentNotificationBannerStore(
            presentedAgent: { nil }, triggers: { _ in nil }, playSound: {})
        console.setAgentSummariesEnabled(true)
        console.setHosts([SampleHost.host])
    }

    deinit {
        // A cover torn down without `stop()` must not leave its suite behind.
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    func start() async {
        guard !stopped else { return }
        await console.resume()
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        console.setHosts([])
        await console.suspend()
        defaults.removePersistentDomain(forName: suiteName)
    }
}
