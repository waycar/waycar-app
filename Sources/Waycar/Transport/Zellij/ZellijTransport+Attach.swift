import Foundation

extension ZellijTransport {
    static func oversized(_ request: TerminalAttachRequest) -> TerminalAttachRequest {
        TerminalAttachRequest(target: request.target, cols: 600, rows: 200)
    }

    private func attachLocation(_ request: TerminalAttachRequest) throws -> (ZellijPaneID, ZellijPaneRecord) {
        try ensureOpen()
        let pane: ZellijPaneID
        switch request.target {
        case .agentPane(let id): pane = try Self.paneID(id)
        case .terminal(let terminal):
            guard let info = currentSnapshot().panes.first(where: { $0.terminalID == terminal }) else {
                throw HerdrAPIError(code: "pane_not_found", message: "This Zellij terminal is no longer running")
            }
            pane = try Self.paneID(info.paneID)
        }
        guard frame.sessions.contains(where: { $0.name == pane.session && !$0.closed }),
            let row = record(pane), row.exited != true else {
            throw HerdrAPIError(code: "pane_not_found", message: "This Zellij pane is no longer running")
        }
        return (pane, row)
    }

    func attachTerminal(_ request: TerminalAttachRequest) async throws -> TerminalAttachSession {
        if let name = ZellijClosedSession.name(for: request.target) {
            try ensureOpen()
            return try await session.attachTerminal(command: commands.resumeSession(name: name), request: request)
        }
        let (pane, _) = try attachLocation(request)
        let terminal = try await session.attachTerminal(
            command: commands.attach(session: pane.session), request: Self.oversized(request))
        do { return try await prepareMoshTerminal(terminal, request: request) }
        catch { await terminal.end(); throw error }
    }

    /// Shared SSH/mosh handoff: the raw session already starts oversized.
    func prepareMoshTerminal(
        _ terminal: TerminalAttachSession, request: TerminalAttachRequest
    ) async throws -> TerminalAttachSession {
        let (pane, row) = try attachLocation(request)
        let tabs = Dictionary(
            (frame.panes[pane.session] ?? []).map { (($0.isPlugin == true ? "plugin_" : "terminal_") + String($0.id), $0.tabID) },
            uniquingKeysWith: { first, _ in first })
        let driver = ZellijAttachDriver(
            terminal: terminal, request: request, commands: commands, pane: pane, tabID: row.tabID,
            tabByPane: tabs, exec: { try await self.exec($0) })
        return try await driver.prepare()
    }

    func probeMoshServer() async throws -> Bool { try await session.probeMoshServer() }

    func runMoshBootstrap(_ request: TerminalAttachRequest) async throws -> MoshBootstrap {
        let (pane, _) = try attachLocation(request)
        // The shared mosh wrapper forbids quotes/backslashes inside its own shell literal.
        // An encoded shell script preserves arbitrary valid session names without nested quoting.
        let encoded = Data(commands.attach(session: pane.session).utf8).base64EncodedString()
        let command = "/bin/sh -c \"$(printf %s " + encoded + " | base64 -d)\""
        return try await session.runMoshBootstrap(attachCommand: command, request: TerminalAttachRequest(
            target: request.target, cols: 512, rows: 200))
    }
}
