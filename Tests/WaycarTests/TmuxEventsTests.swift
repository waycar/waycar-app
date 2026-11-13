import Foundation
import Testing

@testable import Waycar

@Suite("tmux events")
struct TmuxEventsTests {
    private func value(_ rows: [[String]]) -> String {
        rows.map { $0.joined(separator: "\u{241F}") + "\u{241E}" }.joined()
    }

    private func status(
        _ pane: String, _ status: String, agent: String = "claude", session: String = "s1",
        seq: String = "1"
    ) -> [String] {
        [pane, status, agent, session, seq]
    }

    /// An option holding the separators must never yield a row: here pane
    /// %1's status smuggles in a forged blocked pane %9.
    @Test func separatorsInAnOptionYieldNoForgedRow() {
        let smuggled = "x\u{241E}%9\u{241F}blocked\u{241F}claude\u{241F}s\u{241F}1"
        let pushed = value([
            ["%1", smuggled, "claude", "s1", "1"], status("%2", "idle"), status("p3", "idle"),
        ])

        let rows = TmuxEvents.rows(pushed, fieldCount: TmuxEvents.statusFields.count)

        #expect(rows.map { $0[0] } == ["%2"])
    }

    @Test func firstStatusPushWithoutSnapshotResyncsAndUnchangedValueEmitsNothing() {
        let current = value([status("%1", "idle")])
        #expect(TmuxEvents.events(name: TmuxEvents.statusName, previous: nil, value: current)
            == [TmuxEvents.resync])
        #expect(TmuxEvents.events(name: TmuxEvents.statusName, previous: current, value: current)
            .isEmpty)
    }

    @Test func firstStatusPushMatchingSnapshotNeedsNoResync() {
        let panes = TmuxInventory.parsePanes([TmuxTransportTests.paneRecord(
            "%3", session: "$1", window: "@2", command: "claude", agent: "claude", status: "idle")])
        let pushed = value([status("%3", "idle", session: "", seq: "")])
        #expect(TmuxEvents.events(
            name: TmuxEvents.statusName, previous: TmuxEvents.statusValue(panes), value: pushed)
            .isEmpty)
    }

    @Test func statusOnlyChangeIsOneStatusEventPerPane() {
        let before = value([status("%1", "idle"), status("%2", "working"), status("%3", "done")])
        let after = value([
            status("%1", "working", seq: "2"), status("%2", "blocked", seq: "2"),
            status("%3", "done"),
        ])

        let events = TmuxEvents.events(name: TmuxEvents.statusName, previous: before, value: after)

        #expect(events == [
            HerdrEvent(
                kind: PaneEventKind.agentStatusChanged.kind,
                data: .object(["pane_id": .string("tmux:%1"), "agent_status": .string("working")])),
            HerdrEvent(
                kind: PaneEventKind.agentStatusChanged.kind,
                data: .object(["pane_id": .string("tmux:%2"), "agent_status": .string("blocked")])),
        ])
    }

    @Test func clearedStatusReportsUnknown() {
        let events = TmuxEvents.events(
            name: TmuxEvents.statusName, previous: value([status("%1", "done")]),
            value: value([status("%1", "")]))
        #expect(events.first?.data["agent_status"] == .string("unknown"))
    }

    @Test func kindOrSessionChangeResyncs() {
        let before = value([status("%1", "idle")])
        let kindChange = value([status("%1", "idle", agent: "codex")])
        let sessionChange = value([status("%1", "idle", session: "s2")])
        #expect(TmuxEvents.events(name: TmuxEvents.statusName, previous: before, value: kindChange)
            == [TmuxEvents.resync])
        #expect(TmuxEvents.events(
            name: TmuxEvents.statusName, previous: before, value: sessionChange)
            == [TmuxEvents.resync])
    }

    @Test func sequenceOnlyChangeResyncs() {
        let events = TmuxEvents.events(
            name: TmuxEvents.statusName, previous: value([status("%1", "done", seq: "1")]),
            value: value([status("%1", "done", seq: "9")]))
        #expect(events == [TmuxEvents.resync])
    }

    @Test func topologyChangeResyncsButGroupedReorderDoesNot() {
        let a = ["$1", "@1", "%1", "zsh", "0"]
        let b = ["$1", "@1", "%2", "2.1.286", "0"]
        let groupedB = ["$2", "@1", "%2", "2.1.286", "0"]
        let before = value([a, b])
        #expect(TmuxEvents.events(
            name: TmuxEvents.topologyName, previous: before, value: value([b, a])).isEmpty)
        #expect(TmuxEvents.events(
            name: TmuxEvents.topologyName, previous: before, value: value([a]))
            == [TmuxEvents.resync])
        #expect(TmuxEvents.events(
            name: TmuxEvents.topologyName, previous: before, value: value([a, b, groupedB]))
            == [TmuxEvents.resync])
        let resyncKind = TmuxEvents.resync.kind
        #expect(resyncKind == GlobalEventKind.paneCreated.kind)
    }

    @Test func notificationsMapToResyncKinds() {
        let cases: [(String, GlobalEventKind)] = [
            ("%sessions-changed", .workspaceCreated),
            ("%session-renamed $1 new", .workspaceRenamed),
            ("%window-add @3", .tabCreated),
            ("%unlinked-window-add @4", .tabCreated),
            ("%window-close @3", .tabClosed),
            ("%unlinked-window-close @4", .tabClosed),
            ("%window-renamed @3 name", .tabRenamed),
            ("%unlinked-window-renamed @4 name", .tabRenamed),
        ]
        for (line, kind) in cases {
            #expect(TmuxEvents.events(notification: line).map(\.kind) == [kind.kind])
        }
        #expect(TmuxEvents.events(notification: "%layout-change @1 abc,80x24,0,0 * 0").isEmpty)
        #expect(TmuxEvents.events(notification: "%output %1 hi").isEmpty)
    }
}
