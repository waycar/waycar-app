import Foundation
import Testing

@testable import Waycar

/// Chat Mode through the Console: launch records, Host marker refreshes,
/// transcript requests and the Chat view's pane input.
@MainActor
@Suite("Console Chat Mode", .timeLimit(.minutes(1)))
struct ConsoleChatModeTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-console-chat-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func makeConsole(
        _ transport: ScriptedTransport, defaults: UserDefaults, chatMode: ChatModeStore? = nil,
        chatTranscriptCache: ChatTranscriptCache? = nil, chatMediaCache: ChatMediaCache? = nil
    ) -> ConsoleStore {
        ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults),
            chatMode: chatMode ?? ChatModeStore(defaults: defaults),
            chatTranscriptCache: chatTranscriptCache,
            chatMediaCache: chatMediaCache
        ) { _, _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
    }

    private func makeCacheDirectory() -> (URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "hm-chat-transcripts-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (directory, { try? FileManager.default.removeItem(at: directory) })
    }

    /// Connects `host` and waits for its rows to be verified.
    private func connect(_ store: ConsoleStore, _ host: Host, agents: Int) async throws {
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the snapshot should verify the rows") {
            store.agents.count == agents && !store.hostsAwaitingSnapshot.contains(host.id)
        }
    }

    /// Connects `host` and waits for the Chat Marker read connecting starts
    /// to land; the Host lists a marker for a pane it does not run so the
    /// landing shows. The next read is `chatModeMarkerRefreshInterval`
    /// away, so nothing the test records afterwards is read over or
    /// written back meanwhile.
    private func connectReadingMarkers(
        _ store: ConsoleStore, _ transport: ScriptedTransport, _ host: Host, agents: Int
    ) async throws {
        let probe = marker("w9:gone")
        await transport.setChatModeMarkers([probe])
        try await connect(store, host, agents: agents)
        try await waitUntil("connecting should read the Host's markers") {
            store.chatMode.marker(for: ConsoleAgent.ID(hostID: host.id, paneID: probe.paneID))
                == probe
        }
    }

    private func marker(
        _ paneID: String, kind: String = "claude", session: String? = nil,
        cwd: String? = "/work/w1", launchedAt: Date = Date()
    ) -> ChatModeMarker {
        ChatModeMarker(
            paneID: paneID, terminalID: "term_\(paneID)", kind: kind, cwd: cwd,
            session: session.map { ChatModeMarker.Session(kind: "id", value: $0) },
            launchedAt: launchedAt)
    }

    private func header(
        _ status: ChatTranscriptHeader.Status, transcript: String?
    ) -> ChatTranscriptHeader {
        ChatTranscriptHeader(
            kind: "codex", status: status, transcript: transcript, activity: nil,
            turnOpen: false, truncated: false, error: nil)
    }

    /// Pane w1:p1 running claude in `session`, or back at its shell when nil.
    private func paneSnapshot(claudeSession session: String?) -> SessionSnapshot {
        paneSnapshot(claude: session.map { claudeInfo(session: $0) })
    }

    /// claude in pane w1:p1 on `terminalID`, reporting `session` once it has one.
    private func claudeInfo(terminalID: String = "term_w1:p1", session: String?) -> AgentInfo {
        AgentInfo(
            agentStatus: .idle, focused: false, paneID: "w1:p1", revision: 1,
            tabID: "w1:t1", terminalID: terminalID, workspaceID: "w1",
            agent: "claude",
            agentSession: session.map {
                AgentSessionInfo(agent: "claude", kind: .id, source: "hook", value: $0)
            },
            cwd: "/work/w1")
    }

    /// Pane w1:p1 running `claude`, or its shell on `shellTerminalID` when nil.
    private func paneSnapshot(
        claude: AgentInfo?, shellTerminalID: String = "term_w1:p1"
    ) -> SessionSnapshot {
        SessionSnapshot(
            agents: claude.map { [$0] } ?? [],
            layouts: [],
            panes: [
                PaneInfo(
                    agentStatus: .idle, focused: false, paneID: "w1:p1", revision: 1,
                    tabID: "w1:t1", terminalID: claude?.terminalID ?? shellTerminalID,
                    workspaceID: "w1", cwd: "/work/w1", terminalTitleStripped: "zsh")
            ],
            protocolVersion: 22,
            tabs: [
                TabInfo(
                    agentStatus: .idle, focused: false, label: "Main", number: 1, paneCount: 1,
                    tabID: "w1:t1", workspaceID: "w1")
            ],
            version: "0.9.0",
            workspaces: [.fixture(workspaceID: "w1", label: "Project")])
    }

    /// Waits out the gap a dropped stream opens (the default reconnect
    /// waits a second first) and the new connection's verification.
    private func reverify(_ store: ConsoleStore, _ host: Host) async throws {
        try await waitUntil("the drop should unverify the rows") {
            store.hostsAwaitingSnapshot.contains(host.id)
        }
        try await waitUntil("the Host should verify on its new connection") {
            store.hostStatuses[host.id] == .connected
                && !store.hostsAwaitingSnapshot.contains(host.id)
        }
    }

    /// Serves `snapshot` on the next resync and triggers one.
    private func resync(_ transport: ScriptedTransport, to snapshot: SessionSnapshot) async {
        await transport.setSnapshot(snapshot)
        #expect(
            await transport.emit(HerdrEvent(kind: GlobalEventKind.paneExited.kind, data: .object([:]))))
    }

    @Test func aLaunchShowsChatAtOnceAndWritesTheMarkerToTheHost() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .working),
                .fixture(paneID: "w1:p2", status: .idle),
            ]))
        let store = makeConsole(transport, defaults: defaults)
        try await connectReadingMarkers(store, transport, host, agents: 2)
        defer { store.setHosts([]) }
        let chat = try #require(store.agents.first { $0.agent.paneID == "w1:p1" })
        let other = try #require(store.agents.first { $0.agent.paneID == "w1:p2" })
        #expect(!store.isChatMode(chat))

        let launched = marker("w1:p1", session: "pinned")
        await store.recordChatModeLaunch(launched, hostID: host.id)

        #expect(store.isChatMode(chat))
        #expect(!store.isChatMode(other), "only the launched pane is a chat")
        #expect(await transport.chatModeMarkerWrites == [launched])

        // The Host refusing the write still leaves the launch in chat here.
        await transport.setChatModeMarkerWriteFailure(
            NotificationRegistrationError.pluginNotInstalled)
        await store.recordChatModeLaunch(marker("w1:p2"), hostID: host.id)
        #expect(store.isChatMode(other))
    }

    @Test func aHostRefreshReplacesThatHostsMarkersOnlyAndIsThrottled() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let otherHostID = UUID()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle),
                .fixture(paneID: "w1:p2", status: .idle),
            ]))
        let fresh = marker("w1:p2")
        await transport.setChatModeMarkers([fresh])
        let store = makeConsole(transport, defaults: defaults)
        // Cached from an earlier launch of the app: the Host has since
        // garbage-collected w1:p1's marker.
        let stale = marker("w1:p1")
        let elsewhere = marker("w9:p1")
        store.chatMode.replaceMarkers([stale], for: host.id)
        store.chatMode.replaceMarkers([elsewhere], for: otherHostID)

        try await connect(store, host, agents: 2)
        defer { store.setHosts([]) }
        let p2 = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p2")
        try await waitUntil("connecting should read the Host's markers") {
            store.chatMode.marker(for: p2) != nil
        }

        #expect(store.chatMode.marker(for: p2) == fresh)
        #expect(store.chatMode.marker(for: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")) == nil)
        #expect(
            store.chatMode.marker(for: ConsoleAgent.ID(hostID: otherHostID, paneID: "w9:p1"))
                == elsewhere,
            "another Host's markers are not this Host's to replace")

        // Activity right after the read does not read again within 30 s.
        try await waitUntil("pane subscription should be live") {
            await transport.capturedSubscriptions.last?
                .contains(.pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }
        // The status event triggers a resync, and herdr's snapshot then
        // reports Working too; a scripted snapshot still saying Idle would
        // take the change straight back.
        await transport.setSnapshot(
            .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .working),
                .fixture(paneID: "w1:p2", status: .idle),
            ]))
        let fetchesBefore = await transport.snapshotFetchCount
        #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .working)))
        try await waitUntil("the status change and its resync should land") {
            await transport.snapshotFetchCount > fetchesBefore
                && store.agents.first { $0.agent.paneID == "w1:p1" }?.agent.status == .working
        }
        // Time enough for a read the rebuilds failed to hold back to run.
        try await Task.sleep(for: .milliseconds(200))
        #expect(await transport.chatModeMarkerReadCount == 1)
    }

    /// CONSOLE-07: a marker read that spans a reconnect confirms nothing. Its
    /// answer is applied, the held read keeps the new verification from
    /// starting a second read beside it, and once it ends the new
    /// verification reads again: that answer is the one that stands.
    @Test func aMarkerReadSpanningAReconnectIsReadAgainForTheNewVerification() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let before = marker("w9:before")
        let after = marker("w9:after")
        await transport.setChatModeMarkers([before])
        let read = ScriptedTransportCallGate()
        await transport.gateNextChatModeMarkerRead(using: read)
        let store = makeConsole(transport, defaults: defaults)
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        await read.waitForEntry()
        await transport.setChatModeMarkers([after])
        await transport.failEventStream(.channelFailed(detail: "dropped during the marker read"))
        try await reverify(store, host)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.chatModeMarkerReadCount == 1)

        await read.open()
        let afterID = ConsoleAgent.ID(hostID: host.id, paneID: after.paneID)
        try await waitUntil("the new verification should read again") {
            store.chatMode.marker(for: afterID) == after
        }
        #expect(store.chatMode.marker(for: ConsoleAgent.ID(hostID: host.id, paneID: before.paneID)) == nil)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.chatModeMarkerReadCount == 2)
    }

    /// CONSOLE-07: a repair write still out when the Host reconnects confirms
    /// nothing either: the new verification reads once the write ends, and
    /// finds the marker the write put there.
    @Test func aRepairWriteSpanningAReconnectIsFollowedByTheNewVerificationsRead() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let store = makeConsole(transport, defaults: defaults)
        let recorded = marker("w1:p1")
        store.chatMode.record(recorded, hostID: host.id)
        let write = ScriptedTransportCallGate()
        await transport.gateNextChatModeMarkerWrite(using: write)
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        await write.waitForEntry()
        #expect(await transport.chatModeMarkerWrites == [recorded])
        await transport.setChatModeMarkers([recorded])
        await transport.failEventStream(.channelFailed(detail: "dropped during the repair"))
        try await reverify(store, host)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.chatModeMarkerReadCount == 1)

        await write.open()
        try await waitUntil("the new verification should read once the write ends") {
            await transport.chatModeMarkerReadCount == 2
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.chatModeMarkerReadCount == 2)
        #expect(await transport.chatModeMarkerWrites == [recorded])
        #expect(store.chatMode.marker(for: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")) == recorded)
    }

    @Test func aTranscriptReadPrefersTheLiveSessionOverTheMarkersPin() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                // After `/clear` herdr reports a new session and the pin is stale.
                AgentInfo(
                    agentStatus: .working, focused: false, paneID: "w1:p1", revision: 1,
                    tabID: "w1:t1", terminalID: "term_w1:p1", workspaceID: "w1",
                    agent: "claude",
                    agentSession: AgentSessionInfo(
                        agent: "claude", kind: .id, source: "hook", value: "live-session"),
                    cwd: "/work/live"),
                // No session reported yet, and no cwd either.
                AgentInfo(
                    agentStatus: .done, focused: false, paneID: "w1:p2", revision: 1,
                    tabID: "w1:t1", terminalID: "term_w1:p2", workspaceID: "w1",
                    agent: "claude"),
            ]))
        let reply = ChatTranscriptSnapshot(
            header: ChatTranscriptHeader(
                kind: "claude", status: .ok, transcript: nil, activity: "Thinking",
                turnOpen: true, truncated: false, error: nil),
            messages: [
                ChatTranscriptMessage(id: "u1", role: .user, text: "hi", timestamp: nil)
            ])
        await transport.setChatTranscriptResponder { _ in reply }
        let store = makeConsole(transport, defaults: defaults)
        try await connect(store, host, agents: 2)
        defer { store.setHosts([]) }
        let launchedAt = Date(timeIntervalSince1970: 1_790_000_000)
        store.chatMode.record(
            marker("w1:p1", session: "pinned-1", cwd: "/work/marker", launchedAt: launchedAt),
            hostID: host.id)
        store.chatMode.record(
            marker("w1:p2", session: "pinned-2", cwd: "/work/marker", launchedAt: launchedAt),
            hostID: host.id)
        let live = try #require(store.agents.first { $0.agent.paneID == "w1:p1" })
        let pinned = try #require(store.agents.first { $0.agent.paneID == "w1:p2" })

        #expect(try await store.readChatTranscript(for: live, after: "a7") == reply)
        _ = try await store.readChatTranscript(for: pinned, after: nil)

        let requests = await transport.chatTranscriptRequests
        #expect(
            requests == [
                ChatTranscriptRequest(
                    paneID: "w1:p1", kind: "claude", sessionKind: "id",
                    sessionValue: "live-session", cwd: "/work/live", launchedAt: launchedAt,
                    status: .working, after: "a7"),
                ChatTranscriptRequest(
                    paneID: "w1:p2", kind: "claude", sessionKind: "id",
                    sessionValue: "pinned-2", cwd: "/work/marker", launchedAt: launchedAt,
                    status: .done, after: nil),
            ])
    }

    @Test func aRefreshWritesAgainTheRecentMarkersTheHostLacks() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(
                agents: ["w1:p1", "w1:p2", "w1:p3", "w1:p4"].map { AgentInfo.fixture(paneID: $0) }))
        var clock = Date()
        let chatMode = ChatModeStore(defaults: defaults, now: { clock })
        let store = makeConsole(transport, defaults: defaults, chatMode: chatMode)
        // Recorded long enough ago that the Host's list is final.
        chatMode.record(marker("w1:p1"), hostID: host.id)
        clock = clock.addingTimeInterval(ChatModeStore.localRecordGrace + 1)
        // Recorded just now: a launch whose write failed, one whose write
        // landed, and one the Host has from before its transcript was bound.
        let unwritten = marker("w1:p2")
        let written = marker("w1:p3")
        let launch = marker("w1:p4")
        for recorded in [unwritten, written, launch] {
            chatMode.record(recorded, hostID: host.id)
        }
        let p4 = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p4")
        let bound = try #require(
            chatMode.updateSession(.init(kind: "path", value: "/t/p4.jsonl"), for: p4))
        await transport.setChatModeMarkers([written, launch])

        try await connect(store, host, agents: 4)
        defer { store.setHosts([]) }
        try await waitUntil("the refresh should write the missing markers again") {
            await transport.chatModeMarkerWrites.count == 2
        }

        #expect(
            await transport.chatModeMarkerWrites.sorted { $0.paneID < $1.paneID }
                == [unwritten, bound])
        #expect(chatMode.marker(for: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")) == nil)
        #expect(chatMode.marker(for: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p2")) == unwritten)
        #expect(chatMode.marker(for: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p3")) == written)
        #expect(chatMode.marker(for: p4) == bound, "the Host's older copy does not undo the binding")
    }

    /// codex reports no session to herdr, so the reader matches its
    /// transcript by cwd and launch time; the first match then sticks.
    @Test func aTranscriptMatchedWithoutASessionSticksToTheMarker() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .working, kind: "codex")]))
        let store = makeConsole(transport, defaults: defaults)
        try await connectReadingMarkers(store, transport, host, agents: 1)
        defer { store.setHosts([]) }
        let launched = marker(
            "w1:p1", kind: "codex", launchedAt: Date(timeIntervalSince1970: 1_790_000_000))
        store.chatMode.record(launched, hostID: host.id)
        let agent = try #require(store.agents.first)

        // No transcript yet: nothing to bind.
        let waiting = ChatTranscriptSnapshot(header: header(.notFound, transcript: nil), messages: [])
        await transport.setChatTranscriptResponder { _ in waiting }
        _ = try await store.readChatTranscript(for: agent, after: nil)
        #expect(store.chatMode.marker(for: agent.id) == launched)

        let path = "/home/me/.codex/sessions/rollout-a.jsonl"
        let matched = ChatTranscriptSnapshot(header: header(.ok, transcript: path), messages: [])
        await transport.setChatTranscriptResponder { _ in matched }
        #expect(try await store.readChatTranscript(for: agent, after: nil) == matched)
        let bound = ChatModeMarker(
            paneID: "w1:p1", terminalID: "term_w1:p1", kind: "codex", cwd: "/work/w1",
            session: .init(kind: "path", value: path), launchedAt: launched.launchedAt)
        #expect(store.chatMode.marker(for: agent.id) == bound)
        #expect(store.isChatMode(agent))
        try await waitUntil("the binding should be written to the Host") {
            await transport.chatModeMarkerWrites == [bound]
        }

        _ = try await store.readChatTranscript(for: agent, after: "a1")
        let requests = await transport.chatTranscriptRequests
        #expect(requests.map(\.sessionKind) == [nil, nil, "path"])
        #expect(requests.last?.sessionValue == path)
    }

    @Test func aClosingChatAgentKeepsChatInItsRecordAndRetiresItsMarker() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1"),
                // A chat claude ran here once; codex was typed into the pane since.
                .fixture(paneID: "w1:p2", kind: "codex"),
                .fixture(paneID: "w1:p3"),
            ]))
        let store = makeConsole(transport, defaults: defaults)
        try await connectReadingMarkers(store, transport, host, agents: 3)
        defer { store.setHosts([]) }
        store.chatMode.record(marker("w1:p1"), hostID: host.id)
        store.chatMode.record(marker("w1:p2"), hostID: host.id)

        await transport.setSnapshot(.fixture(agents: [.fixture(paneID: "w1:p3")]))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneClosed.kind, data: .object([:]))))
        try await waitUntil("both closures should be recorded") {
            store.closedSessions.sessions.count == 2
        }

        let chatModeByKind = Dictionary(
            uniqueKeysWithValues: store.closedSessions.sessions.map { ($0.kind, $0.chatMode) })
        #expect(chatModeByKind == [.claude: true, .codex: false])
        #expect(
            store.chatMode.marker(for: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")) == nil,
            "whatever runs in the pane next is no chat")
        try await waitUntil("the Host's copy should be deleted") {
            await transport.chatModeMarkerDeletes == ["w1:p1"]
        }
    }

    /// herdr reports no session without its integration: a plain launch's
    /// pin, kept in its marker, is what the Closed Session resumes, and the
    /// marker is retired with it. A session herdr reported wins.
    @Test func aClosingPinnedPlainAgentResumesItsPinAndRetiresItsMarker() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1"),
                .fixture(paneID: "w1:p2", kind: "copilot"),
                .fixture(paneID: "w1:p3"),
            ]))
        let store = makeConsole(transport, defaults: defaults)
        try await connectReadingMarkers(store, transport, host, agents: 3)
        defer { store.setHosts([]) }
        let pinned = ChatModeMarker(
            paneID: "w1:p1", terminalID: "term_w1:p1", kind: "claude", cwd: "/work/w1",
            session: .init(kind: "id", value: "0b6a2c1e-5f1d-4e4c-9b1a-3f2d8c7e6a10"), chatMode: false,
            launchedAt: Date())
        store.chatMode.record(pinned, hostID: host.id)
        #expect(!store.isChatMode(try #require(store.agents.first { $0.agent.paneID == "w1:p1" })))

        await transport.setSnapshot(.fixture(agents: [.fixture(paneID: "w1:p3")]))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneClosed.kind, data: .object([:]))))
        try await waitUntil("both closures should be recorded") {
            store.closedSessions.sessions.count == 2
        }

        let claude = try #require(store.closedSessions.sessions.first { $0.kind == .claude })
        #expect(!claude.chatMode)
        #expect(claude.resumeArguments == ["--resume", "0b6a2c1e-5f1d-4e4c-9b1a-3f2d8c7e6a10"])
        let copilot = try #require(store.closedSessions.sessions.first { $0.kind == .copilot })
        #expect(copilot.resumeArguments == ["--continue"], "no pin, no reported session")
        #expect(store.chatMode.marker(for: ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")) == nil)
        try await waitUntil("the Host's copy should be deleted") {
            await transport.chatModeMarkerDeletes == ["w1:p1"]
        }
    }

    /// `/clear` sent just before the app went away reads as a closure in
    /// the first snapshot after the gap; the chat Agent still runs, so its
    /// marker stays, following the session switched to, until the Agent
    /// really exits.
    @Test func aSessionSwitchSeenAfterAGapKeepsTheMarkerUntilTheAgentExits() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: paneSnapshot(claudeSession: "s-1"))
        let store = makeConsole(transport, defaults: defaults)
        try await connectReadingMarkers(store, transport, host, agents: 1)
        defer { store.setHosts([]) }
        let id = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        let launched = marker("w1:p1")
        store.chatMode.record(launched, hostID: host.id)

        await store.suspend()
        try await waitUntil("suspending should leave the rows awaiting a snapshot") {
            store.hostsAwaitingSnapshot.contains(host.id)
        }
        await transport.setSnapshot(paneSnapshot(claudeSession: "s-2"))
        await store.resume()
        try await waitUntil("the switch should be recorded as a closure, the marker following it") {
            store.closedSessions.sessions.count == 1
                && store.chatMode.marker(for: id)?.session?.value == "s-2"
        }
        #expect(store.chatMode.marker(for: id)?.launchedAt == launched.launchedAt)
        #expect(store.chatMode.marker(for: id)?.terminalID == launched.terminalID)
        let row = try #require(store.agents.first { $0.id == id })
        #expect(store.isChatMode(row), "the Agent still running is still a chat")

        await resync(transport, to: paneSnapshot(claudeSession: nil))
        try await waitUntil("the exit should be recorded") {
            store.closedSessions.sessions.count == 2
        }
        #expect(store.chatMode.marker(for: id) == nil, "the shell left in the pane is no chat")
        try await waitUntil("the Host's copy should be deleted") {
            await transport.chatModeMarkerDeletes == ["w1:p1"]
        }
    }

    /// herdr's restore resumes the chat in a new terminal of its pane under
    /// the same session: it stays a chat, and its marker follows it there.
    @Test func aChatRestoredInANewTerminalStaysAChatAndItsMarkerFollows() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: paneSnapshot(claudeSession: "s-1"))
        let store = makeConsole(transport, defaults: defaults)
        try await connectReadingMarkers(store, transport, host, agents: 1)
        defer { store.setHosts([]) }
        let id = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        let launched = marker("w1:p1", session: "s-1")
        store.chatMode.record(launched, hostID: host.id)

        await resync(
            transport, to: paneSnapshot(claude: claudeInfo(terminalID: "term_restored", session: "s-1")))
        let rebound = ChatModeMarker(
            paneID: "w1:p1", terminalID: "term_restored", kind: "claude", cwd: launched.cwd,
            session: launched.session, launchedAt: launched.launchedAt)
        try await waitUntil("the marker should follow the restored Agent to the Host") {
            await transport.chatModeMarkerWrites == [rebound]
        }
        #expect(store.chatMode.marker(for: id) == rebound)
        let row = try #require(store.agents.first { $0.id == id })
        #expect(row.agent.terminalID == "term_restored")
        #expect(store.isChatMode(row))
        #expect(await transport.chatModeMarkerDeletes.isEmpty, "the marker was not retired")
    }

    /// A chat Agent that reports its session once launched gets it recorded
    /// in its marker, locally and on the Host.
    @Test func aChatAgentsLiveSessionIsWrittenToItsMarker() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: paneSnapshot(claude: claudeInfo(session: nil)))
        let store = makeConsole(transport, defaults: defaults)
        try await connectReadingMarkers(store, transport, host, agents: 1)
        defer { store.setHosts([]) }
        let id = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        let launched = marker("w1:p1")
        store.chatMode.record(launched, hostID: host.id)

        await resync(transport, to: paneSnapshot(claudeSession: "s-1"))
        let recorded = marker("w1:p1", session: "s-1", launchedAt: launched.launchedAt)
        try await waitUntil("the session should be written to the Host") {
            await transport.chatModeMarkerWrites == [recorded]
        }
        #expect(store.chatMode.marker(for: id) == recorded)
    }

    /// herdr lists a restored Agent in its new terminal before it reports
    /// its session: the marker is not retired meanwhile, and applies once
    /// the session shows.
    @Test func aRestoreNotReportingItsSessionYetKeepsTheMarker() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: paneSnapshot(claudeSession: "s-1"))
        let store = makeConsole(transport, defaults: defaults)
        try await connectReadingMarkers(store, transport, host, agents: 1)
        defer { store.setHosts([]) }
        let id = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        let launched = marker("w1:p1", session: "s-1")
        store.chatMode.record(launched, hostID: host.id)

        await resync(
            transport, to: paneSnapshot(claude: claudeInfo(terminalID: "term_restored", session: nil)))
        try await waitUntil("the old terminal's Agent should be recorded as closed") {
            store.closedSessions.sessions.count == 1
        }
        #expect(store.chatMode.marker(for: id) == launched)
        let waiting = try #require(store.agents.first { $0.id == id })
        #expect(!store.isChatMode(waiting), "nothing ties the new terminal to the chat yet")

        await resync(
            transport, to: paneSnapshot(claude: claudeInfo(terminalID: "term_restored", session: "s-1")))
        let rebound = ChatModeMarker(
            paneID: "w1:p1", terminalID: "term_restored", kind: "claude", cwd: launched.cwd,
            session: launched.session, launchedAt: launched.launchedAt)
        try await waitUntil("the session should tie the restored Agent to the chat") {
            await transport.chatModeMarkerWrites == [rebound]
        }
        let restored = try #require(store.agents.first { $0.id == id })
        #expect(store.isChatMode(restored))
        #expect(await transport.chatModeMarkerDeletes.isEmpty)
    }

    /// herdr's restore can show the pane as a plain shell in its new
    /// terminal before it identifies the resumed Agent there: the marker
    /// stays, and the Agent reporting the chat's session is a chat again.
    /// (A chat Agent exiting to its shell keeps its terminal and is retired:
    /// `aSessionSwitchSeenAfterAGapKeepsTheMarkerUntilTheAgentExits`.)
    @Test func aRestoreShowingAShellInANewTerminalFirstKeepsTheMarker() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: paneSnapshot(claudeSession: "s-1"))
        let store = makeConsole(transport, defaults: defaults)
        try await connectReadingMarkers(store, transport, host, agents: 1)
        defer { store.setHosts([]) }
        let id = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        let launched = marker("w1:p1", session: "s-1")
        store.chatMode.record(launched, hostID: host.id)

        await resync(transport, to: paneSnapshot(claude: nil, shellTerminalID: "term_restored"))
        try await waitUntil("the old terminal's Agent should be recorded as closed") {
            store.closedSessions.sessions.count == 1
        }
        #expect(store.chatMode.marker(for: id) == launched)
        let shell = try #require(store.agents.first { $0.id == id })
        #expect(shell.isShell)
        #expect(!store.isChatMode(shell))

        await resync(
            transport, to: paneSnapshot(claude: claudeInfo(terminalID: "term_restored", session: "s-1")))
        let rebound = ChatModeMarker(
            paneID: "w1:p1", terminalID: "term_restored", kind: "claude", cwd: launched.cwd,
            session: launched.session, launchedAt: launched.launchedAt)
        try await waitUntil("the session should tie the restored Agent to the chat") {
            await transport.chatModeMarkerWrites == [rebound]
        }
        let restored = try #require(store.agents.first { $0.id == id })
        #expect(store.isChatMode(restored))
        #expect(await transport.chatModeMarkerDeletes.isEmpty)
    }

    /// After a gap the cached markers may be stale (another device may have
    /// retired one), so none is followed and written back until this
    /// verification's read of the Host's markers lands.
    @Test func noMarkerIsFollowedAfterAGapUntilTheHostsMarkersAreRead() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let id = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        let cached = marker(
            "w1:p1", session: "s-1", launchedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let probe = marker("w9:gone")
        let transport = ScriptedTransport(snapshot: paneSnapshot(claudeSession: "s-1"))
        await transport.setChatModeMarkers([probe, cached])
        let store = makeConsole(transport, defaults: defaults)
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        try await waitUntil("connecting should adopt the Host's marker") {
            store.chatMode.marker(for: id) == cached
        }

        // The gap: the Host's markers cannot be read, and the chat Agent
        // switched session in place meanwhile.
        await store.suspend()
        try await waitUntil("suspending should leave the rows awaiting a snapshot") {
            store.hostsAwaitingSnapshot.contains(host.id)
        }
        await transport.setChatModeMarkerReadFailure(
            NotificationRegistrationError.pluginNotInstalled)
        await transport.setSnapshot(paneSnapshot(claudeSession: "s-2"))
        let readsBefore = await transport.chatModeMarkerReadCount
        await store.resume()
        try await waitUntil("the rows should be verified and the markers' read fail") {
            let reads = await transport.chatModeMarkerReadCount
            return reads > readsBefore && !store.hostsAwaitingSnapshot.contains(host.id)
                && store.agents.first { $0.id == id }?.agent.agentSession?.value == "s-2"
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.chatModeMarkerWrites.isEmpty, "an unconfirmed marker is not written back")
        #expect(store.chatMode.marker(for: id) == cached)

        // The next verification reads the Host's markers: now it is followed.
        await store.suspend()
        try await waitUntil("suspending should leave the rows awaiting a snapshot") {
            store.hostsAwaitingSnapshot.contains(host.id)
        }
        await transport.setChatModeMarkerReadFailure(nil)
        await store.resume()
        let followed = marker("w1:p1", session: "s-2", launchedAt: cached.launchedAt)
        try await waitUntil("the read should land and the marker follow the session") {
            await transport.chatModeMarkerWrites == [followed]
        }
        #expect(store.chatMode.marker(for: id) == followed)
    }

    /// The scripted Host keeps listing a marker after its delete, as when
    /// the delete failed: the next refresh deletes it again, and the claude
    /// typed into the pane since (same pane and terminal) is no chat.
    @Test func aRetiredMarkerTheHostStillListsIsDeletedAgainAndNotAdopted() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let id = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        let launched = marker("w1:p1")
        let transport = ScriptedTransport(snapshot: paneSnapshot(claudeSession: "s-1"))
        await transport.setChatModeMarkers([launched])
        let store = makeConsole(transport, defaults: defaults)
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        try await waitUntil("connecting should adopt the Host's marker") {
            store.chatMode.marker(for: id)?.launchedAt == launched.launchedAt
        }

        await resync(transport, to: paneSnapshot(claudeSession: nil))
        try await waitUntil("the exit should retire the marker") {
            store.chatMode.marker(for: id) == nil
        }
        try await waitUntil("the exit should delete the Host's copy") {
            await transport.chatModeMarkerDeletes == ["w1:p1"]
        }
        store.setHosts([])

        // The app's next launch, reading the markers this one persisted.
        let relaunched = ScriptedTransport(snapshot: paneSnapshot(claudeSession: "s-3"))
        await relaunched.setChatModeMarkers([launched])
        let next = makeConsole(relaunched, defaults: defaults)
        try await connect(next, host, agents: 1)
        defer { next.setHosts([]) }
        try await waitUntil("the refresh should delete the Host's copy again") {
            await relaunched.chatModeMarkerDeletes == ["w1:p1"]
        }
        #expect(next.chatMode.marker(for: id) == nil)
        let row = try #require(next.agents.first { $0.id == id })
        #expect(!next.isChatMode(row))
    }

    /// After a relaunch a chat opens with the transcript the last launch
    /// read, before its Host answers; a later launch in the same pane
    /// (another Chat Marker) opens with none of it.
    @Test func aChatOpensWithTheTranscriptTheLastLaunchKept() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (directory, removeDirectory) = makeCacheDirectory()
        defer { removeDirectory() }
        let host = Host.fixture()
        let launched = marker("w1:p1", launchedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let messages = [
            ChatTranscriptMessage(id: "u1", role: .user, text: "hi", timestamp: nil),
            ChatTranscriptMessage(id: "a1", role: .assistant, text: "hello", timestamp: nil),
        ]
        let reply = ChatTranscriptSnapshot(
            header: header(.ok, transcript: "/t/s-1.jsonl"), messages: messages)
        let transport = ScriptedTransport(snapshot: paneSnapshot(claudeSession: "s-1"))
        await transport.setChatTranscriptResponder { _ in reply }
        let firstCache = ChatTranscriptCache(directory: directory)
        let store = makeConsole(transport, defaults: defaults, chatTranscriptCache: firstCache)
        try await connect(store, host, agents: 1)
        // Removing the Host would drop what it kept, so it stays set.
        defer { store.setHosts([]) }
        store.chatMode.record(launched, hostID: host.id)
        let agent = try #require(store.agents.first)
        let key = store.chatTranscriptKey(for: agent)
        let first = store.makeChatTranscriptStore(for: agent)
        #expect(first.messages.isEmpty, "nothing is kept before the first read")
        first.start()
        try await waitUntil("the read should land") { first.messages == messages }
        first.stop()
        firstCache.flush()

        // The app's next launch: a new cache over the same directory, and a
        // Host that has not answered yet.
        let relaunched = ScriptedTransport(snapshot: paneSnapshot(claudeSession: "s-1"))
        let nextCache = ChatTranscriptCache(directory: directory)
        let next = makeConsole(relaunched, defaults: defaults, chatTranscriptCache: nextCache)
        try await connect(next, host, agents: 1)
        defer { next.setHosts([]) }
        next.chatMode.record(launched, hostID: host.id)
        let row = try #require(next.agents.first)
        #expect(next.chatTranscriptKey(for: row) == key)
        let reopened = next.makeChatTranscriptStore(for: row)
        #expect(reopened.messages == messages, "the bubbles show before any read")
        #expect(await relaunched.chatTranscriptRequests.isEmpty)

        next.chatMode.record(
            marker("w1:p1", launchedAt: Date(timeIntervalSince1970: 1_790_000_600)),
            hostID: host.id)
        let laterLaunch = next.chatTranscriptKey(for: row)
        #expect(laterLaunch != key)
        #expect(nextCache.messages(for: laterLaunch).isEmpty)
    }

    /// A chat Agent that exits takes its kept transcript with it; one
    /// still running keeps its own.
    @Test func aRetiredChatAgentsKeptTranscriptIsRemoved() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (directory, removeDirectory) = makeCacheDirectory()
        defer { removeDirectory() }
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p3")]))
        let cache = ChatTranscriptCache(directory: directory)
        let store = makeConsole(transport, defaults: defaults, chatTranscriptCache: cache)
        try await connectReadingMarkers(store, transport, host, agents: 2)
        defer { store.setHosts([]) }
        store.chatMode.record(marker("w1:p1"), hostID: host.id)
        store.chatMode.record(marker("w1:p3"), hostID: host.id)
        let closing = try #require(store.agents.first { $0.agent.paneID == "w1:p1" })
        let staying = try #require(store.agents.first { $0.agent.paneID == "w1:p3" })
        let closingKey = store.chatTranscriptKey(for: closing)
        let stayingKey = store.chatTranscriptKey(for: staying)
        let closingMessages = [
            ChatTranscriptMessage(id: "u1", role: .user, text: "bye", timestamp: nil)
        ]
        let stayingMessages = [
            ChatTranscriptMessage(id: "u2", role: .user, text: "still here", timestamp: nil)
        ]
        cache.save(closingMessages, for: closingKey)
        cache.save(stayingMessages, for: stayingKey)
        cache.flush()

        await transport.setSnapshot(.fixture(agents: [.fixture(paneID: "w1:p3")]))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneClosed.kind, data: .object([:]))))
        try await waitUntil("the exit should retire the marker") {
            store.chatMode.marker(for: closing.id) == nil
        }
        cache.flush()

        // A fresh instance reads only what is on disk.
        let onDisk = ChatTranscriptCache(directory: directory)
        #expect(onDisk.messages(for: closingKey) == [])
        #expect(onDisk.messages(for: stayingKey) == stayingMessages)
        #expect(cache.messages(for: closingKey) == [])
    }

    /// A chat still open when its Agent exits never writes its copy back.
    @Test func aRetiredChatAgentsTranscriptStoreWritesNothingBack() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (directory, removeDirectory) = makeCacheDirectory()
        defer { removeDirectory() }
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p3")]))
        let messages = [ChatTranscriptMessage(id: "u1", role: .user, text: "bye", timestamp: nil)]
        let reply = ChatTranscriptSnapshot(header: header(.ok, transcript: "/t/s-1.jsonl"), messages: messages)
        await transport.setChatTranscriptResponder { _ in reply }
        let cache = ChatTranscriptCache(directory: directory)
        let store = makeConsole(transport, defaults: defaults, chatTranscriptCache: cache)
        try await connectReadingMarkers(store, transport, host, agents: 2)
        defer { store.setHosts([]) }
        store.chatMode.record(marker("w1:p1"), hostID: host.id)
        let closing = try #require(store.agents.first { $0.agent.paneID == "w1:p1" })
        let closingKey = store.chatTranscriptKey(for: closing)
        let transcript = store.makeChatTranscriptStore(for: closing)

        await transport.setSnapshot(.fixture(agents: [.fixture(paneID: "w1:p3")]))
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneClosed.kind, data: .object([:]))))
        try await waitUntil("the exit should retire the marker") {
            store.chatMode.marker(for: closing.id) == nil
        }

        await transcript.refresh()
        #expect(transcript.messages == messages, "the read landed and asked to persist")
        cache.flush()
        #expect(cache.messages(for: closingKey) == [])
        #expect(ChatTranscriptCache(directory: directory).messages(for: closingKey) == [])
    }

    @Test func theChatViewTypesWithoutEnterAndSendsKeysToThePane() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1", status: .blocked)]))
        await transport.setPaneReadText("Allow edit?\n1. Yes\n2. No")
        let store = makeConsole(transport, defaults: defaults)
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        let agent = try #require(store.agents.first)

        try await store.insertText("use the staging key", into: agent)
        try await store.sendKeys(["enter"], to: agent)
        let screen = try await store.readVisibleScreen(for: agent)

        let input = try #require(await transport.paneInputParams.last)
        #expect(input.paneID == "w1:p1")
        #expect(input.text == "use the staging key")
        #expect(input.keys == nil, "no keys: the text is inserted, not submitted")
        #expect(
            await transport.agentKeyParams == [AgentSendKeysParams(keys: ["enter"], target: "w1:p1")])
        #expect(screen == "Allow edit?\n1. Yes\n2. No")
        let read = try #require(await transport.paneReadParams.last)
        #expect(read.paneID == "w1:p1")
        #expect(read.source == .visible)
        #expect(read.stripANSI == true)
    }

    // MARK: Chat media

    nonisolated private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])

    private func image(_ source: ChatMedia.Source, mime: String? = "image/png") -> ChatMedia {
        ChatMedia(id: "m", kind: .image, mime: mime, source: source)
    }

    @Test func hostMediaPathsResolveAgainstTheCwdAndTheHostsHomeAskedOnce() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.setPreviewFileResponder { _, _ in Self.png }
        let store = makeConsole(transport, defaults: defaults)
        var homeLookups = 0
        store.resolveChatMediaHome = { _ in
            homeLookups += 1
            return "/home/me"
        }
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        let agent = try #require(store.agents.first)

        let relative = try await store.chatMediaFile(for: image(.hostFile(path: "shots/../a.png")), agent: agent)
        _ = try await store.chatMediaFile(for: image(.hostFile(path: "~/b.webp")), agent: agent)
        let clip = ChatMedia(id: "v", kind: .video, mime: nil, source: .hostFile(path: "~/c.mov"))
        let video = try await store.chatMediaFile(for: clip, agent: agent)
        _ = try await store.chatMediaFile(for: image(.hostFile(path: "/abs/d.png")), agent: agent)

        let reads = await transport.previewFileReads
        #expect(reads.map { $0.path } == ["/work/w1/a.png", "/home/me/b.webp", "/home/me/c.mov", "/abs/d.png"])
        #expect(reads.map { $0.maxBytes } == [
            ChatMedia.maximumImageBytes, ChatMedia.maximumImageBytes,
            ChatMedia.maximumVideoBytes, ChatMedia.maximumImageBytes,
        ])
        #expect(homeLookups == 1)
        #expect(relative.pathExtension == "png")
        #expect(video.pathExtension == "mov", "the path's extension wins over the bytes'")
        #expect(try Data(contentsOf: relative) == Self.png)

        await #expect(throws: ChatMediaError.unavailable) {
            _ = try await store.chatMediaFile(for: image(.hostFile(path: "~other/x.png")), agent: agent)
        }
        #expect(await transport.previewFileReads.count == 4, "an unresolvable path is never read")
    }

    @Test func hostFileRefusalsReadAsChatMediaErrors() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.setPreviewFileResponder { path, maxBytes in
            guard path == "/big.png" else { throw RemoteFilePreviewError.missing }
            throw RemoteFilePreviewError.tooLarge(size: UInt64(maxBytes) + 1, limit: maxBytes)
        }
        let store = makeConsole(transport, defaults: defaults)
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        let agent = try #require(store.agents.first)

        await #expect(throws: ChatMediaError.tooLarge) {
            _ = try await store.chatMediaFile(for: image(.hostFile(path: "/big.png")), agent: agent)
        }
        await #expect(throws: ChatMediaError.unavailable) {
            _ = try await store.chatMediaFile(for: image(.hostFile(path: "/gone.png")), agent: agent)
        }
    }

    @Test func inlineMediaGoThroughThePluginsReader() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.setChatMediaResponder { _ in Self.png }
        let store = makeConsole(transport, defaults: defaults)
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        let agent = try #require(store.agents.first)
        let inline = image(.inline(transcript: "/t/s.jsonl", offset: 418, pointer: "/message/content/0"), mime: nil)

        let url = try await store.chatMediaFile(for: inline, agent: agent)

        #expect(
            await transport.chatMediaRequests == [
                ChatMediaRequest.line(
                    transcript: "/t/s.jsonl", offset: 418, pointer: "/message/content/0",
                    maxBytes: ChatMedia.maximumImageBytes)
            ])
        #expect(url.pathExtension == "png", "no mime: the bytes name the type")
        #expect(await transport.previewFileReads.isEmpty)

        await transport.setChatMediaResponder { _ in throw ChatMediaError.pluginOutdated }
        let other = image(.inline(transcript: "/t/s.jsonl", offset: 9, pointer: "/p"))
        await #expect(throws: ChatMediaError.pluginOutdated) {
            _ = try await store.chatMediaFile(for: other, agent: agent)
        }
    }

    /// A session-inline item asks the reader with the session form: the
    /// session to export again, the media item's id (whose `#prt_…` tail
    /// must still name the part under the pointer), the pointer into its
    /// document, and the harness whose export it is (Kilo's here).
    @Test func sessionInlineMediaAsksTheReaderForTheSessionForm() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.setChatMediaResponder { _ in Self.png }
        let store = makeConsole(transport, defaults: defaults)
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        let agent = try #require(store.agents.first)
        let inline = ChatMedia(
            id: "inline:/messages/0/parts/1/url#prt_1", kind: .image, mime: nil,
            source: .sessionInline(session: "ses_demo", pointer: "/messages/0/parts/1/url", agentKind: "kilo"))

        let url = try await store.chatMediaFile(for: inline, agent: agent)

        #expect(
            await transport.chatMediaRequests == [
                ChatMediaRequest.sessionInline(
                    session: "ses_demo", id: "inline:/messages/0/parts/1/url#prt_1",
                    pointer: "/messages/0/parts/1/url", agentKind: "kilo",
                    maxBytes: ChatMedia.maximumImageBytes)
            ])
        #expect(url.pathExtension == "png", "no mime: the bytes name the type")
        #expect(await transport.previewFileReads.isEmpty)
    }

    @Test func aWebMediaURLMustBeHTTPS() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let store = makeConsole(transport, defaults: defaults)
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        let agent = try #require(store.agents.first)
        let url = try #require(URL(string: "http://example.com/a.png"))

        await #expect(throws: ChatMediaError.unsupported) {
            _ = try await store.chatMediaFile(for: image(.web(url)), agent: agent)
        }
    }

    @Test func concurrentRequestsForOneItemShareOneRead() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.setChatMediaResponder { _ in Self.png }
        let gate = ScriptedTransportCallGate()
        await transport.setMediaReadGate(gate)
        // No cache: a second read could only be avoided by sharing the first.
        let store = makeConsole(transport, defaults: defaults)
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        let agent = try #require(store.agents.first)
        // An inline item reaches the shared load without suspending, so a
        // request that has started has joined it.
        let media = image(.inline(transcript: "/t/s.jsonl", offset: 9, pointer: "/p"))

        let first = Task { try await store.chatMediaFile(for: media, agent: agent) }
        await gate.waitForEntry()
        let secondStarted = StartFlag()
        let second = Task {
            secondStarted.isSet = true
            return try await store.chatMediaFile(for: media, agent: agent)
        }
        try await waitUntil("the second request should join the shared read") { secondStarted.isSet }
        await gate.open()

        #expect(try await first.value == second.value)
        #expect(await transport.chatMediaRequests.count == 1)
    }

    @Test func aCachedItemIsServedWithoutAReadAfterARelaunch() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (directory, removeDirectory) = makeCacheDirectory()
        defer { removeDirectory() }
        let host = Host.fixture()
        let media = ChatMedia(
            id: "blob:sha256:ab", kind: .image, mime: "image/png", source: .hostFile(path: "/shots/a.png"))
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.setPreviewFileResponder { _, _ in Self.png }
        let store = makeConsole(
            transport, defaults: defaults, chatMediaCache: ChatMediaCache(directory: directory))
        try await connect(store, host, agents: 1)
        let agent = try #require(store.agents.first)
        let url = try await store.chatMediaFile(for: media, agent: agent)
        #expect(try await store.chatMediaFile(for: media, agent: agent) == url)
        #expect(await transport.previewFileReads.count == 1)
        store.setHosts([])

        let relaunched = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let next = makeConsole(
            relaunched, defaults: defaults, chatMediaCache: ChatMediaCache(directory: directory))
        try await connect(next, host, agents: 1)
        defer { next.setHosts([]) }
        let row = try #require(next.agents.first)
        let cached = try await next.chatMediaFile(for: media, agent: row)
        #expect(try Data(contentsOf: cached) == Self.png)
        #expect(await relaunched.previewFileReads.isEmpty)
    }

    /// claude in pane w1:p1 on `terminalID`, reporting `cwd` (none when nil).
    private func mediaAgentInfo(terminalID: String = "term_w1:p1", cwd: String?) -> AgentInfo {
        AgentInfo(
            agentStatus: .idle, focused: false, paneID: "w1:p1", revision: 1,
            tabID: "w1:t1", terminalID: terminalID, workspaceID: "w1",
            agent: "claude", cwd: cwd)
    }

    @Test func theMediaFolderIsTheListedRowsCwdOverTheMarkers() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [mediaAgentInfo(cwd: "/work/listed")]))
        let store = makeConsole(transport, defaults: defaults)
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        let agent = try #require(store.agents.first)
        store.chatMode.record(marker("w1:p1", cwd: "/work/marker"), hostID: host.id)

        #expect(store.mediaWorkingDirectory(for: agent) == "/work/listed")
    }

    @Test func withoutAListedCwdTheMediaFolderIsTheMarkersCwd() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [mediaAgentInfo(cwd: nil)]))
        let store = makeConsole(transport, defaults: defaults)
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        let agent = try #require(store.agents.first)
        #expect(agent.agent.cwd.isEmpty)
        store.chatMode.record(marker("w1:p1", cwd: "/work/marker"), hostID: host.id)

        #expect(store.mediaWorkingDirectory(for: agent) == "/work/marker")
    }

    @Test func withNeitherCwdThereIsNoMediaFolder() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [mediaAgentInfo(cwd: "")]))
        let store = makeConsole(transport, defaults: defaults)
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        let agent = try #require(store.agents.first)

        #expect(store.mediaWorkingDirectory(for: agent) == nil, "no marker either")
        store.chatMode.record(marker("w1:p1", cwd: ""), hostID: host.id)
        #expect(store.mediaWorkingDirectory(for: agent) == nil, "an empty marker cwd is none")
        store.chatMode.record(marker("w1:p1", cwd: nil), hostID: host.id)
        #expect(store.mediaWorkingDirectory(for: agent) == nil)
    }

    /// The pane now runs another terminal: its listed cwd is not the
    /// Agent's folder any more, so the marker's is.
    @Test func aListedRowOnAnotherTerminalFallsBackToTheMarkersCwd() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [mediaAgentInfo(cwd: nil)]))
        let store = makeConsole(transport, defaults: defaults)
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        let stale = try #require(store.agents.first)

        await resync(
            transport, to: .fixture(agents: [mediaAgentInfo(terminalID: "term_new", cwd: "/work/listed")]))
        try await waitUntil("the pane should list its new terminal") {
            store.agents.first?.agent.terminalID == "term_new"
        }
        let current = try #require(store.agents.first)
        store.chatMode.record(marker("w1:p1", cwd: "/work/marker"), hostID: host.id)

        #expect(store.mediaWorkingDirectory(for: current) == "/work/listed")
        #expect(store.mediaWorkingDirectory(for: stale) == "/work/marker")
    }

    /// A launch's Launch Prompt Files go through the connected Host's live
    /// transport: what it supports, where it wrote, and its failures.
    @Test func launchPromptFilesGoThroughTheConnectedHost() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let store = makeConsole(transport, defaults: defaults)
        try await connect(store, host, agents: 1)
        defer { store.setHosts([]) }
        #expect(store.launchPromptHost(for: UUID()) == nil, "an unknown Host has none")
        let promptHost = try #require(store.launchPromptHost(for: host.id))

        let file = LaunchPromptFile(
            destination: .stageDirectory, name: LaunchPromptStager.chatPromptFileName, contents: "Be brief.")
        let staged = try await promptHost.stage([file])
        #expect(staged == [StagedLaunchPromptFile(file: file, path: ScriptedTransport.stagedLaunchPromptPath(for: file))])
        #expect(await transport.launchPromptStageRequests == [[file]])

        let full = LaunchPromptCapabilities(claudeAppendSystemPromptFile: true, codexProfileFile: true)
        #expect(await promptHost.capabilities() == full)
        await transport.setLaunchPromptCapabilities(.none)
        #expect(await promptHost.capabilities() == .none)

        await transport.setLaunchPromptStagingFailure(.writeFailed)
        await #expect(throws: LaunchPromptStagingError.writeFailed) {
            try await promptHost.stage([file])
        }
    }
}

/// Set by a main-actor task once it runs.
@MainActor
private final class StartFlag {
    var isSet = false
}
