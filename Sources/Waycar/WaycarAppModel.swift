import Observation
import SwiftUI

/// The stores every window shares, and the app-wide wiring between them.
///
/// On iPad each window is its own scene with its own `ContentView`, but there
/// is still one Host catalog, one set of Host connections, one Live Activity
/// per Host, and one app activity: building these per window would open every
/// connection once per window and let two coordinators fight over the same
/// Live Activity. So the composition root lives here, once per process, and a
/// window adds only what is genuinely its own — its navigation router and its
/// restored Agent.
///
/// App activity drives the events sessions' suspend/resume (spec #20): the
/// connections survive a backgrounding for the length of the grace period
/// (see AppActivityCoordinator), then quiesce, keeping each Host's SSH
/// connection for the return to probe (#105). Every return to the
/// foreground re-activates them — and, for a connection the app was still
/// holding, re-proves it, because a link can die while the app is away
/// without anything having noticed (#142). The phase that feeds it is the
/// app's aggregate one, so backgrounding one window while another stays on
/// screen suspends nothing. The first window scene to connect starts the
/// Host dials before its window lays out (`connectAtLaunch`).
@MainActor
final class WaycarAppModel {
    let pushRegistration: PushRegistrationStore
    let sceneDirectory: AgentSceneDirectory
    let hostStore: HostStore
    let console: ConsoleStore
    let notificationPreferences: NotificationPreferencesStore
    let terminalThemes: TerminalThemeSettings
    let terminalZoom: TerminalZoomSettings
    let terminalFonts: TerminalFontSettings
    let terminalEdgeDock: EdgeDockSettings
    let terminalBackButton: AgentBackButtonSettings
    let snippets: SnippetStore
    let toolbars: AgentToolbarLayoutStore
    let footer: AgentFooterLayoutStore
    let appearance: AppAppearanceSettings
    /// The Console's outdated-plugin Not now answers and the Hosts with a
    /// plugin update running (#209): one of each for every window, so a
    /// dismissal or an update in one iPad window shows in all of them.
    let pluginNoticeDismissals: WaycarPluginNoticeDismissals
    let hostToolsOffer: HostToolsOffer
    let pluginUpdateActivity: WaycarPluginUpdateActivity
    /// The "Install herdr / tmux" runs, one for every window, so a hidden
    /// install keeps its progress for the Console banner and a reopened New
    /// Agent (WAY-338).
    let backendInstall: BackendInstallCenter
    let relaySettings: NotificationRelaySettings
    let agentSummaries: AgentSummarySettings
    let chatModeSettings: ChatModeSettings
    let bannerStore: AgentNotificationBannerStore
    let liveActivities: HostLiveActivityCoordinator
    let attentionBadge: AttentionBadgeCoordinator
    let activity: AppActivityCoordinator
    let iCloudSync: ICloudSyncCoordinator
    let whatsNew: WhatsNewStore
    let aiUsage: AIUsageStore
    /// Send, Blocked-prompt reads and answers for every surface that acts
    /// on an Agent away from its terminal: CarPlay and the Apple Watch
    /// share this one, so one in-flight send per Agent holds across both.
    let agentActions: AgentActionService
    /// Each Agent's latest terminal frame, shown on entry until it is live.
    let lastFrames = AgentLastFrameStore.caches()
    /// The app's one network path monitor (#105): mosh rebinds, remembered
    /// mosh outcomes and Host revalidation all follow it. nil in the
    /// unit-test host, which reads no path.
    let networkPath: NetworkPathMonitor?
    /// The grid each window layout last had, kept across launches (#105);
    /// nil in the unit-test host.
    let terminalGridSizes: TerminalGridSizeMemory?
    let analytics: any Analytics
    let analyticsConsent: AnalyticsConsentPrompt
    let notificationAsk: NotificationAsk
    /// The Review Prompt's local history: real-use counts and when Apple's
    /// rating prompt was last requested.
    let reviewPrompt: ReviewPromptStore

    private var isStarted = false
    /// Whether `connectAtLaunch` started the Host dials.
    private var connectedAtLaunch = false
    /// Whether the Host dials are already under way, by `start` or
    /// `connectAtLaunch`; a later scene connection need not start them.
    var hasStartedDials: Bool { isStarted || connectedAtLaunch }
    /// `app_opened` goes out once per launch, on the first activation once
    /// the user's analytics choice exists (`reportOpen`).
    private var didReportOpen = false
    /// The foreground sources the Agent Summary gate follows.
    private var isPhoneForeground = false
    private var isCarPlayForeground = false
    private var isWatchForeground = false
    private var observers: [AnyObject] = []

