import Foundation

/// Starts a Closed Session again (CONTEXT.md **Closed Session**) through the
/// New Agent launch path (`StartAgentStore.submit`): a fresh tab in the
/// session's Workspace while the Host still reports it, else a new Workspace
/// opened at the session's directory, running the Agent with its resume
/// arguments (`ClosedSession.resumeArguments`). Either launches on the
/// backend the Agent ran on (`ClosedSession.backend`, ADR 0026). A chat
/// record resumes in Chat Mode: the Chat Mode arguments come first, and a
/// started resume writes its Chat Marker. A started session is held as a
/// pending resume (`ClosedSessionsStore.beginPendingResume`) until the user
/// uses or backs out of it; a failed one stays listed.
///
/// Kept off the SSH types like `StartAgentStore`: it talks to injected
/// closures, so it is testable against a scripted launch.
@MainActor
struct ClosedSessionResumer {
    enum Outcome: Equatable, Sendable {
        /// The resumed Agent's row, for the Console to open.
        case started(ConsoleAgent.ID)
        /// User-facing, in the New Agent flow's words.
        case failed(String)
    }

    struct Launch: Equatable {
        let request: AgentLaunchRequest
        let destination: StartAgentStore.LaunchDestination
    }

    let workspaces: (Host.ID) -> [ConsoleWorkspace]
    let existingAgentNames: (Host.ID) -> Set<String>
    let start: (AgentLaunchRequest, StartAgentStore.LaunchDestination, Host.ID, HostBackend)
        async throws -> Agent
    /// Bounded, like the New Agent flow's: the row the Console opens exists
    /// only once the post-start resync lands.
    let awaitAgentVisible: (ConsoleAgent.ID) async -> Void
    let beginPendingResume: (ClosedSession.ID, ConsoleAgent.ID, String) -> Void
    /// Told once a resume started, which counts as real use for the Review
    /// Prompt.
    let recordLaunch: () -> Void
    /// Records a Chat Mode resume's Chat Marker, locally and on the Host.
    let recordChatMode: (ChatModeMarker, Host.ID) async -> Void
    /// What a chat record of a kind resumes with: the normalized Chat
    /// Prompt, the kind's model and Quick thinking.
    let chatOptions: (SupportedAgentKind) -> ChatModeLaunchOptions
    /// Writes a Chat Mode resume's Chat Prompt to its Host as a Launch
    /// Prompt File (`ConsoleStore.launchPromptHost(for:)`).
    let launchPromptHost: (Host.ID) -> LaunchPromptHost?
    /// How failures name a Host.
    let hostName: (Host.ID) -> String
    /// Whether the Host's `opencode` is OpenCode 2, whose TUI has no `-m`
    /// (O12): a Chat Mode resume there leaves the model out.
    let runsOpenCode2: (Host.ID) -> Bool
    let now: () -> Date

    init(
        workspaces: @escaping (Host.ID) -> [ConsoleWorkspace],
        existingAgentNames: @escaping (Host.ID) -> Set<String>,
        start: @escaping (AgentLaunchRequest, StartAgentStore.LaunchDestination, Host.ID, HostBackend)
            async throws -> Agent,
        awaitAgentVisible: @escaping (ConsoleAgent.ID) async -> Void,
        beginPendingResume: @escaping (ClosedSession.ID, ConsoleAgent.ID, String) -> Void,
        recordLaunch: @escaping () -> Void = {},
        recordChatMode: @escaping (ChatModeMarker, Host.ID) async -> Void = { _, _ in },
        chatOptions: @escaping (SupportedAgentKind) -> ChatModeLaunchOptions = {
            ChatModeSettings.launchOptions(for: $0)
        },
        launchPromptHost: @escaping (Host.ID) -> LaunchPromptHost? = { _ in nil },
        hostName: @escaping (Host.ID) -> String = { _ in "the Host" },
        runsOpenCode2: @escaping (Host.ID) -> Bool = { _ in false },
        now: @escaping () -> Date = Date.init
    ) {
        self.workspaces = workspaces
        self.existingAgentNames = existingAgentNames
        self.start = start
        self.awaitAgentVisible = awaitAgentVisible
        self.beginPendingResume = beginPendingResume
        self.recordLaunch = recordLaunch
        self.recordChatMode = recordChatMode
        self.chatOptions = chatOptions
        self.launchPromptHost = launchPromptHost
        self.hostName = hostName
        self.runsOpenCode2 = runsOpenCode2
        self.now = now
    }

