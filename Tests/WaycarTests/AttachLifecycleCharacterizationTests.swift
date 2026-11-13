import Foundation
import Synchronization
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

    /// ATTACH-03 pin, a pre-existing race kept as it is: the automatic
    /// mosh fallback checks for a stop only before it invalidates mosh, so a
    /// stop that lands while the invalidation runs is followed by one more
    /// start. That run sees the stop and ends its session at once; the
    /// stopped store then reads Connecting.
    @Test func aStopDuringTheFallbackInvalidationIsFollowedByOneSelfEndingRun() async throws {
        let mosh = ScriptedMoshSessions()
        let invalidation = CharacterizationGate()
        let finished = CharacterizationCounter()
        let store = AttachTerminalStore(
            target: .agentPane("w1:p1"), takeover: true,
            runDidFinish: { _ in finished.increment() },
            onMoshFailure: { _ in await invalidation.wait() }
        ) { request, handler in
            await handler.transportDidBecomeReady(1, flavor: .mosh)
            let session = mosh.factory(
                ScriptedMoshSessions.bootstrap, request.cols, request.rows, .seconds(6))
            try await handler.runEndingSession(session)
        }
        defer { invalidation.open() }
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { mosh.sessions.count == 1 }
        mosh.sessions[0].fail(TransportError.moshSessionFailed(detail: "handshake"))
        try await waitUntil { invalidation.isWaiting }
        #expect(store.status == .connecting)
        #expect(store.endedWithMoshFailure)
        await store.stop()
        #expect(store.status == .stopped)
        invalidation.open()
        try await waitUntil { finished.value == 2 }
        #expect(mosh.sessions.count == 2)
        #expect(mosh.sessions[1].teardown == .ended)
        #expect(store.status == .connecting)
        #expect(!store.isRunningMosh)
        #expect(!store.isAwaitingTransport)
        #expect(!store.canUpgradeToMosh)
    }

    /// ATTACH-03 pin: an upgrade while the run still waits for its
    /// transport cancels that run, which ends silently, and starts exactly
    /// one replacement; the scheduled upgrade cannot be asked for twice.
    @Test func anUpgradeWhileAwaitingTransportCancelsTheRunAndStartsOnce() async throws {
        let opens = AttachLifecycleSessionTrace()
        let runs = CharacterizationCounter()
        let store = AttachTerminalStore(target: .agentPane("w1:p1"), takeover: true) { request, handler in
            if await runs.increment() == 1 { try await Task.sleep(for: .seconds(3600)) }
            await handler.transportDidBecomeReady(2, flavor: .ssh)
            try await handler.runEndingSession(await opens.open(request))
        }
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { runs.value == 1 }
        #expect(store.isAwaitingTransport)
        #expect(!store.canUpgradeToMosh, "a run with no flavor yet is not an SSH session")
        await store.stop()

        let upgrading = AttachTerminalStore(target: .agentPane("w1:p1"), takeover: true) { request, handler in
            await handler.transportDidBecomeReady(1, flavor: .ssh)
            if await runs.increment() == 2 { try await Task.sleep(for: .seconds(3600)) }
            try await handler.runEndingSession(await opens.open(request))
        }
        upgrading.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { runs.value == 2 }
        #expect(upgrading.canUpgradeToMosh)
        upgrading.upgradeToMosh()
        #expect(!upgrading.canUpgradeToMosh)
        #expect(upgrading.status == .connecting)
        upgrading.upgradeToMosh()
        try await waitUntil { upgrading.status == .live }
        #expect(runs.value == 3)
        #expect(await opens.requests.count == 1)
        await upgrading.stop()
        #expect(await opens.teardowns.first == "end")
    }

    /// ATTACH-03 pin: a mosh session's blank-frame grace belongs to its
    /// session. A session that ends inside the grace ends; its timer never
    /// turns the terminal live, and a reattach starts its own grace.
    @Test func aBlankFrameGraceDiesWithItsSession() async throws {
        let mosh = ScriptedMoshSessions()
        let store = AttachTerminalStore(
            target: .agentPane("w1:p1"), takeover: true, blankFrameGrace: .seconds(3600)
        ) { request, handler in
            await handler.transportDidBecomeReady(1, flavor: .mosh)
            let session = mosh.factory(
                ScriptedMoshSessions.bootstrap, request.cols, request.rows, .seconds(6))
            try await handler.runEndingSession(session)
        }
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { mosh.sessions.count == 1 }
        mosh.sessions[0].emit("\u{1B}[H\u{1B}[2J")
        mosh.sessions[0].finish()
        try await waitUntil { store.status == .ended("The session ended.") }
        #expect(!store.hasBeenLive)
        store.retry()
        try await waitUntil { mosh.sessions.count == 2 }
        mosh.sessions[1].emit("\u{1B}[H\u{1B}[2J")
        #expect(store.status == .connecting)
        mosh.sessions[1].emit("$ ready")
        try await waitUntil { store.status == .live }
        await store.stop()
    }

    /// ATTACH-01 pin: a contact check that answers after the screen left
    /// changes nothing; the leave ends the session cleanly.
    @Test func aContactCheckAnsweringAfterLeaveChangesNothing() async throws {
        let link = GatedContactLink()
        let trace = AttachLifecycleSessionTrace()
        let store = makeMoshAttach(trace: trace, link: link)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { store.terminalStatus == .live && store.terminalRunsMosh }
        let pipeline = store.terminalID
        store.didBecomeActive(afterPossibleSuspension: true)
        try await waitUntil { link.checks == 1 }
        await store.leave().value
        link.answer(0, heard: false)
        #expect(await trace.teardowns.first == "end")
        #expect(store.terminalID == pipeline)
        #expect(store.terminalStatus == .stopped)
        #expect(await trace.requests.count == 1)
    }

    /// ATTACH-01 pin: a second return supersedes the first one's contact
    /// check; only the newest check's answer decides, and a heard server
    /// keeps the session.
    @Test func aNewerReturnSupersedesTheContactCheckInFlight() async throws {
        let link = GatedContactLink()
        let trace = AttachLifecycleSessionTrace()
        let store = makeMoshAttach(trace: trace, link: link)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { store.terminalStatus == .live && store.terminalRunsMosh }
        let pipeline = store.terminalID
        store.didBecomeActive(afterPossibleSuspension: true)
        try await waitUntil { link.checks == 1 }
        store.didBecomeActive(afterPossibleSuspension: true)
        try await waitUntil { link.checks == 2 }
        link.answer(0, heard: false)
        link.answer(1, heard: true)
        // The kept session is asked to repaint: the newest check ran.
        try await waitUntil { link.repaints == 1 }
        #expect(store.terminalID == pipeline)
        #expect(store.terminalStatus == .live)
        await store.leave().value
        #expect(store.terminalID == pipeline)
        #expect(await trace.teardowns.first == "end", "the superseded check replaced nothing")
        #expect(await trace.requests.count == 1)
    }

    /// ATTACH-01 pin: an unheard contact check replaces the pipeline,
    /// abandoning (never ending) the predecessor; a leave queued behind
    /// that replacement then ends the replacement cleanly.
    @Test func anUnheardContactCheckAbandonsAndALeaveBehindItEnds() async throws {
        let link = GatedContactLink()
        let trace = AttachLifecycleSessionTrace()
        let store = makeMoshAttach(trace: trace, link: link)
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { store.terminalStatus == .live && store.terminalRunsMosh }
        let pipeline = store.terminalID
        store.didBecomeActive(afterPossibleSuspension: true)
        try await waitUntil { link.checks == 1 }
        link.answer(0, heard: false)
        try await waitUntil { store.terminalID != pipeline }
        #expect(store.terminalStatus == .waitingForSize)
        #expect(await trace.sessionTeardowns.first?.first == "abandon")
        store.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { await trace.requests.count == 2 }
        try await waitUntil { store.terminalStatus == .live }
        await store.leaveForTerminalHandoff().value
        #expect(await trace.sessionTeardowns.last?.first == "end")
        #expect(store.terminalStatus == .stopped)
    }

    private func makeMoshAttach(
        trace: AttachLifecycleSessionTrace, link: GatedContactLink
    ) -> AgentAttachStore {
        let composer = AgentComposerStore(target: "w1:p1") { _ in Agent(.fixture(paneID: "w1:p1")) }
        return AgentAttachStore(
            target: .agentPane("w1:p1"), transportGeneration: 1,
            recordsNetworkTelemetry: false, isOnStage: { true },
            runTerminal: { request, handler in
                await handler.transportDidBecomeReady(1, flavor: .mosh)
                let session = await trace.open(request, link: link)
                try await handler.runEndingSession(session)
            },
            stageImage: { _, _ in throw TransportError.cancelled },
            stageFile: { _, _ in throw TransportError.cancelled },
            composer: composer, closePane: {})
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
    /// Each opened session's teardowns, in open order.
    private(set) var sessionTeardowns: [[String]] = []

    func open(
        _ request: TerminalAttachRequest, link: (any TerminalSessionLink)? = nil
    ) -> TerminalAttachSession {
        requests.append(request)
        let index = sessionTeardowns.count
        sessionTeardowns.append([])
        let (output, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        continuation.yield(Data("ready".utf8))
        return TerminalAttachSession(
            output: { output }, input: TerminalAttachInputQueue(), link: link,
            abandoner: {
                await self.record("abandon", session: index)
                continuation.finish()
            },
            ender: {
                await self.record("end", session: index)
                continuation.finish()
            })
    }

    private func record(_ event: String, session: Int) {
        teardowns.append(event)
        sessionTeardowns[session].append(event)
    }
}

/// A mosh link whose return contact checks the test answers one by one.
private final class GatedContactLink: TerminalSessionLink, Sendable {
    private struct State {
        var waiters: [CheckedContinuation<Bool, Never>?] = []
        var repaints = 0
    }

    private let state = Mutex(State())

    var checks: Int { state.withLock { $0.waiters.count } }
    var repaints: Int { state.withLock { $0.repaints } }

    func answer(_ index: Int, heard: Bool) {
        let waiter = state.withLock { current -> CheckedContinuation<Bool, Never>? in
            defer { current.waiters[index] = nil }
            return current.waiters[index]
        }
        waiter?.resume(returning: heard)
    }

    func connectivity() -> AsyncStream<TerminalLinkConnectivity> {
        AsyncStream { $0.yield(.connected) }
    }

    func firstContact() async -> TerminalLinkFirstContact { .answered }

    func awaitServerContact(within timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            state.withLock { $0.waiters.append(continuation) }
        }
    }

    func repaint(cols: Int, rows: Int) async {
        state.withLock { $0.repaints += 1 }
    }
}

@MainActor
private final class CharacterizationCounter {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}

@MainActor
private final class CharacterizationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    var isWaiting: Bool { continuation != nil }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
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
