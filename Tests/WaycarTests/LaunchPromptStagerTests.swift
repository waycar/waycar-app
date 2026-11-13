import Foundation
import Testing

@testable import Waycar

/// Launch Prompt Files: what a launch writes to the Host and the arguments
/// that point each harness at it, so no prompt's length reaches the line
/// herdr types into a fresh pane.
@Suite("Launch prompt stager")
struct LaunchPromptStagerTests {
    private static let pin = UUID(uuidString: "0F4C2B1A-9D8E-4F70-A1B2-C3D4E5F60718")
    private static let pinText = "0f4c2b1a-9d8e-4f70-a1b2-c3d4e5f60718"
    private static let profileID = UUID(uuidString: "7A0B1C2D-3E4F-4051-8263-748596A7B8C9")
    private static let profileName = "waycar-7a0b1c2d-3e4f-4051-8263-748596a7b8c9"
    private static let prompt = "Reply like a text."
    private static let firstMessage = "Fix it."
    private static let user = ["--verbose"]

    private static let files = LaunchPromptCapabilities(
        claudeAppendSystemPromptFile: true, codexProfileFile: true)

    private static func options(model: String?) -> ChatModeLaunchOptions {
        ChatModeLaunchOptions(prompt: prompt, model: model, quickThinking: true)
    }

    private static func plan(
        _ kind: SupportedAgentKind,
        chat: ChatModeLaunchOptions? = LaunchPromptStagerTests.options(model: "m1"),
        sessionPin: UUID? = nil, user: [String] = LaunchPromptStagerTests.user,
        initialPrompt: String? = LaunchPromptStagerTests.firstMessage,
        capabilities: LaunchPromptCapabilities = LaunchPromptStagerTests.files
    ) throws -> LaunchPromptPlan {
        let profileID = try #require(Self.profileID)
        return LaunchPromptStager.plan(
            kind: kind, chatOptions: chat, sessionPin: sessionPin, userArguments: user,
            initialPrompt: initialPrompt, capabilities: capabilities, makeID: { profileID })
    }

    /// `plan`'s files as `FakeLaunchPromptHost` writes them, or with stage
    /// files under `root` when given.
    private static func staged(_ plan: LaunchPromptPlan, root: String? = nil) -> [StagedLaunchPromptFile] {
        FakeLaunchPromptHost.staged(plan.files).map { staged in
            guard let root, staged.file.destination == .stageDirectory else { return staged }
            return StagedLaunchPromptFile(file: staged.file, path: "\(root)/\(staged.file.name)")
        }
    }

    private static let chatPath = FakeLaunchPromptHost.path(
        for: LaunchPromptFile(destination: .stageDirectory, name: LaunchPromptStager.chatPromptFileName, contents: ""))
    private static let firstPath = FakeLaunchPromptHost.path(
        for: LaunchPromptFile(destination: .stageDirectory, name: LaunchPromptStager.initialPromptFileName, contents: ""))
    private static let pointer = "Read and follow \(firstPath)"

    // MARK: Routes

