import Foundation
import Testing

@testable import Waycar

/// `EventsConnectionMachine` (HERDR-02): one test per transition, plus the
/// stale and ignored cases. The owner suites are `EventsSessionResilienceTests`
/// (kept connections, hedges) and `EventsSessionConnectFlowTests` (attach
/// first, generations).
@Suite("EventsConnectionMachine")
struct EventsConnectionMachineTests {
    private static let kept = PooledConnectionID(key: "host", serial: 1)
    private static let fresh = PooledConnectionID(key: "host", serial: 2)
    private let start = ContinuousClock.now

    private var proven: EventsConnectionMachine {
        EventsConnectionMachine().after([.offer, .install(generation: 0, connection: Self.kept)])
    }

    @Test func aFreshSessionHasNoConnection() {
        let machine = EventsConnectionMachine()
        #expect(machine.stage == .absent)
        #expect(machine.state.published == 0)
        #expect(machine.keepable == nil)
        #expect(machine.hasNoTrustedConnection)
    }

    @Test func anOfferReservesTheNextGenerationAndTrustsTheConnection() {
        var machine = EventsConnectionMachine().after([.suspect])
        #expect(machine.handle(.offer) == [.offer(generation: 0)])
        #expect(machine.stage == .provisional)
        #expect(!machine.isDistrusted)
        #expect(machine.handle(.offer) == [.offer(generation: 1)])
        #expect(machine.state.provisional == 1)
        // Observers see nothing until a ping proves one.
        #expect(machine.state.published == 0)
    }

    @Test func aReplacementReservesAGenerationOfItsOwn() {
        var machine = proven
        #expect(machine.handle(.reserve) == [.reserved(generation: 1)])
        #expect(machine.handle(.offer) == [.offer(generation: 2)])
    }

    @Test func installingPublishesTheProvenGeneration() {
        var machine = EventsConnectionMachine().after([.offer])
        #expect(
            machine.handle(.install(generation: 0, connection: Self.kept))
                == [.forgetProvisional, .publish(generation: 0)])
        #expect(machine.stage == .proven)
        #expect(
            machine.state.installed
                == EventsConnectionMachine.Installed(generation: 0, connection: Self.kept))
        #expect(machine.state.published == 0)
        #expect(machine.keepable == Self.kept)
        #expect(!machine.hasNoTrustedConnection)
    }

    @Test func installingAReplacementWithNothingOfferedOnlyPublishes() {
        var machine = proven.after([.reserve])
        #expect(
            machine.handle(.install(generation: 1, connection: Self.fresh))
                == [.publish(generation: 1)])
        #expect(machine.state.published == 1)
    }

    @Test func aFailedPingBurnsItsGeneration() {
        var machine = EventsConnectionMachine().after([.offer])
        #expect(machine.handle(.provisionalFailed(generation: 0)) == [.forgetProvisional])
        #expect(machine.stage == .absent)
        #expect(machine.handle(.offer) == [.offer(generation: 1)])
    }

    @Test func anOlderOffersFailureLeavesTheNewerOne() {
        var machine = EventsConnectionMachine().after([.offer, .offer])
        #expect(machine.handle(.provisionalFailed(generation: 0)) == [])
        #expect(machine.state.provisional == 1)
    }

    @Test func aRequestThatFoundTheLinkDeadDistrustsAndDropsIt() {
        var machine = proven
        #expect(machine.handle(.distrust) == [.uninstall])
        #expect(machine.stage == .distrusted)
        #expect(machine.state.installed == nil)
        #expect(machine.keepable == nil)
        #expect(machine.hasNoTrustedConnection)
    }

    @Test func aSwallowedRequestDistrustsTheInstalledConnection() {
        var machine = proven
        #expect(machine.handle(.suspect) == [])
        #expect(machine.stage == .distrusted)
        #expect(machine.state.installed != nil)
        #expect(machine.keepable == nil)
        #expect(machine.hasNoTrustedConnection)
    }

    @Test func aConnectionFoundDeadIsDropped() {
        var machine = proven
        #expect(machine.handle(.drop) == [.uninstall])
        #expect(machine.stage == .absent)
        #expect(machine.state.published == 0)
    }

    @Test func anUnpooledConnectionIsNotKeepable() {
        let machine = EventsConnectionMachine().after([
            .offer, .install(generation: 0, connection: nil),
        ])
        #expect(machine.keepable == nil)
    }

    @Test func aSuspensionKeepsTheConnection() {
        var machine = proven.after([.windDownStarted, .woundDown])
        #expect(machine.handle(.keep(id: Self.kept, since: start)) == [])
        #expect(machine.stage == .kept)
    }

    @Test func aKeptConnectionIsClaimedForItsProbe() {
        var machine = EventsConnectionMachine().after([.keep(id: Self.kept, since: start)])
        #expect(
            machine.handle(.takeKept(now: start + LivenessTiming.keptConnectionMaxAge))
                == [.probeKept(Self.kept)])
        #expect(machine.state.kept == nil)
        #expect(machine.handle(.takeKept(now: start)) == [])
    }

    @Test func aConnectionKeptTooLongIsRetiredUnprobed() {
        var machine = EventsConnectionMachine().after([.keep(id: Self.kept, since: start)])
        #expect(
            machine.handle(
                .takeKept(now: start + LivenessTiming.keptConnectionMaxAge + .milliseconds(1)))
                == [.retireKept(Self.kept)])
        #expect(machine.stage == .absent)
    }

    @Test func aProbeHoldsItsHandoutUntilItSettles() {
        var machine = EventsConnectionMachine().after([.offer])
        #expect(machine.handle(.probeOffered(generation: 0)) == [.holdProbe])
        #expect(machine.ridesKept(generation: 0))
        #expect(machine.handle(.probeSettled) == [.forgetProbe])
        #expect(machine.state.probe == nil)
        // Terminals on it still rode the kept connection.
        #expect(machine.ridesKept(generation: 0))
    }

    @Test func aLostProbeDropsItsHandoutOnce() {
        var machine = EventsConnectionMachine().after([.offer, .probeOffered(generation: 0)])
        #expect(machine.handle(.probeAbandoned) == [.forgetProbe])
        #expect(machine.handle(.probeAbandoned) == [])
        #expect(machine.handle(.provisionalFailed(generation: 0)) == [.forgetProvisional])
    }

    @Test func endingReleasesTheKeptConnection() {
        var machine = EventsConnectionMachine().after([.keep(id: Self.kept, since: start)])
        #expect(machine.handle(.end) == [.releaseKept(Self.kept)])
        #expect(machine.handle(.end) == [])
    }

    @Test func theTeardownDropsWhatIsInstalledAndOffered() {
        var machine = proven.after([.offer])
        #expect(machine.handle(.windDownStarted) == [.uninstall, .forgetProvisional])
        #expect(machine.state.installed == nil)
        #expect(machine.state.provisional == nil)
        var empty = EventsConnectionMachine()
        #expect(empty.handle(.windDownStarted) == [])
    }

    @Test func distrustLastsUntilTheTeardownEnds() {
        var machine = proven.after([.suspect, .windDownStarted])
        #expect(machine.isDistrusted)
        #expect(machine.handle(.woundDown) == [])
        #expect(!machine.isDistrusted)
        #expect(machine.state.published == 0)
    }
}
