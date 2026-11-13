import Foundation
import Testing

@testable import Waycar

@Suite("Zellij clients and attach machine")
struct ZellijAttachMachineTests {
    private func drawingMachine() throws -> ZellijAttachMachine {
        var machine = ZellijAttachMachine(
            targetPane: "terminal_2", tabByPane: ["terminal_0": 0, "terminal_2": 1])
        #expect(machine.handle(.ptyOpened) == [.armTimeout(1, after: .seconds(5))])
        #expect(machine.handle(.outputSeen) == [.armQuiet(2, after: .milliseconds(200))])
        #expect(machine.handle(.outputSeen) == [.armQuiet(3, after: .milliseconds(200))])
        #expect(machine.handle(.quietElapsed(2)).isEmpty)
        #expect(machine.handle(.quietElapsed(3)) == [.sendClaim(4, bytes: [0x07])])
        #expect(machine.handle(.claimSent(4, success: true)).isEmpty)
        #expect(machine.handle(.quietElapsed(3)).isEmpty)
        #expect(machine.handle(.outputSeen) == [.armQuiet(5, after: .milliseconds(200))])
        #expect(machine.handle(.quietElapsed(5)) == [.runNavigation(6)])
        return machine
    }

    @Test func exactPaneOnlyAfterResize() throws {
        var machine = try drawingMachine()
        let before: [ZellijClient] = [.init(id: 0, pane: "terminal_0"), .init(id: 4, pane: "terminal_0")]
        let after: [ZellijClient] = [.init(id: 0, pane: "terminal_0"), .init(id: 4, pane: "terminal_2")]
        #expect(machine.handle(.navigationResult(99, before: before, after: after)).isEmpty)
        #expect(machine.handle(.navigationResult(6, before: before, after: after)) == [.resizeToPhone(7)])
        #expect(machine.state == .resizing(7, .exactPane))
        #expect(machine.handle(.resized(7)) == [.finish(.exactPane)])
        #expect(machine.handle(.ptyOpened).isEmpty)
    }

    @Test func deskMovedRestoresItsEarlierTabAndPane() throws {
        var machine = try drawingMachine()
        let before: [ZellijClient] = [.init(id: 0, pane: "terminal_0"), .init(id: 4, pane: "terminal_0")]
        let after: [ZellijClient] = [.init(id: 0, pane: "terminal_2"), .init(id: 4, pane: "terminal_0")]
        #expect(
            machine.handle(.navigationResult(6, before: before, after: after)) == [
                .restoreDesk(7, .init(clientID: 0, tabID: 0, pane: "terminal_0"))
            ])
        #expect(machine.handle(.restoreResult(6)).isEmpty)
        #expect(machine.handle(.restoreResult(7)) == [.resizeToPhone(8)])
        #expect(machine.handle(.resized(8)) == [.finish(.wholeSession)])
    }

    @Test func timeoutFallsBackWithoutNavigation() {
        var machine = ZellijAttachMachine(targetPane: "terminal_2", tabByPane: [:])
        _ = machine.handle(.ptyOpened)
        #expect(machine.handle(.attachTimeout(99)).isEmpty)
        #expect(machine.handle(.attachTimeout(1)) == [.resizeToPhone(2)])
        #expect(machine.handle(.resized(2)) == [.finish(.wholeSession)])
    }

    @Test func claimMustRedrawBeforeNavigationAndCanTimeOut() {
        var machine = ZellijAttachMachine(targetPane: "terminal_2", tabByPane: [:])
        _ = machine.handle(.ptyOpened)
        _ = machine.handle(.outputSeen)
        #expect(machine.handle(.quietElapsed(2)) == [.sendClaim(3, bytes: [0x07])])
        #expect(machine.handle(.outputSeen).isEmpty)  // Redraw may arrive before the PTY write completes.
        #expect(machine.handle(.claimSent(3, success: true)) == [.armQuiet(4, after: .milliseconds(200))])
        #expect(machine.handle(.attachTimeout(1)) == [.resizeToPhone(5)])
        #expect(machine.handle(.quietElapsed(4)).isEmpty)
    }

    @Test func claimRecipeControlsInputAndPostRedrawQuiet() {
        let claim = ZellijAttachMachine.Claim(mode: "session", bytes: [0x1B], settle: .seconds(1))
        var machine = ZellijAttachMachine(targetPane: "terminal_2", tabByPane: [:], claim: claim)
        _ = machine.handle(.ptyOpened)
        _ = machine.handle(.outputSeen)
        #expect(machine.handle(.quietElapsed(2)) == [.sendClaim(3, bytes: [0x1B])])
        _ = machine.handle(.claimSent(3, success: true))
        #expect(machine.handle(.outputSeen) == [.armQuiet(4, after: .seconds(1))])
        #expect(machine.handle(.quietElapsed(4)) == [.runNavigation(5)])
    }

    @Test func parsesClientTablesAndNavigationSentinels() throws {
        let table =
            "CLIENT_ID ZELLIJ_PANE_ID RUNNING_COMMAND\r\n0    terminal_0    claude --continue\r\n4 terminal_2 N/A\r\n"
        let clients = ZellijClients.parse(table)
        #expect(
            clients == [
                .init(id: 0, pane: "terminal_0", command: "claude --continue"),
                .init(id: 4, pane: "terminal_2"),
            ])
        let output =
            ZellijCommand.clientsBefore + "\n" + table + "Pane Terminal(2) is already focused\n"
            + ZellijCommand.clientsAfter + "\n" + table + ZellijCommand.clientsEnd + "\n"
        let parsed = try #require(ZellijClients.navigation(output))
        #expect(parsed.before == clients)
        #expect(parsed.after == clients)
    }
}