    /// `hostStore`, `console`, and `activity` are injectable so a test can
    /// drive the activity wiring and observe that something consumed it:
    /// `AppModelActivityDriverTests` is what turns deleting the task that
    /// runs `ConsoleActivityDriver` red (#167). Defaults are the production
    /// (and syncs it, except in the process hosting the unit tests) and
    /// `ConsoleStore(inventoryCache:chatTranscriptCache:chatMediaCache:queuedMessages:queuedLaunches:)`
    /// reaches the real `sshSessionFactory()`, the real
    /// `sshBackendDetector()` and `sshRuntimeStarter()`, the on-device
    /// last-known inventory, Chat Mode transcripts, chat media, Queued Messages and Queued Launches; its Closed Sessions
    /// persist beside that inventory and sync like the Host catalog.
    init(
        pushRegistration: PushRegistrationStore,
        sceneDirectory: AgentSceneDirectory,
        hostStore: HostStore = HostStore(sync: ICloudSync.runsInThisProcess ? .iCloud : nil),
        console: ConsoleStore = ConsoleStore(
            closedSessions: ClosedSessionsStore(
                directory: ClosedSessionsStore.applicationSupportDirectory(),
                sync: ICloudSync.runsInThisProcess ? .iCloud : nil),
            inventoryCache: .applicationSupport(),
            chatTranscriptCache: .applicationSupport(),
            chatMediaCache: .caches(),
            queuedMessages: .applicationSupport(),
            queuedLaunches: .applicationSupport(),
            detectBackends: ConsoleStore.sshBackendDetector(),
            probeServerRuntime: ConsoleStore.sshServerRuntimeProbe(),
            startRuntime: ConsoleStore.sshRuntimeStarter()),
        activity: AppActivityCoordinator = AppActivityCoordinator(),
        analytics: any Analytics = NoopAnalytics(),
        backendInstall: BackendInstallCenter = BackendInstallCenter()
    ) {
        self.pushRegistration = pushRegistration
        self.sceneDirectory = sceneDirectory
        self.hostStore = hostStore
        self.console = console
        agentActions = AgentActionService(console: console)
        // A Queued Answer ends while the user is away from the screen that
        // took it: say how it went.
        console.blockedAnswers.onFinished = { [weak console] entry, finish in
            let identity = console?.agents.first { $0.id == entry.agentID }
                .map { AgentGlanceList.title(for: $0) }
            let notice = BlockedAnswerQueue.notice(
                label: entry.pending.label, identity: identity, finish: finish)
            NotificationTextReplies.postLocalNotification(title: notice.title, body: notice.body)
        }
        // Attachment copies (Edit Draft's, pasted files) from an earlier run are orphans.
        ComposerTray.sweepLocalCopies()
        self.activity = activity
        self.analytics = analytics
        analyticsConsent = AnalyticsConsentPrompt(analytics: analytics)
        // The network edges (#105) report through the same gate.
        NetworkTelemetry.analytics = analytics
        let terminalThemes = TerminalThemeSettings()
        self.terminalThemes = terminalThemes
        terminalZoom = TerminalZoomSettings()
        let terminalFonts = TerminalFontSettings()
        self.terminalFonts = terminalFonts
        terminalEdgeDock = EdgeDockSettings()
        let terminalBackButton = AgentBackButtonSettings()
        self.terminalBackButton = terminalBackButton
        let snippets = SnippetStore()
        self.snippets = snippets
        let toolbars = AgentToolbarLayoutStore()
        self.toolbars = toolbars
        let footer = AgentFooterLayoutStore()
        self.footer = footer
        let appearance = AppAppearanceSettings()
        self.appearance = appearance
        let pluginNoticeDismissals = WaycarPluginNoticeDismissals()
        self.pluginNoticeDismissals = pluginNoticeDismissals
        let hostToolsOffer = HostToolsOffer()
        self.hostToolsOffer = hostToolsOffer
        pluginUpdateActivity = WaycarPluginUpdateActivity()
        self.backendInstall = backendInstall
        // A Host an install found reconnects whether or not the sheet that
        // started it is still up.
        backendInstall.onOutcome = { [weak console] hostID, outcome in
            console?.backendInstallEnded(on: hostID, outcome: outcome)
        }
        let relaySettings = NotificationRelaySettings()
        self.relaySettings = relaySettings
        let agentSummaries = AgentSummarySettings()
        self.agentSummaries = agentSummaries
        let chatModeSettings = ChatModeSettings()
        self.chatModeSettings = chatModeSettings
        whatsNew = WhatsNewStore(
            notes: WhatsNewStore.bundledNotes(),
            currentBuild: WhatsNewStore.currentBuild(),
            isExistingInstall: !hostStore.hosts.isEmpty)
        // iCloud Sync (ADR 0019): each synced preference key and the store
        // that must re-read it when another device changed it. A synced
        // catalog this build cannot read is neither adopted nor overwritten,
        // so an older device cannot wipe it where it can be read. Terminal
        // zoom, edge-dock positions and Console list state stay per device.
        iCloudSync = ICloudSyncCoordinator(
            hostStore: hostStore,
            closedSessions: console.closedSessions,
            preferences: [
                SnippetStore.defaultsKey: SyncedPreference(
                    reload: { snippets.reload() },
                    canRead: { ($0 as? Data).map(SnippetStore.canRead) ?? false }),
                AgentRowLayoutStore.defaultsKey: SyncedPreference(
                    reload: { console.rowLayouts.reload() },
                    canRead: { ($0 as? Data).map(AgentRowLayoutStore.canRead) ?? false }),
                // Per device type: iPhone and iPad each sync their own toolbar.
                toolbars.defaultsKey: SyncedPreference(
                    reload: { toolbars.reload() },
                    canRead: { ($0 as? Data).map(AgentToolbarLayoutStore.canRead) ?? false }),
                // Per device type, like the toolbar.
                footer.defaultsKey: SyncedPreference(
                    reload: { footer.reload() },
                    canRead: { ($0 as? Data).map(AgentFooterLayoutStore.canRead) ?? false }),
                PinnedAgentsStore.defaultsKey: SyncedPreference(reload: { console.pins.reload() }),
                // Per Host: the New Agent backend and Show tmux sessions
                // (ADR 0026).
                HostBackendPreferences.defaultsKey: SyncedPreference(
                    reload: { console.backendPreferences.reload() },
                    canRead: { ($0 as? Data).map(HostBackendPreferences.canRead) ?? false }),
                // Runtime visibility has its own key: an older build that
                // rewrites the legacy backend blob must leave it alone.
                HostBackendPreferences.runtimeVisibilityKey: SyncedPreference(
                    reload: { console.backendPreferences.reload() },
                    canRead: { ($0 as? Data).map(HostBackendPreferences.canReadRuntimeVisibility) ?? false }),
                // Kept apart from the Host records, so an older build that
                // republishes a record cannot turn a Disabled Host back on.
                // Only a list of Host ids is this build's format; anything
                // else is a newer build's and is left for it.
                HostStore.disabledHostsKey: SyncedPreference(
                    reload: { hostStore.reloadDisabledHosts() },
                    canRead: {
                        ($0 as? [String])?.allSatisfy { UUID(uuidString: $0) != nil } ?? false
                    }),
                AppAppearanceSettings.defaultsKey: SyncedPreference(reload: { appearance.reload() }),
                TerminalFontSettings.defaultsKey: SyncedPreference(reload: { terminalFonts.reload() }),
                TerminalThemeSettings.lightDefaultsKey: SyncedPreference(
                    reload: { terminalThemes.reload() }),
                TerminalThemeSettings.darkDefaultsKey: SyncedPreference(
                    reload: { terminalThemes.reload() }),
                NotificationRelaySettings.defaultsKey: SyncedPreference(
                    reload: { relaySettings.reload() }),
                // Synced so two devices sharing a Host cannot keep flipping
                // its `summary_enabled` back and forth on every connection.
                AgentSummarySettings.defaultsKey: SyncedPreference(
                    reload: { agentSummaries.reload() }),
                AgentBackButtonSettings.defaultsKey: SyncedPreference(
                    reload: { terminalBackButton.reload() }),
                // Per Host: Not now and the reminder switch on the Host Tools
                // offers, so an answer reaches the other devices and survives
                // a reinstall.
                HostToolsOffer.defaultsKey: SyncedPreference(
                    reload: { hostToolsOffer.reload() },
                    canRead: { ($0 as? Data).map(HostToolsOffer.canRead) ?? false }),
                WaycarPluginNoticeDismissals.defaultsKey: SyncedPreference(
                    reload: { pluginNoticeDismissals.reload() },
                    canRead: { $0 is [String: String] }),
            ].merging(
                ChatModeSettings.syncedKeys.map { key in
                    (key, SyncedPreference(reload: { chatModeSettings.reload() }))
                },
                uniquingKeysWith: { _, chatMode in chatMode }),
            retryConnections: { await console.retryFailedHosts() })
        // Never in the unit-test host, previews or demo screenshots; the
        // demo composition installs none at all.
        let reviewPrompt = ReviewPromptStore(isDisabled: ReviewPromptStore.isSuppressedInThisProcess)
        self.reviewPrompt = reviewPrompt
        console.installReviewPrompt(reviewPrompt)
        console.onSteer = { [analytics] in analytics.noteSteer() }
        // The network path, grid sizes and mosh's fast path (#105). The
        // unit-test host keeps none of them.
        // Every Host also re-proves its connection when the path changes,
        // and redials at once when a path comes back.
        if ICloudSync.runsInThisProcess {
            let networkPath = NetworkPathMonitor(debounce: .milliseconds(300))
            let gridSizes = TerminalGridSizeMemory()
            self.networkPath = networkPath
            terminalGridSizes = gridSizes
            console.agentTerminals.gridSizes = gridSizes
            console.installMoshFastPath(.live(networkPath: networkPath))
            console.followNetworkPath(networkPath)
        } else {
            networkPath = nil
            terminalGridSizes = nil
        }
        // A notification, Live Activity or link naming an Agent starts its
        // standby mosh while the detail opens.
        sceneDirectory.agentNamed = { [weak console] id in console?.noteAgentIntent(id) }
        // Preference reads/writes borrow the Console's live per-Host SSH
        // connections (#75); the token comes from push bootstrap (#71), and
        // the custom relay URL (#76) and the AI summaries choice ride along
        // into each Host's notify.json.
        let notificationWriter = NotificationRegistrationWriter(
            transports: console,
            computer: { [weak hostStore] hostID in
                guard let hostStore else { return [hostID] }
                return await MainActor.run {
                    HostLiveActivityCoordinator.computerHostIDs(
                        of: hostID, among: hostStore.hosts, digests: \.trustedHostKeyDigests)
                }
            })
        let notificationPreferences = NotificationPreferencesStore(
            transports: notificationWriter,
            deviceToken: { [weak pushRegistration] in pushRegistration?.deviceToken },
            relayBaseURL: { [weak relaySettings] in relaySettings?.relayURL },
            summariesEnabled: { [weak agentSummaries] in agentSummaries?.isEnabled ?? false },
            backendPresence: { [weak console] in console?.backendPresence(on: $0) })
        self.notificationPreferences = notificationPreferences
        // The in-app foreground banner (#77): presented-Agent suppression
        // reads the key window's Agent at fire time; the preference gate
        // reads each Host's confirmed notify flags and fails closed on
        // unknowns.
        bannerStore = AgentNotificationBannerStore(
            presentedAgent: { [weak sceneDirectory] in sceneDirectory?.keyScenePresentedAgent },
            triggers: { [weak notificationPreferences] in
                notificationPreferences?.confirmedTriggers(for: $0)
            })
        // One Live Activity per Host: the Console Agent list is the source
        // of truth while foregrounded; the plugin takes over over APNs
        // after the app suspends. Fail closed on a missing opt-in, key, or
        // device token — the same gates the registration write uses.
        let liveActivityPreferences = LiveActivityPreferences()
        let liveActivities = HostLiveActivityCoordinator(
            controller: ActivityKitLiveActivityController(),
            preferences: liveActivityPreferences,
            transports: notificationWriter,
            deviceToken: { [weak pushRegistration] in pushRegistration?.deviceToken },
            // A Disabled Host counts as gone here, so while the app runs its
            // Live Activities end. Nothing persisted is deleted, and the Host
            // keeps this device's registrations: its Agent Notifications and
            // push-started Live Activities can still arrive. So does a second
            // entry for a computer another entry already shows.
            knownHostIDs: { [weak hostStore] in
                HostLiveActivityCoordinator.activityHostIDs(
                    enabledHosts: hostStore?.enabledHosts ?? [],
                    isPreferred: liveActivityPreferences.isEnabled(for:),
                    digests: \.trustedHostKeyDigests)
            },
            hostDisplayName: { [weak hostStore] id in
                hostStore?.hosts.first(where: { $0.id == id })?.displayName ?? ""
            },
            isAwaitingSnapshot: { [weak console] id in
                console?.hostsAwaitingSnapshot.contains(id) ?? true
            },
            connectionStatus: { [weak console] id in
                console?.hostStatuses[id]
            },
            pinnedPaneIDs: { [weak console] id in
                console?.pins.pinnedPaneIDs(for: id) ?? []
            },
            rowLayout: { [weak console] id in console?.rowLayout(for: id) })
        self.liveActivities = liveActivities
        // The one-time ask to turn both on (#71); never in the unit-test
        // host or previews.
        notificationAsk = NotificationAsk(
            pushRegistration: pushRegistration, preferences: notificationPreferences,
            liveActivities: liveActivities,
            isDisabled: NotificationAsk.isSuppressedInThisProcess)
        // AI Usage borrows the Console's live Host connections too, and
        // probes each Host for CodexBar as its connection comes up.
        aiUsage = AIUsageStore(
            preferences: AIUsagePreferences(),
            transports: console,
            connectionStatus: { [weak console] id in console?.hostStatuses[id] },
            connectionGeneration: { [weak console] id in
                console?.hostConnectionGenerations[id]
            })
        attentionBadge = AttentionBadgeCoordinator()
    }

