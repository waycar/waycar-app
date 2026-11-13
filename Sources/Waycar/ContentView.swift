import CarPlay
import StoreKit
import SwiftUI
import UIKit

/// One window's root: the Console (#8), with Host management (#14) behind it.
///
/// The stores behind it are app-wide (`WaycarAppModel`); what a window owns
/// is its navigation. On iPad every window is a scene with its own router,
/// so two windows can show two Agents, and each restores its own Agent after
/// the app is terminated: first from its scene storage, else from the value
/// the window was opened with, else from a dragged row's user activity.
struct ContentView: View {
    let app: WaycarAppModel
    /// The `WindowGroup` value: the Agent this window was opened on, kept in
    /// step with the window's navigation so opening that Agent again finds
    /// this window.
    @Binding var windowRoute: AgentRoute?
    @State private var notificationRouter = AgentNotificationRouter()
    @State private var sceneID = UUID()
    @State private var window = WindowReference()
    #if DEBUG || WAYCAR_ADMIN
    /// Owns this window's slot in `ReviewPromptStore`'s root request.
    @State private var rootRequestToken: UUID?
    #endif
    /// A dragged row's Agent that reached this scene before it restored.
    @State private var incomingActivityRoute: AgentRoute?
    @State private var hasRestoredRoute = false
    /// Replaced once restoration knows whether this window is new.
    @State private var activation = SceneActivationTracker(isRestored: false)
    /// Per-window dismissal ownership; notes and their acknowledgement remain app-wide.
    @State private var launchSheets = LaunchSheetMachine()
    /// `AgentRoute.sceneStorageValue`; nil while the window shows the Console.
    @SceneStorage("com.otreva.waycar.agentRoute") private var storedRoute: String?
    @Environment(\.scenePhase) private var scenePhase
    /// Home Screen quick actions; the active window takes the pending one.
    var quickActions: QuickActionCenter = .shared
    /// Bumped per New Chat quick action this window takes.
    @State private var newChatRequest = 0
    /// This window's Agent screen time and natural breaks for the
    /// Notification Ask.
    @State private var agentSessions = AgentSessionClock()
    /// The break the Notification Ask is settling on; any change cancels it.
    @State private var notificationAskBreak: AgentSessionClock.Break?
    /// Apple's own rating prompt (`ReviewPromptStore`); the only way Waycar
    /// ever asks for a rating.
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        ConsoleView(
            hosts: app.hostStore, console: app.console, terminal: app.terminal,
            appearance: app.appearance,
            pluginNoticeDismissals: app.pluginNoticeDismissals,
            pushRegistration: app.pushRegistration,
            notificationPreferences: app.notificationPreferences,
            relaySettings: app.relaySettings,
            agentSummaries: app.agentSummaries,
            chatModeSettings: app.chatModeSettings,
            notificationRouter: notificationRouter,
            bannerStore: app.bannerStore,
            liveActivities: app.liveActivities,
            activity: app.activity,
            aiUsage: app.aiUsage,
            iCloudSync: app.iCloudSync,
            newChatRequest: newChatRequest
        )
        .environment(\.sceneWindow, window)
        .environment(\.agentLastFrames, app.lastFrames)
        // One plugin update per Host across every window, Host detail and
        // Chat (#209).
        .environment(\.waycarPluginUpdateActivity, app.pluginUpdateActivity)
        .environment(\.hostToolsOffer, app.hostToolsOffer)
        .environment(\.backendInstallCenter, app.backendInstall)
        .environment(
            \.agentSceneRouting,
            AgentSceneRouting(directory: app.sceneDirectory, sceneID: sceneID))
        // The one place the app's light/dark override is applied: it lands on
        // the window, so sheets, pushed screens, and the UIKit terminal
        // surfaces all resolve against the chosen appearance.
        .preferredColorScheme(app.appearance.preferredColorScheme)
        // Brand accent for Toggles, pickers and other tinted controls in the
        // main window. Sheets don't take it: each sheet with Toggles or
        // pickers sets its own. The AccentColor asset covers UIKit tint and
        // `Color.accentColor` everywhere.
        .tint(Brand.Colors.accent)
        .background {
            WindowReader { window.attach($0) }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        // Every window binds the one app-wide store, so OK in any window
        // dismisses the sheet everywhere.
        .sheet(
            isPresented: Binding(
                get: { app.whatsNew.pending != nil },
                set: { if !$0 { app.whatsNew.acknowledge() } }),
            onDismiss: {
                _ = launchSheets.handle(.dismissed(notesPending: app.whatsNew.pending != nil))
            }
        ) {
            WhatsNewSheet(builds: app.whatsNew.pending ?? []) {
                app.whatsNew.acknowledge()
            }
            .onAppear {
                _ = launchSheets.handle(.appeared(notesPending: app.whatsNew.pending != nil))
            }
        }
        .onChange(of: app.whatsNew.pending != nil, initial: true) { _, pending in
            _ = launchSheets.handle(.notesChanged(pending: pending))
        }
        // The first-launch analytics question: once per install, in one
        // window, after What's New (see `AnalyticsConsentPrompt`). Neither
        // answer is styled as the default, and only an answer closes it.
        .alert(
            AnalyticsConsentPrompt.title,
            isPresented: Binding(
                get: {
                    app.analyticsConsent.isShown(inScene: sceneID)
                        && app.whatsNew.pending == nil && launchSheets.isReadyForConsent
                },
                set: { _ in })
        ) {
            Button(AnalyticsConsentPrompt.allowTitle) {
                app.answerAnalyticsConsent(allow: true)
            }
            Button(AnalyticsConsentPrompt.declineTitle) {
                app.answerAnalyticsConsent(allow: false)
            }
            .tint(Brand.Colors.quietAction)
        } message: {
            Text(AnalyticsConsentPrompt.message)
        }
        // Every window offers to ask whenever no window is asking, so the
        // question moves on if the window that claimed it closes.
        .onChange(of: app.analyticsConsent.sceneID, initial: true) {
            app.analyticsConsent.claim(sceneID: sceneID)
        }
        // The one-time Notification Ask, at a natural break after an Agent
        // Session and never over another modal (`agentSessionDidChange`).
        // Only an answer closes it: Continue alone while the iOS prompt is
        // still to come (`NotificationAsk.actions`).
        .sheet(
            isPresented: Binding(
                get: { app.notificationAsk.isShown(inScene: sceneID) },
                set: { _ in })
        ) {
            NotificationAskSheet(
                actions: app.notificationAsk.actions,
                onTurnOn: { Task { await app.notificationAsk.turnOn() } },
                onNotNow: { app.notificationAsk.decline() })
        }
        .task(id: notificationAskBreak) {
            guard let pending = notificationAskBreak else { return }
            do { try await Task.sleep(for: pending.settle) } catch { return }
            notificationAskBreak = nil
            guard
                agentSessions.stillHolds(
                    pending, lastRouteRequest: notificationRouter.lastRouteRequest),
                notificationRouter.pendingTarget == nil,
                isFreeForNotificationAsk
            else { return }
            app.notificationAsk.present(inScene: sceneID)
        }
        // Apple's rating prompt, at a positive and idle moment: an Agent the
        // phone prompted finished while the user is on the Console or on
        // that Agent's screen (`askForReviewAtPositiveMoment`). A route
        // change (returning to the Console) or a foreground return retries.
        .task(id: reviewAskTrigger) {
            await askForReviewAtPositiveMoment()
        }
        // The admin "Request Review Sheet in 5 s" fires this same closure from
        // the store, away from the Settings sheet. Refreshed on appear and
        // cleared on disappear so it is never stale.
        #if DEBUG || WAYCAR_ADMIN
        .onAppear { rootRequestToken = app.reviewPrompt.registerRootRequest { requestReview() } }
        .onDisappear {
            if let token = rootRequestToken {
                app.reviewPrompt.unregisterRootRequest(token: token)
                rootRequestToken = nil
            }
        }
        #endif
        .onAppear {
            // Restored first, so a notification tap that launched the app
            // and is waiting for a window lands on top of it when the window
            // registers. A dragged row's Agent needs the registration to
            // route through the single-window rule, so it goes last.
            let draggedRoute = restoreRoute()
            app.sceneDirectory.register(
                sceneID: sceneID, router: notificationRouter, window: window,
                activate: { activateWindow() })
            window.observeInteraction { [directory = app.sceneDirectory, sceneID] in
                directory.sceneDidReceiveInteraction(sceneID: sceneID)
            }
            // The restored Agent is where this window's screen time starts.
            agentSessionDidChange(
                agentSessions.pathDidChange(
                    to: notificationRouter.path.last, isRetarget: false, at: .now))
            if scenePhase == .active {
                sceneDidBecomeActive()
                agentSessionDidChange(
                    agentSessions.didBecomeActive(
                        at: .now, isLaunchWindow: app.notificationAsk.isLaunchWindow(sceneID)))
            }
            takeQuickAction()
            if let draggedRoute {
                app.sceneDirectory.open(draggedRoute.target, preferredSceneID: sceneID)
            }
            app.start()
        }
        .onDisappear {
            app.sceneDirectory.unregister(sceneID: sceneID)
            app.analyticsConsent.release(sceneID: sceneID)
            app.notificationAsk.release(sceneID: sceneID)
        }
        // A foreground return is not the user choosing this window; see
        // `SceneActivationTracker`. Moving between windows arrives through
        // `observeInteraction` instead.
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                sceneDidBecomeActive()
                takeQuickAction()
                agentSessionDidChange(
                    agentSessions.didBecomeActive(
                        at: .now, isLaunchWindow: app.notificationAsk.isLaunchWindow(sceneID)))
            } else {
                notificationAskBreak = nil
                if scenePhase == .background {
                    agentSessionDidChange(agentSessions.didEnterBackground(at: .now))
                }
            }
        }
        .onChange(of: quickActions.pending) {
            takeQuickAction()
        }
        // Feeds the Console's Agent list to this window's router, so a
        // notification tap that arrived before the Hosts synced (killed-state
        // launch) routes the moment its pane appears.
        .onChange(of: app.console.agents, initial: true) {
            notificationRouter.agentsDidChange(app.console.agents)
            app.sceneDirectory.sceneRouteDidChange(sceneID: sceneID)
        }
        // Every navigation is written back, so a relaunch restores the Agent
        // this window was last on, and times the Agent screen for the
        // Notification Ask (a move's re-key is the same screen).
        .onChange(of: notificationRouter.path) { oldPath, path in
            agentSessionDidChange(
                agentSessions.pathDidChange(
                    to: path.last,
                    isRetarget: notificationRouter.isRetarget(from: oldPath.last, to: path.last),
                    at: .now))
            let route = path.last.map(AgentRoute.init(agentID:))
            storedRoute = route?.sceneStorageValue
            if windowRoute != route {
                windowRoute = route
            }
            app.sceneDirectory.sceneRouteDidChange(sceneID: sceneID)
        }
        // Live Activity row links name an Agent; surrounding chrome,
        // compact, and minimal presentations name only the Host and land on
        // the Console. Notification links share the same URL parser.
        .onOpenURL { url in
            guard let link = AgentActivityLink.target(from: url) else { return }
            app.sceneDirectory.open(
                link.paneID.map { AgentNotificationTarget(hostID: link.hostID, paneID: $0) },
                preferredSceneID: sceneID)
        }
        .onContinueUserActivity(AgentRoute.activityType) { activity in
            guard let route = AgentRoute(userActivity: activity) else { return }
            if hasRestoredRoute {
                app.sceneDirectory.open(route.target, preferredSceneID: sceneID)
            } else {
                incomingActivityRoute = route
            }
        }
        // An existing window prefers Waycar's own links, so a Live Activity
        // tap lands in a window that is already open instead of spawning
        // one. A dragged row's activity is not a `waycar://` link, so it
        // still gets the new window it was dropped to create.
        .handlesExternalEvents(
            preferring: [Self.linkEventPrefix], allowing: ["*"])
    }

    private static let linkEventPrefix = "\(AgentActivityLink.scheme)://"

    /// Counts only a newly opened window's first activation as the user
    /// working in it.
    private func sceneDidBecomeActive() {
        guard activation.sceneDidBecomeActive() else { return }
        app.sceneDirectory.sceneDidBecomeActive(sceneID: sceneID)
    }

    /// Records a finished Agent Session and settles on a new break; any
    /// other navigation drops the break waiting to settle.
    private func agentSessionDidChange(_ change: AgentSessionClock.Change) {
        if change.endedSession {
            app.notificationAsk.noteAgentSession()
        }
        if let newBreak = change.newBreak {
            notificationAskBreak = newBreak
        } else if let pending = notificationAskBreak,
            !agentSessions.stillHolds(
                pending, lastRouteRequest: notificationRouter.lastRouteRequest)
        {
            notificationAskBreak = nil
        }
    }

    /// This window is in front and nothing else is up in it: not What's
    /// New, the analytics question, or any sheet, alert, or popover the
    /// Console presents (all of which hang off the window's root
    /// controller). Read live, after the break has settled.
    private var isFreeForNotificationAsk: Bool {
        window.window?.windowScene?.activationState == .foregroundActive
            && app.whatsNew.pending == nil && launchSheets.isReadyForConsent
            && !app.analyticsConsent.isShown(inScene: sceneID)
            && window.window?.rootViewController?.presentedViewController == nil
    }

    /// Everything that decides whether a rating ask may be tried: a finished
    /// turn, where the user is, and whether the window is in front.
    private struct ReviewAskTrigger: Equatable {
        let turn: ReviewPromptStore.CompletedTurn?
        let agent: ConsoleAgent.ID?
        let isActive: Bool
        /// A blocker clearing re-runs the ask for a turn dropped while blocked.
        let isBlocked: Bool
    }

    private var reviewAskTrigger: ReviewAskTrigger {
        ReviewAskTrigger(
            turn: app.reviewPrompt.completedTurn, agent: notificationRouter.path.last,
            isActive: scenePhase == .active, isBlocked: isBlockedForReviewPrompt)
    }

    /// Hands the ask to `ReviewPromptStore`, which settles, re-checks and
    /// records it; this view only supplies where the user is.
    private func askForReviewAtPositiveMoment() async {
        await app.reviewPrompt.askIfDue(
            isActive: { scenePhase == .active },
            viewing: { notificationRouter.path.last },
            blocked: { isBlockedForReviewPrompt },
            request: { requestReview() })
    }

    /// The user is in the way of something: another modal is up in this
    /// window, CarPlay is connected (no sheet while driving; read live, so
    /// the ask still fires after disconnect), or the finished turn's Agent
    /// waits on them or its Host shows an error.
    private var isBlockedForReviewPrompt: Bool {
        app.reviewPrompt.isBlocked(
            isGloballyBlocked: !isFreeForNotificationAsk
                || UIApplication.shared.connectedScenes.contains { $0 is CPTemplateApplicationScene },
            failedHosts: Set(app.console.hostStandingFailures.keys)
                .union(app.console.hostSyncErrors.keys),
            blockedAgents: Set(
                app.console.agents.lazy.filter { !$0.isShell && $0.agent.status == .blocked }
                    .map(\.id)))
    }

    /// Only the active window takes a pending quick action, so a warm
    /// launch lands in the window the user is looking at.
    private func takeQuickAction() {
        guard scenePhase == .active, quickActions.pending != nil else { return }
        switch quickActions.consume() {
        case .newChat: newChatRequest += 1
        case nil: break
        }
    }

    /// Applies the restoration precedence once, on the window's first
    /// appearance. A stored or window-value route is placed on the path
    /// directly rather than through `open`: the Agent detail then shows the
    /// Host connecting and the Agent loading, and says so if the pane is
    /// gone, instead of quietly falling back to the Console after a grace
    /// period. A dragged row's route is returned for the caller to open once
    /// this window is registered.
    private func restoreRoute() -> AgentRoute? {
        guard !hasRestoredRoute else { return nil }
        hasRestoredRoute = true
        let incoming = incomingActivityRoute
        incomingActivityRoute = nil
        let restoration = SceneRouteRestoration.resolve(
            sceneStorage: storedRoute, windowValue: windowRoute, userActivity: incoming)
        // A window back from its own scene storage is one the system
        // restored, not one the user just opened.
        activation = SceneActivationTracker(isRestored: restoration?.source == .sceneStorage)
        guard let restoration else { return nil }
        switch restoration.source {
        case .sceneStorage, .windowValue:
            notificationRouter.path = [restoration.route.agentID]
            return nil
        case .userActivity:
            return restoration.route
        }
    }

    /// Brings this window forward when a deep link picks it. A no-op for the
    /// window the user is already in.
    private func activateWindow() {
        guard let scene = window.window?.windowScene,
            scene.activationState != .foregroundActive
        else { return }
        UIApplication.shared.activateSceneSession(
            for: UISceneSessionActivationRequest(session: scene.session),
            errorHandler: nil)
    }
}

#Preview {
    ContentView(
        app: WaycarAppModel(
            pushRegistration: PushRegistrationStore(), sceneDirectory: AgentSceneDirectory()),
        windowRoute: .constant(nil))
}
