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
