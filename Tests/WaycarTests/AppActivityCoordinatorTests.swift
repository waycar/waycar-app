import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("App activity coordinator")
struct AppActivityCoordinatorTests {
    /// The absence is measured on a clock rather than inferred from `phase`,
    /// because iOS freezes the process for exactly the absences that matter:
    /// the grace timer never fires, no `.suspended` is published, and the app
    /// comes back believing it never left (#141). Only a clock survives that.
    @Test func aMultiMinuteFrozenAbsenceMayHaveSuspended() async throws {
        var clock = ContinuousClock.now
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(20),
            granter: FakeBackgroundExecutionGranter(),
            now: { clock })

        coordinator.didEnterBackground(.phone)
        // Longer than the grace, but the process was frozen throughout, so
        // the phase never left `.active` and no teardown ever ran.
        clock = clock.advanced(by: .seconds(180))
        coordinator.didBecomeActive(.phone)

        #expect(coordinator.phase == .active)
        #expect(coordinator.lastAbsenceMayHaveSuspended)
        #if DEBUG
        #expect(coordinator.lastAbsenceDuration == .seconds(180))
        #endif
    }

    /// Deliberately configured away from `defaultGracePeriod`, and with an
    /// absence that straddles the two: 30s is past the 20s default but short
    /// of this coordinator's own 60s. A comparison written against the static
    /// default instead of the injected value passes every other test in this
    /// suite and fails only here.
    @Test func theInjectedBackgroundGracePeriodDefinesTheBoundary() async throws {
        var clock = ContinuousClock.now
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(60),
            granter: FakeBackgroundExecutionGranter(),
            now: { clock })
        #expect(AppActivityCoordinator.defaultGracePeriod == .seconds(20))

        coordinator.didEnterBackground(.phone)
        clock = clock.advanced(by: .seconds(30))
        coordinator.didBecomeActive(.phone)

        #expect(!coordinator.lastAbsenceMayHaveSuspended)
    }

    /// Two consecutive edges report their own durations rather than retaining
    /// or classifying the previous one.
    @Test func theBackgroundGraceBoundaryIsInclusiveAndResets() async throws {
        var clock = ContinuousClock.now
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(20),
            granter: FakeBackgroundExecutionGranter(),
            now: { clock })

        coordinator.didEnterBackground(.phone)
        clock = clock.advanced(by: .seconds(20))
        coordinator.didBecomeActive(.phone)
        #expect(coordinator.lastAbsenceMayHaveSuspended)

        coordinator.didEnterBackground(.phone)
        clock = clock.advanced(by: .milliseconds(19_999))
        coordinator.didBecomeActive(.phone)
        #expect(!coordinator.lastAbsenceMayHaveSuspended)
    }

    /// A foreground return with no backgrounding behind it — the app becoming
    /// active after a Control Center pull-down, say — is not an absence, and
    /// must not cost the Attach terminal a reattach.
    @Test func anActivationWithNoBackgroundingIsNotAnAbsence() async throws {
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(20), granter: FakeBackgroundExecutionGranter())

        coordinator.didBecomeActive(.phone)

        #expect(!coordinator.lastAbsenceMayHaveSuspended)
    }

    @Test func backgroundingStaysActiveForTheGracePeriod() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: granter)

        coordinator.didEnterBackground(.phone)

        try await Task.sleep(for: .milliseconds(20))
        #expect(coordinator.phase == .active)
        #expect(granter.liveTokenCount == 1)
    }

    @Test func returningInsideTheGracePeriodNeverSuspends() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: granter)

        coordinator.didEnterBackground(.phone)
        coordinator.didBecomeActive(.phone)

        try await Task.sleep(for: .milliseconds(20))
        #expect(coordinator.phase == .active)
        // The assertion goes back as soon as it is no longer needed;
        // holding one while in the foreground is pure battery waste.
        #expect(granter.liveTokenCount == 0)
        #expect(granter.beginCount == 1)
    }

    @Test func aBounceTheGracePeriodAbsorbsStillCountsAsAReturn() async throws {
        // The edge #141 loses: the round trip never leaves `.active`, so a
        // SwiftUI `onChange` on the phase observes nothing and the screens
        // that must prove their channels on return are never told. The
        // counter is what they observe instead, so it has to move here.
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: granter)
        #expect(coordinator.activationCount == 0)

        coordinator.didEnterBackground(.phone)
        coordinator.didBecomeActive(.phone)

        #expect(coordinator.phase == .active)
        #expect(coordinator.activationCount == 1)

        coordinator.didEnterBackground(.phone)
        coordinator.didBecomeActive(.phone)
        #expect(coordinator.activationCount == 2)
    }

    @Test func gracePeriodElapsingSuspends() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .milliseconds(20), granter: granter)

        coordinator.didEnterBackground(.phone)

        try await waitUntil("the grace period should expire into a suspension") {
            coordinator.phase == .suspended
        }
        // Still held: the teardown it just triggered needs the time.
        #expect(granter.liveTokenCount == 1)

        coordinator.didFinishSuspending()
        #expect(granter.liveTokenCount == 0)
    }

    @Test func foregroundingAfterASuspensionReactivates() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .milliseconds(20), granter: granter)

        coordinator.didEnterBackground(.phone)
        try await waitUntil("the grace period should expire into a suspension") {
            coordinator.phase == .suspended
        }
        coordinator.didBecomeActive(.phone)

        #expect(coordinator.phase == .active)
        #expect(granter.liveTokenCount == 0)
        #expect(coordinator.lastAbsenceMayHaveSuspended)
    }

    @Test func systemReclaimingItsTimeSuspendsAndReturnsTheAssertion() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: granter)

        coordinator.didEnterBackground(.phone)
        granter.expireAll()

        try await waitUntil("expiration should force a suspension") {
            coordinator.phase == .suspended
        }
        // Holding an expired assertion is how an app gets killed, so it is
        // returned before the teardown rather than after it.
        #expect(granter.liveTokenCount == 0)

        coordinator.didBecomeActive(.phone)
        #expect(coordinator.lastAbsenceMayHaveSuspended)
    }

    @Test func anOldExpirationCannotSuspendForegroundSourcesOrANewerGrant() throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(gracePeriod: .seconds(60), granter: granter)
        coordinator.didEnterBackground(.phone)
        let oldExpiration = try #require(granter.retainedExpirations.first)

        coordinator.didBecomeActive(.phone)
        oldExpiration()
        #expect(coordinator.phase == .active)
        #expect(!coordinator.hasBackgroundTimeForTeardown)

        coordinator.didEnterBackground(.phone)
        oldExpiration()
        #expect(coordinator.phase == .active)
        #expect(granter.liveTokenCount == 1)
        #expect(granter.beginCount == 2)
        coordinator.didBecomeActive(.phone)
    }

    @Test func refusedBackgroundTimeSuspendsImmediately() {
        let granter = FakeBackgroundExecutionGranter()
        granter.grantsTime = false
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: granter)

        coordinator.didEnterBackground(.phone)

        #expect(coordinator.phase == .suspended)
        #expect(granter.liveTokenCount == 0)

        coordinator.didBecomeActive(.phone)
        #expect(coordinator.lastAbsenceMayHaveSuspended)
    }

    @Test func repeatedBackgroundingDoesNotStackAssertions() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: granter)

        coordinator.didEnterBackground(.phone)
        coordinator.didEnterBackground(.phone)

        #expect(granter.beginCount == 1)
        #expect(granter.liveTokenCount == 1)
    }

    /// The transitions are delivered as events, not inferred from the phase.
    /// A whole background→foreground round trip can land between two looks at
    /// `phase` — it happens while the app is in the background drawing
    /// nothing — and a consumer that compares values would see no change at
    /// all, tearing nothing down and resuming nothing (#142).
    @Test func everyTransitionIsDeliveredEvenWhenNothingWatchesThePhase() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .milliseconds(20), granter: granter)
        var events = coordinator.events.makeAsyncIterator()

        coordinator.didEnterBackground(.phone)
        try await waitUntil("the grace period should expire into a suspension") {
            coordinator.phase == .suspended
        }
        coordinator.didBecomeActive(.phone)

        #expect(coordinator.phase == .active)
        #expect(await events.next() == .suspended)
        #expect(await events.next() == .activated)
    }

    /// A return the grace period absorbed still reports an activation: the
    /// connection may have died while the app was away, and nothing else in
    /// the app is going to ask it.
    @Test func aBounceInsideTheGracePeriodStillReportsAnActivation() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: granter)
        var events = coordinator.events.makeAsyncIterator()

        coordinator.didEnterBackground(.phone)
        coordinator.didBecomeActive(.phone)

        #expect(await events.next() == .activated)
    }

    /// The phone locks with Waycar on the car's screen: the CarPlay scene
    /// keeps the app active, so no grace period, no background assertion
    /// and no teardown start (docs/design/carplay.md §6).
    @Test func aForegroundCarPlaySceneHoldsTheAppPastThePhonesBackgrounding() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .milliseconds(20), granter: granter)

        coordinator.didBecomeActive(.phone)
        coordinator.didBecomeActive(.carPlay)
        coordinator.didEnterBackground(.phone)
        try await Task.sleep(for: .milliseconds(80))

        #expect(coordinator.phase == .active)
        #expect(granter.beginCount == 0)

        // The car leaves too: now the grace period runs, and expires.
        coordinator.didEnterBackground(.carPlay)
        #expect(granter.beginCount == 1)
        try await waitUntil("the grace period should expire into a suspension") {
            coordinator.phase == .suspended
        }
    }

    /// A CarPlay-only launch (no window ever active) holds the app the same
    /// way, and the car coming back cancels a grace period already running.
    @Test func theCarPlaySceneAloneHoldsAndItsReturnCancelsTheGracePeriod() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .milliseconds(60), granter: granter)
        var events = coordinator.events.makeAsyncIterator()

        coordinator.didBecomeActive(.carPlay)
        #expect(await events.next() == .activated)
        // The phone window scene reporting background changes nothing.
        coordinator.didEnterBackground(.phone)
        #expect(granter.beginCount == 0)

        coordinator.didEnterBackground(.carPlay)
        #expect(granter.liveTokenCount == 1)
        coordinator.didBecomeActive(.carPlay)
        #expect(granter.liveTokenCount == 0)
        #expect(await events.next() == .activated)
        try await Task.sleep(for: .milliseconds(120))
        #expect(coordinator.phase == .active)
    }

    /// CarPlay connecting while a window is already on screen is no return:
    /// nothing was away, so nothing is re-proved. A window coming back is
    /// always one, for the windows' attach terminals.
    @Test func onlyAPhoneEdgeCountsAsAReturnWhileAnotherSourceHolds() {
        let coordinator = AppActivityCoordinator(
            gracePeriod: .seconds(60), granter: FakeBackgroundExecutionGranter())

        coordinator.didBecomeActive(.phone)
        #expect(coordinator.activationCount == 1)
        coordinator.didBecomeActive(.carPlay)
        #expect(coordinator.activationCount == 1)
        coordinator.didEnterBackground(.phone)
        coordinator.didBecomeActive(.phone)
        #expect(coordinator.activationCount == 2)
        #expect(!coordinator.lastAbsenceMayHaveSuspended)
    }

    /// The watch leaving while CarPlay still shows Waycar suspends nothing;
    /// only the last source out starts the grace period.
    @Test func theWatchLeavingWhileCarPlayHoldsKeepsTheAppActive() {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(gracePeriod: .seconds(60), granter: granter)

        coordinator.didBecomeActive(.watch)
        coordinator.didBecomeActive(.carPlay)
        coordinator.didEnterBackground(.watch)
        #expect(coordinator.phase == .active)
        #expect(granter.beginCount == 0)

        coordinator.didEnterBackground(.carPlay)
        #expect(granter.beginCount == 1)
    }

    /// A source reporting active again while it holds (a watch request while
    /// the watch app is reachable) holds once: its one leave lets go.
    @Test(arguments: [AppActivitySource.watch, .carPlay])
    func aRepeatedActivationHoldsOnce(source: AppActivitySource) {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(gracePeriod: .seconds(60), granter: granter)

        coordinator.didBecomeActive(source)
        coordinator.didBecomeActive(source)
        coordinator.didEnterBackground(source)
        #expect(granter.beginCount == 1)
        #expect(granter.liveTokenCount == 1)
    }

    /// Work ahead of the teardown (standby mosh, #105) gets background time
    /// only from a grace-timer suspension still holding its assertion: at
    /// most the asked limit, never the teardown's reserve.
    @Test func aGraceSuspensionLendsBackgroundTimeAheadOfTheTeardown() async throws {
        let granter = FakeBackgroundExecutionGranter()
        let coordinator = AppActivityCoordinator(
            gracePeriod: .milliseconds(20), granter: granter)
        #expect(
            coordinator.backgroundTimeBeforeTeardown(upTo: .seconds(3), leaving: .seconds(5)) == nil,
            "an active app has nothing ahead of a teardown")

        coordinator.didEnterBackground(.phone)
        try await waitUntil("the grace period should expire into a suspension") {
            coordinator.phase == .suspended
        }
        // The Hosts' quiesce may wait on the network now (#105).
        #expect(coordinator.hasBackgroundTimeForTeardown)
        granter.timeRemaining = .seconds(10)
        #expect(
            coordinator.backgroundTimeBeforeTeardown(upTo: .seconds(3), leaving: .seconds(5))
                == .seconds(3))
        granter.timeRemaining = .seconds(6)
        #expect(
            coordinator.backgroundTimeBeforeTeardown(upTo: .seconds(3), leaving: .seconds(5))
                == .seconds(1))
        granter.timeRemaining = .seconds(4)
        #expect(
            coordinator.backgroundTimeBeforeTeardown(upTo: .seconds(3), leaving: .seconds(5)) == nil,
            "the teardown's reserve is never lent")

        granter.timeRemaining = .seconds(10)
        coordinator.didBecomeActive(.phone)
        #expect(
            coordinator.backgroundTimeBeforeTeardown(upTo: .seconds(3), leaving: .seconds(5)) == nil,
            "a return ends the suspension the time was for")
        #expect(!coordinator.hasBackgroundTimeForTeardown)
    }

    /// Expiration handlers must not wait on the network (TN2277): neither an
    /// expired assertion nor a refused one lends any time, however much the
    /// system still reports.
    @Test func expirationAndRefusalLendNoBackgroundTime() async throws {
        let expiring = FakeBackgroundExecutionGranter()
        let expired = AppActivityCoordinator(gracePeriod: .seconds(60), granter: expiring)
        expired.didEnterBackground(.phone)
        expiring.expireAll()
        try await waitUntil("expiration should force a suspension") {
            expired.phase == .suspended
        }
        #expect(expired.backgroundTimeBeforeTeardown(upTo: .seconds(3), leaving: .seconds(5)) == nil)
        // The Hosts' quiesce must stay local there (#105).
        #expect(!expired.hasBackgroundTimeForTeardown)

        let refusing = FakeBackgroundExecutionGranter()
        refusing.grantsTime = false
        let refused = AppActivityCoordinator(gracePeriod: .seconds(60), granter: refusing)
        refused.didEnterBackground(.phone)
        #expect(refused.phase == .suspended)
        #expect(refused.backgroundTimeBeforeTeardown(upTo: .seconds(3), leaving: .seconds(5)) == nil)
        #expect(!refused.hasBackgroundTimeForTeardown)
    }
}

@MainActor
private final class FakeBackgroundExecutionGranter: BackgroundExecutionGranting {
    var grantsTime = true
    private(set) var beginCount = 0
    private var live: [BackgroundExecutionToken: @MainActor @Sendable () -> Void] = [:]
    private var nextRawValue = 1
    private(set) var retainedExpirations: [@MainActor @Sendable () -> Void] = []
    /// What the system reports as left of the background time.
    var timeRemaining: Duration = .seconds(10)

    var liveTokenCount: Int { live.count }
    var backgroundTimeRemaining: Duration { timeRemaining }

    func begin(
        onExpiration: @escaping @MainActor @Sendable () -> Void
    ) -> BackgroundExecutionToken? {
        guard grantsTime else { return nil }
        beginCount += 1
        let token = BackgroundExecutionToken(rawValue: nextRawValue)
        nextRawValue += 1
        live[token] = onExpiration
        retainedExpirations.append(onExpiration)
        return token
    }

    func end(_ token: BackgroundExecutionToken) {
        live[token] = nil
    }

    /// Stands in for the system reclaiming its background time.
    func expireAll() {
        for handler in live.values {
            handler()
        }
    }
}
