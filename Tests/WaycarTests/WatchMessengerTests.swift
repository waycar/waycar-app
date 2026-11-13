import Foundation
import Testing

@testable import Waycar

/// The watch's message sending: the two-phase acknowledgement and its
/// deadline, the delivery wait, Try again under the same id, and how long a
/// recording is kept. Driven through a scripted phone link and clocks the
/// test fires.
@Suite("Watch messenger", .timeLimit(.minutes(1)))
@MainActor
struct WatchMessengerTests {
    // MARK: Fixtures

    /// The Agent every message goes to.
    private static let agent = WatchAgentID(hostID: UUID(), paneID: "w1:p1")
    /// The stamp on `.sent`.
    private static let now = Date(timeIntervalSince1970: 1_791_800_000)
    /// The delivery wait the messenger is given.
    private static let timeout: Duration = .seconds(7)
    /// How long the messenger waits for an acknowledgement.
    private static let ackDeadline: Duration = .seconds(20)

    /// A messenger over a scripted link and manual clocks, with a folder
    /// for recordings.
    @MainActor
    private struct Harness {
        /// The scripted phone link.
        let link: ScriptedLink
        /// The delivery clock the test fires.
        let clock: DeliveryClock
        /// The acknowledgement deadline's clock, fired separately.
        let ackClock: DeliveryClock
        /// Sends the acknowledgement requests, shared with any other request
        /// a test makes.
        let requester: WatchRequester
        /// The messenger under test.
        let messenger: WatchMessenger
        /// Where this test's recordings live.
        let folder: URL

        init() throws {
            let link = ScriptedLink()
            let clock = DeliveryClock()
            let ackClock = DeliveryClock()
            self.link = link
            self.clock = clock
            self.ackClock = ackClock
            requester = WatchRequester(
                link: link, deadline: WatchMessengerTests.ackDeadline, isReachable: true,
                isReachableNow: { link.isReachable }, sleep: { try await ackClock.sleep($0) })
            messenger = WatchMessenger(
                link: link, requester: requester, deliveryTimeout: WatchMessengerTests.timeout,
                sleep: { try await clock.sleep($0) }, now: { WatchMessengerTests.now })
            folder = FileManager.default.temporaryDirectory.appending(
                path: "WatchMessengerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        /// A recording file on disk.
        func recording() throws -> URL {
            let url = folder.appending(path: "\(UUID().uuidString).m4a")
            try Data("audio".utf8).write(to: url)
            return url
        }

        /// A voice message begun from a fresh recording.
        func beginVoice() throws -> (id: UUID, url: URL) {
            let url = try recording()
            let id = try #require(messenger.begin(.voice(duration: 4), to: WatchMessengerTests.agent, recordingAt: url))
            return (id, url)
        }

        /// The message's phase.
        func phase(_ id: UUID) -> WatchOutgoing.Phase? {
            messenger.outbox.messages[id]?.phase
        }

        /// Lets the messenger's timer tasks run until `condition` holds.
        func settle(
            until condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
        ) async {
            try? await waitUntil("the condition never held", sourceLocation: sourceLocation, condition: condition)
        }

        /// Removes the recordings folder and ends any wait still parked.
        func tearDown() {
            clock.cancelAll()
            ackClock.cancelAll()
            link.releaseParked()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// The delivery event for a message to `agent`.
    private static func delivery(_ id: UUID, _ outcome: WatchDelivery) -> WatchEvent {
        .delivery(messageID: id, agent, outcome)
    }

    // MARK: Acknowledgement

    @Test func ackFailureCancelsTheTransferAndIsNotSent() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.link.replies = [.failure(LinkDown())]
        harness.messenger.failureReason = { _ in "Update Waycar on your iPhone" }
        let (id, url) = try harness.beginVoice()

        await harness.messenger.deliver(id)

        #expect(harness.link.transfers.map { $0.file.messageID } == [id])
        #expect(harness.link.cancelled == [id])
        #expect(harness.phase(id) == .notSent(reason: "Update Waycar on your iPhone"))
        #expect(FileManager.default.fileExists(atPath: url.path()), "kept for Try again")
        #expect(harness.clock.requested.isEmpty)
    }

    @Test func aRefusalShowsThePhonesReasonAndCancelsTheTransfer() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.link.replies = [.success(.failure("Can't reach studio"))]
        let (id, _) = try harness.beginVoice()

        await harness.messenger.deliver(id)

        #expect(harness.link.cancelled == [id])
        #expect(harness.phase(id) == .notSent(reason: "Can't reach studio"))
    }

    /// No acknowledgement within the deadline: definitely not sent ("iPhone
    /// didn't answer"), the queued recording cancelled, and Try again
    /// offered, even though the link's own wait never ends.
    @Test func noAcknowledgementInTimeIsNotSentAndCancelsTheTransfer() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.link.parkedTypes = ["voice"]
        let (id, url) = try harness.beginVoice()

        let delivering = Task { await harness.messenger.deliver(id) }
        await harness.settle { harness.ackClock.parked == 1 }
        #expect(harness.phase(id) == .sending)
        #expect(harness.link.cancelled.isEmpty)

        try await harness.ackClock.fire()
        await delivering.value

        #expect(harness.ackClock.requested == [Self.ackDeadline])
        #expect(harness.phase(id) == .notSent(reason: "iPhone didn't answer"))
        #expect(harness.link.cancelled == [id])
        #expect(FileManager.default.fileExists(atPath: url.path()), "kept for Try again")
        #expect(harness.clock.requested.isEmpty, "no delivery wait without an acknowledgement")
        #expect(harness.messenger.retry(id))
    }

