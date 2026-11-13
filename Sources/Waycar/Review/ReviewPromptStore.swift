import Foundation
import Observation

/// Where Waycar's listing and its review page live. Settings › About opens
/// both: `writeReviewURL` as a plain link, never tied to anything else, and
/// `shareURL` through the share sheet.
enum AppStoreListing {
    static let writeReviewURL = URL(
        string: "https://apps.apple.com/app/id6815881853?action=write-review")

    /// The listing as Settings › About › Share Waycar shares it, tagged
    /// `ct=ref` like the site's links tag `ct=site` (`apps/web`,
    /// `src/data/links.ts`): App Analytics counts installs that started from
    /// the shared link under that one campaign. No personal invite code and
    /// no reward is attached; the tag is static, the same for every share.
    static let shareURL = URL(
        string: "https://apps.apple.com/app/id6815881853?pt=102524811&ct=ref&mt=8")
}

/// The device-local memory behind Apple's rating prompt: how much the user
/// has really used Waycar, when and for which version it last asked, and
/// whether an Agent they prompted just finished. Decisions are
/// `ReviewPromptPolicy`'s; this store only keeps the history and the clock.
///
/// Local only: UserDefaults, no Keychain, no network, no analytics.
@MainActor
@Observable
final class ReviewPromptStore {
    /// An Agent the phone prompted reached Done: the positive, idle moment
    /// the system prompt may follow.
    struct CompletedTurn: Equatable, Sendable {
        let agent: ConsoleAgent.ID
        let at: Date
    }

    static let defaultsKey = "com.otreva.waycar.reviewPrompt.state"

    private(set) var state: ReviewPromptState
    /// The newest finished turn not yet followed by an ask. In memory only.
    private(set) var completedTurn: CompletedTurn?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let clock: @MainActor () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let marketingVersion: String
    @ObservationIgnored private let policy: ReviewPromptPolicy
    @ObservationIgnored private let isDisabled: Bool