    var terminal: TerminalSettings {
        TerminalSettings(
            themes: terminalThemes, zoom: terminalZoom, fonts: terminalFonts,
            snippets: snippets, toolbars: toolbars, edgeDock: terminalEdgeDock,
            backButton: terminalBackButton, footer: footer)
    }

    /// Starts every Host's dial as the first window or CarPlay scene
    /// connects (#105), ahead of that window's layout: `start()` comes only
    /// once the window appears, about 300 ms later (Simulator, Debug), or
    /// once the CarPlay scene's interface controller connects. A
    /// scene-based app launches in the background state, so this hangs off
    /// scene connection, not `applicationState`. A background launch (a
    /// push, a background task) connects no scene and never dials: no
    /// screen shows what it would fetch, and its time is not the user's.
    /// While the Keychain is not yet readable (before the first unlock
    /// after a restart) the Host credentials cannot be read, so the dial is
    /// left to `start()`. `start()` finds the dials under way and starts
    /// nothing twice.
    func connectAtLaunch() {
        guard !isStarted, !connectedAtLaunch else { return }
        connectedAtLaunch = true
        console.setAgentSummariesEnabled(agentSummaries.isEnabled)
        console.setHosts(hostStore.hosts)
        Task { await console.resume() }
    }

    /// Starts the app-wide work exactly once, however many windows or
    /// CarPlay scenes ask. Every window calls this as it appears, and the
    /// CarPlay scene as it connects, so a CarPlay-only launch (phone locked
    /// in a pocket) still runs the Console; only the first call does
    /// anything.
    func start() {
        guard !isStarted else { return }
        isStarted = true

        // The banner store diffs the Agent list for foreground Blocked/Done
        // transitions (#77); both it and the Live Activities take the
        // current list as their baseline before the Hosts connect. Shell
        // rows have no Agent Status, so neither ever sees them. Neither sees
        // a Host's last-known rows either: until its live snapshot verifies
        // them they are not news, and the snapshot that does is a baseline.
        bannerStore.agentsDidChange(console.verifiedAgents.excludingShells)
        liveActivities.agentsDidChange(console.verifiedAgents.excludingShells)
        // The Attention Badge starts from what is stored: at launch no Host
        // is connected yet, so this prunes deleted Hosts and corrects a
        // badge an earlier run left stale.
        attentionBadge.inventoryDidChange(Self.attentionInventory(console, hostStore))

        console.setAgentSummariesEnabled(agentSummaries.isEnabled)
        Task {
            console.setHosts(hostStore.hosts)
            notificationPreferences.setHosts(hostStore.enabledHosts)
            aiUsage.setHosts(hostStore.enabledHosts)
            await console.resume()
        }
        // Only a real suspension moves the connections: a backgrounding the
        // grace period absorbed emits no `.suspended`, so a quick trip out of
        // the app leaves the events sessions and Attach terminals untouched.
        // Driven off the coordinator's event stream rather than an observation
        // of its phase — the suspension happens while the app is in the
        // background and rendering nothing, and a consumer that only compares
        // the value it last saw misses both that edge and the resume behind
        // it (#142). The stream has one consumer for the life of the process.
        Task {
            await ConsoleActivityDriver(activity: activity, console: console).run()
        }
        Task { await pushRegistration.refresh() }
        // Existing installs' Notification Keys predate the app-group
        // mirror; refresh it before a locked widget render needs it.
        NotificationKeyStore().refreshMirror()
        liveActivities.start()
        // Not in the unit-test host (`ICloudSync.runsInThisProcess`), which
        // reaches neither the App Store nor the real Keychain's ledger.
        if ICloudSync.runsInThisProcess {
            Task { await AppEnvironment.resolve() }
            SKANConversionReporting.reportInstall()
            LaunchLedgerSweep.runOnce()
        }
        // Publishes this device's data on the first launch with iCloud Sync
        // and pulls what other devices wrote; later passes follow the scene.
        iCloudSync.start()

        observeStores()
    }

