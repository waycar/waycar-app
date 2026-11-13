import Testing

@testable import Waycar

/// `TmuxSubscriptionBaselineMachine`: what each subscription push diffs
/// against.
@Suite("tmux subscription baseline machine")
struct TmuxSubscriptionBaselineMachineTests {
    typealias Machine = TmuxSubscriptionBaselineMachine

    private static func status(_ rows: [[String]]) -> String {
        rows.map { $0.joined(separator: "\u{241F}") + "\u{241E}" }.joined()
    }

    private static func topology(_ rows: [[String]]) -> String {
        status(rows)
    }

    private let idlePanes = TmuxInventory.parsePanes([
        TmuxTransportTests.paneRecord(
            "%3", session: "$1", window: "@2", command: "claude", agent: "claude", status: "idle")
    ])
    private let idle = Self.status([["%3", "idle", "claude", "", ""]])
    private let blocked = Self.status([["%3", "blocked", "claude", "", ""]])
    private var resync: Machine.Effect { .resync(TmuxEvents.resyncKind) }

    @Test func aFirstStatusPushWithoutASnapshotAsksForOne() {
        var machine = Machine()
        let push = Machine.Event.pushed(
            name: TmuxEvents.statusName, value: blocked, snapshotPanes: nil)
        #expect(machine.handle(push) == [resync])
        #expect(machine.value(of: TmuxEvents.statusName) == blocked)
    }

    @Test func aFirstStatusPushDiffsAgainstTheSnapshot() {
        var machine = Machine()
        let push = Machine.Event.pushed(
            name: TmuxEvents.statusName, value: blocked, snapshotPanes: idlePanes)
        #expect(machine.handle(push) == [
            .deliver(TmuxEvents.statusChanged(paneID: "%3", status: "blocked"))
        ])
    }

    @Test func laterPushesDiffAgainstTheLastPushNotTheSnapshot() {
        var machine = Machine().after([
            .pushed(name: TmuxEvents.statusName, value: blocked, snapshotPanes: idlePanes)
        ])
        #expect(machine.handle(
            .pushed(name: TmuxEvents.statusName, value: blocked, snapshotPanes: idlePanes)).isEmpty)
        #expect(machine.handle(
            .pushed(name: TmuxEvents.statusName, value: idle, snapshotPanes: nil))
            == [.deliver(TmuxEvents.statusChanged(paneID: "%3", status: "idle"))])
    }

    @Test func aFirstTopologyPushIsOnlyTheBaseline() {
        var machine = Machine()
        let first = Self.topology([["$1", "@2", "%3", "zsh", "0"]])
        let second = Self.topology([["$1", "@2", "%3", "zsh", "0"], ["$1", "@2", "%4", "zsh", "0"]])
        #expect(machine.handle(
            .pushed(name: TmuxEvents.topologyName, value: first, snapshotPanes: idlePanes)).isEmpty)
        #expect(machine.handle(
            .pushed(name: TmuxEvents.topologyName, value: second, snapshotPanes: idlePanes))
            == [resync])
        #expect(machine.value(of: TmuxEvents.topologyName) == second)
        #expect(machine.value(of: TmuxEvents.statusName) == nil)
    }

    @Test func aResetForgetsEveryBaseline() {
        var machine = Machine().after([
            .pushed(name: TmuxEvents.statusName, value: blocked, snapshotPanes: idlePanes),
            .pushed(name: TmuxEvents.topologyName, value: "x", snapshotPanes: idlePanes),
        ])
        #expect(machine.handle(.reset).isEmpty)
        #expect(machine.state.isEmpty)
        #expect(machine.handle(
            .pushed(name: TmuxEvents.statusName, value: blocked, snapshotPanes: idlePanes))
            == [.deliver(TmuxEvents.statusChanged(paneID: "%3", status: "blocked"))])
    }
}
