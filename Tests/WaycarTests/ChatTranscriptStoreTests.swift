import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Chat transcript store")
struct ChatTranscriptStoreTests {
    @Test func fullReadThenIncrementalReadsMergeByIDWithoutDuplicates() async throws {
        let host = TranscriptHost()
        let first: [ChatTranscriptMessage] = [.user("u1", "why is CI red?"), .assistant("a1", "Flaky test.")]
        let later: [ChatTranscriptMessage] = [
            .assistant("a1", "Flaky test."), .user("u2", "fix it"), .assistant("a2", "Fixed."),
        ]
        host.respond = { after in
            ChatTranscriptSnapshot(header: .ok(), messages: after == nil ? first : later)
        }
        let (updates, continuation) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        let store = host.makeStore(initialStatus: .idle, statusUpdates: updates)

        store.start()
        try await waitUntil("full read lands") { store.messages.count == 2 }
        #expect(host.afters == [nil])
        #expect(store.availability == .ready)

        continuation.yield(.init(status: .done, liveUpdatesAvailable: true))
        try await waitUntil("status change reads after the last id") { store.messages.count == 4 }
        #expect(host.afters == [nil, "a1"])
        #expect(store.messages.map(\.id) == ["u1", "a1", "u2", "a2"])
        store.stop()
    }

    @Test func aFullReadOnRestartReplacesTheList() async throws {
        let host = TranscriptHost()
        host.respond = { _ in ChatTranscriptSnapshot(header: .ok(), messages: [.user("u1", "a"), .user("u2", "b")]) }
        let store = host.makeStore(initialStatus: .idle)
        store.start()
        try await waitUntil("first read") { store.messages.count == 2 }
        store.stop()

        host.respond = { _ in ChatTranscriptSnapshot(header: .ok(), messages: [.user("u9", "after /clear")]) }
        store.start()
        try await waitUntil("restart replaces") { store.messages.map(\.id) == ["u9"] }
        #expect(host.afters == [nil, nil])
        store.stop()
    }

    @Test func pollsOnlyWhileWorkingOrTurnOpenAndNeverAfterStop() async throws {
        let host = TranscriptHost()
        var turnOpen = false
        host.respond = { _ in ChatTranscriptSnapshot(header: .ok(turnOpen: turnOpen), messages: []) }
        let (updates, continuation) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        let store = host.makeStore(
            initialStatus: .working, statusUpdates: updates, pollInterval: .milliseconds(20))

        store.start()
        try await waitUntil("working polls") { host.afters.count >= 4 }

        continuation.yield(.init(status: .idle, liveUpdatesAvailable: true))
        try await waitUntil("idle status lands") { store.status == .idle }
        try await Task.sleep(for: .milliseconds(60))
        let idleCount = host.afters.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(host.afters.count == idleCount, "an idle Agent with no open turn is not polled")

        turnOpen = true
        await store.refresh()
        #expect(store.isTurnOpen)
        try await waitUntil("an open turn polls") { host.afters.count >= idleCount + 4 }

        store.stop()
        let stoppedCount = host.afters.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(host.afters.count == stoppedCount, "stop ends polling")
    }

    @Test func blockedStatusKeepsTheLastTwelveNonEmptyScreenLines() async throws {
        let host = TranscriptHost()
        let lines = (1...15).map { "line \($0)" }
        host.screen = lines.map { "\($0)   \n\n  \t\n" }.joined() + "\n\n"
        let (updates, continuation) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        let store = host.makeStore(initialStatus: .working, statusUpdates: updates)
        store.start()
        #expect(store.blockedScreen == nil)

        continuation.yield(.init(status: .blocked, liveUpdatesAvailable: true))
        try await waitUntil("screen fetched") { store.blockedScreen != nil }
        #expect(store.blockedScreen == lines.suffix(12).joined(separator: "\n"))
        #expect(!store.showsTypingIndicator)

        continuation.yield(.init(status: .working, liveUpdatesAvailable: true))
        try await waitUntil("leaving Blocked clears the screen") { store.status == .working }
        #expect(store.blockedScreen == nil)
        store.stop()
    }

    @Test func allowAndCancelSendTheirKeyAndWaitForTheNextStatus() async throws {
        let host = TranscriptHost()
        host.screen = "Run npm test?\n❯ 1. Yes\n  2. No"
        let (updates, continuation) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        let store = host.makeStore(initialStatus: .blocked, statusUpdates: updates)
        store.start()
        try await waitUntil("prompt shown") { store.canAnswerBlocked }

        await store.allow()
        #expect(host.sentKeys == [["enter"]])
        #expect(store.isAnsweringBlocked)
        await store.cancel()
        #expect(host.sentKeys == [["enter"]], "a second answer waits for the next status")

        continuation.yield(.init(status: .working, liveUpdatesAvailable: true))
        try await waitUntil("status change re-enables") { !store.isAnsweringBlocked }
        continuation.yield(.init(status: .blocked, liveUpdatesAvailable: true))
        try await waitUntil("blocked again, prompt shown") { store.canAnswerBlocked }

        await store.cancel()
        #expect(host.sentKeys == [["enter"], ["esc"]])
        #expect(store.isAnsweringBlocked)

        continuation.yield(.init(status: .working, liveUpdatesAvailable: true))
        try await waitUntil("working") { store.status == .working }
        continuation.yield(.init(status: .blocked, liveUpdatesAvailable: true))
        try await waitUntil("blocked once more, prompt shown") { store.canAnswerBlocked }
        host.keyFailure = TransportError.cancelled
        await store.allow()
        #expect(host.sentKeys.count == 3)
        #expect(!store.isAnsweringBlocked, "a failed send can be retried")
        store.stop()
    }