    init(console: ConsoleStore) {
        self.init(
            workspaces: { console.workspaces(for: $0) },
            existingAgentNames: { console.agentNames(on: $0) },
            start: { try await console.startAgent($0, at: $1, on: $2, backend: $3) },
            awaitAgentVisible: { await console.waitForAgent($0) },
            beginPendingResume: { console.closedSessions.beginPendingResume($0, agent: $1, terminal: $2) },
            recordLaunch: { console.reviewPrompt?.recordValueEvent() },
            recordChatMode: { await console.recordChatModeLaunch($0, hostID: $1) },
            launchPromptHost: { console.launchPromptHost(for: $0) },
            hostName: { console.catalog[$0]?.displayName ?? "the Host" },
            runsOpenCode2: { console.backendPresence(on: $0)?.opencode != nil })
    }

    func resume(_ session: ClosedSession) async -> Outcome {
        guard session.canResume else {
            let described = session.backend.serverChat?.sessionDescription ?? "session"
            return .failed("This \(described) has no session id to resume.")
        }
        if let server = session.backend.serverChat, let reference = session.session {
            do {
                let agent = try await start(
                    server.resumeRequest(
                        sessionID: reference.value,
                        name: Self.agentName(for: session, taken: existingAgentNames(session.hostID)),
                        cwd: session.cwd, launchID: UUID()),
                    .newWorkspace(NewWorkspaceSpec(directory: session.cwd, label: nil)),
                    session.hostID, server.backend)
                let id = ConsoleAgent.ID(hostID: session.hostID, paneID: agent.paneID)
                recordLaunch()
                // Native threads have no disposable pane to close on Back.
                // Their existing record stays hidden while the thread lists.
                await awaitAgentVisible(id)
                return .started(id)
            } catch {
                return .failed(StartAgentStore.message(for: error, launchedKind: server.agentKind))
            }
        }
        let chatMode = Self.resumesInChatMode(session)
        // The Chat Mode options, read once: the launch arguments and the
        // marker's `prompt` field use them.
        var chatOptionsForSession = chatMode ? chatOptions(session.kind) : nil
        if session.kind == .opencode, runsOpenCode2(session.hostID) { chatOptionsForSession?.model = nil }
        // Where it would land, checked before writing anything to the Host.
        let nowhere = Outcome.failed(
            "The session's Workspace is gone and its directory is unknown, "
                + "so there is nowhere to resume it.")
        guard
            Self.launch(
                for: session, workspaces: workspaces(session.hostID),
                takenNames: existingAgentNames(session.hostID),
                command: AgentLaunchCommand(arguments: [])) != nil
        else { return nowhere }
        do {
            // The Chat Prompt goes to the Host as a file before anything
            // opens a tab, so a failed write leaves nothing half-started.
            let command = try await Self.launchCommand(
                for: session, chatOptions: chatOptionsForSession,
                host: launchPromptHost(session.hostID), hostName: hostName(session.hostID))
            // Planned again after the write: the Host's Workspaces and
            // Agent names may have changed meanwhile.
            guard
                let launch = Self.launch(
                    for: session, workspaces: workspaces(session.hostID),
                    takenNames: existingAgentNames(session.hostID), command: command)
            else { return nowhere }
            let launchedAt = now()
            let agent = try await start(
                launch.request, launch.destination, session.hostID, session.backend)
            let startedID = ConsoleAgent.ID(hostID: session.hostID, paneID: agent.paneID)
            recordLaunch()
            beginPendingResume(session.id, startedID, agent.terminalID)
            // A Chat Mode resume marks its pane as a chat; a plain one that
            // resumes a known session records it, so closing it again keeps
            // the exact resume where herdr reports no session.
            let resumedSession = session.session.map {
                ChatModeMarker.Session(kind: $0.kind.rawValue, value: $0.value)
            }
            if chatMode || resumedSession != nil {
                await recordChatMode(
                    ChatModeMarker(
                        paneID: agent.paneID, terminalID: agent.terminalID,
                        kind: session.kind.rawValue, cwd: session.cwd,
                        session: resumedSession,
                        prompt: chatOptionsForSession?.prompt,
                        chatMode: chatMode,
                        launchedAt: launchedAt),
                    session.hostID)
            }
            await awaitAgentVisible(startedID)
            return .started(startedID)
        } catch {
            return .failed(StartAgentStore.message(for: error, launchedKind: session.kind))
        }
    }

