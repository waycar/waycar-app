import Foundation
import Testing

@testable import Waycar

@Suite("Chat Mode launch arguments")
struct ChatModeLaunchTests {
    private let pin = UUID(uuidString: "0F4C2B1A-9D8E-4F70-A1B2-C3D4E5F60718")
    private let pinText = "0f4c2b1a-9d8e-4f70-a1b2-c3d4e5f60718"
    private let prompt = "Reply like a text."

    /// The prompt alone: no model, Quick thinking off.
    private var promptOnly: ChatModeLaunchOptions { ChatModeLaunchOptions(prompt: prompt, quickThinking: false) }

    private func tuned(_ model: String) -> ChatModeLaunchOptions {
        ChatModeLaunchOptions(prompt: prompt, model: model, quickThinking: true)
    }

    /// The Chat Prompt never rides these arguments: it goes to a Launch
    /// Prompt File (`LaunchPromptStager`), so a long prompt cannot overflow
    /// the typed launch line.
    @Test(arguments: SupportedAgentKind.allCases.filter(\.supportsChatMode))
    func thePromptIsNeverAnArgument(_ kind: SupportedAgentKind) {
        let arguments = ChatModeLaunch.arguments(kind: kind, options: tuned("m"), sessionPin: UUID())
        #expect(!arguments.contains { $0.contains(prompt) }, "\(kind.rawValue)")
    }