    /// A text message the iPhone never acknowledges is not sent either.
    @Test func anUnacknowledgedTextIsNotSent() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.link.parkedTypes = ["send"]
        let id = try #require(harness.messenger.begin(.text("ship it"), to: Self.agent))

        let delivering = Task { await harness.messenger.deliver(id) }
        try await harness.ackClock.fire()
        await delivering.value

        #expect(harness.phase(id) == .notSent(reason: WatchMessenger.notSentReason))
        #expect(harness.link.cancelled.isEmpty, "no recording to cancel")
    }

    /// An iPhone that stays unreachable for the debounce window fails with
    /// "iPhone not reachable", without waiting out the deadline.
    @Test func anUnreachableIPhoneIsNotSentOnceTheDebouncePasses() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.link.replies = [.failure(WatchLinkError.unreachable)]
        harness.link.isReachable = false
        let (id, _) = try harness.beginVoice()
        let messenger = harness.messenger
        let delivery = Task { await messenger.deliver(id) }
        await harness.settle {
            harness.ackClock.requested.contains(WatchRequester.debounce) && harness.ackClock.parked == 1
        }

        try await harness.ackClock.fire()
        await delivery.value

        #expect(harness.phase(id) == .notSent(reason: "iPhone not reachable"))
        #expect(harness.link.cancelled == [id])
        #expect(harness.messenger.retry(id))
    }

    /// A voice message still waiting for its `.received` when the app went
    /// to the background is asked for again under the same id on return;
    /// the recording is neither re-queued nor cancelled.
    @Test func aVoiceMessageWaitingForItsAckResendsWithTheSameID() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.link.parkedTypes = ["voice"]
        let (id, url) = try harness.beginVoice()
        let messenger = harness.messenger
        let delivery = Task { await messenger.deliver(id) }
        await harness.settle { harness.link.requests.count == 1 && harness.ackClock.parked == 1 }

        harness.requester.setActive(false)
        try await harness.ackClock.fire(WatchRequester.debounce)  // Lost with the link.
        harness.link.parkedTypes = []
        harness.requester.setActive(true)
        try await harness.ackClock.fire(WatchRequester.debounce)  // Ready: resent.
        await delivery.value

        #expect(harness.phase(id) == .transcribing)
        #expect(harness.link.requests == [.voice(messageID: id, Self.agent), .voice(messageID: id, Self.agent)])
        #expect(harness.link.transfers.count == 1)
        #expect(harness.link.cancelled.isEmpty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// A Latest the iPhone never answers does not hold up a voice message's
    /// acknowledgement sent after it through the same requester.
    @Test func aStuckLatestDoesNotDelayAVoiceAcknowledgement() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.link.parkedTypes = ["latest"]
        let requester = harness.requester
        let latest = Task { try await requester.send(.latest(Self.agent)) }
        await harness.settle { harness.link.requests.count == 1 && harness.ackClock.parked == 1 }

        let (id, _) = try harness.beginVoice()
        await harness.messenger.deliver(id)

        #expect(harness.phase(id) == .transcribing)
        #expect(harness.link.requests == [.latest(Self.agent), .voice(messageID: id, Self.agent)])
        await harness.settle { harness.ackClock.parked == 1 }
        #expect(harness.ackClock.parked == 1, "only the Latest still waits")

        try await harness.ackClock.fire()
        await #expect(throws: WatchLinkError.noAnswer) { try await latest.value }
        #expect(harness.phase(id) == .transcribing)
    }

    @Test func receivedThenNoOutcomeTimesOutAsUnknown() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let (id, _) = try harness.beginVoice()

        await harness.messenger.deliver(id)
        #expect(harness.link.requests == [.voice(messageID: id, Self.agent)])
        #expect(harness.phase(id) == .transcribing)

        try await harness.clock.fire()
        await harness.settle { harness.phase(id) == .unknown }
        #expect(harness.phase(id) == .unknown)
        #expect(harness.clock.requested == [Self.timeout])
        #expect(harness.messenger.retry(id) == false, "an unknown message is never resent")
    }

    @Test func aDeliveryOutcomeStopsTheWait() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let id = try #require(harness.messenger.begin(.text("ship it"), to: Self.agent))
        await harness.messenger.deliver(id)
        #expect(harness.phase(id) == .delivering)
        await harness.settle { harness.clock.parked == 1 }
        #expect(harness.clock.parked == 1)

        harness.messenger.receive(Self.delivery(id, .sent(text: "ship it")))
        await harness.settle { harness.clock.parked == 0 }
        #expect(harness.clock.parked == 0, "the cancelled wait ended without timing out")
        #expect(harness.phase(id) == .sent(text: "ship it", at: Self.now))
    }

    @Test func restartingTheWaitsStartsThemOverFromNow() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let id = try #require(harness.messenger.begin(.text("ship it"), to: Self.agent))
        await harness.messenger.deliver(id)
        await harness.settle { harness.clock.parked == 1 }

        harness.messenger.restartDeliveryTimers()
        await harness.settle { harness.clock.requested.count == 2 && harness.clock.parked == 1 }
        #expect(harness.clock.requested == [Self.timeout, Self.timeout])
        #expect(harness.clock.parked == 1, "the first wait was cancelled")
        #expect(harness.phase(id) == .delivering)

        try await harness.clock.fire()
        await harness.settle { harness.phase(id) == .unknown }
        #expect(harness.phase(id) == .unknown)
    }

    // MARK: Recording lifetime

    @Test(arguments: [WatchDelivery.sent(text: "ship it"), .keptAsDraft(reason: .blocked), .noWords])
    func theRecordingOutlivesUnknownUntilAFinalOutcome(_ outcome: WatchDelivery) async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let (id, url) = try harness.beginVoice()
        await harness.messenger.deliver(id)
        try await harness.clock.fire()
        await harness.settle { harness.phase(id) == .unknown }

        #expect(harness.phase(id) == .unknown)
        #expect(FileManager.default.fileExists(atPath: url.path()))
        #expect(harness.link.cancelled.isEmpty, "the queued transfer may still arrive")

        harness.messenger.receive(Self.delivery(id, outcome))
        #expect(!FileManager.default.fileExists(atPath: url.path()))
        #expect(harness.link.cancelled == [id])
    }

    @Test func theNextMessageDiscardsTheLastRecording() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.link.replies = [.failure(LinkDown())]
        let (id, url) = try harness.beginVoice()
        await harness.messenger.deliver(id)
        #expect(FileManager.default.fileExists(atPath: url.path()))

        let next = harness.messenger.begin(.text("never mind"), to: Self.agent)
        #expect(next != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path()))
        #expect(harness.messenger.outbox.messages[id] == nil)
    }

    @Test func aRecordingRefusedWhileOneIsInFlightIsDeleted() throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let (first, firstURL) = try harness.beginVoice()
        let secondURL = try harness.recording()

        let second = harness.messenger.begin(.voice(duration: 2), to: Self.agent, recordingAt: secondURL)

        #expect(second == nil)
        #expect(!FileManager.default.fileExists(atPath: secondURL.path()))
        #expect(FileManager.default.fileExists(atPath: firstURL.path()))
        #expect(harness.phase(first) == .sending)
    }

    // MARK: Try again

    @Test func retryResendsUnderTheSameID() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.link.replies = [.failure(LinkDown())]
        let id = try #require(harness.messenger.begin(.text("ship it"), to: Self.agent))
        await harness.messenger.deliver(id)
        #expect(harness.phase(id) == .notSent(reason: WatchMessenger.notSentReason))

        #expect(harness.messenger.retry(id))
        await harness.messenger.deliver(id)

        let request = WatchRequest.send(messageID: id, Self.agent, text: "ship it")
        #expect(harness.link.requests == [request, request])
        #expect(harness.phase(id) == .delivering)
        #expect(harness.messenger.outbox.messages.count == 1)
    }

    @Test func aLateNotSentAfterUnknownAllowsAVoiceRetry() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let (id, url) = try harness.beginVoice()
        await harness.messenger.deliver(id)
        try await harness.clock.fire()
        await harness.settle { harness.phase(id) == .unknown }

        harness.messenger.receive(Self.delivery(id, .notSent(reason: "Can't reach studio")))
        #expect(harness.phase(id) == .notSent(reason: "Can't reach studio"))
        #expect(harness.messenger.retry(id))
        await harness.messenger.deliver(id)

        let request = WatchRequest.voice(messageID: id, Self.agent)
        #expect(harness.link.requests == [request, request])
        #expect(harness.link.transfers.map { $0.file.messageID } == [id, id])
        #expect(harness.phase(id) == .transcribing)
        #expect(FileManager.default.fileExists(atPath: url.path()))
    }

    @Test func aStaleTransferFailureLeavesTheRetryAlone() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        harness.link.replies = [.success(.failure("Can't reach studio"))]
        let (id, _) = try harness.beginVoice()
        await harness.messenger.deliver(id)
        let first = try #require(harness.link.transfers.first?.attempt)

        // The cancelled transfer's failure keeps the iPhone's reason…
        harness.messenger.voiceTransferFailed(messageID: id, agentID: Self.agent, attempt: first)
        #expect(harness.phase(id) == .notSent(reason: "Can't reach studio"))

        #expect(harness.messenger.retry(id))
        await harness.messenger.deliver(id)
        #expect(harness.phase(id) == .transcribing)
        let attempts = harness.link.transfers.map { $0.attempt }
        try #require(attempts.count == 2)

        // …and, arriving after Try again, leaves the retry in flight.
        harness.messenger.voiceTransferFailed(messageID: id, agentID: Self.agent, attempt: attempts[0])
        #expect(harness.phase(id) == .transcribing)

        // The retry's own transfer failing does count.
        harness.messenger.voiceTransferFailed(messageID: id, agentID: Self.agent, attempt: attempts[1])
        #expect(harness.phase(id) == .notSent(reason: WatchMessenger.notSentReason))
    }

    // MARK: Change reports

    @Test func reportsEachPhaseOnce() async throws {
        let harness = try Harness()
        defer { harness.tearDown() }
        let log = PhaseLog()
        harness.messenger.onChange = { log.phases.append($0?.phase) }
        let id = try #require(harness.messenger.begin(.text("ship it"), to: Self.agent))
        await harness.messenger.deliver(id)
        harness.messenger.receive(Self.delivery(id, .sent(text: "ship it")))
        harness.messenger.receive(Self.delivery(id, .sent(text: "ship it")))

        #expect(log.phases == [.sending, .delivering, .sent(text: "ship it", at: Self.now)])
    }
}

