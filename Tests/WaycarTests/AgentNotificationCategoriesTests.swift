import Foundation
import Testing
import UserNotifications

@testable import Waycar

/// The Agent Notification categories (#193): the action shape the iPhone
/// registers, the status → category mapping, the plaintext ids the watch
/// routes by, and the extension's decoration, which tags only decrypted
/// pushes.
@Suite("Agent notification categories")
struct AgentNotificationCategoriesTests {
    private static let vectors = NotificationVectorFile.shared

    private static func category(
        _ identifier: String, in categories: Set<UNNotificationCategory>
    ) throws -> UNNotificationCategory {
        try #require(categories.first { $0.identifier == identifier })
    }

    // MARK: - Categories

    @Test func voiceReplyOnWatchMakesEveryActionOpenTheWatchApp() throws {
        let categories = AgentNotificationCategories.categories(voiceReplyOnWatch: true)
        #expect(Set(categories.map(\.identifier)) == ["waycar.agent.done", "waycar.agent.blocked"])

        let done = try Self.category("waycar.agent.done", in: categories)
        #expect(done.actions.map(\.identifier) == ["waycar.reply", "waycar.open"])
        #expect(done.actions.allSatisfy { $0.options == [.foreground] })
        #expect(!done.actions.contains { $0 is UNTextInputNotificationAction })

        let blocked = try Self.category("waycar.agent.blocked", in: categories)
        #expect(blocked.actions.map(\.identifier) == ["waycar.review"])
        #expect(blocked.actions.allSatisfy { $0.options == [.foreground] })
    }

    /// Without iPhone transcription Reply becomes the system text input,
    /// answered on the iPhone in the background and only once unlocked;
    /// Open and Review keep opening the watch app.
    @Test func withoutVoiceReplyReplyIsABackgroundTextInput() throws {
        let categories = AgentNotificationCategories.categories(voiceReplyOnWatch: false)
        let done = try Self.category("waycar.agent.done", in: categories)
        #expect(done.actions.map(\.identifier) == ["waycar.reply.text", "waycar.open"])

        let reply = try #require(done.actions.first as? UNTextInputNotificationAction)
        #expect(reply.options == [.authenticationRequired])
        #expect(done.actions.last?.options == [.foreground])

        let blocked = try Self.category("waycar.agent.blocked", in: categories)
        #expect(blocked.actions.map(\.identifier) == ["waycar.review"])
    }

    @Test func onlyDoneAndBlockedHaveACategory() {
        #expect(AgentNotificationCategories.category(forStatus: "done") == "waycar.agent.done")
        #expect(AgentNotificationCategories.category(forStatus: "blocked") == "waycar.agent.blocked")
        for status in ["working", "idle", "unknown", "Done", ""] {
            #expect(AgentNotificationCategories.category(forStatus: status) == nil)
        }
    }

    // MARK: - Plaintext target

    @Test func targetRoundTripsThroughDecoratedUserInfo() throws {
        let hostID = UUID()
        let content = UNMutableNotificationContent()
        AgentNotificationCategories.decorate(
            content, agent: (hostID: hostID, paneID: "w1:p2", status: "done"))

        let target = try #require(AgentNotificationCategories.target(from: content.userInfo))
        #expect(target.hostID == hostID)
        #expect(target.paneID == "w1:p2")
    }

    @Test func targetRejectsMissingOrMalformedIds() {
        let host = UUID().uuidString
        let garbage: [[AnyHashable: Any]] = [
            [:],
            ["waycarHostID": host],
            ["waycarPaneID": "w1:p1"],
            ["waycarHostID": "not-a-uuid", "waycarPaneID": "w1:p1"],
            ["waycarHostID": host, "waycarPaneID": ""],
            ["waycarHostID": 42, "waycarPaneID": "w1:p1"],
            ["waycarHostID": host, "waycarPaneID": ["w1:p1"]],
        ]
        for userInfo in garbage {
            #expect(AgentNotificationCategories.target(from: userInfo) == nil)
        }
    }

    // MARK: - Extension rewrite

    /// The extension's real path over a valid vector: the decrypted copy,
    /// its category and ids, the badge, and the fields it arrived with.
    @Test func decryptedPushIsRenderedTaggedAndBadged() throws {
        let vector = try #require(Self.vectors.valid.first { $0.name == "blocked claude agent" })
        let key = try #require(Data(base64URLEncoded: vector.key))
        let hostID = UUID()
        let record = NotificationKeyRecord(hostID: hostID, hostName: "mac-studio", key: key)
        let raw = UNMutableNotificationContent()
        raw.subtitle = "relay wrap"
        raw.userInfo = ["envelope": vector.envelope]
        var badgedHost: UUID?

        let content = AgentNotificationRewriter.rewritten(raw, keys: [record]) { _, host in
            badgedHost = host
            return 3
        }

        let payload = try #require(
            NotificationEnvelope.open(userInfo: raw.userInfo, keys: [record])?.payload)
        let alert = AgentNotificationRenderer.alert(for: payload)
        #expect(content.title == alert.title)
        #expect(content.body == alert.body)
        #expect(content.subtitle == "")
        #expect(content.categoryIdentifier == "waycar.agent.blocked")
        #expect(content.userInfo["envelope"] as? String == vector.envelope)
        #expect(content.userInfo["waycarHostID"] as? String == hostID.uuidString)
        #expect(content.userInfo["waycarPaneID"] as? String == vector.payload.paneId)
        #expect(content.userInfo.count == 3)
        #expect(content.badge == 3)
        #expect(badgedHost == hostID)
    }

    /// A raw push that does not decrypt gets the fallback copy, no actions,
    /// no Agent and no badge, even when it arrived carrying forged ids and a
    /// category.
    @Test func forgedIdsOnAnUndecryptablePushAreStripped() throws {
        let vector = try #require(Self.vectors.valid.first { $0.name == "blocked claude agent" })
        let raw = UNMutableNotificationContent()
        raw.title = "Forged"
        raw.categoryIdentifier = "waycar.agent.done"
        raw.userInfo = [
            "envelope": vector.envelope,
            "waycarHostID": UUID().uuidString,
            "waycarPaneID": "w1:p1",
        ]
        var badged = false

        // No key on this device opens the envelope.
        let content = AgentNotificationRewriter.rewritten(raw, keys: []) { _, _ in
            badged = true
            return 1
        }

        let fallback = AgentNotificationRenderer.alert(for: nil)
        #expect(content.title == fallback.title)
        #expect(content.body == fallback.body)
        #expect(content.categoryIdentifier == "")
        #expect(AgentNotificationCategories.target(from: content.userInfo) == nil)
        #expect(content.userInfo.count == 1)
        #expect(content.badge == nil)
        #expect(!badged)
    }

    @Test func decryptedStatusWithoutActionsGetsIdsButNoCategory() {
        let content = UNMutableNotificationContent()
        AgentNotificationCategories.decorate(
            content, agent: (hostID: UUID(), paneID: "w1:p1", status: "working"))

        #expect(content.categoryIdentifier == "")
        #expect(AgentNotificationCategories.target(from: content.userInfo) != nil)
    }
}
