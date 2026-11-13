import Foundation
import Synchronization
import Testing

@testable import Waycar

@Suite("Zellij attach integration")
struct ZellijAttachIntegrationTests {
    private final class Recorder: Sendable {
        private let state = Mutex<[TerminalAttachInput]>([])
        func append(_ value: TerminalAttachInput) { state.withLock { $0.append(value) } }
        var values: [TerminalAttachInput] { state.withLock { $0 } }
    }

    private final class Raw: Sendable {
        let output = WaycarSSHAttachOutputGate()
        let input = TerminalAttachInputQueue()
        let received = Recorder()
        let writer: Task<Void, Never>
        let terminal: TerminalAttachSession

        init() {
            let output = output
            let input = input
            let received = received
            writer = Task {
                while let next = await input.next() {
                    received.append(next)
                    if next == .keystrokes(Data([0x07])) { output.yield(Data("claim redraw".utf8)) }
                }
            }
            terminal = TerminalAttachSession(output: output.makeOutput, input: input) {
                input.finish()
                output.beginExplicitEnd()
            }
        }
    }

    @Test(arguments: [false, true])
    func checkedNavigationAndDeskRestore(deskMoved: Bool) async throws {
        let raw = Raw()
        let calls = Mutex<[String]>([])
        let commands = try ZellijCommand(zellij: "/bin/zellij")
        let pane = try #require(ZellijPaneID(session: "work", pane: 1))
        let driver = ZellijAttachDriver(
            terminal: raw.terminal, request: TerminalAttachRequest(target: pane.description, cols: 80, rows: 30),
            commands: commands, pane: pane, tabID: 2, tabByPane: ["terminal_0": 0, "terminal_1": 2]
        ) { command in
            calls.withLock { $0.append(command) }
            return ZellijCommand.clientsBefore + "\n0 terminal_0 desk\n1 terminal_0 phone\n"
                + ZellijCommand.clientsAfter + "\n0 \(deskMoved ? "terminal_1" : "terminal_0") desk\n"
                + "1 \(deskMoved ? "terminal_0" : "terminal_1") phone\n" + ZellijCommand.clientsEnd + "\n"
        }
        let preparation = Task { try await driver.prepare() }
        try await waitUntil { raw.output.hasParkedConsumerForTesting }
        raw.output.yield(Data("initial oversized frame".utf8))
        let terminal = try await preparation.value
        #expect(raw.received.values.contains(.keystrokes(Data([0x07]))))
        try await waitUntil { raw.received.values.contains(.resize(cols: 80, rows: 30)) }
        #expect(calls.withLock { $0.count } == (deskMoved ? 2 : 1))
        if deskMoved {
            #expect(calls.withLock { $0.last } == commands.restoreChecked(session: "work", tabID: 0, rawPane: "terminal_0"))
        }
        let reader = Task { () throws -> Data? in
            var iterator = terminal.output.makeAsyncIterator()
            return try await iterator.next()
        }
        raw.output.yield(Data("phone redraw".utf8))
        #expect(try await reader.value == Data("phone redraw".utf8))
        terminal.scroll(Data("wheel".utf8), rows: 2)
        try await waitUntil { raw.received.values.contains(.scroll(Data("wheelwheel".utf8))) }
        #expect(!raw.received.values.contains(.keystrokes(Data("wheelwheel".utf8))))
        await terminal.end()
        await raw.writer.value
    }

    @Test func failedDeskRestorationDoesNotClaimASuccessfulHandoff() async throws {
        let raw = Raw()
        let pane = try #require(ZellijPaneID(session: "work", pane: 1))
        let driver = ZellijAttachDriver(
            terminal: raw.terminal, request: TerminalAttachRequest(target: pane.description, cols: 80, rows: 30),
            commands: try ZellijCommand(zellij: "/bin/zellij"), pane: pane, tabID: 2,
            tabByPane: ["terminal_0": 0, "terminal_1": 2]
        ) { command in
            guard command.contains("Cbefore") else { throw TransportError.channelFailed(detail: "restore refused") }
            return ZellijCommand.clientsBefore + "\n0 terminal_0 desk\n1 terminal_0 phone\n"
                + ZellijCommand.clientsAfter + "\n0 terminal_1 desk\n1 terminal_0 phone\n"
                + ZellijCommand.clientsEnd + "\n"
        }
        let preparation = Task { try await driver.prepare() }
        try await waitUntil { raw.output.hasParkedConsumerForTesting }
        raw.output.yield(Data("initial".utf8))
        await #expect(throws: TransportError.self) { _ = try await preparation.value }
        await raw.writer.value
        #expect(!raw.received.values.contains(.resize(cols: 80, rows: 30)))
    }

