import Foundation
import Testing

@testable import Waycar

@Suite("Review prompt policy")
struct ReviewPromptPolicyTests {
    private static let day: TimeInterval = 86_400
    private static let version = "1.2.0"
    fileprivate static let noonUTC: TimeInterval = {
        let base: Int = 1_800_000_000
        return TimeInterval(base - base % 86_400 + 43_200)
    }()

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    /// Noon UTC, so a day offset never lands on a day boundary.
    private static let now = Date(timeIntervalSince1970: noonUTC)

    private func daysAgo(_ days: Int) -> Date {
        Self.now.addingTimeInterval(-Double(days) * Self.day)
    }

    /// History that meets every rule at `now`, each at its exact minimum.
    private func eligibleState() -> ReviewPromptState {
        ReviewPromptState(
            valueEventCount: ReviewPromptPolicy.minimumValueEvents,
            eventDays: (0..<ReviewPromptPolicy.minimumDistinctDays).map {
                Self.calendar.startOfDay(for: daysAgo($0))
            },
            firstEventAt: daysAgo(ReviewPromptPolicy.minimumDaysSinceFirstEvent),
            lastPromptAt: nil,
            lastPromptedVersion: nil)
    }

    private func isEligible(
        _ state: ReviewPromptState, version: String = ReviewPromptPolicyTests.version,
        blocked: Bool = false
    ) -> Bool {
        ReviewPromptPolicy().isEligible(
            state, marketingVersion: version, blocked: blocked, now: Self.now,
            calendar: Self.calendar)
    }

    @Test func thresholdsAreTheAgreedOnes() {
        #expect(ReviewPromptPolicy.minimumValueEvents == 15)
        #expect(ReviewPromptPolicy.minimumDistinctDays == 3)
        #expect(ReviewPromptPolicy.minimumDaysSinceFirstEvent == 7)
        #expect(ReviewPromptPolicy.minimumDaysBetweenPrompts == 120)
    }

    @Test func meetingEveryRuleAtItsMinimumIsEligible() {
        #expect(isEligible(eligibleState()))
    }

    @Test func fourteenValueEventsAreNotEnoughFifteenAre() {
        var state = eligibleState()
        state.valueEventCount = 14
        #expect(!isEligible(state))
        state.valueEventCount = 15
        #expect(isEligible(state))
    }

    @Test func twoDistinctDaysAreNotEnoughThreeAre() {
        var state = eligibleState()
        state.eventDays.removeLast()
        #expect(state.eventDays.count == 2)
        #expect(!isEligible(state))
        state = eligibleState()
        #expect(state.eventDays.count == 3)
        #expect(isEligible(state))
    }

    @Test func sixDaysSinceTheFirstEventAreNotEnoughSevenAre() {
        var state = eligibleState()
        state.firstEventAt = daysAgo(6)
        #expect(!isEligible(state))
        state.firstEventAt = daysAgo(7)
        #expect(isEligible(state))
    }

    @Test func aVersionThatAlreadyAskedDoesNotAskAgain() {
        var state = eligibleState()
        state.lastPromptedVersion = Self.version
        state.lastPromptAt = daysAgo(ReviewPromptPolicy.minimumDaysBetweenPrompts + 30)
        #expect(!isEligible(state))
        #expect(isEligible(state, version: "1.3.0"))
    }

    @Test func oneHundredNineteenDaysSinceTheLastAskAreTooSoonOneTwentyAreNot() {
        var state = eligibleState()
        state.lastPromptedVersion = "1.1.0"
        state.lastPromptAt = daysAgo(119)
        #expect(!isEligible(state))
        state.lastPromptAt = daysAgo(120)
        #expect(isEligible(state))
    }

    @Test func aBlockedMomentIsNeverEligible() {
        #expect(!isEligible(eligibleState(), blocked: true))
    }

    @Test func aClockThatMovedBackwardsIsNeverEligible() {
        var state = eligibleState()
        state.firstEventAt = daysAgo(-1)
        #expect(!isEligible(state))
        state = eligibleState()
        state.lastPromptedVersion = "1.1.0"
        state.lastPromptAt = daysAgo(-1)
        #expect(!isEligible(state))
    }

