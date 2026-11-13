import UserNotifications

/// The Notification Service Extension shell (ADR 0008). iOS hands every
/// `mutable-content` push through here before display; all real work — kid
/// key selection, envelope decryption, alert phrasing — is the pure
/// `AgentNotificationRenderer.alert` over the Notification Keys in the
/// shared-access-group Keychain, compiled from WaycarNotificationCore and
/// covered by the app test suite against the shared vectors. Undecryptable
/// pushes get the generic fallback copy applied unconditionally, so garbage
/// input never renders as-is and never crashes the extension.
///
/// A decrypted push that carries its Host's attention count also updates
/// the Attention Badge: the count replaces that Host's stored share (unless
/// the Host left the catalog or the push is older than the stored count)
/// and the badge becomes the sum across Hosts. Without the count the badge
/// is left alone.
///
/// A decrypted push is also tagged with its action category (Reply / Open /
/// Review) and the plaintext Host and pane ids the watch routes by
/// (`AgentNotificationCategories.decorate`); the fallback banner gets
/// neither.
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let records = (try? NotificationKeyStore().allRecords()) ?? []
        let badgeStore = AttentionBadgeStore()
        contentHandler(
            AgentNotificationRewriter.rewritten(request.content, keys: records) {
                badgeStore.badge(after: $0, from: $1)
            })
    }

    // Everything in didReceive is synchronous, so the expiration callback
    // can never catch it mid-flight; if iOS ever cut us off anyway, the
    // system falls back to the relay's generic wrap copy, which is the same
    // banner our own fallback shows.
    override func serviceExtensionTimeWillExpire() {}
}
