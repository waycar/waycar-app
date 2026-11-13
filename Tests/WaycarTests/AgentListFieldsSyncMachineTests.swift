import Foundation
import Testing

@testable import Waycar

struct AgentListFieldsSyncMachineTests {
    private let host = UUID()
    private let other = UUID()
    private let layout = AgentRowLayout.waycarDefault

    @Test(arguments: [false, true])
    func successfulSyncAppliesItsOwnModeAndKeepsTheMessage(saveImmediately: Bool) {
        var machine = AgentListFieldsSyncMachine()
        #expect(machine.handle(.start(host, saveImmediately: saveImmediately)) == [.fetch(1)])
        #expect(machine.displays[host] == .syncing)
        #expect(machine.displays[host]?.message == nil)
        #expect(machine.handle(.received(host, 1, .replacement(layout, message: "filled"))) == [
            .applyLayout(host, 1, layout, saveImmediately: saveImmediately)
        ])
        #expect(machine.displays[host] == .filled("filled"))
        #expect(machine.handle(.applied(host, 1)) == [.clearError])
        #expect(machine.state.hosts[host] == .filled("filled"))
    }

    @Test func fetchAndPersistenceFailuresUseTheExistingPresentation() {
        var machine = AgentListFieldsSyncMachine()
        _ = machine.handle(.start(host, saveImmediately: false))
        #expect(machine.handle(.received(host, 1, .failed("offline"))) == [.clearError])
        #expect(machine.displays[host] == .failed("offline"))
        _ = machine.handle([.start(host, saveImmediately: true), .received(host, 2, .replacement(layout, message: "filled"))])
        #expect(machine.handle(.applyFailed(host, 2, "read only")) == [.reportError("read only")])
        #expect(machine.displays[host]?.message == "read only")
    }

    @Test func hostsHaveIndependentRequestsAndInvalidations() {
        var machine = AgentListFieldsSyncMachine()
        _ = machine.handle([.start(host, saveImmediately: true), .start(other, saveImmediately: true)])
        #expect(machine.handle(.received(host, 1, .replacement(layout, message: "one"))) == [
            .applyLayout(host, 1, layout, saveImmediately: true)
        ])
        _ = machine.handle([.applied(host, 1), .invalidate(host)])
        #expect(machine.displays[host] == nil)
        #expect(machine.handle(.received(other, 2, .replacement(layout, message: "two"))) == [
            .applyLayout(other, 2, layout, saveImmediately: true)
        ])
        _ = machine.handle(.applied(other, 2))
        #expect(machine.displays[other] == .filled("two"))
    }

    @Test func editSessionEndAndNewerRequestsDropStaleCompletions() {
        var machine = AgentListFieldsSyncMachine()
        _ = machine.handle([.start(host, saveImmediately: false), .invalidateAll])
        #expect(machine.displays.isEmpty)
        #expect(machine.handle(.start(host, saveImmediately: false)) == [.fetch(2)])
        let syncing = machine.state
        let stale: [AgentListFieldsSyncMachine.Event] = [
            .received(host, 1, .replacement(layout, message: "old")), .received(host, 1, .failed("old")),
            .applied(host, 1), .applyFailed(host, 1, "old"), .received(other, 2, .failed("wrong Host"))
        ]
        for event in stale {
            #expect(machine.handle(event) == [])
            #expect(machine.state == syncing)
        }
        _ = machine.handle(.received(host, 2, .replacement(layout, message: "current")))
        let applying = machine.state
        #expect(machine.handle(.received(host, 2, .failed("duplicate"))) == [])
        #expect(machine.state == applying)
        _ = machine.handle(.invalidateAll)
        #expect(machine.handle(.applied(host, 2)) == [])
        #expect(machine.handle(.applyFailed(host, 2, "old")) == [])
    }

    @Test func terminalStatesIgnoreDuplicateCompletionsButAllowNewRequests() {
        for success in [true, false] {
            var machine = AgentListFieldsSyncMachine().after([.start(host, saveImmediately: true)])
            _ = machine.handle(.received(host, 1, success ? .replacement(layout, message: "done") : .failed("offline")))
            if success { _ = machine.handle(.applied(host, 1)) }
            let terminal = machine.state
            #expect(machine.handle(.received(host, 1, .failed("duplicate"))) == [])
            #expect(machine.handle(.applied(host, 1)) == [])
            #expect(machine.handle(.applyFailed(host, 1, "duplicate")) == [])
            #expect(machine.state == terminal)
            #expect(machine.handle(.start(host, saveImmediately: false)) == [.fetch(2)])
        }
    }
}
