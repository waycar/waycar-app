import Foundation

/// Why a launch carrying Launch Prompt Files could not start.
enum LaunchPromptError: Error, Equatable, Sendable {
    /// Waycar couldn't write the launch's prompt files on the Host shown as
    /// `hostName`; `chatPrompt` says whether one of them was the Chat Prompt
    /// (otherwise it was only the first message). The launch never goes out
    /// without its prompt.
    case stagingFailed(hostName: String, chatPrompt: Bool)
    /// Even with every prompt in a file, the line herdr would type is
    /// `bytes` long, over `LaunchPromptStager.typedLineBudget`.
    case launchLineTooLong(bytes: Int)
}

/// What a launch asks of the pane: the `agent.start` arguments after the
/// kind's executable, and the variables its pane starts with.
struct AgentLaunchCommand: Equatable, Sendable {
    let arguments: [String]
    let environment: [String: String]

    init(arguments: [String], environment: [String: String] = [:]) {
        self.arguments = arguments
        self.environment = environment
    }
}

/// What one launch writes to the Host and, once written, the arguments that
/// point the harness at those files instead of carrying the prompts inline
/// (`LaunchPromptStager`). Built by `LaunchPromptStager.plan`.
struct LaunchPromptPlan: Equatable, Sendable {
    /// How the Chat Prompt reaches the harness.
    enum ChatPromptRoute: Equatable, Sendable {
        /// No Chat Prompt rides the launch: not a Chat Mode launch;
        /// OpenCode or Kilo, whose prompt rides the Chat Marker; Cline,
        /// which has no per-launch append (cline.md §5); or a Grok resume,
        /// whose session keeps its rules (grok.md §5).
        case offTheLine
        /// `--append-system-prompt-file <path>`.
        case claudeFile
        /// `-p <profile>`, the profile holding `developer_instructions`.
        case codexProfile(String)
        /// `--append-system-prompt=<path>`.
        case ompFile
        /// `--append-system-prompt <path>`.
        case piFile
        /// `--include-directories <dir>`, the stage directory holding
        /// `GEMINI.md`, which Gemini CLI loads as project context.
        case geminiContextDirectory
        /// `--add-dir <dir>`, the stage directory holding `AGENTS.md`, which
        /// Antigravity appends to its rules (never `--agent`, which
        /// replaces the system prompt; agy.md §5).
        case agyRulesDirectory
        /// `COPILOT_CUSTOM_INSTRUCTIONS_DIRS=<dir>` in the pane, the stage
        /// directory holding `.github/instructions/waycar.instructions.md`.
        case copilotInstructionsDirectory
        /// `HERMES_EPHEMERAL_SYSTEM_PROMPT=<prompt>` in the pane: Hermes
        /// appends it at request time and never stores it, so a resume
        /// sets it again (hermes.md §5).
        case hermesEnvironment
        /// The inline flag when the line fits (claude or codex without a
        /// file route, Qwen's `--append-system-prompt`, Grok's `--rules`,
        /// Muse's `-c run.developer_prompt=…`), else a pointer in the first
        /// user message.
        case inlineOrFirstMessage
        /// Resuming with only an inline flag: the flag when the line fits,
        /// else no Chat Prompt at all. A resumed transcript already carries
        /// it, and a first message would start a turn nobody asked for.
        case inlineIfFits
    }

    /// A staged file the plan needs was not among those written; nil when
    /// the plan had no Chat Prompt file for its route.
    struct MissingStagedFile: Error, Equatable {
        let file: LaunchPromptFile?
    }

    let kind: SupportedAgentKind
    let route: ChatPromptRoute
    /// The Chat Prompt text, for the inline and environment routes; nil
    /// without a route.
    let chatPrompt: String?
    /// The kind's own leading arguments: a subcommand (`kiro-cli chat`,
    /// `hermes chat`) or Cline's local runtime (`-i --data-dir …`).
    let kindArguments: [String]
    /// `ChatModeLaunch.arguments`: model, reasoning and session flags.
    let chatFlags: [String]
    let userArguments: [String]
    /// The file holding the Chat Prompt, if it is staged.
    let chatPromptFile: LaunchPromptFile?
    /// The file holding the first user message, if the launch has one and
    /// the kind takes one.
    let initialPromptFile: LaunchPromptFile?
    /// Whether the line is typed into the pane (herdr) and so limited to
    /// `LaunchPromptStager.typedLineBudget`; tmux runs it as a command.
    let isTyped: Bool

