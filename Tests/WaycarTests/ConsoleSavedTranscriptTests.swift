import Foundation
import Testing

@testable import Waycar

private func savedTestSnapshot(
    status: AgentStatus = .idle, terminalID: String = "term_w1:p1", session: String? = "s-1",
    kind: String = "cursor"
) -> SessionSnapshot {
    // A kind the background reads leave alone, unless a test asks for one they read.
    let info = AgentInfo(
        agentStatus: status, focused: false, paneID: "w1:p1", revision: 1,
        tabID: "w1:t1", terminalID: terminalID, workspaceID: "w1", agent: kind,
        agentSession: session.map {
            AgentSessionInfo(agent: kind, kind: .id, source: "hook", value: $0)
        },
        cwd: "/work/w1")
    return SessionSnapshot(
        agents: [info], layouts: [],
        panes: [
            PaneInfo(
                agentStatus: status, focused: false, paneID: "w1:p1", revision: 1,
                tabID: "w1:t1", terminalID: terminalID, workspaceID: "w1", cwd: "/work/w1",
                terminalTitleStripped: "zsh")
        ],
        protocolVersion: 22,
        tabs: [
            TabInfo(
                agentStatus: status, focused: false, label: "Main", number: 1, paneCount: 1,
                tabID: "w1:t1", workspaceID: "w1")
        ],
        version: "0.9.0", workspaces: [.fixture(workspaceID: "w1", label: "Project")])
}

private func transcriptReply(
    _ status: ChatTranscriptHeader.Status = .ok, messages: [ChatTranscriptMessage],
    truncated: Bool = false
) -> ChatTranscriptSnapshot {
    ChatTranscriptSnapshot(
        header: ChatTranscriptHeader(
            kind: "claude", status: status, transcript: "/t/s-1.jsonl", activity: nil,
            turnOpen: false, truncated: truncated, error: nil),
        messages: messages)
}

