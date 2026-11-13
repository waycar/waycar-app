import Foundation
import UserNotifications

/// The watch's notification delegate. Done and Blocked pushes reach the
/// watch while the iPhone is locked; Reply, Open, Review, and a tap open the
/// matching screen through `WatchDeepLink` (design §4 N1). The actions are
/// the iPhone's categories: forwarded notifications use them, so the watch
/// registers none of its own.
///
/// The system calls these on a background queue. The Agent is resolved
/// there from plaintext ids, so only Sendable values cross to the main
/// actor, and the non-Sendable completion handler is boxed to run exactly
/// once there, after the route applies.
final class WatchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    /// Opens a route, holding it until the first Watch State when needed.
    private let open: @MainActor @Sendable (WatchStore.PendingRoute) -> Void
    /// Asks the iPhone for a fresh Watch State.
    private let refresh: @MainActor @Sendable () -> Void

    /// A delegate that navigates with `open` (which decides whether Reply
    /// may record once a Watch State is present) and refreshes with
    /// `refresh`.
    init(
        open: @escaping @MainActor @Sendable (WatchStore.PendingRoute) -> Void,
        refresh: @escaping @MainActor @Sendable () -> Void
    ) {
        self.open = open
        self.refresh = refresh
    }

    /// A push while the app is in front still shows (the Watch State may lag
    /// behind it) and triggers a refresh so the list catches up.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions)
            -> Void
    ) {
        let refresh = self.refresh
        Task { @MainActor in refresh() }
        completionHandler([.banner, .list, .sound])
    }

    /// Reply → recorder over detail (detail alone when it can't record),
    /// Open or a tap → detail, Review or a tap on a Blocked notification →
    /// Blocked prompt; missing ids → the root list; dismissal → nothing.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        let action = response.actionIdentifier
        let category = content.categoryIdentifier
        let agentID = WatchDeepLink.agentID(from: content.userInfo)
        let complete = CompletionBox(completionHandler)
        let open = self.open
        Task { @MainActor in
            open(WatchStore.PendingRoute(agentID: agentID) { canRecord in
                WatchDeepLink.routes(
                    forAction: action, category: category, agentID: agentID, canRecord: canRecord)
            })
            complete.handler()
        }
    }
}

/// Carries the system's non-Sendable completion handler to the main actor,
/// where it is invoked exactly once.
private struct CompletionBox: @unchecked Sendable {
    /// The system's completion handler.
    let handler: () -> Void

    /// Boxes `handler`.
    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }
}
