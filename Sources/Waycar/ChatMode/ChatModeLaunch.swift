import Foundation

extension SupportedAgentKind {
    /// Whether New Agent offers Chat Mode for this kind: only the harnesses
    /// whose transcripts the plugin's reader understands. Cursor, Devin and
    /// Kiro have no reader: their transcript formats are unsourced (they
    /// need an account to capture).
    var supportsChatMode: Bool {
        switch self {
        case .claude, .codex, .omp, .pi, .opencode, .copilot, .qwen, .gemini, .grok, .antigravity,
            .hermes, .kilo, .cline, .muse:
            true
        default: false
        }
    }
}

/// What a Chat Mode launch asks of the harness, read from Settings ›
/// Chat Mode at launch.
struct ChatModeLaunchOptions: Equatable, Sendable {
    /// Longest model sent at launch, in Characters.
    static let maxModelLength = 200

    /// The Chat Prompt, already normalized by `ChatModePrompt.launchText(from:)`.
    var prompt: String
    /// The model to start with, already normalized by `normalizedModel(_:)`;
    /// nil keeps the harness's own default.
    var model: String?
    /// Quick thinking: asks the harness for less reasoning.
    var quickThinking: Bool

    init(prompt: String, model: String? = nil, quickThinking: Bool = true) {
        self.prompt = prompt
        self.model = model
        self.quickThinking = quickThinking
    }

    /// Removes every whitespace, control and format character (herdr refuses
    /// newline/tab args; model ids never contain spaces or invisible
    /// characters), caps at 200 characters; nil when empty or when it starts
    /// with `-`, since a value that reads as a flag would be parsed as one.
    static func normalizedModel(_ text: String?) -> String? {
        guard let text else { return nil }
        var kept = String.UnicodeScalarView()
        kept.append(
            contentsOf: text.unicodeScalars.filter { scalar in
                let properties = scalar.properties
                return !properties.isWhitespace
                    && properties.generalCategory != .control && properties.generalCategory != .format
            })
        let capped = String(String(kept).prefix(maxModelLength))
        return capped.isEmpty || capped.hasPrefix("-") ? nil : capped
    }
}

