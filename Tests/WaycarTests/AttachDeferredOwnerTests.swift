import Foundation
import Testing
import UIKit

@testable import Waycar

/// Safety nets for high-risk owners deliberately left unchanged until a Mac
/// pass can exercise their disk, continuation and keyboard ordering.
@MainActor
struct AgentLastFrameDeferredOwnerTests {
    @Test func removalsWhileLockedFilterOldFramesButNotAFreshRecapture() async throws {
        let directory = AgentLastFrameStoreTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let first = AgentLastFrameStoreTests.agent("w1:p1", host: host)
        let second = AgentLastFrameStoreTests.agent("w1:p2", host: host)
        let writer = AgentLastFrameStore(directory: directory)
        for agent in [first, second] {
            writer.record(AgentLastFrameStoreTests.image(), size: AgentLastFrameStoreTests.size, for: agent, host: host)
        }
        await writer.settle()
        let indexURL = directory.appending(path: "index.json")
        let originalIndex = try Data(contentsOf: indexURL)
        let lock = DeviceLock()
        let store = AgentLastFrameStore(directory: directory, readIndex: { url in
            lock.isLocked ? .unreadable : ConsoleInventoryCache.FileAccess.live.read(url)
        })
        let scope = ConsoleScope(hostID: host.id, backend: .herdr)
        store.discard(first.id)
        store.retainAgents([second.id], verifiedScopes: [scope])
        store.retainAgents([first.id, second.id], verifiedScopes: [scope])
        store.record(AgentLastFrameStoreTests.image(), size: AgentLastFrameStoreTests.size, for: first, host: host)
        let freshFile = try #require(store.cachedEntries.first?.file)
        await store.settle()
        #expect(try Data(contentsOf: indexURL) == originalIndex)
        #expect(try AgentLastFrameStoreTests.images(in: directory).count == 2)
        lock.isLocked = false
        #expect(Set(store.cachedEntries.map(\.agentID)) == [first.id, second.id])
        #expect(store.cachedEntries.first(where: { $0.agentID == first.id })?.file == freshFile)
        #expect(store.frame(for: first.id, host: host) != nil)
        await store.settle()
    }

    /// The catalog asked for while the index is unreadable applies to the
    /// disk's frames once it loads, and their files are swept.
    @Test func aHostCatalogWhileLockedAppliesWhenTheIndexLoads() async throws {
        let directory = AgentLastFrameStoreTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let kept = Host.fixture()
        let removed = Host.fixture()
        let writer = AgentLastFrameStore(directory: directory)
        for host in [kept, removed] {
            writer.record(
                AgentLastFrameStoreTests.image(), size: AgentLastFrameStoreTests.size,
                for: AgentLastFrameStoreTests.agent("w1:p1", host: host), host: host)
        }
        await writer.settle()
        let lock = DeviceLock()
        let store = AgentLastFrameStore(directory: directory, readIndex: { url in
            lock.isLocked ? .unreadable : ConsoleInventoryCache.FileAccess.live.read(url)
        })
        store.retainHosts([kept])
        await store.settle()
        #expect(try AgentLastFrameStoreTests.images(in: directory).count == 2)
        lock.isLocked = false
        #expect(store.cachedEntries.map(\.hostID) == [kept.id])
        await store.settle()
        #expect(try AgentLastFrameStoreTests.images(in: directory).count == 1)
        #expect(AgentLastFrameStore(directory: directory).cachedEntries.map(\.hostID) == [kept.id])
    }

    /// The first load sweeps files no index entry names (a write the app
    /// did not live to index).
    @Test func theFirstLoadSweepsFilesNoEntryNames() async throws {
        let directory = AgentLastFrameStoreTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let agent = AgentLastFrameStoreTests.agent("w1:p1", host: host)
        let writer = AgentLastFrameStore(directory: directory)
        writer.record(AgentLastFrameStoreTests.image(), size: AgentLastFrameStoreTests.size, for: agent, host: host)
        await writer.settle()
        try Data("orphan".utf8).write(to: directory.appending(path: "orphan.jpg"))
        let store = AgentLastFrameStore(directory: directory)
        #expect(store.cachedEntries.map(\.agentID) == [agent.id])
        await store.settle()
        #expect(try AgentLastFrameStoreTests.images(in: directory).count == 1)
        #expect(store.frame(for: agent.id, host: host) != nil)
    }

