import Foundation
import Testing

@testable import Waycar

/// Owner characterization: these use only the projection's pre-conversion API.
@MainActor
@Suite("Host projection lifecycle characterization", .timeLimit(.minutes(1)))
struct HostConsoleProjectionLifecycleTests {
    private let host = Host.fixture()
    private let snapshot = SessionSnapshot.fixture(
        agents: [.fixture(paneID: "w1:p1", status: .working)],
        workspaces: [.fixture(workspaceID: "w1", label: "Cached")], protocolVersion: 22)

    private func makeProjection(
        _ transport: ScriptedTransport, foreground: Bool = false, settle: Duration = .zero
    ) -> HostConsoleProjection {
        let session = EventsSession(
            subscriptions: HostConsoleProjection.subscriptions(paneIDs: []),
            connect: { transport },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        let projection = HostConsoleProjection(
            host: host, session: session, snapshotRetryDelay: .milliseconds(10),
            summaryRefreshTiming: AgentSummaryRefreshTiming(
                interval: .seconds(60), settle: settle, debounce: .milliseconds(10))) {}
        projection.setSummaryRefreshGate(
            AgentSummaryRefreshGate(isForeground: foreground, isEnabled: true))
        projection.seed(snapshot, verifiedAt: Date(timeIntervalSince1970: 100))
        return projection
    }

    /// The seeded rows subscribe the first connection with their pane set
    /// (#105), so its one live snapshot needs no resubscribe; waits for it.
    private func waitForPaneSubscription(
        _ transport: ScriptedTransport, _ projection: HostConsoleProjection
    ) async throws {
        try await waitUntil {
            let live = await transport.capturedSubscriptions.last?
                .contains(.pane(.agentStatusChanged, paneID: "w1:p1")) == true
            let snapshotted = await transport.snapshotFetchCount >= 1
            return live && snapshotted && !projection.isAwaitingSnapshot
        }
    }

    @Test func cachedRowsStayVisibleUntilTheSubscribedLiveSnapshotVerifiesThem() async throws {
        let live = SessionSnapshot.fixture(
            agents: [.fixture(paneID: "w1:p2")],
            workspaces: [.fixture(workspaceID: "w1", label: "Live")], protocolVersion: 22)
        let transport = ScriptedTransport(snapshot: live)
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: gate)
        let projection = makeProjection(transport)
        defer { projection.end() }
        projection.start(isActive: true)
        try await waitUntil { await gate.entryCount == 1 }

        #expect(projection.status == .connected)
        #expect(projection.hasInventory && projection.isAwaitingSnapshot)
        #expect(projection.agentsByPane.keys.sorted() == ["w1:p1"])
        #expect(projection.liveSnapshotRevision == 0)
        #expect(projection.inventoryVerifiedAt == Date(timeIntervalSince1970: 100))
        #expect(await transport.snapshotHadLiveSubscription == [true])

        await gate.open()
        try await waitUntil {
            !projection.isAwaitingSnapshot && projection.agentsByPane.keys.sorted() == ["w1:p2"]
        }
        #expect(projection.hasInventory)
        #expect(projection.liveSnapshotRevision > 0)
    }

    @Test func anEndedProjectionKeepsItsRowsAndRejectsAnInFlightSnapshot() async throws {
        let transport = ScriptedTransport(snapshot: snapshot)
        let projection = makeProjection(transport)
        defer { projection.end() }
        projection.start(isActive: true)
        try await waitUntil { !projection.isAwaitingSnapshot }
        let revision = projection.liveSnapshotRevision
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: gate)
        await transport.setSnapshot(.fixture(protocolVersion: 22))
        let refresh = Task { await projection.refreshSidebarMetadata() }
        try await waitUntil { await gate.entryCount == 1 }
        projection.end()
        await gate.open()
        await refresh.value
        await projection.resume()
        await projection.retry()
        await projection.revalidate()

