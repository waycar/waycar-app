import Foundation
import Testing

@testable import Waycar

/// Queued Messages (#151): a send that never left the device waits on it,
/// survives the app, and goes out on its own once the Host can take it.
@MainActor
@Suite("Queued Messages", .timeLimit(.minutes(1)))
struct QueuedMessageTests {
    private let directory = FileManager.default.temporaryDirectory
        .appending(path: "queued-messages-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let hostID = UUID()

    // MARK: Classification

    @Test func onlyLinkFailuresBeforeTheWriteCountAsUnsent() {
        let unreachable = TransportError.sshUnreachable(detail: "down")
        #expect(RequestNotSentError.wrapping(unreachable) is RequestNotSentError)
        #expect(RequestNotSentError.wrapping(TransportError.timedOut) is RequestNotSentError)
        let rejected = TransportError.apiRejected(code: "agent_not_found", message: "gone")
        #expect(RequestNotSentError.wrapping(rejected) as? TransportError == rejected)
        #expect(RequestNotSentError.wrapping(TransportError.cancelled) as? TransportError == .cancelled)
        let herdr = HerdrAPIError(code: "agent_blocked", message: "blocked")
        #expect(RequestNotSentError.wrapping(herdr) as? HerdrAPIError == herdr)
        // Already unsent: the link-failure check and the message see the cause.
        let unsent = RequestNotSentError(cause: unreachable)
        #expect(EventsSession.isTransportLinkFailure(unsent))
        #expect(
            AgentComposerStore.message(for: unsent)
                == AgentComposerStore.message(for: unreachable))
    }

