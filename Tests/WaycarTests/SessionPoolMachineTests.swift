import Testing

@testable import Waycar

@Suite("Session pool machine")
struct SessionPoolMachineTests {
    private final class Stub: SSHPooledSession {
        var isConnected: Bool { get async { true } }
        func retain() async -> Bool { true }
        func release() async {}
    }

    private typealias Machine = SessionPoolMachine<Stub>
    private typealias Entry = Machine.Entry

    /// Gives `machine`'s `host` key a live connection, landed from a dial
    /// with one waiter, and returns it.
    private func withLive(_ machine: inout Machine) -> Entry {
        let session = Stub()
        guard case .wait(let waiter) = machine.handle(.lookUp(key: "host", stale: nil)).first,
            case .startDial(let dial) = machine.handle(.join(key: "host", waiter: waiter, stale: nil)).first,
            case .distribute(let entry, _) = machine.handle(
                .dialEnded(key: "host", dial: dial, session: session)).first
        else {
            Issue.record("no live connection")
            return Entry(session: session, serial: 0)
        }
        return entry
    }

    // MARK: Acquire

    @Test func anEmptyKeyWaitsForADial() {
        var machine = Machine()
        guard case .wait(let waiter) = machine.handle(.lookUp(key: "host", stale: nil)).first else {
            Issue.record("did not wait")
            return
        }
        guard case .startDial(let dial) = machine.handle(
            .join(key: "host", waiter: waiter, stale: nil)).first
        else {
            Issue.record("did not dial")
            return
        }
        #expect(machine.state.dials["host"] == Machine.Dial(id: dial, replaces: nil, waiters: [waiter]))
        #expect(machine.waiterCount(key: "host") == 1)
    }

    @Test func aSecondAcquirerJoinsTheDialInFlight() {
        var machine = Machine()
        _ = machine.handle(.join(key: "host", waiter: 100, stale: nil))
        #expect(machine.handle(.join(key: "host", waiter: 101, stale: nil)) == [])
        #expect(machine.state.dials["host"]?.waiters == [100, 101])
    }

