import Foundation
import UserNotifications

// MARK: - Deep links

/// Where Live Activity links and notification actions land on the watch.
/// Pure: the app and the notification delegate only apply the routes.
enum WatchDeepLink {
    /// The routes for a `waycar://agent/<host>[/<pane>]` link: an Agent
    /// opens its detail, a Host-only link (Live Activity chrome) the root
    /// list. Nil for anything that is not a Waycar Agent link.
    static func routes(for url: URL) -> [WatchStore.Route]? {
        guard let target = AgentActivityLink.target(from: url) else { return nil }
        guard let paneID = target.paneID else { return [] }
        return [.agent(WatchAgentID(hostID: target.hostID, paneID: paneID))]
    }

    /// The Agent a notification is about, from the plaintext ids the
    /// iPhone's notification extension writes; nil when they are missing.
    static func agentID(from userInfo: [AnyHashable: Any]) -> WatchAgentID? {
        AgentNotificationCategories.target(from: userInfo).map {
            WatchAgentID(hostID: $0.hostID, paneID: $0.paneID)
        }
    }

    /// The routes for a notification response: Reply opens the recorder
    /// over the Agent's detail when `canRecord`, otherwise the detail alone
    /// (a message is in flight, or the iPhone can't transcribe); Open or a
    /// tap opens the detail, and a tap on a Blocked notification or Review
    /// the Blocked prompt. A missing `agentID` opens the root list (design
    /// §4 N1). Nil when the response should not navigate (dismissal,
    /// unknown actions).
    static func routes(
        forAction actionIdentifier: String, category: String, agentID: WatchAgentID?, canRecord: Bool
    ) -> [WatchStore.Route]? {
        switch actionIdentifier {
        case AgentNotificationCategories.replyAction:
            guard let agentID else { return [] }
            return canRecord ? [.agent(agentID), .recorder(agentID)] : [.agent(agentID)]
        case UNNotificationDefaultActionIdentifier where category == AgentNotificationCategories.blocked,
            AgentNotificationCategories.reviewAction:
            return agentID.map { [.blocked($0)] } ?? []
        case AgentNotificationCategories.openAction, UNNotificationDefaultActionIdentifier:
            return agentID.map { [.agent($0)] } ?? []
        default:
            return nil
        }
    }
}

// MARK: - Handoff

/// Handoff from an Agent screen to the iPhone. The activity carries the same
/// `hostID`/`paneID` user info and content identifier the iPhone's
/// `AgentRoute` reads, plus the `waycar://agent/...` link; no web page URL.
enum WatchHandoff {
    /// The activity type, shared with the iPhone's `AgentRoute`.
    static let activityType = "com.otreva.waycar.agent"
    /// The Host id key `AgentRoute` reads.
    static let hostIDKey = "hostID"
    /// The pane id key `AgentRoute` reads.
    static let paneIDKey = "paneID"
    /// The deep link key (`waycar://agent/<host>/<pane>`).
    static let urlKey = "url"

    /// Fills `activity` for the Agent: use it from
    /// `.userActivity(WatchHandoff.activityType) { WatchHandoff.configure($0, for: id) }`.
    static func configure(_ activity: NSUserActivity, for agentID: WatchAgentID, title: String? = nil) {
        let host = agentID.hostID.uuidString
        var userInfo: [String: String] = [hostIDKey: host, paneIDKey: agentID.paneID]
        if let url = AgentActivityLink.agentURL(hostID: host, paneID: agentID.paneID) {
            userInfo[urlKey] = url.absoluteString
        }
        activity.title = title
        activity.userInfo = userInfo
        activity.requiredUserInfoKeys = [hostIDKey, paneIDKey]
        activity.targetContentIdentifier = "\(activityType)/\(host)/\(agentID.paneID)"
        activity.isEligibleForHandoff = true
    }
}