/// The `agent.start` arguments that turn an Agent into a Chat Mode Agent.
/// They are prepended, before the user's Arguments field and any resume
/// arguments.
enum ChatModeLaunch {
    /// The harness flags that pick `options.model` and ask for low reasoning
    /// when `options.quickThinking` is on, then pin `sessionPin` where the
    /// harness accepts one. The Chat Prompt is not among them: it rides a
    /// Launch Prompt File, a flag or the pane's environment
    /// (`LaunchPromptStager`), or for OpenCode and Kilo the Chat Marker. A
    /// model or reasoning flag is left out when `userArguments` (the user's
    /// own, or a resume's) already set it, so they win. Kinds without Chat
    /// Mode get no arguments, and so does a harness's missing flag: Qwen,
    /// Gemini, OpenCode and Kilo have no reasoning flag for their TUI.
    static func arguments(
        kind: SupportedAgentKind, options: ChatModeLaunchOptions, sessionPin: UUID?,
        userArguments: [String] = []
    ) -> [String] {
        let pin = pinArguments(sessionPin)
        var arguments: [String] = []
        /// `model` after `flag`, unless the user's arguments name any of
        /// `userFlags`; then `effort` unless they name any of `effortFlags`.
        func add(
            model flag: String, unless userFlags: [String], effort: [String] = [],
            unlessEffort effortFlags: [String] = []
        ) {
            if let model = options.model, !names(userFlags, in: userArguments) {
                arguments += flag.hasSuffix("=") ? [flag + model] : [flag, model]
            }
            if !effort.isEmpty, options.quickThinking, !names(effortFlags, in: userArguments) {
                arguments += effort
            }
        }
        switch kind {
        case .claude:
            add(model: "--model", unless: ["--model"], effort: ["--effort", "low"], unlessEffort: ["--effort"])
            return arguments + pin
        case .codex:
            // A profile can set either, so it wins over both.
            let profile = setsCodexProfile(userArguments)
            let overrides = codexConfigValues(in: userArguments)
            // A local or other provider brings its own default model, which
            // ours would replace.
            let userModel =
                profile || userArguments.contains { $0.hasPrefix("-m") }
                || names(["--model", "--oss", "--local-provider"], in: userArguments)
                || overrides.contains { $0.hasPrefix("model=") || $0.hasPrefix("model_provider=") }
            if let model = options.model, !userModel {
                arguments += ["-m", model]
            }
            let userEffort =
                profile || overrides.contains(where: { $0.hasPrefix("model_reasoning_effort=") })
            if options.quickThinking, !userEffort {
                arguments += ["-c", #"model_reasoning_effort="low""#]
            }
            return arguments
        case .omp:
            // A model meant for the default provider breaks under another one.
            add(
                model: "--model=", unless: ["--model", "--provider"], effort: ["--thinking=low"],
                unlessEffort: ["--thinking"])
            return arguments
        case .pi:
            let model = names(["--model", "--provider"], in: userArguments) ? nil : options.model
            if let model {
                arguments += ["--model", model]
            }
            // pi reads `model:level` as a model and its thinking level, so
            // such a model already says how hard to think. pi starts on the
            // `--model` passed (ours or the user's); only without one does it
            // start on a `--models` entry, possibly the saved default.
            let pairs = Array(zip(userArguments, userArguments.dropFirst()))
            let userModel = pairs.last { $0.0 == "--model" }?.1
            let scoped = pairs.last { $0.0 == "--models" }.map {
                $0.1.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } ?? []
            let startModels = (model ?? userModel).map { [$0] } ?? scoped
            let modelThinks = !startModels.isEmpty && startModels.allSatisfy(piModelSetsThinking)
            if options.quickThinking, !modelThinks, !names(["--thinking"], in: userArguments) {
                arguments += ["--thinking", "low"]
            }
            return arguments + pin
        case .opencode, .kilo:
            // The Chat Prompt does not ride the launch: neither has a
            // system-prompt flag, so the plugin's `waycar-chat-prompt`
            // extension appends it from the Chat Marker's `prompt` field.
            // Quick thinking is ignored: their TUIs have no reasoning-effort
            // flag (`--variant` exists only on `run`; kilo.md §8).
            add(model: "-m", unless: ["-m", "--model"])
            return arguments
        case .copilot:
            add(
                model: "--model", unless: ["--model"], effort: ["--reasoning-effort", "low"],
                unlessEffort: ["--reasoning-effort"])
            return arguments + pin
        case .qwen:
            add(model: "-m", unless: ["-m", "--model"])
            return arguments + pin
        case .gemini:
            // Thinking is settings-only (gemini.md §8).
            add(model: "-m", unless: ["-m", "--model"])
            return arguments
        case .grok:
            // `--effort` is accepted; whether a custom model gets it on the
            // wire is unverified (grok.md §8).
            add(
                model: "-m", unless: ["-m", "--model"], effort: ["--effort", "low"],
                unlessEffort: ["--effort", "--reasoning-effort"])
            return arguments + pin
        case .antigravity:
            // A `<family>-<effort>` model id already names its effort, and
            // with `--effort` too agy silently falls back to its default
            // model in the TUI (agy.md §8): so the user's own `--effort`
            // gets our model's family, and our `--effort` never joins a
            // combined id.
            let userEffort = names(["--effort"], in: userArguments)
            if let model = options.model, !names(["--model"], in: userArguments) {
                arguments += ["--model", userEffort ? agyModelFamily(model) : model]
            }
            let model =
                names(["--model"], in: userArguments)
                ? value(of: "--model", in: userArguments) : options.model
            if options.quickThinking, !userEffort, !(model.map(agyModelNamesEffort) ?? false) {
                arguments += ["--effort", "low"]
            }
            return arguments
        case .hermes:
            // `chat`'s own flags: `LaunchPromptStager` launches `hermes chat`.
            add(
                model: "-m", unless: ["-m", "--model"], effort: ["--reasoning", "low"],
                unlessEffort: ["--reasoning"])
            return arguments
        case .cline:
            // A model meant for the default provider breaks under another one.
            add(
                model: "-m", unless: ["-m", "--model", "-P", "--provider"], effort: ["--thinking", "low"],
                unlessEffort: ["--thinking"])
            return arguments
        case .muse:
            // Root options also apply after `resume` (muse.md §5, §8); the
            // TUI has no session pin (§7).
            add(
                model: "--model", unless: ["--model"], effort: ["--reasoning-effort", "low"],
                unlessEffort: ["--reasoning-effort", "--effort"])
            return arguments
        default:
            return []
        }
    }

    /// Whether codex `arguments` pick a profile, as `--profile` or `-p`, or
    /// as a `-c profile=<name>` override. clap also takes a short flag's
    /// value attached (`-pfast`, `-p=fast`).
    static func setsCodexProfile(_ arguments: [String]) -> Bool {
        names(["--profile"], in: arguments) || arguments.contains { $0.hasPrefix("-p") }
            || codexConfigValues(in: arguments).contains { override in
                override.split(separator: "=", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespaces) == "profile"
            }
    }

    /// A fresh session id to pin at launch, Chat Mode or not, so the
    /// launch's marker names the session before (or, on herdr without its
    /// integration, instead of) the harness reporting it: a Closed Session
    /// then resumes exactly. Nil when the kind cannot be pinned (codex, omp,
    /// opencode, kilo, gemini, agy, hermes, cline), when the user's own
    /// arguments already pick, continue or fork a session, or when they
    /// open with a subcommand or positional, which the pin would precede.
    /// Resumes never call this: they never pin.
    static func sessionPin(
        kind: SupportedAgentKind, userArguments: [String], makeID: () -> UUID = UUID.init
    ) -> UUID? {
        let conflicting: [String]
        switch kind {
        case .claude:
            conflicting = ["--resume", "-r", "--continue", "-c", "--session-id", "--fork-session"]
        case .pi:
            conflicting = ["--session", "--session-id", "--continue", "-c", "--resume", "-r", "--fork", "--no-session"]
        case .copilot:
            conflicting = ["--resume", "-r", "--continue", "--session-id"]
        case .qwen:
            conflicting = ["--resume", "-r", "--continue", "-c", "--session-id", "--fork-session"]
        case .grok:
            conflicting = ["--resume", "-r", "--continue", "-c", "--session-id", "-s"]
        default:
            return nil
        }
        if let first = userArguments.first, !first.hasPrefix("-") { return nil }
        return names(conflicting, in: userArguments) ? nil : makeID()
    }

    /// The arguments that pin `pin` as the new session's id; every kind
    /// `sessionPin` pins takes `--session-id <uuid>`.
    static func pinArguments(_ pin: UUID?) -> [String] {
        pin.map { ["--session-id", $0.uuidString.lowercased()] } ?? []
    }

    /// The value `arguments` give `flag`, as the next argument or joined as
    /// `flag=value`; the last one wins.
    private static func value(of flag: String, in arguments: [String]) -> String? {
        var found: String?
        for (index, argument) in arguments.enumerated() {
            if argument == flag, index + 1 < arguments.count {
                found = arguments[index + 1]
            } else if argument.hasPrefix(flag + "=") {
                found = String(argument.dropFirst(flag.count + 1))
            }
        }
        return found
    }

    /// agy's effort levels (`agy --help`: `low|medium|high|xhigh|max`), which
    /// also end its combined model ids (`gemini-3.6-flash-high`; agy.md §8).
    private static let agyEffortLevels: Set<Substring> = ["low", "medium", "high", "xhigh", "max"]

    /// Whether an agy model id is a combined `<family>-<effort>` id.
    private static func agyModelNamesEffort(_ model: String) -> Bool {
        guard let dash = model.lastIndex(of: "-") else { return false }
        return agyEffortLevels.contains(model[model.index(after: dash)...])
    }

    /// An agy model id without its `-<effort>` suffix, if it has one.
    private static func agyModelFamily(_ model: String) -> String {
        guard agyModelNamesEffort(model), let dash = model.lastIndex(of: "-") else { return model }
        return String(model[..<dash])
    }

    /// Whether `arguments` set any of `flags`, alone or joined as `flag=value`.
    private static func names(_ flags: [String], in arguments: [String]) -> Bool {
        arguments.contains { argument in
            flags.contains { flag in argument == flag || argument.hasPrefix(flag + "=") }
        }
    }

    /// The `key=value` overrides codex's `-c`/`--config` set in `arguments`,
    /// whether given as the next argument, joined as `--config=key=value`, or
    /// attached as `-ckey=value` or `-c=key=value`.
    private static func codexConfigValues(in arguments: [String]) -> [String] {
        let separate = zip(arguments, arguments.dropFirst()).compactMap { flag, value in
            flag == "-c" || flag == "--config" ? value : nil
        }
        let joined = arguments.compactMap { argument -> String? in
            if argument.hasPrefix("--config=") { return String(argument.dropFirst("--config=".count)) }
            guard argument.hasPrefix("-c"), argument != "-c" else { return nil }
            let value = argument.dropFirst(2)
            return String(value.hasPrefix("=") ? value.dropFirst() : value)
        }
        return separate + joined
    }

    /// pi's thinking levels (`pi --help`, `--thinking <level>`).
    private static let piThinkingLevels: Set<Substring> = ["off", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// Whether pi reads `model` as `model:level`: only when the text after
    /// its last `:` is a thinking level, so `deepseek-r1:free` or `qwen3:8b`
    /// stay plain models.
    private static func piModelSetsThinking(_ model: String) -> Bool {
        guard let colon = model.lastIndex(of: ":") else { return false }
        return piThinkingLevels.contains(model[model.index(after: colon)...])
    }
}
