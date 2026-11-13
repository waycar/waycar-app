import Foundation

extension ZellijTransport {
    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        try await launchAgent(request, workspace: nil)
    }

    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent {
        try await launchAgent(request, workspace: workspace)
    }

    private func launchAgent(_ request: AgentLaunchRequest, workspace: NewWorkspaceSpec?) async throws -> Agent {
        let tag = (request.launchID ?? UUID()).uuidString
        if request.mayHaveStarted, let found = try await findLaunch(tag: tag) {
            await nameLaunchTab(found, name: request.name)
            return launchedAgent(found, request: request)
        }
        let line = try await ZellijCommand.launchLine(request: request, tag: tag) {
            await self.codexSupportsNoDaemon()
        }
        let found = try await launch(
            tag: tag, name: request.name, cwd: workspace?.directory ?? request.cwd,
            workspaceID: workspace == nil ? request.workspaceID : nil,
            backgroundName: workspace?.label ?? request.name, line: line)
        return launchedAgent(found, request: request)
    }

    private func codexSupportsNoDaemon() async -> Bool {
        await AgentLaunchBuilder.codexSupportsNoDaemon(presence: await session.codexPresence) {
            let result = try await self.session.runExec(
                SSHTransportSettings.defaultCodexHelpCommand,
                input: Data(), timeout: self.configuration.requestTimeout)
            return try AgentLaunchBuilder.codexNoDaemonProbe(
                stdout: String(decoding: result.stdout, as: UTF8.self),
                stderr: String(decoding: result.stderr, as: UTF8.self), exitCode: Int(result.exitStatus))
        }
    }

    private func launchedAgent(_ found: ZellijLaunchReconciliation.Match, request: AgentLaunchRequest) -> Agent {
        // Do not wait for kind detection or the first-prompt readiness gate. The feed catches up.
        detectedAt[found.pane.description] = .now
        return Agent(
            terminalID: found.pane.terminalID(generation: generations[found.pane.session] ?? 0),
            kind: request.kind, title: found.record.title ?? "", status: .unknown,
            workspaceID: found.pane.workspaceID,
            tabID: ZellijPaneID.tab(session: found.pane.session, id: found.record.tabID),
            paneID: found.pane.description, cwd: found.record.paneCwd ?? request.cwd ?? "",
            revision: 0, name: request.name)
    }

    func createShellTerminal(_ request: ShellTerminalCreationRequest) async throws -> ShellTerminalIdentity {
        let result = try await startShellTerminal(ShellLaunchRequest(
            workspaceID: request.workspaceID, cwd: request.cwd))
        return ShellTerminalIdentity(paneID: result.paneID, tabID: result.tabID, terminalID: result.terminalID)
    }

    func startShellTerminal(_ request: ShellLaunchRequest) async throws -> ShellLaunchResult {
        try await launchShell(request, workspace: nil)
    }

    func startShellTerminalInNewWorkspace(
        _ request: ShellLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> ShellLaunchResult {
        try await launchShell(request, workspace: workspace)
    }

    private func launchShell(_ request: ShellLaunchRequest, workspace: NewWorkspaceSpec?) async throws -> ShellLaunchResult {
        let tag = (request.launchID ?? UUID()).uuidString
        let found: ZellijLaunchReconciliation.Match
        if request.mayHaveStarted, let earlier = try await findLaunch(tag: tag) {
            await nameLaunchTab(earlier, name: request.name ?? "Shell")
            found = earlier
        } else {
            found = try await launch(
                tag: tag, name: request.name ?? "Shell", cwd: workspace?.directory ?? request.cwd,
                workspaceID: workspace == nil ? request.workspaceID : nil,
                backgroundName: workspace?.label ?? request.name,
                line: ZellijCommand.shellLaunchLine(tag: tag))
        }
        return ShellLaunchResult(
            paneID: found.pane.description,
            tabID: ZellijPaneID.tab(session: found.pane.session, id: found.record.tabID),
            terminalID: found.pane.terminalID(generation: generations[found.pane.session] ?? 0),
            workspaceID: found.pane.workspaceID)
    }

    private func launch(
        tag: String, name: String, cwd: String?, workspaceID: String?, backgroundName: String?, line: String
    ) async throws -> ZellijLaunchReconciliation.Match {
        try ensureOpen()
        let target: ZellijSessionRecord?
        if let workspaceID {
            guard let found = frame.sessions.first(where: {
                !$0.closed && ZellijPaneID.workspace(session: $0.name) == workspaceID
            }) else { throw HerdrAPIError(code: "workspace_not_found", message: "No Zellij session for this Workspace") }
            target = found
        } else { target = nil }
        let directory: String
        if let chosen = cwd ?? target.flatMap({ frame.panes[$0.name]?.first(where: \.isVisible)?.paneCwd }) {
            directory = chosen
        } else { directory = try await remoteHomeDirectory() }
        if let target {
            LaunchProgress.report(.creatingTab)
            // Check and create on one exec; an empty-success tab id is not evidence of a pane.
            let creation = try await exec(commands.newTabIfAttached(
                session: target.name, name: name, cwd: directory, line: line))
            if creation.hasPrefix("waycar-zellij-client\n"),
                let confirmed = try await confirmLaunch(tag: tag, sessionName: target.name) { return confirmed }
        }
        LaunchProgress.report(.creatingWorkspace)
        let listing = try await exec(commands.listSessions(namesOnly: true), allowsNoSessions: true)
        let base = backgroundName.flatMap { $0.isEmpty ? nil : $0 }
            ?? directory.split(separator: "/").last.map(String.init) ?? "agent"
        let unique = ZellijCommand.uniqueSessionName(base, listing: listing)
        let command = commands.backgroundSession(name: unique, cwd: directory, line: line)
        let start = Self.backgroundStart(command: command, inLoginSession: configuration.wakesInLoginSession)
        try await exec(start.command, input: start.input)
        guard let confirmed = try await confirmLaunch(tag: tag, sessionName: unique) else {
            // Creation may have reached the Host. Let the existing uncertain-launch path reconcile it.
            throw TransportError.timedOut
        }
        await nameLaunchTab(confirmed, name: name)
        return confirmed
    }

    /// A background session's only tab gets Zellij's default name, and a lone pane's Agent
    /// is named by its tab (`ZellijSnapshotBuilder`), so name the tab after the launch. A
    /// failed rename leaves the launch running under the default name.
    private func nameLaunchTab(_ found: ZellijLaunchReconciliation.Match, name: String) async {
        guard !name.isEmpty, found.record.tabName != name else { return }
        _ = try? await exec(commands.renameTab(
            session: found.pane.session, tabID: found.record.tabID, name: name))
    }

    static func backgroundStart(command: String, inLoginSession: Bool) -> HostServerStartExec {
        guard inLoginSession else { return HostServerStartExec(command: command, input: Data()) }
        let script = HerdrHostPath.pathExport + "; "
            + HostLoginSessionStart.script(variables: ["SHELL=\"$SHELL\""], ready: "true") + command + " < /dev/null"
        return HostServerStartExec(
            command: "/bin/sh -c " + ShellWord.quoted(script),
            input: Data(HostLoginSessionStart.job(command: command).utf8))
    }

    private func confirmLaunch(tag: String, sessionName: String) async throws -> ZellijLaunchReconciliation.Match? {
        let deadline = ContinuousClock.now + configuration.launchConfirmationTimeout
        repeat {
            let output = try await exec(commands.listPanes(session: sessionName))
            let rows = output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? [] : try JSONDecoder().decode([ZellijPaneRecord].self, from: Data(output.utf8))
            let fresh = ZellijFrame(sessions: [.init(name: sessionName, closed: false)], panes: [sessionName: rows])
            if let found = ZellijLaunchReconciliation.find(tag: tag, frame: fresh) { return found }
            if ContinuousClock.now >= deadline { return nil }
            try await Task.sleep(for: .milliseconds(100))
        } while true
    }

    /// An uncertain launch must ask the Host, not the feed's last (possibly pre-launch) frame.
    private func findLaunch(tag: String) async throws -> ZellijLaunchReconciliation.Match? {
        let listing = try await exec(commands.listSessions(), allowsNoSessions: true)
        for session in ZellijSessionRecord.listing(listing) where !session.closed {
            let output = try await exec(commands.listPanes(session: session.name))
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let rows = try JSONDecoder().decode([ZellijPaneRecord].self, from: Data(output.utf8))
            let fresh = ZellijFrame(sessions: [session], panes: [session.name: rows])
            if let found = ZellijLaunchReconciliation.find(tag: tag, frame: fresh) { return found }
        }
        return nil
    }
}
