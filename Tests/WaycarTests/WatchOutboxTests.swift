import Foundation
import Testing

@testable import Waycar

/// The watch-side message state machine: voice and text walk their own
/// phases to a delivery outcome, failures map to retry or no-retry, a retry
/// keeps its id, and an Agent has at most one message in flight.
@Suite("Watch outbox")
struct WatchOutboxTests {
    // MARK: Fixtures

    /// The Agent most tests send to.
    private static let agent = WatchAgentID(hostID: UUID(), paneID: "w1:p1")
    /// Another Agent on the same Host.
    private static let otherAgent = WatchAgentID(hostID: agent.hostID, paneID: "w1:p2")
    /// The delivery time stamped on `.sent`.
    private static let now = Date(timeIntervalSince1970: 1_791_800_000)

    /// A voice message to `agent`.
    private static func voice(_ id: UUID = UUID(), to agent: WatchAgentID = WatchOutboxTests.agent) -> WatchOutgoing {
        WatchOutgoing(id: id, agentID: agent, content: .voice(duration: 4.5))
    }

    /// A text message to `agent`.
    private static func text(_ id: UUID = UUID(), to agent: WatchAgentID = WatchOutboxTests.agent) -> WatchOutgoing {
        WatchOutgoing(id: id, agentID: agent, content: .text("ship it"))
    }

    /// The delivery event for `message`.
    private static func delivery(_ message: WatchOutgoing, _ outcome: WatchDelivery) -> WatchEvent {
        .delivery(messageID: message.id, message.agentID, outcome)
    }

    /// An outbox holding `message`, already begun.
    private static func outbox(with message: WatchOutgoing) -> WatchOutbox {
        var outbox = WatchOutbox()
        let began = outbox.begin(message)
        #expect(began)
        return outbox
    }

    // MARK: Happy paths

    @Test func voiceWalksSendingTranscribingSent() {
        let message = Self.voice()
        var outbox = Self.outbox(with: message)
        #expect(outbox.latest(for: Self.agent)?.phase == .sending)
        #expect(outbox.hasInFlight(for: Self.agent))

        outbox.acknowledged(message.id)
        #expect(outbox.latest(for: Self.agent)?.phase == .transcribing)
        #expect(outbox.hasInFlight(for: Self.agent))

        outbox.apply(Self.delivery(message, .sent(text: "Ship it")), now: Self.now)
        let sent = outbox.latest(for: Self.agent)
        #expect(sent?.phase == .sent(text: "Ship it", at: Self.now))
        #expect(sent?.id == message.id)
        #expect(sent?.content == .voice(duration: 4.5))
        #expect(sent?.canRetry == false)
        #expect(!outbox.hasInFlight(for: Self.agent))
    }

    @Test func textWalksSendingDeliveringSent() {
        let message = Self.text()
        var outbox = Self.outbox(with: message)
        outbox.acknowledged(message.id)
        #expect(outbox.latest(for: Self.agent)?.phase == .delivering)
        #expect(outbox.hasInFlight(for: Self.agent))

        outbox.apply(Self.delivery(message, .sent(text: "ship it")), now: Self.now)
        #expect(outbox.latest(for: Self.agent)?.phase == .sent(text: "ship it", at: Self.now))
        #expect(!outbox.hasInFlight(for: Self.agent))
    }

    @Test func beginForcesSendingWhateverPhaseWasPassed() {
        var message = Self.text()
        message.phase = .unknown
        let outbox = Self.outbox(with: message)
        #expect(outbox.latest(for: Self.agent)?.phase == .sending)
    }

    @Test func deliveryBeforeAcknowledgementStillApplies() {
        let message = Self.text()
        var outbox = Self.outbox(with: message)
        outbox.apply(Self.delivery(message, .sent(text: "ship it")), now: Self.now)
        outbox.acknowledged(message.id)
        #expect(outbox.latest(for: Self.agent)?.phase == .sent(text: "ship it", at: Self.now))
    }