    @Test func theLiveConnectionIsProbedAndHandedOut() {
        var machine = Machine()
        let live = withLive(&machine)
        #expect(machine.handle(.lookUp(key: "host", stale: nil)) == [.probeLive(live)])
        #expect(machine.handle(.liveProbed(key: "host", live, retained: true, stale: nil))
            == [.handOut(live)])
    }

    @Test func aLiveConnectionThatFailsItsProbeStopsBeingShared() {
        var machine = Machine()
        let live = withLive(&machine)
        let effects = machine.handle(.liveProbed(key: "host", live, retained: false, stale: nil))
        guard case .wait = effects.first else {
            Issue.record("did not wait: \(effects)")
            return
        }
        #expect(machine.state.live["host"] == nil)
    }

    @Test func aStaleProbeLeavesANewerLiveConnectionAlone() {
        var machine = Machine()
        let live = withLive(&machine)
        let older = Entry(session: Stub(), serial: live.serial - 1)
        #expect(machine.handle(.liveProbed(key: "host", older, retained: false, stale: nil))
            == [.probeLive(live)])
        #expect(machine.state.live["host"] == live)
    }

    @Test func theStaleConnectionIsNeverHandedOutAgain() {
        var machine = Machine()
        let live = withLive(&machine)
        let effects = machine.handle(.lookUp(key: "host", stale: live.serial))
        guard case .wait(let waiter) = effects.first else {
            Issue.record("did not wait: \(effects)")
            return
        }
        guard case .startDial(let dial) = machine.handle(
            .join(key: "host", waiter: waiter, stale: live.serial)).first
        else { return }
        #expect(machine.state.dials["host"]?.replaces == live.serial)
        _ = dial
    }

    @Test func aHedgeLandingWhileTheReplacedIsLiveIsHeldBack() {
        var machine = Machine()
        let live = withLive(&machine)
        _ = machine.handle(.join(key: "host", waiter: 200, stale: live.serial))
        guard let dial = machine.state.dials["host"]?.id else { return }
        let hedge = Stub()
        guard case .distribute(let entry, let waiters) = machine.handle(
            .dialEnded(key: "host", dial: dial, session: hedge)).first
        else {
            Issue.record("not distributed")
            return
        }
        #expect(waiters == [200])
        #expect(machine.state.replacements["host"] == entry)
        #expect(machine.state.live["host"] == live)
        // A replacing acquire is handed the hedge; others still the live one.
        #expect(machine.handle(.lookUp(key: "host", stale: live.serial)) == [.probeReplacement(entry)])
        #expect(machine.handle(.lookUp(key: "host", stale: nil)) == [.probeLive(live)])
    }

    @Test func aHedgeThatFailsItsProbeLeavesTheAcquireToWait() {
        var machine = Machine()
        let live = withLive(&machine)
        let hedge = Entry(session: Stub(), serial: 999)
        let effects = machine.handle(
            .replacementProbed(key: "host", hedge, retained: false, stale: live.serial))
        guard case .wait = effects.first else {
            Issue.record("did not wait: \(effects)")
            return
        }
    }

    @Test func aFailedDialFailsItsWaiters() {
        var machine = Machine()
        _ = machine.handle(.join(key: "host", waiter: 1, stale: nil))
        _ = machine.handle(.join(key: "host", waiter: 2, stale: nil))
        guard let dial = machine.state.dials["host"]?.id else { return }
        #expect(machine.handle(.dialEnded(key: "host", dial: dial, session: nil))
            == [.failWaiters([1, 2])])
        #expect(machine.state.dials["host"] == nil)
    }

    @Test func aDialNobodyWaitsForIsCancelledAndReleasedWhenItLands() {
        var machine = Machine()
        _ = machine.handle(.join(key: "host", waiter: 1, stale: nil))
        guard let dial = machine.state.dials["host"]?.id else { return }
        #expect(machine.handle(.cancelWaiter(key: "host", waiter: 1))
            == [.cancelWaiter(1), .cancelDial(dial)])
        #expect(machine.handle(.dialEnded(key: "host", dial: dial, session: Stub()))
            == [.releaseUnclaimed])
        #expect(machine.state.live.isEmpty)
    }

    @Test func oneWaiterLeavingKeepsTheDialForTheOthers() {
        var machine = Machine()
        _ = machine.handle(.join(key: "host", waiter: 1, stale: nil))
        _ = machine.handle(.join(key: "host", waiter: 2, stale: nil))
        #expect(machine.handle(.cancelWaiter(key: "host", waiter: 1)) == [.cancelWaiter(1)])
        #expect(machine.state.dials["host"]?.waiters == [2])
        #expect(machine.handle(.cancelWaiter(key: "host", waiter: 7)) == [])
    }

    @Test func anAbandonedDialIsNotJoinedAndKeepsItsWaiters() {
        var machine = Machine()
        _ = machine.handle(.join(key: "host", waiter: 1, stale: nil))
        guard let old = machine.state.dials["host"]?.id else { return }
        _ = machine.handle(.abandonDial(key: "host"))
        #expect(machine.state.dials["host"] == nil)
        #expect(machine.state.abandoned[old]?.dial.waiters == [1])
        guard case .startDial(let fresh) = machine.handle(
            .join(key: "host", waiter: 2, stale: nil)).first
        else {
            Issue.record("a new acquirer should dial")
            return
        }
        #expect(fresh != old)
        // Its last waiter leaving cancels it.
        #expect(machine.handle(.cancelWaiter(key: "host", waiter: 1))
            == [.cancelWaiter(1), .cancelDial(old)])
        #expect(machine.state.abandoned.isEmpty)
    }

    @Test func anAbandonedDialLandingOnALiveConnectionChecksItFirst() {
        var machine = Machine()
        _ = machine.handle(.join(key: "host", waiter: 1, stale: nil))
        guard let old = machine.state.dials["host"]?.id else { return }
        _ = machine.handle(.abandonDial(key: "host"))
        _ = machine.handle(.join(key: "host", waiter: 2, stale: nil))
        guard let fresh = machine.state.dials["host"]?.id,
            case .distribute(let current, _) = machine.handle(
                .dialEnded(key: "host", dial: fresh, session: Stub())).first
        else { return }

        let late = Stub()
        guard case .checkCurrent(current, let placing, [1]) = machine.handle(
            .dialEnded(key: "host", dial: old, session: late)).first
        else {
            Issue.record("the live connection was not checked")
            return
        }
        var stillLive = machine
        #expect(stillLive.handle(
            .currentChecked(key: "host", placing: placing, waiters: [1], connected: true))
            == [.distribute(placing, waiters: [1])])
        #expect(stillLive.state.live["host"] == current)
        #expect(machine.handle(
            .currentChecked(key: "host", placing: placing, waiters: [1], connected: false))
            == [.distribute(placing, waiters: [1])])
        #expect(machine.state.live["host"] == placing)
    }

    // MARK: Keep, release, retire

    @Test func keepRetainsTheLiveConnectionOnce() {
        var machine = Machine()
        let live = withLive(&machine)
        #expect(machine.handle(.keep(key: "host", serial: live.serial)) == [.retainForKeep(live)])
        #expect(machine.handle(.keepRetained(key: "host", live, retained: true))
            == [.keepAnswered(true)])
        #expect(machine.state.kept["host"] == live)
        #expect(machine.handle(.keep(key: "host", serial: live.serial)) == [.keepAnswered(true)])
    }

    @Test func keepRefusesAnythingButTheLiveConnection() {
        var machine = Machine()
        let live = withLive(&machine)
        #expect(machine.handle(.keep(key: "host", serial: live.serial + 1)) == [.keepAnswered(false)])
        #expect(machine.handle(.keep(key: "other", serial: live.serial)) == [.keepAnswered(false)])
        #expect(machine.handle(.keepRetained(key: "host", live, retained: false))
            == [.keepAnswered(false)])
    }

    @Test func aKeepWhoseConnectionWasRetiredMeanwhileGivesItsHoldBack() {
        var machine = Machine()
        let live = withLive(&machine)
        _ = machine.handle(.retire(key: "host", serial: live.serial))
        #expect(machine.handle(.keepRetained(key: "host", live, retained: true))
            == [.release(live), .keepAnswered(false)])
        #expect(machine.state.kept.isEmpty)
    }

    @Test func aKeepThatLostTheRaceGivesItsExtraHoldBack() {
        var machine = Machine()
        let live = withLive(&machine)
        _ = machine.handle(.keepRetained(key: "host", live, retained: true))
        #expect(machine.handle(.keepRetained(key: "host", live, retained: true))
            == [.release(live), .keepAnswered(true)])
    }

    @Test func releaseKeptGivesTheHoldBackAndDropsTheHedge() {
        var machine = Machine()
        let live = withLive(&machine)
        _ = machine.handle(.keepRetained(key: "host", live, retained: true))
        _ = machine.handle(.join(key: "host", waiter: 50, stale: live.serial))
        guard let dial = machine.state.dials["host"]?.id else { return }
        _ = machine.handle(.dialEnded(key: "host", dial: dial, session: Stub()))
        #expect(machine.state.replacements["host"] != nil)

        #expect(machine.handle(.releaseKept(key: "host", serial: live.serial + 99)) == [])
        #expect(machine.handle(.releaseKept(key: "host", serial: live.serial)) == [.releaseLater(live)])
        #expect(machine.state.kept.isEmpty)
        #expect(machine.state.replacements.isEmpty)
        #expect(machine.state.live["host"] == live)
    }

    @Test func retireReleasesTheKeepAndAsksAboutTheHedge() {
        var machine = Machine()
        let live = withLive(&machine)
        _ = machine.handle(.keepRetained(key: "host", live, retained: true))
        _ = machine.handle(.join(key: "host", waiter: 50, stale: live.serial))
        guard let dial = machine.state.dials["host"]?.id,
            case .distribute(let hedge, _) = machine.handle(
                .dialEnded(key: "host", dial: dial, session: Stub())).first
        else { return }

        #expect(machine.handle(.retire(key: "host", serial: live.serial))
            == [.releaseLater(live), .checkReplacement(hedge)])
        #expect(machine.state.live.isEmpty)
        var dead = machine
        _ = dead.handle(.replacementChecked(key: "host", hedge, connected: false))
        #expect(dead.state.live.isEmpty)
        _ = machine.handle(.replacementChecked(key: "host", hedge, connected: true))
        #expect(machine.state.live["host"] == hedge)
    }

    @Test func retiringAnotherConnectionChangesNothing() {
        var machine = Machine()
        let live = withLive(&machine)
        let before = machine.state
        #expect(machine.handle(.retire(key: "host", serial: live.serial + 5)) == [])
        #expect(machine.state == before)
    }

    @Test func noTokenIsReused() {
        var machine = Machine()
        var tokens: Set<UInt64> = []
        for _ in 0..<5 {
            guard case .wait(let waiter) = machine.handle(.lookUp(key: "k", stale: nil)).first,
                case .startDial(let dial) = machine.handle(
                    .join(key: "k", waiter: waiter, stale: nil)).first,
                case .distribute(let entry, _) = machine.handle(
                    .dialEnded(key: "k", dial: dial, session: Stub())).first
            else {
                Issue.record("no dial")
                return
            }
            #expect(tokens.insert(waiter).inserted)
            #expect(tokens.insert(dial).inserted)
            #expect(tokens.insert(entry.serial).inserted)
            _ = machine.handle(.retire(key: "k", serial: entry.serial))
        }
    }
}
