import Foundation

extension CoreTransport {
    // MARK: Starting an agent (design §9)

    /// A new terminal running the agent in the Workspace's folder, or in
    /// `request.cwd` when the launch names one (an origin launch, a Closed
    /// Session resume). A core Workspace is a folder, so there is no tab to
    /// create: the terminal appears in the Console through the event path.
    func startAgent(_ request: AgentLaunchRequest) async throws -> Agent {
        if let earlier = try await earlierLaunch(request) { return earlier }
        return try await launch(request, in: try launchFolder(for: request))
    }

    /// A launch into a folder no terminal is in yet. A core Workspace has
    /// no name of its own, so the spec's label is not used.
    func startAgentInNewWorkspace(
        _ request: AgentLaunchRequest, workspace: NewWorkspaceSpec
    ) async throws -> Agent {
        if let earlier = try await earlierLaunch(request) { return earlier }
        return try await launch(request, in: workspace.directory)
    }

    /// A fresh list, not the last event projection: the unanswered run may
    /// have reached core after this connection's initial inventory. The tag
    /// is ownership even before detection or after exit; never run it twice.
    private func earlierLaunch(_ request: AgentLaunchRequest) async throws -> Agent? {
        guard request.mayHaveStarted, let id = request.launchID else { return nil }
        let listed = try await call(
            "terminal.list", CoreParams.List(all: true), as: CoreParams.Listed.self)
        for terminal in listed.terminals
        where terminal.labels[CoreLaunch.launchLabel] == id.uuidString {
            _ = launchGate.handle(
                .launched(address: terminal.address, kind: request.kind, at: .now))
            return startedAgent(terminal, request: request, cwd: terminal.cwd)
        }
        return nil
    }

    /// The folder of a launch into an existing Workspace: the request's own
    /// when it has one, else the start folder of the Workspace's first
    /// terminal on this core.
    private func launchFolder(for request: AgentLaunchRequest) throws -> String {
        if let cwd = request.cwd, !cwd.isEmpty { return cwd }
        guard let workspaceID = request.workspaceID else {
            throw HerdrAPIError(
                code: "invalid_argument", message: "a launch on herdr-core needs a folder")
        }
        let terminals = CoreSnapshotBuilder.ordered(inventory?.terminals ?? [])
        for terminal in terminals
        where CoreSnapshotBuilder.machine(of: terminal.address) == nil
            && !terminal.isFinished && !terminal.cwd.isEmpty
            && CoreID.workspace(key: CoreSnapshotBuilder.workspaceKey(of: terminal)) == workspaceID
        {
            return terminal.cwd
        }
        throw HerdrAPIError(
            code: "workspace_not_found", message: "no folder is known for \(workspaceID)")
    }

    private func launch(_ request: AgentLaunchRequest, in folder: String) async throws -> Agent {
        // Everything that can fail before the terminal exists comes first:
        // a launch that cannot be built never reaches core.
        let argv = try await AgentLaunchBuilder.argv(
            for: request, codexSupportsNoDaemon: { await self.codexSupportsNoDaemon() })
        let environment = Dictionary(
            uniqueKeysWithValues: try AgentLaunchBuilder.environment(of: request).map {
                ($0.name, $0.value)
            })
        let path = try await currentLaunchPATH()
        let cwd = try await validatedFolder(folder, path: path)
        // One step: core has no tab to create before the program starts.
        LaunchProgress.report(.startingAgent)
        let record = try await run(
            request, argv: argv, cwd: cwd, environment: environment, path: path)
        _ = launchGate.handle(.launched(address: record.address, kind: request.kind, at: .now))
        return startedAgent(record, request: request, cwd: cwd)
    }

    /// `terminal.run`, once. A `spawn_failed` after the folder was checked
    /// means the program was not found on the PATH sent: the Host's login
    /// PATH is asked again (it may predate `~/.local/bin`, C22) and the
    /// launch retried once when that changes the PATH, since nothing was
    /// started. Still failing, the program is missing.
    private func run(
        _ request: AgentLaunchRequest, argv: [String], cwd: String,
        environment: [String: String], path: String
    ) async throws -> CoreTerminal {
        func attempt(with path: String) async throws -> CoreTerminal {
            var environment = environment
            if environment["PATH"] == nil { environment["PATH"] = path }
            return try await call(
                "terminal.run",
                CoreParams.Run(
                    argv: argv, cwd: cwd, env: environment,
                    labels: CoreLaunch.labels(
                        kind: request.kind, name: request.name, launchID: request.launchID)),
                as: CoreTerminal.self, subject: .pane)
        }
        do {
            return try await attempt(with: path)
        } catch let error as HerdrAPIError where error.code == "agent_start_failed" {
            let missing = HerdrAPIError(
                code: "agent_start_failed",
                message: CoreLaunch.notInstalledMessage(kind: request.kind))
            guard let refreshed = await refreshedLaunchPATH(), refreshed != path else {
                throw missing
            }
            do {
                return try await attempt(with: refreshed)
            } catch let retry as HerdrAPIError where retry.code == "agent_start_failed" {
                throw missing
            }
        }
    }

