import Foundation
import Testing

@testable import Waycar

@Suite("Live Activity lifecycle machine")
struct LiveActivityLifecycleMachineTests {
    private let host = UUID()
    private var handle: LiveActivityHandle { LiveActivityHandle(id: "activity", hostID: host) }
    private var desire: AgentActivityDesire {
        AgentActivityDesire(counts: .init(working: 1, blocked: 0, done: 0), hostName: "Host", agents: [])
    }

    @Test func startIsIdempotentAndSettleReplacementsRejectOldTimers() {
        var machine = LiveActivityLifecycleMachine()
        #expect(!machine.state.isStarted)
        #expect(machine.handle([.start, .start]) == [])
        #expect(machine.state.isStarted)
        #expect(machine.handle(.schedule(host)) == [.armSettle(host, 1)])
        #expect(machine.handle(.schedule(host)) == [.cancelSettle(1), .armSettle(host, 2)])
        #expect(machine.handle(.settleElapsed(host, 1)) == [])
        #expect(machine.handle(.settleElapsed(UUID(), 2)) == [])
        #expect(machine.handle(.settleElapsed(host, 2)) == [.apply(host)])
        #expect(machine.handle(.settleElapsed(host, 2)) == [])
        #expect(machine.handle(.schedule(host)) == [.armSettle(host, 3)])
        #expect(machine.handle(.cancelSettle(host)) == [.cancelSettle(3)])
        #expect(machine.handle(.cancelSettle(host)) == [])
    }

    @Test func sessionsCarryDesireAndSnapshotHoldWithoutLosingIdentity() {
        var machine = LiveActivityLifecycleMachine().after([.start])
        #expect(machine.handle(.begin(handle, awaitingSnapshot: true)) == [.watch(handle)])
        #expect(machine.sessions[host] == .init(id: handle.id, awaitingFirstSnapshot: true))
        #expect(machine.handle(.applied(host, desire)) == [])
        #expect(machine.applied[host] == desire)
        #expect(machine.handle(.releaseHold(host)) == [])
        #expect(machine.sessions[host]?.awaitingFirstSnapshot == false)
        #expect(machine.handle([.hold(host), .hold(host)]) == [])
        #expect(machine.sessions[host]?.awaitingFirstSnapshot == true)
        #expect(machine.applied[host] == desire)
        #expect(machine.handle(.applied(host, nil)) == [])
        #expect(machine.applied[host] == nil)
        #expect(machine.handle([.hold(UUID()), .releaseHold(UUID())]) == [])
    }

    @Test func dismissalRetainsAppliedDesireButExpiryResetsAndSchedulesReplacement() {
        var dismissed = LiveActivityLifecycleMachine().after([
            .start, .begin(handle, awaitingSnapshot: false), .applied(host, desire),
        ])
        #expect(dismissed.handle(.activityState(handle, .dismissed)) == [.cancelWatch(handle.id), .clearToken(host)])
        #expect(dismissed.state.hosts[host]?.phase == .dismissed(desire))
        #expect(dismissed.applied[host] == desire, "LA-02: same desire must not restart after dismissal")
        #expect(dismissed.sessions.isEmpty)
        #expect(dismissed.state.retiredIDs == [handle.id])
        var expired = LiveActivityLifecycleMachine().after([
            .start, .begin(handle, awaitingSnapshot: false), .applied(host, desire),
        ])
        #expect(expired.handle(.activityState(handle, .ended)) == [
            .cancelWatch(handle.id), .endActivity(handle.id), .clearToken(host), .schedule(host),
        ])
        #expect(expired.applied[host] == nil)
        #expect(expired.sessions.isEmpty)
    }

    @Test func stateEventsFromAReplacedSessionCannotEndTheNewSession() {
        let replacement = LiveActivityHandle(id: "replacement", hostID: host)
        var machine = LiveActivityLifecycleMachine().after([
            .start, .begin(handle, awaitingSnapshot: false), .drop(host, end: true),
            .begin(replacement, awaitingSnapshot: false), .applied(host, desire),
        ])
        #expect(machine.handle([.activityState(handle, .dismissed), .activityState(handle, .ended),
                                .activityState(replacement, .active), .activityState(replacement, .stale)]) == [])
        #expect(machine.sessions[host]?.id == replacement.id)
        #expect(machine.applied[host] == desire)
    }

    @Test func requestFailureIsRetryableAndBeginningASessionClearsIt() {
        var machine = LiveActivityLifecycleMachine().after([.start])
        #expect(machine.handle(.startFailed(host)) == [])
        #expect(machine.failedStarts == [host])
        #expect(machine.sessions.isEmpty)
        #expect(machine.handle(.forgetFailure(host)) == [])
        #expect(machine.failedStarts.isEmpty)
        #expect(machine.handle(.startFailed(host)) == [])
        #expect(machine.handle(.begin(handle, awaitingSnapshot: false)) == [.watch(handle)])
        #expect(machine.failedStarts.isEmpty)
        #expect(machine.handle(.forgetFailure(host)) == [])
        #expect(machine.sessions[host]?.id == handle.id)
    }

    @Test func explicitEndDropsSessionAndDesireButNotAnUnrelatedSettle() {
        var machine = LiveActivityLifecycleMachine().after([
            .start, .begin(handle, awaitingSnapshot: false), .applied(host, desire), .schedule(host),
        ])
        #expect(machine.handle(.end(host)) == [.cancelWatch(handle.id), .endActivity(handle.id), .clearToken(host)])
        #expect(machine.state.hosts[host]?.phase == .idle)
        #expect(machine.state.hosts[host]?.settle == .waiting(1))
        #expect(machine.handle(.drop(host, end: false)) == [])
        #expect(machine.handle(.end(host)) == [.clearToken(host)])
    }

    @Test func newestInventoryRetiresDuplicatesUnknownEndedAndAlreadyRetiredActivities() {
        let unknown = UUID()
        var machine = LiveActivityLifecycleMachine()
        #expect(machine.handle(.retire("retired")) == [.endActivity("retired")])
        let inventory: [LiveActivityLifecycleMachine.SystemActivity] = [
            .init(id: "old", hostID: host, state: .active),
            .init(id: "new", hostID: host, state: .stale),
            .init(id: "ended", hostID: host, state: .ended),
            .init(id: "retired", hostID: host, state: .active),
            .init(id: "orphan", hostID: unknown, state: .active),
            .init(id: "dismissed", hostID: host, state: .dismissed),
        ]
        #expect(machine.handle(.inventory(inventory, known: [host], only: nil)) == [
            .endActivity("old"), .endActivity("ended"), .endActivity("retired"), .endActivity("orphan"),
        ])
        #expect(machine.state.newest == [host: "new"])
        #expect(!machine.state.retiredIDs.contains("dismissed"))
        #expect(machine.handle(.inventory([], known: [host], only: nil)) == [])
        #expect(machine.state.retiredIDs.isEmpty)
    }

    @Test func filteredInventoryOnlyEndsTheRequestedHostAndRetainsOtherRetirements() {
        let other = UUID()
        var machine = LiveActivityLifecycleMachine().after([.retire("other")])
        #expect(machine.handle(.inventory([
            .init(id: "other", hostID: other, state: .active),
            .init(id: handle.id, hostID: host, state: .active),
        ], known: [host], only: host)) == [])
        #expect(machine.state.newest == [host: handle.id])
        #expect(machine.state.retiredIDs == ["other"])
    }
}
