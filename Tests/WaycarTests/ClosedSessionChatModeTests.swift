import Foundation
import Testing

@testable import Waycar

/// Closed Sessions of Chat Mode Agents: the flag survives old synced
/// records and merges, and resuming one relaunches it in Chat Mode.
@MainActor
@Suite("Closed session Chat Mode")
struct ClosedSessionChatModeTests {
    private let hostID = UUID(uuidString: "6B1E5A9C-1D2F-4E3A-9B8C-7D6E5F4A3B2C") ?? UUID()

    /// A record as a build before Chat Mode encoded it: no `chatMode` key.
    private var legacyRecordJSON: String {
        #"{"id":"rec-1","hostID":"\#(hostID.uuidString)","hostName":"alpha","kind":"claude","#
            + #""agentName":"reviewer","cwd":"/work/app","workspaceID":"w1","#
            + #""session":{"kind":"id","value":"s-1"},"#
            + #""lastSeenRunningAtMilliseconds":1800000000000,"closedAtMilliseconds":1800000001000}"#
    }

    private func row(paneID: String = "w1:p1", session: String = "s-1") -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID, hostName: "alpha",
            agent: Agent(
                terminalID: "t1", kind: "claude", title: "Task", status: .idle,
                workspaceID: "w1", tabID: "w1:t1", paneID: paneID, cwd: "/work/app",
                revision: 1,
                agentSession: AgentSessionInfo(
                    agent: "claude", kind: .id, source: "herdr:claude", value: session)),
            workspaceLabel: "App", repositoryCheckout: nil)
    }

    @Test func aRecordFromABuildBeforeChatModeDecodesAsATerminalAgent() throws {
        let session = try JSONDecoder().decode(
            ClosedSession.self, from: Data(legacyRecordJSON.utf8))

        #expect(session.chatMode == false)
        #expect(session.id == "rec-1")
        #expect(session.session == .init(kind: .id, value: "s-1"))
        #expect(session.title == nil)
    }

    @Test func aChatRecordKeepsChatModeThroughEncoding() throws {
        let record = ClosedSession.fixture(session: .init(kind: .id, value: "s-1"))
        var chat = record
        chat.chatMode = true

        let decoded = try JSONDecoder().decode(
            ClosedSession.self, from: JSONEncoder().encode(chat))

        #expect(decoded == chat)
        #expect(decoded.chatMode)
        #expect(decoded != record)
    }

    /// iCloud Keychain holds `{v, session}` items; one synced by an older
    /// build must still read, or the catalog would mark it unreadable and
    /// never update it again.
    @Test func anOlderBuildsSyncedItemStillReads() throws {
        let item = Data(#"{"v":1,"session":\#(legacyRecordJSON)}"#.utf8)

        let contents = SyncedClosedSessionCatalog.contents(
            of: [SyncedClosedSessionCatalog.account(for: "rec-1"): item])

        #expect(contents.unreadable.isEmpty)
        #expect(contents.records["rec-1"]?.chatMode == false)
    }

    @Test func aClosedChatAgentIsRecordedInChatMode() throws {
        let store = ClosedSessionsStore()
        let chatRow = row(paneID: "w1:p1", session: "s-chat")
        let terminalRow = row(paneID: "w1:p2", session: "s-term")
        store.chatModeLookup = { $0.id == chatRow.id }

        store.record([
            ClosedAgentCapture(row: chatRow, session: nil, lastSeenRunningAt: store.now()),
            ClosedAgentCapture(row: terminalRow, session: nil, lastSeenRunningAt: store.now()),
        ])

        let bySession = Dictionary(
            uniqueKeysWithValues: store.sessions.compactMap { record in
                record.session.map { ($0.value, record.chatMode) }
            })
        #expect(bySession == ["s-chat": true, "s-term": false])
    }

    @Test func withoutALookupEveryClosureIsATerminalAgent() {
        let store = ClosedSessionsStore()

        store.record([ClosedAgentCapture(row: row(), session: nil, lastSeenRunningAt: store.now())])

        #expect(store.sessions.map(\.chatMode) == [false])
    }

    /// The same session closing again from a terminal presentation the
    /// lookup no longer knows (its marker already collected) stays a chat.
    @Test func aLaterClosureOfAChatSessionStaysInChatMode() throws {
        let clock = ManualClock()
        let store = ClosedSessionsStore(now: { clock.now })
        var chat = true
        store.chatModeLookup = { _ in chat }
        store.record([ClosedAgentCapture(row: row(), session: nil, lastSeenRunningAt: clock.now)])

        clock.advance(by: 60)
        chat = false
        store.record([ClosedAgentCapture(row: row(), session: nil, lastSeenRunningAt: clock.now)])

        let record = try #require(store.sessions.first)
        #expect(store.sessions.count == 1)
        #expect(record.lastSeenRunningAt == clock.now)
        #expect(record.chatMode)
    }

    @MainActor
    private final class Recorder {
        var requests: [AgentLaunchRequest] = []
        var markers: [(ChatModeMarker, Host.ID)] = []
        var optionKinds: [SupportedAgentKind] = []
        /// The Host the resume writes its Chat Prompt to.
        var promptHost = FakeLaunchPromptHost()
    }

    @Test func aChatClaudeRecordResumesWithTheChatArgumentsBeforeItsSession() async throws {
        var record = ClosedSession.fixture(
            hostID: hostID, kind: .claude, cwd: "/work/app", workspaceID: "w1",
            session: .init(kind: .id, value: "s-1"))
        record.chatMode = true
        let launchedAt = Date(timeIntervalSince1970: 1_800_000_500)
        let recorder = Recorder()
        let started = Agent(
            terminalID: "t-new", kind: "claude", title: "", status: .working,
            workspaceID: "w1", tabID: "w1:t2", paneID: "w1:p-resumed", cwd: "/work/app",
            revision: 1, agentSession: nil)
        let resumer = ClosedSessionResumer(
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "App")] },
            existingAgentNames: { _ in [] },
            start: { request, _, _, _ in
                recorder.requests.append(request)
                return started
            },
            awaitAgentVisible: { _ in },
            beginPendingResume: { _, _, _ in },
            recordChatMode: { recorder.markers.append(($0, $1)) },
            chatOptions: { kind in
                recorder.optionKinds.append(kind)
                return ChatModeLaunchOptions(prompt: "Reply briefly.", model: "opus", quickThinking: true)
            },
            launchPromptHost: { _ in recorder.promptHost.host },
            now: { launchedAt })

        let outcome = await resumer.resume(record)

        #expect(outcome == .started(ConsoleAgent.ID(hostID: hostID, paneID: "w1:p-resumed")))
        let staged = await recorder.promptHost.stagedFiles
        #expect(staged.map(\.contents) == ["Reply briefly."])
        let promptPath = try #require(staged.first.map(FakeLaunchPromptHost.path(for:)))
        #expect(
            recorder.requests.map(\.arguments)
                == [
                    [
                        "--append-system-prompt-file", promptPath, "--model", "opus", "--effort", "low",
                        "--resume", "s-1",
                    ]
                ])
        #expect(recorder.optionKinds == [.claude])
        let (marker, markerHost) = try #require(recorder.markers.first)
        #expect(recorder.markers.count == 1)
        #expect(markerHost == hostID)
        #expect(
            marker
                == ChatModeMarker(
                    paneID: "w1:p-resumed", terminalID: "t-new", kind: "claude",
                    cwd: "/work/app", session: .init(kind: "id", value: "s-1"),
                    prompt: "Reply briefly.", launchedAt: launchedAt))
    }

    /// A plain resume of a known session records it in a plain marker, so
    /// closing it again still resumes it exactly on herdr.
    @Test func aPlainResumeOfAKnownSessionRecordsAPlainMarker() async throws {
        let record = ClosedSession.fixture(
            hostID: hostID, kind: .copilot, cwd: "/work/app", workspaceID: "w1",
            session: .init(kind: .id, value: "s-1"))
        let launchedAt = Date(timeIntervalSince1970: 1_800_000_500)
        let recorder = Recorder()
        let started = Agent(
            terminalID: "t-new", kind: "copilot", title: "", status: .working,
            workspaceID: "w1", tabID: "w1:t2", paneID: "w1:p-resumed", cwd: "/work/app",
            revision: 1, agentSession: nil)
        let resumer = ClosedSessionResumer(
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "App")] },
            existingAgentNames: { _ in [] },
            start: { request, _, _, _ in
                recorder.requests.append(request)
                return started
            },
            awaitAgentVisible: { _ in },
            beginPendingResume: { _, _, _ in },
            recordChatMode: { recorder.markers.append(($0, $1)) },
            launchPromptHost: { _ in recorder.promptHost.host },
            now: { launchedAt })

        _ = await resumer.resume(record)

        #expect(recorder.requests.map(\.arguments) == [["--resume=s-1"]])
        #expect(
            recorder.markers.map(\.0)
                == [
                    ChatModeMarker(
                        paneID: "w1:p-resumed", terminalID: "t-new", kind: "copilot", cwd: "/work/app",
                        session: .init(kind: "id", value: "s-1"), chatMode: false, launchedAt: launchedAt)
                ])
        let unknown = ClosedSession.fixture(
            hostID: hostID, kind: .copilot, cwd: "/work/app", workspaceID: "w1")
        recorder.markers = []
        _ = await resumer.resume(unknown)
        #expect(recorder.markers.isEmpty, "a --continue resume knows no session to record")
    }

    @Test func aFailedChatResumeWritesNoMarker() async {
        var record = ClosedSession.fixture(hostID: hostID, kind: .claude, workspaceID: "w1")
        record.chatMode = true
        let recorder = Recorder()
        let resumer = ClosedSessionResumer(
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "App")] },
            existingAgentNames: { _ in [] },
            start: { _, _, _, _ in throw CancellationError() },
            awaitAgentVisible: { _ in },
            beginPendingResume: { _, _, _ in },
            recordChatMode: { recorder.markers.append(($0, $1)) },
            launchPromptHost: { _ in recorder.promptHost.host })

        let outcome = await resumer.resume(record)

        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(recorder.markers.isEmpty)
    }

    /// A resume never goes out without its Chat Prompt: when the Host can't
    /// take the file, nothing starts and the failure names the Host.
    @Test func aFailedPromptWriteFailsTheResume() async {
        var record = ClosedSession.fixture(hostID: hostID, kind: .pi, workspaceID: "w1")
        record.chatMode = true
        let recorder = Recorder()
        recorder.promptHost = FakeLaunchPromptHost(failure: LaunchPromptStagingError.writeFailed)
        let resumer = ClosedSessionResumer(
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "App")] },
            existingAgentNames: { _ in [] },
            start: { request, _, _, _ in
                recorder.requests.append(request)
                throw CancellationError()
            },
            awaitAgentVisible: { _ in },
            beginPendingResume: { _, _, _ in },
            recordChatMode: { recorder.markers.append(($0, $1)) },
            launchPromptHost: { _ in recorder.promptHost.host },
            hostName: { _ in "Studio" })

        let outcome = await resumer.resume(record)

        guard case .failed(let message) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(message.contains("Studio"))
        #expect(recorder.requests.isEmpty)
        #expect(recorder.markers.isEmpty)
    }

    @Test func onlyChatRecordsOfChatKindsGetChatArguments() async throws {
        var codex = ClosedSession.fixture(kind: .codex, session: .init(kind: .id, value: "c-1"))
        var cursor = ClosedSession.fixture(kind: .cursor)
        let terminal = ClosedSession.fixture(kind: .claude, session: .init(kind: .id, value: "s-1"))
        codex.chatMode = true
        cursor.chatMode = true
        let options = ChatModeLaunchOptions(prompt: #"say "hi""#, model: "gpt-5", quickThinking: true)
        let promptHost = FakeLaunchPromptHost()

        let codexArguments = try await ClosedSessionResumer.launchCommand(
            for: codex, chatOptions: options, host: promptHost.host, hostName: "Studio"
        ).arguments
        let profile = try #require(await promptHost.stagedFiles.first)
        #expect(profile.destination == .codexProfile)
        #expect(profile.contents == #"say "hi""#)
        #expect(
            codexArguments
                == ["-p", profile.name, "-m", "gpt-5", "-c", #"model_reasoning_effort="low""#, "resume", "c-1"])
        #expect(
            try await ClosedSessionResumer.launchCommand(
                for: cursor, chatOptions: options, host: promptHost.host, hostName: "Studio")
                == AgentLaunchCommand(arguments: []))
        #expect(
            try await ClosedSessionResumer.launchCommand(
                for: terminal, chatOptions: options, host: promptHost.host, hostName: "Studio")
                == AgentLaunchCommand(arguments: ["--resume", "s-1"]))
        #expect(await promptHost.stagedBatches.count == 1, "only the chat codex record writes a file")
    }

    /// Hermes and Copilot keep their Chat Prompt outside the session, so a
    /// chat resume sets it in the pane again (hermes.md §5, copilot.md §5).
    @Test func environmentRoutesAreSetAgainOnResume() async throws {
        var hermes = ClosedSession.fixture(
            kind: .hermes, session: .init(kind: .id, value: "20261012_164012_b4df59"))
        var copilot = ClosedSession.fixture(kind: .copilot)
        hermes.chatMode = true
        copilot.chatMode = true
        let options = ChatModeLaunchOptions(prompt: "Text back.", model: nil, quickThinking: false)
        let promptHost = FakeLaunchPromptHost()

        #expect(
            try await ClosedSessionResumer.launchCommand(
                for: hermes, chatOptions: options, host: promptHost.host, hostName: "Studio")
                == AgentLaunchCommand(
                    arguments: ["chat", "--resume", "20261012_164012_b4df59"],
                    environment: ["HERMES_EPHEMERAL_SYSTEM_PROMPT": "Text back."]))
        let resumed = try await ClosedSessionResumer.launchCommand(
            for: copilot, chatOptions: options, host: promptHost.host, hostName: "Studio")
        #expect(resumed.arguments == ["--continue"])
        #expect(resumed.environment == ["COPILOT_CUSTOM_INSTRUCTIONS_DIRS": "/tmp/waycar.test"])
    }

    /// A codex too old for profile files keeps today's inline flag while the
    /// launch line stays short.
    @Test func anOldCodexResumesWithTheInlineFlag() async throws {
        var codex = ClosedSession.fixture(kind: .codex, session: .init(kind: .id, value: "c-1"))
        codex.chatMode = true
        let options = ChatModeLaunchOptions(prompt: #"say "hi""#, model: "gpt-5", quickThinking: true)
        let promptHost = FakeLaunchPromptHost(capabilities: .none)

        #expect(
            try await ClosedSessionResumer.launchCommand(
                for: codex, chatOptions: options, host: promptHost.host, hostName: "Studio"
            ).arguments
                == [
                    "-c", #"developer_instructions="say \"hi\"""#, "-m", "gpt-5",
                    "-c", #"model_reasoning_effort="low""#, "resume", "c-1",
                ])
    }

    /// An old claude or codex whose inline Chat Prompt is too long for the
    /// typed line resumes without it: a first-message pointer would start a
    /// turn nobody asked for, and the resumed transcript already holds the
    /// prompt.
    @Test(arguments: [SupportedAgentKind.claude, .codex])
    func anOldCLIResumesWithoutATooLongChatPrompt(_ kind: SupportedAgentKind) async throws {
        var record = ClosedSession.fixture(kind: kind, session: .init(kind: .id, value: "s-1"))
        record.chatMode = true
        let options = ChatModeLaunchOptions(prompt: ChatModePrompt.defaultText, model: nil, quickThinking: false)
        let promptHost = FakeLaunchPromptHost(capabilities: .none)

        let arguments = try await ClosedSessionResumer.launchCommand(
            for: record, chatOptions: options, host: promptHost.host, hostName: "Studio"
        ).arguments

        #expect(arguments == record.resumeArguments)
        #expect(!arguments.contains("--"))
        #expect(!arguments.contains { $0.contains("Read and follow") })
        #expect(!arguments.contains { $0.contains(ChatModePrompt.defaultText) })
        #expect(
            LaunchPromptStager.typedLineBytes(executable: kind.executable, arguments: arguments)
                <= LaunchPromptStager.typedLineBudget)
        #expect(await promptHost.stagedBatches.isEmpty)
    }
}