    @Test(arguments: [true, false])
    func allowAndCancelWaitForAPromptOnScreen(readFails: Bool) async throws {
        let host = TranscriptHost()
        if readFails {
            host.screenFailure = TransportError.timedOut
        } else {
            host.screen = "  \n\n"
        }
        let store = host.makeStore(initialStatus: .blocked)
        store.start()
        try await waitUntil("the card says the prompt is unreadable") { store.blockedScreenUnreadable }
        #expect(store.blockedScreen == nil)
        #expect(!store.canAnswerBlocked)
        await store.allow()
        await store.cancel()
        #expect(host.sentKeys.isEmpty, "Enter or Esc never answers a prompt the user hasn't seen")

        host.screenFailure = nil
        host.screen = "Delete build/?\n❯ 1. Yes\n  2. No"
        store.retryBlockedScreen()
        try await waitUntil("Retry reads the prompt") { store.canAnswerBlocked }
        #expect(!store.blockedScreenUnreadable)
        await store.allow()
        #expect(host.sentKeys == [["enter"]])
        store.stop()
    }

    /// The Console republishes the current status on every rebuild: a
    /// repeat reads nothing and leaves an answer in progress alone.
    @Test func aRepeatedStatusUpdateReadsNothing() async throws {
        let host = TranscriptHost()
        host.screen = "Edit Package.swift?\n❯ Yes"
        let (updates, continuation) = AsyncStream.makeStream(of: ConsoleStore.AgentStatusUpdate.self)
        let store = host.makeStore(initialStatus: .blocked, statusUpdates: updates)
        store.start()
        try await waitUntil("prompt shown, transcript read") {
            store.canAnswerBlocked && !host.afters.isEmpty
        }
        await store.allow()
        #expect(host.sentKeys == [["enter"]])

        // The answer moved the screen on while herdr still says Blocked.
        host.screen = "Editing Package.swift…"
        let reads = host.screenReads
        let transcriptReads = host.afters.count
        for _ in 0..<5 {
            continuation.yield(.init(status: .blocked, liveUpdatesAvailable: true))
        }
        try await Task.sleep(for: .milliseconds(80))
        #expect(host.screenReads == reads)
        #expect(host.afters.count == transcriptReads)
        #expect(store.isAnsweringBlocked, "Cancel must not reopen on a screen nobody asked about")
        #expect(store.blockedScreen == "Edit Package.swift?\n❯ Yes")
        store.stop()
    }

    @Test func allowSendsNothingWhenThePromptChangedAndEnterWhenItIsStillOnScreen() async throws {
        let host = TranscriptHost()
        host.screen = "Run npm test?\n❯ 1. Yes\n  2. No"
        let store = host.makeStore(initialStatus: .blocked)
        store.start()
        try await waitUntil("prompt shown") { store.canAnswerBlocked }

        // Answered on the Mac, and the next question is up.
        host.screen = "Delete build/?\n❯ 1. Yes\n  2. No"
        await store.allow()
        #expect(host.sentKeys.isEmpty, "Enter never answers a prompt the user hasn't seen")
        #expect(store.blockedScreen == "Delete build/?\n❯ 1. Yes\n  2. No")
        #expect(!store.blockedScreenUnreadable)
        #expect(store.canAnswerBlocked, "the new prompt can be answered")

        // Trailing whitespace and blank lines are not a different prompt.
        host.screen = "Delete build/?   \n\n❯ 1. Yes\n  2. No\n\n"
        await store.allow()
        #expect(host.sentKeys == [["enter"]])
        #expect(store.isAnsweringBlocked)
        store.stop()
    }

    @Test func anAnswerWhoseScreenReadFailsSendsNothing() async throws {
        let host = TranscriptHost()
        host.screen = "Run npm test?\n❯ 1. Yes\n  2. No"
        let store = host.makeStore(initialStatus: .blocked)
        store.start()
        try await waitUntil("prompt shown") { store.canAnswerBlocked }

        host.screenFailure = TransportError.timedOut
        await store.cancel()
        #expect(host.sentKeys.isEmpty)
        #expect(store.blockedScreen == nil)
        #expect(store.blockedScreenUnreadable)
        #expect(!store.canAnswerBlocked)
        #expect(!store.isAnsweringBlocked)
        store.stop()
    }