    @Test func aPromptToAHostWithNoConnectionNeverLeftTheDevice() async {
        let console = ConsoleStore()
        await #expect(throws: RequestNotSentError.self) {
            try await console.promptAgent(
                AgentPromptParams(target: "w1:p1", text: "hello"), on: UUID())
        }
    }

    /// With the device's network path gone, a prompt to a Host whose rows are
    /// not verified queues at once: it never waits out `verificationTimeout`,
    /// which here never fires, so a wait would hang the test into its limit.
    @Test func aPromptWithNoNetworkPathQueuesWithoutWaiting() async throws {
        defer { cleanUp() }
        let host = Host.fixture(id: hostID)
        let cache = ConsoleInventoryCache(directory: directory)
        cache.save(
            ConsoleInventoryCache.Entry(
                snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]), sidebarLayout: nil),
            for: host)
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let console = ConsoleStore(
            inventoryCache: cache,
            verificationTimeout: ConsoleStore.Countdown {
                try await Task.sleep(for: .seconds(3600))
            }
        ) { _, _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        defer { console.setHosts([]) }
        // Never activated: the last-known row is listed but not verified.
        console.setHosts([host])
        #expect(console.agents.map(\.agent.paneID) == ["w1:p1"])
        let path = ScriptedNetworkPathSource()
        let monitor = path.monitor()
        console.followNetworkPath(monitor)
        path.read(ScriptedNetworkPathSource.home)
        path.read(
            NetworkPathSnapshot(
                isSatisfied: false, interface: nil, interfaceName: nil, localAddress: nil))
        await #expect(throws: RequestNotSentError.self) {
            try await console.promptAgent(
                AgentPromptParams(target: "w1:p1", text: "hello"), on: host.id)
        }
        #expect(await transport.agentPromptParams.isEmpty)
        withExtendedLifetime(monitor) {}
    }

    /// A launch with no network: the monitor's baseline reading is none, so
    /// the prompt queues at once without any path change.
    @Test func aPromptAfterALaunchWithNoNetworkQueuesWithoutWaiting() async throws {
        defer { cleanUp() }
        let host = Host.fixture(id: hostID)
        let cache = ConsoleInventoryCache(directory: directory)
        cache.save(
            ConsoleInventoryCache.Entry(
                snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]), sidebarLayout: nil),
            for: host)
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let console = ConsoleStore(
            inventoryCache: cache,
            verificationTimeout: ConsoleStore.Countdown {
                try await Task.sleep(for: .seconds(3600))
            }
        ) { _, _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        defer { console.setHosts([]) }
        console.setHosts([host])
        let path = ScriptedNetworkPathSource()
        let monitor = path.monitor()
        console.followNetworkPath(monitor)
        path.read(
            NetworkPathSnapshot(
                isSatisfied: false, interface: nil, interfaceName: nil, localAddress: nil))
        await #expect(throws: RequestNotSentError.self) {
            try await console.promptAgent(
                AgentPromptParams(target: "w1:p1", text: "hello"), on: host.id)
        }
        #expect(await transport.agentPromptParams.isEmpty)
        withExtendedLifetime(monitor) {}
    }

    @Test func anUnsentSendQueuesWhileAnAmbiguousOneFailsForRetry() async throws {
        defer { cleanUp() }
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        let unsent = harness.makeComposer { _ in
            throw RequestNotSentError(cause: TransportError.sshUnreachable(detail: "down"))
        }
        unsent.replaceDraft(with: "never left")
        #expect(await unsent.send() == .queued)
        #expect(unsent.messages.map(\.state) == [.queued])
        #expect(harness.store.messages(on: hostID).map(\.draftText) == ["never left"])
        #expect(harness.counts.last == 1)

        // Written, then the answer was lost: it may have been delivered.
        let ambiguous = harness.makeComposer(paneID: "w1:p2") { _ in throw TransportError.timedOut }
        ambiguous.replaceDraft(with: "maybe delivered")
        #expect(await ambiguous.send() == .failed)
        #expect(
            ambiguous.messages.map(\.state)
                == [.failed("The Host did not answer. Check the connection and retry.")])
        #expect(harness.store.messages(on: hostID).map(\.draftText) == ["never left"])
    }

    // MARK: Persistence

    @Test func aQueuedMessageRoundTripsThroughTheDevice() throws {
        defer { cleanUp() }
        let store = QueuedMessageStore(directory: directory)
        let message = QueuedMessage(
            id: UUID(), hostID: hostID,
            agent: QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "claude", session: "s-1"),
            draftText: "Café 👋",
            attachments: [
                QueuedMessage.Attachment(
                    id: UUID(), kind: .image, fileName: nil, localFileName: "a.jpg",
                    fileExtension: "jpeg", pixelWidth: 4, pixelHeight: 3, byteCount: 12,
                    hostPath: nil),
                QueuedMessage.Attachment(
                    id: UUID(), kind: .file, fileName: "notes.txt", localFileName: nil,
                    fileExtension: "txt", pixelWidth: nil, pixelHeight: nil, byteCount: 0,
                    hostPath: "/tmp/waycar/notes.txt"),
            ],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(message)

        let reopened = QueuedMessageStore(directory: directory)
        #expect(reopened.messages(on: hostID) == [message])
        #expect(reopened.messages(on: UUID()).isEmpty)

        reopened.retainOnly([UUID()])
        #expect(reopened.messages(on: hostID).isEmpty)

        try store.save(message)
        store.remove(message)
        #expect(store.messages(on: hostID).isEmpty)
    }

    @Test func theConsoleRestoresQueuedMessagesAtLaunchAndDrainsThemOnConnect() async throws {
        defer { cleanUp() }
        let host = Host.fixture(id: hostID)
        let store = QueuedMessageStore(directory: directory)
        let record = QueuedMessage(
            id: UUID(), hostID: hostID,
            agent: QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "claude", session: nil),
            draftText: "sent while away", attachments: [], createdAt: Date())
        try store.save(record)
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let console = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(
                defaults: UserDefaults(suiteName: "queued-pins-\(UUID().uuidString)")
                    ?? .standard),
            queuedMessages: store
        ) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions, connect: { transport },
                reconnectPolicy: ReconnectPolicy(
                    initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
                keepalive: nil)
        }
        defer { console.setHosts([]) }
        let id = ConsoleAgent.ID(hostID: hostID, paneID: "w1:p1")

        // No Composer was opened this launch: the catalog brings it back.
        console.setHosts([host])
        #expect(console.queuedMessageCounts[id] == 1)

        await console.resume()
        try await waitUntil("the queue should drain once the Host is verified") {
            await transport.agentPromptParams.map(\.text) == ["sent while away"]
        }
        try await waitUntil("the delivered message should leave the device") {
            console.queuedMessageCounts[id] == nil && store.messages(on: hostID).isEmpty
        }
    }

    @Test func reTargetingAHostDropsItsQueuedMessages() throws {
        defer { cleanUp() }
        let host = Host.fixture(id: hostID, address: "old.example")
        let store = QueuedMessageStore(directory: directory)
        try store.save(
            QueuedMessage(
                id: UUID(), hostID: hostID,
                agent: QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "claude", session: nil),
                draftText: "for the old machine", attachments: [], createdAt: Date()))
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let console = ConsoleStore(
            pins: PinnedAgentsStore(
                defaults: UserDefaults(suiteName: "queued-pins-\(UUID().uuidString)")
                    ?? .standard),
            queuedMessages: store
        ) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        defer { console.setHosts([]) }
        let id = ConsoleAgent.ID(hostID: hostID, paneID: "w1:p1")
        console.setHosts([host])
        #expect(console.queuedMessageCounts[id] == 1)

        // Same Host id, another machine: nothing may drain to it.
        console.setHosts([Host.fixture(id: hostID, address: "new.example")])

        #expect(console.queuedMessageCounts[id] == nil)
        #expect(store.messages(on: hostID).isEmpty)
    }

    @Test func anUnreadableRecordIsKeptWhileACorruptOneIsDeleted() throws {
        defer { cleanUp() }
        let store = QueuedMessageStore(directory: directory)
        let message = QueuedMessage(
            id: UUID(), hostID: hostID,
            agent: QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "claude", session: nil),
            draftText: "kept", attachments: [], createdAt: Date())
        let folder = store.messageDirectory(for: message)
        // A record that cannot be read right now (here a directory where the
        // file should be) is skipped, not destroyed.
        try FileManager.default.createDirectory(
            at: folder.appending(path: "message.json", directoryHint: .isDirectory),
            withIntermediateDirectories: true)
        #expect(store.messages(on: hostID).isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder.path))

        let corrupt = QueuedMessage(
            id: UUID(), hostID: hostID, agent: message.agent, draftText: "corrupt",
            attachments: [], createdAt: Date())
        let corruptFolder = try store.preparedDirectory(for: corrupt)
        try Data("not json".utf8).write(
            to: corruptFolder.appending(path: "message.json", directoryHint: .notDirectory))
        #expect(store.messages(on: hostID).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: corruptFolder.path))
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    // MARK: Drain

    @Test func aReconnectDrainsTheQueueInTheOrderItWasSent() async throws {
        defer { cleanUp() }
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        harness.mayDrain = false
        let prompts = PromptLog()
        let composer = harness.makeComposer { params in
            await prompts.append(params.text)
            if await prompts.isOffline {
                throw RequestNotSentError(cause: TransportError.sshUnreachable(detail: "down"))
            }
            return Self.agent(paneID: params.target)
        }
        composer.replaceDraft(with: "first")
        #expect(await composer.send() == .queued)
        // A send behind a queued one waits its turn without trying.
        composer.replaceDraft(with: "second")
        #expect(await composer.send() == .queued)
        composer.replaceDraft(with: "third")
        #expect(await composer.send() == .queued)
        #expect(await prompts.texts == ["first"])

        await prompts.setOffline(false)
        harness.mayDrain = true
        composer.drainQueue()
        try await waitUntil("every queued message should be delivered") {
            composer.messages.allSatisfy { $0.state == .delivered(.acknowledged) }
        }
        #expect(await prompts.texts == ["first", "first", "second", "third"])
        #expect(harness.store.messages(on: hostID).isEmpty)
        #expect(harness.counts.last == 0)
    }

    @Test func aChangedAgentSessionHoldsTheMessageUntilTheUserSendsIt() async throws {
        defer { cleanUp() }
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        harness.identity = QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "claude", session: "s-1")
        harness.mayDrain = false
        let prompts = PromptLog()
        await prompts.setOffline(false)
        let composer = harness.makeComposer { params in
            await prompts.append(params.text)
            return Self.agent(paneID: params.target)
        }
        harness.unsentOnce = true
        composer.replaceDraft(with: "for the old session")
        #expect(await composer.send() == .queued)

        harness.identity = QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "claude", session: "s-2")
        harness.mayDrain = true
        composer.drainQueue()
        try await waitUntil("the message should be held") {
            composer.messages.first?.isHeld == true
        }
        #expect(composer.messages.first?.state == .held(AgentComposerStore.agentChangedMessage))
        #expect(await prompts.texts.isEmpty)
        #expect(harness.counts.last == 1)

        composer.sendAnyway(try #require(composer.messages.first?.id))
        try await waitUntil("Send Anyway should deliver it") {
            composer.messages.first?.state == .delivered(.acknowledged)
        }
        #expect(await prompts.texts == ["for the old session"])
    }

    @Test func anAgentWithoutASessionMatchesByKindOnItsPane() {
        let queued = QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "claude", session: nil)
        #expect(queued.matches(.init(paneID: "w1:p1", kind: "claude", session: "s-9")))
        #expect(!queued.matches(.init(paneID: "w1:p1", kind: "codex", session: nil)))
        #expect(!queued.matches(.init(paneID: "w1:p2", kind: "claude", session: nil)))
        let withSession = QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "claude", session: "s-1")
        #expect(!withSession.matches(.init(paneID: "w1:p1", kind: "claude", session: nil)))
        #expect(withSession.matches(.init(paneID: "w1:p1", kind: "claude", session: "s-1")))
        // Queued with no Agent listed: never sent on its own.
        let unknown = QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: nil, session: nil)
        #expect(!unknown.matches(.init(paneID: "w1:p1", kind: "claude", session: nil)))
    }

    @Test func aMessageQueuedWithNoAgentListedIsHeldUntilSentAnyway() async throws {
        defer { cleanUp() }
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        harness.identity = nil
        harness.mayDrain = false
        let prompts = PromptLog()
        let composer = harness.makeComposer { params in
            await prompts.append(params.text)
            if await prompts.isOffline {
                throw RequestNotSentError(cause: TransportError.sshUnreachable(detail: "down"))
            }
            return Self.agent(paneID: params.target)
        }
        composer.replaceDraft(with: "for whoever was there")
        #expect(await composer.send() == .queued)
        // An Agent shows up on the pane before the queue drains.
        harness.identity = QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "claude", session: nil)
        harness.mayDrain = true
        composer.drainQueue()
        try await waitUntil("the message should be held") {
            composer.messages.first?.isHeld == true
        }
        #expect(composer.messages.first?.state == .held(AgentComposerStore.agentChangedMessage))
        #expect(await prompts.texts == ["for whoever was there"])

        await prompts.setOffline(false)
        composer.sendAnyway(try #require(composer.messages.first?.id))
        try await waitUntil("Send Anyway should deliver it") {
            composer.messages.first?.state == .delivered(.acknowledged)
        }
        #expect(await prompts.texts == ["for whoever was there", "for whoever was there"])
        #expect(harness.store.messages(on: hostID).isEmpty)
    }

    @Test func anAgentThatChangesDuringTheUploadsHoldsTheMessage() async throws {
        defer { cleanUp() }
        let source = directory.appending(path: "picked/report.txt", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("report".utf8).write(to: source)
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        harness.identity = QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "claude", session: "s-1")
        harness.mayDrain = false
        let prompts = PromptLog()
        let composer = harness.makeComposer { params in
            await prompts.append(params.text)
            return Self.agent(paneID: params.target)
        }
        composer.setHostReachable(false)
        composer.tray.add([.file(source)])
        composer.replaceDraft(with: "see attached")
        #expect(await composer.send() == .queued)

        harness.onUpload = { [weak harness] in
            harness?.identity = QueuedMessage.AgentIdentity(
                paneID: "w1:p1", kind: "claude", session: "s-2")
        }
        harness.mayDrain = true
        composer.drainQueue()
        try await waitUntil("the message should be held") {
            composer.messages.first?.isHeld == true
        }
        #expect(await prompts.texts.isEmpty)
        // The upload is kept: the record names its Host path and no marker.
        let saved = try #require(harness.store.messages(on: hostID).first)
        #expect(saved.attachments.first?.hostPath == "/host/staged/report.txt")
        #expect(saved.promptStartedAt == nil)
    }

    @Test func anUploadTheHostRefusesFailsInsteadOfRetrying() async throws {
        defer { cleanUp() }
        let source = directory.appending(path: "picked/report.txt", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("report".utf8).write(to: source)
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        harness.mayDrain = false
        let composer = harness.makeComposer { params in Self.agent(paneID: params.target) }
        composer.setHostReachable(false)
        composer.tray.add([.file(source)])
        composer.replaceDraft(with: "see attached")
        #expect(await composer.send() == .queued)

        harness.uploadError = TransportError.invalidDirectoryPath(path: "/nope")
        harness.mayDrain = true
        composer.drainQueue()
        try await waitUntil("the message should fail") {
            composer.messages.first?.isFailed == true
        }
        #expect(await harness.sleeper.delays.isEmpty)
        let prompts = PromptLog()
        let reopened = harness.makeComposer { params in
            await prompts.append(params.text)
            return Self.agent(paneID: params.target)
        }
        reopened.restoreQueued(harness.store.messages(on: hostID))
        #expect(reopened.messages.first?.isFailed == true)
        harness.uploadError = nil
        reopened.drainQueue()
        // An explicit Retry is the only operation allowed to send it.
        #expect(reopened.messages.first?.isFailed == true)
        #expect(await prompts.texts.isEmpty)
        let id = try #require(reopened.messages.first?.id)
        #expect(await reopened.retry(id) == .queued)
        try await waitUntil("Retry should deliver the attachment") {
            await prompts.texts.count == 1
        }
    }

    @Test func anUploadOverADroppedLinkStaysQueued() async throws {
        defer { cleanUp() }
        let source = directory.appending(path: "picked/report.txt", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("report".utf8).write(to: source)
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        harness.mayDrain = false
        let composer = harness.makeComposer { params in Self.agent(paneID: params.target) }
        composer.setHostReachable(false)
        composer.tray.add([.file(source)])
        composer.replaceDraft(with: "see attached")
        #expect(await composer.send() == .queued)

        harness.uploadError = TransportError.channelFailed(detail: "link dropped")
        harness.mayDrain = true
        composer.drainQueue()
        try await waitUntil("the drain should back off") {
            await !harness.sleeper.delays.isEmpty
        }
        #expect(composer.messages.first?.isFailed == false)
        #expect(harness.store.messages(on: hostID).count == 1)
    }

    @Test func attachmentsUploadBeforeThePromptGoesOut() async throws {
        defer { cleanUp() }
        let source = directory.appending(path: "picked/report.txt", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("report".utf8).write(to: source)
        let events = PromptLog()
        await events.setOffline(false)
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        harness.mayDrain = false
        harness.uploadLog = events
        let composer = harness.makeComposer { params in
            await events.append("prompt:\(params.text)")
            return Self.agent(paneID: params.target)
        }
        composer.setHostReachable(false)
        composer.tray.add([.file(source)])
        composer.replaceDraft(with: "see attached")
        #expect(composer.canSend)

        #expect(await composer.send() == .queued)
        #expect(composer.tray.isEmpty)
        let saved = try #require(harness.store.messages(on: hostID).first)
        let copy = try #require(saved.attachments.first)
        #expect(copy.hostPath == nil)
        #expect(harness.store.fileURL(of: copy, in: saved) != nil)
        #expect(await events.texts.isEmpty)

        harness.mayDrain = true
        composer.drainQueue()
        try await waitUntil("the message should be delivered") {
            composer.messages.first?.state == .delivered(.acknowledged)
        }
        #expect(
            await events.texts == [
                "upload:report.txt", "prompt:see attached /host/staged/report.txt",
            ])
        #expect(harness.store.messages(on: hostID).isEmpty)
    }

    @Test func aPromptCutOffByTheAppEndingComesBackFailedNotQueued() throws {
        defer { cleanUp() }
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        let composer = harness.makeComposer { _ in throw TransportError.timedOut }
        var record = QueuedMessage(
            id: UUID(), hostID: hostID,
            agent: QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "claude", session: nil),
            draftText: "was going out", attachments: [], createdAt: Date())
        record.promptStartedAt = Date()
        try harness.store.save(record)
        let waiting = QueuedMessage(
            id: UUID(), hostID: hostID, agent: record.agent, draftText: "still waiting",
            attachments: [], createdAt: Date())
        try harness.store.save(waiting)

        composer.restoreQueued(harness.store.messages(on: hostID))

        #expect(composer.messages.map(\.draftText) == ["was going out", "still waiting"])
        #expect(composer.messages.first?.isFailed == true)
        #expect(composer.messages.last?.state == .queued)
        #expect(harness.store.messages(on: hostID).map(\.id) == [waiting.id])
        #expect(harness.counts.last == 1)
    }

    @Test func editingAQueuedMessageGivesBackItsTextAndAttachments() async throws {
        defer { cleanUp() }
        let source = directory.appending(path: "picked/notes.md", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: source)
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        harness.mayDrain = false
        let composer = harness.makeComposer { _ in
            throw RequestNotSentError(cause: TransportError.sshUnreachable(detail: "down"))
        }
        composer.setHostReachable(false)
        composer.tray.add([.file(source)])
        composer.replaceDraft(with: "read this")
        #expect(await composer.send() == .queued)
        let id = try #require(composer.messages.first?.id)

        // A newer draft may already fill the tray when Edit restores the old one.
        composer.tray.add((0..<ComposerTray.capacity).map { .file(source.deletingLastPathComponent().appending(path: "new-\($0).txt")) })
        composer.withdrawToDraft(id)

        #expect(composer.messages.isEmpty)
        #expect(composer.draft == "read this")
        #expect(composer.tray.items.count == ComposerTray.capacity + 1)
        let restored = try #require(composer.tray.items.last)
        #expect(restored.kind == .file(name: "notes.md"))
        guard case .file(let copy) = composer.tray.source(of: restored.id) else {
            Issue.record("Edit must retain the unuploaded source")
            return
        }
        defer { ComposerTray.discardLocalCopy(.file(copy)) }
        #expect(try Data(contentsOf: copy) == Data("notes".utf8))
        #expect(harness.store.messages(on: hostID).isEmpty)
        #expect(harness.counts.last == 0)
    }

    @Test func failedPreparationRestoresEveryAttachmentPastCapacity() async throws {
        defer { cleanUp() }
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        harness.mayDrain = false
        let gate = ScriptedTransportCallGate()
        harness.preparationGate = gate
        let composer = harness.makeComposer { _ in throw TransportError.timedOut }
        composer.setHostReachable(false)
        let source = directory.appending(path: "missing.txt")
        composer.tray.add([.file(source)])
        composer.replaceDraft(with: "keep this")
        let send = Task { await composer.send() }
        await gate.waitForEntry()
        composer.tray.add((0..<ComposerTray.capacity).map { .file(directory.appending(path: "new-\($0).txt")) })
        await gate.open()

        #expect(await send.value == .failed)
        #expect(composer.messages.isEmpty)
        #expect(composer.draft == "keep this")
        #expect(composer.tray.items.count == ComposerTray.capacity + 1)
        let restored = try #require(composer.tray.items.last)
        #expect(restored.kind == .file(name: "missing.txt"))
        guard case .file(let restoredURL) = composer.tray.source(of: restored.id) else {
            Issue.record("Rollback must retain the unprepared source")
            return
        }
        #expect(restoredURL == source)
    }

    // MARK: Backoff

    @Test func retriesBackOffAndAReconnectStartsOver() async throws {
        defer { cleanUp() }
        #expect(AgentComposerStore.queueRetryDelay(afterFailures: 0) == .seconds(2))
        #expect(AgentComposerStore.queueRetryDelay(afterFailures: 3) == .seconds(16))
        #expect(AgentComposerStore.queueRetryDelay(afterFailures: 20) == .seconds(300))

        let harness = OutboxHarness(hostID: hostID, directory: directory)
        let prompts = PromptLog()
        let composer = harness.makeComposer { params in
            await prompts.append(params.text)
            throw RequestNotSentError(cause: TransportError.sshUnreachable(detail: "down"))
        }
        composer.replaceDraft(with: "keep trying")
        #expect(await composer.send() == .queued)
        try await waitUntil("the first backoff should be waiting") {
            await harness.sleeper.delays == [.seconds(2)]
        }

        await harness.sleeper.releaseAll()
        try await waitUntil("a second failure should double the wait") {
            await harness.sleeper.delays == [.seconds(2), .seconds(4)]
        }
        #expect(await prompts.texts.count == 2)

        // A reconnect cancels the pending wait and tries at once.
        composer.drainQueue()
        try await waitUntil("the reconnect attempt should start the backoff over") {
            await harness.sleeper.delays == [.seconds(2), .seconds(4), .seconds(2)]
        }
        #expect(await prompts.texts.count == 3)
        #expect(composer.messages.map(\.state) == [.queued])
    }

    // MARK: A launch's first message

    /// A kind with no first-message flag gets it from the queue: it waits
    /// while the pane lists no Agent of its own yet (no row, herdr's pending
    /// launch, the shell before the Agent starts), never holds, and goes out
    /// once, ahead of a message the user sent meanwhile, which waits for the
    /// launched Agent too.
    @Test func aLaunchsFirstMessageWaitsForItsAgentAndGoesOutOnce() async throws {
        defer { cleanUp() }
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        harness.identity = nil
        let prompts = PromptLog()
        let composer = harness.makeComposer { params in
            await prompts.append(params.text)
            return Self.agent(paneID: params.target)
        }
        let launched = QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "copilot", session: nil)
        #expect(composer.queueLaunchMessage("read the page", for: launched) == .queued)
        #expect(harness.store.messages(on: hostID).map(\.agent) == [launched])
        try await waitUntil("the queue should wait for the launch") {
            await harness.sleeper.delays == [.milliseconds(500)]
        }
        #expect(composer.messages.map(\.state) == [.queued])

        composer.replaceDraft(with: "and then this")
        #expect(await composer.send() == .queued)
        #expect(harness.store.messages(on: hostID).map(\.agent) == [launched, launched])

        for pending in [Agent.unidentifiedKind, Agent.shellKind] {
            harness.identity = QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: pending, session: nil)
            let waits = await harness.sleeper.delays.count
            await harness.sleeper.releaseAll()
            try await waitUntil("a pane listing \(pending) is still the launch") {
                await harness.sleeper.delays.count == waits + 1
            }
            #expect(composer.messages.map(\.state) == [.queued, .queued])
        }
        #expect(await prompts.texts.isEmpty)

        harness.identity = QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "copilot", session: "s-1")
        await harness.sleeper.releaseAll()
        try await waitUntil("both should be delivered") {
            composer.messages.allSatisfy { $0.state == .delivered(.acknowledged) }
        }
        #expect(await prompts.texts == ["read the page", "and then this"])
        #expect(harness.store.messages(on: hostID).isEmpty)
    }

    /// A launch's first message is counted with its launch, so the Composer
    /// does not count it again when it goes out; a message the user sends
    /// meanwhile does count.
    @Test func aLaunchsFirstMessageIsNotCountedAgainWhenDelivered() async throws {
        defer { cleanUp() }
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        harness.identity = QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "copilot", session: "s-1")
        let composer = harness.makeComposer { params in Self.agent(paneID: params.target) }
        var delivered = 0
        composer.onAgentMessageDelivered = { delivered += 1 }
        let launched = QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "copilot", session: nil)

        composer.queueLaunchMessage("read the page", for: launched)
        try await waitUntil("the first message should be delivered") {
            composer.messages.allSatisfy { $0.state == .delivered(.acknowledged) }
        }
        #expect(delivered == 0)

        composer.replaceDraft(with: "and this")
        await composer.send()
        #expect(delivered == 1)
    }

    /// herdr 0.9.1 answers a fresh pane `agent_not_found` for a moment: a
    /// launch's first message tries again instead of being held.
    @Test func aLaunchsFirstMessageWaitsOutAFreshPanesAgentNotFound() async throws {
        defer { cleanUp() }
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        harness.identity = QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "copilot", session: nil)
        let prompts = PromptLog()
        let composer = harness.makeComposer { params in
            await prompts.append(params.text)
            if await prompts.texts.count == 1 {
                throw HerdrAPIError(code: "agent_not_found", message: "agent target w1:p1 not found")
            }
            return Self.agent(paneID: params.target)
        }
        composer.queueLaunchMessage(
            "read the page",
            for: QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "copilot", session: nil))
        try await waitUntil("the refused prompt should wait for the launch") {
            await harness.sleeper.delays == [.milliseconds(500)]
        }
        #expect(composer.messages.map(\.state) == [.queued])
        #expect(harness.store.messages(on: hostID).first?.promptStartedAt == nil)

        await harness.sleeper.releaseAll()
        try await waitUntil("it should be delivered") {
            composer.messages.map(\.state) == [.delivered(.acknowledged)]
        }
        #expect(await prompts.texts == ["read the page", "read the page"])
    }

    @Test func anIdleWakeDuringABlockedPromptIsRemembered() async throws {
        defer { cleanUp() }
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        let prompts = PromptLog()
        let gate = ScriptedTransportCallGate()
        let composer = harness.makeComposer { params in
            await prompts.append(params.text)
            if await prompts.texts.count == 1 {
                await gate.waitUntilOpen()
                throw HerdrAPIError(code: "agent_blocked", message: "blocked")
            }
            return Self.agent(paneID: params.target)
        }
        composer.queueLaunchMessage("hello", for: try #require(harness.identity))
        await gate.waitForEntry()
        composer.agentStatusDidChange(.blocked)
        composer.agentStatusDidChange(.idle)
        await gate.open()
        try await waitUntil("the idle wake should resume the queue") {
            composer.messages.map(\.state) == [.delivered(.acknowledged)]
        }
        #expect(await prompts.texts == ["hello", "hello"])
        #expect(await harness.sleeper.delays.isEmpty)
    }

    /// A launch's first message never types into a question on screen
    /// (a folder-trust dialog): it goes out once the Agent is past it.
    @Test func aLaunchsFirstMessageWaitsOutABlockedAgent() async throws {
        defer { cleanUp() }
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        harness.identity = QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "copilot", session: nil)
        let prompts = PromptLog()
        let composer = harness.makeComposer { params in
            await prompts.append(params.text)
            return Self.agent(paneID: params.target)
        }
        composer.agentStatusDidChange(.blocked)
        composer.queueLaunchMessage(
            "read the page",
            for: QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "copilot", session: nil))
        try await Task.sleep(for: .milliseconds(50))
        #expect(composer.messages.map(\.state) == [.queued])
        #expect(await prompts.texts.isEmpty)

        composer.agentStatusDidChange(.idle)
        try await waitUntil("it should go out once the question is answered") {
            composer.messages.map(\.state) == [.delivered(.acknowledged)]
        }
        #expect(await prompts.texts == ["read the page"])
    }

    /// Past its launch window, a first message is a Queued Message like any
    /// other: a pane that still lists no Agent of its kind holds it.
    @Test func aLaunchsFirstMessagePastItsWindowIsHeld() async throws {
        defer { cleanUp() }
        let harness = OutboxHarness(hostID: hostID, directory: directory)
        harness.identity = QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: Agent.shellKind, session: nil)
        let prompts = PromptLog()
        let composer = harness.makeComposer(agentNotReadyRetryBudget: .zero) { params in
            await prompts.append(params.text)
            return Self.agent(paneID: params.target)
        }
        composer.queueLaunchMessage(
            "read the page",
            for: QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "copilot", session: nil))
        try await waitUntil("it should be held") {
            composer.messages.first?.state == .held(AgentComposerStore.agentChangedMessage)
        }
        #expect(await prompts.texts.isEmpty)
        #expect(await harness.sleeper.delays.isEmpty)
    }

    /// The Console hands a launch's first message to the Agent's Composer,
    /// made for it: it is on the device at once and goes out to the pane.
    @Test func theConsoleQueuesALaunchsFirstMessageForItsAgent() async throws {
        defer { cleanUp() }
        let host = Host.fixture(id: hostID)
        let store = QueuedMessageStore(directory: directory)
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", kind: "copilot")]))
        let console = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(
                defaults: UserDefaults(suiteName: "queued-pins-\(UUID().uuidString)")
                    ?? .standard),
            queuedMessages: store
        ) { _, _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        defer { console.setHosts([]) }
        let id = ConsoleAgent.ID(hostID: hostID, paneID: "w1:p1")
        console.setHosts([host])
        await console.resume()
        try await waitUntil("the Host's rows should be listed") {
            console.agents.contains { $0.id == id }
        }

        console.queueLaunchMessage(
            "read the page",
            for: QueuedMessage.AgentIdentity(paneID: "w1:p1", kind: "copilot", session: nil),
            on: hostID)
        #expect(store.messages(on: hostID).map(\.draftText) == ["read the page"])
        try await waitUntil("the first message should reach the pane") {
            await transport.agentPromptParams == [AgentPromptParams(target: "w1:p1", text: "read the page")]
        }
        try await waitUntil("the delivered message should leave the device") {
            console.queuedMessageCounts[id] == nil && store.messages(on: hostID).isEmpty
        }
    }

    // MARK: Support

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    private nonisolated static func agent(paneID: String) -> Agent {
        Agent(
            terminalID: "term", kind: "claude", title: "Task", status: .idle,
            workspaceID: "w1", tabID: "w1:t1", paneID: paneID, cwd: "/work", revision: 1)
    }
}

