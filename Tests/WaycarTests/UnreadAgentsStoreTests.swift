import Foundation
import Testing

@testable import Waycar

/// Mark as Unread: an app-local mark that lists an Idle Agent as Done in the
/// Console index until the user opens it or herdr reports new activity.
@MainActor
@Suite("Unread agents store")
struct UnreadAgentsStoreTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-unread-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func row(
        _ hostID: UUID, _ paneID: String, _ status: AgentStatus, sequence: Int? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: hostID,
            hostName: "alpha",
            agent: Agent(.fixture(paneID: paneID, status: status, stateChangeSeq: sequence)),
            workspaceLabel: "Proj",
            repositoryCheckout: nil)
    }

    @Test func onlyAnIdleAgentCanBeMarkedAndTheMarkSurvivesRelaunch() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()
        let store = UnreadAgentsStore(defaults: defaults)

        for status in [AgentStatus.working, .blocked, .done, .unknown, .shellTerminal] {
            let agent = row(hostID, "w1:\(status.rawValue)", status)
            #expect(!store.markUnread(agent), "\(status.rawValue) must not be markable")
            #expect(store.displayed(agent) == agent)
        }

        let idle = row(hostID, "w1:p1", .idle)
        #expect(store.markUnread(idle))
        #expect(!store.canMarkUnread(idle), "an already-marked Agent offers Mark as Read instead")
        #expect(store.displayed(idle).agent.status == .done)

        let relaunched = UnreadAgentsStore(defaults: defaults)
        #expect(relaunched.isMarkedUnread(idle.id))
        #expect(relaunched.displayed(idle).agent.status == .done)
        #expect(!relaunched.isMarkedUnread(row(UUID(), "w1:p1", .idle).id), "marks are per Host")
    }

    @Test func markReadClearsTheMarkForGood() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let store = UnreadAgentsStore(defaults: defaults)
        let idle = row(UUID(), "w1:p1", .idle)
        store.markUnread(idle)

        #expect(store.markRead(idle.id))
        #expect(!store.markRead(idle.id), "nothing left to clear")
        #expect(store.displayed(idle).agent.status == .idle)
        #expect(!UnreadAgentsStore(defaults: defaults).isMarkedUnread(idle.id))
    }

    @Test func aVerifiedSnapshotClearsMarksOnActivityAndOnPanesThatAreGone() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()
        let otherHostID = UUID()
        let store = UnreadAgentsStore(defaults: defaults)
        let panes = ["still-idle", "working", "blocked", "done", "unknown", "shell", "gone"]
        for pane in panes {
            store.markUnread(row(hostID, pane, .idle))
        }
        let otherHost = row(otherHostID, "gone", .idle)
        store.markUnread(otherHost)

        let live: [String: ConsoleAgent] = [
            "still-idle": row(hostID, "still-idle", .idle),
            "working": row(hostID, "working", .working),
            "blocked": row(hostID, "blocked", .blocked),
            "done": row(hostID, "done", .done),
            "unknown": row(hostID, "unknown", .unknown),
            "shell": row(hostID, "shell", .shellTerminal),
        ]
        #expect(store.reconcile(hostID: hostID, agents: live))

        #expect(store.isMarkedUnread(row(hostID, "still-idle", .idle).id))
        for pane in panes.dropFirst() {
            #expect(!store.isMarkedUnread(row(hostID, pane, .idle).id), "\(pane) keeps a stale mark")
        }
        #expect(store.isMarkedUnread(otherHost.id), "another Host's snapshot says nothing about it")
        #expect(!store.reconcile(hostID: hostID, agents: live), "a settled Host changes nothing")

        let relaunched = UnreadAgentsStore(defaults: defaults)
        #expect(relaunched.isMarkedUnread(row(hostID, "still-idle", .idle).id))
        #expect(!relaunched.isMarkedUnread(row(hostID, "gone", .idle).id))
    }

    @Test func aTurnThatCameAndWentBetweenSnapshotsClearsTheMark() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()
        let store = UnreadAgentsStore(defaults: defaults)
        store.markUnread(row(hostID, "quiet", .idle, sequence: 4))
        store.markUnread(row(hostID, "busy", .idle, sequence: 4))

        // Both still Idle, but herdr counted a state change on "busy": a
        // Working turn started and finished without a snapshot seeing it.
        let live: [String: ConsoleAgent] = [
            "quiet": row(hostID, "quiet", .idle, sequence: 4),
            "busy": row(hostID, "busy", .idle, sequence: 6),
        ]
        #expect(store.reconcile(hostID: hostID, agents: live))
        #expect(store.isMarkedUnread(live["quiet"]!.id))
        #expect(!store.isMarkedUnread(live["busy"]!.id))
        #expect(!UnreadAgentsStore(defaults: defaults).isMarkedUnread(live["busy"]!.id))
    }

    @Test func aMarkWithoutASequenceFallsBackToStatusThenAdoptsTheIdleRowsSequence() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()
        // A blob written before marks recorded `stateChangeSeq`.
        let legacy = """
            {"version":1,"entries":[{"hostID":"\(hostID.uuidString)","paneID":"old"}]}
            """
        defaults.set(Data(legacy.utf8), forKey: UnreadAgentsStore.defaultsKey)
        let store = UnreadAgentsStore(defaults: defaults)
        #expect(store.isMarkedUnread(row(hostID, "old", .idle).id), "old blobs still load")

        #expect(!store.reconcile(hostID: hostID, agents: ["old": row(hostID, "old", .idle, sequence: 9)]))
        #expect(store.isMarkedUnread(row(hostID, "old", .idle).id), "Idle keeps a mark with no sequence")

        // The adopted sequence now catches the next unobserved turn, also
        // after a relaunch.
        let relaunched = UnreadAgentsStore(defaults: defaults)
        #expect(relaunched.reconcile(hostID: hostID, agents: ["old": row(hostID, "old", .idle, sequence: 11)]))
        #expect(!relaunched.isMarkedUnread(row(hostID, "old", .idle).id))
    }

    @Test func aRowAStatusDeltaTurnedIdleNeitherRecordsNorLendsItsStaleSequence() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()
        let store = UnreadAgentsStore(defaults: defaults)
        // The Working snapshot said sequence 4; the Idle delta says none.
        var delta = row(hostID, "p", .working, sequence: 4)
        delta.agent.replaceStatus(.idle)
        #expect(store.markUnread(delta))

        // Rebuilds before the resync see the same delta row: its sequence
        // is the Working one's, so it is not adopted.
        #expect(!store.reconcile(hostID: hostID, agents: ["p": delta]))
        #expect(!store.reconcile(hostID: hostID, agents: ["p": row(hostID, "p", .idle, sequence: 5)]))
        #expect(store.isMarkedUnread(delta.id), "the resync's sequence is the Idle the mark saw")
        #expect(store.reconcile(hostID: hostID, agents: ["p": row(hostID, "p", .idle, sequence: 7)]))
        #expect(!store.isMarkedUnread(delta.id), "a later unobserved turn still clears it")
    }

    @Test func rekeyingCarriesTheMarkToTheMovedPanesNewID() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()
        let store = UnreadAgentsStore(defaults: defaults)
        let moved = row(hostID, "w1:p1", .idle, sequence: 3)
        let sibling = row(hostID, "w1:p2", .idle, sequence: 3)
        store.markUnread(moved)
        store.markUnread(sibling)
        let newID = row(hostID, "w2:moved", .idle).id

        store.rekey(moved.id, toPaneID: "w2:moved")
        #expect(!store.isMarkedUnread(moved.id))
        #expect(store.isMarkedUnread(newID))
        #expect(store.isMarkedUnread(sibling.id), "a sibling pane keeps its mark")
        #expect(UnreadAgentsStore(defaults: defaults).isMarkedUnread(newID))

        // Until herdr's next snapshot the verified rows still list the old
        // id; the new one is not "gone" yet.
        let beforeResync = ["w1:p1": moved, "w1:p2": sibling]
        #expect(!store.reconcile(hostID: hostID, agents: beforeResync))
        #expect(store.isMarkedUnread(newID))

        // The moved pane's sequence need not match the old one's.
        let afterResync = ["w1:p2": sibling, "w2:moved": row(hostID, "w2:moved", .idle, sequence: 8)]
        #expect(!store.reconcile(hostID: hostID, agents: afterResync))
        #expect(store.isMarkedUnread(newID))

        // Once listed, the new pane settles like any other: gone clears it.
        #expect(store.reconcile(hostID: hostID, agents: ["w1:p2": sibling]))
        #expect(!store.isMarkedUnread(newID))
    }

    @Test func aMoveInFlightHoldsTheMarkUntilItEnds() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostID = UUID()
        let store = UnreadAgentsStore(defaults: defaults)
        let moving = row(hostID, "w1:p1", .idle, sequence: 3)
        store.markUnread(moving)

        // herdr moves the pane before its reply names the new id: a snapshot
        // without the old one keeps the mark, even after one that listed it.
        store.beginMove(moving.id)
        #expect(!store.reconcile(hostID: hostID, agents: ["w1:p1": moving]))
        #expect(!store.reconcile(hostID: hostID, agents: [:]))
        #expect(store.isMarkedUnread(moving.id))

        // A failed move ends the hold: the pane gone clears the mark again.
        store.cancelMove(moving.id)
        #expect(store.reconcile(hostID: hostID, agents: [:]))
        #expect(!store.isMarkedUnread(moving.id))
    }

    @Test func removingAHostFromTheCatalogDropsItsMarks() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let kept = row(UUID(), "w1:p1", .idle)
        let removed = row(UUID(), "w1:p1", .idle)
        let store = UnreadAgentsStore(defaults: defaults)
        store.markUnread(kept)
        store.markUnread(removed)

        store.retainHosts([kept.hostID])

        #expect(store.isMarkedUnread(kept.id))
        #expect(!store.isMarkedUnread(removed.id))
        #expect(!UnreadAgentsStore(defaults: defaults).isMarkedUnread(removed.id))
    }

    @Test func theIndexListsAMarkedAgentAsDoneWhileEveryOtherConsumerKeepsHerdrsStatus()
        async throws
    {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .idle),
                .fixture(paneID: "w1:p2", status: .working),
                .fixture(paneID: "w1:p3", status: .done),
            ]))
        let store = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults)
        ) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the snapshot should verify the rows") {
            store.agents.count == 3 && !store.hostsAwaitingSnapshot.contains(host.id)
        }
        let idleID = ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")
        let idle = try #require(store.agents.first { $0.id == idleID })

        store.markUnread(idle)

        let index = store.indexAgents(holding: nil)
        #expect(index.map(\.agent.paneID) == ["w1:p1", "w1:p3", "w1:p2"], "sorts in the Done bucket")
        #expect(index.first?.agent.status == .done)
        #expect(ConsoleStatusFilter.done.matches(try #require(index.first)))
        #expect(ConsoleStatusFilter.attention.matches(try #require(index.first)))
        #expect(
            store.agents.first { $0.id == idleID }?.agent.status == .idle,
            "notifications, Live Activities and focus read herdr's status")

        // Opening the Agent reads the mark; no RPC is involved.
        store.markRead(idleID)
        #expect(store.indexAgents(holding: nil).first { $0.id == idleID }?.agent.status == .idle)

        // New activity on the Host clears a mark too.
        store.markUnread(idle)
        try await waitUntil("pane subscription should be live") {
            await transport.capturedSubscriptions.last?
                .contains(.pane(.agentStatusChanged, paneID: "w1:p1")) == true
        }
        await transport.setSnapshot(
            .fixture(agents: [
                .fixture(paneID: "w1:p1", status: .working),
                .fixture(paneID: "w1:p2", status: .working),
                .fixture(paneID: "w1:p3", status: .done),
            ]))
        #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: .working)))
        try await waitUntil("herdr's Working should clear the mark") {
            !store.unread.isMarkedUnread(idleID)
        }

        store.setHosts([])
    }
}