/// The phases a messenger reported.
@MainActor
private final class PhaseLog {
    /// In report order.
    var phases: [WatchOutgoing.Phase?] = []
}

/// The watch's requester: every kind of request ends at its deadline with
/// `WatchLinkError.noAnswer` (the store's "Waycar on iPhone didn't answer —
/// open it") however long the link would wait; flaps pause rather than
/// resend or fail; a lost request is resent once within what is left of its
/// deadline; and requests never wait on each other.
@Suite("Watch requester", .timeLimit(.minutes(1)))
@MainActor
struct WatchRequesterTests {
    /// The Agent requests name; nonisolated, for the test arguments.
    private nonisolated static let agent = WatchAgentID(hostID: UUID(), paneID: "w1:p1")
    /// The deadline the requester is given.
    private static let deadline: Duration = .seconds(20)
    /// The debounce window.
    private static let debounce = WatchRequester.debounce
    /// An answer to a Blocked prompt; nonisolated, for the test arguments.
    private nonisolated static let answer = WatchRequest.answer(agent, promptID: UUID(), .allow)

    /// A requester over a scripted link and a manual clock.
    @MainActor
    private struct Harness {
        /// The scripted phone link.
        let link: ScriptedLink
        /// The deadline and debounce clock the test fires.
        let clock: DeliveryClock
        /// The requester under test.
        let requester: WatchRequester

