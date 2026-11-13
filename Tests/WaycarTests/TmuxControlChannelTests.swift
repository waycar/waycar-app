import Foundation
import Testing

@testable import Waycar

@Suite("tmux control channel", .timeLimit(.minutes(1)))
struct TmuxControlChannelTests {
    /// The notifications `TmuxTranscripts.attach` carries after its reply.
    private static let attachNotifications: [TmuxControlEvent] = [
        .notification(.sessionChanged(sessionID: "$0", name: "alpha")),
        .notification(.unlinkedWindowAdd(windowID: "@2")),
        .notification(.sessionsChanged),
        .notification(.unlinkedWindowRenamed(windowID: "@2", name: "tmux")),
        .notification(.unlinkedWindowClose(windowID: "@2")),
        .notification(.sessionsChanged),
        .notification(.unlinkedWindowRenamed(windowID: "@1", name: "zsh")),
    ]

    private func makeChannel(
        _ fake: FakeHostControlChannel,
        requestTimeout: Duration = .seconds(30)
    ) -> TmuxControlChannel {
        TmuxControlChannel(requestTimeout: requestTimeout, open: { fake })
    }

    /// A channel past the attach reply of `TmuxTranscripts.attach`.
    private func started(
        _ fake: FakeHostControlChannel,
        requestTimeout: Duration = .seconds(30)
    ) async throws -> TmuxControlChannel {
        fake.feed(TmuxTranscripts.data(TmuxTranscripts.attach))
        let channel = makeChannel(fake, requestTimeout: requestTimeout)
        try await channel.start()
        return channel
    }

    /// Every event up to and including `.ended`.
    private func allEvents(_ channel: TmuxControlChannel) async -> [TmuxControlEvent] {
        var events: [TmuxControlEvent] = []
        for await event in channel.events {
            events.append(event)
        }
        return events
    }

    private func reply(_ number: Int, _ lines: [String], error: Bool = false) -> TmuxReply {
        TmuxReply(commandNumber: number, flags: 1, lines: lines, isError: error)
    }

    private func block(_ number: Int, _ lines: [String], error: Bool = false) -> [String] {
        let guardFields = "1790880000 \(number) 1"
        return ["%begin \(guardFields)"] + lines + ["\(error ? "%error" : "%end") \(guardFields)"]
    }

    private func subscription(_ name: String, _ value: String) -> String {
        "%subscription-changed \(name) $0 - - - : \(value)"
    }

    private func change(_ name: String, _ value: String) -> TmuxControlEvent {
        .notification(.subscriptionChanged(TmuxSubscriptionChange(
            name: name, sessionID: "$0", windowID: nil, windowIndex: nil, paneID: nil, value: value)))
    }

    // MARK: Start

