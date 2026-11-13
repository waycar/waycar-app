import Foundation

extension CoreTransport {
    // MARK: Targets

    /// A terminal's address from the pane id the app hands out; an id that
    /// is not a core pane names no Agent here.
    static func address(ofPane id: String) throws -> String {
        guard let address = CoreID.address(ofPane: id) else {
            throw HerdrAPIError(code: "pane_not_found", message: "\(id) is not a herdr-core terminal")
        }
        return address
    }

    /// The Agent for `address` in the live inventory, as the Console would
    /// show it now.
    func agent(forAddress address: String) throws -> Agent {
        let paneID = CoreID.pane(address)
        guard let info = currentSnapshot().agents.first(where: { $0.paneID == paneID }) else {
            throw HerdrAPIError(
                code: "agent_not_found", message: "no agent in \(paneID)")
        }
        return Agent(info)
    }

    // MARK: Reading

    /// Lines of history a `recent` read takes when the request names none.
    static let defaultReadLines = 200

    func readPane(_ params: PaneReadParams) async throws -> PaneReadResult {
        try await read(paneID: params.paneID, source: params.source, lines: params.lines)
    }

    func readAgent(_ params: AgentReadParams) async throws -> PaneReadResult {
        try await read(paneID: params.target, source: params.source, lines: params.lines)
    }

