import Foundation
import Testing

@testable import Waycar

/// Chat Mode on the New Agent sheet: which kinds offer it, the arguments a
/// chat launch prepends, the Chat Marker it records, and the remembered
/// choice.
@MainActor
@Suite("Start agent Chat Mode")
struct StartAgentChatModeTests {
    private nonisolated static let prompt = "Reply briefly."
    /// Where the fake Host writes the Chat Prompt.
    private nonisolated static let promptPath = FakeLaunchPromptHost.path(
        for: LaunchPromptFile(
            destination: .stageDirectory, name: LaunchPromptStager.chatPromptFileName, contents: prompt))

    /// The prompt alone, so most tests see only the prompt and pin.
    private nonisolated static func promptOnly(_: SupportedAgentKind) -> ChatModeLaunchOptions {
        ChatModeLaunchOptions(prompt: prompt, quickThinking: false)
    }

    /// Records starts and markers, and plays a started Agent of the launched
    /// kind.
    @MainActor
    private final class Recorder {
        var requests: [AgentLaunchRequest] = []
        var markers: [(ChatModeMarker, Host.ID)] = []
        /// Whether the marker was recorded before the Agent became visible.
        var markerBeforeVisible: [Bool] = []
        /// The kinds Chat Mode options were read for.
        var optionKinds: [SupportedAgentKind] = []
        /// Whether each start opens an Agent already running there.
        var joinsRunningAgent = false
        /// The Host the launch writes its prompt files to.
        var promptHost = FakeLaunchPromptHost()

        func start(_ request: AgentLaunchRequest) -> Agent {
            requests.append(request)
            if joinsRunningAgent { LaunchProgress.report(.joiningRunningAgent) }
            return Agent(.fixture(paneID: "w1:pnew", status: .working, kind: request.kind))
        }
    }