    @Test("start returns after the attach reply; its notifications are events")
    func startSucceeds() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)
        #expect(await channel.isOpen)

        await channel.close()
        #expect(await allEvents(channel) == Self.attachNotifications + [.ended(.closed)])
    }

    @Test("a %config-error inside the attach reply does not fail start")
    func startIgnoresConfigErrors() async throws {
        let fake = FakeHostControlChannel()
        fake.feed(TmuxTranscripts.data(TmuxTranscripts.configError))
        let channel = makeChannel(fake)
        try await channel.start()
        #expect(await channel.isOpen)

        await channel.close()
        let events = await allEvents(channel)
        #expect(events.first == .notification(.configError(
            "/tmp/wc-tmuxcore-5d94e5/bad.conf:2: unknown command: bogus-command")))
    }

    @Test("an attach error reply fails start with tmux's text and ends the channel")
    func startFailsOnNoSessions() async throws {
        let fake = FakeHostControlChannel()
        fake.feed(TmuxTranscripts.data(TmuxTranscripts.noSessions))
        let channel = makeChannel(fake)

        await #expect(throws: HerdrAPIError(code: TmuxErrors.genericCode, message: "no sessions")) {
            try await channel.start()
        }
        #expect(await !channel.isOpen)
        #expect(await allEvents(channel) == [.ended(.lost("tmux attach failed: no sessions"))])
        await fake.waitUntilClosed()
        await #expect(throws: TransportError.self) { _ = try await channel.send(["display -p x"]) }
    }

    @Test("start fails with the open error when the channel cannot open")
    func startFailsWhenOpenFails() async throws {
        let failure = TransportError.sshUnreachable(detail: "refused")
        let channel = TmuxControlChannel(requestTimeout: .seconds(30), open: { throw failure })

        await #expect(throws: failure) { try await channel.start() }
        #expect(await !channel.isOpen)
        let events = await allEvents(channel)
        #expect(events.count == 1)
        guard case .ended(.lost) = events.first else {
            Issue.record("expected .ended(.lost), got \(events)")
            return
        }
    }

    // MARK: Replies

    @Test("one line's replies come back in order across chunk boundaries")
    func repliesAcrossChunks() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)
        let commands = [
            "display -p '#{version} #{client_flags}'",
            "list-sessions",
            "list-windows -a",
            "list-panes -a",
        ]
        let pending = Task { try await channel.send(commands) }

        #expect(await fake.waitForWrites(1) == [commands.joined(separator: " ; ") + "\n"])
        fake.feed(TmuxTranscripts.data(TmuxTranscripts.startup), chunkSize: 7)

        let replies = try await pending.value
        #expect(replies.map(\.commandNumber) == [310, 311, 312, 313])
        #expect(replies.allSatisfy { !$0.isError && $0.flags == 1 })
        #expect(replies[0].lines == ["3.7c attached,focused,control-mode,no-detach-on-destroy,no-output,UTF-8"])
        #expect(replies[3].lines == [
            "\u{241E}%0\u{241F}@0\u{241F}$0\u{241F}zsh", "\u{241E}%1\u{241F}@1\u{241F}$1\u{241F}zsh",
        ])
        await channel.close()
    }

    @Test("lines are answered first in, first out; a failing first command ends its line")
    func errorsTranscript() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)

        let first = Task { try await channel.send(["kill-pane -t %999"]) }
        _ = await fake.waitForWrites(1)
        let second = Task { try await channel.send(["display -p 'ok'"]) }
        _ = await fake.waitForWrites(2)
        let third = Task { try await channel.send(["kill-window -t @999", "kill-session -t '$999'"]) }
        #expect(await fake.waitForWrites(3) == [
            "kill-pane -t %999\n",
            "display -p 'ok'\n",
            "kill-window -t @999 ; kill-session -t '$999'\n",
        ])
        fake.feed(TmuxTranscripts.data(TmuxTranscripts.errors))

        #expect(try await first.value == [reply(324, ["can't find pane: %999"], error: true)])
        #expect(try await second.value == [reply(325, ["ok"])])
        #expect(try await third.value == [reply(326, ["can't find window: @999"], error: true)])
        #expect(await channel.isOpen)
        await channel.close()
    }

    @Test("an error in the middle of a 3-command line completes it; the next line gets its own reply")
    func errorEndsLineEarly() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)

        let line = Task { try await channel.send(["display -p one", "kill-pane -t %9", "display -p three"]) }
        _ = await fake.waitForWrites(1)
        fake.feed(lines: block(400, ["one"]) + block(401, ["can't find pane: %9"], error: true))
        #expect(try await line.value == [reply(400, ["one"]), reply(401, ["can't find pane: %9"], error: true)])

        let next = Task { try await channel.send(["display -p next"]) }
        _ = await fake.waitForWrites(2)
        fake.feed(lines: block(402, ["next"]))
        #expect(try await next.value == [reply(402, ["next"])])
        await channel.close()
    }

    @Test("a parse error answers a whole line with one block")
    func parseErrorAnswersLine() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)

        let line = Task { try await channel.send(["kill-pane -t %999", "bogus-command"]) }
        _ = await fake.waitForWrites(1)
        fake.feed(TmuxTranscripts.data(TmuxTranscripts.parseError))
        #expect(try await line.value == [reply(327, ["parse error: unknown command: bogus-command"], error: true)])
        #expect(await channel.isOpen)
        await channel.close()
    }

    @Test("notifications between blocks are events; flags-0 blocks after start are ignored")
    func notificationsInterleaved() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)

        let line = Task { try await channel.send(["display -p a", "display -p b"]) }
        _ = await fake.waitForWrites(1)
        fake.feed(lines: block(500, ["a"])
            + ["%window-add @7", "%begin 1790880000 501 0", "%end 1790880000 501 0", "%sessions-changed"]
            + block(502, ["b"])
            + ["%window-close @7"])
        #expect(try await line.value == [reply(500, ["a"]), reply(502, ["b"])])

        await channel.close()
        #expect(await allEvents(channel) == Self.attachNotifications + [
            .notification(.windowAdd(windowID: "@7")),
            .notification(.sessionsChanged),
            .notification(.windowClose(windowID: "@7")),
            .ended(.closed),
        ])
    }

    @Test("a lagging consumer gets the latest of each subscription in a run, nothing else merged")
    func subscriptionChangesCoalesce() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)

        let line = Task { try await channel.send(["display -p x"]) }
        _ = await fake.waitForWrites(1)
        fake.feed(lines: [
            subscription("wc-topo", "1"),
            subscription("wc-status", "1"),
            subscription("wc-topo", "2"),
            subscription("wc-status", "2"),
            "%window-add @9",
            subscription("wc-topo", "3"),
            subscription("wc-topo", "4"),
        ] + block(700, ["x"]))
        _ = try await line.value

        await channel.close()
        #expect(await allEvents(channel) == Self.attachNotifications + [
            change("wc-topo", "2"),
            change("wc-status", "2"),
            .notification(.windowAdd(windowID: "@9")),
            change("wc-topo", "4"),
            .ended(.closed),
        ])
    }

    @Test("a read timing out with no data is an idle tick, not an end")
    func readTimeoutKeepsReading() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)

        fake.timeOutReads(3)
        let line = Task { try await channel.send(["display -p x"]) }
        _ = await fake.waitForWrites(1)
        fake.feed(lines: block(600, ["x"]))

        #expect(try await line.value == [reply(600, ["x"])])
        #expect(fake.timedOutReads == 3)
        #expect(await channel.isOpen)
        #expect(!fake.isClosed)
        await channel.close()
    }

    // MARK: Ending

    @Test("%exit then EOF ends with .exited and fails pending and later sends")
    func exitThenEOF() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)
        let expected = TransportError.channelFailed(detail: "tmux control mode exited")

        let pending = Task { try await channel.send(["display -p x"]) }
        _ = await fake.waitForWrites(1)
        fake.feed(TmuxTranscripts.data(TmuxTranscripts.killServer))
        fake.finishOutput()

        await #expect(throws: expected) { _ = try await pending.value }
        let events = await allEvents(channel)
        #expect(Array(events.suffix(2)) == [.notification(.exit(reason: nil)), .ended(.exited(reason: nil))])
        #expect(await !channel.isOpen)
        await #expect(throws: expected) { _ = try await channel.send(["display -p y"]) }
        await fake.waitUntilClosed()
    }

    @Test("%exit with a reason carries it to .exited")
    func exitWithReason() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)
        fake.feed(lines: ["%exit detached"])
        fake.finishOutput()

        #expect(await allEvents(channel).last == .ended(.exited(reason: "detached")))
        await #expect(throws: TransportError.channelFailed(detail: "tmux control mode exited: detached")) {
            _ = try await channel.send(["display -p y"])
        }
    }

    @Test("EOF without %exit ends with .lost")
    func eofWithoutExit() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)
        let expected = TransportError.channelFailed(
            detail: "tmux control channel lost: tmux closed the control channel")

        let pending = Task { try await channel.send(["display -p x"]) }
        _ = await fake.waitForWrites(1)
        fake.finishOutput()

        await #expect(throws: expected) { _ = try await pending.value }
        #expect(await allEvents(channel).last == .ended(.lost("tmux closed the control channel")))
        #expect(await !channel.isOpen)
        await #expect(throws: expected) { _ = try await channel.send(["display -p y"]) }
        await fake.waitUntilClosed()
    }

    @Test("a read error without %exit ends with .lost")
    func readErrorEnds() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)
        let pending = Task { try await channel.send(["display -p x"]) }
        _ = await fake.waitForWrites(1)
        fake.failRead(.channelFailed(detail: "boom"))

        do {
            _ = try await pending.value
            Issue.record("the pending send succeeded")
        } catch TransportError.channelFailed {
        } catch {
            Issue.record("unexpected \(error)")
        }
        guard case .ended(.lost) = await allEvents(channel).last else {
            Issue.record("expected .ended(.lost)")
            return
        }
    }

    @Test("a timed-out line ends the channel, failing every pending line with .timedOut")
    func timeoutEndsChannel() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake, requestTimeout: .milliseconds(500))

        let first = Task { try await channel.send(["display -p one"]) }
        let second = Task { try await channel.send(["display -p two"]) }
        await #expect(throws: TransportError.timedOut) { _ = try await first.value }
        await #expect(throws: TransportError.timedOut) { _ = try await second.value }

        #expect(await allEvents(channel).last == .ended(.lost("timed out")))
        await fake.waitUntilClosed()
        #expect(await !channel.isOpen)
        await #expect(throws: TransportError.channelFailed(detail: "tmux control channel lost: timed out")) {
            _ = try await channel.send(["display -p three"])
        }
    }

    @Test("a cancelled send drops its replies; the channel stays open and the next line gets its own")
    func cancellationKeepsChannel() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)

        let cancelled = Task { try await channel.send(["display -p one", "display -p two"]) }
        _ = await fake.waitForWrites(1)
        cancelled.cancel()
        await #expect(throws: TransportError.cancelled) { _ = try await cancelled.value }
        #expect(await channel.isOpen)
        // Written: its placeholder stays to consume its replies.
        #expect(await channel.pendingLineCountForTesting == 1)

        let next = Task { try await channel.send(["display -p next"]) }
        _ = await fake.waitForWrites(2)
        fake.feed(lines: block(800, ["one"]) + block(801, ["two"]) + block(802, ["next"]))

        #expect(try await next.value == [reply(802, ["next"])])
        #expect(await channel.isOpen)
        #expect(!fake.isClosed)
        // Never re-sent.
        #expect(fake.writtenLines == ["display -p one ; display -p two\n", "display -p next\n"])
        await channel.close()
        #expect(await allEvents(channel).last == .ended(.closed))
    }

    @Test("a send cancelled while queued behind a slow write is withdrawn and never written")
    func queuedCancellationIsWithdrawn() async throws {
        let fake = FakeHostControlChannel()
        let held = WriteHoldingChannel(fake)
        fake.feed(TmuxTranscripts.data(TmuxTranscripts.attach))
        let channel = TmuxControlChannel(requestTimeout: .seconds(30), open: { held })
        try await channel.start()

        await held.gate.hold()
        let head = Task { try await channel.send(["display -p head"]) }
        await held.gate.waitForParkedWrites(1)
        let queued = Task { try await channel.send(["display -p queued"]) }
        try await waitUntilPending(channel, count: 2)
        queued.cancel()
        await #expect(throws: TransportError.cancelled) { _ = try await queued.value }
        // Withdrawn: no placeholder, so no timer of its own can end the channel.
        #expect(await channel.pendingLineCountForTesting == 1)

        await held.gate.release()
        _ = await fake.waitForWrites(1)
        fake.feed(lines: block(900, ["head"]))
        #expect(try await head.value == [reply(900, ["head"])])

        let next = Task { try await channel.send(["display -p next"]) }
        _ = await fake.waitForWrites(2)
        fake.feed(lines: block(901, ["next"]))
        #expect(try await next.value == [reply(901, ["next"])])
        #expect(fake.writtenLines == ["display -p head\n", "display -p next\n"])
        #expect(await channel.isOpen)
        await channel.close()
    }

    private func waitUntilPending(_ channel: TmuxControlChannel, count: Int) async throws {
        let deadline = ContinuousClock.now + .waitCeiling
        while await channel.pendingLineCountForTesting < count {
            guard ContinuousClock.now < deadline else {
                Issue.record("never had \(count) pending lines")
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("a cancelled line whose replies never come still times the channel out")
    func cancelledLineStillTimesOut() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake, requestTimeout: .milliseconds(500))

        let cancelled = Task { try await channel.send(["send-keys -t %1 Enter"]) }
        _ = await fake.waitForWrites(1)
        cancelled.cancel()
        await #expect(throws: TransportError.cancelled) { _ = try await cancelled.value }

        #expect(await allEvents(channel).last == .ended(.lost("timed out")))
        await fake.waitUntilClosed()
        #expect(fake.writtenLines == ["send-keys -t %1 Enter\n"])
    }

    // MARK: Startup and end (TMUX-09)

    @Test("a send before start is refused, and so is a second start")
    func startsOnceAndSendsOnlyWhenOpen() async throws {
        let fake = FakeHostControlChannel()
        let channel = makeChannel(fake)
        await #expect(throws: TransportError.channelFailed(detail: "the tmux control channel is not open")) {
            _ = try await channel.send(["display -p x"])
        }
        #expect(await channel.end == nil)
        fake.feed(TmuxTranscripts.data(TmuxTranscripts.attach))
        try await channel.start()
        await #expect(throws: TransportError.channelFailed(
            detail: "the tmux control channel was already started")) {
            try await channel.start()
        }
        #expect(await channel.isOpen)
        #expect(await channel.end == nil)
        await channel.close()
        #expect(await channel.end == .closed)
    }

    @Test("start times out without the attach reply and ends the channel lost")
    func startTimesOut() async throws {
        let fake = FakeHostControlChannel()
        let channel = makeChannel(fake, requestTimeout: .milliseconds(300))
        await #expect(throws: TransportError.timedOut) { try await channel.start() }
        #expect(await allEvents(channel) == [.ended(.lost("timed out"))])
        await fake.waitUntilClosed()
        #expect(await channel.end == .lost("timed out"))
    }

    @Test("a start cancelled while it opens ends the channel lost and closes what opened")
    func startCancelledWhileOpening() async throws {
        let fake = FakeHostControlChannel()
        let gate = OpenGate()
        let channel = TmuxControlChannel(requestTimeout: .seconds(30)) {
            await gate.pass()
            return fake
        }
        let start = Task { try await channel.start() }
        await gate.waitUntilOpening()
        start.cancel()
        await gate.release()
        await #expect(throws: TransportError.cancelled) { try await start.value }
        #expect(await allEvents(channel) == [.ended(.lost("cancelled"))])
        await fake.waitUntilClosed()
    }

    @Test("close while the channel opens ends it closed and closes what opened")
    func closeWhileOpening() async throws {
        let fake = FakeHostControlChannel()
        let gate = OpenGate()
        let channel = TmuxControlChannel(requestTimeout: .seconds(30)) {
            await gate.pass()
            return fake
        }
        let start = Task { try await channel.start() }
        await gate.waitUntilOpening()
        await channel.close()
        await gate.release()
        await #expect(throws: TransportError.cancelled) { try await start.value }
        #expect(await allEvents(channel) == [.ended(.closed)])
        await fake.waitUntilClosed()
        #expect(await channel.end == .closed)
    }

    @Test("%exit then a read error is still an orderly exit")
    func exitThenReadError() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)
        fake.feed(lines: ["%exit"])
        fake.failRead(.channelFailed(detail: "boom"))
        #expect(await allEvents(channel).last == .ended(.exited(reason: nil)))
        #expect(await channel.end == .exited(reason: nil))
    }

    @Test("a write that times out ends the channel lost, failing its line with .timedOut")
    func writeTimeoutEnds() async throws {
        let fake = FakeHostControlChannel()
        fake.feed(TmuxTranscripts.data(TmuxTranscripts.attach))
        let failing = WriteFailingChannel(fake, error: .timedOut)
        let channel = TmuxControlChannel(requestTimeout: .seconds(30), open: { failing })
        try await channel.start()
        await #expect(throws: TransportError.timedOut) { _ = try await channel.send(["display -p x"]) }
        #expect(await allEvents(channel).last == .ended(.lost("timed out")))
        await fake.waitUntilClosed()
    }

    @Test("a write that fails ends the channel lost, failing its line and later ones")
    func writeFailureEnds() async throws {
        let fake = FakeHostControlChannel()
        fake.feed(TmuxTranscripts.data(TmuxTranscripts.attach))
        let failing = WriteFailingChannel(fake, error: .channelFailed(detail: "broken pipe"))
        let channel = TmuxControlChannel(requestTimeout: .seconds(30), open: { failing })
        try await channel.start()
        do {
            _ = try await channel.send(["display -p x"])
            Issue.record("a send whose write failed succeeded")
        } catch TransportError.channelFailed {
        } catch {
            Issue.record("unexpected \(error)")
        }
        guard case .ended(.lost) = await allEvents(channel).last else {
            Issue.record("expected .ended(.lost)")
            return
        }
        await #expect(throws: TransportError.self) { _ = try await channel.send(["display -p y"]) }
        await fake.waitUntilClosed()
    }

    // MARK: Pending lines (TMUX-10)

    @Test("a reply with no line pending is dropped; the next line gets its own")
    func strayReplyIsDropped() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)
        var events = channel.events.makeAsyncIterator()
        fake.feed(lines: block(950, ["stray"]) + ["%window-add @7"])
        while let event = await events.next(), event != .notification(.windowAdd(windowID: "@7")) {}

        let line = Task { try await channel.send(["display -p mine"]) }
        _ = await fake.waitForWrites(1)
        fake.feed(lines: block(951, ["mine"]))
        #expect(try await line.value == [reply(951, ["mine"])])
        #expect(await channel.pendingLineCountForTesting == 0)
        await channel.close()
    }

    @Test("a cancelled written line answered by an error is consumed; the next line gets its own")
    func cancelledLineEndedByAnError() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)

        let cancelled = Task { try await channel.send(["kill-pane -t %9", "display -p two"]) }
        _ = await fake.waitForWrites(1)
        cancelled.cancel()
        await #expect(throws: TransportError.cancelled) { _ = try await cancelled.value }
        let next = Task { try await channel.send(["display -p next"]) }
        _ = await fake.waitForWrites(2)
        fake.feed(lines: block(960, ["can't find pane: %9"], error: true) + block(961, ["next"]))
        #expect(try await next.value == [reply(961, ["next"])])
        #expect(await channel.pendingLineCountForTesting == 0)
        await channel.close()
    }

    @Test("close fails pending sends with .cancelled, ends events once, and is idempotent")
    func closeIsIdempotent() async throws {
        let fake = FakeHostControlChannel()
        let channel = try await started(fake)

        let pending = Task { try await channel.send(["display -p x"]) }
        _ = await fake.waitForWrites(1)
        await channel.close()
        await channel.close()

        await #expect(throws: TransportError.cancelled) { _ = try await pending.value }
        let events = await allEvents(channel)
        #expect(events.filter { if case .ended = $0 { true } else { false } } == [.ended(.closed)])
        #expect(events.last == .ended(.closed))
        #expect(fake.isClosed)
        #expect(await !channel.isOpen)
        await #expect(throws: TransportError.cancelled) { _ = try await channel.send(["display -p y"]) }
    }
}