    /// Only `LaunchPromptStager.plan` builds one, so a file route always
    /// comes with the Chat Prompt file it points at.
    fileprivate init(
        kind: SupportedAgentKind, route: ChatPromptRoute, chatPrompt: String?, kindArguments: [String],
        chatFlags: [String], userArguments: [String], chatPromptFile: LaunchPromptFile?,
        initialPromptFile: LaunchPromptFile?, isTyped: Bool
    ) {
        self.kind = kind
        self.route = route
        self.chatPrompt = chatPrompt
        self.kindArguments = kindArguments
        self.chatFlags = chatFlags
        self.userArguments = userArguments
        self.chatPromptFile = chatPromptFile
        self.initialPromptFile = initialPromptFile
        self.isTyped = isTyped
    }

    /// Everything to write before the launch; empty for a launch with no
    /// prompt on its line, which needs no Host round trip.
    var files: [LaunchPromptFile] { [chatPromptFile, initialPromptFile].compactMap { $0 } }

    /// The launch once `staged` (the written `files`) are on the Host: the
    /// kind's own arguments, the Chat Prompt route, the Chat Mode flags, the
    /// user's own arguments, and the first-message pointer last, plus the
    /// pane variables an environment route sets. A pointer's stage directory
    /// joins the workspace of a kind that reads only there without asking
    /// (`readableDirectoryFlag`).
    /// Throws `MissingStagedFile` when a needed file is absent or its path
    /// is not absolute and plain, and `LaunchPromptError.launchLineTooLong`
    /// when the typed line would still exceed the budget.
    func command(staged: [StagedLaunchPromptFile]) throws -> AgentLaunchCommand {
        let base = chatFlags + userArguments
        var environment: [String: String] = [:]
        let chatPath = try chatPromptFile.map { try path(of: $0, in: staged) }
        let initialPath = try initialPromptFile.map { try path(of: $0, in: staged) }
        let tail = initialPath.map { firstMessageArguments("Read and follow \($0)") } ?? []
        // The first-message file's directory, which the tail points into.
        let initialDirectory = try initialPath.map { try directory(of: $0, file: initialPromptFile) }
        var arguments: [String]
        switch route {
        case .offTheLine:
            arguments = base + tail
        case .claudeFile:
            arguments = ["--append-system-prompt-file", try required(chatPath)] + base + tail
        case .codexProfile(let profile):
            _ = try required(chatPath)
            arguments = ["-p", profile] + base + tail
        case .ompFile:
            arguments = ["--append-system-prompt=" + (try required(chatPath))] + base + tail
        case .piFile:
            arguments = ["--append-system-prompt", try required(chatPath)] + base + tail
        case .geminiContextDirectory:
            arguments = ["--include-directories", try stageDirectory(of: chatPath)] + base + tail
        case .agyRulesDirectory:
            arguments = ["--add-dir", try stageDirectory(of: chatPath)] + base + tail
        case .copilotInstructionsDirectory:
            environment[LaunchPromptStager.copilotInstructionsVariable] = try stageDirectory(of: chatPath)
            arguments = base + tail
        case .hermesEnvironment:
            environment[LaunchPromptStager.hermesPromptVariable] = chatPrompt
            arguments = base + tail
        case .inlineOrFirstMessage:
            let inline = kindArguments + readable(initialDirectory, inlineChatPromptArguments() + base + tail)
            if fits(inline) { return AgentLaunchCommand(arguments: inline) }
            var pointer = "Read and follow \(try required(chatPath)) as standing instructions for this session"
            if let initialPath { pointer += ", then read and follow \(initialPath)" }
            arguments = readable(try stageDirectory(of: chatPath), base + firstMessageArguments(pointer))
        case .inlineIfFits:
            let inline = kindArguments + inlineChatPromptArguments() + base
            return AgentLaunchCommand(arguments: fits(inline) ? inline : try checked(kindArguments + base))
        }
        arguments = readable(initialDirectory, arguments)
        // A line with no prompt file is as short as the user made it.
        let line = kindArguments + arguments
        return AgentLaunchCommand(
            arguments: files.isEmpty ? line : try checked(line), environment: environment)
    }