    @Test func claudeAppendsTheChatPromptFileAndKeepsItsFlags() throws {
        let pin = try #require(Self.pin)
        let plan = try Self.plan(.claude, sessionPin: pin)
        #expect(
            try plan.command(staged: Self.staged(plan)).arguments
                == [
                    "--append-system-prompt-file", Self.chatPath, "--model", "m1", "--effort", "low",
                    "--session-id", Self.pinText, "--verbose", "--", Self.pointer,
                ])
    }

    @Test func codexLayersAProfileHoldingTheChatPrompt() throws {
        let plan = try Self.plan(.codex)
        #expect(
            try plan.command(staged: Self.staged(plan)).arguments
                == [
                    "-p", Self.profileName, "-m", "m1", "-c", #"model_reasoning_effort="low""#, "--verbose",
                    "--", Self.pointer,
                ])
    }

    @Test func ompJoinsTheChatPromptPathToItsFlag() throws {
        let plan = try Self.plan(.omp)
        #expect(
            try plan.command(staged: Self.staged(plan)).arguments
                == [
                    "--append-system-prompt=\(Self.chatPath)", "--model=m1", "--thinking=low", "--verbose",
                    Self.pointer,
                ])
    }

    @Test func piAppendsTheChatPromptPathAndKeepsItsPin() throws {
        let pin = try #require(Self.pin)
        let plan = try Self.plan(.pi, sessionPin: pin)
        #expect(
            try plan.command(staged: Self.staged(plan)).arguments
                == [
                    "--append-system-prompt", Self.chatPath, "--model", "m1", "--thinking", "low",
                    "--session-id", Self.pinText, "--verbose", Self.pointer,
                ])
    }

    /// OpenCode's Chat Prompt rides the Chat Marker, so only its first
    /// message is a file, handed over with `--prompt`.
    @Test func opencodeStagesOnlyItsFirstMessage() throws {
        let plan = try Self.plan(.opencode)
        #expect(plan.files.map(\.name) == [LaunchPromptStager.initialPromptFileName])
        #expect(
            try plan.command(staged: Self.staged(plan)).arguments
                == ["-m", "m1", "--verbose", "--prompt", Self.pointer])
    }

    /// A Chat Mode OpenCode launch with no first message is untouched: no
    /// file, the same arguments as before.
    @Test func opencodeWithoutAFirstMessageIsUntouched() throws {
        let plan = try Self.plan(.opencode, initialPrompt: nil)
        #expect(plan.files.isEmpty)
        #expect(try plan.command(staged: []).arguments == ["-m", "m1", "--verbose"])
    }

    @Test func aLaunchWithNoPromptWritesNothing() throws {
        let plan = try Self.plan(.claude, chat: nil, initialPrompt: nil)
        #expect(plan.files.isEmpty)
        #expect(try plan.command(staged: []).arguments == Self.user)
    }

    /// A kind that takes no first message gets neither the file nor a
    /// pointer it would read as a flag or subcommand.
    @Test func aKindWithoutAFirstMessageWritesNone() throws {
        let plan = try Self.plan(.amp, chat: nil)
        #expect(plan.files.isEmpty)
        #expect(try plan.command(staged: []).arguments == Self.user)
    }

    @Test func aWhitespaceFirstMessageIsNone() throws {
        let plan = try Self.plan(.pi, initialPrompt: " \n\t")
        #expect(plan.files.map(\.name) == [LaunchPromptStager.chatPromptFileName])
    }

    // MARK: Files

    @Test func filesCarryTheFullPromptsUnderWaycarNames() throws {
        let multiLine = "Line one.\n\tLine two."
        let claude = try Self.plan(.claude, initialPrompt: multiLine)
        #expect(
            claude.files == [
                LaunchPromptFile(
                    destination: .stageDirectory, name: LaunchPromptStager.chatPromptFileName,
                    contents: Self.prompt),
                LaunchPromptFile(
                    destination: .stageDirectory, name: LaunchPromptStager.initialPromptFileName,
                    contents: multiLine),
            ])
        let codex = try Self.plan(.codex, initialPrompt: nil)
        #expect(
            codex.files == [
                LaunchPromptFile(destination: .codexProfile, name: Self.profileName, contents: Self.prompt)
            ])
    }

    // MARK: Fallbacks

    /// A claude or codex too old for a file route keeps today's inline flag
    /// while the typed line fits.
    @Test(arguments: [SupportedAgentKind.claude, .codex])
    func anOldCLIGetsTheInlineFlagWhileItFits(_ kind: SupportedAgentKind) throws {
        let plan = try Self.plan(kind, capabilities: .none)
        #expect(plan.files.map(\.destination) == [.stageDirectory, .stageDirectory])
        let arguments = try plan.command(staged: Self.staged(plan)).arguments
        let inline =
            kind == .claude
            ? ["--append-system-prompt", Self.prompt] : ["-c", #"developer_instructions="Reply like a text.""#]
        #expect(Array(arguments.prefix(2)) == inline)
        #expect(Array(arguments.suffix(2)) == ["--", Self.pointer])
    }

    /// Past the budget the Chat Prompt moves into the first message: a
    /// pointer at its file as standing instructions, then at the first
    /// message's own file.
    @Test(arguments: [SupportedAgentKind.claude, .codex])
    func anOldCLIGetsAPointerWhenTheInlineLineIsTooLong(_ kind: SupportedAgentKind) throws {
        let chat = ChatModeLaunchOptions(prompt: ChatModePrompt.defaultText, model: "m1", quickThinking: false)
        let plan = try Self.plan(kind, chat: chat, capabilities: .none)
        let arguments = try plan.command(staged: Self.staged(plan)).arguments
        #expect(!arguments.contains { $0.contains(ChatModePrompt.defaultText) })
        #expect(
            Array(arguments.suffix(2))
                == [
                    "--",
                    "Read and follow \(Self.chatPath) as standing instructions for this session, "
                        + "then read and follow \(Self.firstPath)",
                ])
        #expect(Array(arguments.dropLast(2).suffix(1)) == Self.user, "the user's arguments stay ahead")
    }

    @Test func thePointerAloneWhenThereIsNoFirstMessage() throws {
        let chat = ChatModeLaunchOptions(prompt: ChatModePrompt.defaultText, quickThinking: false)
        let plan = try Self.plan(.claude, chat: chat, user: [], initialPrompt: nil, capabilities: .none)
        #expect(
            try plan.command(staged: Self.staged(plan)).arguments
                == ["--", "Read and follow \(Self.chatPath) as standing instructions for this session"])
    }

    /// The budget is inclusive: `claude --append-system-prompt <n bytes>`
    /// plus Enter is 31 + n bytes.
    @Test func theInlineFlagIsKeptUpToTheBudgetExactly() throws {
        for (length, inline) in [(969, true), (970, false)] {
            let chat = ChatModeLaunchOptions(prompt: String(repeating: "a", count: length), quickThinking: false)
            let plan = try Self.plan(.claude, chat: chat, user: [], initialPrompt: nil, capabilities: .none)
            let arguments = try plan.command(staged: Self.staged(plan)).arguments
            #expect((arguments.first == "--append-system-prompt") == inline, "\(length)")
        }
    }

    /// codex takes one profile, so the user's own leaves ours out, however
    /// it is set.
    @Test(arguments: [
        ["-p", "fast"], ["--profile=fast"], ["-pfast"], ["-c", "profile=fast"], ["--config", "profile=fast"],
        ["--config=profile=fast"], ["-cprofile=fast"],
    ])
    func aUserProfileLeavesCodexOnTheFallback(_ user: [String]) throws {
        let plan = try Self.plan(.codex, user: user, initialPrompt: nil)
        #expect(plan.files.map(\.destination) == [.stageDirectory])
        let arguments = try plan.command(staged: Self.staged(plan)).arguments
        #expect(arguments == ["-c", #"developer_instructions="Reply like a text.""#] + user)
    }

    // MARK: Budget

    @Test func aLineStillTooLongAfterStagingThrows() throws {
        let plan = try Self.plan(.pi, user: ["--note", String(repeating: "x", count: 1_000)])
        let error = #expect(throws: LaunchPromptError.self) {
            try plan.command(staged: Self.staged(plan)).arguments
        }
        guard case .launchLineTooLong(let bytes) = error else {
            Issue.record("expected launchLineTooLong, got \(String(describing: error))")
            return
        }
        #expect(bytes > LaunchPromptStager.typedLineBudget)
    }

    /// The regression test for the hang: the default Chat Prompt (about
    /// 1.7 KB) plus a Keychain-Fix-sized first message, with a model,
    /// Quick thinking and a pin, at a realistic macOS `$TMPDIR` path, types
    /// a line well inside `MAX_CANON` for every Chat Mode kind, with or
    /// without the file routes.
    @Test(arguments: [true, false])
    func theDefaultChatPromptLaunchLineFitsForEveryKind(_ fileRoutes: Bool) throws {
        let pin = try #require(Self.pin)
        let root = "/var/folders/7k/2xq8l0rn5bz9w0d3h4fj1tqm0000gn/T/waycar.Ab3dE9gH"
        let firstMessage = CodexBarKeychainFix.agentPrompt(
            hostName: "Studio",
            problem: .keychainBlocked,
            providers: [
                AIUsageProvider(
                    id: "claude", providerID: "claude", displayName: "Claude", account: nil,
                    windows: [], errorMessage: "No Claude session key found in browser cookies.")
            ],
            codexBarPath: "/opt/homebrew/bin/codexbar")
        let chat = ChatModeLaunchOptions(
            prompt: ChatModePrompt.defaultText, model: "anthropic/claude-sonnet-4-5", quickThinking: true)
        for kind in SupportedAgentKind.allCases where kind.supportsChatMode {
            let plan = try Self.plan(
                kind, chat: chat,
                sessionPin: ChatModeLaunch.sessionPin(kind: kind, userArguments: [], makeID: { pin }),
                user: [], initialPrompt: firstMessage, capabilities: fileRoutes ? Self.files : .none)
            let arguments = try plan.command(staged: Self.staged(plan, root: root)).arguments
            let bytes = LaunchPromptStager.typedLineBytes(executable: kind.executable, arguments: arguments)
            #expect(bytes <= LaunchPromptStager.typedLineBudget, "\(kind.rawValue): \(bytes) bytes")
            #expect(!arguments.contains { $0.contains(ChatModePrompt.defaultText) }, "\(kind.rawValue)")
            #expect(!arguments.contains { $0.contains(firstMessage) }, "\(kind.rawValue)")
        }
    }

    // MARK: Typed-line estimate

    @Test func argumentsAreQuotedTheWayHerdrTypesThem() {
        #expect(ShellWord.quoted("--model=a/b:c,d@e%f+g") == "--model=a/b:c,d@e%f+g")
        #expect(ShellWord.quoted("two words") == "'two words'")
        #expect(ShellWord.quoted("it's") == #"'it'\''s'"#)
        #expect(ShellWord.quoted("") == "''")
        #expect(ShellWord.quoted("é") == "'é'")
    }

    @Test func theEstimateCountsSpacesQuotesAndEnter() {
        // "claude 'a b' --x" + Enter
        #expect(LaunchPromptStager.typedLineBytes(executable: "claude", arguments: ["a b", "--x"]) == 17)
        #expect(LaunchPromptStager.typedLineBytes(executable: "pi", arguments: []) == 3)
        // "claude bare 'it'\''s'" + Enter
        #expect(LaunchPromptStager.typedLineBytes(executable: "claude", arguments: ["bare", "it's"]) == 22)
    }

    // MARK: Staging

    @Test func aLaunchWithNoPromptNeverTouchesTheHost() async throws {
        let command = try await LaunchPromptStager.launchCommand(
            kind: .claude, chatOptions: nil, sessionPin: nil, userArguments: Self.user,
            initialPrompt: nil, host: nil, hostName: "Studio")
        #expect(command == AgentLaunchCommand(arguments: Self.user))
    }

    @Test func stagingWritesThePlanAndPointsAtTheWrittenPaths() async throws {
        let host = FakeLaunchPromptHost()
        let arguments = try await LaunchPromptStager.launchCommand(
            kind: .omp, chatOptions: Self.options(model: nil), sessionPin: nil, userArguments: [],
            initialPrompt: nil, host: host.host, hostName: "Studio"
        ).arguments
        let written = try #require(await host.stagedBatches.first)
        #expect(await host.stagedBatches.count == 1)
        #expect(written.map(\.contents) == [Self.prompt])
        #expect(arguments == ["--append-system-prompt=\(FakeLaunchPromptHost.path(for: written[0]))", "--thinking=low"])
        #expect(await host.capabilityReads == 0, "omp's route does not depend on the CLI")
    }

    /// claude's and codex's routes follow what the Host's CLI supports, read
    /// once per launch: a file route when it has one, else the inline flag.
    @Test(arguments: [SupportedAgentKind.claude, .codex], [true, false])
    func claudeAndCodexReadTheHostsCapabilities(_ kind: SupportedAgentKind, fileRoutes: Bool) async throws {
        let profileID = try #require(Self.profileID)
        let host = FakeLaunchPromptHost(capabilities: fileRoutes ? Self.files : .none)
        let arguments = try await LaunchPromptStager.launchCommand(
            kind: kind, chatOptions: Self.options(model: nil), sessionPin: nil, userArguments: [],
            initialPrompt: nil, host: host.host, hostName: "Studio", makeID: { profileID }
        ).arguments
        #expect(await host.capabilityReads == 1)
        let expected: [String]
        switch (kind, fileRoutes) {
        case (.claude, true): expected = ["--append-system-prompt-file", Self.chatPath]
        case (.claude, false): expected = ["--append-system-prompt", Self.prompt]
        case (_, true): expected = ["-p", Self.profileName]
        default: expected = ["-c", #"developer_instructions="Reply like a text.""#]
        }
        #expect(Array(arguments.prefix(2)) == expected)
    }

    @Test func noHostFailsAsNotConnected() async {
        await #expect(throws: TransportError.sshUnreachable(detail: "The Host is not connected.")) {
            try await LaunchPromptStager.launchCommand(
                kind: .pi, chatOptions: Self.options(model: nil), sessionPin: nil, userArguments: [],
                initialPrompt: nil, host: nil, hostName: "Studio")
        }
    }

    /// A link failure while writing keeps its own error, so the launch
    /// shows the usual connection copy rather than a failed write.
    @Test(arguments: [TransportError.timedOut, .sshUnreachable(detail: "reset")])
    func aLinkFailureWhileStagingSurfacesAsItself(_ failure: TransportError) async {
        let host = FakeLaunchPromptHost(failure: failure)
        await #expect(throws: failure) {
            try await LaunchPromptStager.launchCommand(
                kind: .pi, chatOptions: Self.options(model: nil), sessionPin: nil, userArguments: [],
                initialPrompt: Self.firstMessage, host: host.host, hostName: "Studio")
        }
    }

    @Test func aFailedWriteFailsTheLaunch() async {
        let host = FakeLaunchPromptHost(failure: LaunchPromptStagingError.writeFailed)
        await #expect(throws: LaunchPromptError.stagingFailed(hostName: "Studio", chatPrompt: false)) {
            try await LaunchPromptStager.launchCommand(
                kind: .opencode, chatOptions: Self.options(model: nil), sessionPin: nil, userArguments: [],
                initialPrompt: Self.firstMessage, host: host.host, hostName: "Studio")
        }
    }

    /// A path that would not read the same typed or quoted in a message is
    /// a failed write, never a launch pointing somewhere else.
    @Test func anUnusablePathFailsTheLaunch() async {
        let host = LaunchPromptHost(
            capabilities: { .none },
            stage: { files in files.map { StagedLaunchPromptFile(file: $0, path: "/tmp/my dir/\($0.name)") } },
            homeDirectory: { "/home/you" })
        await #expect(throws: LaunchPromptError.stagingFailed(hostName: "Studio", chatPrompt: true)) {
            try await LaunchPromptStager.launchCommand(
                kind: .pi, chatOptions: Self.options(model: nil), sessionPin: nil, userArguments: [],
                initialPrompt: nil, host: host, hostName: "Studio")
        }
    }
}