    /// Whether `session` resumes in Chat Mode: it ran in Chat Mode and this
    /// build still offers Chat Mode for its kind.
    static func resumesInChatMode(_ session: ClosedSession) -> Bool {
        session.chatMode && session.kind.supportsChatMode
    }

    /// The launch that resumes `session`: its resume arguments, after the
    /// Chat Mode ones for a Chat Mode resume (`chatOptions`, nil otherwise),
    /// whose Chat Prompt `host` writes as a Launch Prompt File first, plus
    /// any pane variables its Chat Prompt route sets. The Chat Mode flags
    /// leave out a model or reasoning flag the resume arguments already set.
    /// Resumes never pin a session id and never carry a first message: a
    /// harness whose Chat Prompt only rides inline takes it when it fits,
    /// and otherwise resumes without it, its transcript already holding it.
    static func launchCommand(
        for session: ClosedSession, chatOptions: ChatModeLaunchOptions?,
        host: LaunchPromptHost?, hostName: String
    ) async throws -> AgentLaunchCommand {
        try await LaunchPromptStager.launchCommand(
            kind: session.kind, chatOptions: resumesInChatMode(session) ? chatOptions : nil,
            sessionPin: nil, userArguments: session.resumeArguments, initialPrompt: nil,
            host: host, hostName: hostName, backend: session.backend, isResume: true)
    }

    /// The launch that resumes `session` with `command`: in its Workspace
    /// while `workspaces` (the Host's current ones) still has it on the
    /// session's backend, else in a new Workspace at its directory, which
    /// herdr refuses if the directory is gone (a removed worktree's). Nil
    /// when neither is possible.
    static func launch(
        for session: ClosedSession, workspaces: [ConsoleWorkspace], takenNames: Set<String>,
        command: AgentLaunchCommand
    ) -> Launch? {
        let cwd = session.cwd.hasPrefix("/") ? session.cwd : nil
        let name = agentName(for: session, taken: takenNames)
        if let workspaceID = session.workspaceID,
            workspaces.contains(where: { $0.id == workspaceID && $0.backend == session.backend })
        {
            return Launch(
                request: AgentLaunchRequest(
                    kind: session.kind.rawValue, name: name, arguments: command.arguments,
                    workspaceID: workspaceID, cwd: cwd, environment: command.environment),
                destination: .existingWorkspace)
        }
        guard let cwd else { return nil }
        return Launch(
            request: AgentLaunchRequest(
                kind: session.kind.rawValue, name: name, arguments: command.arguments,
                environment: command.environment),
            destination: .newWorkspace(
                NewWorkspaceSpec(directory: cwd, label: session.workspaceLabel)))
    }

    /// The Agent's recorded name while herdr would take it and no live Agent
    /// on the Host has it; else the New Agent flow's generated default.
    static func agentName(for session: ClosedSession, taken: Set<String>) -> String {
        if let name = session.agentName, AgentName.validationError(name) == nil,
            !taken.contains(name)
        {
            return name
        }
        return StartAgentStore.defaultAgentName(for: session.kind, taken: taken)
    }
}
