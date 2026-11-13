import Synchronization
import UIKit

/// Whether a phone or iPad window is on screen (foreground, active or not),
/// kept where `UNUserNotificationCenter`'s callback queue can read it.
///
/// The app being foreground no longer means the user is looking at a
/// window: with the phone locked and Waycar on the car's screen, the CarPlay
/// scene keeps the process foreground and `willPresent` runs for every push
/// (docs/design/carplay.md §6). Silencing those would mute the Lock Screen
/// and the Watch for the whole drive, so the presentation decision reads the
/// windows alone. A window that is only inactive (Notification Center or
/// Control Center pulled down, a system alert, the app switcher) still
/// counts: the in-app banner announces there, as before CarPlay.
final class PhoneWindowPresence: Sendable {
    private let state = Mutex(false)

    var isOnScreen: Bool { state.withLock { $0 } }

    /// A window in this state shows the in-app banner.
    static func isOnScreen(_ activationState: UIScene.ActivationState) -> Bool {
        activationState == .foregroundActive || activationState == .foregroundInactive
    }

    /// Follows every scene's foreground edges for the life of the process
    /// (the observers stay registered with the center); call once.
    @MainActor
    func startObserving() {
        let center = NotificationCenter.default
        let edges: [(Notification.Name, Edge)] = [
            (UIScene.willEnterForegroundNotification, .entering),
            (UIScene.didActivateNotification, .settled),
            (UIScene.didEnterBackgroundNotification, .leaving),
            (UIScene.didDisconnectNotification, .leaving),
        ]
        for (name, edge) in edges {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Posted on the main queue, where the scenes live.
                nonisolated(unsafe) let note = note
                MainActor.assumeIsolated {
                    self?.update(edge, of: note.object as? UIScene)
                }
            }
        }
        update(.settled, of: nil)
    }

    private enum Edge {
        case entering, settled, leaving
    }

    /// The scene an edge names may not report its new state yet while the
    /// edge is posted, so it is counted by the edge instead.
    @MainActor
    private func update(_ edge: Edge, of edged: UIScene?) {
        let onScreen = UIApplication.shared.connectedScenes.contains { scene in
            guard scene.session.role == .windowApplication else { return false }
            guard scene === edged else { return Self.isOnScreen(scene.activationState) }
            switch edge {
            case .entering: return true
            case .leaving: return false
            case .settled: return Self.isOnScreen(scene.activationState)
            }
        }
        state.withLock { $0 = onScreen }
    }
}