/// The routes and launch shapes of the harnesses beyond the first five
/// (docs/research/harnesses/<kind>.md, 2026-10-12): each Chat Prompt route,
/// first-message form, the kind's own leading arguments, and the pane
/// variables an environment route sets.
@Suite("Launch prompt stager: more harnesses")
struct HarnessLaunchRouteTests {
    private static let pin = UUID(uuidString: "0F4C2B1A-9D8E-4F70-A1B2-C3D4E5F60718")
    private static let pinText = "0f4c2b1a-9d8e-4f70-a1b2-c3d4e5f60718"
    private static let prompt = "Reply like a text."
    private static let firstMessage = "Fix it."
    private static let user = ["--verbose"]
    private static let stage = "/tmp/waycar.test"
    private static let chatPath = "\(stage)/\(LaunchPromptStager.chatPromptFileName)"
    private static let pointer = "Read and follow \(stage)/\(LaunchPromptStager.initialPromptFileName)"

    private static func options(model: String? = "m1", prompt: String = prompt) -> ChatModeLaunchOptions {
        ChatModeLaunchOptions(prompt: prompt, model: model, quickThinking: true)
    }

    private static func plan(
        _ kind: SupportedAgentKind, chat: ChatModeLaunchOptions? = options(), sessionPin: UUID? = nil,
        user: [String] = user, initialPrompt: String? = firstMessage, backend: HostBackend = .herdr,
        home: String? = nil, isResume: Bool = false
    ) -> LaunchPromptPlan {
        LaunchPromptStager.plan(
            kind: kind, chatOptions: chat, sessionPin: sessionPin, userArguments: user,
            initialPrompt: initialPrompt, capabilities: .none, backend: backend, home: home,
            isResume: isResume)
    }