    /// The app's aggregate window scene phase: active while any window is.
    /// Analytics, iCloud Sync, the receipt check and AI Usage follow the
    /// phone alone.
    func scenePhaseDidChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            reportOpen()
            isPhoneForeground = true
            evaluateUsage()
            activity.didBecomeActive(.phone)
            // Re-probes notification permission on every return, grace
            // period or not: the user may have flipped it in the Settings
            // app while we were backgrounded.
            Task { await pushRegistration.refresh() }
            iCloudSync.sceneDidBecomeActive()
            aiUsage.setForeground(true)
            // A receipt check that found nothing verified at launch (offline,
            // say) tries again.
            if ICloudSync.runsInThisProcess { Task { await AppEnvironment.resolve() } }
            updateAgentSummaryForeground()
            console.setShellActivityForeground(true)
        case .background:
            isPhoneForeground = false
            activity.didEnterBackground(.phone)
            iCloudSync.sceneDidEnterBackground()
            aiUsage.setForeground(false)
            updateAgentSummaryForeground()
            console.setShellActivityForeground(false)
        default:
            break
        }
    }

    /// The CarPlay scene came to the car's screen. It holds the Host
    /// connections like a window does: a running grace period is cancelled,
    /// and none starts while it stays (docs/design/carplay.md §6).
    func carPlayDidBecomeActive() {
        isCarPlayForeground = true
        activity.didBecomeActive(.carPlay)
        updateAgentSummaryForeground()
    }

    /// The CarPlay scene left the car's screen or disconnected.
    func carPlayDidEnterBackground() {
        guard isCarPlayForeground else { return }
        isCarPlayForeground = false
        activity.didEnterBackground(.carPlay)
        updateAgentSummaryForeground()
    }

    /// The Apple Watch app became reachable, or a watch request arrived
    /// (`WatchBridge`). Like CarPlay it holds the Host connections and the
    /// Agent Summary refresh while it lasts.
    func watchDidBecomeActive() {
        guard !isWatchForeground else { return }
        isWatchForeground = true
        activity.didBecomeActive(.watch)
        updateAgentSummaryForeground()
    }

    /// The watch app is no longer reachable and no watch request is in
    /// flight.
    func watchDidEnterBackground() {
        guard isWatchForeground else { return }
        isWatchForeground = false
        activity.didEnterBackground(.watch)
        updateAgentSummaryForeground()
    }

    /// Agent Summaries refresh while anyone can hear or see them: a window,
    /// the car, or the watch.
    private func updateAgentSummaryForeground() {
        console.setAgentSummaryForeground(
            isPhoneForeground || isCarPlayForeground || isWatchForeground)
    }

    /// The first-launch analytics answer. Allow enables analytics and sends
    /// the `app_opened` this launch held back; Don't Allow cleans up as the
    /// Settings toggle does.
    func answerAnalyticsConsent(allow: Bool) {
        analytics.setEnabled(allow)
        reportOpen()
        evaluateUsage()
    }

    /// Waits while the user has not chosen, so the first event of a fresh
    /// install is never dropped for want of an answer.
    private func reportOpen() {
        guard !didReportOpen, !analytics.needsChoice else { return }
        didReportOpen = true
        analytics.capture(.appOpened)
    }

    /// Reads what the Console shows and reports the milestones and the day's
    /// `console_active` it earns. Analytics drops the ones already sent or
    /// not allowed, so this runs on every change and return to the
    /// foreground. A milestone the Console already satisfies when analytics
    /// are allowed goes out at the next of those.
    private func evaluateUsage() {
        let signals = Self.usageSignals(console, hostStore, pushRegistration)
        guard signals.connectedHosts > 0 else { return }
        analytics.milestone(.hostConnected)
        if signals.agents > 0 { analytics.milestone(.agentSeen) }
        // Shown, not just listed: only while a window is on screen.
        guard isPhoneForeground else { return }
        if signals.hasAttention { analytics.milestone(.attentionSeen) }
        analytics.consoleActive(
            ConsoleSnapshot(
                hosts: signals.enabledHosts, backend: signals.backend, agents: signals.agents,
                push: signals.push))
    }

    /// Store-to-store wiring that used to hang off the single window's view.
    /// Observed here instead, so it runs once rather than once per window,
    /// and keeps running while no window is rendering.
    private func observeStores() {
        let hostStore = self.hostStore
        let console = self.console
        let activity = self.activity
        let pushRegistration = self.pushRegistration

        observe({ hostStore.hosts }) { [weak self] hosts in
            guard let self else { return }
            console.setHosts(hosts)
            // Only the Console keeps a Disabled Host (for its saved state);
            // these hold in-memory caches for Hosts the app contacts.
            let enabled = hosts.filter(\.isEnabled)
            notificationPreferences.setHosts(enabled)
            aiUsage.setHosts(enabled)
            liveActivities.hostsDidChange()
            Task { await self.notificationAsk.processPending() }
        }
        // The usage events follow the Console: a Host that connected, an
        // Agent listed, one Blocked or Done, and the push token.
        observe({ Self.usageSignals(console, hostStore, pushRegistration) }) { [weak self] _ in
            self?.evaluateUsage()
        }
        // A removed or re-targeted Host, including one removed while the app
        // was not running, and a pane its verified snapshot no longer lists
        // leave no cached frame behind.
        let lastFrames = self.lastFrames
        lastFrames.retainHosts(hostStore.hosts)
        observe({ hostStore.hosts }) { hosts in lastFrames.retainHosts(hosts) }
        observe({ Self.lastFrameInventory(console) }) { inventory in
            lastFrames.retainAgents(inventory.listed, verifiedScopes: inventory.verifiedScopes)
        }
        // Shells have no Agent Status, and their titles change constantly:
        // observing the shell-free list keeps that churn from restarting the
        // Live Activity settle timer.
        observe({ console.verifiedAgents.excludingShells }) { [weak self] statusAgents in
            self?.bannerStore.agentsDidChange(statusAgents)
            self?.liveActivities.agentsDidChange(statusAgents)
        }
        // The Attention Badge counts per Host, from each Agent's live status.
        observe({ Self.attentionInventory(console, hostStore) }) { [weak self] inventory in
            self?.attentionBadge.inventoryDidChange(inventory)
        }
        observe({ console.rowLayouts.hostLayouts }) { [weak self] _ in
            self?.liveActivities.layoutsDidChange()
        }
        observe({ console.sidebarSnapshots.states }) { [weak self] _ in
            self?.liveActivities.layoutsDidChange()
        }
        observe({ console.pins.revision }) { [weak self] _ in
            self?.liveActivities.pinsDidChange()
        }
        // The banner's preference gate fails closed on unknown flags (#77),
        // so re-read each Host's registration file as its connection comes up
        // (and once the push token lands) instead of waiting for a Settings
        // visit that may never happen. A Host that was unreachable when the
        // AI summaries choice changed gets it the same way.
        observe({ console.hostStatuses }) { [weak self] _ in
            guard let self else { return }
            Task { await self.notificationPreferences.refresh() }
            Task { await self.notificationPreferences.applySummaryChoice() }
            liveActivities.connectionsDidChange()
            aiUsage.connectionsDidChange()
        }
        observe({ console.hostConnectionGenerations }) { [weak self] _ in
            self?.aiUsage.connectionsDidChange()
        }
        // Off turns the Console's summary lines and refreshes off at once
        // and the Hosts' `summary_enabled` off as each confirms it; iCloud
        // Sync's reload lands here the same way.
        let agentSummaries = self.agentSummaries
        observe({ agentSummaries.isEnabled }) { [weak self] isEnabled in
            guard let self else { return }
            console.setAgentSummariesEnabled(isEnabled)
            Task { await self.notificationPreferences.applySummaryChoice() }
        }
        observe({ console.hostsAwaitingSnapshot }) { [weak self] _ in
            self?.liveActivities.connectionsDidChange()
        }
        observe({ activity.activationCount }) { [weak self] _ in
            self?.liveActivities.reconcile()
        }
        observe({ pushRegistration.deviceToken }) { [weak self] _ in
            guard let self else { return }
            Task { await self.notificationPreferences.refresh() }
        }
        // A Notification Ask Turn On finishes Host by Host as permission,
        // the token, and each Host's registration state arrive; an ask up
        // when the push state leaves it nothing to offer closes.
        let registrations = self.notificationPreferences
        observe({ pushRegistration.state }) { [weak self] _ in
            guard let self else { return }
            self.notificationAsk.pushStateDidChange()
            Task { await self.notificationAsk.processPending() }
        }
        observe({ registrations.states }) { [weak self] _ in
            guard let self else { return }
            Task { await self.notificationAsk.processPending() }
        }
    }

    private struct UsageSignals: Equatable {
        /// Hosts the user has switched on.
        var enabledHosts: Int
        /// Hosts connected and past their first snapshot.
        var connectedHosts: Int
        var backend: ConsoleSnapshot.Backend
        /// Listed Agents, shells excluded, on Hosts whose snapshot is verified.
        var agents: Int
        /// Any of those Agents is Blocked or Done.
        var hasAttention: Bool
        var push: Bool
    }

    private static func usageSignals(
        _ console: ConsoleStore, _ hostStore: HostStore, _ pushRegistration: PushRegistrationStore
    ) -> UsageSignals {
        let connected = console.connectedHostIDs
        // A Host's detected backends, or the one its projection leads with
        // before detection has run; herdr before tmux support existed. The
        // herdr runtime counts as the one the Host's pick resolved to.
        var hasHerdr = false
        var hasCore = false
        var hasTmux = false
        for id in connected {
            if let presence = console.backendPresence(on: id) {
                let backends = console.presentBackends(on: id)
                hasCore = hasCore || backends.contains(.core)
                hasHerdr = hasHerdr || (presence.herdr && backends.contains(.herdr))
                hasTmux = hasTmux || presence.tmuxVersion != nil
            } else if console.hostLeadBackends[id] == .tmux {
                hasTmux = true
            } else if console.hostLeadBackends[id] == .core {
                hasCore = true
            } else {
                hasHerdr = true
            }
        }
        let backend = ConsoleSnapshot.Backend(herdr: hasHerdr, core: hasCore, tmux: hasTmux)
        let agents = console.verifiedAgents.excludingShells
        return UsageSignals(
            enabledHosts: hostStore.enabledHosts.count, connectedHosts: connected.count,
            backend: backend, agents: agents.count,
            hasAttention: agents.contains { $0.agent.status == .blocked || $0.agent.status == .done },
            push: pushRegistration.deviceToken != nil)
    }

    private static func attentionInventory(
        _ console: ConsoleStore, _ hostStore: HostStore
    ) -> AttentionBadgeCoordinator.Inventory {
        AttentionBadgeCoordinator.Inventory(
            agents: console.agents, hosts: hostStore.enabledHosts,
            hostStatuses: console.hostStatuses,
            hostsAwaitingSnapshot: console.hostsAwaitingSnapshot)
    }

    private struct LastFrameInventory: Equatable {
        let listed: Set<ConsoleAgent.ID>
        let verifiedScopes: Set<ConsoleScope>
    }

    private static func lastFrameInventory(_ console: ConsoleStore) -> LastFrameInventory {
        LastFrameInventory(
            listed: Set(console.agents.map(\.id)),
            verifiedScopes: Set(console.scopeStatuses.compactMap { scope, status in
                status == .connected && !console.scopesAwaitingSnapshot.contains(scope)
                    ? scope : nil
            }))
    }

    private func observe<Value: Equatable>(
        _ read: @escaping @MainActor () -> Value,
        onChange: @escaping @MainActor (Value) -> Void
    ) {
        observers.append(StoreChangeObserver(read: read, onChange: onChange))
    }
}

/// Calls `onChange` after each change to an observed value, like a view's
/// `onChange(of:)` but without a view: re-arms `withObservationTracking`
/// after every change and delivers the value on the next main-actor turn,
/// once the mutation that triggered it has finished. Changes that land
/// before that turn coalesce into one call with the latest value.
@MainActor
final class StoreChangeObserver<Value: Equatable> {
    private let read: @MainActor () -> Value
    private let onChange: @MainActor (Value) -> Void
    private var lastValue: Value

    init(read: @escaping @MainActor () -> Value, onChange: @escaping @MainActor (Value) -> Void) {
        self.read = read
        self.onChange = onChange
        lastValue = read()
        track()
    }

    private func track() {
        let value = withObservationTracking {
            read()
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
        guard value != lastValue else { return }
        lastValue = value
        onChange(value)
    }
}
