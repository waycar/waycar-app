import Foundation
import Testing

@testable import Waycar

/// The in-app foreground banner (#77): Blocked/Done transitions observed on
/// the Console's live Agent list must hold before announcing (anti-flap),
/// never repeat for an unchanged status (dedupe), stay silent for the
/// presented Agent and for Hosts whose notification preferences are unknown
/// or off (fail closed), and auto-dismiss after a few seconds. The silenced
/// foreground push's Agent Summary rewrites or re-presents its banner.
///
/// Pane ids here stand in for live herdr addresses, so they use the observed
/// alphanumeric `w…:p…` family (uppercase included). The store only compares
/// them as opaque strings.
@MainActor
@Suite("Agent notification banner store")
struct AgentNotificationBannerStoreTests {
    private let hostID = UUID()

    /// Mutable fixtures the store's injected closures read at fire time.
    @MainActor
    private final class World {
        var presentedAgent: ConsoleAgent.ID?
        var triggers: [UUID: NotificationTriggerPreferences] = [:]
        var soundCount = 0
        var carVoice = CarVoiceActivity.State()
    }

    private let world = World()

    private func makeStore(
        holdDuration: Duration = .milliseconds(20),
        dismissDelay: Duration = .seconds(5)
    ) -> AgentNotificationBannerStore {
        let world = world
        return AgentNotificationBannerStore(
            holdDuration: holdDuration,
            dismissDelay: dismissDelay,
            replayInterval: .milliseconds(10),
            presentedAgent: { world.presentedAgent },
            triggers: { world.triggers[$0] },
            playSound: { world.soundCount += 1 },
            carVoice: { world.carVoice })
    }

