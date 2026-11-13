import Foundation
import Testing

@testable import Waycar

struct ChatMarkerAuthorityMachineTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func marker(terminal: String? = "old", session: String? = nil, offset: TimeInterval = 0) -> ChatModeMarker {
        ChatModeMarker(
            paneID: "pane", terminalID: terminal, kind: "claude", cwd: "/work",
            session: session.map { .init(kind: "id", value: $0) }, launchedAt: now + offset)
    }
    private func agent(terminal: String, session: String?) -> Agent {
        Agent(terminalID: terminal, kind: "claude", title: "Task", status: .working,
              workspaceID: "w", tabID: "tab", paneID: "pane", cwd: "/work", revision: 1,
              agentSession: session.map { .init(agent: "claude", kind: .id, source: "herdr:claude", value: $0) })
    }

    @Test func localGraceRewritesUntilTheExactBoundaryThenHostWins() {
        let local = marker()
        var machine = ChatMarkerAuthorityMachine()
        #expect(machine.handle(.record(local, now: now)) == [.changed(revision: true)])
        #expect(machine.handle(.reported(nil, now: now + 119)) == [.rewrite(local)])
        #expect(machine.handle(.reported(nil, now: now + 120)) == [.changed(revision: true)])
        #expect(machine.state == .absent)
        #expect(machine.handle(.reported(nil, now: now + 121)).isEmpty)
    }

    @Test func hostConfirmationClearsLocalAuthorityAndOnlyNewerLaunchSupersedes() {
        let local = marker(session: "s")
        var machine = ChatMarkerAuthorityMachine().after([.record(local, now: now)])
        #expect(machine.handle(.reported(marker(offset: -1), now: now)) == [.rewrite(local)])
        #expect(machine.handle(.reported(marker(), now: now)) == [.rewrite(local)])
        #expect(machine.handle(.reported(local, now: now)) == [.changed(revision: true)])
        #expect(machine.state == .confirmed(local))
        #expect(machine.handle(.reported(local, now: now)).isEmpty)
        #expect(machine.handle(.record(local, now: now)) == [.changed(revision: true)])
        let later = marker(offset: 1)
        #expect(machine.handle(.reported(later, now: now)) == [.changed(revision: true)])
        #expect(machine.state == .confirmed(later))
    }

    @Test func retiredLaunchUsesWireMillisecondsAndEndsOnAbsenceOrNewLaunch() {
        var machine = ChatMarkerAuthorityMachine().after([.record(marker(offset: 0.0004), now: now), .retire])
        #expect(machine.marker == nil)
        #expect(machine.handle(.reported(marker(), now: now)) == [.delete])
        #expect(machine.handle(.retire).isEmpty)
        #expect(machine.handle(.session(.init(kind: "id", value: "s"), now: now)).isEmpty)
        #expect(machine.handle(.follow(agent(terminal: "old", session: "s"), now: now)).isEmpty)
        #expect(machine.handle(.reported(nil, now: now)) == [.changed(revision: false)])
        #expect(machine.state == .absent)
        #expect(machine.handle(.retire).isEmpty)
        #expect(machine.handle(.session(.init(kind: "id", value: "s"), now: now)).isEmpty)
        #expect(machine.handle(.follow(agent(terminal: "old", session: "s"), now: now)).isEmpty)
        _ = machine.handle([.record(marker(), now: now), .retire])
        let later = marker(offset: 1)
        #expect(machine.handle(.reported(later, now: now)) == [.changed(revision: true)])
        _ = machine.handle(.retire)
        #expect(machine.handle(.record(later, now: now)) == [.changed(revision: true)])
        #expect(machine.marker == later)
    }

    @Test func followKeepsTerminalAndSessionCurrentAcrossRestoreAndSessionSwitch() {
        let original = marker(session: "s")
        var machine = ChatMarkerAuthorityMachine().after([.reported(original, now: now)])
        #expect(machine.handle(.follow(agent(terminal: "new", session: "s"), now: now)) == [.changed(revision: true)])
        let rebound = marker(terminal: "new", session: "s")
        #expect(machine.marker == rebound)
        #expect(machine.handle(.reported(original, now: now)) == [.rewrite(rebound)])
        #expect(machine.handle(.follow(agent(terminal: "new", session: "next"), now: now)) == [.changed(revision: true)])
        #expect(machine.marker == marker(terminal: "new", session: "next"))
        #expect(machine.handle(.follow(agent(terminal: "new", session: nil), now: now)).isEmpty)
        #expect(machine.handle(.follow(agent(terminal: "other", session: "unrelated"), now: now)).isEmpty)
    }

    @Test func explicitSessionUpdatesKeepLaunchFieldsAndNilTerminalStaysNil() {
        var machine = ChatMarkerAuthorityMachine().after([.record(marker(terminal: nil), now: now)])
        #expect(machine.handle(.follow(agent(terminal: "new", session: "s"), now: now)) == [.changed(revision: true)])
        #expect(machine.marker == marker(terminal: nil, session: "s"))
        let session = ChatModeMarker.Session(kind: "id", value: "next")
        #expect(machine.handle(.session(session, now: now)) == [.changed(revision: true)])
        #expect(machine.marker == marker(terminal: nil, session: "next"))
        // Explicit updateSession used to publish even an identical binding.
        #expect(machine.handle(.session(session, now: now)) == [.changed(revision: true)])
    }
}
