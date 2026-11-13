import Foundation

/// The raw ids `new-window` / `new-session -P -F` printed for a launch.
struct TmuxLaunchedPane: Sendable, Equatable {
    let paneID: String
    let windowID: String
    let sessionID: String
}

extension TmuxTransport {
    /// Every window Waycar creates carries it (ADR 0018), agent windows too,
    /// so rc files can skip agent auto-launch hooks.
    static let windowEnvironment = ["WAYCAR_SHELL": "1"]

    static var launchPrintFormat: String {
        TmuxInventory.fields(["pane_id", "window_id", "session_id"])
    }

    // MARK: Agents

    /// A new background window in the Workspace's session running the agent
    /// through the user's login shell (T22), which leaves a login shell when
    /// the agent exits.
    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        let sessionID = try Self.launchSession(request.workspaceID)
        if let earlier = try await earlierAgentLaunch(request, workspaceID: request.workspaceID) {
            return earlier
        }
        let agentCommand = try await agentCommandLine(request)
        LaunchProgress.report(.creatingTab)
        let created = try await newWindow(
            sessionID: sessionID, cwd: request.cwd, name: Self.nonEmpty(request.name),
            command: TmuxCommand.loginShellWrapper(agentCommand: agentCommand),
            launchID: request.launchID)
        LaunchProgress.report(.startingAgent)
        _ = launchGates.handle(.launched(pane: created.paneID, kind: request.kind, at: .now))
        return await startedAgent(created, request: request, cwd: request.cwd)
    }

    /// A new session at the directory, named by the label or the directory's
    /// last component, its first window running the agent.
    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent {
        if let earlier = try await earlierAgentLaunch(request, workspaceID: nil) { return earlier }
        let agentCommand = try await agentCommandLine(request)
        LaunchProgress.report(.creatingWorkspace)
        let created = try await newSession(
            label: workspace.label, directory: workspace.directory,
            command: TmuxCommand.loginShellWrapper(agentCommand: agentCommand),
            launchID: request.launchID)
        // new-session names the session, not its window: name the window
        // after the agent. Best-effort, a launch that started stays started.
        if let name = Self.nonEmpty(request.name) {
            _ = try? await run([TmuxCommand.renameWindow(target: created.windowID, name: name)])
        }
        LaunchProgress.report(.startingAgent)
        _ = launchGates.handle(.launched(pane: created.paneID, kind: request.kind, at: .now))
        return await startedAgent(created, request: request, cwd: workspace.directory)
    }

    /// The started Agent from a fresh snapshot when tmux already shows it,
    /// else a minimal Agent of the requested kind.
    private func startedAgent(
        _ created: TmuxLaunchedPane, request: AgentLaunchRequest, cwd: String?
    ) async -> Agent {
        let paneID = TmuxID.app(created.paneID)
        if let snapshot = try? await sessionSnapshot(),
            let info = snapshot.agents.first(where: { $0.paneID == paneID })
        {
            return Agent(info)
        }
        return Agent(
            terminalID: terminalID(forPane: created.paneID), kind: request.kind, title: "",
            status: .unknown,
            workspaceID: TmuxID.app(created.sessionID), tabID: TmuxID.app(created.windowID),
            paneID: paneID, cwd: cwd ?? "", revision: 0, name: Self.nonEmpty(request.name))
    }

    /// The command line herdr's `agent.start` would run, from the launch
    /// builder every program-starting backend shares
    /// (``AgentLaunchBuilder``): the request's environment rides an `env`
    /// prefix, so it reaches the agent alone: not the login shell left
    /// after it exits, nor (as `new-session -e` would) every later window
    /// of the session.
    func agentCommandLine(_ request: AgentLaunchRequest) async throws -> String {
        try await AgentLaunchBuilder.shellLine(
            for: request, codexSupportsNoDaemon: { await self.codexSupportsNoDaemon() })
    }

    /// Detection vouches for modern Codex even when SSH cannot find it.
    /// Only undetected installs need a probe; missing executables are uncached.
    func codexSupportsNoDaemon() async -> Bool {
        let session = self.session
        return await AgentLaunchBuilder.codexSupportsNoDaemon(presence: await session.codexPresence) { [self] in
            try await codexNoDaemon.value {
                let result = try await session.runExec(
                    Self.shellCommand(SSHTransportSettings.codexHelpScript, cLocale: true),
                    input: Data(), timeout: nil)
                return try AgentLaunchBuilder.codexNoDaemonProbe(
                    stdout: Self.text(result.stdout), stderr: Self.text(result.stderr), exitCode: Int(result.exitStatus))
            }
        }
    }

    // MARK: Shells

    func createShellTerminal(
        _ request: ShellTerminalCreationRequest
    ) async throws -> ShellTerminalIdentity {
        let created = try await newWindow(
            sessionID: try Self.rawSession(request.workspaceID), cwd: request.cwd, name: nil,
            command: nil)
        return ShellTerminalIdentity(
            paneID: TmuxID.app(created.paneID), tabID: TmuxID.app(created.windowID),
            terminalID: terminalID(forPane: created.paneID))
    }

    func startShellTerminal(_ request: ShellLaunchRequest) async throws -> ShellLaunchResult {
        let sessionID = try Self.launchSession(request.workspaceID)
        if let earlier = try await earlierShellLaunch(request, workspaceID: request.workspaceID) {
            return earlier
        }
        LaunchProgress.report(.openingShell)
        let created = try await newWindow(
            sessionID: sessionID, cwd: request.cwd, name: request.name.flatMap(Self.nonEmpty),
            command: nil, launchID: request.launchID)
        return shellResult(created)
    }

    func startShellTerminalInNewWorkspace(
        _ request: ShellLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> ShellLaunchResult {
        if let earlier = try await earlierShellLaunch(request, workspaceID: nil) { return earlier }
        LaunchProgress.report(.creatingWorkspace)
        let created = try await newSession(
            label: workspace.label, directory: workspace.directory, command: nil,
            launchID: request.launchID)
        LaunchProgress.report(.openingShell)
        if let name = request.name.flatMap(Self.nonEmpty) {
            _ = try? await run([TmuxCommand.renameWindow(target: created.windowID, name: name)])
        }
        return shellResult(created)
    }

    private func shellResult(_ created: TmuxLaunchedPane) -> ShellLaunchResult {
        ShellLaunchResult(
            paneID: TmuxID.app(created.paneID), tabID: TmuxID.app(created.windowID),
            terminalID: terminalID(forPane: created.paneID),
            workspaceID: TmuxID.app(created.sessionID))
    }

    /// A plain session `main` at the Host's home: the Console's Start
    /// Session on a Host whose tmux runs none (design §2 scenario 8). An
    /// idle transport's inventory is empty, so a second tap, or a replay of
    /// a start whose answer was lost, asks for the same name: tmux refusing
    /// it as a duplicate means the session exists, which is success, and
    /// control mode attaches to it.
    func startMainSession() async throws {
        let home = try await remoteHomeDirectory()
        let name = uniqueSessionName("main")
        do {
            _ = try await newSession(label: name, directory: home, command: nil)
        } catch let error as HerdrAPIError where Self.isDuplicateSession(error, name: name) {
            _ = try? await activeControl(recheckIdle: true)
        }
    }

    /// tmux's `duplicate session: <name>` refusal (3.2a through 3.7c, over
    /// control mode and the one-shot exec alike).
    static func isDuplicateSession(_ error: HerdrAPIError, name: String) -> Bool {
        error.message.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: .whitespaces) == "duplicate session: \(name)"
        }
    }

    // MARK: Launch reconciliation

    /// The Launch Tag belongs to the app, not the Status Hooks contract. It
    /// is read from a fresh snapshot only when a try may have reached tmux.
    func earlierAgentLaunch(
        _ request: AgentLaunchRequest, workspaceID: String?
    ) async throws -> Agent? {
        guard request.mayHaveStarted, let id = request.launchID else { return nil }
        _ = try await sessionSnapshot()
        guard let pane = records.panes.first(where: {
            $0.waycarLaunch == id.uuidString
                && (workspaceID == nil || TmuxID.app($0.sessionID) == workspaceID)
        }) else { return nil }
        // Creation runs the tag before the login shell. Detection may still
        // see that shell, or the Agent may have exited: neither permits a
        // second launch. Restore the same input gate as a fresh start.
        _ = launchGates.handle(.launched(pane: pane.id, kind: request.kind, at: .now))
        return await startedAgent(
            TmuxLaunchedPane(paneID: pane.id, windowID: pane.windowID, sessionID: pane.sessionID),
            request: request, cwd: pane.currentPath)
    }

    private func earlierShellLaunch(
        _ request: ShellLaunchRequest, workspaceID: String?
    ) async throws -> ShellLaunchResult? {
        guard request.mayHaveStarted, let id = request.launchID else { return nil }
        _ = try await sessionSnapshot()
        guard let pane = records.panes.first(where: {
            !$0.dead && $0.waycarLaunch == id.uuidString
                && (workspaceID == nil || TmuxID.app($0.sessionID) == workspaceID)
        }) else { return nil }
        return shellResult(TmuxLaunchedPane(
            paneID: pane.id, windowID: pane.windowID, sessionID: pane.sessionID))
    }

    /// Matching live panes in the last snapshot. Tags belong to this
    /// launch independently of Agent kind detection.
    func taggedLaunchPanes(_ id: UUID, workspaceID: String?) -> Set<String> {
        Set(records.panes.filter {
            !$0.dead && $0.waycarLaunch == id.uuidString
                && (workspaceID == nil || TmuxID.app($0.sessionID) == workspaceID)
        }.map { TmuxID.app($0.id) })
    }

    // MARK: tmux commands

    /// The raw session a launch into an existing Workspace targets.
    private static func launchSession(_ workspaceID: String?) throws -> String {
        guard let workspaceID else {
            throw TransportError.channelFailed(detail: "a tmux launch needs a workspace")
        }
        return try rawSession(workspaceID)
    }

    private func newWindow(
        sessionID: String, cwd: String?, name: String?, command: String?, launchID: UUID? = nil
    ) async throws -> TmuxLaunchedPane {
        let replies = try await run(
            [TmuxCommand.newWindow(
                sessionTarget: sessionID, cwd: cwd, name: name,
                environment: Self.windowEnvironment,
                command: TmuxCommand.taggedLaunchCommand(command, launchID: launchID),
                printFormat: Self.launchPrintFormat)],
            missing: "workspace_not_found")
        return try Self.launchedPane(replies[0].lines)
    }

    /// `new-session` over the control channel, or, with no session to anchor
    /// on, over one exec (`tmux start-server ; source-file -` reading the same
    /// command line), after which control mode attaches to it.
    func newSession(
        label: String?, directory: String, command: String?, launchID: UUID? = nil
    ) async throws -> TmuxLaunchedPane {
        let line = TmuxCommand.newSession(
            name: uniqueSessionName(label.flatMap(Self.nonEmpty) ?? Self.basename(directory)),
            cwd: directory, environment: Self.windowEnvironment,
            command: TmuxCommand.taggedLaunchCommand(command, launchID: launchID),
            printFormat: Self.launchPrintFormat)
        if let replies = try await runLine([line]) {
            return try Self.launchedPane(replies[0].lines)
        }
        let result = try await session.runExec(
            Self.oneShotCommand, input: Data((line + "\n").utf8), timeout: nil)
        let output = Self.text(result.stdout)
        guard result.exitStatus == 0 else {
            if result.exitStatus == 127 { throw TransportError.tmuxNotInstalled }
            throw TmuxErrors.error(Self.text(result.stderr) + "\n" + output)
        }
        let created = try Self.launchedPane(output.split(whereSeparator: \.isNewline).map(String.init))
        _ = try? await connect()
        return created
    }

    /// Runs the tmux command lines on stdin against the (possibly new)
    /// server. No `LC_ALL=C`: a server started here passes its environment
    /// to every pane.
    static var oneShotCommand: String {
        shellCommand("exec env -u TMUX tmux -u start-server \\; source-file -")
    }

    /// `%P␟@W␟$S` from a `-P -F` reply (its last such line).
    static func launchedPane(_ lines: [String]) throws -> TmuxLaunchedPane {
        for line in lines.reversed() {
            let fields = TmuxInventory.split(
                line.trimmingCharacters(in: .whitespaces), at: TmuxInventory.fieldSeparator)
            guard fields.count == 3, fields[0].first == "%", fields[1].first == "@",
                fields[2].first == "$"
            else { continue }
            return TmuxLaunchedPane(paneID: fields[0], windowID: fields[1], sessionID: fields[2])
        }
        throw TransportError.malformedResponse("tmux printed no new pane: \(lines)")
    }

    /// `label` as tmux stores it, or with `-2`, `-3`… when the last inventory
    /// has a session by that name (tmux refuses duplicates). tmux 3.2–3.6
    /// turn `.` and `:` in a session name into `_` (3.7 keeps them), so they
    /// are turned into `_` here: collisions are checked against the name tmux
    /// would hold, and every version gets the same name.
    func uniqueSessionName(_ label: String) -> String {
        let base = String(label.map { $0 == "." || $0 == ":" ? "_" : $0 })
        let taken = records.sessionNames
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    static func basename(_ directory: String) -> String {
        directory.split(separator: "/").last.map(String.init) ?? "main"
    }

    static func nonEmpty(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    // MARK: Attach and mosh

    /// A private grouped session showing the pane's window (design §4.4).
    /// `takeover` is ignored: tmux has no single attach owner.
    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        let command = try await attachExecCommand(for: request)
        return try await session.attachTerminal(command: command, request: request)
    }

    func attachExecCommand(for request: TerminalAttachRequest) async throws -> String {
        let target = try await attachTarget(request)
        return try TmuxAttachCommand.execCommand(
            target: target, attachSessionName: newAttachSessionName())
    }

    func runMoshBootstrap(_ request: TerminalAttachRequest) async throws -> MoshBootstrap {
        let target = try await attachTarget(request)
        let command = try Self.moshAttachCommand(
            target: target, attachSessionName: newAttachSessionName())
        return try await session.runMoshBootstrap(attachCommand: command, request: request)
    }

    func attachTarget(_ request: TerminalAttachRequest) async throws -> TmuxAttachCommand.Target {
        let pane = try Self.rawPane(request.target.identifier)
        let location = try await paneLocation(pane)
        return TmuxAttachCommand.Target(
            sessionID: location.sessionID, windowID: location.windowID, paneID: pane)
    }

    func newAttachSessionName() -> String {
        madeAttachSessions = true
        return TmuxAttachCommand.makeAttachSessionName()
    }

    /// The attach chain as the shell command mosh-server's PTY runs:
    /// `HostSSHServices.runMoshBootstrap` puts it inside a single-quoted
    /// `/bin/sh -c` script, which refuses `'` and `\`, so the chain's
    /// separators are written `";"` and each `$` as `"$"` (so `$1` reaches
    /// tmux as text). The script's own PATH fix-up and locale apply.
    static func moshAttachCommand(
        target: TmuxAttachCommand.Target, attachSessionName: String
    ) throws -> String {
        try TmuxAttachCommand.chainArguments(target: target, attachSessionName: attachSessionName)
            .map { argument in
                argument == ";" ? "\";\"" : argument.replacingOccurrences(of: "$", with: "\"$\"")
            }
            .joined(separator: " ")
    }
}