    /// `arguments` led by the kind's `readableDirectoryFlag` for
    /// `directory`, which a pointer on the line reads from, unless they
    /// already name it (Gemini's and Antigravity's Chat Prompt routes).
    private func readable(_ directory: String?, _ arguments: [String]) -> [String] {
        guard let directory, let flag = LaunchPromptStager.readableDirectoryFlag(kind: kind),
            !zip(arguments, arguments.dropFirst()).contains(where: { $0 == flag && $1 == directory })
        else { return arguments }
        return [flag, directory] + arguments
    }

    private func fits(_ arguments: [String]) -> Bool {
        !isTyped
            || LaunchPromptStager.typedLineBytes(executable: kind.executable, arguments: arguments)
                <= LaunchPromptStager.typedLineBudget
    }

    /// `arguments`, or `LaunchPromptError.launchLineTooLong` past the budget.
    private func checked(_ arguments: [String]) throws -> [String] {
        guard fits(arguments) else {
            throw LaunchPromptError.launchLineTooLong(
                bytes: LaunchPromptStager.typedLineBytes(executable: kind.executable, arguments: arguments))
        }
        return arguments
    }

    /// The kind's inline Chat Prompt flag: claude's and codex's for CLIs too
    /// old for a file route, and the only form Qwen (qwen.md §5), Grok
    /// (grok.md §5) and Muse (muse.md §5) take. Muse's `-c` value is a JSON
    /// string, which a TOML basic string's escapes also are.
    private func inlineChatPromptArguments() -> [String] {
        guard let chatPrompt else { return [] }
        switch kind {
        case .claude, .qwen: return ["--append-system-prompt", chatPrompt]
        case .codex: return ["-c", "developer_instructions=" + CodexProfileTOML.basicString(chatPrompt)]
        case .grok: return ["--rules", chatPrompt]
        case .muse: return ["-c", "run.developer_prompt=" + CodexProfileTOML.basicString(chatPrompt)]
        default: return []
        }
    }

    private func firstMessageArguments(_ pointer: String) -> [String] {
        LaunchPromptStager.firstMessageArguments(kind: kind, pointer: pointer) ?? []
    }

    /// Where `file` was written. A staged-directory path must be absolute
    /// and plain, since it is typed, joined into a flag, or read from a
    /// message; a codex profile is named, never pathed, on the line.
    private func path(of file: LaunchPromptFile, in staged: [StagedLaunchPromptFile]) throws -> String {
        guard let path = staged.first(where: { $0.file == file })?.path,
            file.destination == .codexProfile || LaunchPromptWriter.isPlainAbsolutePath(path)
        else { throw MissingStagedFile(file: file) }
        return path
    }

    /// The Chat Prompt file's path, which every file route has.
    private func required(_ path: String?) throws -> String {
        guard let path else { throw MissingStagedFile(file: chatPromptFile) }
        return path
    }

    /// The stage directory holding the Chat Prompt file written at `path`.
    private func stageDirectory(of path: String?) throws -> String {
        try directory(of: try required(path), file: chatPromptFile)
    }

    /// The stage directory holding `file`, written at `path`.
    private func directory(of path: String, file: LaunchPromptFile?) throws -> String {
        guard let file, path.hasSuffix("/" + file.name), path.count > file.name.count + 1 else {
            throw MissingStagedFile(file: file)
        }
        return String(path.dropLast(file.name.count + 1))
    }
}

