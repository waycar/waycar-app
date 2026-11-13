import Foundation
import Synchronization
import Testing

@testable import Waycar

/// Characterization through existing APIs; no conversion-only seams.
@MainActor
@Suite("Console auxiliary lifecycle safety nets")
struct ConsoleAuxiliaryOwnerTests {
    @Test func disconnectKeepsSeedAndSuppressesAnOutstandingSidebarAnswer() async throws {
        let id = UUID()
        let layout = ConsoleInventoryCache.SidebarLayout(data: nil)
        let transport = ScriptedTransport()
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSidebarLayoutRead(gate)
        let provider = ScriptedTransportProvider(transports: [id: transport])
        let store = HerdrSidebarSnapshotStore()
        store.seed(id, layout: layout)
        let changes = Mutex(0)
        store.reconcile([id: .init(generation: 1, revision: 0)], transports: provider) {
            changes.withLock { $0 += 1 }
        }
        try await waitUntil { await transport.sidebarLayoutReads == 1 }
        store.reconcile([:], transports: provider, didChange: {})
        await gate.open()
        await store.waitForPendingReads()
        #expect(store.states[id] == .loaded(nil))
        #expect(store.layoutFiles[id] == layout)
        #expect(changes.withLock { $0 } == 0)
        #expect(await store.refresh(id, transports: provider, didChange: {}) == nil)
    }

    @Test func removalIgnoresARequestThatWasNotConfirmed() async {
        let checkout = RepositoryCheckout(
            repoKey: "/repo/.git", repoName: "repo", repoRoot: "/repo",
            checkoutPath: "/worktree", isLinkedWorktree: true)
        let request = WorktreeRemovalRequest(identity: .init(
            hostID: UUID(), workspaceID: "w1", checkout: checkout))
        var calls = 0
        let store = WorktreeDetailStore(
            request: request, workspaceLabel: "worktree", checkout: checkout,
            list: { _ in throw CancellationError() },
            remove: {
                calls += 1
                return WorktreeRemovalReceipt(request: $0, affectedAgentIDs: [])
            }, hasWorkingAgent: { false })
        await store.finishRemoval(request)
        #expect(calls == 0)
        #expect(store.removalPhase == .idle)
        store.prepareConfirmation()
        #expect(store.confirmation?.request == request)
        store.cancelConfirmation()
        #expect(store.beginRemoval() == nil)
    }

    /// Deferred CONSOLE-23: selector cache must survive clearing a followed
    /// file, unlike its totals and displayed context window.
    @Test func clearingUsageRetainsTheModelWindowCache() async {
        let store = AgentSessionUsageStore()
        let bytes = Data((#"{"type":"message","message":{"role":"assistant","provider":"p","model":"m","usage":{"cost":{"total":0.25}}}}"# + "\n").utf8)
        var lookups = 0
        let read: (RemoteFileRange) async throws -> RemoteFileSlice = { range in
            RemoteFileSlice(data: range.offset == 0 ? bytes : Data(), length: UInt64(bytes.count))
        }
        let resolve: (String) async throws -> Int? = { _ in
            lookups += 1
            return 100_000
        }
        await store.refresh(path: "/sessions/a.jsonl", read: read, resolveContextWindow: resolve)
        #expect(lookups == 1)
        store.clear()
        #expect(store.usage.cost == nil)
        await store.refresh(path: "/sessions/b.jsonl", read: read, resolveContextWindow: resolve)
        #expect(lookups == 1)
        #expect(store.contextWindow == 100_000)
    }
}