    @Test(arguments: [false, true])
    func anAnswerIsCheckedAgainShortlyAfter(promptChanges: Bool) async throws {
        let host = TranscriptHost()
        host.screen = "Allow edit?\n❯ Yes"
        let store = host.makeStore(initialStatus: .blocked, blockedRecheckDelay: .milliseconds(40))
        store.start()
        try await waitUntil("prompt shown") { store.canAnswerBlocked }
        await store.allow()
        #expect(store.isAnsweringBlocked)

        let reads = host.screenReads
        if promptChanges {
            host.screen = "Allow another edit?\n❯ Yes"
            try await waitUntil("a second prompt under the same status can be answered") {
                store.blockedScreen == "Allow another edit?\n❯ Yes" && store.canAnswerBlocked
            }
        } else {
            try await waitUntil("the check reads the screen") { host.screenReads > reads }
            try await Task.sleep(for: .milliseconds(50))
            #expect(store.isAnsweringBlocked, "the answered prompt stays answered")
        }
        store.stop()
    }

    @Test func restartingChatInvalidatesTheOlderApprovalRead() async throws {
        let host = TranscriptHost()
        host.screen = "Allow edit?\n❯ Yes"
        let store = host.makeStore(initialStatus: .blocked)
        defer { store.stop() }
        store.start()
        try await waitUntil("prompt shown") { store.canAnswerBlocked }
        let (readStarted, didRead) = AsyncStream.makeStream(of: Void.self)
        let (releaseRead, release) = AsyncStream.makeStream(of: Void.self)
        host.beforeScreenRead = {
            didRead.yield(())
            for await _ in releaseRead { break }
        }
        let oldAnswer = Task { await store.allow() }
        for await _ in readStarted { break }
        host.beforeScreenRead = nil
        store.stop()
        store.start()
        try await waitUntil("prompt offered after restart") { store.canAnswerBlocked }
        await store.allow()
        release.yield(())
        await oldAnswer.value
        #expect(host.sentKeys == [["enter"]], "only the current attempt can answer")
        #expect(store.isAnsweringBlocked)
    }

    @Test func aRestartedChatReadsThePromptAfreshAndCanAnswerIt() async throws {
        let host = TranscriptHost()
        host.screen = "Question one?\n❯ Yes"
        let store = host.makeStore(initialStatus: .blocked)
        store.start()
        try await waitUntil("prompt shown") { store.canAnswerBlocked }
        await store.allow()
        #expect(store.isAnsweringBlocked)
        store.stop()

        host.screen = "Question two?\n❯ Yes"
        store.start()
        #expect(!store.isAnsweringBlocked)
        #expect(store.blockedScreen == nil, "the old prompt is not offered again")
        try await waitUntil("the new prompt can be answered") {
            store.blockedScreen == "Question two?\n❯ Yes" && store.canAnswerBlocked
        }
        store.stop()
    }

    @Test func theBlockedScreenIsReadAgainOnThePoll() async throws {
        let host = TranscriptHost()
        host.screen = "Question one?\n❯ Yes"
        let store = host.makeStore(initialStatus: .blocked, pollInterval: .milliseconds(20))
        store.start()
        try await waitUntil("prompt shown") { store.blockedScreen == "Question one?\n❯ Yes" }
        host.screen = "Question two?\n❯ Yes"
        try await waitUntil("the poll shows the screen as it is now") {
            store.blockedScreen == "Question two?\n❯ Yes"
        }
        store.stop()
    }

    @Test(arguments: [
        (NotificationRegistrationError.pluginNotInstalled as any Error, ChatTranscriptStore.Availability.pluginMissing),
        (ChatTranscriptError.readerUnavailable as any Error, .pluginOutdated),
    ])
    func pluginErrorsMapToTheirNotice(error: any Error, expected: ChatTranscriptStore.Availability) async {
        let host = TranscriptHost()
        host.respond = { _ in throw error }
        let store = host.makeStore(initialStatus: .idle)

        await store.refresh()

        #expect(store.availability == expected)
    }

    @Test func notFoundWaitsAndOtherFailuresKeepTheMessages() async {
        let host = TranscriptHost()
        host.respond = { _ in ChatTranscriptSnapshot(header: .ok(status: .notFound), messages: []) }
        let store = host.makeStore(initialStatus: .idle)

        await store.refresh()
        #expect(store.availability == .waitingForConversation)

        host.respond = { _ in ChatTranscriptSnapshot(header: .ok(), messages: [.user("u1", "hello")]) }
        await store.refresh()
        #expect(store.availability == .ready)

        host.respond = { _ in throw ChatTranscriptError.malformedOutput }
        await store.refresh()
        guard case .failed = store.availability else {
            Issue.record("expected a failure, got \(store.availability)")
            return
        }
        #expect(store.messages.map(\.id) == ["u1"])
    }