    @Test(arguments: [
        (WatchDelivery.notSent(reason: "studio is offline"), WatchOutgoing.Phase.notSent(reason: "studio is offline")),
        (.unknown, .unknown),
        (.keptAsDraft(reason: .blocked), .keptAsDraft(reason: .blocked)),
        (.keptAsDraft(reason: .signInRequired), .keptAsDraft(reason: .signInRequired)),
        (.keptAsDraft(reason: .folderTrustRequired), .keptAsDraft(reason: .folderTrustRequired)),
        (.noWords, .noWords),
    ])
    func mapsEveryDeliveryOutcome(_ outcome: WatchDelivery, _ phase: WatchOutgoing.Phase) {
        let message = Self.voice()
        var outbox = Self.outbox(with: message)
        outbox.acknowledged(message.id)
        outbox.apply(Self.delivery(message, outcome), now: Self.now)
        #expect(outbox.latest(for: Self.agent)?.phase == phase)
        #expect(!outbox.hasInFlight(for: Self.agent))
        #expect(outbox.latest(for: Self.agent)?.canRetry == (phase == .notSent(reason: "studio is offline")))
    }

    // MARK: Failures

    @Test func ackFailureIsNotSentAndRetryable() {
        let message = Self.text()
        var outbox = Self.outbox(with: message)
        outbox.ackFailed(message.id, reason: "iPhone didn't answer")
        let failed = outbox.latest(for: Self.agent)
        #expect(failed?.phase == .notSent(reason: "iPhone didn't answer"))
        #expect(failed?.canRetry == true)
        #expect(!outbox.hasInFlight(for: Self.agent))
    }

    @Test func ackFailureAfterAcknowledgementIsIgnored() {
        let message = Self.text()
        var outbox = Self.outbox(with: message)
        outbox.acknowledged(message.id)
        outbox.ackFailed(message.id, reason: "late")
        #expect(outbox.latest(for: Self.agent)?.phase == .delivering)
    }

    @Test func timeoutAfterAcknowledgementIsUnknownWithoutRetry() {
        let message = Self.voice()
        var outbox = Self.outbox(with: message)
        outbox.acknowledged(message.id)
        outbox.timedOut(message.id)
        #expect(outbox.latest(for: Self.agent)?.phase == .unknown)
        #expect(outbox.latest(for: Self.agent)?.canRetry == false)

        outbox.retry(message.id)
        #expect(outbox.latest(for: Self.agent)?.phase == .unknown)
        #expect(!outbox.hasInFlight(for: Self.agent))
    }

    @Test func timeoutNeverOverturnsADeliveredMessage() {
        let message = Self.text()
        var outbox = Self.outbox(with: message)
        outbox.acknowledged(message.id)
        outbox.apply(Self.delivery(message, .sent(text: "ship it")), now: Self.now)
        outbox.timedOut(message.id)
        #expect(outbox.latest(for: Self.agent)?.phase == .sent(text: "ship it", at: Self.now))
    }

    @Test func lateDeliveryResolvesAnUnknownMessage() {
        let message = Self.text()
        var outbox = Self.outbox(with: message)
        outbox.acknowledged(message.id)
        outbox.timedOut(message.id)
        outbox.apply(Self.delivery(message, .sent(text: "ship it")), now: Self.now)
        #expect(outbox.latest(for: Self.agent)?.phase == .sent(text: "ship it", at: Self.now))
    }

    @Test func lateDeliveryOverturnsALostAcknowledgement() {
        // The phone took the message but its reply was lost: the watch shows
        // not sent until the phone's `.sent` arrives and replaces it.
        let message = Self.text()
        var outbox = Self.outbox(with: message)
        outbox.ackFailed(message.id, reason: "iPhone didn't answer")
        outbox.apply(Self.delivery(message, .sent(text: "ship it")), now: Self.now)
        #expect(outbox.latest(for: Self.agent)?.phase == .sent(text: "ship it", at: Self.now))
        #expect(outbox.latest(for: Self.agent)?.canRetry == false)
    }

    @Test func settledOutcomeIgnoresLaterEvents() {
        let message = Self.voice()
        var outbox = Self.outbox(with: message)
        outbox.apply(Self.delivery(message, .noWords), now: Self.now)
        outbox.apply(Self.delivery(message, .notSent(reason: "duplicate")), now: Self.now)
        #expect(outbox.latest(for: Self.agent)?.phase == .noWords)
    }