        /// Active; `isReachable` nil leaves reachability unknown.
        init(isReachable: Bool? = true) {
            let link = ScriptedLink()
            let clock = DeliveryClock()
            self.link = link
            self.clock = clock
            requester = WatchRequester(
                link: link, deadline: WatchRequesterTests.deadline, isReachable: isReachable,
                isReachableNow: { link.isReachable }, now: { clock.now() },
                sleep: { try await clock.sleep($0) })
        }

        /// Lets tasks run until `condition` holds; records an issue when it
        /// never does.
        func settle(
            until condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
        ) async {
            try? await waitUntil("the condition never held", sourceLocation: sourceLocation, condition: condition)
        }

        /// Ends any wait still parked.
        func tearDown() {
            clock.cancelAll()
            link.releaseParked()
        }
    }

    /// Whether `finished` was set, after letting tasks run a while.
    private static func hasFinished(_ finished: Box) async -> Bool {
        for _ in 0..<50 { await Task.yield() }
        return finished.value
    }

    /// A flag a task sets when done.
    @MainActor
    private final class Box {
        var value = false
    }

    // MARK: Deadline

    @Test(arguments: [
        WatchRequest.latest(WatchRequesterTests.agent), .blockedPrompt(WatchRequesterTests.agent),
        .refresh, .answer(WatchRequesterTests.agent, promptID: UUID(), .allow),
    ])
    func aRequestTheIPhoneNeverAnswersEndsAtTheDeadline(_ request: WatchRequest) async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.link.parkedTypes = [request.logType]
        let requester = harness.requester
        let pending = Task { try await requester.send(request) }
        await harness.settle { harness.clock.parked == 1 }

