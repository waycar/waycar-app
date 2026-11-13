import Foundation

extension ZellijTransport {
    static func paneID(_ value: String) throws -> ZellijPaneID {
        guard let pane = ZellijPaneID(value) else {
            throw HerdrAPIError(code: "pane_not_found", message: "Not a Zellij pane: \(value)")
        }
        return pane
    }

    func agent(_ id: ZellijPaneID) throws -> Agent {
        guard let info = currentSnapshot().agents.first(where: { $0.paneID == id.description }) else {
            throw HerdrAPIError(code: "agent_not_found", message: "No Agent in \(id)")
        }
        return Agent(info)
    }

    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        try await read(pane: Self.paneID(params.paneID), source: params.source, lines: params.lines)
    }

    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
        try await read(pane: Self.paneID(params.target), source: params.source, lines: params.lines)
    }

    private func read(pane: ZellijPaneID, source: ReadSource, lines: Int?) async throws -> PaneReadResult {
        let text = try await exec(commands.dumpScreen(pane, full: source != .visible))
        var rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while rows.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { rows.removeLast() }
        let limit = max(0, lines ?? (source == .visible ? rows.count : 200))
        let truncated = rows.count > limit
        rows = Array(rows.suffix(limit))
        let info = currentSnapshot().panes.first { $0.paneID == pane.description }
        return PaneReadResult(
            format: .text, paneID: pane.description, revision: 0, source: source,
            tabID: info?.tabID ?? "", text: rows.joined(separator: "\n"), truncated: truncated,
            workspaceID: pane.workspaceID)
    }

    /// Checks the visible screen before any bytes are sent, including on Agents not launched here.
    private func inputScreen(_ id: ZellijPaneID, kind: String) async throws -> String {
        let screen = try await exec(commands.dumpScreen(id))
        let readiness = AgentScreen.readiness(kind: kind)
        if readiness.hasSignInScreen, AgentScreen.signInRequired(kind: kind, screen: screen) {
            throw AgentSignInRequiredError(kind: kind, target: id.description)
        }
        if readiness.hasTrustDialog, AgentScreen.trustDialogShown(kind: kind, screen: screen) {
            throw AgentFolderTrustRequiredError(kind: kind, target: id.description)
        }
        return screen
    }

    func checkAgentInputScreen(target: String) async throws {
        let id = try Self.paneID(target)
        _ = try await inputScreen(id, kind: agent(id).kind)
    }

    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        let id = try Self.paneID(params.target)
        let turn = try await takePromptTurn(id.description)
        var submitHoldsTurn = false
        defer { if !submitHoldsTurn { releasePromptTurn(turn, of: id.description) } }
        let agent: Agent
        let paste: ZellijCommand.InputExec
        let delay: Duration
        do {
            try ensureOpen()
            agent = try self.agent(id)
            let screen = try await inputScreen(id, kind: agent.kind)
            let readiness = AgentScreen.readiness(kind: agent.kind)
            guard let row = record(id) else {
                throw HerdrAPIError(code: "agent_not_found", message: "No Agent in \(id)")
            }
            guard resolved(row, id: id).status != .blocked,
                TmuxScreenDetector.classify(kind: agent.kind, screen: screen, title: row.title ?? "")
                    != .blocked
            else { throw HerdrAPIError(code: "agent_blocked", message: "The Agent is blocked") }
            let reported = resolved(row, id: id).source
            if reported == .unknown || reported == .screen {
                if let marker = readiness.marker, !AgentScreen.inputIsOnScreen(marker, screen: screen) {
                    throw HerdrAPIError(
                        code: "agent_not_ready", message: "The Agent's input is still starting")
                }
                if let detected = detectedAt[id.description],
                    detected.duration(to: .now) < readiness.minimumDelay
                {
                    throw HerdrAPIError(code: "agent_not_ready", message: "The Agent is still starting")
                }
            }
            // Validate the whole draft before sending even its paste.
            paste = try commands.paste(id, text: params.text)
            delay = readiness.submitDelay
        } catch { throw RequestNotSentError.wrapping(error) }
        if delay > .zero, !params.text.isEmpty {
            try await exec(paste)
            // Once pasted, Enter owns the turn independently of caller cancellation.
            submitHoldsTurn = true
            let submit = Task {
                defer { self.releasePromptTurn(turn, of: id.description) }
                try? await Task.sleep(for: delay)
                try await self.submitPaste(id, kind: agent.kind, draft: params.text)
            }
            try await submit.value
        } else if params.text.isEmpty {
            try await exec(commands.sendKeys(id, keys: ["enter"]))
        } else {
            try await exec(commands.pasteAndEnter(id, text: params.text))
        }
        return agent
    }

    private func submitPaste(_ id: ZellijPaneID, kind: String, draft: String) async throws {
        // The feed ticks once a second: ask for a fresh report across the submit gap.
        let listing = try await exec(commands.listPanes(session: id.session))
        let rows = try JSONDecoder().decode([ZellijPaneRecord].self, from: Data(listing.utf8))
        let screen = try await exec(commands.dumpScreen(id))
        // Unlike notification config, hook state is optional and its directory may not exist.
        // Read without SFTP's config-directory permission enforcement (which throws on absence).
        let path = ShellWord.quoted(stateDirectory + "/" + id.fileName)
        let json = try await exec("if [ -f \(path) ]; then cat \(path); fi")
        let document = ZellijPaneState.decode(Data(json.utf8))
        let freshDocument = document.flatMap { doc in
            (doc.updatedMs ?? .min) >= (firstSeenMs[id.session] ?? .min) ? doc : nil
        }
        guard let row = rows.first(where: { $0.id == id.pane && $0.isVisible }),
            ZellijSnapshotBuilder.status(row, document: freshDocument, screen: nil).status != .blocked,
            record(id).map({ resolved($0, id: id).status }) != .blocked,
            TmuxScreenDetector.classify(kind: kind, screen: screen, title: row.title ?? "") != .blocked,
            AgentScreen.draftAwaitsEnter(kind: kind, draft: draft, screen: screen)
        else {
            throw HerdrAPIError(
                code: "prompt_not_submitted",
                message: "The prompt is typed in the Agent's input but was not submitted")
        }
        try await exec(commands.sendKeys(id, keys: ["enter"]))
    }

    private func takePromptTurn(_ pane: String) async throws -> UUID {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    promptTurnWaiters[id] = continuation
                    performPromptTurns(promptTurns.handle(.request(id, pane: pane)))
                }
            }
        } onCancel: {
            Task { await self.withdrawPromptTurn(id, of: pane) }
        }
        return id
    }

    private func withdrawPromptTurn(_ id: UUID, of pane: String) {
        performPromptTurns(promptTurns.handle(.withdraw(id, pane: pane)))
    }

    private func releasePromptTurn(_ id: UUID, of pane: String) {
        performPromptTurns(promptTurns.handle(.release(id, pane: pane)))
    }

    private func performPromptTurns(_ effects: [TmuxPromptTurnMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .grant(let id):
                promptTurnWaiters.removeValue(forKey: id)?.resume()
            case .cancel(let id):
                promptTurnWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    func sendAgentKeys(_ params: AgentSendKeysParams) async throws {
        guard !params.keys.isEmpty else { return }
        try await exec(commands.sendKeys(Self.paneID(params.target), keys: params.keys))
    }

    func sendPaneInput(_ params: PaneSendInputParams) async throws {
        let pane = try Self.paneID(params.paneID)
        // Validate keys before sending any text. One exec, ordered paste then keys.
        var lines: [String] = []
        var input = Data()
        if let text = params.text, !text.isEmpty {
            let paste = try commands.paste(pane, text: text)
            lines.append(paste.command)
            input = paste.input
        }
        if let keys = params.keys, !keys.isEmpty { lines.append(try commands.sendKeys(pane, keys: keys)) }
        if !lines.isEmpty { try await exec(lines.joined(separator: " && "), input: input) }
    }

    func closePane(_ params: PaneTarget, closesWorktreeGroup: Bool) async throws {
        try await exec(commands.closePane(Self.paneID(params.paneID)))
    }

    private func tab(_ tabID: String) throws -> (session: String, id: Int) {
        for session in frame.sessions where !session.closed {
            for row in frame.panes[session.name] ?? [] {
                if ZellijPaneID.tab(session: session.name, id: row.tabID) == tabID {
                    return (session.name, row.tabID)
                }
            }
        }
        throw HerdrAPIError(code: "tab_not_found", message: "No Zellij tab \(tabID)")
    }

    func closeTab(_ params: TabTarget) async throws {
        let tab = try tab(params.tabID)
        try await exec(commands.closeTab(session: tab.session, tabID: tab.id))
    }

    func renameAgent(_ params: AgentRenameParams) async throws {
        let pane = try Self.paneID(params.target)
        guard let target = ZellijSnapshotBuilder.renameTarget(for: pane, frame: frame) else {
            throw HerdrAPIError(code: "agent_not_found", message: "No Agent in \(pane)")
        }
        switch target {
        case .tab(let id):
            try await exec(commands.renameTab(session: pane.session, tabID: id, name: params.name ?? ""))
        case .pane:
            try await exec(commands.renamePane(pane, name: params.name ?? ""))
        }
    }

    func renameShellTab(tabID: String, label: String) async throws {
        let tab = try tab(tabID)
        try await exec(commands.renameTab(session: tab.session, tabID: tab.id, name: label))
    }

    func focusAgent(_ target: AgentTarget) async throws {
        try ensureOpen()
        let id = try Self.paneID(target.target)
        guard let row = record(id) else {
            throw HerdrAPIError(code: "pane_not_found", message: "No pane \(id)")
        }
        overlay.markSeen(
            terminalID: id.terminalID(generation: generations[id.session] ?? 0), status: resolved(row, id: id)
        )
        deliver(ZellijEvents.resync)
    }
}