    // MARK: Retry

    @Test func retryResendsWithTheSameID() {
        let message = Self.text()
        var outbox = Self.outbox(with: message)
        outbox.ackFailed(message.id, reason: "iPhone didn't answer")
        outbox.retry(message.id)
        let retried = outbox.latest(for: Self.agent)
        #expect(retried?.id == message.id)
        #expect(retried?.phase == .sending)
        #expect(retried?.content == .text("ship it"))
        #expect(outbox.messages.count == 1)
        #expect(outbox.hasInFlight(for: Self.agent))

        outbox.acknowledged(message.id)
        outbox.apply(Self.delivery(message, .sent(text: "ship it")), now: Self.now)
        #expect(outbox.latest(for: Self.agent)?.phase == .sent(text: "ship it", at: Self.now))
    }

    @Test func retryIsIgnoredOutsideNotSent() {
        let message = Self.text()
        var outbox = Self.outbox(with: message)
        outbox.acknowledged(message.id)
        outbox.retry(message.id)
        #expect(outbox.latest(for: Self.agent)?.phase == .delivering)
    }

    // MARK: One in flight

    @Test func refusesASecondMessageWhileOneIsInFlight() {
        let first = Self.text()
        var outbox = Self.outbox(with: first)
        let second = Self.voice()
        let beganWhileSending = outbox.begin(second)
        #expect(!beganWhileSending)
        #expect(outbox.messages[second.id] == nil)
        #expect(outbox.latest(for: Self.agent)?.id == first.id)

        outbox.acknowledged(first.id)
        let beganWhileDelivering = outbox.begin(second)
        #expect(!beganWhileDelivering)
    }

    @Test func otherAgentsAreIndependent() {
        let first = Self.text()
        var outbox = Self.outbox(with: first)
        let other = Self.voice(to: Self.otherAgent)
        let began = outbox.begin(other)
        #expect(began)
        #expect(outbox.hasInFlight(for: Self.agent))
        #expect(outbox.hasInFlight(for: Self.otherAgent))
        #expect(outbox.latest(for: Self.otherAgent)?.id == other.id)
    }

    @Test func newMessageReplacesTheSettledOne() {
        let first = Self.text()
        var outbox = Self.outbox(with: first)
        outbox.ackFailed(first.id, reason: "iPhone didn't answer")
        let second = Self.voice()
        let began = outbox.begin(second)
        #expect(began)
        #expect(outbox.latest(for: Self.agent)?.id == second.id)
        #expect(outbox.messages.count == 1)

        // The replaced message is gone: its retry and events do nothing.
        outbox.retry(first.id)
        outbox.apply(Self.delivery(first, .sent(text: "ship it")), now: Self.now)
        #expect(outbox.messages[first.id] == nil)
        #expect(outbox.latest(for: Self.agent)?.phase == .sending)
    }

    @Test func refusesAReusedID() {
        let first = Self.text()
        var outbox = Self.outbox(with: first)
        outbox.ackFailed(first.id, reason: "iPhone didn't answer")
        let began = outbox.begin(Self.voice(first.id))
        #expect(!began)
        #expect(outbox.latest(for: Self.agent)?.content == .text("ship it"))
    }

    // MARK: Unknown ids

    @Test func eventsForUnknownIDsAreIgnored() {
        let message = Self.text()
        var outbox = Self.outbox(with: message)
        let before = outbox
        let stranger = UUID()
        outbox.acknowledged(stranger)
        outbox.ackFailed(stranger, reason: "x")
        outbox.timedOut(stranger)
        outbox.retry(stranger)
        outbox.apply(.delivery(messageID: stranger, Self.agent, .sent(text: "x")), now: Self.now)
        #expect(outbox == before)
    }

    @Test func deliveryForTheWrongAgentIsIgnored() {
        let message = Self.text()
        var outbox = Self.outbox(with: message)
        outbox.apply(.delivery(messageID: message.id, Self.otherAgent, .sent(text: "x")), now: Self.now)
        #expect(outbox.latest(for: Self.agent)?.phase == .sending)
    }
}
