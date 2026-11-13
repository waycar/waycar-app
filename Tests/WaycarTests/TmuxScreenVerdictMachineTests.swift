import Testing

@testable import Waycar

/// `TmuxScreenVerdictMachine` through `handle`: ticks ask for reads, reads
/// report changes, and `forget` drops every verdict. The scheduling and
/// hook rules behind `due` and `record` are `TmuxScreenDetectorTests`'.
@Suite("tmux screen verdict machine")
struct TmuxScreenVerdictMachineTests {
    typealias Machine = TmuxScreenVerdictMachine

    private let now = ContinuousClock.now
    private let timing = TmuxScreenDetectorTests.timing
    private let hookless = TmuxScreenDetectorTests.pane("%2")
    private let hooked = TmuxScreenDetectorTests.pane("%3", status: "idle", seq: "4")

    @Test func aTickAsksToReadTheDuePanesOnly() {
        var machine = Machine()
        #expect(machine.handle(.tick([hooked, hookless], now: now, timing: timing))
            == [.readScreen(hookless)])
        #expect(Set(machine.state.keys) == ["%2", "%3"])
        // Read just now: not due again inside the interval.
        #expect(machine.handle(.tick([hooked, hookless], now: now + .seconds(1), timing: timing))
            .isEmpty)
    }

    @Test func aReadReportsAChangedVerdictOnce() {
        var machine = Machine().after([.tick([hookless], now: now, timing: timing)])
        #expect(machine.handle(.read(.blocked, pane: hookless, now: now))
            == [.report(.blocked, paneID: "%2")])
        #expect(machine.handle(.read(.blocked, pane: hookless, now: now)).isEmpty)
        #expect(machine.screenStatus(paneID: "%2", hookStatus: "", hookSeq: "", kind: "claude")
            == .blocked)
    }

    @Test func aReadForAnUnwatchedOrReplacedAgentReportsNothing() {
        var machine = Machine()
        #expect(machine.handle(.read(.blocked, pane: hookless, now: now)).isEmpty)
        machine = machine.after([.tick([hookless], now: now, timing: timing)])
        let copilot = TmuxScreenDetectorTests.pane("%2", kind: "copilot")
        #expect(machine.handle(.read(.blocked, pane: copilot, now: now)).isEmpty)
        #expect(machine.screenStatus(paneID: "%2", hookStatus: "", hookSeq: "", kind: "claude")
            == nil)
    }

    @Test func forgetDropsEveryVerdict() {
        var machine = Machine().after([
            .tick([hookless], now: now, timing: timing), .read(.blocked, pane: hookless, now: now),
        ])
        #expect(machine.handle(.forget).isEmpty)
        #expect(machine.state.isEmpty)
        #expect(machine.screenStatus(paneID: "%2", hookStatus: "", hookSeq: "", kind: "claude")
            == nil)
        #expect(machine.handle(.tick([hookless], now: now + .seconds(1), timing: timing))
            == [.readScreen(hookless)])
    }
}