    /// `terminal.read`: `lines` counts scrollback above the screen and 0 is
    /// the visible screen alone, so `visible` asks 0 and `recent` asks the
    /// request's lines; trailing blank rows are dropped and the last
    /// `lines` kept, as on herdr and tmux. A program on the alternate
    /// screen has no scrollback: only its screen comes back.
    private func read(paneID: String, source: ReadSource, lines: Int?) async throws
        -> PaneReadResult
    {
        let address = try Self.address(ofPane: paneID)
        let history = source == .visible ? 0 : min(max(0, lines ?? Self.defaultReadLines), 1000)
        let result = try await call(
            "terminal.read", CoreParams.Read(terminal: address, lines: history),
            as: CoreParams.ReadResult.self, subject: .pane)
        var rows = result.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.removeLast()
        }
        var truncated = result.complete == false
        if let lines, lines >= 0, rows.count > lines {
            rows = Array(rows.suffix(lines))
            truncated = true
        }
        let pane = currentSnapshot().panes.first { $0.paneID == CoreID.pane(address) }
        return PaneReadResult(
            format: .text, paneID: CoreID.pane(address), revision: 0, source: source,
            tabID: pane?.tabID ?? "", text: rows.joined(separator: "\n"), truncated: truncated,
            workspaceID: pane?.workspaceID ?? "")
    }

    /// The visible screen of `address`, for the screen checks before a
    /// prompt.
    func visibleScreen(of address: String, over client: CoreRPCClient) async throws
        -> String
    {
        let result = try await client.call(
            "terminal.read", params: CoreParams.Read(terminal: address, lines: 0),
            as: CoreParams.ReadResult.self, timeout: nil)
        return result.text
    }

    // MARK: Input

    /// The Agent's kind as the live inventory detects it; `unknown` for a
    /// terminal it does not list.
    private func kind(ofAddress address: String) -> String {
        inventory?.terminal(address: address).flatMap(CoreSnapshotBuilder.kind(of:))
            ?? Agent.unidentifiedKind
    }

    /// The screen checks `promptAgent` runs first: a sign-in screen or a
    /// folder-trust dialog the prompt would answer is refused, nothing sent.
    private func refuseInputScreen(
        address: String, kind: String, over client: CoreRPCClient
    ) async throws {
        let readiness = AgentScreen.readiness(kind: kind)
        guard readiness.hasSignInScreen || readiness.hasTrustDialog else { return }
        let screen = try await visibleScreen(of: address, over: client)
        let paneID = CoreID.pane(address)
        if readiness.hasSignInScreen, AgentScreen.signInRequired(kind: kind, screen: screen) {
            throw AgentSignInRequiredError(kind: kind, target: paneID)
        }
        if readiness.hasTrustDialog, AgentScreen.trustDialogShown(kind: kind, screen: screen) {
            throw AgentFolderTrustRequiredError(kind: kind, target: paneID)
        }
    }

    /// Fails `AgentSignInRequiredError` or `AgentFolderTrustRequiredError`
    /// while the Agent shows the screen `promptAgent` refuses; sends nothing.
    func checkAgentInputScreen(target: String) async throws {
        let address = try Self.address(ofPane: target)
        let client = try await connection()
        do {
            try await refuseInputScreen(address: address, kind: kind(ofAddress: address), over: client)
        } catch {
            throw CoreErrors.map(error, subject: .agent)
        }
    }

    /// `terminal.send`: core pastes the text (bracketed only if the program
    /// asked), waits out its paste gap and presses Enter. A `blocked`
    /// terminal is refused (`agent_blocked`) because typing would answer
    /// its dialog; one still starting or lost is `agent_not_ready`. The
    /// first prompt of an agent Waycar launched is held by its launch gate
    /// (`checkLaunchReadiness`) until it has reported its status or, if it
    /// never does, shows its input.
    /// `started: false` or `null` in the answer is not an error. The send is
    /// never retried. A link failure before the request is written fails
    /// `RequestNotSentError`.
    func promptAgent(_ params: AgentPromptParams) async throws -> Agent {
        let address = try Self.address(ofPane: params.target)
        let client: CoreRPCClient
        let agent: Agent
        do {
            client = try await connection()
            var screenKind = kind(ofAddress: address)
            if screenKind == Agent.unidentifiedKind, let launched = launchGate.gate(at: address)?.kind {
                screenKind = launched
            }
            try await refuseInputScreen(address: address, kind: screenKind, over: client)
            try await checkLaunchReadiness(address: address, over: client)
            agent = try await sentAgent(address, over: client)
        } catch {
            throw RequestNotSentError.wrapping(CoreErrors.map(error, subject: .agent))
        }
        do {
            _ = try await client.call(
                "terminal.send", params: CoreParams.Send(terminal: address, text: params.text),
                timeout: nil)
        } catch {
            throw CoreErrors.map(error, subject: .agent)
        }
        // An Agent may finish while core acknowledges the send. Its
        // disappearance must not turn delivered input into a retry.
        return agent
    }

    /// The Agent a prompt targets: the live inventory's row, or, on a
    /// transport nobody subscribed events on, the terminal's own record.
    private func sentAgent(_ address: String, over client: CoreRPCClient) async throws -> Agent {
        if inventory != nil { return try agent(forAddress: address) }
        guard let record = await terminalRecord(address, over: client),
            let info = CoreSnapshotBuilder.agentInfo(for: record, core: hello, overlay: overlay)
        else {
            throw HerdrAPIError(
                code: "agent_not_found", message: "no agent in \(CoreID.pane(address))")
        }
        return Agent(info)
    }

    /// Key names checked against core's accepted list before anything is
    /// sent (`CoreKeys`); `terminal.keys` is not refused for a blocked
    /// terminal, since keys are how a dialog is answered.
    func sendAgentKeys(_ params: AgentSendKeysParams) async throws {
        let address = try Self.address(ofPane: params.target)
        let names = try CoreKeys.names(for: params.keys)
        guard !names.isEmpty else { return }
        try await perform("terminal.keys", CoreParams.Keys(terminal: address, keys: names))
    }

    /// `{text, keys: [enter]}` is `terminal.send`; keys alone are
    /// `terminal.keys`. Text alone (no Enter) has no RPC on core: `send` is
    /// paste plus Enter, so the Composer keeps such text local.
    func sendPaneInput(_ params: PaneSendInputParams) async throws {
        let address = try Self.address(ofPane: params.paneID)
        let keys = params.keys ?? []
        let text = params.text ?? ""
        let submits = keys.map { $0.lowercased() } == ["enter"]
        if !text.isEmpty {
            guard submits else {
                throw HerdrAPIError(
                    code: "unsupported",
                    message: "herdr-core cannot type text without pressing Enter.")
            }
            try await perform("terminal.send", CoreParams.Send(terminal: address, text: text))
            return
        }
        let names = try CoreKeys.names(for: keys)
        guard !names.isEmpty else { return }
        try await perform("terminal.keys", CoreParams.Keys(terminal: address, keys: names))
    }

    // MARK: Close

    /// `terminal.kill` and nothing more: it is idempotent, and the record
    /// stays readable for core's retention window, as when the Herdr app
    /// closes a pane. `closesWorktreeGroup` means nothing without worktrees.
    func closePane(_ params: PaneTarget, closesWorktreeGroup: Bool) async throws {
        let address = try Self.address(ofPane: params.paneID)
        try await perform("terminal.kill", CoreParams.Terminal(terminal: address), subject: .pane)
    }

    /// Kills every terminal of the Tab.
    func closeTab(_ params: TabTarget) async throws {
        let addresses = currentSnapshot().panes
            .filter { $0.tabID == params.tabID }
            .compactMap { CoreID.address(ofPane: $0.paneID) }
        guard !addresses.isEmpty else {
            throw HerdrAPIError(code: "tab_not_found", message: "no tab \(params.tabID)")
        }
        for address in addresses {
            try await perform(
                "terminal.kill", CoreParams.Terminal(terminal: address), subject: .pane)
        }
    }

    // MARK: Seen

    /// herdr's "seen": a Done Agent shows Idle. Core never clears `done`
    /// itself and has no focus, so this is a client overlay: nothing is
    /// sent, and Done returns when the status word or `turn` changes.
    func focusAgent(_ target: AgentTarget) async throws {
        guard let address = CoreID.address(ofPane: target.target),
            let terminal = inventory?.terminal(address: address)
        else { return }
        _ = overlay.handle(.focused(address: address, terminal: terminal))
        cachedSnapshot = nil
    }
}