    /// A capture's JPEG lands on the disk queue after the main actor moved
    /// on: a frame discarded or recaptured meanwhile does not come back, and
    /// only the newest capture's file stays.
    @Test func aQueuedEncodingCannotBringBackADiscardedOrReplacedFrame() async throws {
        let directory = AgentLastFrameStoreTests.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let gone = AgentLastFrameStoreTests.agent("w1:p1", host: host)
        let recaptured = AgentLastFrameStoreTests.agent("w1:p2", host: host)
        let store = AgentLastFrameStore(directory: directory)
        let image = AgentLastFrameStoreTests.image()
        let size = AgentLastFrameStoreTests.size
        store.record(image, size: size, for: gone, host: host)
        store.discard(gone.id)
        store.record(image, size: size, for: recaptured, host: host)
        let replaced = try #require(store.cachedEntries.first?.file)
        store.record(image, size: size, for: recaptured, host: host)
        let newest = try #require(store.cachedEntries.first?.file)
        #expect(newest != replaced)
        await store.settle()
        #expect(store.frame(for: gone.id, host: host) == nil)
        #expect(store.cachedEntries.map(\.file) == [newest])
        #expect(try AgentLastFrameStoreTests.images(in: directory) == [newest])
        let reopened = AgentLastFrameStore(directory: directory)
        #expect(reopened.cachedEntries.map(\.file) == [newest])
        #expect(reopened.frame(for: recaptured.id, host: host) != nil)
        await reopened.settle()
    }
}

@MainActor
struct MessageJumpDeferredOwnerTests {
    @Test func cancellingWhileIdleDoesNotPoisonTheNextWalkOrItsMovementFlag() async throws {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.maxSteps = 1
        configuration.unchangedFramesBeforeEnd = 1
        var controller: TerminalMessageJumpController?
        defer { controller = nil }
        controller = TerminalMessageJumpController(configuration: configuration, step: { _, _ in
            controller?.frameDidChange("next")
        }, visibleMessages: { [$0] })
        let jump = try #require(controller)
        jump.frameDidChange("entry")
        jump.cancel()
        #expect(await jump.jump(.older) == .found)
        #expect(jump.lastRunMovedViewport)
        #expect(!jump.isRunning)
        jump.cancel()
        #expect(await jump.returnToLive() == .reachedEnd)
        #expect(!jump.lastRunMovedViewport)
        #expect(!jump.isRunning)
    }

    @Test func anOlderJumpFinishingCannotClearTheReplacementProgress() async throws {
        let wiring = AgentMessageJumpWiring()
        let first = DeferredOwnerGate()
        let second = DeferredOwnerGate()
        defer { first.open(); second.open(); wiring.resetSession() }
        var firstEnded = false
        wiring.runJump(.older) { _ in
            await first.wait()
            firstEnded = true
        }
        try await waitUntil { first.isWaiting && wiring.runningDirection == .older }
        wiring.runJump(.newer) { _ in await second.wait() }
        try await waitUntil { second.isWaiting && wiring.runningDirection == .newer }
        first.open()
        try await waitUntil { firstEnded }
        #expect(wiring.isJumpRunning)
        #expect(wiring.runningDirection == .newer)
        second.open()
        try await waitUntil { !wiring.isJumpRunning }
        #expect(wiring.jumpInvocationCount == 2)
    }

    @Test func transcriptRefreshesCoalesceAndStayHeldUntilTheWalkFinishes() async throws {
        let first = DeferredOwnerGate()
        let second = DeferredOwnerGate()
        let walk = DeferredOwnerGate()
        let snapshot = HarnessJumpCaptures.transcript(
            kind: "pi", messages: [("turn", .user, "Explain the parser changes")])
        var reads = 0
        var delivered = 0
        let wiring = AgentMessageJumpWiring(readTranscript: {
            reads += 1
            if reads == 1 { await first.wait() } else { await second.wait() }
            return snapshot
        }, jumpUsesTranscript: true)
        defer { first.open(); second.open(); walk.open(); wiring.resetSession() }
        wiring.onTranscript = { _ in delivered += 1 }
        wiring.runJump(.older) { _ in await walk.wait() }
        try await waitUntil { walk.isWaiting && wiring.isJumpRunning }
        wiring.refreshTranscript()
        try await waitUntil { first.isWaiting }
        wiring.refreshTranscript()
        wiring.refreshTranscript()
        first.open()
        try await waitUntil { delivered == 1 && second.isWaiting }
        let frame = "Explain the parser changes"
        #expect(wiring.messageIndex.visibleMessageKeys(frame).isEmpty)
        second.open()
        try await waitUntil { delivered == 2 }
        #expect(reads == 2)
        #expect(wiring.messageIndex.visibleMessageKeys(frame).isEmpty)
        walk.open()
        try await waitUntil { !wiring.isJumpRunning }
        #expect(wiring.messageIndex.visibleMessageKeys(frame) == ["transcript:turn"])
    }

