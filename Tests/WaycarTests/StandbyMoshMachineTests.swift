import Foundation
import Testing

@testable import Waycar

/// `StandbyMoshMachine`: the standbys and attach bootstraps per target
/// (MOSH-03). The owner suite is `StandbyMoshStoreTests`.
@Suite("Standby mosh machine")
struct StandbyMoshMachineTests {
    typealias Machine = StandbyMoshMachine

    private let host = UUID()
    private var key: Machine.Key { .init(hostID: host, backend: .herdr, target: .agentPane("w1:p1")) }
    private var other: Machine.Key { .init(hostID: host, backend: .herdr, target: .agentPane("w1:p2")) }
    private let start = ContinuousClock.now
    private var standby: StandbyMosh {
        StandbyMosh(bootstrap: MoshFlowFixture.standbyBootstrap, origin: .speculative, createdAt: start)
    }
    private var renewed: StandbyMosh {
        StandbyMosh(
            bootstrap: MoshFlowFixture.laterBootstrap, origin: .speculative,
            createdAt: start.advanced(by: .seconds(40)))
    }
    private var ready: Machine { Machine().after([.prepare(key), .prepared(key, token: 1, standby)]) }
    private var bootstrapping: Machine { Machine().after([.claimAttachBootstrap(key, now: start)]) }

    // MARK: Preparing

    @Test func aPreparationStartsUnderAFreshToken() {
        var machine = Machine()
        #expect(machine.handle(.prepare(key)) == [.startPreparation(key, token: 1)])
        #expect(machine.state[key] == .preparing(token: 1))
        #expect(machine.preparation(for: key) == 1)
    }

    @Test func aSecondPreparationJoinsTheFirst() {
        var machine = Machine().after([.prepare(key)])
        #expect(machine.handle(.prepare(key)) == [.joinPreparation(token: 1)])
        var refreshing = ready.after([.prepare(key)])
        #expect(refreshing.handle(.prepare(key)) == [.joinPreparation(token: 2)])
    }

    @Test func aPreparationIsRefusedWhileAnAttachBootstraps() {
        var machine = bootstrapping
        #expect(machine.handle(.prepare(key)) == [.refusePreparation])
        #expect(machine.state[key] == .bootstrapping(count: 1))
    }

    @Test func aPreparedStandbyIsReady() {
        var machine = Machine().after([.prepare(key)])
        #expect(machine.handle(.prepared(key, token: 1, standby)).isEmpty)
        #expect(machine.state[key] == .ready(standby))
    }

    @Test func aFailedPreparationLeavesNothing() {
        var machine = Machine().after([.prepare(key)])
        #expect(machine.handle(.prepared(key, token: 1, nil)).isEmpty)
        #expect(machine.state[key] == nil)
    }

    @Test func aRenewalKeepsTheStandbyUntilItsReplacementIsReady() {
        var machine = ready
        #expect(machine.handle(.prepare(key)) == [.startPreparation(key, token: 2)])
        #expect(machine.state[key] == .refreshing(standby, token: 2))
        #expect(machine.readyStandby(for: key) == standby)
        _ = machine.handle(.prepared(key, token: 2, renewed))
        #expect(machine.state[key] == .ready(renewed))
    }

    @Test func aFailedRenewalKeepsTheStandby() {
        var machine = ready.after([.prepare(key)])
        _ = machine.handle(.prepared(key, token: 2, nil))
        #expect(machine.state[key] == .ready(standby))
    }

    @Test func aStalePreparationIsIgnored() {
        var replaced = Machine().after([.prepare(key), .discard(key), .prepare(key)])
        #expect(replaced.handle(.prepared(key, token: 1, standby)).isEmpty)
        #expect(replaced.state[key] == .preparing(token: 2))
        var dropped = Machine().after([.prepare(key), .discard(key)])
        _ = dropped.handle(.prepared(key, token: 1, standby))
        #expect(dropped.state[key] == nil)
    }

    // MARK: Taking

    @Test func aStandbyIsTakenOnce() {
        var machine = ready
        #expect(machine.handle(.take(key, now: start)) == [.handOut(standby)])
        #expect(machine.handle(.take(key, now: start)) == [.handOut(nil)])
        #expect(machine.state[key] == nil)
    }

    @Test func aStaleStandbyIsDroppedWhenTaken() {
        var machine = ready
        #expect(machine.handle(.take(key, now: start.advanced(by: Machine.maxAge))) == [.handOut(nil)])
        #expect(machine.state[key] == nil)
        #expect(Machine.isFresh(standby, now: start.advanced(by: .seconds(49))))
    }

    @Test func takingDuringARenewalLeavesThePreparation() {
        var machine = ready.after([.prepare(key)])
        #expect(machine.handle(.take(key, now: start)) == [.handOut(standby)])
        #expect(machine.state[key] == .preparing(token: 2))
    }

    // MARK: Attach bootstraps

    @Test func aClaimTakesAReadyStandbyInsteadOfBootstrapping() {
        var machine = ready
        #expect(machine.handle(.claimAttachBootstrap(key, now: start)) == [.handOut(standby)])
        #expect(machine.attachBootstraps(for: key) == 0)
    }