    private static func command(_ plan: LaunchPromptPlan) throws -> AgentLaunchCommand {
        try plan.command(staged: FakeLaunchPromptHost.staged(plan.files))
    }

    /// Copilot takes no first message at launch (copilot.md §6): the
    /// Composer types it once the pane's input is ready.
    @Test func copilotPointsItsInstructionsVariableAtTheStagedDirectory() throws {
        let pin = try #require(Self.pin)
        let plan = Self.plan(.copilot, sessionPin: pin)
        #expect(
            plan.files
                == [
                    LaunchPromptFile(
                        destination: .stageDirectory, name: ".github/instructions/waycar.instructions.md",
                        contents: "---\napplyTo: \"**\"\n---\n\nReply like a text.\n")
                ])
        #expect(
            try Self.command(plan)
                == AgentLaunchCommand(
                    arguments: [
                        "--model", "m1", "--reasoning-effort", "low", "--session-id", Self.pinText, "--verbose",
                    ],
                    environment: ["COPILOT_CUSTOM_INSTRUCTIONS_DIRS": Self.stage]))
        #expect(try Self.command(Self.plan(.copilot, chat: nil)).arguments == ["--verbose"])
    }

    @Test func geminiIncludesTheDirectoryHoldingItsContextFile() throws {
        let plan = Self.plan(.gemini)
        #expect(plan.files.map(\.name) == ["GEMINI.md", LaunchPromptStager.initialPromptFileName])
        #expect(plan.files.first?.contents == Self.prompt)
        #expect(
            try Self.command(plan)
                == AgentLaunchCommand(arguments: [
                    "--include-directories", Self.stage, "-m", "m1", "--verbose", "-i", Self.pointer,
                ]))
    }

    @Test func agyAddsTheDirectoryHoldingItsRulesFile() throws {
        let plan = Self.plan(.antigravity)
        #expect(plan.files.map(\.name) == ["AGENTS.md", LaunchPromptStager.initialPromptFileName])
        #expect(
            try Self.command(plan)
                == AgentLaunchCommand(arguments: [
                    "--add-dir", Self.stage, "--model", "m1", "--effort", "low", "--verbose", "-i",
                    Self.pointer,
                ]))
    }

    /// A pointer into the stage directory needs it in the workspace of a
    /// kind whose file tools ask before reading elsewhere: Chat Mode or
    /// not, and once even when the route already names it.
    @Test func pointersOutsideTheWorkspaceGetTheirDirectoryAdded() throws {
        let expected: [(SupportedAgentKind, [String])] = [
            (.qwen, ["--include-directories", Self.stage, "--verbose", "-i", Self.pointer]),
            (.gemini, ["--include-directories", Self.stage, "--verbose", "-i", Self.pointer]),
            (.antigravity, ["--add-dir", Self.stage, "--verbose", "-i", Self.pointer]),
            (.claude, ["--verbose", "--", Self.pointer]),
        ]
        for (kind, arguments) in expected {
            #expect(try Self.command(Self.plan(kind, chat: nil)).arguments == arguments, "\(kind.rawValue)")
        }
        let gemini = try Self.command(Self.plan(.gemini)).arguments
        #expect(gemini.filter { $0 == "--include-directories" }.count == 1)
    }

    /// Hermes's prompt rides the pane's environment, so only the first
    /// message is a file, under its `chat` subcommand.
    @Test func hermesSetsItsEphemeralPromptAndRunsChat() throws {
        let plan = Self.plan(.hermes)
        #expect(plan.files.map(\.name) == [LaunchPromptStager.initialPromptFileName])
        #expect(
            try Self.command(plan)
                == AgentLaunchCommand(
                    arguments: ["chat", "-m", "m1", "--reasoning", "low", "--verbose", "-q", Self.pointer],
                    environment: ["HERMES_EPHEMERAL_SYSTEM_PROMPT": Self.prompt]))
    }

    @Test func qwenAndGrokTakeTheirInlineFlagWhileItFits() throws {
        let pin = try #require(Self.pin)
        #expect(
            try Self.command(Self.plan(.qwen, sessionPin: pin)).arguments
                == [
                    "--include-directories", Self.stage, "--append-system-prompt", Self.prompt, "-m", "m1",
                    "--session-id", Self.pinText,
                    "--verbose", "-i", Self.pointer,
                ])
        #expect(
            try Self.command(Self.plan(.grok, sessionPin: pin)).arguments
                == [
                    "--rules", Self.prompt, "-m", "m1", "--effort", "low", "--session-id", Self.pinText,
                    "--verbose", Self.pointer,
                ])
        #expect(
            try Self.command(Self.plan(.muse, sessionPin: pin)).arguments
                == [
                    "-c", "run.developer_prompt=" + CodexProfileTOML.basicString(Self.prompt),
                    "--model", "m1", "--reasoning-effort", "low", "--verbose", Self.pointer,
                ])
    }

    /// herdr types the line, so the default Chat Prompt (about 1.7 KB)
    /// moves into a first-message pointer there; tmux runs the command, so
    /// it stays inline and no pointer file is written.
    @Test(arguments: [SupportedAgentKind.qwen, .grok, .muse])
    func theInlineFlagIsBudgetedOnlyOnHerdr(_ kind: SupportedAgentKind) throws {
        let chat = Self.options(model: nil, prompt: ChatModePrompt.defaultText)
        let typed = Self.plan(kind, chat: chat, user: [], initialPrompt: nil)
        let pointer = "Read and follow \(Self.chatPath) as standing instructions for this session"
        #expect(try Self.command(typed).arguments.last == pointer)
        #expect(
            try Self.command(typed).arguments.contains("--include-directories") == (kind == .qwen))
        let tmux = Self.plan(kind, chat: chat, user: [], initialPrompt: nil, backend: .tmux)
        #expect(tmux.files.isEmpty)
        let inline =
            kind == .muse
            ? "run.developer_prompt=" + CodexProfileTOML.basicString(ChatModePrompt.defaultText)
            : ChatModePrompt.defaultText
        #expect(try Self.command(tmux).arguments.prefix(2).last == inline)
    }

    @Test func aTmuxLineOverTheBudgetStillLaunches() throws {
        let plan = Self.plan(.pi, user: ["--note", String(repeating: "x", count: 1_000)], backend: .tmux)
        #expect(try Self.command(plan).arguments.contains("--note"))
    }

    /// A resumed Grok session keeps the rules it started with; Qwen's
    /// inline flag rides again when it fits.
    @Test func resumesCarryOnlyThePromptsTheirSessionsLose() throws {
        let grok = Self.plan(.grok, user: ["--resume", "s-1"], initialPrompt: nil, isResume: true)
        #expect(grok.files.isEmpty)
        #expect(try Self.command(grok).arguments == ["-m", "m1", "--effort", "low", "--resume", "s-1"])
        let qwen = Self.plan(.qwen, user: ["--resume", "s-1"], initialPrompt: nil, isResume: true)
        #expect(
            try Self.command(qwen).arguments
                == ["--append-system-prompt", Self.prompt, "-m", "m1", "--resume", "s-1"])
        let muse = Self.plan(.muse, user: ["resume", "s-1"], initialPrompt: nil, isResume: true)
        #expect(muse.files.isEmpty)
        #expect(
            try Self.command(muse).arguments
                == [
                    "-c", "run.developer_prompt=" + CodexProfileTOML.basicString(Self.prompt),
                    "--model", "m1", "--reasoning-effort", "low", "resume", "s-1",
                ])
        let hermes = Self.plan(.hermes, user: ["--resume", "s-1"], initialPrompt: nil, isResume: true)
        #expect(
            try Self.command(hermes)
                == AgentLaunchCommand(
                    arguments: ["chat", "-m", "m1", "--reasoning", "low", "--resume", "s-1"],
                    environment: ["HERMES_EPHEMERAL_SYSTEM_PROMPT": Self.prompt]))
        let copilot = Self.plan(.copilot, user: ["--resume=s-1"], initialPrompt: nil, isResume: true)
        #expect(try Self.command(copilot).environment == ["COPILOT_CUSTOM_INSTRUCTIONS_DIRS": Self.stage])
    }

    /// Kilo's prompt rides the Chat Marker like OpenCode's; Cline has no
    /// per-launch append, so neither stages one.
    @Test func kiloAndClineStageNoChatPrompt() throws {
        let kilo = Self.plan(.kilo)
        #expect(kilo.files.map(\.name) == [LaunchPromptStager.initialPromptFileName])
        #expect(try Self.command(kilo).arguments == ["-m", "m1", "--verbose", "--prompt", Self.pointer])
        let cline = Self.plan(.cline, home: "/home/you")
        #expect(cline.files.map(\.name) == [LaunchPromptStager.initialPromptFileName])
        #expect(
            try Self.command(cline).arguments
                == [
                    "-i", "--data-dir", "/home/you/.cline/data", "-m", "m1", "--thinking", "low",
                    "--verbose", Self.pointer,
                ])
    }

    @Test func eachKindTakesItsFirstMessageForm() throws {
        let cases: [(SupportedAgentKind, [String])] = [
            (.kiro, ["chat", "--verbose", Self.pointer]),
            (.devin, ["--verbose", "--", Self.pointer]),
            (.cursor, ["--verbose", Self.pointer]),
        ]
        for (kind, expected) in cases {
            #expect(try Self.command(Self.plan(kind, chat: nil)).arguments == expected, "\(kind.rawValue)")
        }
    }

    /// A subcommand or the user's own flags take the place of the kind's
    /// leading arguments.
    @Test func theUsersArgumentsOverrideTheKindsOwn() {
        let home = "/home/you/"
        #expect(LaunchPromptStager.kindArguments(kind: .kiro, userArguments: ["whoami"], home: nil) == [])
        #expect(LaunchPromptStager.kindArguments(kind: .hermes, userArguments: ["--tui"], home: nil) == ["chat"])
        #expect(
            LaunchPromptStager.kindArguments(kind: .cline, userArguments: ["--data-dir", "/x"], home: home)
                == ["-i"])
        #expect(
            LaunchPromptStager.kindArguments(kind: .cline, userArguments: ["--tui"], home: home)
                == ["--data-dir", "/home/you/.cline/data"])
        #expect(LaunchPromptStager.kindArguments(kind: .cline, userArguments: ["auth"], home: home) == [])
        #expect(!LaunchPromptStager.needsHome(kind: .cline, userArguments: ["--data-dir=/x"]))
        #expect(!LaunchPromptStager.needsHome(kind: .pi, userArguments: []))
    }

    /// Cline's `--data-dir` needs the Host's `$HOME`, which only its
    /// launches read; a launch with no Host fails rather than start in
    /// Cline's shared hub.
    @Test func onlyClineReadsTheHostsHome() async throws {
        let host = FakeLaunchPromptHost()
        let cline = try await LaunchPromptStager.launchCommand(
            kind: .cline, chatOptions: nil, sessionPin: nil, userArguments: [], initialPrompt: nil,
            host: host.host, hostName: "Studio")
        #expect(cline.arguments == ["-i", "--data-dir", "\(FakeLaunchPromptHost.home)/.cline/data"])
        _ = try await LaunchPromptStager.launchCommand(
            kind: .grok, chatOptions: nil, sessionPin: nil, userArguments: [], initialPrompt: nil,
            host: host.host, hostName: "Studio")
        #expect(await host.homeReads == 1)
        #expect(await host.stagedBatches.isEmpty)
        await #expect(throws: TransportError.sshUnreachable(detail: "The Host is not connected.")) {
            try await LaunchPromptStager.launchCommand(
                kind: .cline, chatOptions: nil, sessionPin: nil, userArguments: [], initialPrompt: nil,
                host: nil, hostName: "Studio")
        }
    }

    /// An environment-only route needs no Host write.
    @Test func hermesChatModeWithoutAFirstMessageNeverTouchesTheHost() async throws {
        let command = try await LaunchPromptStager.launchCommand(
            kind: .hermes, chatOptions: Self.options(model: nil), sessionPin: nil, userArguments: [],
            initialPrompt: nil, host: nil, hostName: "Studio")
        #expect(
            command
                == AgentLaunchCommand(
                    arguments: ["chat", "--reasoning", "low"],
                    environment: ["HERMES_EPHEMERAL_SYSTEM_PROMPT": Self.prompt]))
    }
}