    @Test func claudeAndPiPinTheSession() throws {
        let pin = try #require(pin)
        #expect(
            ChatModeLaunch.arguments(kind: .claude, options: promptOnly, sessionPin: pin)
                == ["--session-id", pinText])
        #expect(ChatModeLaunch.arguments(kind: .claude, options: promptOnly, sessionPin: nil) == [])
        #expect(
            ChatModeLaunch.arguments(kind: .pi, options: promptOnly, sessionPin: pin)
                == ["--session-id", pinText])
    }

    @Test func codexAndOmpIgnoreAPin() {
        #expect(ChatModeLaunch.arguments(kind: .codex, options: promptOnly, sessionPin: UUID()) == [])
        #expect(ChatModeLaunch.arguments(kind: .omp, options: promptOnly, sessionPin: UUID()) == [])
    }

    /// OpenCode has no system-prompt flag: the launch carries only the
    /// model, and it never pins a session (1.18.x cannot create one by id).
    @Test func opencodeSendsOnlyTheModelAndIgnoresAPin() {
        #expect(
            ChatModeLaunch.arguments(kind: .opencode, options: promptOnly, sessionPin: UUID())
                == [])
        #expect(ChatModeLaunch.sessionPin(kind: .opencode, userArguments: [], makeID: { UUID() }) == nil)
    }

    /// Model, then thinking, then the pin.
    @Test func modelAndQuickThinkingGoBeforeThePin() throws {
        let pin = try #require(pin)
        #expect(
            ChatModeLaunch.arguments(kind: .claude, options: tuned("opus"), sessionPin: pin)
                == ["--model", "opus", "--effort", "low", "--session-id", pinText])
        #expect(
            ChatModeLaunch.arguments(kind: .codex, options: tuned("gpt-5"), sessionPin: nil)
                == ["-m", "gpt-5", "-c", #"model_reasoning_effort="low""#])
        #expect(
            ChatModeLaunch.arguments(kind: .omp, options: tuned("sonnet"), sessionPin: nil)
                == ["--model=sonnet", "--thinking=low"])
        #expect(
            ChatModeLaunch.arguments(kind: .pi, options: tuned("openai/gpt-5"), sessionPin: pin)
                == ["--model", "openai/gpt-5", "--thinking", "low", "--session-id", pinText])
    }

    /// The user's own arguments win: our model or reasoning flag is left out
    /// when they already set it, and the other one stays.
    @Test func userArgumentsSuppressTheFlagsTheySet() {
        let low = ["-c", #"model_reasoning_effort="low""#]
        let cases: [(SupportedAgentKind, model: String, user: [String], expected: [String])] = [
            (.claude, "opus", ["--model=sonnet"], ["--effort", "low"]),
            (.claude, "opus", ["--model", "sonnet"], ["--effort", "low"]),
            (.claude, "opus", ["--effort", "high"], ["--model", "opus"]),
            (.claude, "opus", ["--effort=max"], ["--model", "opus"]),
            (.codex, "gpt-5", ["-c", "model=o3"], low),
            (.codex, "gpt-5", ["--config=model=o3"], low),
            (.codex, "gpt-5", ["-m", "o3"], low),
            (.codex, "gpt-5", ["--model=o3"], low),
            (.codex, "gpt-5", ["--config", "model_reasoning_effort=high"], ["-m", "gpt-5"]),
            (.codex, "gpt-5", ["-c", "model_provider=oss"], low),
            // clap takes a short flag's value attached, and codex refuses a second model.
            (.codex, "gpt-5", ["-mo3"], low),
            (.codex, "gpt-5", ["-m=o3"], low),
            (.codex, "gpt-5", ["-cmodel=o3"], low),
            (.codex, "gpt-5", ["-c=model=o3"], low),
            (.codex, "gpt-5", ["-cmodel_reasoning_effort=high"], ["-m", "gpt-5"]),
            (.codex, "gpt-5", ["-c=model_reasoning_effort=high"], ["-m", "gpt-5"]),
            // A local provider picks its own default model.
            (.codex, "gpt-5", ["--oss"], low),
            (.codex, "gpt-5", ["--local-provider", "ollama"], low),
            (.codex, "gpt-5", ["--local-provider=lmstudio"], low),
            (.codex, "gpt-5", ["--profile", "fast"], []),
            (.codex, "gpt-5", ["-p=fast"], []),
            (.codex, "gpt-5", ["-pfast"], []),
            (.codex, "gpt-5", ["-c", "profile=fast"], []),
            (.codex, "gpt-5", ["--config=profile=fast"], []),
            (.omp, "sonnet", ["--model", "opus"], ["--thinking=low"]),
            (.omp, "sonnet", ["--thinking=high"], ["--model=sonnet"]),
            (.omp, "sonnet", ["--provider", "openai"], ["--thinking=low"]),
            (.omp, "sonnet", ["--provider=openai"], ["--thinking=low"]),
            // opencode takes only the model, and accepts `-m` or `--model`.
            (.opencode, "anthropic/claude-sonnet-4", [], ["-m", "anthropic/claude-sonnet-4"]),
            (.opencode, "anthropic/claude-sonnet-4", ["--model", "x/y"], []),
            (.opencode, "anthropic/claude-sonnet-4", ["--model=x/y"], []),
            (.opencode, "anthropic/claude-sonnet-4", ["-m", "x/y"], []),
            // The TUI has no reasoning-effort flag, so Quick thinking sends nothing.
            (.opencode, "anthropic/claude-sonnet-4", ["--effort", "high"], ["-m", "anthropic/claude-sonnet-4"]),
            (.pi, "gpt-5", ["--provider", "openai"], ["--thinking", "low"]),
            (.pi, "gpt-5", ["--provider=openai"], ["--thinking", "low"]),
            (.pi, "gpt-5", ["--model=o3"], ["--thinking", "low"]),
            (.pi, "gpt-5", ["--thinking", "high"], ["--model", "gpt-5"]),
            // pi's `model:level` already sets the thinking level.
            (.pi, "sonnet:high", [], ["--model", "sonnet:high"]),
            (.pi, "openai/gpt-5:xhigh", [], ["--model", "openai/gpt-5:xhigh"]),
            // Not a level after the colon: a plain model id.
            (.pi, "deepseek/deepseek-r1:free", [], ["--model", "deepseek/deepseek-r1:free", "--thinking", "low"]),
            // Not sent, so it sets nothing.
            (.pi, "sonnet:high", ["--model", "opus"], ["--thinking", "low"]),
            // The user's own `model:level` wins over Quick thinking too.
            (.pi, "gpt-5", ["--model", "opus:high"], []),
            (.pi, "gpt-5", ["--model", "qwen3:8b"], ["--thinking", "low"]),
            // A `--model` sets the starting model, so `--models` levels don't count.
            (.pi, "gpt-5", ["--models", "haiku, sonnet:off"], ["--model", "gpt-5", "--thinking", "low"]),
            (.pi, "gpt-5", ["--models", "haiku,qwen3:8b"], ["--model", "gpt-5", "--thinking", "low"]),
            // Without a `--model`, pi starts on a `--models` entry: only when
            // every entry has a level is the level already set.
            (.pi, "gpt-5", ["--provider", "openai", "--models", "haiku,sonnet:high"], ["--thinking", "low"]),
            (.pi, "gpt-5", ["--provider", "openai", "--models", "opus:high,sonnet:low"], []),
        ]
        for (kind, model, user, expected) in cases {
            #expect(
                ChatModeLaunch.arguments(kind: kind, options: tuned(model), sessionPin: nil, userArguments: user)
                    == expected,
                "\(kind.rawValue) \(user)")
        }
    }

    @Test func flagsThatOnlyShareAPrefixSuppressNothing() {
        #expect(
            ChatModeLaunch.arguments(
                kind: .claude, options: tuned("opus"), sessionPin: nil, userArguments: ["--model-fallback", "x"])
                == ["--model", "opus", "--effort", "low"])
    }

    @Test func modelLosesWhitespaceAndControlCharacters() {
        #expect(ChatModeLaunchOptions.normalizedModel(" claude opus\n4\t") == "claudeopus4")
        #expect(ChatModeLaunchOptions.normalizedModel("gpt\u{0007}-5\r\n") == "gpt-5")
        #expect(ChatModeLaunchOptions.normalizedModel("openai/gpt-5:high") == "openai/gpt-5:high")
    }

    /// Zero-width and byte-order marks are invisible in Settings but would
    /// reach the harness, and a joiner mustn't take its neighbor with it.
    @Test func modelLosesFormatCharacters() {
        #expect(ChatModeLaunchOptions.normalizedModel("\u{FEFF}gpt\u{200B}-5\u{2060}") == "gpt-5")
        #expect(ChatModeLaunchOptions.normalizedModel("gpt\u{200D}5") == "gpt5")
    }

    @Test(arguments: [nil, "", "   ", "\n\t \n", "\u{0007}", "\u{200B}\u{FEFF}"] as [String?])
    func blankModelIsNil(_ text: String?) {
        #expect(ChatModeLaunchOptions.normalizedModel(text) == nil)
    }

    /// codex takes `-m`'s value as its own argument, so a dash would read as a flag.
    @Test(arguments: ["-x", "--oss", " -m gpt-5", "\u{200B}-mo3"])
    func modelThatReadsAsAFlagIsNil(_ text: String) {
        #expect(ChatModeLaunchOptions.normalizedModel(text) == nil)
    }

    @Test func modelCapsAtTwoHundredCharacters() {
        let long = String(repeating: "m", count: 250)
        #expect(ChatModeLaunchOptions.normalizedModel(long) == String(repeating: "m", count: 200))
        #expect(ChatModeLaunchOptions.normalizedModel(" " + long) == String(repeating: "m", count: 200))
    }

    @Test func kindsWithoutChatModeGetNoArguments() {
        #expect(!SupportedAgentKind.cursor.supportsChatMode)
        #expect(ChatModeLaunch.arguments(kind: .cursor, options: tuned("x"), sessionPin: UUID()).isEmpty)
        #expect(
            SupportedAgentKind.allCases.filter(\.supportsChatMode).map(\.rawValue).sorted()
                == [
                    "agy", "claude", "cline", "codex", "copilot", "gemini", "grok", "hermes", "kilo", "muse",
                    "omp", "opencode", "pi", "qwen",
                ])
    }

    /// Each newer harness's model and reasoning flags, then its pin where
    /// it takes one (docs/research/harnesses/<kind>.md §6–8).
    @Test func newerHarnessesGetTheirOwnFlags() throws {
        let pin = try #require(pin)
        let cases: [(SupportedAgentKind, [String])] = [
            (.copilot, ["--model", "m", "--reasoning-effort", "low", "--session-id", pinText]),
            (.qwen, ["-m", "m", "--session-id", pinText]),
            (.gemini, ["-m", "m"]),
            (.grok, ["-m", "m", "--effort", "low", "--session-id", pinText]),
            (.antigravity, ["--model", "m", "--effort", "low"]),
            (.hermes, ["-m", "m", "--reasoning", "low"]),
            (.kilo, ["-m", "m"]),
            (.cline, ["-m", "m", "--thinking", "low"]),
            (.muse, ["--model", "m", "--reasoning-effort", "low"]),
        ]
        for (kind, expected) in cases {
            #expect(
                ChatModeLaunch.arguments(kind: kind, options: tuned("m"), sessionPin: pin) == expected,
                "\(kind.rawValue)")
        }
    }

    @Test func newerHarnessesLeaveOutWhatTheUserSet() {
        let cases: [(SupportedAgentKind, user: [String], expected: [String])] = [
            (.copilot, ["--model=x"], ["--reasoning-effort", "low"]),
            (.copilot, ["--reasoning-effort", "high"], ["--model", "m"]),
            (.qwen, ["--model", "x"], []),
            (.gemini, ["-m", "x"], []),
            (.grok, ["--reasoning-effort=high"], ["-m", "m"]),
            (.hermes, ["--reasoning", "none"], ["-m", "m"]),
            (.kilo, ["--model=a/b"], []),
            // A model meant for Cline's default provider breaks under another.
            (.cline, ["-P", "openai"], ["--thinking", "low"]),
            (.cline, ["--thinking", "high"], ["-m", "m"]),
            (.muse, ["--effort", "high"], ["--model", "m"]),
            (.muse, ["--model=x", "--reasoning-effort=max"], []),
        ]
        for (kind, user, expected) in cases {
            #expect(
                ChatModeLaunch.arguments(kind: kind, options: tuned("m"), sessionPin: nil, userArguments: user)
                    == expected,
                "\(kind.rawValue) \(user)")
        }
    }

    /// agy reads `<family>-<effort>` as a model with its effort, and with
    /// `--effort` as well silently falls back to its default model
    /// (agy.md §8): such a model, ours or the user's, gets no `--effort`,
    /// and the user's own `--effort` gets only our model's family.
    @Test func agyNeverPairsACombinedModelWithAnEffort() {
        #expect(
            ChatModeLaunch.arguments(kind: .antigravity, options: tuned("gemini-3.6-flash-high"), sessionPin: nil)
                == ["--model", "gemini-3.6-flash-high"])
        #expect(
            ChatModeLaunch.arguments(
                kind: .antigravity, options: tuned("gemini-3.6-flash"), sessionPin: nil,
                userArguments: ["--model=gemini-3.1-pro-low"]) == [])
        #expect(
            ChatModeLaunch.arguments(
                kind: .antigravity, options: tuned("gemini-3.6-flash-high"), sessionPin: nil,
                userArguments: ["--model", "gemini-3.1-pro"]) == ["--effort", "low"])
        #expect(
            ChatModeLaunch.arguments(
                kind: .antigravity, options: ChatModeLaunchOptions(prompt: prompt, quickThinking: true),
                sessionPin: nil) == ["--effort", "low"])
        #expect(
            ChatModeLaunch.arguments(
                kind: .antigravity, options: tuned("gemini-3.6-flash-high"), sessionPin: nil,
                userArguments: ["--effort", "medium"]) == ["--model", "gemini-3.6-flash"])
        #expect(
            ChatModeLaunch.arguments(
                kind: .antigravity, options: tuned("gemini-3.6-flash-high"), sessionPin: nil,
                userArguments: ["--effort=medium"]) == ["--model", "gemini-3.6-flash"])
        #expect(
            ChatModeLaunch.arguments(
                kind: .antigravity, options: tuned("gemini-3.6-flash"), sessionPin: nil,
                userArguments: ["--effort", "medium"]) == ["--model", "gemini-3.6-flash"])
    }

    @Test func freshClaudePiCopilotQwenAndGrokLaunchesPin() throws {
        let pin = try #require(pin)
        #expect(ChatModeLaunch.sessionPin(kind: .claude, userArguments: [], makeID: { pin }) == pin)
        #expect(
            ChatModeLaunch.sessionPin(kind: .claude, userArguments: ["--model", "opus"], makeID: { pin }) == pin)
        for kind in [SupportedAgentKind.pi, .copilot, .qwen, .grok] {
            #expect(ChatModeLaunch.sessionPin(kind: kind, userArguments: [], makeID: { pin }) == pin)
        }
    }

    @Test func userSessionFlagsSuppressThePin() {
        let conflicting: [(SupportedAgentKind, [String])] = [
            (.claude, ["--resume", "x"]),
            (.claude, ["--continue"]),
            (.claude, ["--session-id=abc"]),
            (.claude, ["-r"]),
            (.pi, ["--session=abc"]),
            (.pi, ["--no-session"]),
            (.pi, ["--fork", "abc"]),
            (.copilot, ["--resume=abc"]),
            (.copilot, ["--continue"]),
            (.qwen, ["-c"]),
            (.qwen, ["--fork-session"]),
            (.grok, ["-s", "abc"]),
            (.grok, ["-r", "abc"]),
        ]
        for (kind, arguments) in conflicting {
            #expect(
                ChatModeLaunch.sessionPin(kind: kind, userArguments: arguments, makeID: { UUID() }) == nil,
                "\(kind.rawValue) \(arguments)")
        }
    }

    @Test func flagsThatOnlyShareAPrefixStillPin() throws {
        let pin = try #require(pin)
        #expect(
            ChatModeLaunch.sessionPin(kind: .claude, userArguments: ["--resume-later"], makeID: { pin }) == pin)
    }

    /// The pin goes before the user's arguments, so a subcommand or a
    /// positional there (`claude mcp list`, `pi "fix it"`) gets none.
    @Test func argumentsOpeningWithASubcommandOrPositionalAreNotPinned() {
        for (kind, arguments) in [(SupportedAgentKind.claude, ["mcp", "list"]), (.pi, ["fix it"])] {
            #expect(
                ChatModeLaunch.sessionPin(kind: kind, userArguments: arguments, makeID: { UUID() }) == nil,
                "\(kind.rawValue) \(arguments)")
        }
    }

    @Test func kindsThatCannotPinNeverPin() {
        for kind in [SupportedAgentKind.codex, .omp, .opencode, .kilo, .gemini, .antigravity, .hermes, .cline] {
            #expect(ChatModeLaunch.sessionPin(kind: kind, userArguments: [], makeID: { UUID() }) == nil)
        }
    }
}

