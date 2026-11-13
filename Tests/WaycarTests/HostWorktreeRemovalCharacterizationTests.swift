import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Host worktree removal characterization", .timeLimit(.minutes(1)))
struct HostWorktreeRemovalCharacterizationTests {
    private let host = Host.fixture()
    private let snapshot = SessionSnapshot.fixture(
        agents: [.fixture(paneID: "w1:p1")],
        workspaces: [
            .fixture(
                workspaceID: "w1", label: "Linked", repoName: "repo",
                checkoutPath: "/work/linked", isLinkedWorktree: true)
        ], protocolVersion: 22)

    private func makeProjection(_ transport: ScriptedTransport) -> HostConsoleProjection {
        let session = EventsSession(
            subscriptions: HostConsoleProjection.subscriptions(paneIDs: []),
            connect: { transport }, keepalive: nil)
        let projection = HostConsoleProjection(
            host: host, session: session, snapshotRetryDelay: .seconds(1)) {}
        projection.seed(snapshot, verifiedAt: nil)
        return projection
    }

    private func makeRequest(_ projection: HostConsoleProjection) throws -> WorktreeRemovalRequest {
        let checkout = try #require(projection.agentsByPane["w1:p1"]?.repositoryCheckout)
        return WorktreeRemovalRequest(
            identity: WorktreeIdentity(hostID: host.id, workspaceID: "w1", checkout: checkout))
    }

    @Test func duplicateRequestsAndDuplicateIdentitiesCannotReplaceTheAuthorizedOperation() async throws {
        let transport = ScriptedTransport(snapshot: snapshot)
        let projection = makeProjection(transport)
        defer { projection.end() }
        projection.start(isActive: true)
        try await waitUntil { !projection.isAwaitingSnapshot }
        let request = try makeRequest(projection)
        let authorization = ScriptedTransportCallGate()
        await transport.gateNextWorktreeAuthorization(using: authorization)
        let removal = Task { try await projection.removeWorktree(request) }
        try await waitUntil { await authorization.entryCount == 1 }

        await #expect(throws: WorktreeRemovalError.alreadyInProgress) {
            try await projection.removeWorktree(request)
        }
        await #expect(throws: WorktreeRemovalError.alreadyInProgress) {
            try await projection.removeWorktree(WorktreeRemovalRequest(identity: request.identity))
        }
        await transport.setSnapshot(.fixture(protocolVersion: 22))
        await authorization.open()
        let receipt = try await removal.value
        #expect(receipt.request == request)
        #expect(receipt.affectedAgentIDs == [ConsoleAgent.ID(hostID: host.id, paneID: "w1:p1")])
        #expect(await transport.removedWorktreeRequests == [request])
        try await waitUntil { projection.agentsByPane.isEmpty }
        #expect(projection.removedWorktreesByAgent.values.contains(receipt))
    }

    @Test func onlyASnapshotRequestedAfterDispatchCanConfirmAnUnansweredRemoval() async throws {
        let transport = ScriptedTransport(snapshot: snapshot)
        let projection = makeProjection(transport)
        defer { projection.end() }
        projection.start(isActive: true)
        try await waitUntil { !projection.isAwaitingSnapshot }
        let request = try makeRequest(projection)
        let oldSnapshot = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: oldSnapshot)
        let refresh = Task { await projection.refreshSidebarMetadata() }
        try await waitUntil { await oldSnapshot.entryCount == 1 }
        await transport.setWorktreeRemoveFailure(TransportError.timedOut)

        await #expect(throws: WorktreeRemovalError.outcomeUnconfirmed) {
            try await projection.removeWorktree(request)
        }
        let newSnapshot = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: newSnapshot)
        await transport.setSnapshot(.fixture(protocolVersion: 22))
        await oldSnapshot.open()
        try await waitUntil { await newSnapshot.entryCount == 1 }
        #expect(projection.removedWorktreesByAgent.isEmpty)
        await newSnapshot.open()
        await refresh.value
        try await waitUntil { !projection.removedWorktreesByAgent.isEmpty }
        #expect(projection.removedWorktreesByAgent.values.first?.request == request)
    }
}