/// A Composer outbox under test: an on-disk store in a scratch folder, an
/// identity and drain gate the test sets, a fake prepare/upload that copies
/// and names files, and a manual backoff clock.
@MainActor
private final class OutboxHarness {
    let hostID: Host.ID
    let store: QueuedMessageStore
    let sleeper = ManualSleeper()
    var identity: QueuedMessage.AgentIdentity? = QueuedMessage.AgentIdentity(
        paneID: "w1:p1", kind: "claude", session: nil)
    var mayDrain = true
    /// Makes the next prompt fail unsent once, so a Send queues.
    var unsentOnce = false
    var uploadLog: PromptLog?
    /// Runs on the main actor once each upload lands.
    var onUpload: (@MainActor () -> Void)?
    /// Makes every upload throw this.
    var uploadError: (any Error)?
    var preparationGate: ScriptedTransportCallGate?
    private(set) var counts: [Int] = []

    init(hostID: Host.ID, directory: URL) {
        self.hostID = hostID
        store = QueuedMessageStore(directory: directory)
    }

    func makeComposer(
        paneID: String = "w1:p1",
        agentNotReadyRetryBudget: Duration = .seconds(45),
        prompt: @escaping @Sendable (AgentPromptParams) async throws -> Agent
    ) -> AgentComposerStore {
        let sleeper = sleeper
        let log = uploadLog
        let preparationGate = preparationGate
        let outbox = ComposerOutbox(
            hostID: hostID, store: store,
            identity: { [weak self] in
                guard let identity = self?.identity else { return nil }
                return QueuedMessage.AgentIdentity(
                    paneID: paneID, kind: identity.kind, session: identity.session)
            },
            mayDrain: { [weak self] in self?.mayDrain ?? false },
            prepare: { source, directory in
                await preparationGate?.waitUntilOpen()
                guard case .file(let url) = source else {
                    throw AttachmentStagingError.invalidPreparedSource
                }
                let name = UUID().uuidString + ".txt"
                try FileManager.default.copyItem(
                    at: url, to: directory.appending(path: name, directoryHint: .notDirectory))
                return QueuedMessage.Attachment(
                    id: UUID(), kind: .file, fileName: url.lastPathComponent,
                    localFileName: name, fileExtension: "txt", pixelWidth: nil,
                    pixelHeight: nil, byteCount: 6, hostPath: nil)
            },
            upload: { [weak self] attachment, _ in
                if let error = await self?.uploadError { throw error }
                let name = attachment.fileName ?? "file"
                await log?.append("upload:\(name)")
                await self?.onUpload?()
                return "/host/staged/\(name)"
            },
            sleep: { delay in try await sleeper.sleep(delay) },
            countDidChange: { [weak self] count in self?.counts.append(count) })
        let store = AgentComposerStore(
            target: paneID, agentNotReadyRetryBudget: agentNotReadyRetryBudget, outbox: outbox
        ) { [weak self] params in
            if await self?.takeUnsentOnce() == true {
                throw RequestNotSentError(cause: TransportError.sshUnreachable(detail: "down"))
            }
            return try await prompt(params)
        }
        return store
    }