    /// A settle timer whose step already got its frame wakes later (its
    /// sleep ignores cancellation): the wait id keeps it from timing out
    /// the next step's wait.
    @Test func aStaleSettleTimerCannotTimeOutTheNextStep() async throws {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.maxSteps = 3
        configuration.unchangedFramesBeforeEnd = 1
        let sleeps = JumpSleepLedger()
        var steps = 0
        let controller = TerminalMessageJumpController(
            configuration: configuration,
            step: { _, _ in steps += 1 },
            visibleMessages: { $0 == "TARGET" ? ["TARGET"] : [] },
            sleep: { @MainActor _ in await sleeps.sleep() })
        defer { sleeps.releaseAll() }
        controller.frameDidChange("start")
        let jump = Task { await controller.jump(.older) }
        try await waitUntil { sleeps.started == 1 }
        controller.frameDidChange("one")
        try await waitUntil { sleeps.started == 2 }
        #expect(steps == 2)
        sleeps.release(0)
        try await waitUntil { sleeps.finished == 1 }
        #expect(controller.isRunning)
        #expect(steps == 2)
        controller.frameDidChange("TARGET")
        #expect(await jump.value == .found)
        #expect(!controller.isRunning)
    }

    /// The live wait's own timer does time it out.
    @Test func theLiveSettleTimerTimesOutItsStep() async throws {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.maxSteps = 3
        configuration.unchangedFramesBeforeEnd = 1
        let sleeps = JumpSleepLedger()
        var steps = 0
        let controller = TerminalMessageJumpController(
            configuration: configuration,
            step: { _, _ in steps += 1 },
            visibleMessages: { _ in [] },
            sleep: { @MainActor _ in await sleeps.sleep() })
        defer { sleeps.releaseAll() }
        controller.frameDidChange("start")
        let jump = Task { await controller.jump(.older) }
        try await waitUntil { sleeps.started == 1 }
        sleeps.release(0)
        #expect(await jump.value == .reachedEnd)
        #expect(steps == 1)
        #expect(!controller.lastRunMovedViewport)
    }

    /// An enclosing-task cancel whose handler reaches the main actor only
    /// after its run ended, with no run in progress, changes nothing: the
    /// next run walks normally.
    @Test func aCancelHandlerLandingBetweenRunsDoesNotPoisonTheNext() async throws {
        var configuration = TerminalMessageJumpController.Configuration()
        configuration.maxSteps = 3
        let sleeps = JumpSleepLedger()
        let barrier = DeferredOwnerGate()
        var passed = false
        let controller = TerminalMessageJumpController(
            configuration: configuration,
            step: { _, _ in },
            visibleMessages: { $0 == "TARGET" ? ["TARGET"] : [] },
            sleep: { @MainActor _ in await sleeps.sleep() })
        defer {
            barrier.open()
            sleeps.releaseAll()
        }
        controller.enclosingCancelHandlerBarrier = { await barrier.wait() }
        controller.enclosingCancelHandlerDidPassPoisonWindow = { passed = true }
        controller.frameDidChange("start")
        let first = Task { await controller.jump(.older) }
        try await waitUntil { sleeps.started == 1 }
        controller.frameDidChange("one")
        first.cancel()
        #expect(await first.value == .cancelled)
        try await waitUntil { barrier.isWaiting }
        #expect(!controller.isRunning)
        barrier.open()
        try await waitUntil { passed }
        let second = Task { await controller.jump(.older) }
        try await waitUntil { sleeps.started == 2 }
        controller.frameDidChange("TARGET")
        #expect(await second.value == .found)
    }

    /// A reset drops the transcript read in flight and its pending reread:
    /// the old read's answer reaches nobody, and a read started after the
    /// reset is the one a later refresh coalesces behind.
    @Test func aResetDropsTheReadInFlightAndItsReread() async throws {
        let gates = [DeferredOwnerGate(), DeferredOwnerGate(), DeferredOwnerGate()]
        let snapshot = HarnessJumpCaptures.transcript(
            kind: "pi", messages: [("turn", .user, "Explain the parser changes")])
        var reads = 0
        var delivered = 0
        let wiring = AgentMessageJumpWiring(readTranscript: {
            reads += 1
            await gates[min(reads, 3) - 1].wait()
            return snapshot
        }, jumpUsesTranscript: true)
        defer {
            gates.forEach { $0.open() }
            wiring.resetSession()
        }
        wiring.onTranscript = { _ in delivered += 1 }
        wiring.refreshTranscript()
        try await waitUntil { gates[0].isWaiting }
        wiring.refreshTranscript()
        wiring.resetSession()
        wiring.refreshTranscript()
        try await waitUntil { gates[1].isWaiting }
        gates[0].open()
        wiring.refreshTranscript()
        #expect(reads == 2)
        #expect(delivered == 0)
        gates[1].open()
        try await waitUntil { delivered == 1 && gates[2].isWaiting }
        #expect(reads == 3)
        gates[2].open()
        try await waitUntil { delivered == 2 }
        #expect(reads == 3)
    }

