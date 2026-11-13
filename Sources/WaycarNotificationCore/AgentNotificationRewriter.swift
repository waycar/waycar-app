import Foundation
import UserNotifications

/// The Notification Service Extension's rewrite of one push (ADR 0008,
/// issue #193), pure over its inputs so the app suite can test it: open the
/// envelope with the device's Notification Keys, replace the copy with the
/// rendered alert (the generic fallback when it does not decrypt), tag it
/// with its category and plaintext ids (`AgentNotificationCategories.decorate`),
/// and set the Attention Badge the decrypted payload yields.
enum AgentNotificationRewriter {
    /// The rewritten content. `badge` folds a decrypted payload into the
    /// stored per-Host counts and returns the new badge, or nil to leave the
    /// badge alone; it is called only for a push that decrypted.
    static func rewritten(
        _ content: UNNotificationContent,
        keys: [NotificationKeyRecord],
        badge: (NotificationPayload, UUID) -> Int? = { _, _ in nil }
    ) -> UNNotificationContent {
        let opened = NotificationEnvelope.open(userInfo: content.userInfo, keys: keys)
        let alert = AgentNotificationRenderer.alert(for: opened?.payload)
        guard let rewritten = content.mutableCopy() as? UNMutableNotificationContent else {
            return content
        }
        rewritten.title = alert.title
        // Cleared, not left alone: the relay's generic wrap may have set a
        // subtitle, and the decrypted copy has no use for one.
        rewritten.subtitle = ""
        rewritten.body = alert.body
        AgentNotificationCategories.decorate(
            rewritten,
            agent: opened.map {
                (
                    hostID: $0.record.hostID, paneID: $0.payload.paneID,
                    status: $0.payload.status.rawValue
                )
            })
        if let opened, let count = badge(opened.payload, opened.record.hostID) {
            rewritten.badge = NSNumber(value: count)
        }
        return rewritten
    }
}