    @Test func pendingMessageClearsOnItsOwnEchoNotAnOlderIdenticalMessage() async throws {
        let host = TranscriptHost()
        host.respond = { _ in
            ChatTranscriptSnapshot(header: .ok(), messages: [.user("u-old", "ship it"), .assistant("a-old", "Shipped.")])
        }
        let store = host.makeStore(initialStatus: .idle)
        await store.refresh()
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        // The Chat view's first render, before anything is sent.
        #expect(store.pendingMessages(composer.messages).isEmpty)

        composer.replaceDraft(with: "ship it")
        _ = await composer.send()
        #expect(store.pendingMessages(composer.messages).map(\.text) == ["ship it"])

        host.respond = { _ in ChatTranscriptSnapshot(header: .ok(turnOpen: true), messages: [.user("u-new", "  ship it\n")]) }
        await store.refresh()
        #expect(store.pendingMessages(composer.messages).isEmpty)
    }

    @Test func messageSentBeforeTheChatViewOpenedIsNotStranded() async {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        composer.replaceDraft(with: "run the tests")
        _ = await composer.send()

        let host = TranscriptHost()
        host.respond = { _ in ChatTranscriptSnapshot(header: .ok(), messages: [.user("u1", "run the tests")]) }
        let store = host.makeStore(initialStatus: .idle)
        // Rendered before the first read lands, as the view does.
        #expect(store.pendingMessages(composer.messages).count == 1)
        await store.refresh()
        #expect(store.pendingMessages(composer.messages).isEmpty)
    }

    /// A slash command, a Blocked answer or an over-long message never shows
    /// up as the same prompt in the transcript.
    @Test func aDeliveredSendWithoutAnEchoSettlesOnceTheConversationMovesPastIt() async throws {
        let host = TranscriptHost()
        let store = host.makeStore(initialStatus: .idle)
        await store.refresh()
        let composer = Self.makeComposer()
        #expect(store.pendingMessages(composer.messages).isEmpty)
        composer.replaceDraft(with: "/compact")
        _ = await composer.send()
        let sentAt = try #require(composer.messages.first?.sentAt)
        #expect(store.pendingMessages(composer.messages).count == 1)

        host.respond = { _ in
            ChatTranscriptSnapshot(
                header: .ok(), messages: [.assistant("a0", "Earlier.", at: sentAt.addingTimeInterval(-5))])
        }
        await store.refresh()
        #expect(store.pendingMessages(composer.messages).count == 1, "an older reply landing late is not its answer")

        host.respond = { _ in
            ChatTranscriptSnapshot(
                header: .ok(), messages: [.assistant("a1", "Compacted.", at: sentAt.addingTimeInterval(2))])
        }
        await store.refresh()
        #expect(store.pendingMessages(composer.messages).isEmpty)
    }

    @Test func aSendQueuedWhileTheAgentWorksWaitsForAUserMessage() async throws {
        let host = TranscriptHost()
        let store = host.makeStore(initialStatus: .working)
        await store.refresh()
        let composer = Self.makeComposer(initialStatus: .working)
        #expect(store.pendingMessages(composer.messages).isEmpty)
        composer.replaceDraft(with: "also run lint")
        _ = await composer.send()
        let sentAt = try #require(composer.messages.first?.sentAt)
        #expect(composer.messages.map(\.state) == [.delivered(.agentBusy)])

        host.respond = { _ in
            ChatTranscriptSnapshot(
                header: .ok(), messages: [.assistant("a1", "Tests pass.", at: sentAt.addingTimeInterval(1))])
        }
        await store.refresh()
        #expect(
            store.pendingMessages(composer.messages).count == 1,
            "the reply ending the turn it queued behind is not its answer")

