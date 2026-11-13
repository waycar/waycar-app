import Foundation
import Testing

@testable import Waycar

@Suite("Agent notification pipeline machine")
struct AgentNotificationPipelineMachineTests {
    private let target = AgentNotificationTarget(hostID: UUID(), paneID: "opaque:Pane")
    private let now = Date(timeIntervalSince1970: 100)
    private func banner(_ status: AgentStatus, body: String = "live") -> AgentNotificationBanner {
        AgentNotificationBanner(target: target, status: status,
                                alert: AgentNotificationAlert(title: "Agent", body: body))
    }
    private var id: ConsoleAgent.ID { target.agentID }

    @Test func firstSightAndUnchangedStatusesNeverHold() {
        var machine = AgentNotificationPipelineMachine()
        #expect(machine.handle(.observed(banner(.blocked), at: now)) == [])
        #expect(machine.handle(.observed(banner(.blocked), at: now)) == [])
        #expect(machine.handle(.observed(banner(.working), at: now)) == [])
        #expect(machine.knownIDs == [id])
        #expect(machine.handle(.holdElapsed(id, 1, .allowed)) == [])
    }

    @Test func heldTransitionAnnouncesAndFlapsCancelWithNonreusedTokens() {
        var machine = AgentNotificationPipelineMachine().after([.observed(banner(.working), at: now)])
        #expect(machine.handle(.observed(banner(.done), at: now)) == [.armHold(id, 1)])
        #expect(machine.handle(.observed(banner(.working), at: now)) == [.cancelHold(id, 1)])
        #expect(machine.handle(.observed(banner(.blocked), at: now)) == [.armHold(id, 2)])
        #expect(machine.handle(.holdElapsed(id, 1, .allowed)) == [])
        #expect(machine.handle(.holdElapsed(id, 2, .allowed)) == [.show(banner(.blocked), sound: true)])
        #expect(machine.handle(.holdElapsed(id, 2, .allowed)) == [])
    }

    @Test func removalCancelsAndCannotLeakIntoAReappearingAgent() {
        var machine = AgentNotificationPipelineMachine().after([
            .observed(banner(.working), at: now), .observed(banner(.done), at: now),
        ])
        #expect(machine.handle(.removed(id)) == [.cancelHold(id, 1)])
        #expect(machine.knownIDs.isEmpty)
        #expect(machine.handle(.observed(banner(.working), at: now)) == [])
        #expect(machine.handle(.observed(banner(.done), at: now)) == [.armHold(id, 2)])
        #expect(machine.handle(.holdElapsed(id, 1, .allowed)) == [])
    }

    @Test func summaryDuringHoldAndBeforeLiveTransitionSurvivesOnlyItsStatus() {
        var machine = AgentNotificationPipelineMachine().after([.observed(banner(.working), at: now)])
        let pushed = banner(.done, body: "summary")
        #expect(machine.handle(.push(pushed, timestamp: now, showing: nil, gate: .allowed)) == [])
        #expect(machine.handle(.observed(banner(.done), at: now)) == [.armHold(id, 1)])
        #expect(machine.handle(.push(pushed, timestamp: now, showing: nil, gate: .allowed)) == [])
        #expect(machine.handle(.holdElapsed(id, 1, .allowed)) == [.show(pushed, sound: true)])
        #expect(machine.handle(.observed(banner(.working), at: now)) == [])
        #expect(machine.handle(.observed(banner(.done), at: now)) == [.armHold(id, 2)])
        #expect(machine.handle(.holdElapsed(id, 2, .allowed)) == [.show(banner(.done), sound: true)])
    }

    @Test func pushBeforeFirstInventoryIsRetainedAndLatePushIsIgnored() {
        var machine = AgentNotificationPipelineMachine()
        let pushed = banner(.done, body: "summary")
        #expect(machine.handle(.push(pushed, timestamp: now, showing: nil, gate: .allowed)) == [])
        #expect(machine.handle(.observed(banner(.done), at: now)) == [])
        #expect(machine.handle(.push(pushed, timestamp: now, showing: nil, gate: .allowed)) == [.show(pushed, sound: true)])
        #expect(machine.handle(.observed(banner(.working), at: now.addingTimeInterval(1))) == [])
        #expect(machine.handle(.push(pushed, timestamp: now, showing: nil, gate: .allowed)) == [])
        #expect(machine.state.agents[id]?.summary == nil)
    }

