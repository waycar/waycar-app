import Foundation

/// Executes the existing attach machine, retaining sole ownership of the upstream output reader.
/// The UI gets a new gate: pre-handoff frames are discarded, then the resize redraw is forwarded.
actor ZellijAttachDriver {
    typealias Exec = @Sendable (String) async throws -> String
    private var machine: ZellijAttachMachine
    private let commands: ZellijCommand
    private let pane: ZellijPaneID
    private let tabID: Int
    private let terminal: TerminalAttachSession
    private let request: TerminalAttachRequest
    private let exec: Exec
    private let output = WaycarSSHAttachOutputGate()
    private let input = TerminalAttachInputQueue()
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var quiet: Task<Void, Never>?
    private var action: Task<Void, Never>?
    private var ready: CheckedContinuation<TerminalAttachSession, any Error>?

    init(
        terminal: TerminalAttachSession, request: TerminalAttachRequest, commands: ZellijCommand,
        pane: ZellijPaneID, tabID: Int, tabByPane: [String: Int], exec: @escaping Exec
    ) {
        self.terminal = terminal
        self.request = request
        self.commands = commands
        self.pane = pane
        self.tabID = tabID
        self.exec = exec
        machine = ZellijAttachMachine(targetPane: pane.rawPane, tabByPane: tabByPane)
    }

    func prepare() async throws -> TerminalAttachSession {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                send(.ptyOpened)
                let terminal = terminal
                reader = Task { [weak self] in
                    do {
                        for try await bytes in terminal.output where !bytes.isEmpty {
                            await self?.received(bytes)
                        }
                        await self?.ended(nil)
                    } catch { await self?.ended(error) }
                }
            }
        } onCancel: { Task { await self.end() } }
    }

    private func received(_ bytes: Data) {
        if case .finished = machine.state { output.yield(bytes) }
        else { send(.outputSeen) }
    }

    func send(_ event: ZellijAttachMachine.Event) {
        for effect in machine.handle(event) {
            switch effect {
            case .armTimeout(let token, let delay):
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: delay) } catch { return }
                    await self?.send(.attachTimeout(token))
                }
            case .armQuiet(let token, let delay):
                quiet?.cancel()
                quiet = Task { [weak self] in
                    do { try await Task.sleep(for: delay) } catch { return }
                    await self?.send(.quietElapsed(token))
                }
            case .sendClaim(let token, let bytes):
                terminal.send(Data(bytes))
                send(.claimSent(token, success: true))
            case .runNavigation(let token):
                action = Task { [weak self, commands, pane, tabID, exec] in
                    let tables = try? await exec(commands.navigate(pane, tabID: tabID))
                    let parsed = tables.flatMap(ZellijClients.navigation)
                    await self?.send(.navigationResult(token, before: parsed?.before ?? [], after: parsed?.after ?? []))
                }
            case .restoreDesk(let token, let desk):
                action = Task { [weak self, commands, pane, exec, terminal] in
                    do {
                        _ = try await exec(commands.restoreChecked(
                            session: pane.session, tabID: desk.tabID, rawPane: desk.pane))
                        await self?.send(.restoreResult(token))
                    } catch {
                        await self?.ended(TransportError.channelFailed(
                            detail: "Zellij could not restore another client's focus: " + error.localizedDescription))
                        await terminal.end()
                    }
                }
            case .resizeToPhone(let token):
                terminal.resize(cols: request.cols, rows: request.rows)
                send(.resized(token))
            case .finish:
                timeout?.cancel()
                quiet?.cancel()
                let terminal = terminal
                let input = input
                writer = Task {
                    while let next = await input.next() {
                        switch next {
                        case .keystrokes(let bytes): terminal.send(bytes)
                        case .scroll(let bytes): terminal.scroll(bytes, rows: 1)
                        case .resize(let cols, let rows): terminal.resize(cols: cols, rows: rows)
                        }
                    }
                }
                let wrapped = TerminalAttachSession(
                    output: output.makeOutput, input: input,
                    onEndStarted: output.beginExplicitEnd, link: terminal.link,
                    abandoner: { await self.end(abandoning: true) }, ender: { await self.end() })
                ready?.resume(returning: wrapped)
                ready = nil
            }
        }
    }

    private func ended(_ error: (any Error)?) {
        timeout?.cancel()
        quiet?.cancel()
        action?.cancel()
        input.finish()
        output.finish(throwing: error)
        ready?.resume(throwing: error ?? TransportError.channelFailed(detail: "Zellij attach ended before drawing"))
        ready = nil
    }

    private func end(abandoning: Bool = false) async {
        ended(CancellationError())
        reader?.cancel()
        writer?.cancel()
        if abandoning { await terminal.abandon() } else { await terminal.end() }
        await reader?.value
        await writer?.value
    }
}
