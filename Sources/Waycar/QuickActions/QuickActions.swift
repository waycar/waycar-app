import Observation
import UIKit

/// A Home Screen quick action (touch and hold the app icon).
enum QuickAction: Equatable, Sendable {
    /// New Chat: start a Chat Mode Agent from Settings › Chat Mode's defaults.
    case newChat

    static let newChatType = "com.otreva.waycar.new-chat"

    init?(shortcutType: String) {
        switch shortcutType {
        case Self.newChatType: self = .newChat
        default: return nil
        }
    }
}

/// Holds the quick action the user picked until a window takes it. A cold
/// launch posts it before any window exists; a warm one while windows do.
/// Only the latest action counts.
@MainActor
@Observable
final class QuickActionCenter {
    /// The one the app delegate and scene delegate post to.
    static let shared = QuickActionCenter()

    private(set) var pending: QuickAction?

    func post(_ action: QuickAction) {
        pending = action
    }

    /// Returns the pending action once.
    func consume() -> QuickAction? {
        defer { pending = nil }
        return pending
    }
}

/// Receives quick actions picked while Waycar already runs (warm launch).
/// SwiftUI keeps its own scene handling; this class only adds the callback.
final class QuickActionSceneDelegate: UIResponder, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let action = QuickAction(shortcutType: shortcutItem.type) else {
            return completionHandler(false)
        }
        QuickActionCenter.shared.post(action)
        completionHandler(true)
    }
}