    private func makeDefaults() -> UserDefaults {
        let name = "start-agent-chat-mode-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeStore(
        host: Host,
        kinds: [SupportedAgentKind],
        defaults: UserDefaults,
        recorder: Recorder,
        remoteHome: @escaping (Host.ID) async throws -> String = { _ in "/home/you" },
        chatOptions: @escaping (SupportedAgentKind) -> ChatModeLaunchOptions = Self.promptOnly
    ) -> StartAgentStore {
        let recentsName = "start-agent-chat-mode-recents-\(UUID().uuidString)"
        let recentsDefaults = UserDefaults(suiteName: recentsName)!
        recentsDefaults.removePersistentDomain(forName: recentsName)
        return StartAgentStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            existingAgentNames: { _ in [] },
            discoverAgentKinds: { _ in kinds },
            remoteHome: remoteHome,
            start: { request, _, _, _ in recorder.start(request) },
            awaitAgentVisible: { _ in recorder.markerBeforeVisible.append(!recorder.markers.isEmpty) },
            recents: RecentWorkspaceStore(defaults: recentsDefaults),
            selections: RecentSelectionsStore(defaults: defaults),
            recordChatMode: { marker, hostID in recorder.markers.append((marker, hostID)) },
            chatOptions: { kind in
                recorder.optionKinds.append(kind)
                return chatOptions(kind)
            },
            launchPromptHost: { _ in recorder.promptHost.host })
    }

    /// A store with `kind` detected and selected, Chat Mode on.
    private func chatStore(
        _ kind: SupportedAgentKind, host: Host = .fixture(), recorder: Recorder,
        defaults: UserDefaults? = nil,
        chatOptions: @escaping (SupportedAgentKind) -> ChatModeLaunchOptions = Self.promptOnly
    ) async -> StartAgentStore {
        let store = makeStore(
            host: host, kinds: [kind], defaults: defaults ?? makeDefaults(), recorder: recorder,
            chatOptions: chatOptions)
        await store.discoverAgents()
        store.chatMode = true
        return store
    }

    @Test(arguments: [SupportedAgentKind.claude, .codex, .omp, .pi, .opencode])
    func toggleShowsForChatModeKinds(_ kind: SupportedAgentKind) async {
        let store = await chatStore(kind, recorder: Recorder())
        #expect(store.showsChatModeToggle)
    }

    @Test func toggleHiddenForCursorAndDefaultShell() async {
        let cursor = await chatStore(.cursor, recorder: Recorder())
        #expect(!cursor.showsChatModeToggle)

        let shell = await chatStore(.claude, recorder: Recorder())
        shell.selectedLaunchIsShell = true
        #expect(!shell.showsChatModeToggle)
    }

    @Test func claudeChatLaunchPrependsPromptAndPinnedSession() async throws {
        let recorder = Recorder()
        let store = await chatStore(.claude, recorder: recorder)
        store.arguments = "--model opus"
        await store.submit()

        let args = try #require(recorder.requests.first).arguments
        try #require(args.count == 6)
        #expect(Array(args[0..<3]) == ["--append-system-prompt-file", Self.promptPath, "--session-id"])
        #expect(UUID(uuidString: args[3]) != nil)
        #expect(args[3] == args[3].lowercased())
        #expect(Array(args[4...]) == ["--model", "opus"])
    }

    /// Settings › Chat Mode's model and Quick thinking go after the prompt
    /// and before the pin, read for the kind launched.
    @Test func claudeChatLaunchSendsTheModelAndEffort() async throws {
        let recorder = Recorder()
        let store = await chatStore(
            .claude, recorder: recorder,
            chatOptions: { _ in ChatModeLaunchOptions(prompt: Self.prompt, model: "opus", quickThinking: true) })
        await store.submit()

        let args = try #require(recorder.requests.first).arguments
        try #require(args.count == 8)
        #expect(
            Array(args[0..<7])
                == ["--append-system-prompt-file", Self.promptPath, "--model", "opus", "--effort", "low", "--session-id"])
        #expect(UUID(uuidString: args[7]) != nil)
        #expect(recorder.optionKinds == [.claude])
    }

    /// The Arguments field reaches the chat flags too, so a model there
    /// wins over Settings' one while Quick thinking still applies.
    @Test func aModelInTheArgumentsFieldWins() async throws {
        let recorder = Recorder()
        let store = await chatStore(
            .claude, recorder: recorder,
            chatOptions: { _ in ChatModeLaunchOptions(prompt: Self.prompt, model: "opus", quickThinking: true) })
        store.arguments = "--model sonnet"
        await store.submit()

        let args = try #require(recorder.requests.first).arguments
        try #require(args.count == 8)
        #expect(Array(args[0..<5]) == ["--append-system-prompt-file", Self.promptPath, "--effort", "low", "--session-id"])
        #expect(Array(args[6...]) == ["--model", "sonnet"])
    }

    @Test func claudeContinueGetsNoPinnedSession() async throws {
        let recorder = Recorder()
        let store = await chatStore(.claude, recorder: recorder)
        store.arguments = "--continue"
        await store.submit()

        let args = try #require(recorder.requests.first).arguments
        #expect(args == ["--append-system-prompt-file", Self.promptPath, "--continue"])
        let marker = try #require(recorder.markers.first).0
        #expect(marker.session == nil)
    }

    /// The Chat Prompt goes to the Host as a file, full text, and the launch
    /// points at it, so its length never reaches the typed launch line.
    @Test func chatLaunchWritesThePromptToTheHostBeforeStarting() async throws {
        let recorder = Recorder()
        let store = await chatStore(.claude, recorder: recorder)
        await store.submit()

        let staged = await recorder.promptHost.stagedFiles
        #expect(
            staged == [
                LaunchPromptFile(
                    destination: .stageDirectory, name: LaunchPromptStager.chatPromptFileName,
                    contents: Self.prompt)
            ])
        let args = try #require(recorder.requests.first).arguments
        #expect(!args.contains(Self.prompt))
    }

    @Test func codexChatLaunchPointsAtAProfileHoldingThePrompt() async throws {
        let recorder = Recorder()
        let store = await chatStore(.codex, recorder: recorder)
        await store.submit()

        let args = try #require(recorder.requests.first).arguments
        try #require(args.count == 2)
        #expect(args[0] == "-p")
        let staged = try #require(await recorder.promptHost.stagedFiles.first)
        #expect(staged.destination == .codexProfile)
        #expect(staged.name == args[1])
        #expect(staged.contents == Self.prompt)
    }

    /// A launch never goes out without its Chat Prompt: when the Host can't
    /// take the file, nothing starts and the sheet names the Host.
    @Test func aFailedPromptWriteFailsTheLaunch() async throws {
        let host = Host.fixture()
        let recorder = Recorder()
        recorder.promptHost = FakeLaunchPromptHost(failure: LaunchPromptStagingError.writeFailed)
        let store = await chatStore(.claude, host: host, recorder: recorder)
        await store.submit()

        #expect(recorder.requests.isEmpty)
        #expect(recorder.markers.isEmpty)
        guard case .failed(let message) = store.state else {
            Issue.record("expected a failed launch, got \(store.state)")
            return
        }
        #expect(message.contains(host.displayName))
    }

    /// No Host connection to write to fails the launch the same way.
    @Test func noPromptHostFailsTheLaunch() async throws {
        let recorder = Recorder()
        let store = StartAgentStore(
            hosts: [.fixture()],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            existingAgentNames: { _ in [] },
            discoverAgentKinds: { _ in [.pi] },
            remoteHome: { _ in "/home/you" },
            start: { request, _, _, _ in recorder.start(request) },
            awaitAgentVisible: { _ in },
            selections: RecentSelectionsStore(defaults: makeDefaults()),
            chatOptions: Self.promptOnly,
            launchPromptHost: { _ in nil })
        await store.discoverAgents()
        store.chatMode = true
        await store.submit()

        #expect(recorder.requests.isEmpty)
        guard case .failed = store.state else {
            Issue.record("expected a failed launch, got \(store.state)")
            return
        }
    }

    /// Arguments too long for a fresh pane's typed line, even with every
    /// prompt in a file, start nothing rather than hang the pane.
    @Test func aLaunchLineOverTheBudgetStartsNothing() async throws {
        let recorder = Recorder()
        let store = await chatStore(.pi, recorder: recorder)
        store.arguments = "--note " + String(repeating: "x", count: 1_000)
        await store.submit()

        #expect(recorder.requests.isEmpty)
        #expect(recorder.markers.isEmpty)
        guard case .failed = store.state else {
            Issue.record("expected a failed launch, got \(store.state)")
            return
        }
    }

    /// A launch with no prompt on its line never touches the Host.
    @Test func opencodeChatLaunchWritesNothing() async throws {
        let recorder = Recorder()
        let store = await chatStore(.opencode, recorder: recorder)
        await store.submit()

        #expect(recorder.requests.count == 1)
        #expect(await recorder.promptHost.stagedBatches.isEmpty)
        #expect(await recorder.promptHost.capabilityReads == 0)
    }

    /// OpenCode has no system-prompt flag, so the launch sends only the
    /// model; the prompt rides the Chat Marker for the plugin's extension.
    @Test func opencodeChatLaunchSendsOnlyTheModel() async throws {
        let recorder = Recorder()
        let store = await chatStore(
            .opencode, recorder: recorder,
            chatOptions: {
                _ in ChatModeLaunchOptions(prompt: Self.prompt, model: "anthropic/claude-sonnet-4")
            })
        await store.submit()

        let args = try #require(recorder.requests.first).arguments
        #expect(args == ["-m", "anthropic/claude-sonnet-4"])
        // The prompt is never an argument; the plugin injects it.
        #expect(!args.contains(Self.prompt))
    }

    @Test func opencodeChatLaunchWithoutAModelSendsNoArguments() async throws {
        let recorder = Recorder()
        let store = await chatStore(.opencode, recorder: recorder)
        await store.submit()

        let args = try #require(recorder.requests.first).arguments
        #expect(args.isEmpty)
        #expect(!args.contains(Self.prompt))
    }

    /// The plugin's prompt injection reads the marker, so it must carry the
    /// prompt; opencode never pins a session.
    @Test func opencodeChatMarkerCarriesThePromptAndPinsNoSession() async throws {
        let recorder = Recorder()
        let store = await chatStore(
            .opencode, recorder: recorder,
            chatOptions: {
                _ in ChatModeLaunchOptions(prompt: Self.prompt, model: "anthropic/claude-sonnet-4")
            })
        await store.submit()

        let marker = try #require(recorder.markers.first).0
        #expect(marker.kind == "opencode")
        #expect(marker.prompt == Self.prompt)
        #expect(marker.session == nil)
    }

    /// A model in the Arguments field wins over Settings' one, so opencode
    /// gets none from the launch.
    @Test func opencodeModelInTheArgumentsFieldWins() async throws {
        let recorder = Recorder()
        let store = await chatStore(
            .opencode, recorder: recorder,
            chatOptions: {
                _ in ChatModeLaunchOptions(prompt: Self.prompt, model: "anthropic/claude-sonnet-4")
            })
        store.arguments = "--model vendor/model"
        await store.submit()

        let args = try #require(recorder.requests.first).arguments
        // The launch itself adds nothing (the user's model wins); the
        // Arguments field itself still rides.
        #expect(args == ["--model", "vendor/model"])
    }

    /// The form stays editable while a New Workspace launch probes the
    /// Host's home. codex's `-c` is claude's `--continue`, so the chat
    /// arguments must be the kind's chosen by then.
    @Test func chatArgumentsFollowTheKindChosenDuringTheHomeProbe() async throws {
        let recorder = Recorder()
        let probe = ScriptedTransportCallGate()
        let store = makeStore(
            host: .fixture(), kinds: [.codex, .claude], defaults: makeDefaults(),
            recorder: recorder,
            remoteHome: { _ in
                await probe.waitUntilOpen()
                return "/home/you"
            })
        await store.discoverAgents()
        try #require(store.selectedAgentKind == .codex)
        store.chatMode = true
        store.selectNewWorkspace()

        let submit = Task { await store.submit() }
        await probe.waitForEntry()
        store.selectedAgentKind = .claude
        await probe.open()
        await submit.value

        let request = try #require(recorder.requests.first)
        #expect(request.kind == "claude")
        #expect(recorder.optionKinds == [.claude], "the options are the dispatched kind's")
        try #require(request.arguments.count == 4)
        #expect(
            Array(request.arguments[0..<3]) == ["--append-system-prompt-file", Self.promptPath, "--session-id"])
        let marker = try #require(recorder.markers.first).0
        #expect(marker.kind == "claude")
        #expect(marker.session == ChatModeMarker.Session(kind: "id", value: request.arguments[3]))
    }

    /// Outside Chat Mode a pinnable kind still pins its session, and its
    /// marker records only that pin, so its Closed Session resumes it.
    @Test func chatOffPinsTheSessionAndRecordsAPlainMarker() async throws {
        let recorder = Recorder()
        let store = await chatStore(.claude, recorder: recorder)
        store.chatMode = false
        store.arguments = "--model opus"
        await store.submit()

        let arguments = try #require(recorder.requests.first).arguments
        #expect(Array(arguments.prefix(1)) == ["--session-id"])
        #expect(Array(arguments.suffix(2)) == ["--model", "opus"])
        #expect(await recorder.promptHost.stagedBatches.isEmpty)
        let marker = try #require(recorder.markers.first).0
        #expect(!marker.chatMode)
        #expect(marker.prompt == nil)
        #expect(marker.session == ChatModeMarker.Session(kind: "id", value: arguments[1]))
    }

    @Test func chatOffLeavesAnUnpinnableKindAloneAndRecordsNothing() async throws {
        let recorder = Recorder()
        let store = await chatStore(.codex, recorder: recorder)
        store.chatMode = false
        store.arguments = "--model opus"
        await store.submit()

        #expect(try #require(recorder.requests.first).arguments == ["--model", "opus"])
        #expect(recorder.markers.isEmpty)
    }

    @Test func chatLaunchRecordsMarkerBeforeStarted() async throws {
        let host = Host.fixture()
        let recorder = Recorder()
        let store = await chatStore(.claude, host: host, recorder: recorder)
        await store.submit()

        #expect(store.state == .started(ConsoleAgent.ID(hostID: host.id, paneID: "w1:pnew")))
        #expect(recorder.markerBeforeVisible == [true])
        let (marker, hostID) = try #require(recorder.markers.first)
        #expect(hostID == host.id)
        #expect(marker.paneID == "w1:pnew")
        #expect(marker.terminalID == "term_w1:pnew")
        #expect(marker.kind == "claude")
        #expect(marker.cwd == "/work/w1")
        #expect(marker.prompt == Self.prompt)
        let args = try #require(recorder.requests.first).arguments
        #expect(marker.session == ChatModeMarker.Session(kind: "id", value: args[3]))
    }

    @Test func chatChoiceIsRemembered() async {
        let defaults = makeDefaults()
        let store = await chatStore(.claude, recorder: Recorder(), defaults: defaults)
        await store.submit()

        let next = makeStore(
            host: .fixture(), kinds: [.claude], defaults: defaults, recorder: Recorder())
        #expect(next.chatMode)
    }

    /// New Chat's Last Used follows the chat: where the started Agent
    /// landed, labeled as the Console lists it, and its kind.
    @Test func chatLaunchIsRememberedForNewChat() async {
        let host = Host.fixture()
        let defaults = makeDefaults()
        let store = await chatStore(.claude, host: host, recorder: Recorder(), defaults: defaults)
        await store.submit()

        #expect(store.launchedChat)
        let selections = RecentSelectionsStore(defaults: defaults)
        #expect(
            selections.lastChatDestination
                == ChatDestination(hostID: host.id, workspaceID: "w1", workspaceLabel: "Proj", cwd: "/work/w1"))
        #expect(selections.lastChatKind == .claude)
    }

    @Test func nonChatLaunchRemembersNoChat() async {
        let defaults = makeDefaults()
        let store = await chatStore(.claude, recorder: Recorder(), defaults: defaults)
        store.chatMode = false
        await store.submit()

        #expect(!store.launchedChat)
        let selections = RecentSelectionsStore(defaults: defaults)
        #expect(selections.lastChatDestination == nil)
        #expect(selections.lastChatKind == nil)
    }

    /// Joining an Agent already running is not a chat the sheet started:
    /// no keyboard request and no New Chat Last Used.
    @Test func chatLaunchThatJoinsARunningAgentRemembersNoChat() async {
        let defaults = makeDefaults()
        let recorder = Recorder()
        recorder.joinsRunningAgent = true
        let store = await chatStore(.claude, recorder: recorder, defaults: defaults)
        await store.submit()

        #expect(store.state == .started(ConsoleAgent.ID(hostID: store.selectedHostID!, paneID: "w1:pnew")))
        #expect(!store.launchedChat)
        #expect(store.launchedAgentKind == nil)
        let selections = RecentSelectionsStore(defaults: defaults)
        #expect(selections.lastChatDestination == nil)
        #expect(selections.lastChatKind == nil)
    }
}