        try await harness.clock.fire(Self.deadline)

        await #expect(throws: WatchLinkError.noAnswer) { try await pending.value }
        #expect(harness.clock.requested == [Self.deadline])
        #expect(WatchLinkCopy.noAnswer == "Waycar on iPhone didn't answer — open it")
    }

    @Test func aReplyBeforeTheDeadlineStopsItsTimer() async throws {
        let harness = Harness()
        defer { harness.tearDown() }

        let reply = try await harness.requester.send(.latest(Self.agent))

        #expect(reply == .received)
        await harness.settle { harness.clock.requested.count == 1 && harness.clock.parked == 0 }
        #expect(harness.clock.requested == [Self.deadline])
    }

    /// Time on the link before a loss counts: the resend gets only what is
    /// left of the deadline, and fails when that runs out.
    @Test func theDeadlineBudgetCarriesAcrossAResend() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.link.parkedTypes = ["latest"]
        let requester = harness.requester
        let pending = Task { try await requester.send(.latest(Self.agent)) }
        await harness.settle { harness.clock.parked(Self.deadline) == 1 }
        harness.clock.elapsed = .seconds(5)

        requester.setActive(false)
        try await harness.clock.fire(Self.debounce)  // Lost.
        harness.clock.elapsed = .seconds(500)  // Suspended time never counts.
        requester.setActive(true)
        try await harness.clock.fire(Self.debounce)  // Ready: resent.
        await harness.settle { harness.link.requests.count == 2 }

        #expect(harness.clock.requested.last == .seconds(15))
        try await harness.clock.fire(.seconds(15))
        await #expect(throws: WatchLinkError.noAnswer) { try await pending.value }
    }

    /// A request is sent at most twice: lost again after its resend, it
    /// fails as unanswered instead of going out a third time.
    @Test func aRequestIsResentOnlyOnce() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.link.parkedTypes = ["latest"]
        let requester = harness.requester
        let pending = Task { try await requester.send(.latest(Self.agent)) }
        await harness.settle { harness.link.requests.count == 1 }

        for _ in 0..<2 {
            requester.setActive(false)
            try await harness.clock.fire(Self.debounce)
            requester.setActive(true)
            try await harness.clock.fire(Self.debounce)
        }

        await #expect(throws: WatchLinkError.noAnswer) { try await pending.value }
        #expect(harness.link.requests.count == 2)
    }

    /// A reply that arrives after the deadline is dropped; the requester
    /// keeps working.
    @Test func aLateReplyIsDropped() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.link.parkedTypes = ["latest"]
        let requester = harness.requester
        let pending = Task { try await requester.send(.latest(Self.agent)) }
        await harness.settle { harness.clock.parked == 1 }
        try await harness.clock.fire(Self.deadline)
        await #expect(throws: WatchLinkError.noAnswer) { try await pending.value }

        harness.link.releaseParked()
        await harness.settle { requester.droppedReplies == 1 }
        harness.link.parkedTypes = []
        #expect(try await requester.send(.refresh) == .received)
        #expect(requester.droppedReplies == 1)
    }

    /// One request stuck at the link never delays another.
    @Test func aStuckRequestDoesNotDelayAnother() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.link.parkedTypes = ["latest"]
        let requester = harness.requester
        let stuck = Task { try await requester.send(.latest(Self.agent)) }
        await harness.settle { harness.link.requests.count == 1 }

        let ack = try await requester.send(.voice(messageID: UUID(), Self.agent))

        #expect(ack == .received)
        try await harness.clock.fire(Self.deadline)
        await #expect(throws: WatchLinkError.noAnswer) { try await stuck.value }
    }

    // MARK: Flaps and suspension

    /// Reachability dropping and coming back within the debounce window
    /// pauses the request without resending or failing it, an `.answer`
    /// included, and its deadline carries on.
    @Test(arguments: [WatchRequest.latest(WatchRequesterTests.agent), WatchRequesterTests.answer])
    func aReachabilityFlapNeitherResendsNorFails(_ request: WatchRequest) async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.link.parkedTypes = [request.logType]
        harness.link.replies = [.success(.answerResult(.sent))]
        let requester = harness.requester
        let pending = Task { try await requester.send(request) }
        await harness.settle { harness.clock.parked(Self.deadline) == 1 }

        requester.setReachable(false)
        requester.setReachable(true)
        await harness.settle {
            harness.clock.requested.filter { $0 == Self.deadline }.count == 2
                && harness.clock.requested.contains(Self.debounce)
        }
        harness.link.releaseParked()

        #expect(try await pending.value == .answerResult(.sent))
        #expect(harness.link.requests == [request])
    }

    /// A wrist flick shorter than the debounce window resends nothing.
    @Test func aBriefWristDownResendsNothing() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.link.parkedTypes = ["latest"]
        let requester = harness.requester
        let pending = Task { try await requester.send(.latest(Self.agent)) }
        await harness.settle { harness.clock.parked(Self.deadline) == 1 }

        requester.setActive(false)
        requester.setActive(true)
        harness.link.releaseParked()

        #expect(try await pending.value == .received)
        #expect(harness.link.requests.count == 1)
    }

    /// The phone's reply to an answer arriving while the link is down but
    /// within the window still counts: the Allow went through.
    @Test func aReplyWhilePausedStillCounts() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.link.parkedTypes = [Self.answer.logType]
        harness.link.replies = [.success(.answerResult(.sent))]
        let requester = harness.requester
        let pending = Task { try await requester.send(Self.answer) }
        await harness.settle { harness.clock.parked(Self.deadline) == 1 }

        requester.setReachable(false)
        harness.link.releaseParked()

        #expect(try await pending.value == .answerResult(.sent))
        #expect(harness.clock.parked(Self.debounce) == 1, "the window had not ended")
    }

    /// An `.answer` lost with the link (the window ended without it) is
    /// resent once under the same prompt id, and the phone's real outcome
    /// for it (here "prompt changed", its dedupe of a spent id) is shown.
    @Test func anAnswerLostInFlightIsResentAndShowsThePhonesOutcome() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.link.parkedTypes = [Self.answer.logType]
        harness.link.replies = [.success(.answerResult(.promptChanged))]
        let requester = harness.requester
        let pending = Task { try await requester.send(Self.answer) }
        await harness.settle { harness.clock.parked(Self.deadline) == 1 }

        requester.setActive(false)
        try await harness.clock.fire(Self.debounce)  // Lost; the first wait stays parked.
        harness.link.parkedTypes = []
        requester.setActive(true)
        try await harness.clock.fire(Self.debounce)  // Ready: resent.

        #expect(try await pending.value == .answerResult(.promptChanged))
        #expect(harness.link.requests == [Self.answer, Self.answer])
    }

    /// Wrist-down mid-request for longer than the window: no failure, and
    /// the request is resent once the app is active and the iPhone
    /// reachable for the window, with no deadline running in between.
    @Test func aRequestSuspendedMidFlightIsResentOnActivation() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.link.parkedTypes = ["latest"]
        let requester = harness.requester
        let pending = Task { try await requester.send(.latest(Self.agent)) }
        await harness.settle { harness.clock.parked(Self.deadline) == 1 }

        requester.setActive(false)
        await harness.settle { harness.clock.parked(Self.deadline) == 0 }
        try await harness.clock.fire(Self.debounce)  // Lost.
        await harness.settle { harness.clock.parked == 0 }
        harness.link.parkedTypes = []
        requester.setActive(true)
        try await harness.clock.fire(Self.debounce)

        #expect(try await pending.value == .received)
        #expect(harness.link.requests == [.latest(Self.agent), .latest(Self.agent)])
    }

    /// After a resend, a reply to the earlier attempt still resolves the
    /// request; the later attempt's outcome is then dropped.
    @Test func aReplyFromTheEarlierAttemptWinsAfterAResend() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.link.parkedTypes = ["latest"]
        harness.link.replies = [.success(.received), .success(.received)]
        let requester = harness.requester
        let pending = Task { try await requester.send(.latest(Self.agent)) }
        await harness.settle { harness.link.requests.count == 1 }
        requester.setActive(false)
        try await harness.clock.fire(Self.debounce)
        requester.setActive(true)
        try await harness.clock.fire(Self.debounce)
        await harness.settle { harness.link.requests.count == 2 }

        harness.link.releaseParked()

        #expect(try await pending.value == .received)
        await harness.settle { requester.droppedReplies == 1 }
    }

    /// A request made while the app is not active waits, with no deadline,
    /// and is sent once the app is active and the link ready.
    @Test func aRequestMadeWhileInactiveIsSentOnActivation() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        let requester = harness.requester
        requester.setActive(false)
        let pending = Task { try await requester.send(.refresh) }
        for _ in 0..<50 { await Task.yield() }
        #expect(harness.link.requests.isEmpty)
        #expect(harness.clock.requested.isEmpty, "nothing runs while inactive")

        requester.setActive(true)
        try await harness.clock.fire(Self.debounce)

        #expect(try await pending.value == .received)
        #expect(harness.link.requests == [.refresh])
    }

    /// Before any reachability is reported (a slow cold launch), the link
    /// is never down: requests wait, then go out once it is reported.
    @Test func unknownReachabilityNeverReadsAsDown() async throws {
        let harness = Harness(isReachable: nil)
        defer { harness.tearDown() }
        let requester = harness.requester
        let finished = Box()
        let pending = Task {
            defer { finished.value = true }
            return try await requester.send(.refresh)
        }
        try await harness.clock.fire(Self.debounce)
        #expect(!(await Self.hasFinished(finished)))
        #expect(harness.link.requests.isEmpty)

        requester.setReachable(true)
        try await harness.clock.fire(Self.debounce)

        #expect(try await pending.value == .received)
    }

    // MARK: Link-reported unreachability

    /// The link says unreachable and WatchConnectivity agrees once the
    /// window passes: the request fails as unreachable, not at the
    /// deadline, and one made then fails at once.
    @Test func anUnreachableIPhoneFailsAfterTheDebounce() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.link.replies = [.failure(WatchLinkError.unreachable)]
        harness.link.isReachable = false
        let requester = harness.requester
        let pending = Task { try await requester.send(.latest(Self.agent)) }

        try await harness.clock.fire(Self.debounce)

        await #expect(throws: WatchLinkError.unreachable) { try await pending.value }
        await #expect(throws: WatchLinkError.unreachable) { try await requester.send(.refresh) }
        #expect(harness.link.requests.count == 1, "nothing is sent while the link is down")
        #expect(WatchMessenger.reason(for: WatchLinkError.unreachable) == "iPhone not reachable")
        #expect(WatchMessenger.reason(for: WatchLinkError.noAnswer) == "iPhone didn't answer")
    }

    /// The link says unreachable while WatchConnectivity still says
    /// reachable and no callback follows: the verdict is not kept, and the
    /// request is resent once the window passes.
    @Test func aLinkErrorIsNotKeptWhileTheIPhoneStaysReachable() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.link.replies = [.failure(WatchLinkError.unreachable)]
        let requester = harness.requester
        let pending = Task { try await requester.send(.latest(Self.agent)) }

        try await harness.clock.fire(Self.debounce)

        #expect(try await pending.value == .received)
        #expect(try await requester.send(.refresh) == .received)
        #expect(harness.link.requests.count == 3)
    }

    /// Down after a link error, the requester recovers when the app next
    /// becomes active and WatchConnectivity says reachable, with no
    /// reachability callback.
    @Test func becomingActiveRereadsReachability() async throws {
        let harness = Harness()
        defer { harness.tearDown() }
        harness.link.replies = [.failure(WatchLinkError.unreachable)]
        harness.link.isReachable = false
        let requester = harness.requester
        let pending = Task { try await requester.send(.latest(Self.agent)) }
        try await harness.clock.fire(Self.debounce)
        await #expect(throws: WatchLinkError.unreachable) { try await pending.value }

        harness.link.isReachable = true
        requester.setActive(false)
        requester.setActive(true)
        try await harness.clock.fire(Self.debounce)

        #expect(try await requester.send(.refresh) == .received)
    }
}

