import SwiftUI

/// The Console home screen (#8): Agents across every Host as cards, sorted
/// Blocked, Done, Working, then Idle. A Host menu and a Workspace menu scope
/// the list; Status pills filter it, and search folds into the icon that
/// leads them. Host management (#14) lives behind the toolbar button. A plain
/// shell tab is a card like any Agent's. Closed Sessions list under the Closed
/// pill, or a search, and resume on a tap.
struct ConsoleView: View {
    let hosts: HostStore
    let console: ConsoleStore
    let terminal: TerminalSettings
    let appearance: AppAppearanceSettings
    /// Hosts whose outdated-plugin row the user answered with Not now; the
    /// app passes its one instance so every window hides the row together.
    var pluginNoticeDismissals = WaycarPluginNoticeDismissals()
    let pushRegistration: PushRegistrationStore
    let notificationPreferences: NotificationPreferencesStore
    let relaySettings: NotificationRelaySettings
    let agentSummaries: AgentSummarySettings
    /// The app-wide Chat Prompt override, edited in Settings › Chat Mode.
    /// Compositions that don't pass one read and write the same defaults key.
    var chatModeSettings = ChatModeSettings()
    /// Owns the navigation path (#74): user taps and notification deep links
    /// drive the same stack.
    @Bindable var notificationRouter: AgentNotificationRouter
    /// Announces foreground Blocked/Done transitions in-app (#77).
    let bannerStore: AgentNotificationBannerStore
    /// Per-Host Live Activity start/update/end and the Settings toggle.
    let liveActivities: HostLiveActivityCoordinator
    /// Scene phase widened by the background grace period; an Attach screen
    /// pauses its work on real suspensions only.
    let activity: AppActivityCoordinator
    /// AI Usage (CodexBar): the row atop the Agent list, its sheet, and the
    /// Hosts list's CodexBar badge and per-Host settings.
    let aiUsage: AIUsageStore
    /// Settings › iCloud Sync. Nil in compositions without sync (demo).
    var iCloudSync: ICloudSyncCoordinator?
    /// Bumped by the window per New Chat quick action; each bump opens one.
    var newChatRequest = 0
    /// Redirects actions that need a real computer while browsing the sample.
    var sampleConnect: (() -> Void)?
    @State private var sampleSession: SampleSession?
    @State private var retiringSampleSession: SampleSession?
    @State private var pendingSampleAddition: HostAddition?
    @State private var sampleCreationError: String?
    @State private var hostSheet: HostSheet?
    /// Whether this window's Host detail is running a plugin update it presented.
    @State private var isHostSheetUpdatingPlugin = false
    /// Scan to Pair or the manual form, opened from the setup steps.
    @State private var hostAddition: HostAddition?
    /// The New Agent sheet; a New Chat quick action presents it in quick chat.
    @State private var startAgentSheet: StartAgentSheet?
    @State private var isShowingSettings = false
    /// Help from the menu bar's Help › Waycar Help (#161).
    @State private var isShowingHelp = false
    /// The first-Host guide's Learn More page (#161).
    @State private var helpPresentation: HelpPresentation?
    /// "Update Waycar on this Host" (#209), opened in place by the plugin
    /// row, an Agent card's progress hint or Chat Mode's notice.
    @State private var pluginUpdateSheet: PluginUpdateSheet?
    /// The install panel a Host's "No tmux or herdr" banner opens (WAY-338).
    @State private var backendInstallSheet: BackendInstallSheetItem?
    @Environment(\.backendInstallCenter) private var backendInstallCenter
    /// The Hosts with a plugin update running, in any window (#209).
    @Environment(\.waycarPluginUpdateActivity) private var pluginUpdateActivity
    /// Per-Host answers to the Install Waycar Host Tools offer (WAY-341).
    @Environment(\.hostToolsOffer) private var hostToolsOffer
    @Environment(\.analytics) private var analytics
    /// Accessibility sizes stack a Host row's buttons under its text.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL
    @State private var isShowingAIUsage = false
    /// The Keychain Fix the user confirmed in AI Usage; its New Agent sheet
    /// opens once that sheet has gone.
    @State private var pendingKeychainFix: CodexBarKeychainFix.Request?
    /// A prefilled New Agent sheet (Help's Ask an Agent) waiting for the
    /// Console's sheets to finish dismissing.
    @State private var pendingPreset: AgentLaunchPreset?
    /// A New Chat quick action that landed while another Console sheet was
    /// up; it opens from that sheet's onDismiss.
    @State private var isNewChatPending = false
    /// Whether this window's AI Usage row is expanded; per window, so
    /// expanding it in one iPad window leaves the others where they are.
    @SceneStorage("ai-usage.summary-expanded") private var isAIUsageExpanded = false
    /// This window's identity to AI Usage, which reads each window's usage
    /// from the Host that window is scoped to.
    @State private var aiUsageWindow = UUID()
    /// Hosts whose Host-detail Reconnect request is in flight, including the
    /// 1.2 s visual-feedback hold after `retryHost` returns. Distinct from
    /// `EventsSessionStatus.reconnecting`.
    @State private var manualReconnectInFlightHostIDs: Set<Host.ID> = []
    /// Scopes the Agent list to one Host; nil shows every Host. The Host menu
    /// offers it whatever the Host count; a choice whose Host leaves the
    /// catalog falls back to nil.
    @State private var hostFilter: Host.ID?
    /// The Workspace in view; All is the default, and a Workspace that
    /// disappears falls back to it.
    @State private var selectedWorkspaceID: ConsoleWorkspaceOption.ID = .all
    /// The Status pill in view; All is the default.
    @State private var statusFilter: ConsoleStatusFilter = .all
    /// The open Agent as it was when this window opened it. It keeps that
    /// place and Status-pill membership in this window's list until another
    /// Agent (or none) is opened, so the Agent's own change — opening a Done
    /// Agent turns it Idle — does not make the list jump.
    @State private var heldAgent: ConsoleAgent?
    /// Client-side Agents search text (#292). It stands in for the Status
    /// pills while open; the Host and Workspace still apply.
    @State private var searchText = ""
    @State private var isSearchPresented = false
    @FocusState private var isSearchFocused: Bool
    /// Command-F revealed the hidden iPad list; search opens once the list
    /// is shown. Opening it in the same pass would lose the focus to the
    /// covered Agent resigning the keyboard as the list comes out.
    @State private var opensSearchOnReveal = false
    /// The Closed Session whose resume is in flight; one at a time.
    @State private var resumingClosedSession: ClosedSession.ID?
    /// A failed resume's text; non-nil shows the error alert.
    @State private var closedSessionResumeError: String?
    @State private var resumedZellijSession: ClosedZellijSession?
    @State private var zellijSessionToDelete: ClosedZellijSession?
    /// The header row's width: how far the open search capsule pushes the
    /// Status pills.
    @State private var headerRowWidth: CGFloat = 0
    /// The pinned bottom bar's measured height in the slide-over, which the
    /// list reserves as its bottom scroll margin; it grows with Dynamic Type.
    @State private var pinnedBarHeight: CGFloat = ConsoleBottomBar.pinnedContentInset
    @State private var commandRegistry = ConsoleCommandRegistry()
    /// Row-level `pane.move` failure text; non-nil shows the error alert.
    @State private var moveAgentError: String?
    /// The herdr row whose tab the card menu's Rename Tab is renaming.
    @State private var renamingTabOf: ConsoleAgent?
    /// Start Session's per-Host in-flight guard and failure text.
    @State private var sessionStarter = TmuxSessionStarter()
    /// The one row whose swipe-to-close is open; scrolling shuts it.
    @State private var openSwipeRow: ConsoleAgent.ID?
    /// Selection Mode's checked Agents; nil while not selecting. A card's
    /// Select menu item enters it; Done, a Close, a Move or any navigation
    /// leaves it.
    @State private var multiSelection: ConsoleMultiSelection?
    /// Rows whose Close started from Selection Mode's bar: their rows keep
    /// quiet, the bar having announced them together.
    @State private var bulkClosingRows: Set<ConsoleAgent.ID> = []
    /// The departing rows (`ConsoleStore.departingRows`) already lifting out:
    /// set in an animated transaction as they arrive, so each card rises and
    /// fades while its row still stands.
    @State private var liftedRows: Set<ConsoleAgent.ID> = []
    /// Departing rows whose cards have lifted away: already deleted from the
    /// List (`indexAgents` leaves them out) while the store still lists
    /// them.
    @State private var droppedRows: Set<ConsoleAgent.ID> = []
    /// Outlives the detail column's rebuilds, which is the whole point: it
    /// carries the raised keyboard from one Attach screen to the next.
    @State private var keyboardHandoff = TerminalKeyboardHandoff()
    /// Outlives those rebuilds for the same reason. A per-screen inset starts
    /// every switch at zero and only learns the keyboard's height once UIKit
    /// posts the next frame notification, so the terminal that inherits a
    /// raised keyboard would lay out full height first and shrink a moment
    /// later — an extra reflow, and a Connecting loader that visibly jumps
    /// from the middle of the screen to the middle of the terminal.
    @State private var keyboardInset = TerminalKeyboardInset()
    @State private var splitVisibility = ConsoleSplitVisibilityState()
    /// The open Agent whose detail shows the Chat view rather than its
    /// terminal, as the detail reports it (Show Terminal is the detail's
    /// own choice).
    @State private var chatPresentedAgent: ConsoleAgent.ID?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sceneWindow) private var sceneWindow
    @State private var detailCrossfade = DetailCrossfade()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    /// The window-aware entry into navigation; nil outside a scene root.
    @Environment(\.agentSceneRouting) private var sceneRouting

    var body: some View {
        // iPad at regular width slides the Agent over the list
        // (`ConsoleSlideOverLayout`); iPhone keeps a split view, which shows
        // the list beside the Attach terminal at regular width and collapses
        // into the familiar push navigation at compact width. The router's
        // path stays the single source of truth — the list selection is a
        // projection of it, so notification deep links keep working. A
        // size-class change (Stage Manager, Split View) swaps one layout for
        // the other and rebuilds the detail; what must survive that lives in
        // this view's state and the router.
        GeometryReader { geometry in
            let presentation = ConsoleSplitPresentation(
                horizontalSizeClass: horizontalSizeClass,
                size: geometry.size,
                safeAreaInsets: geometry.safeAreaInsets,
                idiom: UIDevice.current.userInterfaceIdiom)
            Group {
                if presentation.usesSlideOver {
                    slideOver(presentation)
                } else {
                    splitView(presentation)
                }
            }
            // Side by side, the keyboard belongs to the Agent, which keeps
            // its own inset (`TerminalKeyboardInset`). Left to SwiftUI, the
            // whole layout would shrink in two stages as it rose and fell,
            // the list's column and bottom bar jumping with it. Compact
            // width keeps the avoidance: there the keyboard can be the
            // list's own, for its search.
            .ignoresSafeArea(
                presentation.usesRegularColumns ? .keyboard : [], edges: .bottom)
            // The detail swapping its content dissolves from the leaving
            // screen to the arriving one; see `DetailCrossfade`.
            .environment(\.detailCrossfade, detailCrossfade)
            .onChange(of: presentation, initial: true) { _, presentation in
                splitVisibility.update(from: presentation)
            }
        }
        // The detail's actions can present these even while the sidebar is hidden.
        .sheet(item: $hostSheet, onDismiss: startPendingPreset) { destination in
            // HostListView brings its own NavigationStack.
            HostListView(
                store: hosts,
                initialHostID: destination.hostID,
                connectionStatuses: console.hostStatuses,
                standingFailures: console.hostStandingFailures,
                latencies: console.hostLatencies,
                moshStates: moshStates,
                reprobeMosh: { id in Task { await console.forceMoshReprobe(for: id) } },
                manualReconnectInFlightHostIDs: manualReconnectInFlightHostIDs,
                retryConnection: { await reconnectHost($0) },
                aiUsage: aiUsage,
                console: console)
            .environment(\.pluginUpdateRunningChange) { isHostSheetUpdatingPlugin = $0 }
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(
                    horizontalSizeClass: horizontalSizeClass)))
        }
        // The setup steps add the first Host from here, then open its page
        // in Hosts, where every later Host is added.
        .modifier(HostAdditionSheet(
            store: hosts, addition: $hostAddition,
            onAdded: { id in presentHosts(id) },
            onDismissed: startPendingPreset))
        .fullScreenCover(item: $sampleSession, onDismiss: sampleDidDismiss) { session in
            SampleConsoleView(
                session: session,
                appearance: appearance,
                pushRegistration: pushRegistration,
                notificationPreferences: notificationPreferences,
                relaySettings: relaySettings,
                liveActivities: liveActivities,
                activity: activity,
                close: { sampleSession = nil },
                addHost: { addition in
                    pendingSampleAddition = addition
                    sampleSession = nil
                })
        }
        .alert(
            "Could Not Open Sample",
            isPresented: Binding(
                get: { sampleCreationError != nil },
                set: { if !$0 { sampleCreationError = nil } })
        ) {
            Button("OK", role: .cancel) { sampleCreationError = nil }
        } message: {
            Text(sampleCreationError ?? "")
        }
        .onChange(of: hosts.sampleHost) { _, host in
            guard host == nil else { return }
            pendingSampleAddition = nil
            sampleSession = nil
        }
        .sheet(item: $startAgentSheet, onDismiss: startPendingPreset) { sheet in
            // StartAgentView brings its own NavigationStack.
            StartAgentView(
                hosts: consoleHosts, console: console, quickChat: sheet.quickChat,
                preset: sheet.preset
            ) { launched in
                // A fresh launch lands in its own terminal, exactly as
                // tapping the new row would — an Agent and a plain shell
                // alike, since both are rows.
                notificationRouter.path = [launched]
            }
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(
                    horizontalSizeClass: horizontalSizeClass)))
        }
        .sheet(isPresented: $isShowingAIUsage, onDismiss: {
            startPendingKeychainFix()
            startPendingPreset()
        }) {
            // Tall on iPad so every provider and the footer fit without scrolling.
            AIUsageView(store: aiUsage, scope: effectiveHostID) { request in
                // One sheet at a time: the fix's opens from onDismiss.
                pendingKeychainFix = request
                isShowingAIUsage = false
            }
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(
                    horizontalSizeClass: horizontalSizeClass),
                isTall: true))
        }
        .sheet(isPresented: $isShowingSettings, onDismiss: startPendingPreset) {
            // Tall on iPad with compact section spacing so the whole list, About
            // footer included, shows at once instead of a form sheet cut off
            // mid-list. iPhone keeps its inherited sheet and default spacing.
            SettingsView(
                terminal: terminal,
                appearance: appearance,
                pushRegistration: pushRegistration,
                notificationPreferences: notificationPreferences,
                relaySettings: relaySettings,
                agentSummaries: agentSummaries,
                liveActivities: liveActivities,
                console: console,
                hosts: hosts.hosts,
                aiUsage: aiUsage,
                iCloudSync: iCloudSync,
                chatMode: chatModeSettings)
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(
                    horizontalSizeClass: horizontalSizeClass),
                isTall: true))
        }
        .sheet(isPresented: $isShowingHelp, onDismiss: startPendingPreset) {
            NavigationStack {
                HelpView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingHelp = false }
                                .accessibilityIdentifier("help.done")
                        }
                    }
            }
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(
                    horizontalSizeClass: horizontalSizeClass),
                isTall: true))
        }
        .sheet(item: $helpPresentation, onDismiss: startPendingPreset) { presentation in
            HelpPresentationSheet(presentation: presentation) { helpPresentation = nil }
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: ConsoleSheetPresentation(
                        horizontalSizeClass: horizontalSizeClass),
                    isTall: true))
        }
        .sheet(item: $pluginUpdateSheet, onDismiss: startPendingPreset) { sheet in
            WaycarPluginUpdateSheet(store: sheet.store)
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: ConsoleSheetPresentation(
                        horizontalSizeClass: horizontalSizeClass)))
        }
        .sheet(item: $backendInstallSheet, onDismiss: startPendingPreset) { sheet in
            BackendInstallHostSheet(panel: sheet.panel)
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: ConsoleSheetPresentation(
                        horizontalSizeClass: horizontalSizeClass)))
        }
        .modifier(
            ConsoleStatusBarModifier(
                scheme: terminalStatusBarColorScheme
            )
        )
        // Above the NavigationStack so a banner also shows over a pushed
        // Agent detail; a tap deep-links exactly like a push tap would.
        .overlay(alignment: .top) {
            if let banner = bannerStore.banner {
                AgentNotificationBannerView(banner: banner) {
                    bannerStore.dismiss()
                    openNotificationTarget(banner.target)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: bannerStore.banner)
        // A notification deep link must land on Agent detail even when one of
        // the Console's sheets covers it. The only other push a sheet can
        // cause is the new-agent flow's, which dismisses itself first, so
        // clearing here is a no-op for it.
        .onChange(of: notificationRouter.path) { _, path in
            guard !path.isEmpty else { return }
            // Host detail stays up over a plugin update it started in this
            // window, whose sheet it presents.
            if !isHostSheetUpdatingPlugin { hostSheet = nil }
            hostAddition = nil
            startAgentSheet = nil
            isShowingSettings = false
            isShowingHelp = false
            helpPresentation = nil
            // A running update keeps its sheet: it refuses a swipe down too.
            if pluginUpdateSheet?.store.isRunning != true { pluginUpdateSheet = nil }
            backendInstallSheet = nil
            isShowingAIUsage = false
            pendingKeychainFix = nil
            pendingPreset = nil
            isNewChatPending = false
        }
        // A New Chat quick action replaces whatever New Agent sheet is up;
        // a fresh sheet identity re-presents it in quick chat.
        .onChange(of: newChatRequest, initial: true) {
            guard newChatRequest > 0 else { return }
            startNewChat()
        }
        // A filter pointing at a removed or disabled Host would silently
        // hide every Agent; fall back to All Hosts instead.
        .onChange(of: consoleHosts) { _, hosts in
            if let hostFilter, !hosts.contains(where: { $0.id == hostFilter }) {
                self.hostFilter = nil
            }
        }
        // Workspaces belong to the Host scope; a new scope starts at All.
        .onChange(of: hostFilter) { _, _ in
            selectedWorkspaceID = .all
        }
        // Usage is account-level: the scoped Host is only the preferred
        // place to read it from, per window.
        .onAppear { aiUsage.setScope(effectiveHostID, forWindow: aiUsageWindow) }
        .onChange(of: effectiveHostID) { _, scope in
            aiUsage.setScope(scope, forWindow: aiUsageWindow)
        }
        .onDisappear { aiUsage.removeWindow(aiUsageWindow) }
        // Snapshot the Agent as it is listed at the moment it is opened (an
        // unread-marked Agent is held as Done); keep that snapshot while it
        // stays open, and let go on any other selection. Opening it reads
        // its unread mark and closes the pushed portrait list; a move
        // re-targeting the open Agent is no opening.
        .onChange(of: notificationRouter.path.last, initial: true) { previous, id in
            let isMove = notificationRouter.isRetarget(from: previous, to: id)
            // Backing out of a resumed Closed Session never used recloses it.
            if let previous, previous != id, !isMove {
                backedOut(of: previous)
            }
            if id != nil, !isMove { splitVisibility.agentDidOpen() }
            // Navigating anywhere (a deep link, a keyboard step) leaves
            // Selection Mode, whose rows open nothing.
            if !isMove { multiSelection = nil }
            guard heldAgent?.id != id else { return }
            heldAgent = id.flatMap { console.listedAgent($0) }
            if let id, !isMove { console.markRead(id) }
        }
        .environment(\.consoleCommandRegistry, commandRegistry)
        .environment(\.sampleConnect, sampleConnect)
        // Every Help surface the Console presents, however deep, offers
        // Ask an Agent through this.
        .environment(\.askAgent, sampleConnect == nil && !consoleHosts.isEmpty ? askAgent : nil)
        // The Console's plugin row, Agent cards and every Agent detail's
        // Chat Mode notice open the same update sheet through this.
        .environment(\.requestWaycarPluginUpdate, pluginUpdateAction)
        .focusedSceneValue(\.consoleCommandTarget, commandTarget)
    }

    private func slideOver(_ presentation: ConsoleSplitPresentation) -> some View {
        let isSidebarVisible = splitVisibility.isSidebarVisible(applying: presentation)
        return ConsoleSlideOverLayout(
            reveal: presentation.sidebarReveal,
            sidebarColumn: presentation.sidebarWidth,
            isSidebarVisible: isSidebarVisible,
            setSidebarVisible: { splitVisibility.setSidebarVisible($0) }
        ) {
            agentsColumn(pinnedBottomBar: true)
        } detail: {
            detail
        }
        // The covered list's search field would otherwise keep taking the
        // hardware keyboard's keystrokes, and the command target keep
        // reporting the list focused. What was typed stays for its return.
        .onChange(of: isSidebarVisible) { _, isVisible in
            let opensSearch = opensSearchOnReveal
            opensSearchOnReveal = false
            if !isVisible {
                isSearchFocused = false
            } else if opensSearch {
                // A pass after the Agent's own resign, so the field keeps focus.
                openSearch()
            }
            if isVisible {
                // The freshly mounted list is focusable by default; the
                // terminal holding the keyboard re-suppresses it, or arrows
                // would walk the Agent list before the terminal sees them
                // (#80, seen on a hardware-keyboard iPad).
                commandRegistry.terminal?.resuppressKeyboardFocus?()
            }
        }
    }

    private func splitView(_ presentation: ConsoleSplitPresentation) -> some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { splitVisibility.visibility },
            set: { splitVisibility.systemDidChangeVisibility($0, presentation: presentation) })
        ) {
            agentsColumn(pinnedBottomBar: false)
                // The title still names the column for the back button,
                // window switcher and VoiceOver, but the heading itself
                // is not drawn: the filters lead the list.
                .navigationTitle("Agents")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(removing: .title)
                .navigationSplitViewColumnWidth(
                    min: presentation.sidebarWidth.minimum,
                    ideal: presentation.sidebarWidth.ideal,
                    max: presentation.sidebarWidth.maximum)
                // The column's controls live in the bottom bar, so at
                // compact width the empty navigation bar goes too. Regular
                // width keeps it for the split view's own sidebar button.
                .toolbar(
                    horizontalSizeClass == .compact ? .hidden : .automatic,
                    for: .navigationBar)
        } detail: {
            detail
        }
        // Keep structural identity stable across rotation and size-class changes.
        .navigationSplitViewStyle(.automatic)
    }

    /// Before the first Host the setup steps stand in for the Agents and
    /// carry Settings themselves.
    private var isAwaitingFirstHost: Bool {
        hosts.hosts.isEmpty && hosts.catalogLoadError == nil
    }

    /// The Agent list over its bottom bar: the split view's sidebar column,
    /// or the layer under the Agent in the slide-over. The slide-over pins
    /// the bar to the column's bottom edge as an overlay: a safe-area inset
    /// rides the keyboard region up — the strip the system's mini keyboard
    /// bar occupies while a hardware keyboard types into the terminal — and
    /// left the bar parked off the screen edge (#79). The pinned bar never
    /// moves, and the list keeps a scroll margin of the bar's height so its
    /// last row clears it. The split view keeps the bar in a bottom
    /// safe-area inset, above the home indicator, as before.
    private func agentsColumn(pinnedBottomBar: Bool) -> some View {
        content
            .overlay(alignment: .bottom) {
                if pinnedBottomBar {
                    consoleBottomBar()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            pinnedBarHeight = $0
                        }
                }
            }
            .contentMargins(
                .bottom,
                pinnedBottomBar && !isAwaitingFirstHost ? pinnedBarHeight : 0,
                for: .scrollContent)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !pinnedBottomBar { consoleBottomBar() }
            }
            // The keyboard belongs to the terminal in the detail. On iPad
            // its safe area (even the shortcut bar a hardware keyboard
            // leaves) otherwise lifts the list's content off the screen
            // edge while an Agent has focus.
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    @ViewBuilder
    private func consoleBottomBar() -> some View {
        // Before the first Host its Workspace and New Agent can do
        // nothing, Hosts would repeat the steps on screen, and the
        // steps carry Settings.
        if !isAwaitingFirstHost {
            if multiSelection != nil {
                selectionActionBar()
            } else {
                ConsoleBottomBar(
                    hosts: consoleHosts,
                    moshStates: moshStates,
                    hostSelection: $hostFilter,
                    workspaceOptions: workspaceOptions,
                    tmuxWorkspaceOptionIDs: tmuxWorkspaceOptionIDs,
                    zellijWorkspaceOptionIDs: zellijWorkspaceOptionIDs,
                    workspaceSelection: Binding(
                        get: { effectiveWorkspaceID },
                        set: { selectedWorkspaceID = $0 }),
                    newAgent: { startAgent() },
                    showHosts: { presentHosts() },
                    showSettings: presentSettings)
            }
        }
    }

    private var commandTarget: ConsoleCommandTarget {
        // A departing row is leaving: keyboard navigation steps over it.
        let agents = visibleAgents.lazy
            .filter { console.departingRow($0.id) == nil }
            .map(\.id)
        let agentIDs = Array(agents)
        return ConsoleCommandTarget(
            registry: commandRegistry,
            context: {
                .init(
                    selection: notificationRouter.path.last,
                    agents: agentIDs,
                    isSearchFocused: isSearchFocused,
                    isCovered: isPresentingSheet)
            },
            navigate: { id in
                guard id != notificationRouter.path.last else { return }
                if commandRegistry.terminal?.isFocused == true
                    || commandRegistry.composer?.isFocused == true
                {
                    keyboardHandoff.arm(for: id)
                }
                notificationRouter.path = [id]
            },
            focusSearch: {
                if splitVisibility.revealForSearch() {
                    opensSearchOnReveal = true
                } else {
                    openSearch()
                }
            },
            newAgent: { startAgent() },
            settings: presentSettings,
            hosts: { presentHosts() },
            closeAgent: { clearSelection() },
            help: { isShowingHelp = true })
    }

    /// The sidebar selection as a projection of the router's path. Setting
    /// it (a row tap, or the collapsed stack popping) writes the path back,
    /// so user navigation and deep links keep one source of truth. In
    /// Selection Mode it reads nothing, so every row tap reaches the setter,
    /// which checks or unchecks the row and opens nothing.
    private var selectedItem: Binding<ConsoleAgent.ID?> {
        Binding(
            get: { multiSelection == nil ? notificationRouter.path.last : nil },
            set: { selection in
                if multiSelection != nil {
                    if let selection, selectableAgents.contains(where: { $0.id == selection }) {
                        multiSelection?.toggle(selection)
                    }
                } else if let selection {
                    selectAgent(selection)
                } else {
                    clearSelection()
                }
            })
    }

    private func selectAgent(_ id: ConsoleAgent.ID) {
        // Re-picking the open Agent leaves the path as it is, so the path's
        // own handler never sees it; it still closes the pushed portrait list.
        if id == notificationRouter.path.last { splitVisibility.agentDidOpen() }
        changeSelection {
            notificationRouter.path = [id]
        }
    }

    private func clearSelection() {
        changeSelection {
            notificationRouter.path = []
        }
    }

    /// A selection that replaces one detail screen with another dissolves
    /// between them. A first selection or a cleared one is the split view's
    /// own navigation and needs nothing from here, and neither is a pick
    /// that closes the pushed portrait list: the crossfade would freeze the
    /// list-open frame over the Agent sliding back.
    private func changeSelection(_ change: () -> Void) {
        let before = notificationRouter.path.last
        let closesList = splitVisibility.agentOpenClosesList
        change()
        let after = notificationRouter.path.last
        guard let before, let after, before != after, !closesList,
              let window = sceneWindow?.window
        else { return }
        detailCrossfade.beginSwap(in: window)
    }

    /// The split view owns the window's status-bar appearance on iPhone. A
    /// pushed terminal cannot reliably override it from the detail subtree.
    /// The Chat view is drawn in the brand's dark palette whatever the
    /// terminal theme, so its status bar is too. A Queued Launch's screen
    /// draws the system background, so it keeps the system's.
    private var terminalStatusBarColorScheme: ColorScheme? {
        guard let id = notificationRouter.path.last,
            QueuedLaunch.launchID(forPendingAgent: id) == nil
        else { return nil }
        let showsTerminalSurface = console.listedAgent(id) != nil
        if showsTerminalSurface, chatPresentedAgent == id { return Brand.colorScheme }
        let showsTerminalSyncSurface = !showsTerminalSurface
            && MissingAgentPresentation(agentID: id, console: console, hosts: hosts)
                .renderingMode == .progress
        guard showsTerminalSurface || showsTerminalSyncSurface else { return nil }
        return terminal.themes.selection(for: colorScheme)
            .chromeColorScheme(for: colorScheme)
    }

    /// The detail column. Not keyed off the live Agent list alone: the
    /// selection must survive its Agent leaving the list while shown (a Host
    /// with no last-known inventory lists nothing until it answers), so a
    /// vanished Agent shows a placeholder instead of clearing the selection.
    @ViewBuilder
    private var detail: some View {
        if hosts.hosts.isEmpty {
            // No Agent is listed without a Host, so a selection restored from
            // an earlier launch, or left by removing the last Host, yields to
            // the setup steps. At compact width the list shows them itself.
            hostSetup
        } else if let id = notificationRouter.path.last {
            if let receipt = matchingRemovedWorktreeReceipt(for: id) {
                removedWorktreeSurface(receipt)
            } else if let launchID = QueuedLaunch.launchID(forPendingAgent: id) {
                if let launch = console.queuedLaunch(forPendingAgent: id) {
                    QueuedLaunchDetailView(
                        launch: launch, console: console,
                        host: hosts.hosts.first { $0.id == launch.hostID })
                        .id(launch.id)
                } else {
                    Color.clear.task(id: id) {
                        guard notificationRouter.path.last == id else { return }
                        if let started = console.startedAgentsByQueuedLaunch[launchID] {
                            selectAgent(started)
                        } else {
                            clearSelection()
                        }
                    }
                }
            } else if let agent = console.listedAgent(id) {
                AgentDetailView(
                    agent: agent,
                    console: console,
                    terminal: terminal,
                    hosts: hosts.hosts,
                    activity: activity,
                    keyboardHandoff: keyboardHandoff,
                    keyboardInset: keyboardInset,
                    stage: AgentDetailStage(
                        // The router's truth, not SwiftUI's appear/disappear:
                        // only the screen still selected may rebuild its
                        // terminal on a spurious reappearance.
                        isVisible: { [notificationRouter] in
                            notificationRouter.path.last == id
                                && console.listedAgent(id) != nil
                        },
                        terminalAccess: { [sceneRouting, backend = agent.backend] in
                            backend.terminalAccess(
                                sceneRouting?.terminalAccess(for: id.hostID) ?? .holds)
                        }),
                    onSwitch: { selectAgent($0) },
                    onClosed: { clearSelection() },
                    onMarkedUnread: { clearSelection() },
                    onChatPresentationChange: { showsChat in
                        if showsChat {
                            chatPresentedAgent = id
                        } else if chatPresentedAgent == id {
                            chatPresentedAgent = nil
                        }
                    }
                )
                // Selecting another Agent must tear down the previous terminal
                // pipeline; without the explicit identity the detail column
                // would reuse the old view's state. See `AgentDetailIdentity`
                // for what else rebuilds it.
                .id(AgentDetailIdentity(agent))
            } else {
                // The Agent is gone from the list, but not necessarily
                // because its pane went: a Host with no last-known inventory
                // lists nothing while it connects or after it fails, and
                // blaming the Agent for that hides the only text that says
                // what to do about it (#146).
                // The stores, not their contents: which collections this reads
                // is the part a test can then assert, and the part #146 got
                // wrong.
                let presentation = MissingAgentPresentation(
                    agentID: id, console: console, hosts: hosts)
                missingAgentSurface(presentation)
            }
        } else {
            ConsoleEmptyDetailView(
                presentation: ConsoleEmptyDetailPresentation(
                    showsAgentsAction: splitVisibility.showsAgentsAction,
                    hostCount: hosts.hosts.count,
                    enabledHostCount: consoleHosts.count)
            ) { action in
                switch action {
                case .showAgents:
                    // Animates the split view's column; the slide-over
                    // slides on its own.
                    withAnimation(reduceMotion ? nil : .snappy) {
                        splitVisibility.setSidebarVisible(true)
                    }
                case .newAgent: startAgent()
                case .hosts: presentHosts()
                }
            }
        }
    }

    /// A receipt is keyed by the Agent set captured at the authorized write.
    /// If the same pane id has already returned, require the live row to match
    /// the exact removed workspace/worktree identity before showing it.
    private func matchingRemovedWorktreeReceipt(
        for id: ConsoleAgent.ID
    ) -> WorktreeRemovalReceipt? {
        RemovedWorktreeSelection.receipt(
            for: id,
            agents: console.agents,
            receipts: console.removedWorktreesByAgent)
    }

    private func removedWorktreeSurface(
        _ receipt: WorktreeRemovalReceipt
    ) -> some View {
        ContentUnavailableView {
            Label("Worktree Removed", systemImage: "checkmark.circle")
        } description: {
            Text(
                "The checkout at \(receipt.request.identity.checkoutPath) was removed and its workspace was closed. No branch was deleted."
            )
        } actions: {
            Button("Back to Console") { notificationRouter.path = [] }
                .buttonStyle(.borderedProminent)
                .hoverEffect(.highlight)
        }
    }

    @ViewBuilder
    private func missingAgentSurface(_ presentation: MissingAgentPresentation) -> some View {
        if presentation.renderingMode == .progress {
            let theme = terminal.themes.selection(for: colorScheme)
            ZStack {
                theme.surfaceBackground(for: colorScheme)
                    .ignoresSafeArea()
                TerminalStatusDialog(
                    glyph: .progress,
                    title: presentation.title,
                    message: presentation.message,
                    palette: theme.palette(for: colorScheme),
                    dimsBackground: false)
            }
        } else {
            ContentUnavailableView(
                presentation.title, systemImage: presentation.systemImage,
                description: Text(presentation.message))
        }
    }

    /// What stands in for the Agents while there is no Host: the setup
    /// steps, or why none can be added when the catalog could not be read.
    @ViewBuilder
    private var hostSetup: some View {
        if hosts.catalogLoadError != nil {
            HostCatalogUnavailableView()
        } else {
            HostSetupGuide(
                scan: { hostAddition = .scan },
                addManually: { hostAddition = .manual },
                showSettings: presentSettings,
                showHelp: {
                    Task {
                        await HelpPresentation.open(.install, openURL: openURL) {
                            helpPresentation = $0
                        }
                    }
                },
                sampleHostRow: hosts.sampleHost.map { _ in AnyView(sampleHostRow) })
        }
    }

    private var sampleHostRow: some View {
        Button(action: presentSample) {
            HStack(spacing: 14) {
                Image(systemName: "play.rectangle")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sample")
                        .font(.headline)
                    Text("Fictional offline agents")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: .rect(cornerRadius: Brand.Radius.control))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityIdentifier("setup.sample")
    }

    private func presentSample() {
        guard hosts.sampleHost != nil, sampleSession == nil,
            retiringSampleSession == nil
        else { return }
        do {
            let session = try SampleSession()
            retiringSampleSession = session
            sampleSession = session
            analytics?.milestone(.sampleHostOpened)
        } catch {
            sampleCreationError = "The offline sample could not be opened. Please try again."
        }
    }

    private func sampleDidDismiss() {
        let session = retiringSampleSession
        let addition = pendingSampleAddition
        pendingSampleAddition = nil
        Task {
            await session?.stop()
            retiringSampleSession = nil
            if let addition, hosts.sampleHost != nil { hostAddition = addition }
            startPendingPreset()
        }
    }

    @ViewBuilder
    private var content: some View {
        let surface = agentsSurface
        if surface == .noHosts {
            if horizontalSizeClass == .regular {
                // The detail beside the list holds the setup steps.
                ContentUnavailableView {
                    Label("No Hosts", systemImage: "server.rack")
                } description: {
                    if hosts.catalogLoadError == nil {
                        Text("Your Agents show up here once you add a Host.")
                    }
                }
            } else {
                hostSetup
            }
        } else {
            List(selection: selectedItem) {
                aiUsageRows
                agentListBody(surface)
            }
            // Outside the List on purpose: a section header is a UIKit-hosted
            // supplementary view that drops the search morph's animation and
            // swaps its content a beat late.
            .safeAreaInset(edge: .top, spacing: 0) {
                listHeader
                    // The column's bottom margin is the List's, for the
                    // pinned bar; the pills' horizontal scroller takes none.
                    .contentMargins(.bottom, 0, for: .scrollContent)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            // A live snapshot replacing last-known rows removes the panes
            // that are gone; animate that rather than snapping rows away.
            .animation(reduceMotion ? nil : .snappy, value: visibleAgents.map(\.id))
            .animation(reduceMotion ? nil : .snappy, value: visibleClosedSessions.map(\.id))
            // A Queued Launch arrives, changes state, and leaves as its
            // Agent's own row comes in.
            .animation(reduceMotion ? nil : .snappy, value: visibleQueuedLaunches.map(\.id))
            .animation(reduceMotion ? nil : .snappy, value: visibleQueuedLaunches.map(\.state))
            // A poll that adds a provider, a first report or a failure
            // grows or shrinks the AI Usage card; animate that too.
            .animation(reduceMotion ? nil : .snappy, value: aiUsageLayoutKey)
            // A sent swiped Close's rows stay listed for a while
            // (`ConsoleStore.rowDepartureHold`): their cards lift out, then
            // the rows leave the List.
            .onChange(of: console.departingRows.map(\.agent.id)) { _, departing in
                liftDepartingRows(Set(departing))
            }
            // A checked Agent that leaves the list (closed, filtered away)
            // leaves the selection.
            .onChange(of: selectableAgents.map(\.id)) { _, ids in
                multiSelection?.prune(keeping: Set(ids))
            }
            .onScrollPhaseChange { _, phase in
                // Not `.tracking`: that fires on touch-down, and would shut
                // the open row under a tap on its disc or card.
                if phase == .interacting || phase == .decelerating { openSwipeRow = nil }
            }
            .quietCancelAlert("Could Not Close Tab", isPresented: tabCloseErrorPresented) {
                Button("OK", role: .cancel) { console.tabCloseFailure = nil }
                    .tint(Brand.Colors.quietAction)
            } message: {
                Text(console.tabCloseFailure ?? "")
            }
            .quietCancelAlert("Could Not Move Agent", isPresented: moveAgentErrorPresented) {
                Button("OK", role: .cancel) { moveAgentError = nil }
                    .tint(Brand.Colors.quietAction)
            } message: {
                Text(moveAgentError ?? "")
            }
            .sheet(item: $renamingTabOf) { agent in
                RenameSheetView(
                    title: "Rename Tab",
                    store: RenameStore.tab(
                        currentLabel: HostConsoleProjection.shellName(
                            tabLabel: agent.tabLabel, tabPosition: agent.tabPosition) ?? ""
                    ) { [console] label in
                        try await console.renameTab(of: agent, label: label)
                    })
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: ConsoleSheetPresentation(
                        horizontalSizeClass: horizontalSizeClass)))
            }
            .sheet(item: $resumedZellijSession) { row in
                ClosedZellijSessionTerminalView(
                    row: row, console: console, terminal: terminal, hosts: hosts.hosts,
                    activity: activity, keyboardHandoff: keyboardHandoff, keyboardInset: keyboardInset,
                    isPresented: { resumedZellijSession?.id == row.id },
                    dismiss: { resumedZellijSession = nil })
            }
            .modifier(ZellijSessionDeleteConfirmation(pending: $zellijSessionToDelete) { row in
                Task {
                    do { try await console.deleteClosedZellijSession(row) }
                    catch { closedSessionResumeError = error.localizedDescription }
                }
            })
            .task(id: showsClosedZellijSessions) {
                if showsClosedZellijSessions { await console.refreshClosedZellijSessions() }
            }
            .quietCancelAlert("Could Not Resume Session", isPresented: closedSessionResumeErrorPresented) {
                Button("OK", role: .cancel) { closedSessionResumeError = nil }
                    .tint(Brand.Colors.quietAction)
            } message: {
                Text(closedSessionResumeError ?? "")
            }
        }
    }

    /// AI Usage between the Status pills and the cards, scrolling away with
    /// the list: the summary row and, while expanded, every provider under
    /// it. Absent while no Host can report usage.
    @ViewBuilder
    private var aiUsageRows: some View {
        if let source = aiUsage.source(scopedTo: effectiveHostID) {
            AIUsageSummaryRow(
                store: aiUsage, source: source, isExpanded: isAIUsageExpanded,
                toggle: toggleAIUsage)
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            if isAIUsageExpanded {
                AIUsageSummaryCard(
                    store: aiUsage, source: source, scope: effectiveHostID,
                    showDetails: { isShowingAIUsage = true })
                    .modifier(ConsoleCardRow())
            }
        }
    }

    private func toggleAIUsage() {
        withAnimation(reduceMotion ? nil : .snappy) {
            isAIUsageExpanded.toggle()
        }
    }

    /// What changes the AI Usage rows' layout, coarsely: whether they show,
    /// and which providers, report and failure the card lays out. Numbers
    /// changing within a poll leave it alone.
    private struct AIUsageLayoutKey: Equatable {
        var hasSource = false
        var providerIDs: [String] = []
        var hasSnapshot = false
        var hasFailure = false
    }

    private var aiUsageLayoutKey: AIUsageLayoutKey {
        guard let source = aiUsage.source(scopedTo: effectiveHostID) else {
            return AIUsageLayoutKey()
        }
        let state = aiUsage.usage[source.hostID]
        return AIUsageLayoutKey(
            hasSource: true,
            providerIDs: state?.snapshot?.report.providers.map(\.id) ?? [],
            hasSnapshot: state?.snapshot != nil,
            hasFailure: state?.lastFailure != nil)
    }

    /// The cards under the pinned header, or the empty state that explains
    /// why there are none. The header stays either way, so the Host picker
    /// and search remain reachable from an empty list.
    @ViewBuilder
    private func agentListBody(_ surface: ConsoleAgentsSurface) -> some View {
        switch surface {
        case .noHosts, .rows:
            hostIssueAndQueuedLaunchRows
            ForEach(visibleAgents) { agent in
                agentRow(agent)
            }
            // Alone (the Closed pill) they need no header; beside Agents (a
            // search) they follow every Agent in their own section.
            if visibleAgents.isEmpty {
                ForEach(visibleClosedSessions) { session in
                    closedSessionRow(session)
                }
                ForEach(visibleClosedZellijSessions) { zellijClosedRow($0) }
            } else if !visibleClosedSessions.isEmpty || !visibleClosedZellijSessions.isEmpty {
                Section {
                    ForEach(visibleClosedSessions) { session in
                        closedSessionRow(session)
                    }
                    ForEach(visibleClosedZellijSessions) { zellijClosedRow($0) }
                } header: {
                    Text("Closed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        case .noAgentsWithStatus(let filter):
            emptyStateRow {
                ContentUnavailableView {
                    Label(filter.emptyTitle, systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Show All") { selectStatus(.all) }
                        .hoverEffect(.highlight)
                }
            }
        case .allHostsDisabled(let hostCount):
            emptyStateRow {
                ContentUnavailableView {
                    Label("No Agents", systemImage: "rectangle.on.rectangle.slash")
                } description: {
                    Text(ConsoleAgentsSurface.allHostsDisabledMessage(hostCount: hostCount))
                } actions: {
                    Button("Hosts") { presentHosts() }
                        .hoverEffect(.highlight)
                }
            }
        case .noAgents, .noAgentsOnHost:
            // Only outdated-plugin rows can be left here: they sit above
            // the empty state and never stand in for it.
            hostIssueRows
            if let host = sessionlessTmuxHost {
                startTmuxSessionState(host)
            } else if case .noAgentsOnHost(let hostName) = surface {
                noAgentsOnHostState(hostName)
            } else {
                emptyStateRow {
                    ContentUnavailableView {
                        Label("No Agents", systemImage: "rectangle.on.rectangle.slash")
                    } description: {
                        Text("Agents detected on your Hosts appear here.")
                    }
                }
            }
        case .noSearchResults:
            emptyStateRow {
                ContentUnavailableView {
                    Label("No Results", systemImage: "magnifyingglass")
                } description: {
                    Text("No agents match \"\(searchText)\".")
                } actions: {
                    Button("Clear Search") { searchText = "" }
                        .buttonStyle(.borderedProminent)
                        .hoverEffect(.highlight)
                }
            }
        }
    }

    private var hostIssueRows: some View {
        ForEach(visibleHostIssues) { issue in
            hostIssueListRow(issue)
        }
    }

    /// The Host rows with each Queued Launch under its Host's last row, and
    /// the launches of Hosts that show none after them, above every Agent:
    /// a launch waiting for an offline Host sits right under the row that
    /// says it is offline.
    @ViewBuilder
    private var hostIssueAndQueuedLaunchRows: some View {
        let launches = visibleQueuedLaunches
        if launches.isEmpty {
            hostIssueRows
        } else {
            ForEach(ConsoleLeadRow.ordered(issues: visibleHostIssues, launches: launches)) { row in
                switch row {
                case .issue(let issue): hostIssueListRow(issue)
                case .launch(let launch): queuedLaunchRow(launch)
                }
            }
        }
    }

    private func hostIssueListRow(_ issue: ConsoleHostStatusPresentation) -> some View {
        Group {
            // A backend's row carries its own Retry instead, and a stopped
            // runtime's its Start.
            if issue.navigates && issue.retryScope == nil && issue.startsRuntime == nil {
                Button {
                    if issue.opensBackendInstall {
                        presentBackendInstall(issue.hostID)
                    } else {
                        presentHosts(issue.hostID)
                    }
                } label: {
                    hostIssueRow(issue, showsChevron: true)
                }
                .buttonStyle(.plain)
                .accessibilityHint(
                    issue.opensBackendInstall
                        ? "Opens setup for this Host." : "Opens this Host's settings.")
            } else {
                hostIssueRow(issue, showsChevron: false)
            }
        }
        .modifier(ConsoleCardRow())
    }

    private func noAgentsOnHostState(_ hostName: String) -> some View {
        emptyStateRow {
            ContentUnavailableView {
                Label(
                    "No Agents on \(hostName)",
                    systemImage: "server.rack")
            } actions: {
                Button("Show All Hosts") { hostFilter = nil }
                    .hoverEffect(.highlight)
            }
        }
    }

    private func emptyStateRow(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: .infinity, minHeight: 320)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// Pinned above the cards: search folded into an icon ahead of the
    /// Status pills and the Closed chip. Opening it grows the icon into
    /// a field that pushes the pills off to the trailing edge; closing it
    /// pulls them back. Host and Workspace live in the bottom bar with the
    /// other controls. Selection Mode adds its own row on top.
    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if multiSelection != nil {
                selectionHeaderRow
            }
            filterRow
        }
        .modifier(ConsoleListHeaderInsets(rowHeight: Self.searchIconSize))
        // The pushed pills leave at the column's edge, not the screen's.
        .clipped()
        .background(Color(uiColor: .systemGroupedBackground))
    }

    /// The search icon and the Status pills. In Selection Mode a closed
    /// search steps aside so the pills lead; an open one stays, since its
    /// text still filters the rows Select All checks.
    private var filterRow: some View {
        let showsSearch = multiSelection == nil || isSearchPresented
        return ZStack(alignment: .leading) {
            // First, so VoiceOver and keyboard focus reach it before the pills.
            if showsSearch {
                searchControl
                    .zIndex(1)
            }
            ConsoleStatusPillBar(
                counts: ConsoleListProjection.statusCounts(
                    workspaceAgents, held: heldAgent, chatAgentIDs: chatAgentIDs),
                selection: statusFilter,
                onSelect: selectStatus,
                closedCount: scopedClosedSessions.count + scopedClosedZellijSessions.count)
            .padding(.leading, showsSearch ? Self.searchIconSize + 8 : 0)
            // Glued to the capsule's trailing edge as it grows and shrinks.
            .offset(x: isSearchPresented ? max(0, headerRowWidth - Self.searchIconSize) : 0)
            .opacity(isSearchPresented ? 0 : 1)
            .allowsHitTesting(!isSearchPresented)
            .accessibilityHidden(isSearchPresented)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
            headerRowWidth = $0
        }
    }

    /// Selection Mode's header row, on the search capsule's line height:
    /// Select All checks every Agent the filters show, the count sits in
    /// the middle, and Done leaves. Plain text, not the accent: the mode
    /// is a quiet one.
    private var selectionHeaderRow: some View {
        let selectable = selectableAgents.map(\.id)
        return HStack(spacing: 0) {
            Button("Select All") { multiSelection?.selectAll(selectable) }
                .padding(.horizontal, 8)
                .frame(minHeight: Self.searchIconSize)
                .contentShape(Rectangle())
                .disabled(selectable.isEmpty)
                .opacity(selectable.isEmpty ? 0.4 : 1)
                .hoverEffect(.highlight)
            Spacer(minLength: 8)
            Text("\(selectedAgents.count) Selected")
                .font(.headline)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button("Done") { endSelection() }
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .frame(minHeight: Self.searchIconSize)
                .contentShape(Rectangle())
                .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .frame(minHeight: Self.searchIconSize)
    }

    private static let searchIconSize: CGFloat = 34

    /// One capsule for both states, so opening morphs the icon's circle into
    /// the field instead of swapping one view for another.
    private var searchControl: some View {
        HStack(spacing: 0) {
            Button { openSearch() } label: {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(isSearchPresented ? .secondary : .primary)
                    .frame(width: Self.searchIconSize, height: Self.searchIconSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .accessibilityLabel("Search Agents")
            .accessibilityHidden(isSearchPresented)
            if isSearchPresented {
                TextField("Search Agents", text: $searchText)
                    .focused($isSearchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onKeyPress(.escape) {
                        closeSearch()
                        return .handled
                    }
                    // The field only exists once search opens; focus it then.
                    .task { isSearchFocused = true }
                    .transition(.opacity)
                Button { closeSearch() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .frame(height: Self.searchIconSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close Search")
                .transition(.opacity)
            }
        }
        // The open capsule takes the proposed width rather than the measured
        // one, so a narrower column (rotation, window resize) shrinks it too.
        .frame(
            minWidth: Self.searchIconSize,
            maxWidth: isSearchPresented ? .infinity : Self.searchIconSize,
            alignment: .leading)
        .frame(height: Self.searchIconSize)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
        .clipShape(Capsule())
    }

    private func openSearch() {
        withAnimation(searchAnimation) {
            isSearchPresented = true
        }
        isSearchFocused = true
    }

    private func closeSearch() {
        isSearchFocused = false
        withAnimation(searchAnimation) {
            searchText = ""
            isSearchPresented = false
        }
    }

    /// Long enough to read as the pills being pushed and pulled, not
    /// swapped; none under Reduce Motion.
    private var searchAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.35)
    }

    /// A departing card's lift: it speeds up as it rises and fades, so the
    /// rows below start gliding just as it is gone; under Reduce Motion a
    /// plain fade, since the card then only fades.
    private var liftAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.2) : .easeIn(duration: 0.2)
    }

    /// Lifts the cards of newly departing rows out of their places, then
    /// deletes the rows from the List, the rows below gliding up into their
    /// place. Only the card moves: a List does not animate a row's own height
    /// change, so the gap closes through the delete. The delete runs in its
    /// own animated transaction: left to the List's implicit animation, a
    /// store-driven removal mostly lands unanimated and the rows below snap
    /// up. Under Reduce Motion they close up without moving. Rows the store
    /// no longer lists are forgotten.
    private func liftDepartingRows(_ departing: Set<ConsoleAgent.ID>) {
        liftedRows.formIntersection(departing)
        droppedRows.formIntersection(departing)
        let arriving = departing.subtracting(liftedRows)
        guard !arriving.isEmpty else { return }
        withAnimation(liftAnimation) {
            liftedRows.formUnion(arriving)
        } completion: {
            // The store may have stopped listing some meanwhile.
            let lifted = arriving.intersection(liftedRows)
            withAnimation(reduceMotion ? nil : .snappy) {
                droppedRows.formUnion(lifted)
            }
        }
    }

    private func selectStatus(_ filter: ConsoleStatusFilter) {
        withAnimation(reduceMotion ? nil : .snappy) {
            statusFilter = filter
        }
    }

    /// A Closed Session's card: a tap resumes it, a swipe or the context
    /// menu forgets it. It cannot resume while its Host is not connected,
    /// or while another resume is in flight.
    private func zellijClosedRow(_ row: ClosedZellijSession) -> some View {
        let connected = console.hostStatuses[row.hostID] == .connected
        return Button { resumedZellijSession = row } label: {
            ClosedZellijSessionCardView(row: row).modifier(AgentCardChrome(isSelected: false))
        }
        .buttonStyle(.plain)
        .disabled(!connected || multiSelection != nil)
        .opacity(connected ? 1 : 0.55)
        .accessibilityHint("Resumes this Zellij session on the Host.")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { zellijSessionToDelete = row }
                .disabled(!connected || multiSelection != nil)
        }
        .contextMenu {
            Button("Resume", systemImage: "arrow.uturn.forward") { resumedZellijSession = row }
                .disabled(!connected || multiSelection != nil)
            Button("Delete", systemImage: "trash", role: .destructive) { zellijSessionToDelete = row }
                .disabled(!connected || multiSelection != nil)
        }
        .modifier(ConsoleCardRow())
    }

    private func closedSessionRow(_ session: ClosedSession) -> some View {
        let isConnected = console.hostStatuses[session.hostID] == .connected
        let canResume = session.canResume && isConnected && resumingClosedSession == nil
        let host = hosts.hosts.first { $0.id == session.hostID }
        let isSelecting = multiSelection != nil
        return Button { resume(session) } label: {
            ClosedSessionCardView(
                session: session,
                hostName: host?.displayName,
                hostUsername: host?.username,
                isResuming: resumingClosedSession == session.id)
            .modifier(AgentCardChrome(isSelected: false))
        }
        .buttonStyle(.plain)
        .disabled(!canResume || isSelecting)
        .opacity(isConnected ? 1 : 0.55)
        .hoverEffect(.highlight)
        .accessibilityHint(
            !session.canResume
                ? "Resume this \(session.backend.serverChat?.sessionDescription ?? "session") on the Host."
                : isConnected ? "Resumes this Agent in a new tab." : "Its Host is not connected.")
        .modifier(AgentRowGap(rowGap: console.rowLayout(for: session.hostID).rowGap))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            // Inert in Selection Mode, like the tap.
            if !isSelecting {
                Button("Forget", systemImage: "trash", role: .destructive) {
                    forgetClosedSession(session)
                }
            }
        }
        .contextMenu {
            // Inert in Selection Mode, like the tap.
            if !isSelecting {
                Button("Resume", systemImage: "arrow.uturn.forward") { resume(session) }
                    .disabled(!canResume)
                Button("Forget", systemImage: "trash", role: .destructive) {
                    forgetClosedSession(session)
                }
            }
        }
        .modifier(ConsoleCardRow())
    }

    /// Resumes a Closed Session and opens the resumed Agent, the way a New
    /// Agent launch lands in its terminal; a failure keeps the row and says
    /// why. The launch can take seconds while the list stays usable, so it
    /// opens the Agent only if the user has not opened another meanwhile.
    private func resume(_ session: ClosedSession) {
        guard resumingClosedSession == nil else { return }
        resumingClosedSession = session.id
        let selectionAtTap = notificationRouter.path.last
        Task {
            let outcome = await ClosedSessionResumer(console: console).resume(session)
            resumingClosedSession = nil
            switch outcome {
            case .started(let id):
                // Opened elsewhere meanwhile: the user never saw it, so it
                // stays live as any other resume would.
                guard notificationRouter.path.last == selectionAtTap else {
                    console.closedSessions.resolvePendingResumeAsUsed(session.id)
                    return
                }
                notificationRouter.path = [id]
            case .failed(let message):
                closedSessionResumeError = message
            }
        }
    }

    private func forgetClosedSession(_ session: ClosedSession) {
        withAnimation(reduceMotion ? nil : .snappy) {
            console.closedSessions.forget(session.id)
        }
    }

    /// A Queued Launch's card (CONTEXT.md **Queued Launch**): it waits for
    /// its Host, shows progress while it starts, and once it failed
    /// offers Retry and Delete. A swipe or the context menu
    /// deletes it; one that is starting is past deleting. Its dashed outline
    /// says it is still on this device, not an Agent on the Host; once it
    /// starts, the Agent's own row takes over.
    private func queuedLaunchRow(_ launch: QueuedLaunch) -> some View {
        let host = hosts.hosts.first { $0.id == launch.hostID }
        let isSelecting = multiSelection != nil
        let canRemove = !isSelecting && launch.state != .starting
        let presentation = QueuedLaunchPresentation(
            launch, hostName: host?.displayName, hostUsername: host?.username,
            workspaces: console.workspacesByHost[launch.hostID] ?? [],
            pendingMessages: console.pendingComposer(for: launch.id)?.messages ?? [])
        return QueuedLaunchCardView(
            presentation: presentation,
            state: launch.state,
            createdAt: launch.createdAt,
            retry: { retryQueuedLaunch(launch) },
            delete: { removeQueuedLaunch(launch) })
        .modifier(AgentCardChrome(
            isSelected: !isSelecting && notificationRouter.path.last == launch.pendingAgentID))
        .onTapGesture {
            guard !isSelecting else { return }
            selectAgent(launch.pendingAgentID)
        }
        .tag(launch.pendingAgentID)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(presentation.headline)
        .accessibilityHint("Opens this launch to queue messages")
        // Neutral in every state: the status word and glyph carry colour.
        .modifier(QueuedMessageOutline(
            state: launch.state == .starting ? .sending : .queued, cornerRadius: 18))
        // Inert in Selection Mode, like a Closed Session's card.
        .disabled(isSelecting)
        .modifier(AgentRowGap(rowGap: console.rowLayout(for: launch.hostID).rowGap))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if canRemove {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    removeQueuedLaunch(launch)
                }
            }
        }
        .contextMenu {
            if canRemove {
                if launch.state.awaitsUser {
                    Button("Retry", systemImage: "arrow.clockwise") { retryQueuedLaunch(launch) }
                }
                Button("Delete", systemImage: "trash", role: .destructive) {
                    removeQueuedLaunch(launch)
                }
            }
        }
        .modifier(ConsoleCardRow())
    }

    private func retryQueuedLaunch(_ launch: QueuedLaunch) {
        console.retryQueuedLaunch(launch.id)
    }

    private func removeQueuedLaunch(_ launch: QueuedLaunch) {
        withAnimation(reduceMotion ? nil : .snappy) {
            console.cancelQueuedLaunch(launch.id)
        }
    }

    /// Closes the resumed Agent `id` left unused (`ClosedSessionsStore
    /// .backedOut`); it lists as a Closed Session again. Silent either way.
    private func backedOut(of id: ConsoleAgent.ID) {
        let console = console
        Task {
            await console.closedSessions.backedOut(
                of: id,
                verifiedRow: { try await console.verifiedAgent($0) },
                closePane: { try await console.closePane(of: $0) })
        }
    }

    /// Rows of a backend with the herdr plugin follow its Agent Row Layout;
    /// tmux and herdr-core rows get what a Host without plugin fields gets
    /// (`AgentRowLayoutResolver`).
    private func rowLayout(for agent: ConsoleAgent) -> AgentRowLayout {
        guard !agent.backend.capabilities.pluginRowLayout else { return console.rowLayout(for: agent.hostID) }
        return console.rowLayouts.resolvedLayout(
            for: agent.hostID,
            pluginSnapshot: console.sidebarSnapshots.snapshot(for: agent.hostID),
            backend: agent.backend)
    }

    /// Whether the Host lists a herdr runtime's and tmux's rows together, the
    /// only case where tmux rows and Workspaces carry a `tmux` mark.
    private func listsBothBackends(on hostID: Host.ID) -> Bool {
        let backends = console.presentBackends(on: hostID)
        return backends.contains(where: \.fillsHerdrSlot) && backends.contains(.tmux)
    }

    private func agentRow(_ agent: ConsoleAgent) -> some View {
        let layout = rowLayout(for: agent)
        // A departing row keeps the swiped Close it was drawn with.
        let departing = console.departingRow(agent.id)
        let pending = departing == nil ? console.pendingTabCloses[agent.id] : departing?.pendingClose
        let isLifted = liftedRows.contains(agent.id)
        let isSelecting = multiSelection != nil
        // Only a row Selection Mode can act on draws checked.
        let isChecked = multiSelection?.contains(agent.id) == true
            && pending == nil && departing == nil
        // Selection Mode's checkboxes stand in for the open Agent's ring.
        let isSelected = !isSelecting && (notificationRouter.path.last == agent.id
            || (agent.backend == .ultimate && agent.ultimateChildren.contains {
                notificationRouter.path.last == .init(hostID: agent.hostID, paneID: $0.paneID)
            }))
        // An older plugin never sends progress (#209); Selection Mode's rows
        // act on nothing but their checkbox.
        let showsPluginHint = !isSelecting
            && agent.showsPluginProgressHint(
                summariesEnabled: agentSummaries.isEnabled,
                pluginStatus: console.waycarPluginStatus(on: agent.hostID))
        let updatePluginForProgress: (() -> Void)? =
            showsPluginHint ? { presentPluginUpdate(agent.hostID) } : nil
        return HStack(spacing: 12) {
            if isSelecting, agent.backend.hasTerminal {
                SelectionCheckbox(isChecked: isChecked)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            AgentCardView(
                agent: agent,
                layout: layout,
                isPinned: console.pins.isPinned(
                    hostID: agent.hostID, paneID: agent.agent.paneID),
                isChatMode: console.isChatMode(agent),
                queuedCount: console.queuedMessageCounts[agent.id] ?? 0,
                openUltimateChild: agent.backend == .ultimate ? { selectAgent($0) } : nil,
                updatePluginForProgress: updatePluginForProgress)
            .modifier(AgentCardChrome(
                isSelected: isSelected, isChecked: isChecked, progressAgent: agent))
        }
        .modifier(SwipeToCloseRow(
            pending: pending,
            agentName: agent.agent.displayName,
            closesWorkspace: console.closesWorkspaceWithTab(of: agent),
            isDeparting: departing != nil,
            isOpen: Binding(
                get: { openSwipeRow == agent.id },
                set: { open in
                    if open {
                        openSwipeRow = agent.id
                    } else if openSwipeRow == agent.id {
                        openSwipeRow = nil
                    }
                }),
            close: {
                // No confirmation, Workspace or not: the countdown is the
                // undo window, and the card stays where the swipe left it.
                scheduleRowClose(agent)
            },
            undo: { console.undoTabClose(agent.id) },
            isEnabled: !isSelecting && agent.backend.closesRows,
            announcesCountdown: !bulkClosingRows.contains(agent.id),
            archives: agent.backend.archivesOnClose))
        .modifier(AgentRowGap(rowGap: layout.rowGap))
        .modifier(DepartingRowLift(
            isDeparting: departing != nil, isLifted: isLifted, rises: !reduceMotion))
        .hoverEffect(.highlight)
        // The selected cell's system focus halo would duplicate the card's ring.
        .background(ListCellFocusHaloRemover(isSelected: isSelected))
        .background(ConsoleListSelectionModeTuner(isSelecting: isSelecting))
        .tag(agent.id)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isChecked ? .isSelected : [])
        .contextMenu {
            // The way into Selection Mode, for VoiceOver too; holding a card
            // alone never changes the mode.
            if agent.backend.hasTerminal, !isSelecting, pending == nil, departing == nil {
                Section {
                    Button("Select", systemImage: "checkmark.circle") {
                        beginSelection(with: agent.id)
                    }
                }
            }
            let pinned = console.pins.isPinned(
                hostID: agent.hostID, paneID: agent.agent.paneID)
            Button(
                pinned ? "Unpin" : "Pin",
                systemImage: pinned ? "pin.slash" : "pin"
            ) {
                console.togglePin(
                    hostID: agent.hostID, paneID: agent.agent.paneID)
            }
            if console.unread.isMarkedUnread(agent.id) {
                Button("Mark as Read", systemImage: "envelope.open") {
                    console.markRead(agent.id)
                    refreshHeldAgent(agent.id)
                }
                .accessibilityLabel("Mark as Read")
                .accessibilityHint("Lists this Agent by its Host status again.")
            } else if console.unread.canMarkUnread(agent) {
                Button("Mark as Unread", systemImage: "envelope.badge") {
                    console.markUnread(agent)
                    refreshHeldAgent(agent.id)
                }
                .accessibilityLabel("Mark as Unread")
                .accessibilityHint("Lists this Agent as Done until you open it.")
            }
            // The move path: Workspace is a menu, so there is no drop target.
            if !moveWorkspaces(for: agent).isEmpty {
                Menu {
                    ForEach(moveWorkspaces(for: agent)) { workspace in
                        Button(workspace.label) {
                            moveAgent(agent, to: workspace)
                        }
                    }
                } label: {
                    Label("Move to Workspace…", systemImage: "folder")
                }
            }
            // herdr only (not core, not tmux): the tab label, which a shell row also shows as its name.
            if agent.backend == .herdr || agent.backend == .zellij, !isSelecting, pending == nil, departing == nil {
                Button("Rename Tab…", systemImage: "pencil") {
                    renamingTabOf = agent
                }
            }
            // Never on iPhone, and not for the Agent this window already shows.
            if supportsMultipleWindows, notificationRouter.path.last != agent.id {
                Button("Open in New Window", systemImage: "plus.rectangle.on.rectangle") {
                    openInNewWindow(agent)
                }
            }
            // The pointer path to the swipe: the same undo countdown, with
            // the card slid aside over the draining disc.
            if agent.backend.closesRows, !isSelecting, pending == nil, departing == nil {
                if agent.backend.archivesOnClose {
                    Button("Archive", systemImage: "archivebox") { scheduleRowClose(agent) }
                } else {
                    Button("Close", systemImage: "trash", role: .destructive) {
                        scheduleRowClose(agent)
                    }
                }
            }
        }
        .modifier(
            AgentWindowDrag(
                route: AgentRoute(agentID: agent.id),
                title: agent.agent.displayName,
                isAvailable: supportsMultipleWindows,
                isEnabled: !isSelecting))
        .modifier(ConsoleCardRow())
    }

    /// A mark changed on an Agent: re-take the held row if it is this
    /// window's (`ConsoleStore.held(_:afterMarkChangeOn:)`).
    private func refreshHeldAgent(_ id: ConsoleAgent.ID) {
        heldAgent = console.held(heldAgent, afterMarkChangeOn: id)
    }

    /// Workspaces offered as move targets for one Agent: the Agent's Host's
    /// known workspaces, minus the one it already lives in (a same-workspace
    /// move is a no-op, so it must not be offered).
    private func moveWorkspaces(for agent: ConsoleAgent) -> [ConsoleWorkspace] {
        // herdr-core has no `pane.move`: no Move to Workspace on its rows.
        guard agent.backend.capabilities.renaming, agent.backend != .zellij else { return [] }
        return (console.workspacesByHost[agent.hostID] ?? [])
            .filter { $0.id != agent.agent.workspaceID }
    }

    /// Moves the Agent into `workspace` (`pane.move`). When the moved Agent
    /// was the open detail the selection re-targets to its new pane id —
    /// herdr re-keys the pane during the move and reports the new id in the
    /// reply.
    private func moveAgent(_ agent: ConsoleAgent, to workspace: ConsoleWorkspace) {
        let hostID = agent.hostID
        // Moving an Agent is using it: a resume pending on it stays live.
        console.noteUserInput(to: agent.id)
        Task {
            do {
                let response = try await console.moveAgent(
                    agent, toWorkspaceID: workspace.id, on: hostID)
                guard let response,
                    notificationRouter.path.last == agent.id
                else { return }
                let newID = ConsoleAgent.ID(
                    hostID: hostID, paneID: response.moveResult.pane.paneID)
                guard newID != agent.id else { return }
                notificationRouter.retarget(from: agent.id, to: newID)
            } catch {
                moveAgentError = ConsoleStore.failureMessage(for: error)
            }
        }
    }

    /// Enters Selection Mode with `id` checked; an open swipe shuts.
    private func beginSelection(with id: ConsoleAgent.ID) {
        openSwipeRow = nil
        var selection = ConsoleMultiSelection()
        selection.insert(id)
        withAnimation(reduceMotion ? nil : .snappy) {
            multiSelection = selection
        }
    }

    private func endSelection() {
        withAnimation(reduceMotion ? nil : .snappy) {
            multiSelection = nil
        }
    }

    /// The listed Agents Selection Mode can check: a row whose Close is
    /// counting down or already sent is spoken for.
    private var selectableAgents: [ConsoleAgent] {
        visibleAgents.filter {
            $0.backend.hasTerminal
                && console.pendingTabCloses[$0.id] == nil && console.departingRow($0.id) == nil
        }
    }

    /// The checked Agents as listed now, in list order: what every bulk
    /// action acts on.
    private var selectedAgents: [ConsoleAgent] {
        guard let multiSelection else { return [] }
        return selectableAgents.filter { multiSelection.contains($0.id) }
    }

    /// Selection Mode's bar, standing where the bottom bar stands.
    private func selectionActionBar() -> some View {
        let agents = selectedAgents
        let move = ConsoleBulkActions.moveAvailability(for: agents)
        return ConsoleSelectionActionBar(
            pinAction: ConsoleBulkActions.pinAction(for: agents) {
                console.pins.isPinned(hostID: $0.hostID, paneID: $0.agent.paneID)
            },
            readAction: ConsoleBulkActions.readAction(
                for: agents,
                isMarkedUnread: { console.unread.isMarkedUnread($0) },
                canMarkUnread: { console.unread.canMarkUnread($0) }),
            moveAvailability: move,
            moveTargets: bulkMoveWorkspaces(move, agents: agents),
            closeCount: agents.count,
            pin: { applyBulkPin($0) },
            mark: { applyBulkRead($0) },
            move: { moveSelection(to: $0) },
            close: { closeSelection() })
    }

    /// Pins the unpinned checked Agents, or unpins them all once every one
    /// is pinned. Selection Mode stays for the next action. Pinning goes
    /// bottom-up, since each pin lands on top of the pinned rows, so the
    /// newly pinned rows keep their listed order.
    private func applyBulkPin(_ action: ConsoleBulkPinAction) {
        let agents = action == .pin ? Array(selectedAgents.reversed()) : selectedAgents
        for agent in agents {
            let pinned = console.pins.isPinned(hostID: agent.hostID, paneID: agent.agent.paneID)
            guard pinned == (action == .unpin) else { continue }
            console.togglePin(hostID: agent.hostID, paneID: agent.agent.paneID)
        }
    }

    /// Marks the checked Agents read or unread, each only where that mark
    /// applies, as the context menu would one at a time.
    private func applyBulkRead(_ action: ConsoleBulkReadAction) {
        for agent in selectedAgents {
            switch action {
            case .markRead:
                guard console.unread.isMarkedUnread(agent.id) else { continue }
                console.markRead(agent.id)
            case .markUnread:
                guard console.unread.canMarkUnread(agent) else { continue }
                console.markUnread(agent)
            }
            refreshHeldAgent(agent.id)
        }
    }

    /// The Workspaces a one-Host selection can move into, alphabetically:
    /// each with at least one checked Agent outside it.
    private func bulkMoveWorkspaces(
        _ availability: ConsoleBulkMoveAvailability, agents: [ConsoleAgent]
    ) -> [ConsoleWorkspace] {
        guard case .available(let hostID) = availability else { return [] }
        return (console.workspacesByHost[hostID] ?? [])
            .filter { workspace in agents.contains { $0.agent.workspaceID != workspace.id } }
            .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// Moves every checked Agent not already there into `workspace`, one
    /// `pane.move` each, then leaves Selection Mode.
    private func moveSelection(to workspace: ConsoleWorkspace) {
        for agent in selectedAgents where agent.agent.workspaceID != workspace.id {
            moveAgent(agent, to: workspace)
        }
        endSelection()
    }

    /// Starts each checked Agent's own swiped Close, no confirmation: every
    /// row slides aside over its draining undo disc, and a tap on one undoes
    /// that one alone. Then Selection Mode ends. VoiceOver hears one
    /// announcement for them all, not one per row.
    private func closeSelection() {
        let agents = selectedAgents
        bulkClosingRows = Set(agents.map(\.id))
        for agent in agents {
            console.scheduleTabClose(agent)
        }
        endSelection()
        guard !agents.isEmpty else { return }
        let seconds = Int(ConsoleStore.tabCloseUndoSeconds)
        let message = agents.count == 1
            ? "Closing 1 Agent in \(seconds) seconds. Undo on its row to cancel."
            : "Closing \(agents.count) Agents in \(seconds) seconds. Undo on each row to cancel."
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    /// A row's own Close, swiped or from its menu: announced on its row.
    private func scheduleRowClose(_ agent: ConsoleAgent) {
        bulkClosingRows.remove(agent.id)
        console.scheduleTabClose(agent)
        openSwipeRow = nil
    }

    private var tabCloseErrorPresented: Binding<Bool> {
        Binding(
            get: { console.tabCloseFailure != nil },
            set: { shown in if !shown { console.tabCloseFailure = nil } })
    }

    private var moveAgentErrorPresented: Binding<Bool> {
        Binding(
            get: { moveAgentError != nil },
            set: { shown in if !shown { moveAgentError = nil } })
    }

    private var closedSessionResumeErrorPresented: Binding<Bool> {
        Binding(
            get: { closedSessionResumeError != nil },
            set: { shown in if !shown { closedSessionResumeError = nil } })
    }

    /// A window already showing this Agent comes forward instead of a second
    /// one opening: two windows on one Agent would contend for its Host's
    /// single terminal channel.
    private func openInNewWindow(_ agent: ConsoleAgent) {
        if sceneRouting?.directory.activateScene(presenting: agent.id) == true { return }
        openWindow(value: AgentRoute(agentID: agent.id))
    }

    /// Deep links raised inside this window obey the same single-window rule
    /// as a notification tap.
    private func openNotificationTarget(_ target: AgentNotificationTarget?) {
        if let sceneRouting {
            sceneRouting.open(target)
        } else {
            notificationRouter.open(target)
        }
    }

    private var agentsSurface: ConsoleAgentsSurface {
        ConsoleAgentsSurface(
            hostCount: hosts.hosts.count,
            enabledHostCount: consoleHosts.count,
            filteredHostName: effectiveHostID == nil ? nil : filteredHostName,
            filteredAgentCount: visibleAgents.count + visibleClosedSessions.count + visibleClosedZellijSessions.count
                + visibleQueuedLaunches.count,
            // A plugin row is no reason to list: the empty states keep their
            // say and show it above them.
            visibleIssueCount: visibleHostIssues.count(where: { !$0.isPluginRow }),
            statusFilter: statusFilter,
            searchQuery: searchText)
    }

    /// The Hosts the Console presents as live. A Disabled Host is absent
    /// from the Console: no scope, issues, transport or new Agents on it.
    private var consoleHosts: [Host] { hosts.enabledHosts }

    private var effectiveHostID: Host.ID? {
        ConsoleListProjection.effectiveHostID(hostFilter, hosts: consoleHosts)
    }

    /// Each connected Host's mosh/SSH transport, for the Host menu and the
    /// Hosts sheet. Hosts with no connection have nothing to report.
    private var moshStates: [Host.ID: ConsoleStore.MoshHostCapsuleState] {
        Dictionary(uniqueKeysWithValues: consoleHosts.compactMap { host in
            console.hostStatuses[host.id] == nil
                ? nil : (host.id, console.moshCapsuleState(for: host.id))
        })
    }

    /// The store's index less the departing rows already deleted from the
    /// List, so the Workspace menu, Status counts, and empty states change
    /// with the delete, not when the store stops listing the rows.
    private var indexAgents: [ConsoleAgent] {
        let listed = console.indexAgents(holding: heldAgent)
        guard !droppedRows.isEmpty else { return listed }
        return listed.filter { !droppedRows.contains($0.id) }
    }

    private var workspaceOptions: [ConsoleWorkspaceOption] {
        ConsoleListProjection.workspaceOptions(
            hosts: consoleHosts,
            agents: indexAgents,
            workspacesByHost: console.workspacesByHost,
            hostID: effectiveHostID)
    }

    /// Workspace menu entries owned by tmux, on Hosts that list both
    /// backends; nothing on herdr-only and tmux-only Hosts.
    private var tmuxWorkspaceOptionIDs: Set<ConsoleWorkspaceOption.ID> {
        var ids: Set<ConsoleWorkspaceOption.ID> = []
        for (hostID, workspaces) in console.workspacesByHost where listsBothBackends(on: hostID) {
            for workspace in workspaces where workspace.backend == .tmux {
                ids.insert(.group(hostID, .workspace(workspace.id)))
            }
        }
        return ids
    }

    private var zellijWorkspaceOptionIDs: Set<ConsoleWorkspaceOption.ID> {
        var ids: Set<ConsoleWorkspaceOption.ID> = []
        for (hostID, workspaces) in console.workspacesByHost {
            for workspace in workspaces where workspace.backend == .zellij {
                ids.insert(.group(hostID, .workspace(workspace.id)))
            }
        }
        return ids
    }

    private var effectiveWorkspaceID: ConsoleWorkspaceOption.ID {
        ConsoleListProjection.effectiveWorkspaceID(selectedWorkspaceID, in: workspaceOptions)
    }

    /// Host and Workspace applied; the Status pills count from this.
    private var workspaceAgents: [ConsoleAgent] {
        ConsoleListProjection.workspaceAgents(
            options: workspaceOptions, selected: selectedWorkspaceID)
    }

    /// The in-scope Chat Mode Agents' ids, for the Chat pill.
    private var chatAgentIDs: Set<ConsoleAgent.ID> {
        Set(workspaceAgents.filter { console.isChatMode($0) }.map(\.id))
    }

    private var visibleAgents: [ConsoleAgent] {
        ConsoleListProjection.visibleAgents(
            workspaceAgents: workspaceAgents,
            status: statusFilter,
            searchQuery: searchText,
            held: heldAgent,
            chatAgentIDs: chatAgentIDs)
    }

    /// Host and Workspace applied; the Closed chip counts these.
    private var scopedClosedSessions: [ClosedSession] {
        ConsoleListProjection.scopedClosedSessions(
            console.closedSessions.listedSessions,
            listedHostIDs: Set(consoleHosts.map(\.id)),
            hostID: effectiveHostID,
            workspace: effectiveWorkspaceID,
            workspacesByHost: console.workspacesByHost)
    }

    private var showsClosedZellijSessions: Bool {
        statusFilter == .closed || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var scopedClosedZellijSessions: [ClosedZellijSession] {
        guard effectiveWorkspaceID == .all else { return [] }
        let hostIDs = Set(consoleHosts.map(\.id))
        return console.closedZellijSessions.filter {
            hostIDs.contains($0.hostID) && (effectiveHostID == nil || effectiveHostID == $0.hostID)
        }
    }

    private var visibleClosedZellijSessions: [ClosedZellijSession] {
        guard showsClosedZellijSessions else { return [] }
        return scopedClosedZellijSessions.filter {
            ConsoleSearch.matches(searchText, in: [$0.session.name, $0.hostName, "Zellij session"])
        }
    }

    private var visibleClosedSessions: [ClosedSession] {
        ConsoleListProjection.visibleClosedSessions(
            scopedClosedSessions,
            status: statusFilter,
            searchQuery: searchText,
            hostNames: Dictionary(
                hosts.hosts.map { ($0.id, $0.displayName) }) { first, _ in first })
    }

    /// Queued Launches in the Host and Workspace scope, under All or a
    /// search (`ConsoleListProjection.visibleQueuedLaunches`).
    private var visibleQueuedLaunches: [QueuedLaunch] {
        ConsoleListProjection.visibleQueuedLaunches(
            console.queuedLaunches,
            listedHostIDs: Set(consoleHosts.map(\.id)),
            hostID: effectiveHostID,
            workspace: effectiveWorkspaceID,
            workspacesByHost: console.workspacesByHost,
            status: statusFilter,
            searchQuery: searchText,
            hostNames: Dictionary(
                hosts.hosts.map { ($0.id, $0.displayName) }) { first, _ in first })
    }

    /// Host issues shown in the list: all of them, or the scoped Host's
    /// only — a scoped Console should not nag about other machines.
    private var visibleHostIssues: [ConsoleHostStatusPresentation] {
        guard let effectiveHostID else { return hostIssues }
        return hostIssues.filter { $0.hostID == effectiveHostID }
    }

    private var filteredHostName: String {
        hosts.hosts.first(where: { $0.id == effectiveHostID })?.displayName ?? "this Host"
    }

    private struct HostSheet: Identifiable {
        let id = UUID()
        let hostID: Host.ID?
    }

    /// One presentation of the plugin update sheet. It holds the store, so
    /// a run keeps its state for as long as the sheet is up, whatever the
    /// Console's body recomputes.
    private struct PluginUpdateSheet: Identifiable {
        let id = UUID()
        let store: WaycarPluginUpdateStore
    }

    /// One presentation of a Host's install panel. It holds the store, so a
    /// run keeps its state while the sheet is up.
    private struct BackendInstallSheetItem: Identifiable {
        let id = UUID()
        let panel: BackendInstallPanelStore
    }

    /// One actionable status per Host. A disconnected session takes priority;
    /// otherwise a connected Host can still have a failing snapshot RPC. A
    /// Host still inside its reconnect grace keeps its last-known rows and
    /// says nothing unless the user has to act. An outdated plugin speaks
    /// only when nothing else does (`ConsoleHostStatusPresentation.hostRows`).
    private var hostIssues: [ConsoleHostStatusPresentation] {
        consoleHosts.flatMap { host in
            // A Host with no usable backend says so and opens the install
            // panel on a tap, whichever failure its own backend reported;
            // with no install center (previews) it keeps the plain failure.
            let gap = backendInstallCenter == nil
                ? nil : console.backendGapBehindFailure(on: host.id)
            let startErrors = console.startErrors(on: host.id)
            let hostIssue =
                gap.map { ConsoleHostStatusPresentation(host: host, backendGap: $0) }
                ?? ConsoleHostStatusPresentation(
                    host: host,
                    status: console.hostStatuses[host.id],
                    standingFailure: console.hostStandingFailures[host.id],
                    connectedBackends: console.connectedSecondaryBackends(on: host.id),
                    isAwaitingSnapshot: console.hostsAwaitingSnapshot.contains(host.id),
                    isWithinReconnectGrace: console.hostsWithinReconnectGrace.contains(host.id),
                    trustHold: console.hostKeyTrustHolds[host.id],
                    startErrors: startErrors,
                    syncError: console.hostSyncErrors[host.id])
            // A dual Host presents one backend; the other's failure gets its
            // own row with a Retry for that backend alone, or its Start.
            let backendIssues = console.failedSecondaryScopes(on: host.id).map {
                ConsoleHostStatusPresentation(
                    host: host, failedScope: $0.scope, failure: $0.failure,
                    startErrors: startErrors)
            }
            return ConsoleHostStatusPresentation.hostRows(
                condition: hostIssue,
                backendFailures: backendIssues,
                pluginNotice: pluginRow(for: host))
        }
    }

    /// The Host's plugin row: Update for an outdated plugin until Not now at
    /// this build's minimum, Install for a missing one and Update for a
    /// Node-era one until the Host's `HostToolsOffer` hides them. With no offer
    /// record (previews) neither is ever offered.
    private func pluginRow(for host: Host) -> ConsoleHostStatusPresentation? {
        ConsoleHostStatusPresentation.pluginRow(
            host: host,
            pluginStatus: console.waycarPluginStatus(on: host.id),
            nativeToolsStatus: console.nativeToolsStatus(on: host.id),
            noticeDismissals: pluginNoticeDismissals,
            hostToolsOffer: hostToolsOffer)
    }

    /// The Host the empty Console is about when its tmux runs no session
    /// (design §2 scenario 8): the scoped Host, or the only Host.
    private var sessionlessTmuxHost: Host? {
        let candidates = effectiveHostID.map { id in consoleHosts.filter { $0.id == id } }
            ?? consoleHosts
        guard candidates.count == 1, let host = candidates.first,
            console.needsTmuxSession(on: host.id)
        else { return nil }
        return host
    }

    @ViewBuilder
    private func startTmuxSessionState(_ host: Host) -> some View {
        emptyStateRow {
            ContentUnavailableView {
                Label("tmux Isn't Running on \(host.displayName)", systemImage: "terminal")
            } description: {
                Text("Start a tmux session to run Agents and Shells there.")
            } actions: {
                let hostID = host.id
                Button("Start Session") {
                    Task {
                        await sessionStarter.start(on: hostID) {
                            try await console.startTmuxSession(on: $0)
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .hoverEffect(.highlight)
                .disabled(sessionStarter.isStarting(on: hostID))
                if let error = sessionStarter.error(on: hostID) {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .onDisappear { sessionStarter.dismissError(on: host.id) }
        }
    }

    private func hostIssueRow(
        _ issue: ConsoleHostStatusPresentation, showsChevron: Bool
    ) -> some View {
        // At accessibility sizes the buttons move under the text, which then
        // wraps in full rather than truncating beside them.
        let stacksActions = dynamicTypeSize.isAccessibilitySize
        let lineLimit = stacksActions ? nil : 2
        return HStack(alignment: stacksActions ? .firstTextBaseline : .center, spacing: 10) {
            Image(systemName: issue.systemImage)
                .foregroundStyle(hostIssueTint(issue))
            VStack(alignment: .leading, spacing: stacksActions ? 6 : 2) {
                Text(issue.message)
                    .font(.footnote)
                    .foregroundStyle(issue.isCritical ? Color.red : Color.secondary)
                    .lineLimit(lineLimit)
                if let detail = issue.detail {
                    // A failed start's words are what the user tapped for:
                    // a step brighter than a plain hint, and room for
                    // herdr's own message, since this row opens no page.
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(
                            issue.startFailed
                                ? HierarchicalShapeStyle.secondary : HierarchicalShapeStyle.tertiary)
                        .lineLimit(issue.startFailed ? lineLimit.map { $0 + 2 } : lineLimit)
                }
                if stacksActions {
                    HStack(spacing: 16) { hostIssueActions(issue) }
                }
            }
            Spacer(minLength: 0)
            if !stacksActions {
                hostIssueActions(issue)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    /// A Host row's Retry or Start, or the plugin row's Update and Not now.
    @ViewBuilder
    private func hostIssueActions(_ issue: ConsoleHostStatusPresentation) -> some View {
        if let runtime = issue.startsRuntime {
            startRuntimeButton(runtime, on: issue.hostID, hostName: issue.hostName)
        } else if let scope = issue.retryScope {
            Button("Retry") {
                Task { await console.retry(scope) }
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderless)
            .hoverEffect(.highlight)
        }
        switch issue.pluginOffer {
        case .update:
            Button("Update") { presentPluginUpdate(issue.hostID) }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
                .hoverEffect(.highlight)
                .disabled(isUpdatingPlugin(on: issue.hostID))
                .accessibilityHint(isUpdatingPlugin(on: issue.hostID)
                    ? "An update is already running on this Host"
                    : "Updates the Waycar plugin on \(issue.hostName).")
            Button {
                pluginNoticeDismissals.dismiss(issue.hostID)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .hoverEffect(.highlight)
            .accessibilityLabel("Not now")
            .accessibilityHint("Hides this until the app needs a newer plugin.")
        case .install:
            Button("Install") { presentPluginUpdate(issue.hostID) }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
                .hoverEffect(.highlight)
                .disabled(isUpdatingPlugin(on: issue.hostID))
                .accessibilityHint(isUpdatingPlugin(on: issue.hostID)
                    ? "An install is already running on this Host"
                    : "Installs Waycar Host Tools on \(issue.hostName).")
            Button("Not now") { hostToolsOffer?.notNow(issue.hostID) }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
                .hoverEffect(.highlight)
                .accessibilityHint("Hides this for 14 days.")
        case .moveToNative:
            Button("Update") { presentPluginUpdate(issue.hostID) }
                .font(.footnote.weight(.semibold))
                .buttonStyle(.borderless)
                .hoverEffect(.highlight)
                .disabled(isUpdatingPlugin(on: issue.hostID))
                .accessibilityHint(isUpdatingPlugin(on: issue.hostID)
                    ? "An update is already running on this Host"
                    : "Updates Waycar on \(issue.hostName) so it no longer needs Node.")
            Button("Not now") { hostToolsOffer?.nativeToolsNotNow(issue.hostID) }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
                .hoverEffect(.highlight)
                .accessibilityHint("Hides this for 14 days.")
        case nil:
            EmptyView()
        }
    }

    /// Start Herdr TUI or Start Herdr Core on a stopped runtime's row
    /// (#389). While the start and its reconnect run, the same frame shows
    /// a spinner, so the row never shifts.
    private func startRuntimeButton(
        _ runtime: HostBackend, on hostID: Host.ID, hostName: String
    ) -> some View {
        let isStarting = console.isStarting(runtime, on: hostID)
        return Button {
            Task { await console.startRuntime(runtime, on: hostID) }
        } label: {
            ZStack(alignment: .trailing) {
                Text(runtime.startActionTitle)
                    .opacity(isStarting ? 0 : 1)
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Starting…")
                }
                .opacity(isStarting ? 1 : 0)
            }
            .animation(.smooth(duration: 0.25), value: isStarting)
        }
        .font(.footnote.weight(.semibold))
        .buttonStyle(.borderless)
        .hoverEffect(.highlight)
        .disabled(isStarting)
        .accessibilityLabel(
            isStarting ? "Starting \(runtime.displayName)" : runtime.startActionTitle)
        .accessibilityHint(isStarting ? "" : "Starts \(runtime.displayName) on \(hostName).")
    }

    private func hostIssueTint(_ issue: ConsoleHostStatusPresentation) -> Color {
        switch issue.severity {
        case .critical: .red
        case .warning: .orange
        case .informational: .secondary
        }
    }

    /// New Agent from the Console. With every Host disabled the sheet would
    /// have no Host to offer.
    private func startAgent() {
        if let sampleConnect { sampleConnect(); return }
        guard !consoleHosts.isEmpty else { return }
        startAgentSheet = StartAgentSheet(quickChat: nil)
    }

    /// The New Chat quick action. A New Agent sheet already up is replaced
    /// in the same transaction (a fresh sheet identity); any other covering
    /// sheet closes first and New Chat opens from its onDismiss, since a
    /// sheet requested while another animates away is dropped.
    private func startNewChat() {
        if let sampleConnect { sampleConnect(); return }
        guard !consoleHosts.isEmpty else { return }
        let wasCovered = hostSheet != nil || hostAddition != nil || isShowingSettings
            || isShowingHelp || helpPresentation != nil || isShowingAIUsage
            || backendInstallSheet != nil
        // Clear every other Console presentation, as a deep link does. Host
        // detail stays up over a plugin update it started in this window; the
        // new chat then waits for it to close.
        if !isHostSheetUpdatingPlugin { hostSheet = nil }
        hostAddition = nil
        isShowingSettings = false
        isShowingHelp = false
        helpPresentation = nil
        isShowingAIUsage = false
        // A run the sheet shows goes on without it.
        backendInstallSheet = nil
        pendingKeychainFix = nil
        pendingPreset = nil
        startAgentSheet = nil
        if wasCovered {
            isNewChatPending = true
        } else {
            isNewChatPending = false
            startAgentSheet = StartAgentSheet(quickChat: NewChatPreferences.current())
        }
    }

    /// The Keychain Fix the user confirmed in AI Usage, once that sheet is
    /// gone: New Agent prefilled for the blocked Host, which stays locked,
    /// handing over `CodexBarKeychainFix.agentPrompt`. Nothing starts until
    /// the user taps Start.
    private func startPendingKeychainFix() {
        guard let request = pendingKeychainFix else { return }
        pendingKeychainFix = nil
        let hostID = request.hostID
        guard let host = consoleHosts.first(where: { $0.id == hostID }) else { return }
        let preset = CodexBarKeychainFix.preset(
            hostID: hostID,
            hostName: host.displayName,
            problem: request.problem,
            providers: request.providers,
            codexBarPath: aiUsage.detection(for: hostID).path)
        startAgentSheet = StartAgentSheet(quickChat: nil, preset: preset)
    }

    /// Help's Ask an Agent, from any Help surface the Console presents:
    /// every Console sheet that could hold Help closes, and the prefilled
    /// New Agent sheet opens from the closing sheet's onDismiss (a sheet
    /// requested while another animates away is dropped). With nothing
    /// covering the Console it opens at once.
    private func askAgent(_ preset: AgentLaunchPreset) {
        if let sampleConnect { sampleConnect(); return }
        guard !consoleHosts.isEmpty else { return }
        let wasCovered = isPresentingSheet
        pendingPreset = preset
        isNewChatPending = false
        hostSheet = nil
        hostAddition = nil
        startAgentSheet = nil
        isShowingSettings = false
        isShowingHelp = false
        helpPresentation = nil
        isShowingAIUsage = false
        backendInstallSheet = nil
        if !wasCovered { startPendingPreset() }
    }

    /// Opens `pendingPreset`'s sheet, or a pending New Chat, once no Console
    /// sheet is up; each of those sheets calls this from its onDismiss.
    private func startPendingPreset() {
        guard !isPresentingSheet else { return }
        if isNewChatPending {
            isNewChatPending = false
            startAgentSheet = StartAgentSheet(quickChat: NewChatPreferences.current())
            return
        }
        guard let preset = pendingPreset else { return }
        pendingPreset = nil
        startAgentSheet = StartAgentSheet(quickChat: nil, preset: preset)
    }

    private var isPresentingSheet: Bool {
        hostSheet != nil || hostAddition != nil || startAgentSheet != nil
            || isShowingSettings || isShowingHelp || helpPresentation != nil
            || isShowingAIUsage || pluginUpdateSheet != nil || sampleSession != nil
            || backendInstallSheet != nil
    }

    private func presentHosts(_ id: Host.ID? = nil) {
        if let sampleConnect { sampleConnect(); return }
        hostSheet = HostSheet(hostID: id)
    }

    private func presentSettings() {
        if let sampleConnect { sampleConnect(); return }
        isShowingSettings = true
    }

    /// What every surface below the Console calls to update a Host's plugin.
    private var pluginUpdateAction: WaycarPluginUpdateAction {
        let console = console
        return WaycarPluginUpdateAction(
            status: { console.waycarPluginStatus(on: $0) },
            present: { presentPluginUpdate($0) })
    }

    /// Whether a plugin update runs on `hostID`, in this window or another.
    private func isUpdatingPlugin(on hostID: Host.ID) -> Bool {
        pluginUpdateActivity?.runningHosts.contains(hostID) == true
    }

    /// Opens the update sheet for `hostID` with a store of its own, which
    /// reports a finished install back to the Console: it records what the
    /// fresh detection found and reconnects the Host, which clears the
    /// prompts. One at a time; a second ask while it is up, or while any
    /// window or Host detail updates that Host, does nothing.
    private func presentPluginUpdate(_ hostID: Host.ID) {
        guard pluginUpdateSheet == nil, !isUpdatingPlugin(on: hostID),
            let host = hosts.hosts.first(where: { $0.id == hostID })
        else { return }
        let console = console
        pluginUpdateSheet = PluginUpdateSheet(
            store: WaycarPluginUpdateStore(
                host: host,
                detection: console.backendPresence(on: hostID)?.waycarPlugin,
                backends: console.resolvedBackends(on: hostID) ?? [],
                onUpdated: { console.waycarPluginUpdated(on: hostID, presence: $0) },
                activity: pluginUpdateActivity))
    }

    /// Opens the install panel for `hostID` in a sheet titled with the Host
    /// (frame 7). A second ask while it is up does nothing.
    private func presentBackendInstall(_ hostID: Host.ID) {
        guard backendInstallSheet == nil, let center = backendInstallCenter,
            let host = hosts.hosts.first(where: { $0.id == hostID })
        else { return }
        backendInstallSheet = BackendInstallSheetItem(
            panel: BackendInstallPanelStore(host: host, center: center, console: console))
    }

    private func reconnectHost(_ id: Host.ID) async {
        guard manualReconnectInFlightHostIDs.insert(id).inserted else { return }
        await console.retryHost(id)
        try? await Task.sleep(for: .milliseconds(1_200))
        manualReconnectInFlightHostIDs.remove(id)
    }
}

private struct ConsoleStatusBarModifier: ViewModifier {
    let scheme: ColorScheme?

    @ViewBuilder
    func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            content
                .toolbarVisibility(.visible, for: .statusBar)
                .toolbarColorScheme(scheme, for: .statusBar)
        } else {
            content
                .toolbarColorScheme(scheme, for: .navigationBar)
        }
        #else
        content
            .toolbarColorScheme(scheme, for: .navigationBar)
        #endif
    }
}

/// The list header row's padding. Inside the iPad slide-over the row shares
/// the sidebar toggle's line: it starts clear of the toggle and centers on
/// it, which lifts the list into the space a navigation bar used to take.
private struct ConsoleListHeaderInsets: ViewModifier {
    /// The row's content height: the search capsule's.
    let rowHeight: CGFloat

    @Environment(\.consoleSidebarHeaderSlot) private var slot

    private static let horizontal: CGFloat = 16
    private static let vertical: CGFloat = 6

    func body(content: Content) -> some View {
        content
            .padding(.leading, slot?.leading ?? Self.horizontal)
            .padding(.trailing, Self.horizontal)
            .padding(.vertical, Self.vertical)
            .padding(
                .top,
                slot.map { $0.topPadding(rowHeight: rowHeight, verticalPadding: Self.vertical) } ?? 0)
    }
}

/// What the detail column shows when the selected Agent is not in the
/// Console list, and — through `attachHostCondition` — what an open detail
/// says while its Host has not verified it. Seven conditions need seven
/// answers (#141, #146, #154, #155, #110). A Host keeps its last-known rows
/// through a reconnect, so the list lacks an Agent there only when the Host
/// has no last-known inventory or the Agent was not in it.
///
/// Read whether the Host is a Disabled Host first, then Host Connection
/// Status, then Standing Failure, then the Agent Inventory. A Standing
/// Failure changes only what `.connecting` looks like. The inventory is
/// consulted only under `.connected`.
struct MissingAgentPresentation: Equatable {
    /// Which situation the Host is in. Explicit so that collapsing them
    /// into a single message cannot happen by accident.
    enum Cause: Hashable {
        case hostSuspended
        case hostConnecting
        case hostReconnecting
        /// A stopped Host, or a `.connecting` Host that still carries a
        /// Standing Failure.
        case hostFailed
        /// The Host is Connected, but its first snapshot for this connection
        /// has not landed yet.
        case hostLoadingAgents
        /// The Host is a Disabled Host: nothing contacts it, so no status
        /// says anything about it.
        case hostDisabled
        case paneGone
    }

    enum RenderingMode: Equatable {
        case progress
        case staticUnavailable
    }

    let cause: Cause
    let title: String
    let systemImage: String
    let message: String

    var renderingMode: RenderingMode {
        switch cause {
        case .hostConnecting, .hostReconnecting, .hostLoadingAgents:
            .progress
        case .hostSuspended, .hostFailed, .hostDisabled, .paneGone:
            .staticUnavailable
        }
    }

    /// Resolves the Host from the selection rather than taking a status the
    /// caller looked up: the pane address alone is not unique across Hosts,
    /// so `ConsoleAgent.ID` carries the `hostID`, and keeping the resolution
    /// here means no call site can apply a *different* rule to it.
    ///
    /// This initializer takes the *contents* and so cannot police where they
    /// came from — passing an empty `hostStatuses` restores #146's defect
    /// outright, since every failed Host then falls back to the placeholder.
    /// The detail column therefore does not call it; it calls the store-taking
    /// initializer below, which is the one under test (#152).
    init(
        agentID: ConsoleAgent.ID,
        hostStatuses: [Host.ID: EventsSessionStatus],
        hosts: [Host],
        hostsAwaitingSnapshot: Set<Host.ID> = [],
        hostStandingFailures: [Host.ID: TransportError] = [:]
    ) {
        let host = hosts.first { $0.id == agentID.hostID }
        let hostName = host?.displayName
        func named(_ text: String) -> String {
            hostName.map { "\($0): \(text)" } ?? text
        }
        func applyFailed(_ failure: TransportError) -> (
            Cause, String, String, String
        ) {
            (
                .hostFailed,
                "Host Unavailable",
                failure.isHostKeySecurityFailure
                    ? "exclamationmark.shield.fill" : "exclamationmark.triangle.fill",
                named(failure.presentation.message)
            )
        }
        let hostStatus = hostStatuses[agentID.hostID]
        let standingFailure = hostStandingFailures[agentID.hostID]
        // Before the status: a Disabled Host has none, which would otherwise
        // read as a pane that is no longer reported.
        if let host, !host.isEnabled {
            cause = .hostDisabled
            title = "\(host.displayName) Is Disabled"
            systemImage = "power.circle"
            message = "Turn it on in Hosts to see its Agents."
            return
        }
        switch hostStatus {
        case .suspended:
            cause = .hostSuspended
            title = "Connection Paused"
            systemImage = "pause.circle"
            message = named("The connection is paused until Waycar becomes active.")
        case .connecting:
            if let standingFailure {
                (cause, title, systemImage, message) = applyFailed(standingFailure)
            } else {
                cause = .hostConnecting
                title = "Connecting…"
                systemImage = "dot.radiowaves.left.and.right"
                message = named("Opening the connection.")
            }
        case .reconnecting(_, _, let failure):
            cause = .hostReconnecting
            title = "Reconnecting…"
            systemImage = "arrow.trianglehead.2.clockwise"
            message = named(failure.presentation.summary)
        case .failed(let failure):
            (cause, title, systemImage, message) = applyFailed(failure)
        case .connected:
            if hostsAwaitingSnapshot.contains(agentID.hostID) {
                cause = .hostLoadingAgents
                title = "Loading Agents…"
                systemImage = "hourglass"
                message = named("Fetching the latest Agents.")
            } else {
                cause = .paneGone
                title = "Please select an agent"
                systemImage = "rectangle.on.rectangle.slash"
                message = "This Agent's pane is no longer reported. Choose another Agent from the list."
            }
        case .ended, nil:
            cause = .paneGone
            title = "Please select an agent"
            systemImage = "rectangle.on.rectangle.slash"
            message = "This Agent's pane is no longer reported. Choose another Agent from the list."
        }
    }

    /// What the Console's detail column shows when the selected Agent is not
    /// in the list.
    ///
    /// This exists to be called from a test, and deleting it would cost real
    /// coverage rather than tidy up an unused overload. The defect it guards
    /// (#146) is *which collections the view reads*, not what the rule does
    /// with them, and that could not be reached: a hosted `NavigationSplitView`
    /// builds its columns and navigation bar but never the SwiftUI content
    /// inside them, so the detail column cannot be rendered in a test and
    /// asserted against (measured under #152).
    ///
    /// Taking the stores instead of their contents is what makes the seam
    /// worth having. The reader is now written once, here, where a test calls
    /// exactly what the view calls — rather than at a call site that no test
    /// can reach.
    @MainActor
    init(agentID: ConsoleAgent.ID, console: ConsoleStore, hosts: HostStore) {
        self.init(
            agentID: agentID,
            hostStatuses: console.hostStatuses,
            hosts: hosts.hosts,
            hostsAwaitingSnapshot: console.hostsAwaitingSnapshot,
            hostStandingFailures: console.hostStandingFailures)
    }

    /// What an open Agent detail says about its Host while its attach waits
    /// for the Host to verify the row, or nil when the plain Connecting
    /// loader should stand: the Host is verified, or it is still inside its
    /// reconnect grace. A failure the user must act on speaks at once. A
    /// suspended Host is connecting here: suspension evicts every on-stage
    /// attach (`AgentTerminalCache.suspend()`), so one only meets
    /// `.suspended` on a return's activation edge, before
    /// `ConsoleStore.activate` resumes the Host.
    static func attachHostCondition(
        agentID: ConsoleAgent.ID,
        hostStatuses: [Host.ID: EventsSessionStatus],
        hosts: [Host],
        hostsAwaitingSnapshot: Set<Host.ID>,
        hostStandingFailures: [Host.ID: TransportError],
        hostsWithinReconnectGrace: Set<Host.ID>
    ) -> MissingAgentPresentation? {
        let presentation = MissingAgentPresentation(
            agentID: agentID, hostStatuses: hostStatuses, hosts: hosts,
            hostsAwaitingSnapshot: hostsAwaitingSnapshot,
            hostStandingFailures: hostStandingFailures)
        switch presentation.cause {
        case .paneGone, .hostSuspended:
            return nil
        case .hostFailed, .hostDisabled:
            return presentation
        case .hostConnecting, .hostReconnecting, .hostLoadingAgents:
            return hostsWithinReconnectGrace.contains(agentID.hostID) ? nil : presentation
        }
    }

    @MainActor
    static func attachHostCondition(
        agentID: ConsoleAgent.ID, console: ConsoleStore, hosts: [Host]
    ) -> MissingAgentPresentation? {
        attachHostCondition(
            agentID: agentID,
            hostStatuses: console.hostStatuses,
            hosts: hosts,
            hostsAwaitingSnapshot: console.hostsAwaitingSnapshot,
            hostStandingFailures: console.hostStandingFailures,
            hostsWithinReconnectGrace: console.hostsWithinReconnectGrace)
    }
}

/// Selection Mode's List: an iPad hardware keyboard's arrows move focus
/// without selecting, so they never check rows they pass, while a tap,
/// Return or VoiceOver still check one; and no row drags out as a window.
/// Hosted in each Agent row's background, it walks up to the List's
/// collection view. Every row tuning one collection view shares a claim:
/// the first claim saves its values, the last release restores them exactly,
/// so the normal List's arrows select as before.
private struct ConsoleListSelectionModeTuner: UIViewRepresentable {
    let isSelecting: Bool

    func makeUIView(context: Context) -> TunerView {
        let view = TunerView()
        view.isHidden = true
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: TunerView, context: Context) {
        uiView.isSelecting = isSelecting
        uiView.apply()
    }

    static func dismantleUIView(_ uiView: TunerView, coordinator: ()) {
        uiView.release()
    }

    @MainActor
    private enum Registry {
        struct Entry {
            weak var collectionView: UICollectionView?
            let selectionFollowsFocus: Bool
            let dragInteractionEnabled: Bool
            var claimants: Set<ObjectIdentifier>
        }

        static var entries: [ObjectIdentifier: Entry] = [:]

        static func claim(_ collectionView: UICollectionView, by tuner: TunerView) {
            let key = ObjectIdentifier(collectionView)
            if var entry = entries[key], entry.collectionView === collectionView {
                entry.claimants.insert(ObjectIdentifier(tuner))
                entries[key] = entry
            } else {
                entries[key] = Entry(
                    collectionView: collectionView,
                    selectionFollowsFocus: collectionView.selectionFollowsFocus,
                    dragInteractionEnabled: collectionView.dragInteractionEnabled,
                    claimants: [ObjectIdentifier(tuner)])
            }
            collectionView.selectionFollowsFocus = false
            collectionView.dragInteractionEnabled = false
        }

        static func release(_ collectionView: UICollectionView, by tuner: TunerView) {
            let key = ObjectIdentifier(collectionView)
            guard var entry = entries[key] else { return }
            entry.claimants.remove(ObjectIdentifier(tuner))
            guard entry.claimants.isEmpty else {
                entries[key] = entry
                return
            }
            entries[key] = nil
            if let saved = entry.collectionView, saved === collectionView {
                saved.selectionFollowsFocus = entry.selectionFollowsFocus
                saved.dragInteractionEnabled = entry.dragInteractionEnabled
            }
        }
    }

    final class TunerView: UIView {
        var isSelecting = false {
            didSet {
                guard isSelecting != oldValue else { return }
                apply()
            }
        }
        /// The collection view this view currently claims, if any.
        private weak var claimed: UICollectionView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func release() {
            guard let collectionView = claimed else { return }
            claimed = nil
            Registry.release(collectionView, by: self)
        }

        func apply() {
            guard isSelecting, window != nil, let collectionView = enclosingCollectionView() else {
                release()
                return
            }
            if claimed === collectionView { return }
            release()
            claimed = collectionView
            Registry.claim(collectionView, by: self)
        }

        private func enclosingCollectionView() -> UICollectionView? {
            var node = superview
            while let view = node {
                if let collectionView = view as? UICollectionView { return collectionView }
                node = view.superview
            }
            return nil
        }
    }
}

/// Clears the UIKit focus halo, a sharp rectangle, on the List cell hosting
/// the selected Agent row, which `AgentCardChrome` already rings. Other rows
/// keep the halo because focus can sit on a row that is not selected: under
/// Full Keyboard Access selection does not follow focus, and selection-disabled
/// rows can still be focused. SwiftUI's `focusEffectDisabled` does not reach
/// the cell's halo (seen on iOS 27).
/// A cleared cell gets the default system effect back rather than a saved
/// one: the default resolves its shape from the cell's bounds each time focus
/// lands, while a saved effect keeps the bounds it was read at.
private struct ListCellFocusHaloRemover: UIViewRepresentable {
    var isSelected: Bool

    func makeUIView(context: Context) -> HaloRemovingView {
        let view = HaloRemovingView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: HaloRemovingView, context: Context) {
        uiView.isSelected = isSelected
    }

    static func dismantleUIView(_ uiView: HaloRemovingView, coordinator: ()) {
        uiView.restoreHalo()
    }

    final class HaloRemovingView: UIView {
        /// The cell this view cleared, if any.
        private weak var clearedCell: UICollectionViewCell?

        var isSelected = false {
            didSet {
                if isSelected != oldValue { apply() }
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        private func apply() {
            guard isSelected, window != nil else {
                restoreHalo()
                return
            }
            var view = superview
            while let current = view, !(current is UICollectionViewCell) {
                view = current.superview
            }
            let cell = view as? UICollectionViewCell
            if cell !== clearedCell {
                restoreHalo()
            }
            cell?.focusEffect = nil
            clearedCell = cell
        }

        func restoreHalo() {
            clearedCell?.focusEffect = UIFocusEffect()
            clearedCell = nil
        }
    }
}

/// A row a sent swiped Close took (`ConsoleStore.departingRows`): inert
/// while it leaves (`SwipeToCloseRow` keeps it from selection and VoiceOver;
/// here it drops touches). Lifted, the card rises out of its place as it
/// shrinks and fades. That is drawn only: a List row does not animate its own
/// height, so the row keeps its height until the List deletes it and glides
/// the rows below up into its place. Without `rises` (Reduce Motion) the card
/// only fades.
private struct DepartingRowLift: ViewModifier {
    let isDeparting: Bool
    let isLifted: Bool
    let rises: Bool

    func body(content: Content) -> some View {
        let rising = isLifted && rises
        return content
            .scaleEffect(rising ? 0.96 : 1, anchor: .top)
            .offset(y: rising ? -36 : 0)
            .opacity(isLifted ? 0 : 1)
            .allowsHitTesting(!isDeparting)
    }
}

/// The Console's bottom bar: scope on the left (Host then Workspace, always
/// shown so the bar keeps its five places whatever the Host count, and
/// disabled while there is no Host), New Agent as the outlined accent circle
/// in the middle, and Hosts and Settings on the right. Host and Workspace
/// labels name the current choice and turn the accent colour while one is
/// chosen; their menus list choices alphabetically.
private struct ConsoleBottomBar: View {
    let hosts: [Host]
    /// Each connected Host's transport, shown beside its name in the menu.
    let moshStates: [Host.ID: ConsoleStore.MoshHostCapsuleState]
    @Binding var hostSelection: Host.ID?
    let workspaceOptions: [ConsoleWorkspaceOption]
    /// Entries the menu marks `tmux` (dual-backend Hosts only).
    let tmuxWorkspaceOptionIDs: Set<ConsoleWorkspaceOption.ID>
    let zellijWorkspaceOptionIDs: Set<ConsoleWorkspaceOption.ID>
    @Binding var workspaceSelection: ConsoleWorkspaceOption.ID
    let newAgent: () -> Void
    let showHosts: () -> Void
    let showSettings: () -> Void

    /// The bottom margin the pinned bar reserves in the list's scroll
    /// content, so the last row scrolls clear of the overlay-pinned bar:
    /// the bar's own height at the default text size (top padding 7, the
    /// 44pt row, bottom padding 5); the column measures the real height.
    static let pinnedContentInset: CGFloat = 56

    private var hostTitle: String {
        hosts.first(where: { $0.id == hostSelection })?.displayName ?? "All Hosts"
    }

    private var workspaceTitle: String {
        guard workspaceSelection != .all else { return "Workspaces" }
        return workspaceOptions.first(where: { $0.id == workspaceSelection })?.title
            ?? "Workspaces"
    }

    /// Menu order: alphabetical by name (the list's own order is untouched).
    private var sortedHosts: [Host] {
        hosts.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// "All Workspaces" first, then the Workspaces alphabetically.
    private var sortedWorkspaceOptions: [ConsoleWorkspaceOption] {
        let all = workspaceOptions.filter { $0.id == .all }
        let rest = workspaceOptions.filter { $0.id != .all }.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        return all + rest
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            ConsoleBarMenu(
                accessibilityLabel: "Host",
                title: hostTitle,
                systemImage: "desktopcomputer",
                isActive: hostSelection != nil
            ) {
                Picker("Host", selection: $hostSelection) {
                    Text("All Hosts").tag(Host.ID?.none)
                    ForEach(sortedHosts) { host in
                        Text(hostMenuTitle(host)).tag(Host.ID?.some(host.id))
                    }
                }
            }
            .disabled(hosts.isEmpty)
            .frame(maxWidth: .infinity)
            ConsoleBarMenu(
                accessibilityLabel: "Workspace",
                title: workspaceTitle,
                systemImage: "square.stack.3d.up",
                isActive: workspaceSelection != .all
            ) {
                Picker("Workspace", selection: $workspaceSelection) {
                    ForEach(sortedWorkspaceOptions) { option in
                        Text(ConsoleWorkspaceMenuTitle.text(
                            option, isTmux: tmuxWorkspaceOptionIDs.contains(option.id),
                            isZellij: zellijWorkspaceOptionIDs.contains(option.id)))
                            .tag(option.id)
                    }
                }
            }
            .disabled(hosts.isEmpty)
            .frame(maxWidth: .infinity)
            Button(action: newAgent) {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 39, height: 39)
                    .overlay {
                        // An outlined circle, not a filled one: the bar stays
                        // quiet and the row keeps its 44pt height, so the
                        // bar carries no strip of empty material below the
                        // captions.
                        Circle()
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                    // The ring draws at 39pt; the hit target stays 44pt.
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .hoverEffect(.lift)
            .disabled(hosts.isEmpty)
            .opacity(hosts.isEmpty ? 0.4 : 1)
            .accessibilityLabel("New Agent")
            .frame(maxWidth: .infinity)
            Button(action: showHosts) {
                ConsoleBarItemLabel(title: "Hosts", systemImage: "server.rack", isActive: false)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .frame(maxWidth: .infinity)
            Button(action: showSettings) {
                ConsoleBarItemLabel(title: "Settings", systemImage: "gearshape", isActive: false)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .frame(maxWidth: .infinity)
        }
        .modifier(ConsoleBarChrome())
    }

    /// "studio · MOSH" / "studio · SSH"; the bare name while disconnected.
    private func hostMenuTitle(_ host: Host) -> String {
        guard let state = moshStates[host.id] else { return host.displayName }
        return "\(host.displayName) · \(state.transportLabel)"
    }
}

/// The bottom bar's surface, shared by the Console's bar and Selection
/// Mode's: the 44pt row padded to `ConsoleBottomBar.pinnedContentInset`,
/// on bar material under a hairline.
private struct ConsoleBarChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 5)
            .background(.bar)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(uiColor: .separator))
                    .frame(height: 0.5)
            }
    }
}

/// The Console Workspace menu's entry text.
enum ConsoleWorkspaceMenuTitle {
    /// "proj (2)"; a tmux-owned entry on a dual-backend Host reads
    /// "proj (2) · tmux".
    static func text(_ option: ConsoleWorkspaceOption, isTmux: Bool, isZellij: Bool = false) -> String {
        let title = "\(option.title) (\(option.agents.count))"
        if isZellij { return "\(title) · Zellij" }
        return isTmux ? "\(title) · \(HostBackend.tmux.displayName)" : title
    }
}

/// A bottom-bar item that opens a menu (Host, Workspace). The menu sits over
/// the item with an invisible label: a Liquid Glass menu morphs out of its
/// label, hides it while open, and when the label changes as the menu
/// closes (a pick renames and recolours it) can leave it blank for a second
/// or so. The visible item is never the menu's label, so a pick cannot
/// blank it. The hover effect wraps the drawn item; the Menu's own is off.
private struct ConsoleBarMenu<MenuContent: View>: View {
    let accessibilityLabel: String
    let title: String
    let systemImage: String
    let isActive: Bool
    @ViewBuilder let content: MenuContent

    var body: some View {
        ConsoleBarItemLabel(title: title, systemImage: systemImage, isActive: isActive)
            .accessibilityHidden(true)
            .overlay {
                Menu {
                    content
                } label: {
                    Color.clear.contentShape(Rectangle())
                }
                .hoverEffectDisabled()
                .accessibilityLabel(accessibilityLabel)
                .accessibilityValue(title)
            }
            .hoverEffect(.highlight)
    }
}

/// One bottom-bar item: an icon over a short caption, 44pt or taller so it
/// is easy to hit. An active scope (a chosen Host or Workspace) reads in the
/// accent colour. A disabled item (the Host and Workspace menus while there
/// is no Host) fades like the New Agent circle.
/// It carries no hover effect: the control around it adds
/// `.hoverEffect(.highlight)`, and `ConsoleBarMenu` wraps its drawn copy.
private struct ConsoleBarItemLabel: View {
    let title: String
    let systemImage: String
    let isActive: Bool

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .frame(height: 24)
            Text(title)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
        // Neither a plain view nor a Menu's custom label dims when
        // disabled, so fade it the way the New Agent circle fades.
        .opacity(isEnabled ? 1 : 0.4)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }
}

/// Selection Mode's stand-in for the bottom bar: Pin or Unpin, Mark Read or
/// Mark Unread, Move, and Close, every item in the bar's own gray. An item
/// that applies to none of the checked Agents is disabled. Move works
/// within one Host: across Hosts it stays tappable but dimmed, and a tap
/// says why.
private struct ConsoleSelectionActionBar: View {
    let pinAction: ConsoleBulkPinAction?
    let readAction: ConsoleBulkReadAction?
    let moveAvailability: ConsoleBulkMoveAvailability
    /// The Workspaces a one-Host selection can move into.
    let moveTargets: [ConsoleWorkspace]
    let closeCount: Int
    let pin: (ConsoleBulkPinAction) -> Void
    let mark: (ConsoleBulkReadAction) -> Void
    let move: (ConsoleWorkspace) -> Void
    let close: () -> Void

    @State private var isExplainingMove = false

    private static let moveReason = "Move works within one Host."

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Button {
                if let pinAction { pin(pinAction) }
            } label: {
                ConsoleBarItemLabel(
                    title: pinAction == .unpin ? "Unpin" : "Pin",
                    systemImage: pinAction == .unpin ? "pin.slash" : "pin",
                    isActive: false)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .disabled(pinAction == nil)
            .frame(maxWidth: .infinity)
            Button {
                if let readAction { mark(readAction) }
            } label: {
                ConsoleBarItemLabel(
                    title: readAction == .markRead ? "Mark Read" : "Mark Unread",
                    systemImage: readAction == .markRead ? "envelope.open" : "envelope.badge",
                    isActive: false)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .disabled(readAction == nil)
            .frame(maxWidth: .infinity)
            moveItem
                .frame(maxWidth: .infinity)
            Button(action: close) {
                ConsoleBarItemLabel(
                    title: closeCount > 0 ? "Close \(closeCount)" : "Close",
                    systemImage: "trash",
                    isActive: false)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .disabled(closeCount == 0)
            .accessibilityLabel(closeCount == 1 ? "Close 1 Agent" : "Close \(closeCount) Agents")
            .frame(maxWidth: .infinity)
        }
        .modifier(ConsoleBarChrome())
    }

    @ViewBuilder
    private var moveItem: some View {
        switch moveAvailability {
        case .spansHosts(let hostNames):
            let detail = ConsoleBulkActions.spansHostsMessage(hostNames: hostNames)
            Button { isExplainingMove = true } label: {
                // Faded like a disabled item, but a tap still explains.
                moveLabel
                    .opacity(0.4)
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .help(Self.moveReason)
            .accessibilityLabel("Move to Workspace")
            .accessibilityHint("\(Self.moveReason) \(detail)")
            .popover(isPresented: $isExplainingMove) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.moveReason)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280, alignment: .leading)
                .padding()
                // A popover on iPhone too, not a sheet.
                .presentationCompactAdaptation(.popover)
            }
        case .available, .unavailable:
            Menu {
                ForEach(moveTargets) { workspace in
                    Button(workspace.label) { move(workspace) }
                }
            } label: {
                moveLabel
            }
            .hoverEffect(.highlight)
            .disabled(moveTargets.isEmpty)
            .accessibilityLabel("Move to Workspace")
        }
    }

    private var moveLabel: some View {
        ConsoleBarItemLabel(title: "Move…", systemImage: "folder", isActive: false)
    }
}

/// Selection Mode's checkbox beside a card: a gray ring, or once checked a
/// filled disc with a checkmark. Neutral, never the accent: the brand's
/// paper disc with an ink mark in dark mode, the inverse in light mode, so
/// it reads on either backdrop.
private struct SelectionCheckbox: View {
    let isChecked: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if isChecked {
                Circle()
                    .fill(colorScheme == .dark ? Brand.Colors.paper : Brand.Colors.ink)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(colorScheme == .dark ? Brand.Colors.ink : Brand.Colors.paper)
            } else {
                Circle()
                    .strokeBorder(Color(uiColor: .secondaryLabel), lineWidth: 1.5)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

/// The horizontally scrolling filter pills: All, Chat, Needs Attention,
/// Blocked, Done, Working, each with its count in the current Host and
/// Workspace scope and, for a status, a dot in that status's colour; Chat
/// leads with a chat bubble instead. The Closed chip follows them,
/// styled like a pill and counting the Closed Sessions in scope; selecting
/// it lists only those, and tapping it again returns to All. Always offered,
/// even at zero, so the filter never disappears from the bar.
private struct ConsoleStatusPillBar: View {
    let counts: [ConsoleStatusFilter: Int]
    let selection: ConsoleStatusFilter
    let onSelect: (ConsoleStatusFilter) -> Void
    let closedCount: Int

    /// Scrolled off its resting position, so pills are passing out of view
    /// at the leading edge.
    @State private var isScrolled = false

    private var showsClosed: Bool { selection == .closed }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ConsoleStatusFilter.statusPills) { filter in
                    pillButton(filter)
                }
                closedChip
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.x > 0 } action: {
            isScrolled = $1
        }
        // Pills scrolled past the leading edge fade out there instead of
        // running on around the search icon and into the column's margin.
        // Only that edge clips: the trailing pills still run on to the
        // column's edge, where the header clips them.
        .mask(alignment: .leading) {
            HStack(spacing: 0) {
                LinearGradient(
                    colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: isScrolled ? 24 : 0)
                Color.black
            }
            .padding(.trailing, -40)
            .padding(.vertical, -8)
        }
    }

    private func pillButton(_ filter: ConsoleStatusFilter) -> some View {
        let isSelected = filter == selection
        let count = counts[filter] ?? 0
        return Button { onSelect(filter) } label: {
            pillLabel(filter.title, count: count, isSelected: isSelected) {
                if let status = filter.dotStatus {
                    Circle()
                        .fill(Color(status.inkUIColor))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                } else if filter == .chat {
                    Image(systemName: "bubble.left.fill")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel(filter.title)
        .accessibilityValue(count == 1 ? "1 Agent" : "\(count) Agents")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var closedChip: some View {
        Button { onSelect(showsClosed ? .all : .closed) } label: {
            pillLabel("Closed", count: closedCount, isSelected: showsClosed) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .accessibilityLabel("Closed")
        .accessibilityValue(closedCount == 1 ? "1 Session" : "\(closedCount) Sessions")
        .accessibilityAddTraits(showsClosed ? .isSelected : [])
    }

    private func pillLabel(
        _ title: String, count: Int, isSelected: Bool,
        @ViewBuilder leading: () -> some View
    ) -> some View {
        HStack(spacing: 6) {
            leading()
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(count, format: .number)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .opacity(0.6)
        }
        .foregroundStyle(isSelected ? Color(uiColor: .systemBackground) : Color.primary)
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(
            isSelected ? Color.primary : Color(uiColor: .secondarySystemGroupedBackground),
            in: Capsule())
        .contentShape(Capsule())
    }
}

/// The two ways a selected Agent detail can be on stage. A window whose Host
/// channel is live in another window still shows its detail, so that detail's
/// presentations keep covering the window's keyboard commands, while its
/// Attach stays off stage until the window holds the channel again.
struct AgentDetailStage {
    /// The detail is the window's selected, still-listed Agent.
    let isVisible: () -> Bool
    let terminalAccess: () -> HostTerminalAccess

    /// A linked terminal leaves independently of its thread's detail.
    func linkedTerminal(
        _ pane: ConsoleAgent, isPresented: @escaping () -> Bool,
        current: @escaping () -> ConsoleAgent?
    ) -> AgentDetailStage {
        let identity = AgentDetailIdentity(pane)
        return AgentDetailStage(isVisible: {
            isVisible() && isPresented() && current().map(AgentDetailIdentity.init) == identity
        }, terminalAccess: terminalAccess)
    }

    /// Attach start, resize and rejoin: visible and holding the Host's channel.
    func isOnStage() -> Bool {
        isVisible() && terminalAccess() == .holds
    }
}

/// The detail column's view identity: the selected row, and whether it is a
/// shell. The row keeps its identity when its shell starts an Agent, but the
/// detail's Composer, Attach target and Agent-only actions do not carry over.
/// It also rebuilds when the row's terminal changes under the same pane — a
/// verified snapshot replacing a last-known row, or herdr reusing the pane
/// id: the terminal cache evicts the old terminal's entry, and only a fresh
/// detail acquires one for the new terminal.
struct AgentDetailIdentity: Hashable {
    let agentID: ConsoleAgent.ID
    let attachTarget: TerminalAttachTarget
    let terminalID: String

    init(_ agent: ConsoleAgent) {
        agentID = agent.id
        attachTarget = agent.attachTarget
        terminalID = agent.agent.terminalID
    }
}

/// Start Session (design §2 scenario 8) per Host: one start in flight at a
/// time, and the last failure's text, cleared when the next start begins
/// or the sessionless state goes away.
@MainActor
@Observable
final class TmuxSessionStarter {
    private var starting: Set<Host.ID> = []
    private var errors: [Host.ID: String] = [:]

    func isStarting(on hostID: Host.ID) -> Bool {
        starting.contains(hostID)
    }

    func error(on hostID: Host.ID) -> String? {
        errors[hostID]
    }

    /// Runs `start` unless one is in flight for the Host; its failure's
    /// text replaces the Host's error.
    func start(
        on hostID: Host.ID, _ start: @MainActor (Host.ID) async throws -> Void
    ) async {
        guard starting.insert(hostID).inserted else { return }
        errors[hostID] = nil
        defer { starting.remove(hostID) }
        do {
            try await start(hostID)
        } catch {
            errors[hostID] = error.localizedDescription
        }
    }

    func dismissError(on hostID: Host.ID) {
        errors[hostID] = nil
    }
}

/// One presentation of the Console's New Agent sheet. Each value has its
/// own identity, so a New Chat over an open sheet presents a fresh one.
private struct StartAgentSheet: Identifiable {
    let id = UUID()
    /// Set for a New Chat quick action.
    let quickChat: NewChatPreferences?
    /// Prefills the sheet (Help's Ask an Agent, the Keychain Fix); nil otherwise.
    var preset: AgentLaunchPreset? = nil
}