/// Moves a launch's prompts (the Chat Prompt of every kind whose route is a
/// file, and any first user message) off the typed launch line into files on
/// the Host (CONTEXT.md **Launch Prompt File**). herdr types `<exe> <args>`
/// into a fresh pane, and a line over the tty's `MAX_CANON` (1024 bytes,
/// Enter included) loses its tail before the shell's line editor is up, so
/// the pane hangs on an open quote. tmux passes the command without typing,
/// so only herdr launches are held to the budget; both take the file routes.
enum LaunchPromptStager {
    /// Longest typed launch line allowed, Enter included: under `MAX_CANON`
    /// with room for whatever herdr adds. `typedLineBytes` assumes POSIX
    /// shell quoting; a PowerShell pane quotes more, which the 24-byte
    /// margin covers.
    static let typedLineBudget = 1000
    /// The staged Chat Prompt's file name.
    static let chatPromptFileName = "chat-prompt.md"
    /// The staged first user message's file name.
    static let initialPromptFileName = "first-message.md"
    /// The context file Gemini CLI loads from an `--include-directories`
    /// directory (gemini.md §5).
    static let geminiContextFileName = "GEMINI.md"
    /// The rules file Antigravity loads from an `--add-dir` directory
    /// (agy.md §5).
    static let agyRulesFileName = "AGENTS.md"
    /// Where Copilot reads instructions under a
    /// `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` directory; `AGENTS.md` or
    /// `copilot-instructions.md` there are not read (copilot.md §5).
    static let copilotInstructionsFileName = ".github/instructions/waycar.instructions.md"
    static let copilotInstructionsVariable = "COPILOT_CUSTOM_INSTRUCTIONS_DIRS"
    static let hermesPromptVariable = "HERMES_EPHEMERAL_SYSTEM_PROMPT"

    /// What a launch of `kind` writes and how it points at it. `chatOptions`
    /// is nil for a launch outside Chat Mode, which still takes
    /// `sessionPin`; `initialPrompt` is the first
    /// user message, if any. `capabilities` picks claude's and codex's file
    /// routes; `makeID` names a codex profile. A resume (`isResume`) takes
    /// no first message: without a file route its Chat Prompt rides inline
    /// when it fits and is otherwise left to the resumed transcript.
    /// `backend` says whether the line is typed (herdr) and so budgeted; tmux
    /// and herdr-core start the program as a command (`terminal.run`'s
    /// `argv`), never by typing a line;
    /// `home` is the Host's `$HOME`, which Cline's `--data-dir` needs.
    static func plan(
        kind: SupportedAgentKind, chatOptions: ChatModeLaunchOptions?, sessionPin: UUID?,
        userArguments: [String], initialPrompt: String?, capabilities: LaunchPromptCapabilities,
        backend: HostBackend = .herdr, home: String? = nil, isResume: Bool = false,
        makeID: () -> UUID = UUID.init
    ) -> LaunchPromptPlan {
        let firstMessage = isResume ? nil : initialPrompt.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
        let takesFirstMessage = firstMessageArguments(kind: kind, pointer: "") != nil
        let options = chatOptions
        let chatFlags =
            options.map {
                ChatModeLaunch.arguments(
                    kind: kind, options: $0, sessionPin: sessionPin, userArguments: userArguments)
            } ?? ChatModeLaunch.pinArguments(sessionPin)
        var route = LaunchPromptPlan.ChatPromptRoute.offTheLine
        var chatPromptFile: LaunchPromptFile?
        if let prompt = options?.prompt {
            // The stage file holding the prompt, when its route has one.
            var stageFileName: String?
            // Without a file route, the inline flag, else a first-message
            // pointer, which a resume cannot send. The pointer's file only
            // backs a typed (herdr) line over the budget.
            let inlineRoute: LaunchPromptPlan.ChatPromptRoute =
                isResume ? .inlineIfFits : .inlineOrFirstMessage
            let pointerFile = !isResume && backend == .herdr ? chatPromptFileName : nil
            switch kind {
            case .claude:
                if capabilities.claudeAppendSystemPromptFile {
                    route = .claudeFile
                    stageFileName = chatPromptFileName
                } else {
                    route = inlineRoute
                    stageFileName = pointerFile
                }
            case .codex:
                // codex takes one profile: the user's own leaves no room
                // for ours.
                if capabilities.codexProfileFile, !ChatModeLaunch.setsCodexProfile(userArguments) {
                    let profile = "waycar-" + makeID().uuidString.lowercased()
                    route = .codexProfile(profile)
                    chatPromptFile = LaunchPromptFile(
                        destination: .codexProfile, name: profile, contents: prompt)
                } else {
                    route = inlineRoute
                    stageFileName = pointerFile
                }
            case .omp:
                route = .ompFile
                stageFileName = chatPromptFileName
            case .pi:
                route = .piFile
                stageFileName = chatPromptFileName
            case .qwen, .muse:
                // Neither keeps the prompt in a resumed session, so a
                // resume passes it again (muse.md §5).
                route = inlineRoute
                stageFileName = pointerFile
            case .grok:
                // A resumed session keeps the rules it started with.
                route = isResume ? .offTheLine : .inlineOrFirstMessage
                stageFileName = pointerFile
            case .gemini:
                route = .geminiContextDirectory
                stageFileName = geminiContextFileName
            case .antigravity:
                route = .agyRulesDirectory
                stageFileName = agyRulesFileName
            case .copilot:
                route = .copilotInstructionsDirectory
                stageFileName = copilotInstructionsFileName
            case .hermes:
                route = .hermesEnvironment
            default:
                break
            }
            if let stageFileName {
                // Copilot reads only instructions files, which apply to
                // the files their front matter matches.
                let contents =
                    kind == .copilot ? "---\napplyTo: \"**\"\n---\n\n\(prompt)\n" : prompt
                chatPromptFile = LaunchPromptFile(
                    destination: .stageDirectory, name: stageFileName, contents: contents)
            }
        }
        let chatPrompt = route == .offTheLine ? nil : options?.prompt
        let initialPromptFile = firstMessage.flatMap { prompt in
            takesFirstMessage
                ? LaunchPromptFile(destination: .stageDirectory, name: initialPromptFileName, contents: prompt)
                : nil
        }
        return LaunchPromptPlan(
            kind: kind, route: route, chatPrompt: chatPrompt,
            kindArguments: kindArguments(kind: kind, userArguments: userArguments, home: home),
            chatFlags: chatFlags, userArguments: userArguments, chatPromptFile: chatPromptFile,
            initialPromptFile: initialPromptFile, isTyped: backend == .herdr)
    }