// MARK: - Test doubles

/// A link error with no reply.
private struct LinkDown: Error {}

/// A phone link that answers from a script (`.received` once it runs out)
/// and records requests, queued transfers, and cancels. Requests of a kind
/// in `parkedTypes` wait until `releaseParked()` whether or not they are
/// cancelled, as a WatchConnectivity reply that never comes does.
@MainActor
private final class ScriptedLink: WatchMessageLink {
    /// Replies in order.
    var replies: [Result<WatchReply, any Error>] = []
    /// WatchConnectivity's live reachability, as the requester reads it.
    var isReachable = true
    /// The request kinds (`WatchRequest.logType`) that park.
    var parkedTypes: Set<String> = []
    /// Every request sent.
    private(set) var requests: [WatchRequest] = []
    /// Every recording queued, with its attempt tag.
    private(set) var transfers: [(file: WatchVoiceFile, attempt: UUID)] = []
    /// Every message whose transfer was cancelled.
    private(set) var cancelled: [UUID] = []
    /// Parked requests.
    private var parked: [CheckedContinuation<Void, Never>] = []

    func send(_ request: WatchRequest) async throws -> WatchReply {
        requests.append(request)
        if parkedTypes.contains(request.logType) {
            await withCheckedContinuation { parked.append($0) }
        }
        let reply = replies.isEmpty ? .success(.received) : replies.removeFirst()
        return try reply.get()
    }

