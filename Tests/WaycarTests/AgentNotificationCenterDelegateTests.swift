import Foundation
import Testing
import UserNotifications

@testable import Waycar

/// The iPhone side of a notification response (#193): the tap and the Open,
/// Review and Reply buttons deep-link to the Agent; a Reply typed into the
/// text input is sent to the Agent exactly once, or reported as not sent;
/// nothing else acts.
@MainActor
@Suite("Agent notification responses")
struct AgentNotificationCenterDelegateTests {
    private typealias Delegate = AgentNotificationCenterDelegate
    private let hostID = UUID()

    /// Records every text reply the delegate hands to the sender, and every
    /// local notification it posts.
    @MainActor
    private final class SentReplies {
        var calls: [(target: AgentNotificationTarget, text: String)] = []
        var notifications: [String] = []
    }

    private func target(_ paneID: String) -> AgentNotificationTarget {
        AgentNotificationTarget(hostID: hostID, paneID: paneID)
    }

    /// `sent` records the notifications either way; `sends` says whether
    /// a sender is wired at all.
    private func makeDelegate(
        directory: AgentSceneDirectory = AgentSceneDirectory(), sent: SentReplies = SentReplies(),
        sends: Bool = true, keys: [NotificationKeyRecord] = []
    ) -> Delegate {
        var send: (@MainActor (AgentNotificationTarget, String) async -> Void)?
        if sends {
            send = { target, text in sent.calls.append((target, text)) }
        }
        return Delegate(
            directory: directory, isPhoneWindowOnScreen: { false }, loadKeys: { keys },
            sendTextReply: send,
            notify: { title, body in sent.notifications.append("\(title) / \(body)") })
    }

    private func makeRouter(knowing paneIDs: [String]) -> AgentNotificationRouter {
        let router = AgentNotificationRouter()
        router.agentsDidChange(
            paneIDs.map {
                ConsoleAgent(
                    hostID: hostID, hostName: "mac-studio", agent: Agent(.fixture(paneID: $0)),
                    workspaceLabel: nil, repositoryCheckout: nil)
            })
        return router
    }

    // MARK: - Action mapping

    @Test func tapAndEveryOpeningButtonOpenTheAgent() {
        for identifier in [
            UNNotificationDefaultActionIdentifier, "waycar.open", "waycar.review", "waycar.reply",
        ] {
            #expect(Delegate.responseAction(actionIdentifier: identifier, userText: nil) == .open)
        }
    }

    @Test func typedReplySendsTheTextAsTyped() {
        #expect(
            Delegate.responseAction(actionIdentifier: "waycar.reply.text", userText: " run tests ")
                == .sendText(" run tests "))
    }

    @Test func emptyTypedReplyAndDismissalDoNothing() {
        #expect(
            Delegate.responseAction(actionIdentifier: "waycar.reply.text", userText: "  \n")
                == .ignore)
        #expect(
            Delegate.responseAction(actionIdentifier: "waycar.reply.text", userText: nil)
                == .ignore)
        #expect(
            Delegate.responseAction(
                actionIdentifier: UNNotificationDismissActionIdentifier, userText: nil) == .ignore)
        #expect(Delegate.responseAction(actionIdentifier: "unknown", userText: nil) == .ignore)
    }

    // MARK: - Responding

    @Test func textReplyCallsTheSenderOnceWithTheTypedText() async {
        let sent = SentReplies()
        let directory = AgentSceneDirectory()
        let delegate = makeDelegate(directory: directory, sent: sent)

        await delegate.respond(.sendText("run the tests"), target: target("w1:p1"))

        #expect(sent.calls.count == 1)
        #expect(sent.calls.first?.target == target("w1:p1"))
        #expect(sent.calls.first?.text == "run the tests")
        #expect(sent.notifications.isEmpty)
        // A reply sends; it never navigates.
        let router = makeRouter(knowing: ["w1:p1"])
        directory.register(sceneID: UUID(), router: router, activate: {})
        #expect(router.path.isEmpty)
    }

    @Test func openDeepLinksAndSendsNothing() async {
        let sent = SentReplies()
        let directory = AgentSceneDirectory()
        let delegate = makeDelegate(directory: directory, sent: sent)

        await delegate.respond(.open, target: target("w1:p2"))

        let router = makeRouter(knowing: ["w1:p2"])
        directory.register(sceneID: UUID(), router: router, activate: {})
        #expect(router.path == [target("w1:p2").agentID])
        #expect(sent.calls.isEmpty)
    }

    /// With no target (an envelope this device can't decrypt) or no sender,
    /// nothing is sent, the user is asked to send it again, and a reply
    /// never navigates.
    @Test func textReplyWithoutATargetOrASenderIsReportedNotSent() async {
        let sent = SentReplies()
        let directory = AgentSceneDirectory()
        await makeDelegate(directory: directory, sent: sent)
            .respond(.sendText("run the tests"), target: nil)
        await makeDelegate(directory: directory, sent: sent, sends: false)
            .respond(.sendText("run the tests"), target: target("w1:p1"))

        #expect(sent.calls.isEmpty)
        #expect(
            sent.notifications == Array(
                repeating: "Reply not sent / Open Waycar and send it again.", count: 2))
        let router = makeRouter(knowing: ["w1:p1"])
        directory.register(sceneID: UUID(), router: router, activate: {})
        #expect(router.path.isEmpty)
    }

    // MARK: - Resolving the target

    /// The decrypted envelope names the Agent both a reply and an open act on.
    @Test func envelopeTargetDrivesSendingAndOpening() throws {
        let vector = try #require(
            NotificationVectorFile.shared.valid.first { $0.name == "blocked claude agent" })
        let key = try #require(Data(base64URLEncoded: vector.key))
        let delegate = makeDelegate(
            keys: [NotificationKeyRecord(hostID: hostID, hostName: "mac-studio", key: key)])
        let userInfo: [AnyHashable: Any] = [
            "envelope": vector.envelope,
            "waycarHostID": UUID().uuidString, "waycarPaneID": "w9:p9",
        ]

        let expected = target(vector.payload.paneId)
        #expect(delegate.resolveTarget(for: .sendText("go"), userInfo: userInfo) == expected)
        #expect(delegate.resolveTarget(for: .open, userInfo: userInfo) == expected)
    }

    /// Plaintext ids are unauthenticated: they may open a screen but never
    /// pick a pane to type into.
    @Test func plaintextIdsOpenButNeverSend() {
        let delegate = makeDelegate()
        let userInfo: [AnyHashable: Any] = [
            "envelope": "garbage", "waycarHostID": hostID.uuidString, "waycarPaneID": "w1:p1",
        ]

        #expect(delegate.resolveTarget(for: .sendText("rm -rf"), userInfo: userInfo) == nil)
        #expect(delegate.resolveTarget(for: .open, userInfo: userInfo) == target("w1:p1"))
    }

    @Test func noEnvelopeAndNoIdsResolveToNoTarget() {
        let delegate = makeDelegate()
        let userInfo: [AnyHashable: Any] = ["envelope": "garbage"]

        #expect(delegate.resolveTarget(for: .sendText("go"), userInfo: userInfo) == nil)
        #expect(delegate.resolveTarget(for: .open, userInfo: userInfo) == nil)
    }
}
