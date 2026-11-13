import Foundation
import Synchronization
import Testing

@testable import Waycar

@MainActor
@Suite("Backend detection ownership", .timeLimit(.minutes(1)))
struct BackendDetectionCharacterizationTests {
    private final class Flag: Sendable {
        private let value = Mutex(false)
        var isSet: Bool { value.withLock { $0 } }
        func set() { value.withLock { $0 = true } }
    }

    @Test func externalPresenceSupersedesAnInFlightDetectionAndItsCache() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [], workspaces: []))
        let gate = ScriptedTransportCallGate()
        let answered = Flag()
        let old = HostBackendPresence(herdr: true, tmuxVersion: nil)
        let external = HostBackendPresence(herdr: true, tmuxVersion: nil, ultimate: [])
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "detection-owner-\(UUID().uuidString)")
        let cache = ConsoleInventoryCache(directory: directory)
        let store = ConsoleStore(
            inventoryCache: cache,
            makeSession: { _, _, subscriptions in
                EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
            },
            detectBackends: { _ in
                await gate.waitUntilOpen()
                answered.set()
                return old
            })
        defer {
            store.setHosts([])
            try? FileManager.default.removeItem(at: directory)
        }
        store.setHosts([host])
        await store.resume()
        await gate.waitForEntry()
        store.recordDetectedPresence(external, on: host.id)
        cache.flush()
        #expect(store.backendPresence(on: host.id) == external)
        await gate.open()
        try await waitUntil("superseded detection should return") { answered.isSet }
        // Exercise a lifecycle transition after the superseded request returns.
        await store.suspend()
        #expect(store.backendPresence(on: host.id) == external)
        #expect(cache.loadPresence(for: host)?.presence == external)
    }
}
