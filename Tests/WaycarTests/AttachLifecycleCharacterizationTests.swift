import Foundation
import Testing

@testable import Waycar

/// Safety nets using only APIs available on the base; no new production seam.
@MainActor
@Suite("Attach lifecycle characterization")
struct AttachLifecycleCharacterizationTests {
    @Test func unchangedFocusTargetKeepsTheOriginallyScheduledOperation() async throws {
        let coordinator = AgentFocusCoordinator(dwell: .zero)
        let state = viewingState()
        var calls: [String] = []
        coordinator.update(state) { _ in calls.append("first") }
        coordinator.update(state) { _ in calls.append("replacement") }
        try await waitUntil { !coordinator.isInFlight }
        #expect(calls == ["first"])
        coordinator.update(state) { _ in calls.append("duplicate") }
        #expect(!coordinator.isInFlight)
        #expect(calls == ["first"])
        coordinator.leave()
    }

    @Test func cancelledFocusDrainsBeforeOnlyTheLatestTargetStarts() async throws {
        let coordinator = AgentFocusCoordinator(dwell: .zero)
        let gate = ScriptedTransportCallGate()
        let first = viewingState()
        var calls: [String] = []
        coordinator.update(first) { _ in
            calls.append("first")
            await gate.waitUntilOpen()
            throw TransportError.timedOut
        }
        try await waitUntil { calls == ["first"] }
        coordinator.update(viewingState(terminalID: "second")) { _ in calls.append("second") }
        coordinator.leave()
        coordinator.update(viewingState(terminalID: "latest")) { _ in calls.append("latest") }
        #expect(coordinator.isInFlight)
        #expect(calls == ["first"])
        await gate.open()
        try await waitUntil { calls == ["first", "latest"] && !coordinator.isInFlight }
        coordinator.leave()
    }

    @Test func anIdleEntryChangesWindowOwnerWithoutReplacingItsPipeline() async throws {
        let host = Host.fixture()
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        let console = ConsoleStore { _, _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        console.setHosts([host])
        await console.resume()
        try await waitUntil { console.agents.count == 1 }
        let agent = try #require(console.agents.first)
        let cache = AgentTerminalCache()
        let oldOwner = UUID()
        let newOwner = UUID()
        let composer = console.composerStore(for: agent)
        let entry = cache.acquire(agent: agent, console: console, composer: composer, ownerID: oldOwner)
        entry.attach.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(Data("ready".utf8)))
        try await waitUntil { entry.attach.terminalStatus == .live }
        let pipeline = entry.attach.terminalID
        cache.release(entry, ownerID: oldOwner)
        let adopted = cache.acquire(agent: agent, console: console, composer: composer, ownerID: newOwner)
        #expect(adopted === entry)
        #expect(adopted.attach.terminalID == pipeline)
        adopted.attach.requestPaste("git status\ngit diff", bracketedPaste: true)
        let review = try #require(adopted.attach.pendingPaste)
        cache.release(entry, ownerID: oldOwner)
        #expect(adopted.attach.pendingPaste == review)
        #expect(entry.isRetained)
        #expect(cache.entries[agent.id] === entry)
        #expect(await transport.attachRequests.count == 1)
        await cache.suspend()
        #expect(!entry.isRetained)
        #expect(await transport.hasLiveAttachSession == false)
        console.setHosts([])
    }

    /// ATTACH-01 stays deferred: this pins end versus abandon at the owner
    /// boundary without changing its overlapping recovery/leave tasks.
    @Test func suspensionAbandonsItsPredecessorButOrdinaryLeaveEndsIt() async throws {
        for recovering in [false, true] {
            let trace = AttachLifecycleSessionTrace()
            let composer = AgentComposerStore(target: "w1:p1") { _ in
                Agent(.fixture(paneID: "w1:p1"))
            }
            let store = AgentAttachStore(
                target: .agentPane("w1:p1"), transportGeneration: 1,
                recordsNetworkTelemetry: false, isOnStage: { true },
                runTerminal: { request, handler in
                    let session = await trace.open(request)
                    try await handler.runEndingSession(session)
                },
                stageImage: { _, _ in throw TransportError.cancelled },
                stageFile: { _, _ in throw TransportError.cancelled },
                composer: composer, closePane: {})
            store.viewDidResize(cols: 80, rows: 24)
            try await waitUntil { store.terminalStatus == .live }
            let predecessor = store.terminalID
            if recovering {
                store.didBecomeActive(afterPossibleSuspension: true)
                try await waitUntil { store.terminalID != predecessor }
                #expect(await trace.teardowns.first == "abandon")
                #expect(await trace.requests.count == 1)
            }
            await store.leaveForTerminalHandoff().value
            #expect(await trace.teardowns.first == (recovering ? "abandon" : "end"))
            #expect(store.terminalStatus == .stopped)
            #expect(await trace.requests.allSatisfy(\.takeover))
        }
    }

