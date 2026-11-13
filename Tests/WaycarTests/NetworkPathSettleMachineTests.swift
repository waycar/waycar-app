import Testing

@testable import Waycar

@Suite("Network path settle machine")
struct NetworkPathSettleMachineTests {
    private typealias Machine = NetworkPathSettleMachine

    private static let home = NetworkPathKey(
        interface: .wifi, interfaceName: "en0", addressPrefix: "192.168.1")
    private static let cafe = NetworkPathKey(
        interface: .wifi, interfaceName: "en0", addressPrefix: "10.0.7")

    @Test func startStartsTheSourceOnce() {
        var machine = Machine()
        #expect(machine.handle(.start) == [.startSource])
        #expect(machine.handle(.start) == [])
        #expect(machine.state.isStarted)
    }

    @Test func theFirstReadingIsTheBaseline() {
        var machine = Machine()
        #expect(machine.settledKey == .none)
        #expect(machine.handle(.read(Self.home)) == [.reportBaseline(Self.home)])
        #expect(machine.state.reading == .settled(Self.home))
        #expect(machine.currentKey == Self.home)
        #expect(machine.settledKey == .some(Self.home))
    }

    @Test func aBaselineWithNoPathIsStillABaseline() {
        var machine = Machine()
        #expect(machine.handle(.read(nil)) == [.reportBaseline(nil)])
        #expect(machine.settledKey == .some(nil))
    }

    @Test func aLaterReadingArmsADebounce() {
        var machine = Machine().after([.read(Self.home)])
        let effects = machine.handle(.read(Self.cafe))
        guard case .debouncing(Self.home, Self.cafe, let token) = machine.state.reading else {
            Issue.record("not debouncing: \(machine.state.reading)")
            return
        }
        #expect(effects == [.armDebounce(token: token)])
        #expect(machine.currentKey == Self.cafe)
        #expect(machine.settledKey == .some(Self.home))
    }

    @Test func eachReadingReplacesTheDebounceUnderAFreshToken() {
        var machine = Machine().after([.read(Self.home), .read(Self.cafe)])
        guard case .debouncing(_, _, let first) = machine.state.reading else { return }
        let effects = machine.handle(.read(nil))
        guard case .debouncing(Self.home, nil, let second) = machine.state.reading else {
            Issue.record("not debouncing: \(machine.state.reading)")
            return
        }
        #expect(second != first)
        #expect(effects == [.armDebounce(token: second)])
    }

    @Test func theCurrentDebounceSettlesAChange() {
        var machine = Machine().after([.read(Self.home), .read(Self.cafe)])
        guard case .debouncing(_, _, let token) = machine.state.reading else { return }
        #expect(machine.handle(.debounceElapsed(token: token)) == [.reportChange(Self.cafe)])
        #expect(machine.state.reading == .settled(Self.cafe))
    }

    @Test func aBlipBackToTheSettledPathSettlesWithoutAChange() {
        var machine = Machine().after([.read(Self.home), .read(nil), .read(Self.home)])
        guard case .debouncing(_, _, let token) = machine.state.reading else { return }
        #expect(machine.handle(.debounceElapsed(token: token)) == [])
        #expect(machine.state.reading == .settled(Self.home))
    }

    /// B-26: a debounce a newer reading replaced settles nothing, even when
    /// the newer reading names the same path.
    @Test func aReplacedDebounceSettlesNothing() {
        var machine = Machine().after([.read(Self.home), .read(Self.cafe)])
        guard case .debouncing(_, _, let stale) = machine.state.reading else { return }
        _ = machine.handle([.read(Self.home), .read(Self.cafe)])
        let before = machine.state
        #expect(machine.handle(.debounceElapsed(token: stale)) == [])
        #expect(machine.state == before)
    }

    @Test func aDebounceElapsingWhenNoneIsArmedIsIgnored() {
        var waiting = Machine()
        #expect(waiting.handle(.debounceElapsed(token: 1)) == [])
        #expect(waiting.state.reading == .awaitingBaseline)

        var settled = Machine().after([.read(Self.home), .read(Self.cafe)])
        guard case .debouncing(_, _, let token) = settled.state.reading else { return }
        _ = settled.handle(.debounceElapsed(token: token))
        #expect(settled.handle(.debounceElapsed(token: token)) == [])
        #expect(settled.state.reading == .settled(Self.cafe))
    }

    @Test func noTokenIsReused() {
        var machine = Machine().after([.read(Self.home)])
        var tokens: Set<UInt64> = []
        for key in [Self.cafe, Self.home, nil, Self.cafe] {
            guard case .armDebounce(let token) = machine.handle(.read(key)).first else {
                Issue.record("no debounce armed")
                return
            }
            #expect(tokens.insert(token).inserted)
            _ = machine.handle(.debounceElapsed(token: token))
        }
    }

    @Test func stopCancelsAndFinishesAndLeavesTheReadings() {
        var machine = Machine().after([.start, .read(Self.home), .read(Self.cafe)])
        let before = machine.state
        #expect(machine.handle(.stop) == [.cancelDebounce, .cancelSource, .finishStreams])
        #expect(machine.state == before)
        #expect(machine.handle(.stop) == [.cancelDebounce, .cancelSource, .finishStreams])
    }
}