    @Test func eventsAtTwoMinutesEitherSideOfMidnightAreTwoDays() {
        var state = ReviewPromptState()
        let midnight = Self.calendar.startOfDay(for: Self.now)
        state.recordValueEvent(at: midnight.addingTimeInterval(-60), calendar: Self.calendar)
        state.recordValueEvent(at: midnight.addingTimeInterval(60), calendar: Self.calendar)
        #expect(state.eventDays.count == 2)
    }

    @Test func twentyEventsOnOneDayAreNotEligibleAfterAWeek() {
        var state = ReviewPromptState()
        let start = daysAgo(7)
        for i in 0..<20 {
            state.recordValueEvent(at: start.addingTimeInterval(Double(i)), calendar: Self.calendar)
        }
        #expect(state.valueEventCount == 20)
        #expect(!isEligible(state))
    }

    @Test func calendarDaysAcrossADSTBoundaryAreCountedByCalendarNotSeconds() throws {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) throws -> Date {
            try #require(ny.date(from: DateComponents(year: y, month: m, day: d, hour: h)))
        }
        // US spring forward: 2026-03-08.
        let first = try date(2026, 3, 5)
        var state = ReviewPromptState(
            valueEventCount: 15,
            eventDays: [first, try date(2026, 3, 6), try date(2026, 3, 7)].map(ny.startOfDay(for:)),
            firstEventAt: first, lastPromptAt: nil, lastPromptedVersion: nil)
        func eligible(at now: Date) -> Bool {
            ReviewPromptPolicy().isEligible(
                state, marketingVersion: "1.2.0", blocked: false, now: now, calendar: ny)
        }
        #expect(eligible(at: try date(2026, 3, 12)))  // 7 calendar days (167 h)
        #expect(!eligible(at: try date(2026, 3, 11, 11)))  // just under
        #expect(!eligible(at: try date(2026, 3, 11)))  // 6 days

        // 120-day gap across the same boundary.
        state.lastPromptedVersion = "1.1.0"
        state.lastPromptAt = first
        #expect(eligible(at: try date(2026, 7, 3)))  // 120 calendar days
        #expect(!eligible(at: try date(2026, 7, 2)))  // 119
    }

    @Test func recordingEventsCountsDistinctCalendarDaysAndKeepsOnlyWhatDecides() {
        var state = ReviewPromptState()
        let calendar = Self.calendar
        state.recordValueEvent(at: daysAgo(5), calendar: calendar)
        state.recordValueEvent(at: daysAgo(5).addingTimeInterval(60), calendar: calendar)
        #expect(state.valueEventCount == 2)
        #expect(state.eventDays.count == 1)
        #expect(state.firstEventAt == daysAgo(5))

        for offset in [4, 3, 2, 1] { state.recordValueEvent(at: daysAgo(offset), calendar: calendar) }
        #expect(state.valueEventCount == 6)
        #expect(state.eventDays.count == ReviewPromptPolicy.minimumDistinctDays)
        #expect(state.firstEventAt == daysAgo(5))
    }
}

