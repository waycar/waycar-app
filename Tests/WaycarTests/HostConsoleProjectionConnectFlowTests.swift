import Foundation
import Synchronization
import Testing

@testable import Waycar

/// A projection's side of #105: its first events subscribe carries the
/// last-known rows' pane set, so an unchanged Host needs no second
/// subscribe-and-snapshot round, and a confirmed rename or close shows
/// before the resync that follows it.
@MainActor
@Suite("Host Console projection connect flow", .timeLimit(.minutes(1)))
struct HostConsoleProjectionConnectFlowTests {
    private static let agents: [AgentInfo] = [
        .fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2", workspaceID: "w1"),
    ]
    private static let snapshot = SessionSnapshot.fixture(
        agents: agents, workspaces: [.fixture(workspaceID: "w1", label: "Proj")],
        protocolVersion: 22)

    private func makeProjection(
        transport: ScriptedTransport
    ) -> HostConsoleProjection {
        let session = EventsSession(
            subscriptions: HostConsoleProjection.subscriptions(paneIDs: []),
            connect: { transport },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .milliseconds(10), multiplier: 2, maxDelay: .milliseconds(50)),
            keepalive: nil)
        return HostConsoleProjection(
            host: .fixture(), session: session, snapshotRetryDelay: .milliseconds(10)) {}
    }

    private func waitUntilVerified(_ projection: HostConsoleProjection) async throws {
        try await waitUntil("the projection's rows should be verified") {
            projection.status == .connected && !projection.isAwaitingSnapshot
        }
    }

    @Test func aCachedPaneSetRidesTheFirstSubscribeSoAnUnchangedHostNeedsNoSecondRound()
        async throws
    {
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        let projection = makeProjection(transport: transport)
        defer { projection.end() }
        projection.seed(Self.snapshot, verifiedAt: nil)

        projection.start(isActive: true)
        try await waitUntilVerified(projection)
        // Long enough for a second subscribe the resync would have asked for.
        try await Task.sleep(for: .milliseconds(50))

        let seeded = HostConsoleProjection.subscriptions(
            paneIDs: ["w1:p1", "w1:p2"], protocolVersion: 22)
        #expect(await transport.capturedSubscriptions == [seeded])
        #expect(await transport.snapshotFetchCount == 1)
    }

    /// The pane set a cached snapshot names can be stale: herdr refuses the
    /// whole subscribe for one exited pane, and the existing fallback to the
    /// global set carries the Host to its snapshot, which installs the live
    /// pane set.
    @Test func aCachedPaneThatExitedFallsBackToTheGlobalSet() async throws {
        let live = SessionSnapshot.fixture(
            agents: [.fixture(paneID: "w1:p1")],
            workspaces: [.fixture(workspaceID: "w1", label: "Proj")], protocolVersion: 22)
        let transport = ScriptedTransport(snapshot: live)
        await transport.setMissingPanes(["w1:p2"])
        let projection = makeProjection(transport: transport)
        defer { projection.end() }
        projection.seed(Self.snapshot, verifiedAt: nil)

        projection.start(isActive: true)
        try await waitUntilVerified(projection)
        try await waitUntil("the live pane set should be installed") {
            await transport.capturedSubscriptions.count == 3
        }

        let captured = await transport.capturedSubscriptions
        #expect(
            captured == [
                HostConsoleProjection.subscriptions(
                    paneIDs: ["w1:p1", "w1:p2"], protocolVersion: 22),
                HostConsoleProjection.subscriptions(paneIDs: []),
                HostConsoleProjection.subscriptions(paneIDs: ["w1:p1"], protocolVersion: 22),
            ])
        #expect(projection.agentsByPane.keys.sorted() == ["w1:p1"])
    }

    @Test func aConfirmedRenameShowsBeforeTheResyncAnswers() async throws {
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        let projection = makeProjection(transport: transport)
        defer { projection.end() }
        projection.start(isActive: true)
        try await waitUntilVerified(projection)
        let resync = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: resync)

        try await projection.renameAgent("w1:p1", name: "reviewer")

        #expect(projection.agentsByPane["w1:p1"]?.agent.displayName == "reviewer")
        #expect(projection.inventorySnapshot?.agents.first?.name == "reviewer")
        await resync.waitForEntry()
        await resync.open()
    }

    /// A snapshot requested before a close was confirmed still lists the
    /// closed tab; laid under the confirmed close, it cannot put the rows
    /// back. The closed Agents are captured once, when the close shows.
    @Test func aCloseShowsAtOnceAndAnOlderSnapshotCannotUndoIt() async throws {
        let transport = ScriptedTransport(snapshot: Self.snapshot)
        let projection = makeProjection(transport: transport)
        defer { projection.end() }
        let captures = Mutex<[String]>([])
        projection.onAgentsClosed = { closed in
            captures.withLock { $0 += closed.map(\.row.agent.paneID) }
        }
        projection.start(isActive: true)
        try await waitUntilVerified(projection)

        // A snapshot already in flight when the close is confirmed.
        let older = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: older)
        #expect(
            await transport.emit(
                HerdrEvent(kind: GlobalEventKind.paneExited.kind, data: .object([:]))))
        await older.waitForEntry()

        try await projection.closeTab("w1:t1")
        #expect(projection.agentsByPane.isEmpty)
        #expect(captures.withLock { $0.sorted() } == ["w1:p1", "w1:p2"])

        // Told apart from the older snapshot by its workspace label: how many
        // snapshots ran is not this test's to pin, since every changed pane
        // set resubscribes and each `.connected` asks for one more.
        let authoritative = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: authoritative)
        await transport.setSnapshot(
            .fixture(workspaces: [.fixture(workspaceID: "w1", label: "Live")], protocolVersion: 22))
        await older.open()
        await authoritative.waitForEntry()
        #expect(projection.agentsByPane.isEmpty)

        await authoritative.open()
        try await waitUntil("the authoritative resync should land") {
            projection.inventorySnapshot?.workspaces.map(\.label) == ["Live"]
        }
        #expect(projection.agentsByPane.isEmpty)
        #expect(captures.withLock { $0.count } == 2)
    }
}
