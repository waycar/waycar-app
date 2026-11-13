import Foundation
import Testing

@testable import Waycar

/// Every transition of `NotificationRouteMachine`, the notification tap's
/// way to its Agent detail. `AgentNotificationRouterTests` covers the router
/// that performs its effects.
@Suite("Notification route machine")
struct NotificationRouteMachineTests {
    private let hostID = UUID()
    private var target: AgentNotificationTarget { AgentNotificationTarget(hostID: hostID, paneID: "wV:p1") }
    private var other: AgentNotificationTarget { AgentNotificationTarget(hostID: hostID, paneID: "w1C:p1") }

    @Test func aTapForAKnownPaneOpensIt() {
        var machine = NotificationRouteMachine()

        #expect(machine.handle(.tapped(target, paneIsKnown: true)) == [.showAgent(target.agentID)])
        #expect(machine.state == .idle)
    }

    @Test func anUnresolvableTapShowsTheConsole() {
        var machine = NotificationRouteMachine()

        #expect(machine.handle(.tapped(nil, paneIsKnown: false)) == [.showConsole])
        #expect(machine.state == .idle)
    }

    @Test func aTapForAnUnknownPaneWaitsOnTheConsole() {
        var machine = NotificationRouteMachine()

        #expect(machine.handle(.tapped(target, paneIsKnown: false)) == [.showConsole, .armGrace(1)])
        #expect(machine.state == .waiting(target, grace: 1))
        #expect(machine.pendingTarget == target)
    }

    @Test func theWaitingPaneArrivingOpensIt() {
        var machine = NotificationRouteMachine().after([.tapped(target, paneIsKnown: false)])

        #expect(machine.handle(.agentsChanged([other.agentID])) == [])
        #expect(machine.handle(.agentsChanged([target.agentID])) == [.cancelGrace, .showAgent(target.agentID)])
        #expect(machine.state == .idle)
    }

    @Test func navigatingEndsTheWait() {
        var machine = NotificationRouteMachine().after([.tapped(target, paneIsKnown: false)])

        #expect(machine.handle(.navigated) == [.cancelGrace])
        #expect(machine.handle(.agentsChanged([target.agentID])) == [])
        #expect(machine.state == .idle)
    }

    @Test func theGraceWindowEndsTheWaitQuietly() {
        var machine = NotificationRouteMachine().after([.tapped(target, paneIsKnown: false)])

        #expect(machine.handle(.graceElapsed(1)) == [])
        #expect(machine.state == .idle)
    }

    /// A timer from an earlier tap that fires late must not end the wait of
    /// the tap that replaced it.
    @Test func aStaleGraceTimerIsIgnored() {
        var machine = NotificationRouteMachine().after([
            .tapped(target, paneIsKnown: false), .tapped(other, paneIsKnown: false),
        ])
        #expect(machine.state == .waiting(other, grace: 2))

        #expect(machine.handle(.graceElapsed(1)) == [])
        #expect(machine.state == .waiting(other, grace: 2))
    }

    @Test func aNewTapReplacesAWaitingOne() {
        var machine = NotificationRouteMachine().after([.tapped(target, paneIsKnown: false)])

        #expect(machine.handle(.tapped(other, paneIsKnown: true)) == [.cancelGrace, .showAgent(other.agentID)])
        #expect(machine.state == .idle)
    }

    @Test func eventsWithNothingWaitingChangeNothing() {
        var machine = NotificationRouteMachine()

        #expect(machine.handle([.agentsChanged([target.agentID]), .navigated, .graceElapsed(1)]) == [])
        #expect(machine.state == .idle)
    }
}
