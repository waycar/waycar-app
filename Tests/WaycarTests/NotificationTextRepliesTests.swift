import Foundation
import Testing

@testable import Waycar

/// A typed notification reply that doesn't go out is never lost silently.
@MainActor
@Suite("Notification text replies")
struct NotificationTextRepliesTests {
    /// What the replies drove.
    @MainActor
    final class Recorder {
        var sent: [String] = []
        var drafts: [String] = []
        var notifications: [String] = []
    }

    private let host = Host.fixture(name: "studio")

    private var codex: ConsoleAgent {
        ConsoleAgent(
            hostID: host.id, hostName: host.displayName,
            agent: Agent(.fixture(paneID: "codex", status: .done, kind: "codex")),
            workspaceLabel: "site", repositoryCheckout: nil)
    }

    /// Replies over fakes: `outcome` is what the bridge reports, nil for
    /// no bridge; `known` whether the Console has the Agent.
    private func make(
        outcome: AgentActionService.SendOutcome?, known: Bool = true
    ) -> (NotificationTextReplies, Recorder) {
        let recorder = Recorder()
        let replies = NotificationTextReplies()
        let agent = codex
        var send: (@MainActor (String, ConsoleAgent.ID) async -> AgentActionService.SendOutcome)?
        if let outcome {
            send = { text, _ in
                recorder.sent.append(text)
                return outcome
            }
        }
        replies.dependencies = NotificationTextReplies.Dependencies(
            send: send,
            agent: { id in known && id == agent.id ? agent : nil },
            keepAsDraft: { text, _ in recorder.drafts.append(text) },
            notify: { title, body in recorder.notifications.append("\(title) / \(body)") })
        return (replies, recorder)
    }

    @Test func aSentReplySaysNothing() async {
        let (replies, recorder) = make(outcome: .sent)
        await replies.send("ship it", to: codex.id)
        #expect(recorder.drafts.isEmpty)
        #expect(recorder.notifications.isEmpty)
    }

    /// Locked, Host never confirmed, not sent, or no bridge at all: the
    /// text becomes the draft, and the user is told.
    @Test(arguments: [
        .notSent(reason: "Unlock your iPhone"),
        .notSent(reason: "Can't reach studio"),
        nil,
    ] as [AgentActionService.SendOutcome?])
    func anUnsentReplyIsKeptAsTheDraft(outcome: AgentActionService.SendOutcome?) async {
        let (replies, recorder) = make(outcome: outcome)
        await replies.send("ship it", to: codex.id)
        #expect(recorder.drafts == ["ship it"])
        #expect(recorder.notifications == ["Not sent to site · Codex / Kept as a draft on your iPhone."])
    }

    @Test func aReplyAlreadyKeptAsADraftIsNotKeptTwice() async {
        let (replies, recorder) = make(outcome: .keptAsDraft(.blocked))
        await replies.send("ship it", to: codex.id)
        #expect(recorder.drafts.isEmpty)
        #expect(recorder.notifications == ["Not sent to site · Codex / Kept as a draft on your iPhone."])
    }

    /// It may have been delivered: no draft, so it is never sent twice.
    @Test func anUnconfirmedReplyIsReportedAndNotKept() async {
        let (replies, recorder) = make(outcome: .unknown)
        await replies.send("ship it", to: codex.id)
        #expect(recorder.drafts.isEmpty)
        #expect(recorder.notifications == ["site · Codex / Couldn't confirm it was delivered."])
    }

    @Test func anUnsentReplyToAnAgentTheConsoleLacksAsksToSendAgain() async {
        let (replies, recorder) = make(outcome: .notSent(reason: "Can't reach studio"), known: false)
        await replies.send("ship it", to: codex.id)
        #expect(recorder.drafts.isEmpty)
        #expect(recorder.notifications == ["Reply not sent / Open Waycar and send it again."])
    }

    /// Text that is nothing but unsafe characters cleans up to nothing: it
    /// is neither sent nor kept, and the user is asked to send it again.
    @Test func aReplyEmptyAfterCleanupAsksToSendAgain() async {
        let (replies, recorder) = make(outcome: .sent)
        await replies.send("\u{1B}\u{07}", to: codex.id)
        #expect(recorder.sent.isEmpty)
        #expect(recorder.drafts.isEmpty)
        #expect(recorder.notifications == ["Reply not sent / Open Waycar and send it again."])
    }
}
