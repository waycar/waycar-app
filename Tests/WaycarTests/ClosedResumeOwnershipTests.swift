import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Closed resume ownership", .timeLimit(.minutes(1)))
struct ClosedResumeOwnershipTests {
    private func row(host: UUID, terminal: String, status: AgentStatus = .idle) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host, hostName: "Host",
            agent: Agent(
                terminalID: terminal, kind: "claude", title: "Task", status: status,
                workspaceID: "w1", tabID: "t1", paneID: "p1", cwd: "/repo", revision: 1,
                agentSession: .init(agent: "claude", kind: .id, source: "herdr:claude", value: "s1")),
            workspaceLabel: "repo", repositoryCheckout: nil)
    }

    /// Owner characterization: the base includes unknown among unused
    /// statuses. This test deliberately preserves that behavior.
    @Test(arguments: [AgentStatus.idle, .done, .unknown, .working, .blocked])
    func backOutPreservesStatusGate(status: AgentStatus) async throws {
        let store = ClosedSessionsStore()
        let original = row(host: UUID(), terminal: "original")
        store.record([.init(row: original, session: nil, lastSeenRunningAt: .now)])
        let record = try #require(store.sessions.first)
        let resumed = row(host: original.hostID, terminal: "resumed", status: status)
        store.beginPendingResume(record.id, agent: resumed.id, terminal: resumed.agent.terminalID)
        var closed = false
        await store.backedOut(of: resumed.id, verifiedRow: { _ in resumed }) { _ in closed = true }
        #expect(closed == [AgentStatus.idle, .done, .unknown].contains(status))
        #expect(store.pendingResumes.isEmpty)
    }

    /// Safety net for deferred extraction: Forget while verifying keeps the
    /// unused pane hidden until its closure, without re-capturing the record.
    @Test func forgettingDuringVerificationStillClosesOnlyTheUnusedResume() async throws {
        let store = ClosedSessionsStore()
        let original = row(host: UUID(), terminal: "original")
        store.record([.init(row: original, session: nil, lastSeenRunningAt: .now)])
        let record = try #require(store.sessions.first)
        let resumed = row(host: original.hostID, terminal: "resumed")
        store.beginPendingResume(record.id, agent: resumed.id, terminal: "resumed")
        var closes = 0
        await store.backedOut(of: resumed.id, verifiedRow: { _ in
            store.forget(record.id)
            #expect(store.backedOutResumes[resumed.id] == record.id)
            return resumed
        }, closePane: { _ in closes += 1 })
        #expect(closes == 1)
        store.record([.init(row: resumed, session: nil, lastSeenRunningAt: .now)])
        #expect(store.sessions.isEmpty)
        #expect(store.backedOutResumes.isEmpty)
    }

    /// B-22: both back-outs own the same row and record. Neither record id
    /// nor current terminal identity fences the first verification's await.
    @Test func oldVerificationCannotCloseAReplacementResume() async throws {
        let store = ClosedSessionsStore()
        let original = row(host: UUID(), terminal: "original")
        store.record([.init(row: original, session: nil, lastSeenRunningAt: .now)])
        let record = try #require(store.sessions.first)
        let replacement = row(host: original.hostID, terminal: "replacement")
        let oldGate = ScriptedTransportCallGate()
        let newGate = ScriptedTransportCallGate()
        var oldEntered = false
        var newEntered = false
        var oldCloses = 0
        var newCloses = 0
        store.beginPendingResume(record.id, agent: replacement.id, terminal: "old")
        let old = Task {
            await store.backedOut(of: replacement.id, verifiedRow: { _ in
                oldEntered = true
                await oldGate.waitUntilOpen()
                return replacement
            }, closePane: { _ in oldCloses += 1 })
        }
        try await waitUntil { oldEntered }
        store.beginPendingResume(record.id, agent: replacement.id, terminal: "replacement")
        let new = Task {
            await store.backedOut(of: replacement.id, verifiedRow: { _ in
                newEntered = true
                await newGate.waitUntilOpen()
                return replacement
            }, closePane: { _ in newCloses += 1 })
        }
        try await waitUntil { newEntered }
        await oldGate.open()
        await old.value
        #expect(oldCloses == 0)
        #expect(store.backedOutResumes[replacement.id] == record.id)
        await newGate.open()
        await new.value
        #expect(newCloses == 1)
    }

    @Test(arguments: [TransportError.timedOut, .apiRejected(code: "agent_not_found", message: "not verified")])
    func oldCloseFailureCannotResolveAReplacementBackOut(error: TransportError) async throws {
        let store = ClosedSessionsStore()
        let original = row(host: UUID(), terminal: "original")
        store.record([.init(row: original, session: nil, lastSeenRunningAt: .now)])
        let record = try #require(store.sessions.first)
        let resumed = row(host: original.hostID, terminal: "resumed")
        let gate = ScriptedTransportCallGate()
        let replacementGate = ScriptedTransportCallGate()
        var closing = false
        var verifying = false
        store.beginPendingResume(record.id, agent: resumed.id, terminal: "resumed")
        let old = Task {
            await store.backedOut(of: resumed.id, verifiedRow: { _ in resumed }) { _ in
                closing = true
                await gate.waitUntilOpen()
                throw error
            }
        }
        try await waitUntil { closing }
        store.beginPendingResume(record.id, agent: resumed.id, terminal: "resumed")
        let replacement = Task {
            await store.backedOut(of: resumed.id, verifiedRow: { _ in
                verifying = true
                await replacementGate.waitUntilOpen()
                return resumed
            }, closePane: { _ in })
        }
        try await waitUntil { verifying }
        await gate.open()
        await old.value
        #expect(store.backedOutResumes[resumed.id] == record.id)
        #expect(store.pendingResumes.isEmpty)
        await replacementGate.open()
        await replacement.value
    }
}