    private func takeUnsentOnce() -> Bool {
        defer { unsentOnce = false }
        return unsentOnce
    }
}

/// What the fake Host saw, in order, and whether it is reachable.
private actor PromptLog {
    private(set) var texts: [String] = []
    private(set) var isOffline = true

    func append(_ text: String) {
        texts.append(text)
    }

    func setOffline(_ offline: Bool) {
        isOffline = offline
    }
}

/// A backoff clock the test advances: each wait is recorded and parked
/// until `releaseAll()`, and a cancelled wait throws at once.
private actor ManualSleeper {
    private(set) var delays: [Duration] = []
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var cancelled: Set<UUID> = []

    func sleep(_ delay: Duration) async throws {
        delays.append(delay)
        let id = UUID()
        try await withTaskCancellationHandler {
            try await park(id)
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func park(_ id: UUID) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            if cancelled.remove(id) != nil {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters[id] = continuation
            }
        }
    }

    func releaseAll() {
        let parked = waiters.values
        waiters.removeAll()
        for waiter in parked { waiter.resume() }
    }

    private func cancel(_ id: UUID) {
        if let waiter = waiters.removeValue(forKey: id) {
            waiter.resume(throwing: CancellationError())
        } else {
            cancelled.insert(id)
        }
    }
}