        // The harness may submit queued messages joined into one prompt.
        host.respond = { _ in
            ChatTranscriptSnapshot(
                header: .ok(turnOpen: true),
                messages: [.user("u2", "fix the test\nalso run lint", at: sentAt.addingTimeInterval(2))])
        }
        await store.refresh()
        #expect(store.pendingMessages(composer.messages).isEmpty)
    }

    @Test func anIdleOrDoneAgentAfterTheSendSettlesIt() async {
        let host = TranscriptHost()
        let store = host.makeStore(initialStatus: .idle)
        await store.refresh()
        let composer = Self.makeComposer()
        #expect(store.pendingMessages(composer.messages).isEmpty)
        composer.replaceDraft(with: "/model")
        _ = await composer.send()
        #expect(store.pendingMessages(composer.messages).count == 1)

        composer.agentStatusDidChange(.working)
        #expect(store.pendingMessages(composer.messages).count == 1)
        composer.agentStatusDidChange(.idle)
        #expect(store.pendingMessages(composer.messages).isEmpty)
    }

    @Test func theNewestSendClaimsTheNewestEcho() async {
        let host = TranscriptHost()
        let store = host.makeStore(initialStatus: .idle)
        await store.refresh()
        let composer = Self.makeComposer()
        #expect(store.pendingMessages(composer.messages).isEmpty)
        _ = await composer.send("continue")
        #expect(store.pendingMessages(composer.messages).count == 1)
        _ = await composer.send("continue")
        #expect(store.pendingMessages(composer.messages).count == 2)

        host.respond = { _ in ChatTranscriptSnapshot(header: .ok(turnOpen: true), messages: [.user("u1", "continue")]) }
        await store.refresh()
        #expect(
            store.pendingMessages(composer.messages).map(\.id) == [composer.messages[0].id],
            "the older send that never echoed stays; the new one is shown by its echo")
    }

    @Test func aFailedSendStaysUntilRetriedOrWithdrawn() async throws {
        let host = TranscriptHost()
        let store = host.makeStore(initialStatus: .idle)
        await store.refresh()
        let transport = ScriptedTransport()
        await transport.setAgentPromptFailure(TransportError.timedOut)
        let composer = Self.makeComposer(transport: transport)
        #expect(store.pendingMessages(composer.messages).isEmpty)
        _ = await composer.send("deploy")
        let failed = try #require(composer.messages.first)
        guard case .failed = failed.state else {
            Issue.record("expected a failed send, got \(failed.state)")
            return
        }
        #expect(store.pendingMessages(composer.messages).count == 1)

        host.respond = { _ in
            ChatTranscriptSnapshot(
                header: .ok(),
                messages: [
                    .user("u1", "deploy", at: failed.sentAt.addingTimeInterval(1)),
                    .assistant("a1", "Deployed.", at: failed.sentAt.addingTimeInterval(2)),
                ])
        }
        await store.refresh()
        #expect(store.pendingMessages(composer.messages).map(\.id) == [failed.id], "Not delivered stays on screen")

        await transport.setAgentPromptFailure(nil)
        _ = await composer.retry(failed.id)
        #expect(composer.messages.map(\.id) == [failed.id], "retried in place")
        #expect(
            store.pendingMessages(composer.messages).count == 1,
            "what the transcript already showed is not the retry's answer")

        host.respond = { _ in ChatTranscriptSnapshot(header: .ok(turnOpen: true), messages: [.user("u2", "deploy")]) }
        await store.refresh()
        #expect(store.pendingMessages(composer.messages).isEmpty)

        await transport.setAgentPromptFailure(TransportError.timedOut)
        _ = await composer.send("roll back")
        let second = try #require(composer.messages.last)
        #expect(store.pendingMessages(composer.messages).map(\.id) == [second.id])
        composer.withdrawToDraft(second.id)
        #expect(store.pendingMessages(composer.messages).isEmpty)
        #expect(composer.draft == "roll back")
    }

    /// omp without herdr's omp integration reports idle for its whole turn.
    @Test func aLocalSendPollsAnIdleAgentUntilItsReplyArrives() async throws {
        let host = TranscriptHost()
        var replied = false
        host.respond = { _ in
            ChatTranscriptSnapshot(
                header: .ok(),
                messages: replied ? [.user("u1", "hi"), .assistant("a1", "Hello.")] : [.user("u1", "hi")])
        }
        let store = host.makeStore(initialStatus: .idle, pollInterval: .milliseconds(20))
        store.start()
        try await waitUntil("first read") { store.messages.count == 1 }
        try await Task.sleep(for: .milliseconds(80))
        let idleReads = host.afters.count
        #expect(idleReads == 1, "an idle Agent is not polled")

        store.followLocalSend()
        try await waitUntil("a send polls the idle Agent") { host.afters.count >= idleReads + 3 }
        replied = true
        try await waitUntil("the reply lands") { store.messages.count == 2 }
        try await Task.sleep(for: .milliseconds(60))
        let answeredReads = host.afters.count
        try await Task.sleep(for: .milliseconds(150))
        #expect(host.afters.count == answeredReads, "the reply ends the polling")
        store.stop()
    }

    /// The window runs on the store's clock, which only the test moves: a
    /// stalled test host can neither end it before the polls nor stretch it.
    @Test func aLocalSendStopsPollingWhenItsWindowEnds() async throws {
        let host = TranscriptHost()
        let store = host.makeStore(
            initialStatus: .idle, pollInterval: .milliseconds(20), localSendPollWindow: .seconds(100))
        store.start()
        try await waitUntil("first read") { host.afters.count == 1 }

        store.followLocalSend()
        try await waitUntil("a send polls the idle Agent") { host.afters.count >= 3 }
        host.now += .seconds(100)
        // A read the last poll before the window's end asked for may still
        // land; no poll after the end reads.
        let readsAtTheEnd = host.afters.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(host.afters.count <= readsAtTheEnd + 1, "no reply within the window: polling stops")
        store.stop()
    }

    /// An omp error reply is re-anchored when the automatic retry answers.
    @Test func aReadFromAnUnknownAfterIDReplacesTheList() async {
        let host = TranscriptHost()
        host.respond = { after in
            after == nil
                ? ChatTranscriptSnapshot(header: .ok(), messages: [.user("u1", "go"), .assistant("e1", "")])
                : ChatTranscriptSnapshot(
                    header: .ok(afterFound: false), messages: [.user("u1", "go"), .assistant("a2", "Done.")])
        }
        let store = host.makeStore(initialStatus: .idle)
        await store.refresh()
        #expect(store.messages.map(\.id) == ["u1", "e1"])

        await store.refresh()
        #expect(host.afters == [nil, "e1"])
        #expect(store.messages.map(\.id) == ["u1", "a2"], "no stale No reply bubble stays behind")

        host.respond = { _ in ChatTranscriptSnapshot(header: .ok(status: .notFound, afterFound: false), messages: []) }
        await store.refresh()
        #expect(store.messages.map(\.id) == ["u1", "a2"], "a transcript not found for now clears nothing")
    }

    /// `/clear` moves the Agent to a new session file.
    @Test func aNewTranscriptPathReplacesTheConversation() async {
        let host = TranscriptHost()
        var path = "/sessions/one.jsonl"
        host.respond = { after in
            guard path == "/sessions/two.jsonl" else {
                return ChatTranscriptSnapshot(
                    header: .ok(transcript: path), messages: [.user("u1", "old"), .assistant("a1", "Old.")])
            }
            return ChatTranscriptSnapshot(
                header: .ok(transcript: path),
                messages: after == nil ? [.user("u9", "new"), .assistant("a9", "New.")] : [.assistant("a9", "New.")])
        }
        let store = host.makeStore(initialStatus: .idle)
        await store.refresh()
        #expect(store.messages.map(\.id) == ["u1", "a1"])

        path = "/sessions/two.jsonl"
        await store.refresh()
        #expect(host.afters == [nil, "a1", nil], "the new conversation is read in full")
        #expect(store.messages.map(\.id) == ["u9", "a9"])
    }

    @Test func cachedMessagesShowBeforeAnyRead() {
        let host = TranscriptHost()
        let cached: [ChatTranscriptMessage] = [.user("u1", "why is CI red?"), .assistant("a1", "Flaky test.")]
        let store = host.makeStore(initialStatus: .idle, cachedMessages: cached)

        #expect(store.messages == cached)
        #expect(host.afters.isEmpty)
        #expect(host.persisted.isEmpty, "the cached copy is not written back")
    }

    @Test func aStartWithACacheStillReadsInFullAndTheSameAnswerWritesNothing() async throws {
        let host = TranscriptHost()
        let cached: [ChatTranscriptMessage] = [.user("u1", "why is CI red?"), .assistant("a1", "Flaky test.")]
        host.respond = { _ in ChatTranscriptSnapshot(header: .ok(), messages: cached) }
        let store = host.makeStore(initialStatus: .idle, cachedMessages: cached)

        store.start()
        try await waitUntil("the full read lands") { store.availability == .ready }
        #expect(host.afters == [nil], "the cached copy is reconciled by a full read")
        #expect(store.messages == cached)
        #expect(host.persisted.isEmpty)
        store.stop()
    }

    @Test func aNotFoundFullReadKeepsTheCachedMessagesAndIsRetriedUntilFound() async throws {
        let host = TranscriptHost()
        let cached: [ChatTranscriptMessage] = [.user("u1", "hi"), .assistant("a1", "Hello.")]
        let found = cached + [.user("u2", "and now?")]
        var reads = 0
        var shownWhileNotFound: [[ChatTranscriptMessage]] = []
        let store = host.makeStore(
            initialStatus: .idle, cachedMessages: cached, retryDelays: [.milliseconds(5)])
        host.respond = { [weak store] _ in
            reads += 1
            guard reads > 3 else {
                shownWhileNotFound.append(store?.messages ?? [])
                return ChatTranscriptSnapshot(header: .ok(status: .notFound), messages: [])
            }
            return ChatTranscriptSnapshot(header: .ok(), messages: found)
        }

        store.start()
        try await waitUntil("a retry finds the transcript") { store.availability == .ready }
        #expect(shownWhileNotFound == [cached, cached, cached], "not found clears nothing")
        #expect(host.afters == [nil, nil, nil, nil], "the list is read in full until a full read lands")
        #expect(store.messages == found)
        try await Task.sleep(for: .milliseconds(60))
        #expect(host.afters.count == 4, "a read that found the transcript ends the retries")
        store.stop()
    }

    @Test func aThrowingReadKeepsTheMessagesAndIsRetriedUntilItSucceeds() async throws {
        let host = TranscriptHost()
        let cached: [ChatTranscriptMessage] = [.user("u1", "hi"), .assistant("a1", "Hello.")]
        var reads = 0
        var shownWhileFailing: [[ChatTranscriptMessage]] = []
        let store = host.makeStore(
            initialStatus: .idle, cachedMessages: cached, retryDelays: [.milliseconds(5)])
        host.respond = { [weak store] _ in
            reads += 1
            guard reads > 2 else {
                shownWhileFailing.append(store?.messages ?? [])
                throw TransportError.timedOut
            }
            return ChatTranscriptSnapshot(header: .ok(), messages: cached)
        }

        store.start()
        try await waitUntil("a retry succeeds") { store.availability == .ready }
        #expect(host.afters.count == 3)
        #expect(shownWhileFailing == [cached, cached])
        #expect(store.messages == cached)
        try await Task.sleep(for: .milliseconds(60))
        #expect(host.afters.count == 3, "a read that succeeded ends the retries")
        store.stop()
    }

    @Test(arguments: [UnfixableRead.unsupported, .pluginMissing, .pluginOutdated])
    func aReadNoRetryCanFixIsNotRetried(failure: UnfixableRead) async throws {
        let host = TranscriptHost()
        let cached: [ChatTranscriptMessage] = [.user("u1", "hi")]
        host.respond = { _ in
            switch failure {
            case .unsupported:
                return ChatTranscriptSnapshot(header: .ok(status: .unsupported), messages: [])
            case .pluginMissing:
                throw NotificationRegistrationError.pluginNotInstalled
            case .pluginOutdated:
                throw ChatTranscriptError.readerUnavailable
            }
        }
        let store = host.makeStore(
            initialStatus: .idle, cachedMessages: cached, retryDelays: [.milliseconds(5)])

        store.start()
        try await waitUntil("the read lands") { store.availability != .loading }
        try await Task.sleep(for: .milliseconds(60))
        #expect(host.afters.count == 1)
        #expect(store.messages == cached)
        store.stop()
    }

    @Test func stopCancelsAPendingRetry() async throws {
        let host = TranscriptHost()
        host.respond = { _ in ChatTranscriptSnapshot(header: .ok(status: .notFound), messages: []) }
        let store = host.makeStore(initialStatus: .idle, retryDelays: [.milliseconds(40)])

        store.start()
        try await waitUntil("not found yet") { store.availability == .waitingForConversation }
        store.stop()
        try await Task.sleep(for: .milliseconds(150))
        #expect(host.afters.count == 1, "nothing is read after stop")
    }

    @Test func anErrorHeaderKeepsTheListActivityAndOpenTurnAndIsRetried() async throws {
        let host = TranscriptHost()
        let shown: [ChatTranscriptMessage] = [.user("u1", "run the tests")]
        var reads = 0
        host.respond = { _ in
            reads += 1
            guard reads > 1 else {
                return ChatTranscriptSnapshot(
                    header: .ok(turnOpen: true, activity: "Running tests"), messages: shown)
            }
            return ChatTranscriptSnapshot(
                header: .ok(status: .error, error: "session file unreadable"), messages: [])
        }
        let store = host.makeStore(initialStatus: .idle, retryDelays: [.milliseconds(5)])

        store.start()
        try await waitUntil("the first read lands") { store.availability == .ready }
        #expect(host.persisted == [shown])

        await store.refresh()
        #expect(store.availability == .failed("session file unreadable"))
        #expect(store.messages == shown)
        #expect(store.activity == "Running tests")
        #expect(store.isTurnOpen)
        #expect(host.persisted == [shown], "a reader error writes nothing")
        try await waitUntil("the error is retried") { host.afters.count >= 3 }
        #expect(store.isTurnOpen)
        store.stop()
    }

    @Test func retriesBackOffAndResetAfterAFoundReadOrARestart() async throws {
        let host = TranscriptHost()
        var found = false
        host.respond = { _ in
            ChatTranscriptSnapshot(header: .ok(status: found ? .ok : .notFound), messages: [])
        }
        let store = host.makeStore(
            initialStatus: .idle, retryDelays: [.milliseconds(5), .seconds(3600)])

        store.start()
        try await waitUntil("the first retry is quick") { host.afters.count == 2 }
        // The next retry waits an hour: nothing in this test can reach it.
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.afters.count == 2, "the second retry takes the slow delay")

        found = true
        await store.refresh()
        #expect(store.availability == .ready)
        found = false
        await store.refresh()
        try await waitUntil("a found read resets to the quick delay") { host.afters.count == 5 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.afters.count == 5)

        store.stop()
        store.start()
        try await waitUntil("a restart resets to the quick delay") { host.afters.count == 7 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(host.afters.count == 7)
        store.stop()
    }

    @Test func persistIsCalledOncePerRealChange() async throws {
        let host = TranscriptHost()
        let first: [ChatTranscriptMessage] = [.user("u1", "hi")]
        let both = first + [.assistant("a1", "Hello.")]
        host.respond = { after in ChatTranscriptSnapshot(header: .ok(), messages: after == nil ? first : []) }
        let store = host.makeStore(initialStatus: .idle)

        await store.refresh()
        #expect(host.persisted == [first], "a whole-list read is kept")
        await store.refresh()
        #expect(host.persisted == [first], "an incremental read with nothing new writes nothing")

        host.respond = { _ in ChatTranscriptSnapshot(header: .ok(), messages: [.assistant("a1", "Hello.")]) }
        await store.refresh()
        #expect(host.persisted == [first, both], "a merge is kept")
        await store.refresh()
        #expect(host.persisted == [first, both], "a message already shown writes nothing")

        host.respond = { _ in ChatTranscriptSnapshot(header: .ok(status: .notFound), messages: []) }
        await store.refresh()
        host.respond = { _ in throw TransportError.timedOut }
        await store.refresh()
        #expect(host.persisted == [first, both], "failures write nothing")
        #expect(store.messages == both)
    }

    private static func makeComposer(
        initialStatus: AgentStatus = .idle,
        transport: ScriptedTransport = ScriptedTransport()
    ) -> AgentComposerStore {
        AgentComposerStore(target: "w1:p1", initialStatus: initialStatus) { params in
            try await transport.promptAgent(params)
        }
    }

    /// A read no later read can do better on.
    enum UnfixableRead: Sendable {
        case unsupported, pluginMissing, pluginOutdated
    }
}