    /// The launch of `kind` on `host`: plans it, reads the Host's
    /// capabilities when claude's or codex's route depends on them and its
    /// `$HOME` when the kind's arguments need it, writes the files, and
    /// returns the arguments that point at them and the pane variables. A
    /// launch with no prompt on its line and no Host path in its arguments
    /// never touches the Host. A missing Host connection throws
    /// `TransportError.sshUnreachable`, and the link's own `TransportError`
    /// passes through unchanged; a write the Host refuses
    /// (`LaunchPromptStagingError`) throws `LaunchPromptError.stagingFailed`.
    /// Either way the launch never goes out silently without its prompt.
    /// Throws `.launchLineTooLong` past the budget of a typed (herdr) line.
    static func launchCommand(
        kind: SupportedAgentKind, chatOptions: ChatModeLaunchOptions?, sessionPin: UUID?,
        userArguments: [String], initialPrompt: String?, host: LaunchPromptHost?, hostName: String,
        backend: HostBackend = .herdr, isResume: Bool = false,
        makeID: @Sendable () -> UUID = { UUID() }
    ) async throws -> AgentLaunchCommand {
        func requiredHost() throws -> LaunchPromptHost {
            guard let host else {
                throw TransportError.sshUnreachable(detail: "The Host is not connected.")
            }
            return host
        }
        var home: String?
        if needsHome(kind: kind, userArguments: userArguments) {
            let value = try await requiredHost().homeDirectory()
            guard value.hasPrefix("/") else {
                throw TransportError.malformedResponse("The Host's home directory is not an absolute path.")
            }
            home = value
        }
        func plan(_ capabilities: LaunchPromptCapabilities) -> LaunchPromptPlan {
            Self.plan(
                kind: kind, chatOptions: chatOptions, sessionPin: sessionPin,
                userArguments: userArguments, initialPrompt: initialPrompt, capabilities: capabilities,
                backend: backend, home: home, isResume: isResume, makeID: makeID)
        }
        let bare = plan(.none)
        let readsCapabilities = bare.chatPrompt != nil && (kind == .claude || kind == .codex)
        guard !bare.files.isEmpty || readsCapabilities else { return try bare.command(staged: []) }
        let host = try requiredHost()
        var planned = bare
        if readsCapabilities { planned = plan(await host.capabilities()) }
        guard !planned.files.isEmpty else { return try planned.command(staged: []) }
        let failure = LaunchPromptError.stagingFailed(
            hostName: hostName, chatPrompt: planned.chatPromptFile != nil)
        let staged: [StagedLaunchPromptFile]
        do {
            staged = try await host.stage(planned.files)
        } catch is LaunchPromptStagingError {
            throw failure
        }
        do {
            return try planned.command(staged: staged)
        } catch is LaunchPromptPlan.MissingStagedFile {
            throw failure
        }
    }

