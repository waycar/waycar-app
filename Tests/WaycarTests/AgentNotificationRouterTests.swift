import Foundation
import Testing

@testable import Waycar

/// The navigation half of #74: taps land on the right Agent detail through
/// the Console's navigation path, a killed-state tap waits for the pane to
/// arrive with the Host's first sync, and stale or unresolvable pushes fall
/// back to the Console with no alarming copy.
///
/// Pane ids that stand in for a live herdr address use the observed
/// alphanumeric `w…:p…` family (uppercase included). `%gone` and `%other`
/// stay deliberately fake: those cases only need distinct opaque strings.
@MainActor
@Suite("Agent notification router")
struct AgentNotificationRouterTests {
    private func consoleAgent(hostID: UUID, paneID: String) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID, hostName: "mac-studio",
            agent: Agent(.fixture(paneID: paneID)),
            workspaceLabel: nil, repositoryCheckout: nil)
    }

    @Test func zellijPushWaitsForInventoryThenOpensTheZellijAgent() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        let paneID = "zellij:work/terminal_7"
        let target = AgentNotificationTarget(hostID: hostID, paneID: paneID)
        router.open(target)
        #expect(router.pendingTarget == target)
        let row = ConsoleAgent(
            hostID: hostID, hostName: "Host", agent: Agent(.fixture(paneID: paneID)),
            workspaceLabel: nil, repositoryCheckout: nil, backend: .zellij)
        router.agentsDidChange([row])
        #expect(router.path == [row.id])
        #expect(router.backend(of: row.id) == .zellij)
        #expect(router.pendingTarget == nil)
    }

    @Test func tapOnAKnownAgentOpensItsDetail() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "wV:p1")])

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))

        #expect(router.path == [ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")])
        #expect(router.pendingTarget == nil)
    }

    @Test func tapReplacesTheCurrentlyPresentedAgent() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        router.agentsDidChange([
            consoleAgent(hostID: hostID, paneID: "wV:p1"),
            consoleAgent(hostID: hostID, paneID: "w1C:p1"),
        ])
        router.path = [ConsoleAgent.ID(hostID: hostID, paneID: "w1C:p1")]

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))

        #expect(router.path == [ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")])
    }

    /// The killed-state launch path: the tap arrives before any Host has
    /// synced, so the router waits on the Console and routes the moment the
    /// pane appears.
    @Test func tapBeforeTheConsoleSyncsWaitsForThePaneThenOpens() {
        let router = AgentNotificationRouter()
        let hostID = UUID()

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))
        #expect(router.path.isEmpty)
        #expect(router.pendingTarget == AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))

        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "wV:p1")])

        #expect(router.path == [ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")])
        #expect(router.pendingTarget == nil)
    }

    /// A stale pane — closed since the push was sent — never shows up, so
    /// the tap quietly stays on the Console once the grace window elapses.
    @Test func stalePaneFallsBackToTheConsoleQuietly() async throws {
        let router = AgentNotificationRouter(pendingGrace: .milliseconds(25))
        let hostID = UUID()
        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "w1:pT")])
        // Viewing some other Agent when the tap lands: fall back means
        // popping to the Console, not staying wherever the user was.
        router.path = [ConsoleAgent.ID(hostID: hostID, paneID: "w1:pT")]

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "%gone"))
        #expect(router.path.isEmpty)

        try await waitUntil("the pending target should expire") {
            router.pendingTarget == nil
        }
        #expect(router.path.isEmpty)
    }

    /// Unknown key id or an undecryptable envelope resolves to no target;
    /// the tap still brings the user to the Console.
    @Test func unresolvableTapFallsBackToTheConsole() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "wV:p1")])
        router.path = [ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")]

        router.open(nil)

        #expect(router.path.isEmpty)
        #expect(router.pendingTarget == nil)
    }

    /// If the user starts navigating while a tap is still waiting for its
    /// pane, the deep link must not yank them away later.
    @Test func manualNavigationDropsAPendingDeepLink() {
        let router = AgentNotificationRouter()
        let hostID = UUID()

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))
        router.path = [ConsoleAgent.ID(hostID: hostID, paneID: "%other")]

        router.agentsDidChange([
            consoleAgent(hostID: hostID, paneID: "wV:p1"),
            consoleAgent(hostID: hostID, paneID: "%other"),
        ])

        #expect(router.path == [ConsoleAgent.ID(hostID: hostID, paneID: "%other")])
        #expect(router.pendingTarget == nil)
    }

    /// Opening another Agent and coming back to the Console still counts as
    /// navigating: the waiting tap is dropped then, not when its pane shows
    /// up while the user happens to be on the Console again.
    @Test func navigatingAwayAndBackStillDropsAPendingDeepLink() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "%other")])

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))
        router.path = [ConsoleAgent.ID(hostID: hostID, paneID: "%other")]
        #expect(router.pendingTarget == nil)
        router.path = []

        router.agentsDidChange([
            consoleAgent(hostID: hostID, paneID: "wV:p1"),
            consoleAgent(hostID: hostID, paneID: "%other"),
        ])

        #expect(router.path.isEmpty)
    }

    /// A move re-keys the open Agent's pane: the path follows, and that
    /// change reads as the same Agent, never as leaving one for another.
    @Test func aMoveRetargetsTheOpenAgentAsTheSameScreen() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        let before = ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")
        let after = ConsoleAgent.ID(hostID: hostID, paneID: "wV:p2")
        let other = ConsoleAgent.ID(hostID: hostID, paneID: "%other")
        router.path = [before]

        router.retarget(from: before, to: after)

        #expect(router.path == [after])
        #expect(router.isRetarget(from: before, to: after))
        router.path = [other]
        #expect(!router.isRetarget(from: after, to: other))
    }

    /// herdr reuses pane ids, so the same pair can come back later as an
    /// ordinary switch; only the change `retarget` made itself is a move.
    @Test func aLaterSwitchBetweenTheSamePanesIsNotAMove() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        let before = ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")
        let after = ConsoleAgent.ID(hostID: hostID, paneID: "wV:p2")
        router.path = [before]
        router.retarget(from: before, to: after)

        router.path = [before]
        router.path = [after]

        #expect(!router.isRetarget(from: before, to: after))
    }

    @Test func aMoveOfAnAgentThatIsNoLongerOpenLeavesThePathAlone() {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        let moved = ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")
        let open = ConsoleAgent.ID(hostID: hostID, paneID: "%other")
        router.path = [open]

        router.retarget(from: moved, to: ConsoleAgent.ID(hostID: hostID, paneID: "wV:p2"))

        #expect(router.path == [open])
    }

    /// Every tap counts as the user asking to go somewhere, even one for the
    /// Agent already open or one still waiting for its pane; a restored
    /// route placed on the path directly does not.
    @Test func everyTapIsARouteRequestButARestoredRouteIsNot() throws {
        let router = AgentNotificationRouter()
        let hostID = UUID()
        router.agentsDidChange([consoleAgent(hostID: hostID, paneID: "wV:p1")])

        router.path = [ConsoleAgent.ID(hostID: hostID, paneID: "wV:p1")]
        #expect(router.lastRouteRequest == nil)

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "wV:p1"))
        let sameAgent = try #require(router.lastRouteRequest)

        router.open(AgentNotificationTarget(hostID: hostID, paneID: "%gone"))
        let pending = try #require(router.lastRouteRequest)
        #expect(pending >= sameAgent)
        #expect(router.pendingTarget != nil)
    }
}
