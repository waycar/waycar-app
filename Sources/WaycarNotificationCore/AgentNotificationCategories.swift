import Foundation
import UserNotifications

/// The Agent Notification categories and their actions (issue #193), shared
/// by the iPhone app (registers them, routes iPhone-side responses), the
/// Notification Service Extension (tags each decrypted push), and the watch
/// app (routes Reply / Open / Review to its screens). Foundation and
/// UserNotifications only, so it compiles on iOS and watchOS alike.
///
/// Done offers Reply and Open; Blocked offers Review only: a notification
/// never carries the lossless command, so it never offers Allow.
enum AgentNotificationCategories {
    // MARK: - Identifiers

    /// Category of a decrypted Done push.
    static let done = "waycar.agent.done"
    /// Category of a decrypted Blocked push.
    static let blocked = "waycar.agent.blocked"

    /// Done: opens the watch recorder for the Agent (`.foreground`).
    static let replyAction = "waycar.reply"
    /// Done: opens the Agent's detail (`.foreground`).
    static let openAction = "waycar.open"
    /// Blocked: opens the Agent's Blocked prompt (`.foreground`).
    static let reviewAction = "waycar.review"
    /// Done, when the iPhone cannot transcribe watch audio: the system text
    /// input, delivered to the iPhone in the background and sent from there.
    static let textReplyAction = "waycar.reply.text"

    /// Plaintext `userInfo` key the extension writes: the Host's id (a random
    /// UUID minted on this device, so it reveals nothing about the Host).
    static let hostIDKey = "waycarHostID"
    /// Plaintext `userInfo` key the extension writes: the herdr pane id.
    static let paneIDKey = "waycarPaneID"

    // MARK: - Categories

    /// Every category to register. With `voiceReplyOnWatch` (the iPhone can
    /// transcribe recorded audio, iOS 26+) Reply opens the watch recorder;
    /// otherwise Reply is a system text input sent from the iPhone, which
    /// requires an unlocked device so a locked one cannot type into an Agent.
    static func categories(voiceReplyOnWatch: Bool) -> Set<UNNotificationCategory> {
        let reply: UNNotificationAction =
            voiceReplyOnWatch
            ? UNNotificationAction(identifier: replyAction, title: "Reply", options: [.foreground])
            : UNTextInputNotificationAction(
                identifier: textReplyAction, title: "Reply", options: [.authenticationRequired],
                textInputButtonTitle: "Send", textInputPlaceholder: "Message Agent")
        let open = UNNotificationAction(identifier: openAction, title: "Open", options: [.foreground])
        let review = UNNotificationAction(
            identifier: reviewAction, title: "Review", options: [.foreground])
        return [
            UNNotificationCategory(
                identifier: done, actions: [reply, open], intentIdentifiers: [], options: []),
            UNNotificationCategory(
                identifier: blocked, actions: [review], intentIdentifiers: [], options: []),
        ]
    }

    /// The category for a wire Agent Status; nil for statuses that offer no
    /// actions (anything but Done and Blocked).
    static func category(forStatus status: String) -> String? {
        switch status {
        case "done": done
        case "blocked": blocked
        default: nil
        }
    }

    // MARK: - Plaintext target

    /// The Agent a delivered notification points at, read from the plaintext
    /// ids the extension wrote. Nil when either id is missing or malformed:
    /// the caller then opens the Agents list.
    static func target(from userInfo: [AnyHashable: Any]) -> (hostID: UUID, paneID: String)? {
        guard let hostText = userInfo[hostIDKey] as? String,
            let hostID = UUID(uuidString: hostText),
            let paneID = userInfo[paneIDKey] as? String,
            !paneID.isEmpty
        else { return nil }
        return (hostID, paneID)
    }

    /// Tags decrypted content with its category and plaintext ids. `agent`
    /// is nil when the push did not decrypt; the generic fallback banner then
    /// offers no actions and names no Agent. Either way any category or ids
    /// the raw push arrived with are replaced. The ids are a navigation hint
    /// only: a relay or anyone holding the device token can still forge
    /// them on a push the extension never sees decrypt, so they may open a
    /// screen but never authorize sending — a typed reply targets only the
    /// Agent named inside a decrypted envelope.
    static func decorate(
        _ content: UNMutableNotificationContent,
        agent: (hostID: UUID, paneID: String, status: String)?
    ) {
        var userInfo = content.userInfo
        if let agent {
            content.categoryIdentifier = category(forStatus: agent.status) ?? ""
            userInfo[hostIDKey] = agent.hostID.uuidString
            userInfo[paneIDKey] = agent.paneID
        } else {
            content.categoryIdentifier = ""
            userInfo[hostIDKey] = nil
            userInfo[paneIDKey] = nil
        }
        content.userInfo = userInfo
    }
}
