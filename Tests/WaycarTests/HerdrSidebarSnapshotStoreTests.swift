import Foundation
import Observation
import Synchronization
import Testing

@testable import Waycar

@MainActor
@Suite("Herdr sidebar snapshots", .timeLimit(.minutes(1)))
struct HerdrSidebarSnapshotStoreTests {
    private let hostID = UUID()
    private let first = Data(#"{"v":1,"agent_panel_sort":"priority","sidebar":{"agents":{"rows":[[{"token":"terminal_title_stripped"}]]}}}"#.utf8)
    private let second = Data(#"{"v":1,"sidebar":{"agents":{"rows":[[{"token":"workspace"}]]}}}"#.utf8)

    @Test func readsExistingTransportAndPublishesMissingMalformedAndErrorFallbacks() async {
        let transport = ScriptedTransport()
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HerdrSidebarSnapshotStore()
        store.reconcile([hostID: .init(generation: 1, revision: 0)], transports: provider, didChange: {})
        await store.waitForPendingReads()
        #expect(store.states[hostID] == .loaded(nil))
        for data in [Data("invalid".utf8), Data(#"{"v":2}"#.utf8), first] {
            await transport.setSidebarLayout(data)
            await store.refresh(transports: provider, didChange: {})
            #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(data))
        }
        await transport.setSidebarLayoutReadFailure(NotificationRegistrationError.pluginNotInstalled)
        await store.refresh(transports: provider, didChange: {})
        #expect(store.states[hostID] == .unavailable)
        #expect(store.snapshot(for: hostID) == nil)
        #expect(await transport.sidebarLayoutReads == 5)
        #expect(await transport.capturedSubscriptions.isEmpty)
        #expect(await transport.isClosed == false)
    }

    @Test func singleHostRefreshReturnsThatHostsStateOrNilWithoutAConnection() async {
        let transport = ScriptedTransport()
        let other = ScriptedTransport()
        await transport.setSidebarLayout(first)
        let otherID = UUID()
        let provider = ScriptedTransportProvider(transports: [hostID: transport, otherID: other])
        let store = HerdrSidebarSnapshotStore()
        #expect(await store.refresh(hostID, transports: provider, didChange: {}) == nil)
        #expect(await transport.sidebarLayoutReads == 0)
        store.reconcile([hostID: .init(generation: 1, revision: 0), otherID: .init(generation: 1, revision: 0)],
                        transports: provider, didChange: {})
        await store.waitForPendingReads()
        await transport.setSidebarLayout(second)
        #expect(await store.refresh(hostID, transports: provider, didChange: {})
            == .loaded(AgentRowLayoutSnapshot.decode(second)))
        #expect(await transport.sidebarLayoutReads == 2)
        #expect(await other.sidebarLayoutReads == 1)
        await transport.setSidebarLayoutReadFailure(NotificationRegistrationError.pluginNotInstalled)
        #expect(await store.refresh(hostID, transports: provider, didChange: {}) == .unavailable)
        #expect(store.states[otherID] == .loaded(nil))
    }

    /// A nil answer from the herdr transport means the Host has no plugin
    /// fields snapshot: the layout is cleared, not kept (the fallback fill
    /// in the Field Editor depends on `.loaded(nil)`); only a thrown
    /// TransportError keeps the cached layout.
    @Test func nilReadReportsAMissingSnapshotAndAFailedReadKeepsTheCache() async {
        let transport = ScriptedTransport()
        await transport.setSidebarLayout(first)
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HerdrSidebarSnapshotStore()
        store.reconcile([hostID: .init(generation: 1, revision: 0)], transports: provider, didChange: {})
        await store.waitForPendingReads()
        await transport.setSidebarLayoutReadFailure(TransportError.sshUnreachable(detail: "down"))
        await store.refresh(transports: provider, didChange: {})
        #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(first))
        await transport.setSidebarLayoutReadFailure(nil)
        await transport.setSidebarLayout(nil)
        await store.refresh(transports: provider, didChange: {})
        #expect(store.states[hostID] == .loaded(nil))
        #expect(store.snapshot(for: hostID) == nil)
    }

    @Test func generationChangeRejectsAnOldReadEvenWhenItIgnoresCancellation() async {
        let transport = ScriptedTransport()
        await transport.setSidebarLayout(first)
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HerdrSidebarSnapshotStore()
        store.reconcile([hostID: .init(generation: 1, revision: 0)], transports: provider, didChange: {})
        await store.waitForPendingReads()
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSidebarLayoutRead(gate)
        let oldRead = Task { await store.refresh(transports: provider, didChange: {}) }
        await gate.waitForEntry()
        await transport.setSidebarLayout(second)
        store.reconcile([hostID: .init(generation: 2, revision: 0)], transports: provider, didChange: {})
        // The layout in force stays until the new connection's read lands.
        #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(first))
        await store.waitForPendingReads()
        #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(second))
        await gate.open()
        await oldRead.value
        #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(second))
    }

    @Test func removedAndReaddedHostCannotReuseAnOldRequestIdentity() async {
        let transport = ScriptedTransport()
        await transport.setSidebarLayout(first)
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HerdrSidebarSnapshotStore()
        let connection: [Host.ID: HerdrSidebarSnapshotStore.Connection] = [hostID: .init(generation: 1, revision: 0)]
        store.reconcile(connection, transports: provider, didChange: {})
        await store.waitForPendingReads()
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSidebarLayoutRead(gate)
        let oldRead = Task { await store.refresh(transports: provider, didChange: {}) }
        await gate.waitForEntry()
        store.reconcile([:], transports: provider, didChange: {})
        // Losing the connection stops reading, not the layout.
        #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(first))
        store.invalidate(hostID)
        #expect(store.states.isEmpty)
        await transport.setSidebarLayout(second)
        store.reconcile(connection, transports: provider, didChange: {})
        await store.waitForPendingReads()
        await gate.open()
        await oldRead.value
        #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(second))
    }

    @Test func aConnectionFailureKeepsTheLayoutAndASeedYieldsToAFreshRead() async {
        let transport = ScriptedTransport()
        await transport.setSidebarLayout(second)
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HerdrSidebarSnapshotStore()
        store.seed(hostID, layout: ConsoleInventoryCache.SidebarLayout(data: first))
        #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(first))

        await transport.setSidebarLayoutReadFailure(TransportError.timedOut)
        store.reconcile([hostID: .init(generation: 1, revision: 0)], transports: provider, didChange: {})
        await store.waitForPendingReads()
        #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(first))

        await transport.setSidebarLayoutReadFailure(nil)
        store.reconcile([hostID: .init(generation: 1, revision: 1)], transports: provider, didChange: {})
        await store.waitForPendingReads()
        #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(second))
        #expect(store.layoutFiles[hostID] == ConsoleInventoryCache.SidebarLayout(data: second))
    }

    @Test func syncFromPluginReportsItsOwnFailedReadWhileTheConsoleKeepsTheLayout() async {
        let transport = ScriptedTransport()
        await transport.setSidebarLayout(first)
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HerdrSidebarSnapshotStore()
        store.reconcile([hostID: .init(generation: 1, revision: 0)], transports: provider, didChange: {})
        await store.waitForPendingReads()

        await transport.setSidebarLayoutReadFailure(TransportError.timedOut)
        #expect(await store.refresh(hostID, transports: provider, didChange: {}) == .unavailable)
        #expect(store.states[hostID] == .loaded(AgentRowLayoutSnapshot.decode(first)))

        await transport.setSidebarLayoutReadFailure(nil)
        await transport.setSidebarLayout(second)
        #expect(await store.refresh(hostID, transports: provider, didChange: {})
            == .loaded(AgentRowLayoutSnapshot.decode(second)))
    }

    @Test func unchangedProjectionDoesNotReadAgainAndRevisionPublishesObservably() async {
        let transport = ScriptedTransport()
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HerdrSidebarSnapshotStore()
        let connection: [Host.ID: HerdrSidebarSnapshotStore.Connection] = [hostID: .init(generation: 1, revision: 0)]
        store.reconcile(connection, transports: provider, didChange: {})
        await store.waitForPendingReads()
        store.reconcile(connection, transports: provider, didChange: {})
        await store.waitForPendingReads()
        #expect(await transport.sidebarLayoutReads == 1)
        let changed = Mutex(false)
        withObservationTracking {
            _ = store.snapshot(for: hostID)
        } onChange: {
            changed.withLock { $0 = true }
        }
        await transport.setSidebarLayout(first)
        store.reconcile([hostID: .init(generation: 1, revision: 1)], transports: provider, didChange: {})
        await store.waitForPendingReads()
        #expect(changed.withLock { $0 })
        #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(first))
    }

    /// Every Console row and the open terminal's switcher read `states`, and
    /// a status change re-reads the layout. A read answering the layout
    /// already in force must not invalidate them.
    @Test func aReadAnsweringTheSameLayoutDoesNotInvalidateReaders() async {
        let transport = ScriptedTransport()
        await transport.setSidebarLayout(first)
        let provider = ScriptedTransportProvider(transports: [hostID: transport])
        let store = HerdrSidebarSnapshotStore()
        store.reconcile([hostID: .init(generation: 1, revision: 0)], transports: provider, didChange: {})
        await store.waitForPendingReads()
        #expect(store.snapshot(for: hostID) == AgentRowLayoutSnapshot.decode(first))

        let changed = Mutex(false)
        withObservationTracking {
            _ = store.states
        } onChange: {
            changed.withLock { $0 = true }
        }
        store.reconcile([hostID: .init(generation: 1, revision: 1)], transports: provider, didChange: {})
        await store.waitForPendingReads()
        #expect(await transport.sidebarLayoutReads == 2)
        #expect(!changed.withLock { $0 })
    }
}