    @Test func aClaimWithoutAStandbyCountsABootstrap() {
        var machine = Machine()
        #expect(machine.handle(.claimAttachBootstrap(key, now: start)) == [.handOut(nil)])
        #expect(machine.handle(.claimAttachBootstrap(key, now: start)) == [.handOut(nil)])
        #expect(machine.state[key] == .bootstrapping(count: 2))
        #expect(machine.hasAttachBootstrap(on: host))
    }

    @Test func aClaimDropsAStaleStandbyAndBootstraps() {
        var machine = ready
        #expect(machine.handle(.claimAttachBootstrap(key, now: start.advanced(by: .seconds(50)))) == [.handOut(nil)])
        #expect(machine.state[key] == .bootstrapping(count: 1))
    }

    @Test func finishingTheHostsLastBootstrapSettlesIt() {
        var machine = Machine().after([
            .claimAttachBootstrap(key, now: start), .claimAttachBootstrap(key, now: start),
            .claimAttachBootstrap(other, now: start),
        ])
        #expect(machine.handle(.finishAttachBootstrap(key)).isEmpty)
        #expect(machine.handle(.finishAttachBootstrap(other)).isEmpty)
        #expect(machine.handle(.finishAttachBootstrap(key)) == [.attachBootstrapsSettled(host)])
        #expect(!machine.hasAttachBootstrap(on: host))
        #expect(machine.handle(.finishAttachBootstrap(key)).isEmpty, "nothing to finish")
    }

    /// The pre-existing overlap: a preparation started just before an
    /// attach's claim runs beside its bootstrap.
    @Test func aPreparationBesideABootstrapIsKeptUntilBothEnd() {
        var machine = Machine().after([.prepare(key), .claimAttachBootstrap(key, now: start)])
        #expect(machine.state[key] == .bootstrappingBesidePreparation(count: 1, token: 1))
        #expect(machine.handle(.prepare(key)) == [.joinPreparation(token: 1)])
        _ = machine.handle(.prepared(key, token: 1, standby))
        #expect(machine.state[key] == .bootstrappingBesideStandby(count: 1, standby))
        #expect(machine.handle(.prepare(key)) == [.refusePreparation])
        #expect(machine.handle(.finishAttachBootstrap(key)) == [.attachBootstrapsSettled(host)])
        #expect(machine.state[key] == .ready(standby))

        var failed = Machine().after([.prepare(key), .claimAttachBootstrap(key, now: start)])
        _ = failed.handle(.prepared(key, token: 1, nil))
        #expect(failed.state[key] == .bootstrapping(count: 1))
        var finishedFirst = Machine().after([.prepare(key), .claimAttachBootstrap(key, now: start)])
        #expect(finishedFirst.handle(.finishAttachBootstrap(key)) == [.attachBootstrapsSettled(host)])
        #expect(finishedFirst.state[key] == .preparing(token: 1))
    }

    @Test func takingBesideABootstrapLeavesTheBootstrap() {
        var machine = Machine().after([
            .prepare(key), .claimAttachBootstrap(key, now: start), .prepared(key, token: 1, standby),
        ])
        #expect(machine.handle(.take(key, now: start)) == [.handOut(standby)])
        #expect(machine.state[key] == .bootstrapping(count: 1))
    }

    // MARK: Discarding

    @Test func discardingATargetCancelsItsPreparationAndKeepsItsBootstraps() {
        var preparing = Machine().after([.prepare(key)])
        #expect(preparing.handle(.discard(key)) == [.cancelPreparation(token: 1)])
        #expect(preparing.state[key] == nil)
        var refreshing = ready.after([.prepare(key)])
        #expect(refreshing.handle(.discard(key)) == [.cancelPreparation(token: 2)])
        #expect(refreshing.state[key] == nil)
        var readyOnly = ready
        #expect(readyOnly.handle(.discard(key)).isEmpty)
        #expect(readyOnly.state[key] == nil)
        var beside = Machine().after([.prepare(key), .claimAttachBootstrap(key, now: start)])
        #expect(beside.handle(.discard(key)) == [.cancelPreparation(token: 1)])
        #expect(beside.state[key] == .bootstrapping(count: 1))
        var besideStandby = Machine().after([
            .prepare(key), .claimAttachBootstrap(key, now: start), .prepared(key, token: 1, standby),
        ])
        #expect(besideStandby.handle(.discard(key)).isEmpty)
        #expect(besideStandby.state[key] == .bootstrapping(count: 1))
        var bootstrapOnly = bootstrapping
        #expect(bootstrapOnly.handle(.discard(key)).isEmpty)
        #expect(bootstrapOnly.state[key] == .bootstrapping(count: 1))
    }

    @Test func discardingAHostLeavesOtherHosts() {
        let elsewhere = Machine.Key(hostID: UUID(), backend: .herdr, target: .agentPane("w1:p1"))
        var machine = ready.after([.prepare(other), .prepare(elsewhere)])
        #expect(machine.handle(.discardHost(host)) == [.cancelPreparation(token: 2)])
        #expect(machine.state[key] == nil)
        #expect(machine.state[other] == nil)
        #expect(machine.state[elsewhere] == .preparing(token: 3))
    }
}
