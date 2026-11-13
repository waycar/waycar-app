import Foundation
import Testing

@testable import Waycar

@Suite("Zellij events and launch reconciliation")
struct ZellijEventsTests {
    @Test func statusDeltaAndMembershipResync() throws {
        let old = ZellijFixtures.frame()
        var new = old
        new.panes["fixture"]?[1].programStatus = [.init(state: "Done", app: "claude-code")]
        let events = ZellijEvents.events(previous: old, frame: new)
        #expect(events.count == 1)
        #expect(events.first?.kind == PaneEventKind.agentStatusChanged.kind)
        #expect(
            events.first?.data
                == .object(["pane_id": .string("zellij:fixture/terminal_0"), "agent_status": .string("done")])
        )
        #expect(ZellijEvents.events(previous: new, frame: new).isEmpty)
        new.panes["fixture"]?.removeLast()
        #expect(ZellijEvents.events(previous: old, frame: new).contains(ZellijEvents.resync))
        #expect(ZellijEvents.events(previous: nil, frame: old) == [ZellijEvents.resync])
    }

    @Test func foregroundCommandResyncsShellActivity() {
        let old = ZellijFixtures.frame(panes: #"[{"id":0,"tab_id":0,"pane_command":"bash"}]"#)
        var new = old
        new.panes["fixture"]?[0].paneCommand = "sleep 3"
        #expect(ZellijEvents.events(previous: old, frame: new) == [ZellijEvents.resync])
    }

    @Test func freshLaunchConfirmationWaitsForAsyncInventory() {
        let empty = ZellijFrame()
        #expect(
            ZellijLaunchReconciliation.confirmation(tag: "w-exact", frame: empty, elapsed: .zero) == .notYet)
        #expect(
            ZellijLaunchReconciliation.confirmation(tag: "w-exact", frame: empty, elapsed: .seconds(5))
                == .notFound)
        let frame = ZellijFixtures.frame(
            panes: #"[{"id":0,"tab_id":0,"terminal_command":"env WAYCAR_LAUNCH=w-exact claude"}]"#)
        guard
            case .found(let match) = ZellijLaunchReconciliation.confirmation(
                tag: "w-exact", frame: frame, elapsed: .seconds(1))
        else {
            Issue.record("A materialized launch must be adopted, not retried")
            return
        }
        #expect(match.pane.description == "zellij:fixture/terminal_0")
    }

    @Test func reconcileExactTagFromCommandOrDocument() throws {
        var frame = ZellijFixtures.frame(
            panes:
                #"[{"id":0,"tab_id":0,"terminal_command":"/bin/sh -c 'env WAYCAR_LAUNCH=w-exact claude'"},{"id":1,"tab_id":0,"terminal_command":"env WAYCAR_LAUNCH=w-exact-extra claude"}]"#
        )
        #expect(ZellijLaunchReconciliation.find(tag: "w-exact", frame: frame)?.pane.pane == 0)
        #expect(ZellijLaunchReconciliation.find(tag: "w-exac", frame: frame) == nil)
        #expect(ZellijLaunchReconciliation.find(tag: "missing", frame: frame) == nil)
        frame.panes["fixture"]?[0].terminalCommand = nil
        frame.documents["zellij:fixture/terminal_0"] = ZellijFixtures.document()
        #expect(ZellijLaunchReconciliation.find(tag: "w-exact", frame: frame)?.pane.pane == 0)
        #expect(
            ZellijLaunchReconciliation.find(tag: "w-exact", frame: frame, firstSeenMs: ["fixture": 101])
                == nil)
    }
}