    /// - Parameter isDisabled: nothing is recorded and nothing is ever
    ///   eligible (the unit-test host and previews, like `NotificationAsk`).
    init(
        defaults: UserDefaults = .standard,
        clock: @escaping @MainActor () -> Date = { Date() },
        calendar: Calendar = .current,
        marketingVersion: String = ReviewPromptStore.currentMarketingVersion,
        policy: ReviewPromptPolicy = ReviewPromptPolicy(),
        isDisabled: Bool = false
    ) {
        self.defaults = defaults
        self.clock = clock
        self.calendar = calendar
        self.marketingVersion = marketingVersion
        self.policy = policy
        self.isDisabled = isDisabled
        state =
            defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(ReviewPromptState.self, from: $0) }
            ?? ReviewPromptState()
    }

    static var currentMarketingVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// The unit-test host, previews and demo screenshot runs never record or
    /// ask. (The demo composition installs no store at all, so its Console
    /// has nothing to feed either.)
    static var isSuppressedInThisProcess: Bool {
        #if DEBUG && targetEnvironment(simulator)
            if DemoScreenshotMode.isEnabled { return true }
        #endif
        return NotificationAsk.isSuppressedInThisProcess
    }

    /// Counts one successful phone-side action that shows real use. Callers
    /// invoke it only on success; a failed action never counts.
    func recordValueEvent() {
        guard !isDisabled else { return }
        state.recordValueEvent(at: clock(), calendar: calendar)
        save()
    }

    /// Whether the system prompt may be requested now. `blocked` is the
    /// caller's word that a Blocked Agent, sheet or error is up. Pure: safe
    /// to read from a view body.
    func shouldPrompt(blocked: Bool) -> Bool {
        guard !isDisabled else { return false }
        return policy.isEligible(
            state, marketingVersion: marketingVersion, blocked: blocked, now: clock(),
            calendar: calendar)
    }

    /// A clock set back since history was written must not hold the next ask
    /// off for months: a last ask or first use dated in the future counts as
    /// now, and event days in the future are dropped. `askIfDue` calls this
    /// before it decides; it saves only when something changed.
    func normalizeClock() {
        guard !isDisabled else { return }
        let now = clock()
        var changed = false
        if let last = state.lastPromptAt, last > now {
            state.lastPromptAt = now
            changed = true
        }
        if let first = state.firstEventAt, first > now {
            state.firstEventAt = now
            changed = true
        }
        if state.eventDays.contains(where: { $0 > now }) {
            state.eventDays.removeAll { $0 > now }
            changed = true
        }
        if changed { save() }
    }

    /// Call as the request goes out. Apple may silently not show it and caps
    /// it at three a year; either way this version asked and the next ask
    /// waits out `ReviewPromptPolicy.minimumDaysBetweenPrompts`.
    func didPrompt() {
        guard !isDisabled else { return }
        state.recordPrompt(at: clock(), version: marketingVersion)
        completedTurn = nil
        save()
    }

    /// An Agent the phone prompted reached Done.
    func noteTurnCompleted(agent: ConsoleAgent.ID) {
        guard !isDisabled else { return }
        completedTurn = CompletedTurn(agent: agent, at: clock())
    }

    /// Whether a recent finished turn makes this a positive moment for the
    /// user, who is on the Console (`viewing` nil) or on that turn's Agent.
    func isPositiveMoment(viewing agent: ConsoleAgent.ID?) -> Bool {
        guard let turn = completedTurn,
            clock().timeIntervalSince(turn.at) <= ReviewPromptPolicy.positiveMomentWindow
        else { return false }
        return agent == nil || agent == turn.agent
    }

    /// Whether something is in the user's way of the ask. `isGloballyBlocked`
    /// is the caller's word for the window-wide blockers (another modal,
    /// CarPlay). A Standing Failure or sync error counts only on the finished
    /// turn's Host, and a Blocked Agent only if it is that turn's Agent: a
    /// forgotten offline Host or Blocked Agent elsewhere must not suppress
    /// the ask for good.
    func isBlocked(
        isGloballyBlocked: Bool, failedHosts: Set<Host.ID>, blockedAgents: Set<ConsoleAgent.ID>
    ) -> Bool {
        if isGloballyBlocked { return true }
        guard let turn = completedTurn else { return false }
        return failedHosts.contains(turn.agent.hostID) || blockedAgents.contains(turn.agent)
    }

    /// After `settle`, asks Apple's system prompt to appear if the moment is
    /// still positive and the policy allows it. Everything is read again
    /// after the settle, and the ask is recorded before `request` runs, so a
    /// second window cannot ask for the same turn. While only `blocked` is in
    /// the way (a sheet UIKit presents is not something SwiftUI observes, so
    /// no one would call again), it re-checks every `retryInterval` until the
    /// blocker clears, the moment ends (`positiveMomentWindow`) or the task
    /// is cancelled, then asks once. Returns whether it asked; a caller still
    /// retries on a new trigger. Apple decides whether the sheet shows.
    /// Nothing here touches quota or Pro.
    @discardableResult
    func askIfDue(
        isActive: @MainActor () -> Bool,
        viewing: @MainActor () -> ConsoleAgent.ID?,
        blocked: @MainActor () -> Bool,
        settle: Duration = ReviewPromptPolicy.positiveMomentSettle,
        retryInterval: Duration = ReviewPromptPolicy.positiveMomentRetryInterval,
        sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        request: @MainActor () -> Void
    ) async -> Bool {
        guard !isDisabled, isActive(), isPositiveMoment(viewing: viewing()) else { return false }
        do { try await sleep(settle) } catch { return false }
        // The window bounds the polling by the clock; this bounds it if the
        // clock never moves forward.
        var checksLeft = Int(ReviewPromptPolicy.positiveMomentWindow / 2) + 1
        while checksLeft > 0 {
            checksLeft -= 1
            guard isActive(), isPositiveMoment(viewing: viewing()) else { return false }
            normalizeClock()
            // Ineligible even unblocked: waiting will not change that.
            guard shouldPrompt(blocked: false) else { return false }
            if blocked() {
                do { try await sleep(retryInterval) } catch { return false }
                continue
            }
            didPrompt()
            request()
            return true
        }
        return false
    }

    #if DEBUG || WAYCAR_ADMIN
    /// The window's own `requestReview` closure, registered by `ContentView`
    /// and cleared when it goes away, so the admin delayed ask uses the same
    /// closure as the production ask and never a stale one. Registration is
    /// token-owned so one iPad window closing cannot clear another's closure.
    @ObservationIgnored private var rootRequest: (token: UUID, call: @MainActor () -> Void)?

    @discardableResult
    func registerRootRequest(_ request: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        rootRequest = (token, request)
        return token
    }

    /// Clears the slot only if `token` still owns it.
    func unregisterRootRequest(token: UUID) {
        if rootRequest?.token == token { rootRequest = nil }
    }

    // MARK: Admin (Debug and WAYCAR_ADMIN builds only; callers check `allowsAdmin`)

    /// Forgets all history, as on a fresh install.
    func resetForAdmin() {
        state = ReviewPromptState()
        completedTurn = nil
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    /// Fills in history that meets every rule now. The ask still waits for
    /// an Agent the phone prompted to finish.
    func makeEligibleNowForAdmin() {
        let now = clock()
        var made = ReviewPromptState()
        let first = calendar.date(
            byAdding: .day, value: -(ReviewPromptPolicy.minimumDaysSinceFirstEvent + 1), to: now)
            ?? now
        made.valueEventCount = ReviewPromptPolicy.minimumValueEvents
        made.firstEventAt = first
        made.eventDays = Array(
            (0..<ReviewPromptPolicy.minimumDistinctDays).compactMap {
                calendar.date(byAdding: .day, value: -$0, to: now).map(calendar.startOfDay(for:))
            }.reversed())
        state = made
        save()
    }

    /// Raw edit of the value-event count (floor 0). Days and the first-event
    /// date stay as they are.
    func adjustValueEventsForAdmin(by delta: Int) {
        state.valueEventCount = max(0, state.valueEventCount + delta)
        save()
    }

    /// Zeroes the counter, days and first-event date; the gap and last-asked
    /// version stay.
    func resetCounterForAdmin() {
        state.valueEventCount = 0
        state.eventDays = []
        state.firstEventAt = nil
        save()
    }

    /// Forgets the last ask (date and version); the counters stay.
    func resetGapForAdmin() {
        state.lastPromptAt = nil
        state.lastPromptedVersion = nil
        save()
    }

    /// Waits `delay`, then calls the registered root request closure once,
    /// bypassing eligibility; counters and `didPrompt()` are untouched. The
    /// wait runs in its own Task, not tied to the Settings view. Returns
    /// that Task, or nil (and does nothing) when no closure is registered.
    /// The closure is read after the wait, so a refreshed one is used.
    @discardableResult
    func requestSheetForAdmin(
        after delay: Duration = .seconds(5),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) -> Task<Void, Never>? {
        guard rootRequest != nil else { return nil }
        return Task { @MainActor [weak self] in
            do { try await sleep(delay) } catch { return }
            self?.rootRequest?.call()
        }
    }
    #endif

    private func save() {
        defaults.set(try? JSONEncoder().encode(state), forKey: Self.defaultsKey)
    }
}