    /// A snapshot held for a walk belongs to its session: a reset drops it,
    /// and the old walk ending later applies nothing to the new session.
    @Test func aSnapshotHeldForAWalkDiesWithItsSession() async throws {
        let walk = DeferredOwnerGate()
        let snapshot = HarnessJumpCaptures.transcript(
            kind: "pi", messages: [("turn", .user, "Explain the parser changes")])
        var delivered = 0
        let wiring = AgentMessageJumpWiring(readTranscript: { snapshot }, jumpUsesTranscript: true)
        defer { walk.open(); wiring.resetSession() }
        wiring.onTranscript = { _ in delivered += 1 }
        var walkEnded = false
        wiring.runJump(.older) { _ in
            await walk.wait()
            walkEnded = true
        }
        try await waitUntil { walk.isWaiting && wiring.isJumpRunning }
        wiring.refreshTranscript()
        try await waitUntil { delivered == 1 }
        let frame = "Explain the parser changes"
        #expect(wiring.messageIndex.visibleMessageKeys(frame).isEmpty)
        wiring.resetSession()
        #expect(!wiring.isJumpRunning)
        walk.open()
        try await waitUntil { walkEnded }
        #expect(wiring.messageIndex.visibleMessageKeys(frame).isEmpty)
        #expect(!wiring.isJumpRunning)
        wiring.refreshTranscript()
        try await waitUntil { delivered == 2 }
        #expect(wiring.messageIndex.visibleMessageKeys(frame) == ["transcript:turn"])
    }
}

/// Settle-timer sleeps the test wakes one by one; each ignores
/// cancellation, so a timer whose wait was answered can still wake late.
@MainActor
private final class JumpSleepLedger {
    private var gates: [DeferredOwnerGate] = []
    private(set) var finished = 0
    var started: Int { gates.count }

    func sleep() async {
        let gate = DeferredOwnerGate()
        gates.append(gate)
        await gate.wait()
        finished += 1
    }

    func release(_ index: Int) { gates[index].open() }

    func releaseAll() { gates.forEach { $0.open() } }
}

@MainActor
struct PaneHistoryDeferredOwnerTests {
    @Test func aLeaveRejectsScrollAndRefreshUntilItsRequestFinishesEvenIfItFails() async throws {
        let gate = DeferredOwnerGate()
        defer { gate.open() }
        var reads = 0
        var leaves = 0
        let history = TmuxPaneHistory(scroll: { _, _ in
            reads += 1
            return PaneHistoryScroll(position: .inHistory)
        }, leave: {
            leaves += 1
            await gate.wait()
            throw TransportError.cancelled
        })
        history.refresh()
        try await waitUntil { history.position == .inHistory }
        #expect(!history.enteredHistory)
        await history.depart()
        #expect(leaves == 0, "departure must preserve the desk's copy mode")
        let leave = Task { await history.leave() }
        try await waitUntil { gate.isWaiting }
        #expect(history.holdsInput)
        history.scroll(towardOlderContent: true, rows: 10)
        history.refresh()
        gate.open()
        await leave.value
        #expect(leaves == 1)
        #expect(reads == 1)
        #expect(history.position == .live, "a failed leave still releases input, as before")
        #expect(!history.holdsInput)
    }
}

@MainActor
struct ShellOpeningDeferredOwnerTests {
    /// The private View's creation/handoff lifecycle is deferred, not replaced
    /// by this narrower existing-API guard on definitive versus lost replies.
    @Test func backendRejectionsStayDistinctFromAnUnclearCreationOutcome() {
        let message = AgentDetailView.terminalCreationFailureMessage(
            for: TransportError.apiRejected(code: "gone", message: "Workspace is gone"), backend: .tmux)
        #expect(message == "tmux couldn't create the terminal: Workspace is gone")
        let cancelled = AgentDetailView.terminalCreationFailureMessage(for: TransportError.cancelled, backend: .tmux)
        #expect(cancelled.contains("may already exist"))
        #expect(!cancelled.contains("couldn't create"))
    }
}

@MainActor
private final class DeferredOwnerGate {
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