/// A fake control channel whose every write fails with `error`.
private final class WriteFailingChannel: HostControlChannel {
    let inner: FakeHostControlChannel
    let error: TransportError

    init(_ inner: FakeHostControlChannel, error: TransportError) {
        self.inner = inner
        self.error = error
    }

    func write(_ data: Data, timeout: Duration) async throws {
        throw error
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        try await inner.read(maximumBytes: maximumBytes, timeout: timeout)
    }

    func exitStatus(timeout: Duration) async throws -> Int32 {
        try await inner.exitStatus(timeout: timeout)
    }

    func standardErrorTail() async -> String {
        await inner.standardErrorTail()
    }

    func close() async {
        await inner.close()
    }
}

/// Holds an `open` closure until released, and says when one is waiting.
private actor OpenGate {
    private var opening = false
    private var released = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var openingWaiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        opening = true
        for waiter in openingWaiters { waiter.resume() }
        openingWaiters = []
        guard !released else { return }
        await withCheckedContinuation { parked.append($0) }
    }

    func waitUntilOpening() async {
        guard !opening else { return }
        await withCheckedContinuation { openingWaiters.append($0) }
    }

    func release() {
        released = true
        for continuation in parked { continuation.resume() }
        parked = []
    }
}

/// A fake control channel whose writes park while its gate is held, as an
/// SSH write does under backpressure: later lines stay in the writer's queue.
private final class WriteHoldingChannel: HostControlChannel {
    let inner: FakeHostControlChannel
    let gate = WriteGate()

    init(_ inner: FakeHostControlChannel) {
        self.inner = inner
    }

    func write(_ data: Data, timeout: Duration) async throws {
        await gate.pass()
        try await inner.write(data, timeout: timeout)
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        try await inner.read(maximumBytes: maximumBytes, timeout: timeout)
    }

    func exitStatus(timeout: Duration) async throws -> Int32 {
        try await inner.exitStatus(timeout: timeout)
    }

    func standardErrorTail() async -> String {
        await inner.standardErrorTail()
    }

    func close() async {
        await inner.close()
    }
}

private actor WriteGate {
    private var held = false
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var parkedWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func hold() {
        held = true
    }

    func release() {
        held = false
        let released = parked
        parked = []
        for continuation in released { continuation.resume() }
    }

    func pass() async {
        guard held else { return }
        await withCheckedContinuation { continuation in
            parked.append(continuation)
            let ready = parkedWaiters.filter { $0.count <= parked.count }
            parkedWaiters.removeAll { $0.count <= parked.count }
            for waiter in ready { waiter.continuation.resume() }
        }
    }

    func waitForParkedWrites(_ count: Int) async {
        guard parked.count < count else { return }
        await withCheckedContinuation { parkedWaiters.append((count, $0)) }
    }
}
