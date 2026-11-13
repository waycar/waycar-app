import Foundation
import Testing

@testable import Waycar

@Suite("Sidebar snapshot machine")
struct SidebarSnapshotMachineTests {
    private let connection = HerdrSidebarSnapshotStore.Connection(generation: 1, revision: 0)

    @Test func cachedLayoutAndLatestReadAnswerStayDistinct() {
        let file = ConsoleInventoryCache.SidebarLayout(data: nil)
        var machine = SidebarSnapshotMachine().after([.seed(file)])
        #expect(machine.handle(.reconcile(connection)) == [.read(1)])
        #expect(machine.handle(.finished(1, .connectionFailed)) == [
            .publish(.init(displayed: .loaded(nil), answer: .unavailable, file: file)), .didChange
        ])
        #expect(machine.handle(.reconcile(connection)).isEmpty)
        #expect(machine.handle(.refresh) == [.read(2)])
        _ = machine.handle(.finished(2, .failed))
        #expect(machine.facts.displayed == .unavailable)
        #expect(machine.facts.file == nil)
        #expect(machine.handle(.seed(file)).isEmpty)
    }

    @Test func revisionDisconnectAndReadditionRetireReadTokens() {
        var machine = SidebarSnapshotMachine().after([.reconcile(connection)])
        #expect(machine.facts.displayed == .loading)
        let revised = HerdrSidebarSnapshotStore.Connection(generation: 1, revision: 1)
        #expect(machine.handle(.reconcile(revised)) == [.cancel(1), .read(2)])
        #expect(machine.handle(.finished(1, .loaded(nil))).isEmpty)
        #expect(machine.handle(.reconcile(nil)) == [.cancel(2)])
        #expect(machine.facts.displayed == .loading) // Existing disconnect behavior.
        #expect(machine.handle(.finished(2, .loaded(nil))).isEmpty)
        #expect(machine.handle(.refresh).isEmpty)
        _ = machine.handle(.invalidate)
        #expect(machine.facts == .init())
        _ = machine.handle(.reconcile(connection))
        #expect(machine.pendingToken == 3)
        #expect(machine.handle(.finished(1, .loaded(nil))).isEmpty)
        _ = machine.handle(.finished(3, .loaded(nil)))
        #expect(machine.facts.displayed == .loaded(nil))
        #expect(machine.facts.file == .init(data: nil))
    }

    @Test func uncachedConnectionFailureStopsLoadingAndRefreshSupersedes() {
        var machine = SidebarSnapshotMachine().after([.reconcile(connection)])
        #expect(machine.handle(.refresh) == [.cancel(1), .read(2)])
        _ = machine.handle(.finished(2, .connectionFailed))
        #expect(machine.facts.displayed == .unavailable)
        #expect(machine.facts.answer == .unavailable)
        #expect(machine.pendingToken == nil)
        #expect(machine.handle(.finished(2, .loaded(nil))).isEmpty)
    }
}