    /// The bytes herdr types for `executable` and `arguments`, Enter
    /// included: each argument as `ShellWord.quoted` writes it, separated
    /// by spaces.
    static func typedLineBytes(executable: String, arguments: [String]) -> Int {
        arguments.reduce(executable.utf8.count + 1) { total, argument in
            total + 1 + ShellWord.quoted(argument).utf8.count
        }
    }

    /// `pointer` as `kind`'s first user message, after every flag; nil for
    /// a kind that takes none at launch. claude, codex and Devin take `--`
    /// as end of options; OpenCode and Kilo take `--prompt`; Qwen, Gemini
    /// and Antigravity `-i` (their bare positional is one-shot or
    /// undocumented); Hermes's `chat` takes `-q`; the rest a positional.
    /// Copilot takes none: after `copilot -i` every hook timed out and the
    /// process outlived its pane, blocking `--resume` (copilot.md §6, lab,
    /// copilot 1.0.96).
    static func firstMessageArguments(kind: SupportedAgentKind, pointer: String) -> [String]? {
        switch kind {
        case .claude, .codex, .devin: ["--", pointer]
        case .omp, .pi, .grok, .cline, .cursor, .kiro, .muse: [pointer]
        case .opencode, .kilo: ["--prompt", pointer]
        case .qwen, .gemini, .antigravity: ["-i", pointer]
        case .hermes: ["-q", pointer]
        default: nil
        }
    }

    /// The flag that adds a directory to `kind`'s workspace, so a pointer
    /// into the stage directory is read without asking; nil for a kind
    /// that needs none. Qwen (in its Ask-permissions mode) and Copilot stop
    /// on a path-permission dialog for a file outside the workspace, and
    /// read it at once with the flag (lab, qwen 0.25.1, copilot 1.0.95).
    /// Gemini CLI, Qwen's upstream, and Antigravity scope file tools to
    /// their workspace the same way; their Chat Prompt routes already pass
    /// the flag (gemini.md §5, agy.md §5).
    static func readableDirectoryFlag(kind: SupportedAgentKind) -> String? {
        switch kind {
        case .qwen, .gemini: "--include-directories"
        case .copilot, .antigravity: "--add-dir"
        default: nil
        }
    }

    /// The arguments every launch of `kind` starts with, unless the user's
    /// own arguments open with a subcommand or already set them:
    /// - Kiro's and Hermes's flags belong to their `chat` subcommand
    ///   (kiro.md recommends `kiro-cli chat`; `hermes chat` is plain
    ///   `hermes` with `-q`, `-m` and `--reasoning`, hermes.md §6, §8).
    /// - Cline runs `-i` (its TUI, which a positional first message needs)
    ///   with `--data-dir <home>/.cline/data`: an explicit data dir keeps
    ///   the session in the pane's own process instead of the shared hub,
    ///   whose hooks carry another pane's environment, while reading the
    ///   default data (cline.md §0, §13). `home` is absolute; Cline does
    ///   not expand `~`.
    static func kindArguments(kind: SupportedAgentKind, userArguments: [String], home: String?) -> [String] {
        if let first = userArguments.first, !first.hasPrefix("-") { return [] }
        switch kind {
        case .kiro, .hermes:
            return ["chat"]
        case .cline:
            var arguments = userArguments.contains { $0 == "-i" || $0 == "--tui" } ? [] : ["-i"]
            if let home, !setsClineDataDirectory(userArguments) {
                arguments += ["--data-dir", (home.hasSuffix("/") ? String(home.dropLast()) : home) + "/.cline/data"]
            }
            return arguments
        default:
            return []
        }
    }

    /// Whether `kindArguments` would need the Host's `$HOME`.
    static func needsHome(kind: SupportedAgentKind, userArguments: [String]) -> Bool {
        kind == .cline && !setsClineDataDirectory(userArguments)
            && !(userArguments.first.map { !$0.hasPrefix("-") } ?? false)
    }

    private static func setsClineDataDirectory(_ arguments: [String]) -> Bool {
        arguments.contains { $0 == "--data-dir" || $0.hasPrefix("--data-dir=") }
    }
}