@Suite("Chat Marker")
struct ChatModeMarkerTests {
    /// 2026-09-30T12:00:00Z.
    private let launchedAt = Date(timeIntervalSince1970: 1_790_769_600)

    private func agent(terminalID: String = "term_a", kind: String = "claude") -> Agent {
        Agent(
            terminalID: terminalID, kind: kind, title: "Task", status: .idle,
            workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1", cwd: "/work/proj", revision: 1)
    }

    @Test func jsonRoundTripsWithSnakeCaseKeysAndExplicitNulls() throws {
        let marker = ChatModeMarker(
            paneID: "w1:p1", terminalID: "term_a", kind: "claude", cwd: "/work/proj",
            session: ChatModeMarker.Session(kind: "id", value: "0f4c2b1a-9d8e-4f70-a1b2-c3d4e5f60718"),
            launchedAt: launchedAt)
        let data = try JSONEncoder().encode(marker)
        #expect(try JSONDecoder().decode(ChatModeMarker.self, from: data) == marker)

        let bare = ChatModeMarker(
            paneID: "w1:p1", terminalID: nil, kind: "codex", cwd: nil, session: nil, launchedAt: launchedAt)
        let bareData = try JSONEncoder().encode(bare)
        let object = try #require(try JSONSerialization.jsonObject(with: bareData) as? [String: Any])
        #expect(
            Set(object.keys)
                == ["v", "pane_id", "terminal_id", "kind", "cwd", "session", "prompt", "chat_mode", "launched_at"])
        #expect(object["chat_mode"] as? Bool == true)
        #expect(object["v"] as? Int == 1)
        #expect(object["terminal_id"] is NSNull)
        #expect(object["prompt"] is NSNull)
        #expect(object["launched_at"] as? String == "2026-09-30T12:00:00.000Z")
        #expect(try JSONDecoder().decode(ChatModeMarker.self, from: bareData) == bare)
    }