@MainActor
@Suite("Agent Composer Blocked insert")
struct AgentComposerBlockedInsertTests {
    @Test func blockedSendWithOnlyABlockedInsertDeliversThroughIt() async {
        let transport = ScriptedTransport()
        let store = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) { params in
            try await transport.promptAgent(params)
        }
        var inserted: [String] = []
        store.bindBlockedInsert { text in inserted.append(text) }
        store.replaceDraft(with: "yes\r\nplease")

        let result = await store.send()

        #expect(result == .deliveredViaAttach)
        #expect(inserted == ["yes\nplease"])
        #expect(store.messages.map(\.state) == [.delivered(.acknowledged)])
        #expect(await transport.agentPromptParams.isEmpty)
    }
}

/// The Host side of a transcript store: scripted reads, screen and keys.
@MainActor
private final class TranscriptHost {
    var respond: @MainActor (String?) throws -> ChatTranscriptSnapshot = { _ in
        ChatTranscriptSnapshot(header: .ok(), messages: [])
    }
    var screen = ""
    var screenFailure: (any Error)?
    var beforeScreenRead: (@MainActor () async -> Void)?
    var keyFailure: (any Error)?
    private(set) var screenReads = 0
    private(set) var afters: [String?] = []
    private(set) var sentKeys: [[String]] = []
    /// Every list the store asked to keep on this device, in order.
    private(set) var persisted: [[ChatTranscriptMessage]] = []
    /// The store's clock. It stands still unless a test moves it.
    var now = ContinuousClock.now