    @Test func transportOpensOversizedAndResolvesShellTerminalGeneration() async throws {
        let raw = Raw()
        let rig = try await ZellijTransportTests.open { _, _ in
            FakeHostSSHServices.result(stdout: ZellijCommand.clientsBefore + "\n1 terminal_0 phone\n"
                + ZellijCommand.clientsAfter + "\n1 terminal_0 phone\n" + ZellijCommand.clientsEnd + "\n")
        }
        await rig.session.serveAttach(raw.terminal)
        let snapshot = try await rig.transport.sessionSnapshot()
        let terminalID = try #require(snapshot.panes.first?.terminalID)
        let preparation = Task { try await rig.transport.attachTerminal(TerminalAttachRequest(
            target: .terminal(terminalID), cols: 80, rows: 30)) }
        try await waitUntil { raw.output.hasParkedConsumerForTesting }
        raw.output.yield(Data("initial".utf8))
        let terminal = try await preparation.value
        #expect(await rig.session.attachRequests.first?.cols == 600)
        #expect(await rig.session.attachRequests.first?.rows == 200)
        #expect(await rig.session.attachCommands.first?.contains("options --default-mode normal") == true)
        await terminal.end()
        await raw.writer.value
        try await rig.transport.close()
    }

    @Test func closedInventoryCannotAttachButExplicitResumeCan() async throws {
        let raw = Raw()
        let rig = try await ZellijTransportTests.open()
        await rig.session.serveAttach(raw.terminal)
        rig.channel.feed("\u{1E}B\nfixture [Created] (EXITED - attach to resurrect)\n\u{1E}P\n\u{1E}H\n\u{1E}E\n")
        try await waitUntil { try await rig.transport.sessionSnapshot().panes.isEmpty }
        await #expect(throws: HerdrAPIError.self) {
            _ = try await rig.transport.attachTerminal(TerminalAttachRequest(
                target: ZellijTransportTests.pane, cols: 80, rows: 30))
        }
        #expect(await rig.session.attachRequests.isEmpty)
        let saved = ZellijClosedSession(name: "fixture")
        let resumed = try await rig.transport.attachTerminal(TerminalAttachRequest(
            target: .terminal(saved.terminalID), cols: 80, rows: 30))
        let commands = try ZellijCommand(zellij: ZellijTransportTests.presence.path)
        #expect(await rig.session.attachCommands == [commands.resumeSession(name: "fixture")])
        await resumed.end()
        await raw.writer.value
        try await rig.transport.close()
    }

    @Test func timeoutHandsOffWholeSessionWithoutNavigationOrClaim() async throws {
        let raw = Raw()
        let calls = Mutex(0)
        let pane = try #require(ZellijPaneID(session: "work", pane: 0))
        let driver = ZellijAttachDriver(
            terminal: raw.terminal, request: TerminalAttachRequest(target: pane.description, cols: 80, rows: 30),
            commands: try ZellijCommand(zellij: "/bin/zellij"), pane: pane, tabID: 0, tabByPane: [:]
        ) { _ in calls.withLock { $0 += 1 }; return "" }
        let preparation = Task { try await driver.prepare() }
        try await waitUntil { raw.output.hasParkedConsumerForTesting }
        // Inject the machine's timer event, not a wall-clock sleep.
        await driver.send(.attachTimeout(1))
        let terminal = try await preparation.value
        #expect(calls.withLock { $0 } == 0)
        #expect(!raw.received.values.contains(.keystrokes(Data([0x07]))))
        await terminal.end()
        await raw.writer.value
    }
}
