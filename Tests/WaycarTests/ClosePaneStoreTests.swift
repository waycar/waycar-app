import Foundation
import Testing

@testable import Waycar

/// Close-pane action logic (#13, User Story 9) against a scripted close
/// closure: the close path, the double-tap guard, and outcome mapping — no
/// SSH, no ConsoleStore. Whether the screen confirms first is
/// `ClosedSession.resumesConversation(of:)` (#185).
@MainActor
@Suite("Close pane store")
struct ClosePaneStoreTests {
    @Test func closesAndReportsSuccess() async {
        let recorder = CloseRecorder()
        let store = ClosePaneStore { try recorder.record() }

        await store.closePane()

        #expect(store.state == .closed)
        #expect(recorder.calls == 1)
    }

    @Test func rapidDoubleTapClosesOnce() async throws {
        // Two closes landing before the first RPC returns must fire
        // pane.close once: the in-flight guard flips synchronously, so the
        // second bails while the first is still parked at the transport hop.
        let gate = Gate()
        let recorder = CloseRecorder()
        let store = ClosePaneStore {
            await gate.waitUntilOpen()
            try recorder.record()
        }

        let first = Task { await store.closePane() }
        try await waitUntil("the first close should reach the gate") {
            await gate.enteredCount == 1
        }
        let second = Task { await store.closePane() }
        await second.value  // the guard makes this return without touching the gate.
        #expect(await gate.enteredCount == 1)

        await gate.open()
        await first.value

        #expect(recorder.calls == 1)
        #expect(store.state == .closed)
    }

    @Test func serverRejectionLeavesTheStoreFailedAndUnclosed() async {
        // herdr rejecting the close surfaces a friendly message and never
        // reports .closed, so the screen stays put and the agent survives.
        let recorder = CloseRecorder()
        let store = ClosePaneStore {
            try recorder.record()
            throw HerdrAPIError(code: "400", message: "pane is busy")
        }

        await store.closePane()

        #expect(store.state == .failed("herdr rejected the close: pane is busy"))
        #expect(recorder.calls == 1)
    }

    @Test func disconnectedHostMapsToAFriendlyMessage() async {
        let store = ClosePaneStore {
            throw TransportError.sshUnreachable(detail: "connection dropped")
        }

        await store.closePane()

        #expect(store.state == .failed("The Host is not connected."))
    }
}

/// Counts the close closure's invocations; MainActor-only, like the store.
@MainActor
private final class CloseRecorder {
    private(set) var calls = 0

    func record() throws {
        calls += 1
    }
}

/// Parks the first caller until opened, so the double-tap guard can be
/// exercised deterministically.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var enteredCount = 0

    func waitUntilOpen() async {
        enteredCount += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let resuming = waiters
        waiters.removeAll()
        for waiter in resuming { waiter.resume() }
    }
}
