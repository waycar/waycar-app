import SwiftUI
import UserNotifications
import WidgetKit

/// The Waycar watch app (ADR 0029, issue #193): Agents, Latest, Blocked
/// prompts, and voice messages, every read and action through the paired
/// iPhone. Launched with `-WaycarWatchDemo YES` (DEBUG), it runs on the
/// design's sample data with no phone.
@main
struct WaycarWatchApp: App {
    /// The phone-backed (or demo) state behind every screen.
    @State private var store: WatchStore
    /// The voice recorder, shared by every recorder screen.
    @State private var recorder: WatchRecorder
    /// Foreground drives refreshes, arrival haptics, and recorder cancels.
    @Environment(\.scenePhase) private var scenePhase
    /// Retained here: the notification center holds its delegate weakly.
    private let notificationDelegate: WatchNotificationDelegate

    /// Activates the phone link and sets the notification delegate before
    /// launch finishes, so a cold-launch notification action is not lost.
    /// No categories are registered: forwarded notifications use the
    /// iPhone's, which match what that iPhone can transcribe.
    init() {
        WatchRecorder.removeLeftoverRecordings()
        let store = Self.makeStore()
        _store = State(initialValue: store)
        _recorder = State(initialValue: WatchRecorder())
        notificationDelegate = WatchNotificationDelegate(
            open: { pending in store.open(pending) },
            refresh: { Task { await store.refresh() } })
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    /// The root list, with Live Activity and deep-link entry points.
    var body: some Scene {
        WindowGroup {
            WatchRootView(store: store, recorder: recorder)
                .onOpenURL(perform: openURL)
                #if DEBUG
                .task { openLaunchURLOnce() }
                #endif
                .onContinueUserActivity(NSUserActivityTypeLiveActivity) { _ in
                    store.route = []
                }
        }
        // `initial`: the store starts inactive and learns the launch phase here.
        .onChange(of: scenePhase, initial: true) { _, phase in
            switch phase {
            case .active:
                store.sceneDidBecomeActive()
            case .background:
                store.sceneDidLeaveForeground()
                recorder.interrupt()
            default:
                // A transient `.inactive` (an overlay, Control Center) keeps
                // the recording; only leaving for the background stops it.
                store.sceneDidLeaveForeground()
            }
        }
    }

    /// Routes a `waycar://` deep link; shared by `onOpenURL` and the DEBUG
    /// launch-argument hook.
    private func openURL(_ url: URL) {
        guard let routes = WatchDeepLink.routes(for: url) else { return }
        let agentID = routes.lazy.compactMap { route -> WatchAgentID? in
            if case .agent(let id) = route { id } else { nil }
        }.first
        store.open(WatchStore.PendingRoute(agentID: agentID) { _ in routes })
    }

    #if DEBUG
    /// Set once the launch URL has been applied, so a recreated root view
    /// does not re-route.
    @MainActor private static var didOpenLaunchURL = false

    /// `-WaycarWatchLaunchURL <url>` (DEBUG): feeds the URL through
    /// `openURL` once at launch, since the watchOS simulator refuses
    /// `simctl openurl` for custom schemes.
    @MainActor private func openLaunchURLOnce() {
        guard !Self.didOpenLaunchURL else { return }
        Self.didOpenLaunchURL = true
        guard let string = UserDefaults.standard.string(forKey: "WaycarWatchLaunchURL"),
              let url = URL(string: string) else { return }
        openURL(url)
    }
    #endif

    /// The demo store under `-WaycarWatchDemo YES` in DEBUG; otherwise the
    /// paired iPhone.
    private static func makeStore() -> WatchStore {
        #if DEBUG
        if WatchStore.isDemoLaunch { return WatchStore.demo() }
        #endif
        return WatchStore.live()
    }
}