    func makeStore(
        initialStatus: AgentStatus,
        statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>? = nil,
        cachedMessages: [ChatTranscriptMessage] = [],
        retryDelays: [Duration] = [.seconds(60)],
        pollInterval: Duration = .seconds(60),
        localSendPollWindow: Duration = .seconds(180),
        blockedRecheckDelay: Duration = .seconds(60)
    ) -> ChatTranscriptStore {
        ChatTranscriptStore(
            read: { [self] after in
                afters.append(after)
                return try respond(after)
            },
            readScreen: { [self] in
                screenReads += 1
                await beforeScreenRead?()
                if let screenFailure { throw screenFailure }
                return screen
            },
            sendKeys: { [self] keys in
                sentKeys.append(keys)
                if let keyFailure { throw keyFailure }
            },
            initialStatus: initialStatus,
            statusUpdates: statusUpdates,
            cachedMessages: cachedMessages,
            persist: { [self] messages in persisted.append(messages) },
            retryDelays: retryDelays,
            workingPollInterval: pollInterval,
            localSendPollWindow: localSendPollWindow,
            blockedRecheckDelay: blockedRecheckDelay,
            now: { [self] in now })
    }
}

@Suite("Chat transcript after_found")
struct ChatTranscriptAfterFoundDecodingTests {
    @Test(arguments: [
        (#"{"type":"header","v":1,"kind":"omp","status":"ok","after_found":false}"#, false),
        (#"{"type":"header","v":1,"kind":"omp","status":"ok","after_found":true}"#, true),
        // A reader that predates the field always found the id.
        (#"{"type":"header","v":1,"kind":"omp","status":"ok"}"#, true),
    ])
    func theHeaderSaysWhetherTheAfterIDWasFound(line: String, expected: Bool) throws {
        let snapshot = try ChatTranscriptDecoding.decode(Data(line.utf8))
        #expect(snapshot.header.afterFound == expected)
    }
}

extension ChatTranscriptHeader {
    fileprivate static func ok(
        status: Status = .ok, turnOpen: Bool = false, transcript: String? = nil, afterFound: Bool = true,
        activity: String? = nil, error: String? = nil
    ) -> Self {
        .init(
            kind: "claude", status: status, transcript: transcript, activity: activity,
            turnOpen: turnOpen, truncated: false, error: error, afterFound: afterFound)
    }
}

extension ChatTranscriptMessage {
    fileprivate static func user(_ id: String, _ text: String, at timestamp: Date? = nil) -> Self {
        .init(id: id, role: .user, text: text, timestamp: timestamp)
    }

    fileprivate static func assistant(_ id: String, _ text: String, at timestamp: Date? = nil) -> Self {
        .init(id: id, role: .assistant, text: text, timestamp: timestamp)
    }
}