@MainActor
@Suite("Review prompt store")
struct ReviewPromptStoreTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: ReviewPromptPolicyTests.noonUTC)

        func advance(days: Int) {
            now = now.addingTimeInterval(Double(days) * 86_400)
        }
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    /// An isolated suite and the call that removes its plist again.
    private func makeDefaults() throws -> (defaults: UserDefaults, cleanup: () -> Void) {
        let name = "review-prompt-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    private func makeStore(
        _ defaults: UserDefaults, clock: Clock, version: String = "1.2.0"
    ) -> ReviewPromptStore {
        ReviewPromptStore(
            defaults: defaults, clock: { clock.now }, calendar: Self.calendar,
            marketingVersion: version)
    }

    /// Value events on three days, then a week of waiting.
    private func useForAWhile(_ store: ReviewPromptStore, clock: Clock) {
        for _ in 0..<5 { store.recordValueEvent() }
        clock.advance(days: 1)
        for _ in 0..<5 { store.recordValueEvent() }
        clock.advance(days: 1)
        for _ in 0..<5 { store.recordValueEvent() }
        clock.advance(days: 5)
    }

    @Test func historySurvivesARelaunch() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let first = makeStore(defaults, clock: clock)
        useForAWhile(first, clock: clock)
        #expect(first.shouldPrompt(blocked: false))

        let relaunched = makeStore(defaults, clock: clock)
        #expect(relaunched.state == first.state)
        #expect(relaunched.shouldPrompt(blocked: false))
        #expect(!relaunched.shouldPrompt(blocked: true))
    }

    @Test func promptingSuppressesTheSameVersionAndTheNextOneUntilTheGapHasPassed() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let first = makeStore(defaults, clock: clock)
        useForAWhile(first, clock: clock)
        #expect(first.shouldPrompt(blocked: false))

        first.didPrompt()
        #expect(!first.shouldPrompt(blocked: false))

        // Persisted: a relaunch of the same version does not ask again.
        #expect(!makeStore(defaults, clock: clock).shouldPrompt(blocked: false))

        // A new version inside the gap still waits...
        clock.advance(days: ReviewPromptPolicy.minimumDaysBetweenPrompts - 1)
        #expect(!makeStore(defaults, clock: clock, version: "1.3.0").shouldPrompt(blocked: false))
        // ...but the old use does not carry over: it needs fresh use too.
        clock.advance(days: 1)
        #expect(!makeStore(defaults, clock: clock, version: "1.3.0").shouldPrompt(blocked: false))
        let later = makeStore(defaults, clock: clock, version: "1.3.0")
        useForAWhile(later, clock: clock)
        #expect(later.shouldPrompt(blocked: false))
        #expect(!makeStore(defaults, clock: clock, version: "1.2.0").shouldPrompt(blocked: false))
    }

    @Test func eachAskNeedsFreshUseAndTheResetSurvivesARelaunch() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let first = makeStore(defaults, clock: clock)
        useForAWhile(first, clock: clock)
        first.didPrompt()
        #expect(first.state.valueEventCount == 0)
        #expect(first.state.eventDays.isEmpty)
        #expect(first.state.firstEventAt == nil)

        clock.advance(days: 130)
        let relaunched = makeStore(defaults, clock: clock, version: "1.3.0")
        #expect(relaunched.state.valueEventCount == 0)
        #expect(relaunched.state.eventDays.isEmpty)
        #expect(relaunched.state.firstEventAt == nil)
        #expect(!relaunched.shouldPrompt(blocked: false))

        // The first event after the ask is fresh event 1.
        relaunched.recordValueEvent()
        #expect(relaunched.state.valueEventCount == 1)
        #expect(relaunched.state.firstEventAt == clock.now)
        #expect(relaunched.state.eventDays.count == 1)

        // Many events on one day, a week on: still short of three days.
        for _ in 0..<20 { relaunched.recordValueEvent() }
        clock.advance(days: 8)
        #expect(!relaunched.shouldPrompt(blocked: false))

        // Fresh use on three days, the first event 7+ days back, is enough.
        relaunched.recordValueEvent()
        clock.advance(days: 1)
        relaunched.recordValueEvent()
        #expect(relaunched.shouldPrompt(blocked: false))
    }

    @Test func aDisabledStoreNeitherRecordsNorAsks() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let disabled = ReviewPromptStore(
            defaults: defaults, clock: { clock.now }, calendar: Self.calendar,
            marketingVersion: "1.2.0", isDisabled: true)
        for _ in 0..<20 { disabled.recordValueEvent() }
        clock.advance(days: 30)

        #expect(disabled.state.valueEventCount == 0)
        #expect(!disabled.shouldPrompt(blocked: false))
        #expect(defaults.data(forKey: ReviewPromptStore.defaultsKey) == nil)
    }

    @Test func aFinishedTurnIsAPositiveMomentOnTheConsoleOrThatAgentOnlyForAWhile() throws {
        let clock = Clock()
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let prompts = makeStore(defaults, clock: clock)
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")
        let other = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p2")
        #expect(!prompts.isPositiveMoment(viewing: nil))

        prompts.noteTurnCompleted(agent: agent)
        #expect(prompts.isPositiveMoment(viewing: nil))
        #expect(prompts.isPositiveMoment(viewing: agent))
        #expect(!prompts.isPositiveMoment(viewing: other))

        clock.now = clock.now.addingTimeInterval(ReviewPromptPolicy.positiveMomentWindow + 1)
        #expect(!prompts.isPositiveMoment(viewing: nil))
    }

    @Test func theMomentIsPositiveAtWindowMinusOneAndExactlyWindowNotAfter() throws {
        let clock = Clock()
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let prompts = makeStore(defaults, clock: clock)
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")
        prompts.noteTurnCompleted(agent: agent)
        let start = clock.now
        clock.now = start.addingTimeInterval(ReviewPromptPolicy.positiveMomentWindow - 1)
        #expect(prompts.isPositiveMoment(viewing: agent))
        clock.now = start.addingTimeInterval(ReviewPromptPolicy.positiveMomentWindow)
        #expect(prompts.isPositiveMoment(viewing: agent))
        clock.now = start.addingTimeInterval(ReviewPromptPolicy.positiveMomentWindow + 1)
        #expect(!prompts.isPositiveMoment(viewing: agent))
    }

    @Test func promptingClearsTheCompletedTurn() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let prompts = makeStore(defaults, clock: Clock())
        prompts.noteTurnCompleted(agent: ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1"))
        #expect(prompts.completedTurn != nil)
        prompts.didPrompt()
        #expect(prompts.completedTurn == nil)
        #expect(prompts.state.lastPromptedVersion == "1.2.0")
    }

    @Test func aDisabledStoreWritesNothingOnPromptOrCompletedTurn() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let disabled = ReviewPromptStore(
            defaults: defaults, clock: { Date() }, calendar: Self.calendar,
            marketingVersion: "1.2.0", isDisabled: true)
        disabled.didPrompt()
        disabled.noteTurnCompleted(agent: ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1"))
        #expect(disabled.state == ReviewPromptState())
        #expect(disabled.completedTurn == nil)
        #expect(defaults.data(forKey: ReviewPromptStore.defaultsKey) == nil)
    }

    @Test func garbagePersistedBytesDecodeToFreshState() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(Data([0xde, 0xad, 0xbe, 0xef]), forKey: ReviewPromptStore.defaultsKey)
        let prompts = makeStore(defaults, clock: Clock())
        #expect(prompts.state == ReviewPromptState())
    }

    @Test func aClockSetBackAfterAPromptWaitsOneGapFromNowNotMonths() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let prompts = makeStore(defaults, clock: clock)
        useForAWhile(prompts, clock: clock)
        prompts.didPrompt()
        // The clock jumps 30 days back, then forward 120: unclamped, the
        // ask would wait until 30 days past that.
        clock.advance(days: -30)
        let later = makeStore(defaults, clock: clock, version: "1.3.0")
        later.normalizeClock()
        #expect(!later.shouldPrompt(blocked: false))
        clock.advance(days: ReviewPromptPolicy.minimumDaysBetweenPrompts)
        // The ask reset the counters: it also needs fresh use.
        #expect(!later.shouldPrompt(blocked: false))
        useForAWhile(later, clock: clock)
        #expect(later.shouldPrompt(blocked: false))
    }

    @Test func shouldPromptNeverMutatesOrSavesEvenWithAClockSetBack() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let prompts = makeStore(defaults, clock: clock)
        useForAWhile(prompts, clock: clock)
        prompts.didPrompt()
        clock.advance(days: -30)
        let later = makeStore(defaults, clock: clock, version: "1.3.0")
        let stateBefore = later.state
        let bytesBefore = defaults.data(forKey: ReviewPromptStore.defaultsKey)
        _ = later.shouldPrompt(blocked: false)
        #expect(later.state == stateBefore)
        #expect(defaults.data(forKey: ReviewPromptStore.defaultsKey) == bytesBefore)
        // Only normalizeClock clamps.
        later.normalizeClock()
        #expect(later.state != stateBefore)
    }

    @Test func aClockSetBackClampsFirstEventAndDropsFutureEventDays() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let prompts = makeStore(defaults, clock: clock)
        let start = clock.now
        prompts.recordValueEvent()
        clock.advance(days: 10)
        prompts.recordValueEvent()
        clock.now = start
        let later = makeStore(defaults, clock: clock)
        #expect(later.state.eventDays.contains { $0 > start })
        later.normalizeClock()
        #expect(later.state.firstEventAt.map { $0 <= start } == true)
        #expect(later.state.eventDays.allSatisfy { $0 <= start })
        #expect(!later.state.eventDays.isEmpty)
        // The clamp persisted.
        let reloaded = makeStore(defaults, clock: clock)
        #expect(reloaded.state == later.state)
    }

    @Test func aFutureFirstEventIsClampedToNow() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let start = clock.now
        clock.advance(days: 20)
        let prompts = makeStore(defaults, clock: clock)
        prompts.recordValueEvent()
        clock.now = start
        let later = makeStore(defaults, clock: clock)
        #expect(later.state.firstEventAt.map { $0 > start } == true)
        later.normalizeClock()
        #expect(later.state.firstEventAt == start)
        #expect(makeStore(defaults, clock: clock).state.firstEventAt == start)
    }

    @Test func normalizeClockWritesNothingWhenNothingIsInTheFuture() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let prompts = makeStore(defaults, clock: clock)
        useForAWhile(prompts, clock: clock)
        let later = makeStore(defaults, clock: clock)
        let stateBefore = later.state
        let bytesBefore = defaults.data(forKey: ReviewPromptStore.defaultsKey)
        later.normalizeClock()
        #expect(later.state == stateBefore)
        #expect(defaults.data(forKey: ReviewPromptStore.defaultsKey) == bytesBefore)
    }

    // MARK: askIfDue

    private final class Ask {
        var requests = 0
        var blocked = false
        var blockedChecks = 0
        var active = true
        var viewing: ConsoleAgent.ID?
        /// Every injected sleep, in order: the settle, then each retry.
        var sleeps: [Duration] = []
        /// Runs on each injected sleep, standing in for time passing.
        var onSleep: (Ask) -> Void = { _ in }
    }

    private func ask(_ store: ReviewPromptStore, _ state: Ask) async -> Bool {
        await store.askIfDue(
            isActive: { state.active }, viewing: { state.viewing },
            blocked: {
                state.blockedChecks += 1
                return state.blocked
            },
            settle: .milliseconds(1), retryInterval: .milliseconds(2),
            sleep: { duration in
                state.sleeps.append(duration)
                state.onSleep(state)
                try Task.checkCancellation()
            },
            request: { state.requests += 1 })
    }

    /// An eligible store with one just-finished turn.
    private func eligibleStore(
        _ defaults: UserDefaults, clock: Clock, agent: ConsoleAgent.ID, disabled: Bool = false
    ) -> ReviewPromptStore {
        let store = ReviewPromptStore(
            defaults: defaults, clock: { clock.now }, calendar: Self.calendar,
            marketingVersion: "1.2.0", isDisabled: disabled)
        useForAWhile(store, clock: clock)
        store.noteTurnCompleted(agent: agent)
        return store
    }

    @Test func asksOnceAfterAFinishedTurnAndNeverTwiceForIt() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")
        let store = eligibleStore(defaults, clock: Clock(), agent: agent)
        let state = Ask()
        #expect(await ask(store, state))
        #expect(!(await ask(store, state)))
        #expect(state.requests == 1)
    }

    @Test func aBlockedAskPollsThenAsksOnceWhenTheBlockerClears() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")
        let store = eligibleStore(defaults, clock: clock, agent: agent)
        let state = Ask()
        state.blocked = true
        // A sheet UIKit presents closes after the third retry; time passes
        // with every sleep.
        state.onSleep = { state in
            clock.now = clock.now.addingTimeInterval(2)
            if state.sleeps.count == 4 { state.blocked = false }
        }
        #expect(await ask(store, state))
        #expect(state.requests == 1)
        #expect(state.sleeps == [.milliseconds(1)] + Array(repeating: .milliseconds(2), count: 3))
        // Asked once for that turn: another run for it does nothing.
        #expect(!(await ask(store, state)))
        #expect(state.requests == 1)
    }

    @Test func aBlockerThatNeverClearsStopsPollingWhenTheWindowEndsAndNeverAsks() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")
        let store = eligibleStore(defaults, clock: clock, agent: agent)
        let state = Ask()
        state.blocked = true
        state.onSleep = { _ in clock.now = clock.now.addingTimeInterval(60) }
        #expect(!(await ask(store, state)))
        #expect(state.requests == 0)
        // Settle, then one retry per minute while the moment holds (60 s
        // through exactly 600 s).
        #expect(state.sleeps.count == 1 + 10)
        #expect(store.state.lastPromptAt == nil)
    }

    @Test func cancellingABlockedAskStopsPollingAndAsksNothing() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")
        let store = eligibleStore(defaults, clock: Clock(), agent: agent)
        let state = Ask()
        state.blocked = true
        // `.task(id:)` cancels the old run when its trigger changes: here on
        // the second retry.
        state.onSleep = { state in
            if state.sleeps.count == 3 { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let asked = await Task { @MainActor in await ask(store, state) }.value
        #expect(!asked)
        #expect(state.requests == 0)
        #expect(state.sleeps.count == 3)
        // The turn is still pending for the run that follows.
        #expect(store.completedTurn != nil)
        state.onSleep = { _ in }
        state.blocked = false
        #expect(await ask(store, state))
        #expect(state.requests == 1)
    }

    @Test func movingAwayFromTheTurnMidPollEndsTheRunWithoutAsking() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")
        let store = eligibleStore(defaults, clock: clock, agent: agent)
        let state = Ask()
        state.blocked = true
        state.onSleep = { state in
            clock.now = clock.now.addingTimeInterval(2)
            if state.sleeps.count == 2 {
                state.viewing = ConsoleAgent.ID(hostID: UUID(), paneID: "w9:p9")
            }
        }
        #expect(!(await ask(store, state)))
        #expect(state.requests == 0)
        #expect(state.sleeps.count == 2)
    }

    @Test func noAskOutsideTheWindowOrWhenNotViewingTheConsoleOrThatAgent() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")

        // Baseline: the same eligible store inside the window does ask.
        let baseline = eligibleStore(defaults, clock: clock, agent: agent)
        let baselineState = Ask()
        #expect(await ask(baseline, baselineState))
        #expect(baselineState.requests == 1)

        let (otherDefaults, otherCleanup) = try makeDefaults()
        defer { otherCleanup() }
        let store = eligibleStore(otherDefaults, clock: clock, agent: agent)
        let state = Ask()
        state.viewing = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p2")
        #expect(!(await ask(store, state)))
        state.viewing = nil
        state.active = false
        #expect(!(await ask(store, state)))
        state.active = true
        clock.now = clock.now.addingTimeInterval(ReviewPromptPolicy.positiveMomentWindow + 1)
        #expect(!(await ask(store, state)))
        #expect(state.requests == 0)
    }

    @Test func noAskWithoutAFinishedTurnOrWhenIneligible() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = makeStore(defaults, clock: Clock())
        let state = Ask()
        store.noteTurnCompleted(agent: ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1"))
        #expect(!(await ask(store, state)))  // no history yet
        #expect(state.requests == 0)
    }

    @Test func anEligibleStoreWithNoFinishedTurnNeverSleepsOrAsks() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let store = makeStore(defaults, clock: clock)
        useForAWhile(store, clock: clock)
        #expect(store.shouldPrompt(blocked: false))
        #expect(store.completedTurn == nil)
        let state = Ask()
        #expect(!(await ask(store, state)))
        #expect(state.requests == 0)
        #expect(state.sleeps.isEmpty)
    }

    @Test func aBlockedIneligibleStoreSettlesOnceAndNeverPollsTheWindow() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = makeStore(defaults, clock: Clock())
        store.noteTurnCompleted(agent: ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1"))
        #expect(!store.shouldPrompt(blocked: false))
        let state = Ask()
        state.blocked = true
        #expect(!(await ask(store, state)))
        #expect(state.requests == 0)
        #expect(state.sleeps == [.milliseconds(1)])
        #expect(state.blockedChecks == 0)
    }

    @Test func theAskIsRecordedBeforeTheRequestGoesOut() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")
        let store = eligibleStore(defaults, clock: Clock(), agent: agent)
        var requested = 0
        let asked = await store.askIfDue(
            isActive: { true }, viewing: { nil }, blocked: { false },
            settle: .milliseconds(1), retryInterval: .milliseconds(2),
            sleep: { _ in },
            request: {
                requested += 1
                #expect(store.state.lastPromptedVersion != nil)
                #expect(store.completedTurn == nil)
            })
        #expect(asked)
        #expect(requested == 1)
    }

    @Test func aDisabledStoreNeverAsks() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")
        let store = eligibleStore(defaults, clock: Clock(), agent: agent, disabled: true)
        let state = Ask()
        #expect(!(await ask(store, state)))
        #expect(state.requests == 0)
    }

    // MARK: isBlocked

    @Test func onlyTheTurnsOwnHostFailureOrBlockedAgentBlocks() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")
        let otherAgent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p2")
        let sameHostAgent = ConsoleAgent.ID(hostID: agent.hostID, paneID: "w1:p3")
        let store = makeStore(defaults, clock: Clock())
        store.noteTurnCompleted(agent: agent)

        func blocked(
            global: Bool = false, hosts: Set<Host.ID> = [], agents: Set<ConsoleAgent.ID> = []
        ) -> Bool {
            store.isBlocked(isGloballyBlocked: global, failedHosts: hosts, blockedAgents: agents)
        }
        #expect(!blocked())
        #expect(!blocked(hosts: [otherAgent.hostID]))
        #expect(!blocked(agents: [otherAgent, sameHostAgent]))
        #expect(blocked(hosts: [agent.hostID]))
        #expect(blocked(agents: [agent]))
        #expect(blocked(global: true))
    }

    @Test func withNoCompletedTurnFailedHostsAndBlockedAgentsDoNotBlock() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = makeStore(defaults, clock: Clock())
        #expect(store.completedTurn == nil)
        let agent = ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1")
        #expect(
            !store.isBlocked(
                isGloballyBlocked: false, failedHosts: [agent.hostID], blockedAgents: [agent]))
        #expect(
            store.isBlocked(
                isGloballyBlocked: true, failedHosts: [agent.hostID], blockedAgents: [agent]))
    }

    // MARK: Admin controls

    #if DEBUG || WAYCAR_ADMIN
    @Test func adminStepperPersistsFloorsAtZeroAndLeavesDaysAndFirstAlone() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let store = makeStore(defaults, clock: clock)
        store.recordValueEvent()
        let days = store.state.eventDays
        let first = store.state.firstEventAt
        store.adjustValueEventsForAdmin(by: 1)
        store.adjustValueEventsForAdmin(by: 1)
        #expect(store.state.valueEventCount == 3)
        #expect(makeStore(defaults, clock: clock).state.valueEventCount == 3)
        for _ in 0..<5 { store.adjustValueEventsForAdmin(by: -1) }
        #expect(store.state.valueEventCount == 0)
        #expect(makeStore(defaults, clock: clock).state.valueEventCount == 0)
        #expect(store.state.eventDays == days)
        #expect(store.state.firstEventAt == first)
    }

    @Test func adminResetCounterKeepsTheGapAndVersion() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let store = makeStore(defaults, clock: clock)
        store.recordValueEvent()
        store.didPrompt()
        store.recordValueEvent()
        let asked = store.state.lastPromptAt
        store.resetCounterForAdmin()
        let reloaded = makeStore(defaults, clock: clock)
        #expect(reloaded.state.valueEventCount == 0)
        #expect(reloaded.state.eventDays.isEmpty)
        #expect(reloaded.state.firstEventAt == nil)
        #expect(reloaded.state.lastPromptAt == asked)
        #expect(reloaded.state.lastPromptedVersion == "1.2.0")
    }

    @Test func adminResetGapKeepsTheCounters() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let store = makeStore(defaults, clock: clock)
        store.didPrompt()
        store.recordValueEvent()
        store.recordValueEvent()
        let days = store.state.eventDays
        let first = store.state.firstEventAt
        store.resetGapForAdmin()
        let reloaded = makeStore(defaults, clock: clock)
        #expect(reloaded.state.lastPromptAt == nil)
        #expect(reloaded.state.lastPromptedVersion == nil)
        #expect(reloaded.state.valueEventCount == 2)
        #expect(reloaded.state.eventDays == days)
        #expect(reloaded.state.firstEventAt == first)
    }

    @Test func adminMakeEligibleNowMeetsEveryRuleAndResetClearsEverything() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let clock = Clock()
        let store = makeStore(defaults, clock: clock)
        store.makeEligibleNowForAdmin()
        store.noteTurnCompleted(agent: ConsoleAgent.ID(hostID: UUID(), paneID: "w1:p1"))
        #expect(store.shouldPrompt(blocked: false))
        #expect(store.state.eventDays.count == 3)
        let first = try #require(store.state.firstEventAt)
        #expect(
            clock.now.timeIntervalSince(first)
                >= Double(ReviewPromptPolicy.minimumDaysSinceFirstEvent) * 86_400)

        store.resetForAdmin()
        #expect(store.state == ReviewPromptState())
        #expect(defaults.data(forKey: ReviewPromptStore.defaultsKey) == nil)
    }
    #endif
}
