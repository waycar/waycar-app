import Foundation
import Synchronization
import Testing

@testable import Waycar

@MainActor
@Suite("Runtime start ownership", .timeLimit(.minutes(1)))
struct RuntimeStartCharacterizationTests {
    private final class Flag: Sendable {
        private let value = Mutex(false)
        var isSet: Bool { value.withLock { $0 } }
        func set() { value.withLock { $0 = true } }
    }

    @Test func terminalStartRemainsInFlightUntilItsSnapshotAnswers() async throws {
        let host = Host.fixture()
        let running = Flag()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [], workspaces: []))
        let gate = ScriptedTransportCallGate()
        await transport.gateNextSnapshot(using: gate)
        let stop = TransportError.herdrNotRunning(path: "/home/dev/.config/herdr/herdr.sock")
        let store = ConsoleStore(
            makeSession: { _, _, subscriptions in
                EventsSession(subscriptions: subscriptions, connect: {
                    guard running.isSet else { throw stop }
                    return transport
                }, keepalive: nil)
            },
            startRuntime: { _, _ in running.set() })
        store.setHosts([host])
        defer { store.setHosts([]) }
        await store.resume()
        let scope = ConsoleScope(hostID: host.id, backend: .herdr)
        try await waitUntil("Herdr should be stopped before the tap") {
            store.scopeStatuses[scope] == .failed(stop)
        }
        let start = Task { await store.startRuntime(.herdr, on: host.id) }
        await gate.waitForEntry()
        #expect(store.isStarting(.herdr, on: host.id))
        #expect(store.offersStart(of: .herdr, on: host.id))
        #expect(await store.startRuntime(.herdr, on: host.id) == false)
        await gate.open()
        #expect(await start.value)
        #expect(!store.isStarting(.herdr, on: host.id))
    }

    /// Each runtime owns its own start, even when the same Host starts two.
    /// A successful old-target start must not publish its detection.
    @Test func serverStartsAreIndependentAndAnEditedHostRejectsTheirOutcomes() async {
        let host = Host.fixture()
        let codexGate = ScriptedTransportCallGate()
        let openCodeGate = ScriptedTransportCallGate()
        let presence = HostBackendPresence(herdr: true, tmuxVersion: nil)
        let store = ConsoleStore(
            detectBackends: { _ in presence },
            startRuntime: { _, backend in
                switch backend {
                case .codex: await codexGate.waitUntilOpen()
                case .opencode: await openCodeGate.waitUntilOpen()
                case .herdr, .core, .tmux, .zellij, .ultimate: break
                }
            })
        store.setHosts([host])
        defer { store.setHosts([]) }
        let codex = Task { await store.startRuntime(.codex, on: host.id) }
        let opencode = Task { await store.startRuntime(.opencode, on: host.id) }
        await codexGate.waitForEntry()
        await openCodeGate.waitForEntry()
        #expect(store.serverRuntimeState(.codex, on: host.id) == .starting)
        #expect(store.serverRuntimeState(.opencode, on: host.id) == .starting)
        #expect(await store.startRuntime(.codex, on: host.id) == false)
        var edited = host
        edited.address = "changed.example"
        store.setHosts([edited])
        // The old attempt remains in flight until its request returns.
        #expect(store.isStarting(.codex, on: host.id))
        await codexGate.open()
        await openCodeGate.open()
        #expect(await codex.value == false)
        #expect(await opencode.value == false)
        #expect(store.backendPresence(on: host.id) == nil)
        #expect(store.startErrors(on: host.id).isEmpty)
        #expect(!store.isStarting(.codex, on: host.id))
        #expect(!store.isStarting(.opencode, on: host.id))
    }
}
