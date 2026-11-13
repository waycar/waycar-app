import Foundation
import Testing

@testable import Waycar

/// Public-API safety nets for the Console lifecycles surveyed in CONSOLE-01,
/// 07, 08, 10 and 16. These require no seams added by the conversions.
@MainActor
@Suite("Console lifecycle characterization", .timeLimit(.minutes(1)))
struct ConsoleLifecycleCharacterizationTests {
    private func store(
        _ transport: ScriptedTransport,
        verification: ConsoleStore.Countdown = .after(.seconds(3600)),
        undo: ConsoleStore.Countdown = .after(.seconds(3600))
    ) -> ConsoleStore {
        let defaults = UserDefaults(suiteName: "console-lifecycle-\(UUID().uuidString)") ?? .standard
        return ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults),
            chatMode: ChatModeStore(defaults: defaults),
            backendPreferences: HostBackendPreferences(defaults: defaults),
            verificationTimeout: verification,
            tabCloseUndoWindow: undo,
            makeSession: { _, _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions, connect: { transport }, keepalive: nil,
                    // These tests hold RPCs, not liveness deadlines; keep the
                    // latter beyond waitCeiling even on a heavily loaded host.
                    clock: LivenessClock(now: { ContinuousClock.now }, sleep: { _ in
                        try await Task.sleep(for: .seconds(3600))
                    }))
            })
    }

    @Test func concurrentLifecycleCallsFinishInCallOrder() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let console = store(transport)
        defer { console.setHosts([]) }
        console.setHosts([host])
        await console.resume()
        try await waitUntil { console.verifiedAgents.count == 1 }

        // Hold reactivate in its revalidation, then enqueue suspend/resume
        // behind it. Neither may overtake the held activation.
        let ping = ScriptedTransportCallGate()
        await transport.gateNextPing(using: ping)
        let activating = Task { await console.reactivate() }
        try await waitUntil { await ping.entryCount == 1 }
        var suspensionRequested = false
        let suspending = Task { @MainActor in
            suspensionRequested = true
            await console.suspend()
        }
        try await waitUntil { suspensionRequested }
        let resuming = Task {
            await suspending.value
            await console.resume()
        }
        #expect(console.isActive)
        await ping.open()
        await activating.value
        await resuming.value
        try await waitUntil { console.isActive && console.hostStatuses[host.id] == .connected }
    }

    @Test func cancellingOneVerificationWaiterDoesNotSettleAnother() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture())
        let timeout = ScriptedTransportCallGate()
        let console = store(transport, verification: .init { await timeout.waitUntilOpen() })
        defer { console.setHosts([]) }
        // No resume: both actions wait for verification, not an RPC response.
        console.setHosts([host])
        let first = Task { try await console.renameAgent("w1:p1", name: "first", on: host.id) }
        let second = Task { try await console.renameAgent("w1:p2", name: "second", on: host.id) }
        try await waitUntil { await timeout.entryCount == 2 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await timeout.open()
        await #expect(throws: TransportError.timedOut) { try await second.value }
        #expect(await transport.agentRenames.isEmpty)
    }

    @Test func aWaitingRPCUsesTheSnapshotThatVerifiesItsHost() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let timeout = ScriptedTransportCallGate()
        let console = store(transport, verification: .init { await timeout.waitUntilOpen() })
        defer { console.setHosts([]) }
        console.setHosts([host])
        let rename = Task { try await console.renameAgent("w1:p1", name: "ready", on: host.id) }
        try await waitUntil { await timeout.entryCount == 1 }
        await console.resume()
        try await rename.value
        #expect(await transport.agentRenames.map(\.name) == ["ready"])
        // A timer already resumed after success cannot settle the waiter twice.
        await timeout.open()
    }

    @Test func notificationVisibilityWritesReadThePrecedingReplacement() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let console = store(transport)
        defer { console.setHosts([]) }
        console.setHosts([host])
        await console.resume()
        try await waitUntil { console.verifiedAgents.count == 1 }
        await transport.setNotificationConfig(Data(#"{"push":"keep"}"#.utf8))
        let read = ScriptedTransportCallGate()
        await transport.gateNextNotificationConfigRead(read)
        let tmux = Task { await console.setShowsTmux(false, for: host.id) }
        try await waitUntil { await read.entryCount == 1 }
        let core = Task { await console.setShowsRuntime(false, runtime: .core, for: host.id) }
        try await waitUntil { !console.backendPreferences.showsRuntime(.core, for: host.id) }
        await read.open()
        await tmux.value
        await core.value
        let data = try #require(await transport.notificationConfig)
        let fields = try JSONDecoder().decode([String: JSONValue].self, from: data)
        #expect(fields == ["push": .string("keep"), "tmux_enabled": .bool(false),
            "core_enabled": .bool(false)])
    }

    @Test func aFailedMarkerReadKeepsTheCacheUntilTheNextVerificationReadsIt() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let marker = ChatModeMarker(
            paneID: "w9:gone", terminalID: "old", kind: "claude", cwd: "/work",
            session: nil, launchedAt: Date())
        await transport.setChatModeMarkers([marker])
        let console = store(transport)
        defer { console.setHosts([]) }
        let id = ConsoleAgent.ID(hostID: host.id, paneID: marker.paneID)
        console.setHosts([host])
        await console.resume()
        try await waitUntil { console.chatMode.marker(for: id) == marker }
        await console.suspend()
        await transport.setChatModeMarkers([])
        await transport.setChatModeMarkerReadFailure(
            TransportError.channelFailed(detail: "read refused"))
        let before = await transport.chatModeMarkerReadCount
        await console.resume()
        try await waitUntil { await transport.chatModeMarkerReadCount > before }
        #expect(console.chatMode.marker(for: id) == marker)
        await console.suspend()
        await transport.setChatModeMarkerReadFailure(nil)
        await console.resume()
        try await waitUntil { console.chatMode.marker(for: id) == nil }
    }

    @Test func aFailedTabCloseReleasesItsFollowerWithoutAnotherClose() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(
            snapshot: .fixture(agents: [.fixture(paneID: "w1:p1"), .fixture(paneID: "w1:p2")]))
        await transport.setCloseFailure(.channelFailed(detail: "close refused"))
        let close = ScriptedTransportCallGate()
        await transport.gateNextTabClose(using: close)
        let undo = ScriptedTransportCallGate()
        let console = store(transport, undo: .init { await undo.waitUntilOpen() })
        defer { console.setHosts([]) }
        console.setHosts([host])
        await console.resume()
        try await waitUntil { console.verifiedAgents.count == 2 }
        for row in console.agents { console.scheduleTabClose(row) }
        try await waitUntil { await undo.entryCount == 2 }
        await undo.open()
        try await waitUntil {
            let entered = await close.entryCount
            return entered == 1 && console.pendingTabCloses.count == 2
                && console.pendingTabCloses.values.allSatisfy { $0.phase == .closing }
        }
        await close.open()
        try await waitUntil { console.pendingTabCloses.isEmpty }
        #expect(console.tabCloseFailure != nil)
        #expect(await close.entryCount == 1)
        #expect(console.agents.count == 2)
    }
}