    /// The Chat Prompt rides the marker so the plugin's
    /// `waycar-chat-prompt` extension can inject it for opencode.
    @Test func roundTripsWithAPrompt() throws {
        let marker = ChatModeMarker(
            paneID: "w1:p1", terminalID: nil, kind: "opencode", cwd: nil, session: nil,
            prompt: "Reply briefly.", launchedAt: launchedAt)
        let data = try JSONEncoder().encode(marker)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["prompt"] as? String == "Reply briefly.")
        #expect(try JSONDecoder().decode(ChatModeMarker.self, from: data) == marker)
    }

    /// Markers written before the field existed still decode, with the
    /// prompt nil.
    @Test func decodesAnOlderMarkerWithoutAPrompt() throws {
        let data = Data(
            #"{"v":1,"pane_id":"w1:p1","kind":"codex","prompt":null,"launched_at":"2026-09-30T12:00:00Z"}"#
                .utf8)
        let marker = try JSONDecoder().decode(ChatModeMarker.self, from: data)
        #expect(marker.prompt == nil)
    }

    /// `chat_mode` is absent from markers written before plain launches
    /// pinned too, which were all Chat Mode; false round-trips.
    @Test func chatModeDefaultsToTrueAndRoundTripsFalse() throws {
        let older = Data(#"{"v":1,"pane_id":"w1:p1","kind":"claude","launched_at":"2026-09-30T12:00:00Z"}"#.utf8)
        #expect(try JSONDecoder().decode(ChatModeMarker.self, from: older).chatMode)
        let plain = ChatModeMarker(
            paneID: "w1:p1", terminalID: "t1", kind: "claude", cwd: nil,
            session: .init(kind: "id", value: "pin-1"), chatMode: false, launchedAt: launchedAt)
        let data = try JSONEncoder().encode(plain)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["chat_mode"] as? Bool == false)
        #expect(try JSONDecoder().decode(ChatModeMarker.self, from: data) == plain)
    }

    @Test func decodesHostTimestampsWithAndWithoutFractionalSeconds() throws {
        let whole = Data(
            #"{"v":1,"pane_id":"w1:p1","terminal_id":null,"kind":"pi","cwd":null,"session":{"kind":"path","value":"/s.jsonl"},"launched_at":"2026-09-30T12:00:00Z","extra":true}"#
                .utf8)
        let fractional = Data(
            #"{"v":1,"pane_id":"w1:p1","kind":"pi","launched_at":"2026-09-30T12:00:00.250Z"}"#.utf8)

        let wholeMarker = try JSONDecoder().decode(ChatModeMarker.self, from: whole)
        #expect(wholeMarker.launchedAt == launchedAt)
        #expect(wholeMarker.session == ChatModeMarker.Session(kind: "path", value: "/s.jsonl"))
        let fractionalMarker = try JSONDecoder().decode(ChatModeMarker.self, from: fractional)
        #expect(abs(fractionalMarker.launchedAt.timeIntervalSince(launchedAt) - 0.25) < 0.001)
        #expect(fractionalMarker.terminalID == nil)
        #expect(fractionalMarker.session == nil)
    }

    @Test func rejectsAnUnparseableTimestamp() {
        let data = Data(#"{"v":1,"pane_id":"w1:p1","kind":"pi","launched_at":"yesterday"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ChatModeMarker.self, from: data) }
    }

    @Test func fileNameIsUnpaddedBase64URLOfThePaneID() {
        #expect(ChatModeMarker.fileName(paneID: "w1:p1") == "dzE6cDE.json")
        // Standard base64's `+` and `/` become `-` and `_`.
        #expect(ChatModeMarker.fileName(paneID: "??>") == "Pz8-.json")
        #expect(ChatModeMarker.fileName(paneID: "???") == "Pz8_.json")
    }

    @Test func appliesOnlyToTheSamePaneKindAndTerminal() {
        let marker = ChatModeMarker(
            paneID: "w1:p1", terminalID: "term_a", kind: "claude", cwd: nil, session: nil, launchedAt: launchedAt)
        #expect(marker.applies(to: agent()))
        #expect(!marker.applies(to: agent(terminalID: "term_b")))
        #expect(!marker.applies(to: agent(kind: "codex")))

        let anyTerminal = ChatModeMarker(
            paneID: "w1:p1", terminalID: nil, kind: "claude", cwd: nil, session: nil, launchedAt: launchedAt)
        #expect(anyTerminal.applies(to: agent(terminalID: "term_b")))
        #expect(!anyTerminal.applies(to: agent(kind: "codex")))

        let otherPane = ChatModeMarker(
            paneID: "w1:p2", terminalID: nil, kind: "claude", cwd: nil, session: nil, launchedAt: launchedAt)
        #expect(!otherPane.applies(to: agent()))
    }

    private func agent(terminalID: String, session: AgentSessionInfo?) -> Agent {
        Agent(
            terminalID: terminalID, kind: "omp", title: "Task", status: .idle,
            workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1", cwd: "/work/proj", revision: 1,
            agentSession: session)
    }

    private func live(_ value: String, kind: AgentSessionRefKind = .path) -> AgentSessionInfo {
        AgentSessionInfo(agent: "omp", kind: kind, source: "herdr:omp", value: value)
    }

    /// herdr restores a chat in a new terminal of the same pane, resumed
    /// under the same `agent_session`: the session recognizes it.
    @Test func appliesInANewTerminalWithTheSameSession() {
        let marker = ChatModeMarker(
            paneID: "w1:p1", terminalID: "term_old", kind: "omp", cwd: nil,
            session: .init(kind: "path", value: "/s/a.jsonl"), launchedAt: launchedAt)
        #expect(marker.applies(to: agent(terminalID: "term_new", session: live("/s/a.jsonl"))))
        #expect(!marker.applies(to: agent(terminalID: "term_new", session: live("/s/b.jsonl"))))
        #expect(!marker.applies(to: agent(terminalID: "term_new", session: live("/s/a.jsonl", kind: .id))))
        #expect(!marker.applies(to: agent(terminalID: "term_new", session: live(""))))
        #expect(!marker.applies(to: agent(terminalID: "term_new", session: nil)))
        // The same terminal still applies after a session switch in place.
        #expect(marker.applies(to: agent(terminalID: "term_old", session: live("/s/b.jsonl"))))
    }

    @Test func aMarkerWithoutASessionDoesNotApplyInANewTerminal() {
        let marker = ChatModeMarker(
            paneID: "w1:p1", terminalID: "term_old", kind: "omp", cwd: nil, session: nil,
            launchedAt: launchedAt)
        #expect(!marker.applies(to: agent(terminalID: "term_new", session: live("/s/a.jsonl"))))
    }

    @Test func aSessionMatchNeedsTheSameAgentKind() {
        let marker = ChatModeMarker(
            paneID: "w1:p1", terminalID: "term_old", kind: "claude", cwd: nil,
            session: .init(kind: "path", value: "/s/a.jsonl"), launchedAt: launchedAt)
        #expect(!marker.applies(to: agent(terminalID: "term_new", session: live("/s/a.jsonl"))))
    }
}

@Suite("Chat transcript decoding")
struct ChatTranscriptDecodingTests {
    private func decode(_ lines: [String]) throws -> ChatTranscriptSnapshot {
        try ChatTranscriptDecoding.decode(Data(lines.joined(separator: "\n").utf8))
    }

    @Test func decodesTheHeaderAndMessagesInOrder() throws {
        let snapshot = try decode([
            "",
            #"{"type":"header","v":1,"kind":"claude","status":"ok","transcript":"/t.jsonl","activity":"Running npm test","turn_open":true,"truncated":false,"error":null}"#,
            #"{"type":"message","id":"u1","role":"user","text":"is the build green?","ts":"2026-09-30T12:00:01.500Z"}"#,
            #"{"type":"message","id":"a1","role":"assistant","text":"Yes, all green.","ts":"2026-09-30T12:00:40Z"}"#,
            "",
        ])
        #expect(
            snapshot.header
                == ChatTranscriptHeader(
                    kind: "claude", status: .ok, transcript: "/t.jsonl", activity: "Running npm test",
                    turnOpen: true, truncated: false, error: nil))
        #expect(snapshot.messages.map(\.id) == ["u1", "a1"])
        #expect(snapshot.messages.map(\.role) == [.user, .assistant])
        #expect(snapshot.messages[1].text == "Yes, all green.")
        #expect(snapshot.messages[0].timestamp == Date(timeIntervalSince1970: 1_790_769_601.5))
        #expect(snapshot.messages[1].timestamp == Date(timeIntervalSince1970: 1_790_769_640))
    }

    @Test func skipsUnknownLineTypesMalformedMessagesAndUnknownRoles() throws {
        let snapshot = try decode([
            #"{"type":"header","v":1,"kind":"pi","status":"ok","transcript":null,"activity":null,"turn_open":false,"truncated":true,"error":null}"#,
            #"{"type":"progress","id":"x"}"#,
            #"{"type":"message","id":"u1","role":"user""#,
            #"{"type":"message","role":"user","text":"no id"}"#,
            #"{"type":"message","id":"s1","role":"system","text":"hidden"}"#,
            #"{"type":"message","id":"a1","role":"assistant","text":"","ts":"not a date","future":1}"#,
        ])
        #expect(snapshot.header.truncated)
        #expect(snapshot.messages == [ChatTranscriptMessage(id: "a1", role: .assistant, text: "", timestamp: nil)])
    }

    @Test func outputWithoutALeadingHeaderIsMalformed() {
        #expect(throws: ChatTranscriptError.malformedOutput) {
            try decode([#"{"type":"message","id":"u1","role":"user","text":"hi"}"#])
        }
        #expect(throws: ChatTranscriptError.malformedOutput) { try decode(["", "  "]) }
        #expect(throws: ChatTranscriptError.malformedOutput) { try decode(["node: not found"]) }
    }

    @Test func mapsHeaderStatuses() throws {
        func status(_ raw: String) throws -> ChatTranscriptHeader.Status {
            try decode([#"{"type":"header","v":1,"kind":"codex","status":"\#(raw)","turn_open":false,"truncated":false}"#])
                .header.status
        }
        #expect(try status("not_found") == .notFound)
        #expect(try status("unsupported") == .unsupported)
        #expect(try status("exploded") == .error)
        let notFound = try decode([
            #"{"type":"header","v":1,"kind":"codex","status":"not_found","transcript":null,"activity":null,"turn_open":false,"truncated":false,"error":null}"#
        ])
        #expect(notFound.messages.isEmpty)
        #expect(notFound.header.transcript == nil)
    }
}

@MainActor
@Suite("Chat Mode store")
struct ChatModeStoreTests {
    private let hostID = UUID()
    private let start = Date(timeIntervalSince1970: 1_790_769_600)

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-chat-markers-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func marker(_ paneID: String, terminalID: String? = nil, launchedAt: Date? = nil) -> ChatModeMarker {
        ChatModeMarker(
            paneID: paneID, terminalID: terminalID, kind: "claude", cwd: "/work/proj", session: nil,
            launchedAt: launchedAt ?? start)
    }

    private func consoleAgent(_ paneID: String, hostID: Host.ID, terminalID: String = "term_a", kind: String = "claude")
        -> ConsoleAgent
    {
        ConsoleAgent(
            hostID: hostID, hostName: "devbox",
            agent: Agent(
                terminalID: terminalID, kind: kind, title: "Task", status: .working,
                workspaceID: "w1", tabID: "w1:t1", paneID: paneID, cwd: "/work/proj", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil)
    }

    @Test func markersPersistAcrossInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = ChatModeStore(defaults: defaults, now: { self.start })
        store.record(marker("w1:p1", terminalID: "term_a"), hostID: hostID)
        store.replaceMarkers([marker("w1:p1", terminalID: "term_a"), marker("w1:p2")], for: hostID)
        #expect(store.revision == 2)

        let reloaded = ChatModeStore(defaults: defaults, now: { self.start })
        #expect(reloaded.marker(for: .init(hostID: hostID, paneID: "w1:p1")) == marker("w1:p1", terminalID: "term_a"))
        #expect(reloaded.isChatMode(consoleAgent("w1:p2", hostID: hostID)))
    }

    @Test func replaceDropsStaleMarkersButKeepsARecentLocalRecord() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        var clock = start
        let store = ChatModeStore(defaults: defaults, now: { clock })

        store.replaceMarkers([marker("w1:p1")], for: hostID)
        store.record(marker("w1:p2"), hostID: hostID)
        clock = start.addingTimeInterval(60)
        store.replaceMarkers([marker("w1:p3")], for: hostID)

        #expect(store.marker(for: .init(hostID: hostID, paneID: "w1:p1")) == nil)
        #expect(store.marker(for: .init(hostID: hostID, paneID: "w1:p2")) != nil)
        #expect(store.marker(for: .init(hostID: hostID, paneID: "w1:p3")) != nil)

        clock = start.addingTimeInterval(ChatModeStore.localRecordGrace + 1)
        store.replaceMarkers([marker("w1:p3")], for: hostID)
        #expect(store.marker(for: .init(hostID: hostID, paneID: "w1:p2")) == nil)
        #expect(store.marker(for: .init(hostID: hostID, paneID: "w1:p3")) != nil)
    }

    @Test func aRecentLocalRecordWinsOverAnOlderHostCopyOfTheSamePane() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ChatModeStore(defaults: defaults, now: { self.start })
        let fresh = marker("w1:p1", terminalID: "term_new", launchedAt: start)
        store.record(fresh, hostID: hostID)

        store.replaceMarkers(
            [marker("w1:p1", terminalID: "term_old", launchedAt: start.addingTimeInterval(-3_600))], for: hostID)
        #expect(store.marker(for: .init(hostID: hostID, paneID: "w1:p1")) == fresh)
    }

    @Test func replaceWithAnUnchangedListLeavesTheRevisionAlone() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ChatModeStore(defaults: defaults, now: { self.start })
        store.replaceMarkers([marker("w1:p1")], for: hostID)
        let revision = store.revision
        store.replaceMarkers([marker("w1:p1")], for: hostID)
        #expect(store.revision == revision)
    }

    @Test func markersAreIsolatedPerHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let otherHost = UUID()
        let store = ChatModeStore(defaults: defaults, now: { self.start })
        store.replaceMarkers([marker("w1:p1")], for: hostID)
        store.replaceMarkers([], for: otherHost)

        #expect(store.isChatMode(consoleAgent("w1:p1", hostID: hostID)))
        #expect(!store.isChatMode(consoleAgent("w1:p1", hostID: otherHost)))

        store.replaceMarkers([], for: hostID)
        #expect(!store.isChatMode(consoleAgent("w1:p1", hostID: hostID)))
    }

    @Test func aMarkerThatNoLongerAppliesIsNotChatMode() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ChatModeStore(defaults: defaults, now: { self.start })
        store.replaceMarkers([marker("w1:p1", terminalID: "term_old")], for: hostID)

        #expect(store.isChatMode(consoleAgent("w1:p1", hostID: hostID, terminalID: "term_old")))
        #expect(!store.isChatMode(consoleAgent("w1:p1", hostID: hostID, terminalID: "term_new")))
        #expect(!store.isChatMode(consoleAgent("w1:p1", hostID: hostID, terminalID: "term_old", kind: "codex")))
    }

    /// A plain launch's marker records its pin for Closed Sessions but
    /// makes no chat.
    @Test func aPlainLaunchMarkerIsNoChatButKeepsItsPin() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ChatModeStore(defaults: defaults, now: { self.start })
        let plain = ChatModeMarker(
            paneID: "w1:p1", terminalID: nil, kind: "claude", cwd: "/work/proj",
            session: .init(kind: "id", value: "pin-1"), chatMode: false, launchedAt: start)
        store.record(plain, hostID: hostID)
        let agent = consoleAgent("w1:p1", hostID: hostID)

        #expect(!store.isChatMode(agent))
        #expect(store.hasMarker(agent))
        #expect(plain.launchSession(of: agent.agent) == .init(kind: "id", value: "pin-1"))
        #expect(plain.launchSession(of: consoleAgent("w1:p1", hostID: hostID, kind: "codex").agent) == nil)
        #expect(store.follow(agent) == nil, "a nil terminal and no live session leave it as is")
    }

    /// The Host's delete is best effort: until the Host stops listing a
    /// retired marker, its copy is not adopted again and is deleted again.
    @Test func aRetiredMarkersHostCopyIsDeletedAgainAndNotAdopted() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ChatModeStore(defaults: defaults, now: { self.start })
        let id = ConsoleAgent.ID(hostID: hostID, paneID: "w1:p1")
        // Recorded here at full precision; the Host's copy carries milliseconds.
        store.record(marker("w1:p1", launchedAt: start.addingTimeInterval(0.0004)), hostID: hostID)
        let hostCopy = marker("w1:p1")
        store.retire(id)
        #expect(store.marker(for: id) == nil)

        let repairs = store.replaceMarkers([hostCopy, marker("w1:p2")], for: hostID)
        #expect(repairs == ChatModeStore.HostRepairs(rewrites: [], deletes: ["w1:p1"]))
        #expect(store.marker(for: id) == nil)
        #expect(store.marker(for: .init(hostID: hostID, paneID: "w1:p2")) != nil)
        #expect(!store.isChatMode(consoleAgent("w1:p1", hostID: hostID)))

        let reloaded = ChatModeStore(defaults: defaults, now: { self.start })
        #expect(reloaded.replaceMarkers([hostCopy], for: hostID).deletes == ["w1:p1"])
        #expect(reloaded.marker(for: id) == nil)

        // The Host no longer lists it: the delete landed, nothing is retried.
        #expect(reloaded.replaceMarkers([], for: hostID) == ChatModeStore.HostRepairs())
    }

    @Test func aLaterLaunchOnARetiredPaneIsAdopted() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ChatModeStore(defaults: defaults, now: { self.start })
        let id = ConsoleAgent.ID(hostID: hostID, paneID: "w1:p1")
        store.replaceMarkers([marker("w1:p1")], for: hostID)
        store.retire(id)

        // Another device launched a chat in the pane since.
        let later = marker("w1:p1", launchedAt: start.addingTimeInterval(60))
        #expect(store.replaceMarkers([later], for: hostID) == ChatModeStore.HostRepairs())
        #expect(store.marker(for: id) == later)

        // A launch on this device ends the tombstone at once, even before
        // the Host lists its marker over the retired one.
        store.retire(id)
        let relaunch = marker("w1:p1", launchedAt: start.addingTimeInterval(120))
        store.record(relaunch, hostID: hostID)
        #expect(
            store.replaceMarkers([later], for: hostID)
                == ChatModeStore.HostRepairs(rewrites: [relaunch], deletes: []))
        #expect(store.marker(for: id) == relaunch)
    }

    private func agent(
        _ paneID: String, terminalID: String, session: String?
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID, hostName: "devbox",
            agent: Agent(
                terminalID: terminalID, kind: "claude", title: "Task", status: .working,
                workspaceID: "w1", tabID: "w1:t1", paneID: paneID, cwd: "/work/proj", revision: 1,
                agentSession: session.map {
                    AgentSessionInfo(agent: "claude", kind: .id, source: "herdr:claude", value: $0)
                }),
            workspaceLabel: nil, repositoryCheckout: nil)
    }

    private func marker(
        _ paneID: String, terminalID: String?, session: String?
    ) -> ChatModeMarker {
        ChatModeMarker(
            paneID: paneID, terminalID: terminalID, kind: "claude", cwd: "/work/proj",
            session: session.map { .init(kind: "id", value: $0) }, launchedAt: start)
    }

    @Test func followRebindsTheTerminalAndSessionOfARestoredChat() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let later = start.addingTimeInterval(30)
        let store = ChatModeStore(defaults: defaults, now: { later })
        let id = ConsoleAgent.ID(hostID: hostID, paneID: "w1:p1")
        store.replaceMarkers([marker("w1:p1", terminalID: "term_old", session: "s-1")], for: hostID)
        let revision = store.revision

        let followed = store.follow(agent("w1:p1", terminalID: "term_new", session: "s-1"))
        let expected = marker("w1:p1", terminalID: "term_new", session: "s-1")
        #expect(followed == expected)
        #expect(store.marker(for: id) == expected)
        #expect(store.revision == revision + 1)
        // Recorded as this device's change: the Host lacking it gets it again.
        #expect(store.replaceMarkers([], for: hostID).rewrites == [expected])
        // Persisted.
        #expect(ChatModeStore(defaults: defaults, now: { later }).marker(for: id) == expected)
    }

    @Test func followRecordsTheLiveSessionOfTheSameTerminal() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ChatModeStore(defaults: defaults, now: { self.start })
        store.replaceMarkers([marker("w1:p1", terminalID: "term_a", session: nil)], for: hostID)

        #expect(
            store.follow(agent("w1:p1", terminalID: "term_a", session: "s-1"))
                == marker("w1:p1", terminalID: "term_a", session: "s-1"))
        // Already held: nothing to write again.
        #expect(store.follow(agent("w1:p1", terminalID: "term_a", session: "s-1")) == nil)
        // An Agent reporting no session keeps the marker's.
        #expect(store.follow(agent("w1:p1", terminalID: "term_a", session: nil)) == nil)
        #expect(
            store.marker(for: .init(hostID: hostID, paneID: "w1:p1"))
                == marker("w1:p1", terminalID: "term_a", session: "s-1"))
    }

    @Test func followReturnsNilWhenTheMarkerDoesNotApply() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ChatModeStore(defaults: defaults, now: { self.start })
        let held = marker("w1:p1", terminalID: "term_a", session: "s-1")
        store.replaceMarkers([held], for: hostID)
        let revision = store.revision

        #expect(store.follow(agent("w1:p1", terminalID: "term_b", session: "s-2")) == nil)
        #expect(store.follow(agent("w1:p1", terminalID: "term_b", session: nil)) == nil)
        #expect(store.follow(agent("w1:p2", terminalID: "term_a", session: "s-1")) == nil)
        #expect(store.follow(agent("w1:p1", terminalID: "term_a", session: "s-1")) == nil)
        #expect(store.marker(for: .init(hostID: hostID, paneID: "w1:p1")) == held)
        #expect(store.revision == revision)
    }

    @Test func followKeepsANilTerminalNil() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = ChatModeStore(defaults: defaults, now: { self.start })
        store.replaceMarkers([marker("w1:p1", terminalID: nil, session: nil)], for: hostID)

        #expect(store.follow(agent("w1:p1", terminalID: "term_a", session: nil)) == nil)
        #expect(
            store.follow(agent("w1:p1", terminalID: "term_a", session: "s-1"))
                == marker("w1:p1", terminalID: nil, session: "s-1"))
    }

    /// A rebind this device just made survives a Host copy still naming the
    /// old terminal, and is written again.
    @Test func aLocalRebindSurvivesAStaleHostCopyInsideTheGrace() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        var clock = start
        let store = ChatModeStore(defaults: defaults, now: { clock })
        let id = ConsoleAgent.ID(hostID: hostID, paneID: "w1:p1")
        let stale = marker("w1:p1", terminalID: "term_old", session: "s-1")
        store.replaceMarkers([stale], for: hostID)
        let rebound = try #require(store.follow(agent("w1:p1", terminalID: "term_new", session: "s-1")))

        clock = start.addingTimeInterval(60)
        #expect(
            store.replaceMarkers([stale], for: hostID)
                == ChatModeStore.HostRepairs(rewrites: [rebound], deletes: []))
        #expect(store.marker(for: id) == rebound)

        // The Host's copy carrying the new terminal supersedes it.
        #expect(store.replaceMarkers([rebound], for: hostID) == ChatModeStore.HostRepairs())

        // Past the grace the Host's copy wins again.
        _ = store.follow(agent("w1:p1", terminalID: "term_newer", session: "s-1"))
        clock = start.addingTimeInterval(60 + ChatModeStore.localRecordGrace + 1)
        store.replaceMarkers([stale], for: hostID)
        #expect(store.marker(for: id) == stale)
    }
}