    /// Lets every parked request go on to its scripted reply.
    func releaseParked() {
        let waiting = parked
        parked = []
        waiting.forEach { $0.resume() }
    }

    func transferVoice(fileAt url: URL, file: WatchVoiceFile, attempt: UUID) throws {
        transfers.append((file, attempt))
    }

    func cancelVoiceTransfer(_ messageID: UUID) {
        cancelled.append(messageID)
    }
}

/// A delivery clock the test fires: each wait is recorded and parked until
/// `fire()`, and a cancelled wait throws at once. `fire()` returns only once
/// the woken waiters ran on, as time really passing would let them before
/// the test's next step. `now()` moves only when the test advances
/// `elapsed`.
@MainActor
private final class DeliveryClock {
    /// Every duration asked for.
    private(set) var requested: [Duration] = []
    /// How far the test moved `now()`.
    var elapsed: Duration = .zero
    /// Parked waits, with the duration each asked for.
    private var waiters: [UUID: (duration: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]
    /// Waits cancelled before they parked.
    private var cancelledEarly: Set<UUID> = []
    /// Fired waits whose waiter has run on past `sleep`.
    private var woken: Set<UUID> = []
    /// Whether the test ended; later waits throw at once.
    private var isClosed = false
    /// Where `now()` starts.
    private let start = ContinuousClock.now

    /// How many waits are parked.
    var parked: Int { waiters.count }

    /// How many waits of `duration` are parked.
    func parked(_ duration: Duration) -> Int {
        waiters.values.filter { $0.duration == duration }.count
    }

    /// The test's instant.
    func now() -> ContinuousClock.Instant { start + elapsed }

    /// Parks until `fire()` or cancellation.
    func sleep(_ duration: Duration) async throws {
        requested.append(duration)
        if isClosed { throw CancellationError() }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if cancelledEarly.remove(id) != nil {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = (duration, continuation)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
        // The caller runs on at once, on the main actor, until it next
        // suspends, so `fire()` sees this only after that.
        woken.insert(id)
    }

    /// Ends every parked wait of `duration` (every parked wait when nil),
    /// once at least one is parked, and lets the woken waiters run on;
    /// fails the test when none parks.
    func fire(_ duration: Duration? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        func matching() -> [UUID] {
            waiters.filter { duration == nil || $0.value.duration == duration }.map(\.key)
        }
        let parkDeadline = ContinuousClock.now + .waitCeiling
        while matching().isEmpty, ContinuousClock.now < parkDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let ids = matching()
        try #require(!ids.isEmpty, "a wait should be parked", sourceLocation: sourceLocation)
        for id in ids { waiters.removeValue(forKey: id)?.continuation.resume() }
        let wakeDeadline = ContinuousClock.now + .waitCeiling
        while !woken.isSuperset(of: ids), ContinuousClock.now < wakeDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(woken.isSuperset(of: ids), "a fired wait should run on", sourceLocation: sourceLocation)
        woken.subtract(ids)
    }

    /// Ends the test: every parked and later wait throws.
    func cancelAll() {
        isClosed = true
        let parked = waiters.values
        waiters.removeAll()
        for waiter in parked { waiter.continuation.resume(throwing: CancellationError()) }
    }

    /// Throws out of a cancelled wait.
    private func cancel(_ id: UUID) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.continuation.resume(throwing: CancellationError())
        } else {
            cancelledEarly.insert(id)
        }
    }
}