/// The Console's side of offline reading: what a read of the whole
/// conversation keeps, and what it never writes into a copy that is not the
/// Agent's own.
@MainActor
@Suite("Saved transcripts through the Console", .timeLimit(.minutes(1)))
struct ConsoleSavedTranscriptTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-console-saved-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func makeCache() -> (ChatTranscriptCache, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "hm-saved-transcripts-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (
            ChatTranscriptCache(directory: directory),
            { try? FileManager.default.removeItem(at: directory) }
        )
    }

    private func makeConsole(
        _ transport: ScriptedTransport, defaults: UserDefaults, cache: ChatTranscriptCache
    ) -> ConsoleStore {
        ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults),
            chatMode: ChatModeStore(defaults: defaults),
            chatTranscriptCache: cache
        ) { _, _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
    }

    private func connect(_ store: ConsoleStore, _ host: Host) async throws {
        store.setHosts([host])
        await store.resume()
        try await waitUntilTrue("the snapshot should verify the row") {
            store.agents.count == 1 && !store.hostsAwaitingSnapshot.contains(host.id)
        }
    }

    /// The Host lists a marker for a pane it does not run: the marker read
    /// connecting starts settles the Host, which the background reads wait for.
    private func listAMarker(on transport: ScriptedTransport) async {
        await transport.setChatModeMarkers([
            ChatModeMarker(
                paneID: "w9:gone", terminalID: "term_w9", kind: "claude", cwd: "/work/w9",
                session: nil, launchedAt: Date())
        ])
    }

    @Test func readingAWholeConversationKeepsItForReadingOffline() async throws {
        let (defaults, cleanupDefaults) = try makeDefaults()
        defer { cleanupDefaults() }
        let (cache, cleanupCache) = makeCache()
        defer { cleanupCache() }
        let host = Host.fixture()
        // No session: the background reads leave this agent to its screen.
        let transport = ScriptedTransport(snapshot: savedTestSnapshot())
        let messages = transcriptMessages(0..<4)
        await transport.setChatTranscriptResponder { _ in transcriptReply(messages: messages) }
        let store = makeConsole(transport, defaults: defaults, cache: cache)
        try await connect(store, host)
        defer { store.setHosts([]) }
        let row = try #require(store.agents.first)
        #expect(store.savedTranscript(for: row) == nil)

        let answered = try await store.readChatTranscriptSaving(for: row)

        #expect(answered.messages == messages)
        #expect(try #require(store.savedTranscript(for: row)).messages == messages)
        #expect(store.savedTranscriptRevisions[row.id] == 1)
    }

    @Test func aSecondReadNeverShrinksWhatTheFirstKept() async throws {
        let (defaults, cleanupDefaults) = try makeDefaults()
        defer { cleanupDefaults() }
        let (cache, cleanupCache) = makeCache()
        defer { cleanupCache() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: savedTestSnapshot())
        let long = transcriptMessages(0..<8)
        let cut = transcriptMessages(4..<10)
        await transport.setChatTranscriptResponder { _ in transcriptReply(messages: long) }
        let store = makeConsole(transport, defaults: defaults, cache: cache)
        try await connect(store, host)
        defer { store.setHosts([]) }
        let row = try #require(store.agents.first)
        _ = try await store.readChatTranscriptSaving(for: row)

        // The Host's reader now sends only its newest six.
        await transport.setChatTranscriptResponder { _ in
            transcriptReply(messages: cut, truncated: true)
        }
        _ = try await store.readChatTranscriptSaving(for: row)

        #expect(try #require(store.savedTranscript(for: row)).messages == transcriptMessages(0..<10))
    }

    @Test func aReadThatFoundNoTranscriptKeepsNothing() async throws {
        let (defaults, cleanupDefaults) = try makeDefaults()
        defer { cleanupDefaults() }
        let (cache, cleanupCache) = makeCache()
        defer { cleanupCache() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: savedTestSnapshot())
        await transport.setChatTranscriptResponder { _ in transcriptReply(.notFound, messages: []) }
        let store = makeConsole(transport, defaults: defaults, cache: cache)
        try await connect(store, host)
        defer { store.setHosts([]) }
        let row = try #require(store.agents.first)

        let answered = try await store.readChatTranscriptSaving(for: row)

        #expect(answered.header.status == .notFound)
        #expect(store.savedTranscript(for: row) == nil)
    }

    @Test func aReadThatOutlivedItsTerminalWritesIntoNoOnesCopy() async throws {
        let (defaults, cleanupDefaults) = try makeDefaults()
        defer { cleanupDefaults() }
        let (cache, cleanupCache) = makeCache()
        defer { cleanupCache() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: savedTestSnapshot())
        let stale = [ChatTranscriptMessage(id: "old", role: .user, text: "the old agent", timestamp: nil)]
        let gate = ScriptedTransportCallGate()
        await transport.setChatTranscriptReadGate(gate)
        await transport.setChatTranscriptResponder { _ in transcriptReply(messages: stale) }
        let store = makeConsole(transport, defaults: defaults, cache: cache)
        try await connect(store, host)
        defer { store.setHosts([]) }
        let row = try #require(store.agents.first)
        let oldKey = store.chatTranscriptKey(for: row)

        let read = Task { try await store.readChatTranscriptSaving(for: row) }
        await gate.waitForEntry()
        // Another Agent takes the pane while the Host answers.
        await transport.setSnapshot(savedTestSnapshot(terminalID: "term_other"))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneClosed.kind, data: .object([:]))))
        try await waitUntilTrue("the pane should list the other terminal") {
            store.agents.first?.agent.terminalID == "term_other"
        }
        await gate.open()
        _ = try await read.value

        let identity = "s:cursor/s-1"
        #expect(cache.messages(for: oldKey, identity: identity).isEmpty)
        let replacement = try #require(store.agents.first)
        #expect(
            cache.messages(for: store.chatTranscriptKey(for: replacement), identity: identity)
                .isEmpty)
    }

    /// herdr keeps pane and terminal ids when an Agent typed into the same
    /// pane replaces the one there (or a restart resumes it under a new
    /// session): the session is what tells the two apart.
    @Test func aReadThatOutlivedItsSessionWritesIntoNoOnesCopy() async throws {
        let (defaults, cleanupDefaults) = try makeDefaults()
        defer { cleanupDefaults() }
        let (cache, cleanupCache) = makeCache()
        defer { cleanupCache() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: savedTestSnapshot(session: "s-1"))
        let gate = ScriptedTransportCallGate()
        await transport.setChatTranscriptReadGate(gate)
        await transport.setChatTranscriptResponder { _ in transcriptReply(messages: transcriptMessages(0..<3)) }
        let store = makeConsole(transport, defaults: defaults, cache: cache)
        try await connect(store, host)
        defer { store.setHosts([]) }
        let row = try #require(store.agents.first)

        let read = Task { try await store.readChatTranscriptSaving(for: row) }
        await gate.waitForEntry()
        // The same terminal, another Agent: a new session.
        await transport.setSnapshot(savedTestSnapshot(session: "s-2"))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneClosed.kind, data: .object([:]))))
        try await waitUntilTrue("the pane should report the other session") {
            store.agents.first?.agent.agentSession?.value == "s-2"
        }
        await gate.open()
        _ = try await read.value

        let replacement = try #require(store.agents.first)
        #expect(store.savedTranscript(for: replacement) == nil)
        let key = store.chatTranscriptKey(for: replacement)
        #expect(cache.messages(for: key, identity: "s:cursor/s-1").isEmpty)
        #expect(cache.messages(for: key, identity: "s:cursor/s-2").isEmpty)
    }

    /// A copy saved for one session is never shown for, or merged into, the
    /// Agent the next session belongs to: the next read replaces it.
    @Test func aCopyOfAnotherSessionIsNeitherShownNorMergedInto() async throws {
        let (defaults, cleanupDefaults) = try makeDefaults()
        defer { cleanupDefaults() }
        let (cache, cleanupCache) = makeCache()
        defer { cleanupCache() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: savedTestSnapshot(session: "s-1"))
        await transport.setChatTranscriptResponder { _ in transcriptReply(messages: transcriptMessages(0..<4)) }
        let store = makeConsole(transport, defaults: defaults, cache: cache)
        try await connect(store, host)
        defer { store.setHosts([]) }
        _ = try await store.readChatTranscriptSaving(for: try #require(store.agents.first))

        await transport.setSnapshot(savedTestSnapshot(session: "s-2"))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneClosed.kind, data: .object([:]))))
        try await waitUntilTrue("the pane should report the other session") {
            store.agents.first?.agent.agentSession?.value == "s-2"
        }
        let second = try #require(store.agents.first)
        #expect(store.savedTranscript(for: second) == nil, "the first Agent's text is not shown")

        // Its own read overlaps the first's, yet nothing of the first survives.
        await transport.setChatTranscriptResponder { _ in transcriptReply(messages: transcriptMessages(2..<6)) }
        _ = try await store.readChatTranscriptSaving(for: second)
        #expect(try #require(store.savedTranscript(for: second)).messages == transcriptMessages(2..<6))
    }

    /// An Agent that reports no session has no identity: nothing is kept for
    /// it. Once the session appears (a launch just started) the next read
    /// keeps its conversation; nothing waits orphaned under "no session".
    @Test func nothingIsKeptUntilTheAgentReportsASession() async throws {
        let (defaults, cleanupDefaults) = try makeDefaults()
        defer { cleanupDefaults() }
        let (cache, cleanupCache) = makeCache()
        defer { cleanupCache() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: savedTestSnapshot(session: nil))
        let gate = ScriptedTransportCallGate()
        await transport.setChatTranscriptReadGate(gate)
        await transport.setChatTranscriptResponder { _ in transcriptReply(messages: transcriptMessages(0..<3)) }
        let store = makeConsole(transport, defaults: defaults, cache: cache)
        try await connect(store, host)
        defer { store.setHosts([]) }
        let row = try #require(store.agents.first)
        #expect(store.transcriptIdentity(for: row) == nil)

        // A read with no session behind it keeps nothing...
        await gate.open()
        _ = try await store.readChatTranscriptSaving(for: row)
        #expect(store.savedTranscript(for: row) == nil)

        // ...and neither does one the session appears during.
        let second = ScriptedTransportCallGate()
        await transport.setChatTranscriptReadGate(second)
        let read = Task { try await store.readChatTranscriptSaving(for: row) }
        await second.waitForEntry()
        await transport.setSnapshot(savedTestSnapshot(session: "s-1"))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneClosed.kind, data: .object([:]))))
        try await waitUntilTrue("the session should appear") {
            store.agents.first?.agent.agentSession?.value == "s-1"
        }
        await second.open()
        _ = try await read.value
        let withSession = try #require(store.agents.first)
        #expect(store.savedTranscript(for: withSession) == nil)

        // The next read, with the session known, keeps it.
        _ = try await store.readChatTranscriptSaving(for: withSession)
        #expect(try #require(store.savedTranscript(for: withSession)).messages == transcriptMessages(0..<3))
    }

    /// A Chat Marker whose kind no longer matches the pane's Agent describes
    /// another Agent: a codex typed into a former chat claude's pane neither
    /// shows nor overwrites the claude's copy.
    @Test func aMarkerThatNoLongerAppliesNeitherShowsNorReceivesTheFormerChatsCopy() async throws {
        let (defaults, cleanupDefaults) = try makeDefaults()
        defer { cleanupDefaults() }
        let (cache, cleanupCache) = makeCache()
        defer { cleanupCache() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: savedTestSnapshot(session: "s-1", kind: "claude"))
        let store = makeConsole(transport, defaults: defaults, cache: cache)
        try await connect(store, host)
        defer { store.setHosts([]) }
        store.chatMode.record(
            ChatModeMarker(
                paneID: "w1:p1", terminalID: "term_w1:p1", kind: "claude", cwd: "/work/w1",
                session: nil, launchedAt: Date(timeIntervalSince1970: 1_790_000_000)),
            hostID: host.id)
        let chat = try #require(store.agents.first)
        let chatKey = store.chatTranscriptKey(for: chat)
        #expect(!chatKey.launchedAt.isEmpty)
        #expect(store.transcriptIdentity(for: chat) == "")
        let chatCopy = transcriptMessages(0..<4)
        cache.save(chatCopy, for: chatKey)

        // The same pane and terminal now run codex.
        await transport.setSnapshot(savedTestSnapshot(session: "s-2", kind: "codex"))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneClosed.kind, data: .object([:]))))
        try await waitUntilTrue("the pane should run codex") { store.agents.first?.agent.kind == "codex" }
        let codex = try #require(store.agents.first)
        #expect(store.chatTranscriptKey(for: codex) != chatKey)
        #expect(store.transcriptIdentity(for: codex) == "s:codex/s-2")
        #expect(store.savedTranscript(for: codex) == nil, "the claude's conversation is not shown")

        let codexCopy = transcriptMessages(10..<12)
        await transport.setChatTranscriptResponder { _ in transcriptReply(messages: codexCopy) }
        _ = try await store.readChatTranscriptSaving(for: codex)
        #expect(try #require(store.savedTranscript(for: codex)).messages == codexCopy)
        // The replaced chat's copy goes with it (`agentsDidClose`); either way
        // none of codex's text is written into it.
        #expect(cache.messages(for: chatKey) != codexCopy)
        #expect(cache.messages(for: chatKey) == [] || cache.messages(for: chatKey) == chatCopy)
    }

    /// A plain launch's pin names a launch but not a session: when another
    /// session takes the terminal, its copy does not inherit the first's.
    @Test func aPlainPinnedLaunchDoesNotPassItsCopyToTheNextSession() async throws {
        let (defaults, cleanupDefaults) = try makeDefaults()
        defer { cleanupDefaults() }
        let (cache, cleanupCache) = makeCache()
        defer { cleanupCache() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: savedTestSnapshot(session: "s-1"))
        await transport.setChatTranscriptResponder { _ in transcriptReply(messages: transcriptMessages(0..<4)) }
        let store = makeConsole(transport, defaults: defaults, cache: cache)
        try await connect(store, host)
        defer { store.setHosts([]) }
        store.chatMode.record(
            ChatModeMarker(
                paneID: "w1:p1", terminalID: "term_w1:p1", kind: "cursor", cwd: "/work/w1",
                session: nil, chatMode: false,
                launchedAt: Date(timeIntervalSince1970: 1_790_000_000)),
            hostID: host.id)
        let first = try #require(store.agents.first)
        #expect(!store.chatTranscriptKey(for: first).launchedAt.isEmpty)
        #expect(store.transcriptIdentity(for: first) == "s:cursor/s-1")
        _ = try await store.readChatTranscriptSaving(for: first)
        #expect(store.savedTranscript(for: first) != nil)

        await transport.setSnapshot(savedTestSnapshot(session: "s-2"))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneClosed.kind, data: .object([:]))))
        try await waitUntilTrue("the pane should report the next session") {
            store.agents.first?.agent.agentSession?.value == "s-2"
        }
        let second = try #require(store.agents.first)
        #expect(store.savedTranscript(for: second) == nil)
        await transport.setChatTranscriptResponder { _ in transcriptReply(messages: transcriptMessages(2..<6)) }
        _ = try await store.readChatTranscriptSaving(for: second)
        #expect(try #require(store.savedTranscript(for: second)).messages == transcriptMessages(2..<6))
    }

    @Test func aClosedAgentsSavedConversationGoesWithIt() async throws {
        let (defaults, cleanupDefaults) = try makeDefaults()
        defer { cleanupDefaults() }
        let (cache, cleanupCache) = makeCache()
        defer { cleanupCache() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: savedTestSnapshot())
        await transport.setChatTranscriptResponder { _ in transcriptReply(messages: transcriptMessages(0..<3)) }
        let store = makeConsole(transport, defaults: defaults, cache: cache)
        try await connect(store, host)
        defer { store.setHosts([]) }
        let row = try #require(store.agents.first)
        let key = store.chatTranscriptKey(for: row)
        _ = try await store.readChatTranscriptSaving(for: row)
        #expect(store.savedTranscript(for: row) != nil)

        await transport.setSnapshot(.fixture(agents: []))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneClosed.kind, data: .object([:]))))
        try await waitUntilTrue("the closed agent should leave the list") {
            store.agents.isEmpty
        }
        cache.flush()

        #expect(cache.messages(for: key, identity: "s:cursor/s-1").isEmpty)
    }

    @Test func aFinishedAgentIsReadAndKeptOnceItsHostSettles() async throws {
        let (defaults, cleanupDefaults) = try makeDefaults()
        defer { cleanupDefaults() }
        let (cache, cleanupCache) = makeCache()
        defer { cleanupCache() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: savedTestSnapshot(session: "s-1", kind: "claude"))
        let messages = transcriptMessages(0..<3)
        await listAMarker(on: transport)
        await transport.setChatTranscriptResponder { _ in transcriptReply(messages: messages) }
        let store = makeConsole(transport, defaults: defaults, cache: cache)
        try await connect(store, host)
        defer { store.setHosts([]) }
        let row = try #require(store.agents.first)

        try await waitUntilTrue("the finished agent should be read without being opened") {
            store.savedTranscript(for: row)?.messages == messages
        }
        #expect(await transport.chatTranscriptRequests.count == 1)
    }

    /// The Host settles (its markers land, which is what the background reads
    /// wait for) with the agent still working; only once it finishes is it
    /// read, so no request was ever built for a working agent.
    @Test func anAgentStillWorkingIsNotReadInTheBackground() async throws {
        let (defaults, cleanupDefaults) = try makeDefaults()
        defer { cleanupDefaults() }
        let (cache, cleanupCache) = makeCache()
        defer { cleanupCache() }
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: savedTestSnapshot(status: .working, session: "s-1", kind: "claude"))
        await listAMarker(on: transport)
        await transport.setChatTranscriptResponder { _ in transcriptReply(messages: transcriptMessages(0..<3)) }
        let store = makeConsole(transport, defaults: defaults, cache: cache)
        try await connect(store, host)
        defer { store.setHosts([]) }
        try await waitUntilTrue("the Host's markers should land") {
            store.chatMode.marker(for: ConsoleAgent.ID(hostID: host.id, paneID: "w9:gone")) != nil
        }

        await transport.setSnapshot(savedTestSnapshot(status: .idle, session: "s-1", kind: "claude"))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneClosed.kind, data: .object([:]))))
        try await waitUntilTrue("the agent should finish") {
            store.agents.first?.agent.status == .idle
        }
        try await waitUntilTrue("the finished agent should be read") {
            await !transport.chatTranscriptRequests.isEmpty
        }

        let requests = await transport.chatTranscriptRequests
        #expect(requests.map(\.status) == [.idle])
    }
}