        #expect(projection.agentsByPane.keys.sorted() == ["w1:p1"])
        #expect(projection.liveSnapshotRevision == revision)
        #expect(await transport.snapshotFetchCount == 2)
    }

    @Test func summaryReadsCoalesceAndKeepThePreviousValueUntilTheFollowUpAnswers() async throws {
        let transport = ScriptedTransport(snapshot: snapshot)
        let first = AgentSummary(
            paneID: "w1:p1", status: .working, text: "first", timestamp: 1)
        let next = AgentSummary(
            paneID: "w1:p1", status: .working, text: "next", timestamp: 2)
        await transport.setAgentSummaries([first])
        let firstRead = ScriptedTransportCallGate()
        await transport.gateNextAgentSummaryRead(using: firstRead)
        let projection = makeProjection(transport)
        defer { projection.end() }
        projection.start(isActive: true)
        try await waitUntil { await firstRead.entryCount == 1 }

        await projection.refreshSidebarMetadata()
        await projection.refreshSidebarMetadata()
        #expect(await transport.agentSummaryReads == 1)
        let followUp = ScriptedTransportCallGate()
        await transport.gateNextAgentSummaryRead(using: followUp)
        await transport.setAgentSummaries([next])
        await firstRead.open()
        try await waitUntil { await followUp.entryCount == 1 }
        #expect(projection.agentsByPane["w1:p1"]?.summary == first)
        #expect(await transport.agentSummaryReads == 2)

        await followUp.open()
        try await waitUntil { projection.agentsByPane["w1:p1"]?.summary == next }
        #expect(await transport.agentSummaryReads == 2)
    }

    /// HCP-1: an old missing-plugin result must drain the queued read on the
    /// new connection, not disable that connection's summaries.
    @Test func aStaleMissingPluginReadStillDrainsTheNewConnectionsFollowUp() async throws {
        let transport = ScriptedTransport(snapshot: snapshot)
        await transport.setAgentSummaryReadFailure(NotificationRegistrationError.pluginNotInstalled)
        let oldRead = ScriptedTransportCallGate()
        await transport.gateNextAgentSummaryRead(using: oldRead)
        let projection = makeProjection(transport)
        defer { projection.end() }
        projection.start(isActive: true)
        try await waitUntil { await oldRead.entryCount == 1 }
        let revision = projection.liveSnapshotRevision
        await transport.setAgentSummaryReadFailure(nil)
        await transport.setAgentSummaries([
            AgentSummary(paneID: "w1:p1", status: .working, text: "current", timestamp: 2)
        ])
        await transport.failEventStream(.channelFailed(detail: "dropped during summary read"))
        try await waitUntil {
            projection.liveSnapshotRevision > revision && !projection.isAwaitingSnapshot
        }
        // Wait for the new resync's summary request, which follows subscription work.
        await projection.refreshSidebarMetadata()
        await oldRead.open()
        try await waitUntil { projection.agentsByPane["w1:p1"]?.summary?.text == "current" }
        #expect(await transport.agentSummaryReads == 2)
    }

    /// CONSOLE-05 safety net: a successful no-summary refresh covers its pane
    /// across a reconnect, including while the new connection's read is held.
    @Test func refreshCoverageSurvivesReconnectWithoutBringingLoadingBack() async throws {
        let transport = ScriptedTransport(snapshot: snapshot)
        let projection = makeProjection(transport, foreground: true)
        defer { projection.end() }
        projection.start(isActive: true)
        try await waitUntil {
            let refreshed = await transport.agentSummaryRefreshes == 1
            let reads = await transport.agentSummaryReads >= 2
            return refreshed && reads && !projection.isAwaitingSnapshot
                && projection.agentsByPane["w1:p1"]?.isSummaryPending == false
        }
        let revision = projection.liveSnapshotRevision
        // An unrelated record's progress declaration is an observable barrier
        // proving the replacement connection's store answer has been applied.
        await transport.setAgentSummaries([
            AgentSummary(paneID: "other", status: .working, text: "other", timestamp: 2)
        ])
        let read = ScriptedTransportCallGate()
        await transport.gateNextAgentSummaryRead(using: read)
        await transport.failEventStream(.channelFailed(detail: "reconnect after refresh"))
        try await waitUntil {
            let held = await read.entryCount == 1
            return held && projection.liveSnapshotRevision > revision && !projection.isAwaitingSnapshot
        }
        #expect(projection.agentsByPane["w1:p1"]?.isSummaryPending == false)
        await read.open()
        try await waitUntil { projection.agentsByPane["w1:p1"]?.hostReportsProgress == true }
        #expect(projection.agentsByPane["w1:p1"]?.summary == nil)
        #expect(projection.agentsByPane["w1:p1"]?.isSummaryPending == false)
        #expect(await transport.agentSummaryRefreshes == 1)
    }

    /// CONSOLE-05: a reconnect cancels the refresh whose trigger is still out,
    /// but it keeps its slot until the trigger answers. Only then does the
    /// new connection's periodic refresh run, at once (a cancelled run moves
    /// no clock), and the cancelled run covers no pane.
    @Test func aRefreshCancelledMidTriggerHandsTheCadenceToTheNewConnectionOnce() async throws {
        let transport = ScriptedTransport(snapshot: snapshot)
        let trigger = ScriptedTransportCallGate()
        await transport.gateNextAgentSummaryRefresh(using: trigger)
        let projection = makeProjection(transport, foreground: true)
        defer { projection.end() }
        projection.start(isActive: true)
        try await waitUntil { await trigger.entryCount == 1 }
        try await waitForPaneSubscription(transport, projection)
        let revision = projection.liveSnapshotRevision
        await transport.failEventStream(.channelFailed(detail: "dropped during the trigger"))
        try await waitUntil {
            projection.liveSnapshotRevision > revision && !projection.isAwaitingSnapshot
                && projection.agentsByPane["w1:p1"]?.isSummaryPending == true
        }
        // The new connection's refresh waits for the cancelled one's slot.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.agentSummaryRefreshes == 1)

        let next = ScriptedTransportCallGate()
        await transport.gateNextAgentSummaryRefresh(using: next)
        await trigger.open()
        try await waitUntil { await next.entryCount == 1 }
        #expect(projection.agentsByPane["w1:p1"]?.isSummaryPending == true)
        await next.open()
        try await waitUntil { projection.agentsByPane["w1:p1"]?.isSummaryPending == false }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.agentSummaryRefreshes == 2)
    }

    /// CONSOLE-05: a reconnect while the refresh joins its store read. The
    /// cancelled refresh keeps joining reads, the new connection's included,
    /// and only then hands over to one periodic refresh.
    @Test func aRefreshCancelledWhileJoiningItsReadHandsOverOnceTheReadsDrain() async throws {
        let transport = ScriptedTransport(snapshot: snapshot)
        let trigger = ScriptedTransportCallGate()
        await transport.gateNextAgentSummaryRefresh(using: trigger)
        let projection = makeProjection(transport, foreground: true)
        defer { projection.end() }
        projection.start(isActive: true)
        try await waitUntil { await trigger.entryCount == 1 }
        try await waitForPaneSubscription(transport, projection)
        try await waitUntil {
            let read = await transport.agentSummaryReads >= 1
            return read && projection.agentsByPane["w1:p1"]?.isSummaryPending == true
        }
        let refreshRead = ScriptedTransportCallGate()
        await transport.gateNextAgentSummaryRead(using: refreshRead)
        let readsBefore = await transport.agentSummaryReads
        await trigger.open()
        try await waitUntil { await refreshRead.entryCount == 1 }
        #expect(await transport.agentSummaryReads == readsBefore + 1)

        let revision = projection.liveSnapshotRevision
        await transport.failEventStream(.channelFailed(detail: "dropped during the read"))
        try await waitUntil {
            projection.liveSnapshotRevision > revision && !projection.isAwaitingSnapshot
        }
        // Barrier: the new connection's summary request follows its
        // subscription work; this resync's own request coalesces with it.
        await projection.refreshSidebarMetadata()
        let next = ScriptedTransportCallGate()
        await transport.gateNextAgentSummaryRefresh(using: next)
        await refreshRead.open()
        try await waitUntil { await next.entryCount == 1 }
        // The old read and the new connection's coalesced follow-up (its
        // resubscribe's resync may add one more).
        #expect(await transport.agentSummaryReads >= readsBefore + 2)
        #expect(projection.agentsByPane["w1:p1"]?.isSummaryPending == true)
        await next.open()
        try await waitUntil { projection.agentsByPane["w1:p1"]?.isSummaryPending == false }
        #expect(await transport.agentSummaryRefreshes == 2)
    }

    /// CONSOLE-05: pausing during the settle skips the re-read and leaves the
    /// periodic clock alone, so the return refreshes at once, and the paused
    /// run covers no pane.
    @Test func pausingDuringTheSettleSkipsTheReReadAndTheReturnRefreshesAtOnce() async throws {
        let transport = ScriptedTransport(snapshot: snapshot)
        let projection = makeProjection(transport, foreground: true, settle: .seconds(3600))
        defer { projection.end() }
        projection.start(isActive: true)
        try await waitUntil { await transport.agentSummaryRefreshes == 1 }
        try await waitForPaneSubscription(transport, projection)
        try await waitUntil {
            let read = await transport.agentSummaryReads >= 1
            return read && projection.agentsByPane["w1:p1"]?.isSummaryPending == true
        }
        let reads = await transport.agentSummaryReads
        projection.setSummaryRefreshGate(AgentSummaryRefreshGate(isForeground: false, isEnabled: true))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.agentSummaryReads == reads)

        projection.setSummaryRefreshGate(AgentSummaryRefreshGate(isForeground: true, isEnabled: true))
        try await waitUntil { await transport.agentSummaryRefreshes == 2 }
        #expect(projection.agentsByPane["w1:p1"]?.isSummaryPending == true)
        #expect(await transport.agentSummaryReads == reads)
    }

    /// CONSOLE-03: signals arriving while a snapshot is out coalesce into one
    /// follow-up snapshot, which a sidebar refresh waits out too.
    @Test func signalsDuringASnapshotCoalesceIntoOneFollowUp() async throws {
        let transport = ScriptedTransport(snapshot: snapshot)
        let projection = makeProjection(transport)
        defer { projection.end() }
        projection.start(isActive: true)
        try await waitForPaneSubscription(transport, projection)
        let held = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: held)
        let fetches = await transport.snapshotFetchCount
        let refresh = Task { await projection.refreshSidebarMetadata() }
        try await waitUntil { await held.entryCount == 1 }
        for status in [AgentStatus.done, .idle, .blocked] {
            #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: status)))
            try await waitUntil { projection.agentsByPane["w1:p1"]?.agent.status == status }
        }
        await held.open()
        await refresh.value
        // The held snapshot and one follow-up for the signals it outlasted.
        #expect(await transport.snapshotFetchCount == fetches + 2)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.snapshotFetchCount == fetches + 2)
        #expect(!projection.isAwaitingSnapshot)
    }

    /// CONSOLE-03: a reconnect while a snapshot is out fences its answer: it
    /// neither verifies nor replaces the last-known rows. The new connection
    /// re-snapshots only once the fenced request has ended, behind its live
    /// subscription.
    @Test func aReconnectDuringASnapshotFencesItsAnswerAndResnapshotsAfterIt() async throws {
        let transport = ScriptedTransport(snapshot: snapshot)
        let projection = makeProjection(transport)
        defer { projection.end() }
        projection.start(isActive: true)
        try await waitForPaneSubscription(transport, projection)
        let held = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: held)
        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:p9")], protocolVersion: 22))
        let refresh = Task { await projection.refreshSidebarMetadata() }
        try await waitUntil { await held.entryCount == 1 }
        let fetches = await transport.snapshotFetchCount
        let revision = projection.liveSnapshotRevision
        let subscribes = await transport.capturedSubscriptions.count
        await transport.setSnapshot(
            .fixture(agents: [.fixture(paneID: "w1:p2")], protocolVersion: 22))
        await transport.failEventStream(.channelFailed(detail: "dropped during the snapshot"))
        // Rows stay unverified until the held request ends, so this sees
        // the new connection's subscribe and status.
        try await waitUntil {
            let resubscribed = await transport.capturedSubscriptions.count > subscribes
            return resubscribed && projection.status == .connected && projection.isAwaitingSnapshot
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await transport.snapshotFetchCount == fetches)
        #expect(projection.isAwaitingSnapshot)
        #expect(projection.agentsByPane.keys.sorted() == ["w1:p1"])

        await held.open()
        await refresh.value
        try await waitUntil {
            !projection.isAwaitingSnapshot && projection.agentsByPane.keys.sorted() == ["w1:p2"]
        }
        // The new connection's own snapshot, then its resubscribe's.
        #expect(projection.liveSnapshotRevision > revision)
        #expect(await transport.snapshotFetchCount > fetches)
        #expect(await transport.snapshotHadLiveSubscription.allSatisfy { $0 })
    }

    /// CONSOLE-05: status changes while a refresh runs queue exactly one
    /// follow-up, which neither waits for the debounce nor the interval.
    @Test func statusChangesDuringARefreshQueueOneFollowUp() async throws {
        let transport = ScriptedTransport(snapshot: snapshot)
        let trigger = ScriptedTransportCallGate()
        await transport.gateNextAgentSummaryRefresh(using: trigger)
        let projection = makeProjection(transport, foreground: true)
        defer { projection.end() }
        projection.start(isActive: true)
        try await waitUntil { await trigger.entryCount == 1 }
        try await waitForPaneSubscription(transport, projection)
        for status in [AgentStatus.done, .working, .blocked] {
            await transport.setSnapshot(
                .fixture(agents: [.fixture(paneID: "w1:p1", status: status)], protocolVersion: 22))
            #expect(await transport.emit(.agentStatusChanged(paneID: "w1:p1", status: status)))
            try await waitUntil { projection.agentsByPane["w1:p1"]?.agent.status == status }
        }
        let next = ScriptedTransportCallGate()
        await transport.gateNextAgentSummaryRefresh(using: next)
        await trigger.open()
        try await waitUntil { await next.entryCount == 1 }
        await next.open()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await transport.agentSummaryRefreshes == 2)
    }
}