    private func agent(
        _ paneID: String, _ status: AgentStatus,
        hostID: UUID? = nil, kind: String = "claude", workspaceLabel: String? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID ?? self.hostID, hostName: "mac-studio",
            agent: Agent(.fixture(paneID: paneID, status: status, kind: kind)),
            workspaceLabel: workspaceLabel,
            repositoryCheckout: nil)
    }

    /// Lets any (wrongly) scheduled hold elapse so silence is meaningful:
    /// three times the 20 ms default hold.
    private func waitPastHold() async throws {
        try await Task.sleep(for: .milliseconds(60))
    }

    /// The decrypted foreground push `willPresent` hands over.
    private func push(
        _ paneID: String, _ status: AgentStatus, summary: String?,
        kind: String = "claude", project: String? = nil, stamped timestamp: Date = Date(),
        reply: String? = nil
    ) -> (target: AgentNotificationTarget, payload: NotificationPayload) {
        (
            AgentNotificationTarget(hostID: hostID, paneID: paneID),
            NotificationPayload(
                paneID: paneID, agentKind: kind, status: status, timestamp: timestamp,
                project: project, summary: summary, reply: reply)
        )
    }

    private func deliver(
        _ push: (target: AgentNotificationTarget, payload: NotificationPayload),
        to store: AgentNotificationBannerStore
    ) {
        store.pushDidArrive(target: push.target, payload: push.payload)
    }

    /// The CarPlay voice defers the in-app banner and its sound: the
    /// conversation's own Agent, and every Agent while the car speaks. Once
    /// the voice stops quieting, the deferred banner replays.
    @Test func theCarPlayVoiceDefersTheBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        world.carVoice.agent = ConsoleAgent.ID(hostID: hostID, paneID: "w1:pA")
        world.carVoice.speaking = 1
        let store = makeStore()
        store.agentsDidChange([agent("w1:pA", .working), agent("w1:pB", .working)])
        store.agentsDidChange([agent("w1:pA", .done), agent("w1:pB", .blocked)])
        try await waitPastHold()
        #expect(store.banner == nil)
        #expect(world.soundCount == 0)

        // Speech ends; the turn's Agent stays quiet, the other replays.
        world.carVoice.speaking = 0
        try await waitUntil("the other Agent's banner replays once the car is quiet") {
            store.banner?.target.paneID == "w1:pB"
        }
        #expect(world.soundCount == 1)

        // The turn ends; the turn's Agent's Done replays too.
        world.carVoice = CarVoiceActivity.State()
        try await waitUntil("the turn's Agent's banner replays after the turn") {
            store.banner?.target.paneID == "w1:pA"
        }
        #expect(world.soundCount == 2)
    }

    /// A deferred banner whose pane left the status before the turn ended
    /// is dropped, not replayed stale.
    @Test func aDeferredBannerForAStatusLeftIsDropped() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        world.carVoice.speaking = 1
        let store = makeStore()
        store.agentsDidChange([agent("w1:pB", .working)])
        store.agentsDidChange([agent("w1:pB", .blocked)])
        try await waitPastHold()
        store.agentsDidChange([agent("w1:pB", .working)])
        world.carVoice = CarVoiceActivity.State()
        try await waitPastHold()
        #expect(store.banner == nil)
        #expect(world.soundCount == 0)
    }

    // MARK: Transition detection and copy

    @Test func blockedTransitionBannersAfterTheHoldWithThePushCopy() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        #expect(store.banner == nil, "the transition must hold before announcing")

        try await waitUntil("the banner should show once the hold elapses") {
            store.banner != nil
        }
        #expect(
            store.banner
                == AgentNotificationBanner(
                    target: AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"),
                    status: .blocked,
                    alert: AgentNotificationAlert(
                        title: "Claude", body: "Blocked — waiting for input")))
        #expect(world.soundCount == 1)
    }

    /// The banner shares the push renderer, so a known workspace leads the
    /// same way it does on a push.
    @Test func aKnownWorkspaceLeadsTheBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working, workspaceLabel: "Caterm")])

        store.agentsDidChange([agent("wV:p1", .blocked, workspaceLabel: "Caterm")])

        try await waitUntil("the banner should show") { store.banner != nil }
        #expect(
            store.banner?.alert
                == AgentNotificationAlert(
                    title: "Caterm · Claude", body: "Blocked — waiting for input"))
    }

    @Test func doneTransitionBannersWithTheDoneCopy() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working, kind: "codex")])

        store.agentsDidChange([agent("wV:p1", .done, kind: "codex")])

        try await waitUntil("the Done banner should show") { store.banner != nil }
        #expect(
            store.banner?.alert
                == AgentNotificationAlert(title: "Codex", body: "Done"))
    }

    /// The first sight of a pane is baseline, not a transition: a killed-state
    /// launch must not banner every already-Blocked Agent it syncs.
    @Test func firstSightOfABlockedAgentIsBaselineNotATransition() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()

        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitPastHold()
        #expect(store.banner == nil)
        #expect(world.soundCount == 0)
    }

    @Test func workingAndIdleTransitionsNeverBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .idle)])

        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .idle)])

        try await waitPastHold()
        #expect(store.banner == nil)
    }

    // MARK: Anti-flap

    @Test func aTransitionThatDoesNotHoldNeverBanners() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        store.agentsDidChange([agent("wV:p1", .working)])

        try await waitPastHold()
        #expect(store.banner == nil)
    }

    /// A flap that settles back into Blocked banners exactly once, from the
    /// re-entry that finally held.
    @Test func aFlapThatSettlesBannersOnce() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitUntil("the settled transition should banner") { store.banner != nil }
        #expect(world.soundCount == 1)
    }

    @Test func aVanishedPaneCancelsItsPendingBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        store.agentsDidChange([])
        // Reappearing is a fresh baseline, not a transition.
        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitPastHold()
        #expect(store.banner == nil)
    }

    // MARK: Same-status dedupe

    @Test func anUnchangedStatusNeverRepeatsTheBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .blocked)])
        try await waitUntil("the first banner should show") { store.banner != nil }

        store.dismiss()
        store.agentsDidChange([agent("wV:p1", .blocked)])
        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitPastHold()
        #expect(store.banner == nil)
        #expect(world.soundCount == 1)
    }

    // MARK: Suppression and preferences

    /// Suppression is decided at fire time: navigating into the Agent while
    /// its transition is still holding silences the banner.
    @Test func thePresentedAgentsOwnTransitionNeverBanners() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])
        world.presentedAgent = ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")

        try await waitPastHold()
        #expect(store.banner == nil)
        #expect(world.soundCount == 0)
    }

    @Test func anotherAgentsTransitionBannersWhileOneIsPresented() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        world.presentedAgent = ConsoleAgent.ID(hostID: hostID, paneID: "w1:pT")
        let store = makeStore()
        store.agentsDidChange([agent("w1:pT", .working), agent("wV:p1", .working)])

        store.agentsDidChange([agent("w1:pT", .working), agent("wV:p1", .blocked)])

        try await waitUntil("the other pane's banner should show") { store.banner != nil }
        #expect(store.banner?.target == AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))
    }

    /// Unknown preferences (Host unreachable, never registered, still loading)
    /// fail closed, matching the plugin's missing-flag semantics.
    @Test func unknownPreferencesFailClosed() async throws {
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitPastHold()
        #expect(store.banner == nil)
    }

    @Test func aDisabledDoneFlagSkipsDoneButKeepsBlocked() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences(blocked: true, done: false)
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .done)])
        try await waitPastHold()
        #expect(store.banner == nil)

        store.agentsDidChange([agent("wV:p1", .blocked)])
        try await waitUntil("the Blocked banner should still show") { store.banner != nil }
    }

    // MARK: Presentation lifecycle

    @Test func theBannerAutoDismissesAfterItsDelay() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore(dismissDelay: .milliseconds(40))
        store.agentsDidChange([agent("wV:p1", .working)])

        store.agentsDidChange([agent("wV:p1", .blocked)])

        try await waitUntil("the banner should show") { store.banner != nil }
        try await waitUntil("the banner should auto-dismiss") { store.banner == nil }
    }

    @Test func aNewerBannerReplacesTheCurrentOne() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("w1:pT", .working), agent("wR:pC", .working)])

        store.agentsDidChange([agent("w1:pT", .blocked), agent("wR:pC", .working)])
        try await waitUntil("the first banner should show") {
            store.banner?.target.paneID == "w1:pT"
        }

        store.agentsDidChange([agent("w1:pT", .blocked), agent("wR:pC", .done)])
        try await waitUntil("the newer banner should replace it") {
            store.banner?.target.paneID == "wR:pC"
        }
    }

    @Test func dismissClearsTheBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .blocked)])
        try await waitUntil("the banner should show") { store.banner != nil }

        store.dismiss()

        #expect(store.banner == nil)
    }

    // MARK: Agent Summary from the foreground push

    /// The live banner outruns the plugin's summary; its push rewrites the
    /// showing banner in place (same title, no second sound) and restarts
    /// the dismissal wait so the summary can be read.
    @Test func aSummaryPushRewritesTheShowingBannerAndExtendsIt() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore(dismissDelay: .seconds(1))
        store.agentsDidChange([agent("wV:p1", .working, workspaceLabel: "Caterm")])
        store.agentsDidChange([agent("wV:p1", .done, workspaceLabel: "Caterm")])
        try await waitUntil("the live banner should show") { store.banner != nil }
        #expect(store.banner?.alert.body == "Done")

        try await Task.sleep(for: .milliseconds(600))
        deliver(push("wV:p1", .done, summary: " tests pass\n", project: "Caterm"), to: store)

        #expect(
            store.banner?.alert
                == AgentNotificationAlert(title: "Caterm · Claude", body: "Done: tests pass"))
        #expect(world.soundCount == 1)
        // Past the original one-second deadline, inside the restarted one.
        try await Task.sleep(for: .milliseconds(600))
        #expect(store.banner?.alert.body == "Done: tests pass")
        try await waitUntil("the rewritten banner should still auto-dismiss") {
            store.banner == nil
        }
    }

    /// A dismissed banner comes back with the summary, without replaying the
    /// sound for an event already announced.
    @Test func aSummaryPushAfterDismissalPresentsTheSummaryBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .blocked)])
        try await waitUntil("the live banner should show") { store.banner != nil }
        store.dismiss()

        deliver(push("wV:p1", .blocked, summary: "approve the merge"), to: store)

        #expect(
            store.banner
                == AgentNotificationBanner(
                    target: AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"),
                    status: .blocked,
                    alert: AgentNotificationAlert(
                        title: "Claude", body: "Blocked: approve the merge")))
        #expect(world.soundCount == 1)
    }

    /// A Chat Mode Done push carrying its reply shows the reply as the body,
    /// the same rule as the push renderer, even when the push has no summary.
    @Test func aDonePushWithAReplyShowsTheReply() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .done)])
        try await waitUntil("the live banner should show") { store.banner != nil }

        deliver(
            push("wV:p1", .done, summary: nil, reply: "  All green, merged.\n"),
            to: store)

        #expect(
            store.banner?.alert
                == AgentNotificationAlert(title: "Claude", body: "All green, merged."))
    }

    /// Without a reply (or with a blank one) a Done push keeps its summary copy.
    @Test func aDonePushWithoutAReplyKeepsTheSummary() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .done)])
        try await waitUntil("the live banner should show") { store.banner != nil }

        deliver(push("wV:p1", .done, summary: "tests pass", reply: "  "), to: store)

        #expect(
            store.banner?.alert
                == AgentNotificationAlert(
                    title: "Claude",
                    body: AgentNotificationRenderer.alert(
                        workspace: nil, agentKind: "claude", status: .done,
                        summary: "tests pass"
                    ).body))
    }

    /// A transition the live banner never announced (here: deduped as an
    /// unchanged status) banners from its summary push, with the sound.
    @Test func aSummaryPushForAnUnannouncedStatusBannersWithSound() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .done)])

        deliver(push("wV:p1", .done, summary: "tests pass"), to: store)

        #expect(store.banner?.alert.body == "Done: tests pass")
        #expect(world.soundCount == 1)
    }

    /// A push that lands while its transition is still holding rides along:
    /// one banner, with the summary, once the hold elapses.
    @Test func aSummaryPushDuringTheHoldPresentsWithItOnce() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore(holdDuration: .milliseconds(100))
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .done)])

        deliver(push("wV:p1", .done, summary: "tests pass"), to: store)
        #expect(store.banner == nil, "the push must not skip the hold")

        try await waitUntil("the held banner should show") { store.banner != nil }
        #expect(store.banner?.alert.body == "Done: tests pass")
        #expect(world.soundCount == 1)
    }

    /// A push can outrun the live stream: its summary waits for the live
    /// transition instead of bannering for a status the list has not shown.
    @Test func aSummaryPushAheadOfTheLiveTransitionWaitsForIt() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])

        deliver(push("wV:p1", .done, summary: "tests pass"), to: store)
        #expect(store.banner == nil)

        store.agentsDidChange([agent("wV:p1", .done)])
        try await waitUntil("the live transition should banner") { store.banner != nil }
        #expect(store.banner?.alert.body == "Done: tests pass")
        #expect(world.soundCount == 1)
    }

    /// Only the same Agent and status is rewritten: another pane's push, or
    /// a stale push for a status the Agent has left, leaves it alone.
    @Test func aSummaryPushForAnotherPaneOrStatusLeavesTheBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working), agent("wR:pC", .working)])
        store.agentsDidChange([agent("wV:p1", .done), agent("wR:pC", .working)])
        try await waitUntil("the live banner should show") { store.banner != nil }
        let shown = store.banner

        deliver(push("wR:pC", .done, summary: "other pane"), to: store)
        deliver(push("wV:p1", .blocked, summary: "stale turn"), to: store)

        #expect(store.banner == shown)
        #expect(world.soundCount == 1)
    }

    /// The push path keeps the banner's gates: the presented Agent and a
    /// disabled trigger stay silent, and a push without a summary is no news.
    @Test func aSummaryPushRespectsTheBannerGates() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences(blocked: true, done: false)
        world.presentedAgent = ConsoleAgent.ID(hostID: hostID, paneID: "w1:pT")
        let store = makeStore()
        store.agentsDidChange([
            agent("wV:p1", .done), agent("w1:pT", .blocked), agent("wR:pC", .blocked),
        ])

        deliver(push("wV:p1", .done, summary: "tests pass"), to: store)
        deliver(push("w1:pT", .blocked, summary: "approve the merge"), to: store)
        deliver(push("wR:pC", .blocked, summary: "   "), to: store)

        #expect(store.banner == nil)
        #expect(world.soundCount == 0)
    }

    /// A push stamped before the pane left its status is late: it must not
    /// label the pane's next turn in that status with the old summary.
    @Test func aLateSummaryPushDoesNotLabelTheNextSameStatusBanner() async throws {
        world.triggers[hostID] = NotificationTriggerPreferences()
        let store = makeStore()
        store.agentsDidChange([agent("wV:p1", .working)])
        store.agentsDidChange([agent("wV:p1", .done)])
        try await waitUntil("the first Done banner should show") { store.banner != nil }
        let stamped = Date()
        store.dismiss()
        try await Task.sleep(for: .milliseconds(5))
        store.agentsDidChange([agent("wV:p1", .working)])

        deliver(push("wV:p1", .done, summary: "old turn", stamped: stamped), to: store)
        #expect(store.banner == nil)

        store.agentsDidChange([agent("wV:p1", .done)])
        try await waitUntil("the next Done banner should show") { store.banner != nil }
        #expect(store.banner?.alert.body == "Done")
    }
}