    @Test func pushRewritesShowingCopyWithoutGatesAndRebannersSilentlyAfterAnnouncement() {
        var machine = AgentNotificationPipelineMachine().after([.observed(banner(.done), at: now)])
        let pushed = banner(.done, body: "summary")
        #expect(machine.handle(.push(pushed, timestamp: now, showing: banner(.done), gate: .disabled))
            == [.show(pushed, sound: false)])
        #expect(machine.handle(.push(pushed, timestamp: now, showing: nil, gate: .allowed))
            == [.show(pushed, sound: true)])
        #expect(machine.handle(.push(pushed, timestamp: now, showing: nil, gate: .allowed))
            == [.show(pushed, sound: false)])
    }

    @Test func fireTimeGatesSuppressDisableOrDeferAndReplayRevalidates() {
        for gate in [AgentNotificationPipelineMachine.Gate.suppressed, .disabled] {
            var machine = AgentNotificationPipelineMachine().after([
                .observed(banner(.working), at: now), .observed(banner(.done), at: now),
            ])
            #expect(machine.handle(.holdElapsed(id, 1, gate)) == [])
            #expect(machine.deferred.isEmpty)
        }
        var machine = AgentNotificationPipelineMachine().after([
            .observed(banner(.working), at: now), .observed(banner(.done), at: now),
        ])
        #expect(machine.handle(.holdElapsed(id, 1, .voiceQuiet)) == [.armReplay(2)])
        #expect(machine.deferred[id] == target)
        #expect(machine.handle(.replayElapsed(999, gates: [id: .allowed])) == [])
        #expect(machine.handle(.replayElapsed(2, gates: [id: .voiceQuiet])) == [.armReplay(3)])
        #expect(machine.handle(.replayElapsed(3, gates: [id: .allowed])) == [.show(banner(.done), sound: true)])
        #expect(machine.deferred.isEmpty)
    }

    @Test func deferredStatusChangeDropsReplayAndNewerPushReplacesDeferredCopy() {
        var machine = AgentNotificationPipelineMachine().after([.observed(banner(.done), at: now)])
        let first = banner(.done, body: "first"), next = banner(.done, body: "next")
        #expect(machine.handle(.push(first, timestamp: now, showing: nil, gate: .voiceQuiet)) == [.armReplay(1)])
        #expect(machine.handle(.push(next, timestamp: now, showing: nil, gate: .voiceQuiet)) == [])
        #expect(machine.handle(.replayElapsed(1, gates: [id: .allowed])) == [.show(next, sound: true)])
        #expect(machine.handle(.push(next, timestamp: now, showing: nil, gate: .voiceQuiet)) == [.armReplay(2)])
        #expect(machine.handle(.replayElapsed(2, gates: [id: .allowed])) == [.show(next, sound: false)])
        #expect(machine.handle(.push(next, timestamp: now, showing: nil, gate: .voiceQuiet)) == [.armReplay(3)])
        #expect(machine.handle(.observed(banner(.working), at: now)) == [])
        #expect(machine.handle(.replayElapsed(3, gates: [id: .allowed])) == [])
        #expect(machine.deferred.isEmpty)
    }

    @Test func replayDropsPresentedOrDisabledBannersAndRemovalPrunesSummaries() {
        for gate in [AgentNotificationPipelineMachine.Gate.suppressed, .disabled] {
            var machine = AgentNotificationPipelineMachine().after([
                .observed(banner(.done), at: now),
                .push(banner(.done, body: "summary"), timestamp: now, showing: nil, gate: .voiceQuiet),
            ])
            #expect(machine.handle(.replayElapsed(1, gates: [id: gate])) == [])
            #expect(machine.deferred.isEmpty)
            #expect(machine.handle(.removed(id)) == [])
            #expect(machine.state.agents.isEmpty)
        }
    }
}