    /// The Agent a launch returns, from the run reply's record: the row the
    /// Console will show when the record names a recognized kind, else a
    /// minimal one of the requested kind. The terminal appears in the
    /// Console through its `created` event either way.
    private func startedAgent(
        _ record: CoreTerminal, request: AgentLaunchRequest, cwd: String
    ) -> Agent {
        let snapshot = CoreSnapshotBuilder.snapshot(
            terminals: [record], core: hello, overlay: overlay)
        if let info = snapshot.agents.first { return Agent(info) }
        let pane = snapshot.panes.first
        return Agent(
            terminalID: pane?.terminalID
                ?? CoreID.terminal(
                    corePrefix: CoreSnapshotBuilder.corePrefix(of: hello), address: record.address),
            kind: request.kind, title: "", status: .unknown,
            workspaceID: pane?.workspaceID
                ?? CoreID.workspace(key: CoreSnapshotBuilder.workspaceKey(of: record)),
            tabID: pane?.tabID ?? CoreID.tab(key: CoreSnapshotBuilder.tabKey(of: record)),
            paneID: CoreID.pane(record.address), cwd: cwd, revision: 0,
            name: request.name.isEmpty ? nil : request.name)
    }

    // MARK: Folder

    /// `folder` as an absolute path that exists on the Host: `~` expands
    /// from the Host's home, a relative folder is refused, and
    /// `machine.exec test -d` says whether it is a folder, because
    /// `terminal.run` blames the program for a bad folder (C6).
    private func validatedFolder(_ folder: String, path: String) async throws -> String {
        guard
            let absolute = try await CoreLaunch.absoluteFolder(
                folder, home: { try await self.remoteHomeDirectory() })
        else {
            throw HerdrAPIError(
                code: "invalid_argument",
                message: "The folder must be an absolute path, like /home/you/project.")
        }
        let result = try await call(
            "machine.exec",
            CoreParams.Exec(argv: ["test", "-d", absolute], env: ["PATH": path], timeout: 20),
            as: CoreParams.ExecResult.self, subject: .pane)
        guard result.code == 0, !result.timedOut else {
            throw HerdrAPIError(
                code: "folder_not_found",
                message: "\(absolute) is not a folder on this Host.")
        }
        return absolute
    }

    // MARK: PATH

    /// The PATH a launch sends as `env.PATH`, computed once per connection
    /// from the login PATH (`CoreLaunch.launchPathCommand`).
    private func currentLaunchPATH() async throws -> String {
        if let launchPATH { return launchPATH }
        return try await computeLaunchPATH(refresh: false)
    }

    /// The launch PATH after asking the Host for its login PATH again; nil
    /// when the Host cannot be asked.
    private func refreshedLaunchPATH() async -> String? {
        try? await computeLaunchPATH(refresh: true)
    }

    private func computeLaunchPATH(refresh: Bool) async throws -> String {
        let login = await resolveLoginPATH(refresh: refresh)
        let result = try await session.runExec(
            CoreLaunch.launchPathCommand(loginPATH: login), input: Data(),
            timeout: configuration.loginPathTimeout)
        guard result.exitStatus == 0,
            let path = CoreLaunch.parseLaunchPath(String(decoding: result.stdout, as: UTF8.self))
        else {
            throw TransportError.channelFailed(detail: "could not work out the Host's PATH")
        }
        launchPATH = path
        return path
    }

    /// Prefer detection; otherwise probe on core's launch PATH. A missing
    /// executable or failed exec is not cached as an unsupported capability.
    func codexSupportsNoDaemon() async -> Bool {
        await AgentLaunchBuilder.codexSupportsNoDaemon(presence: await session.codexPresence) { [self] in
            try await codexNoDaemon.value { [self] in
                let path = try await currentLaunchPATH()
                let result = try await call(
                    "machine.exec",
                    CoreParams.Exec(argv: ["codex", "--help"], env: ["PATH": path], timeout: 20),
                    as: CoreParams.ExecResult.self, subject: .pane)
                return try AgentLaunchBuilder.codexNoDaemonProbe(
                    stdout: result.stdout, stderr: result.stderr, exitCode: result.code)
            }
        }
    }

    // MARK: First prompt

    /// Throws `agent_not_ready` while the gate on a launch holds; terminals
    /// this transport did not launch are always ready. A program that has
    /// reported its status is ready (`CoreLaunch.readiness`); one that never
    /// does is read after `unreportedWait`, and let through only when its
    /// input is on screen (`CoreLaunch.screenDecision`).
    func checkLaunchReadiness(address: String, over client: CoreRPCClient) async throws {
        guard let gate = launchGate.gate(at: address) else { return }
        let elapsed = gate.launchedAt.duration(to: .now)
        let wait = configuration.unreportedWait
        let record = await terminalRecord(address, over: client)
        var effects = launchGate.handle(
            .recordRead(
                address: address, gate: gate, record: record, elapsed: elapsed,
                unreportedWait: wait))
        while let effect = effects.first {
            effects.removeFirst()
            switch effect {
            case .letThrough:
                return
            case .hold:
                throw Self.agentNotReady(gate, address: address)
            case .readScreen:
                let screen = try await visibleScreen(of: address, over: client)
                effects += launchGate.handle(
                    .screenRead(
                        address: address, gate: gate, screen: screen, elapsed: elapsed,
                        unreportedWait: wait))
            }
        }
    }

    /// The terminal's record: the live inventory's when the events are
    /// subscribed (no round trip), else one `terminal.get`, so a transport
    /// nobody subscribed to still sees a status report.
    func terminalRecord(_ address: String, over client: CoreRPCClient) async
        -> CoreTerminal?
    {
        if let inventory { return inventory.terminal(address: address) }
        return try? await client.call(
            "terminal.get", params: CoreParams.Terminal(terminal: address),
            as: CoreTerminal.self, timeout: nil)
    }

    private static func agentNotReady(_ gate: CoreLaunchGate, address: String) -> HerdrAPIError {
        HerdrAPIError(
            code: "agent_not_ready",
            message: "the \(gate.kind) agent in \(CoreID.pane(address)) is still starting")
    }
}