    /// ATTACH-03 stays deferred: a stop awaiting teardown must not let an
    /// upgrade restart the store after it finally releases the old PTY.
    @Test func stopDuringAnUpgradeWaitPreventsTheScheduledRestart() async throws {
        let transport = ScriptedTransport()
        let gate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: gate)
        let store = AttachTerminalStore(target: "w1:p1") { request, handler in
            let session = try await transport.attachTerminal(request)
            try await handler.runEndingSession(session)
        }
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(Data("ready".utf8)))
        try await waitUntil { store.status == .live }
        store.upgradeToMosh()
        try await waitUntil { await gate.entryCount == 1 }
        #expect(store.status == .connecting)
        let stopping = Task { await store.stop() }
        try await waitUntil { await gate.entryCount == 2 }
        await gate.open()
        await stopping.value
        #expect(store.status == .stopped)
        #expect(await transport.attachRequests.count == 1)
        #expect(await transport.hasLiveAttachSession == false)
    }

    private func viewingState(terminalID: String = "first") -> AgentFocusCoordinator.ViewingState {
        .init(
            agentID: .init(hostID: hostID, paneID: "opaque:Pane/A"), terminalID: terminalID,
            transportGeneration: 1, status: .done,
            isHostReady: true, isSceneActive: true, isOnStage: true)
    }

    private let hostID = UUID()
}

private actor AttachLifecycleSessionTrace {
    private(set) var requests: [TerminalAttachRequest] = []
    private(set) var teardowns: [String] = []

    func open(_ request: TerminalAttachRequest) -> TerminalAttachSession {
        requests.append(request)
        let (output, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(Data("ready".utf8))
        return TerminalAttachSession(
            output: { output }, input: TerminalAttachInputQueue(),
            abandoner: {
                await self.record("abandon")
                continuation.finish()
            },
            ender: {
                await self.record("end")
                continuation.finish()
            })
    }

    private func record(_ event: String) {
        teardowns.append(event)
    }
}

@Suite("Recovery latch characterization")
struct TerminalRecoveryGenerationLatchCharacterizationTests {
    @Test func matchingAcquisitionAndProjectionAcknowledgeInEitherOrder() {
        for projectionFirst in [false, true] {
            var latch = TerminalRecoveryGenerationLatch()
            let pipeline = TerminalSurfaceID()
            latch.begin(projectedGeneration: nil)
            latch.bind(to: pipeline)
            if projectionFirst {
                #expect(latch.recordProjection(4) == .pending)
                #expect(latch.recordAcquisition(4, by: pipeline) == .acknowledge(4))
            } else {
                #expect(latch.recordAcquisition(4, by: pipeline) == .pending)
                #expect(latch.recordProjection(4) == .acknowledge(4))
            }
            #expect(!latch.isActive)
            #expect(latch.recordProjection(5) == nil)
        }
    }

    @Test func projectionIsMonotonicAndOnlyTheBoundPipelineMayResolveOrClear() {
        var latch = TerminalRecoveryGenerationLatch()
        let old = TerminalSurfaceID()
        let current = TerminalSurfaceID()
        latch.begin(projectedGeneration: 5)
        latch.bind(to: old)
        latch.begin(projectedGeneration: 1)
        latch.bind(to: current)
        latch.clear(boundTo: old)
        #expect(latch.isActive)
        #expect(latch.recordAcquisition(10, by: old) == nil)
        #expect(latch.recordProjection(2) == .pending)
        #expect(latch.recordAcquisition(4, by: current) == .replace(5))
        #expect(!latch.isActive)
    }

    @Test func rebindingDiscardsAcquisitionButKeepsProjectionAndCanRetainANewerTransport() {
        var latch = TerminalRecoveryGenerationLatch()
        let pipeline = TerminalSurfaceID()
        latch.begin(projectedGeneration: nil)
        latch.bind(to: pipeline)
        #expect(latch.recordAcquisition(7, by: pipeline) == .pending)
        latch.bind(to: pipeline)
        #expect(latch.recordProjection(3) == .pending)
        #expect(latch.recordAcquisition(8, by: pipeline) == .retain(8))
        latch.clear()
        latch.bind(to: pipeline)
        #expect(latch.recordAcquisition(8, by: pipeline) == nil)
        #expect(!latch.isActive)
    }
}
