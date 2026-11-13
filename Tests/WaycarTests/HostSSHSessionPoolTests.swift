import Foundation
import Testing

@testable import Waycar

@Suite("Host SSH session pool", .timeLimit(.minutes(1)))
struct HostSSHSessionPoolTests {
    @Test func concurrentAcquirersShareOneDial() async throws {
        let pool = SSHSessionPool<FakePooledSession>()
        let dialer = FakeSessionDialer()
        let gate = DialGate()
        await dialer.holdNextDial(gate)

        let first = Task { try await pool.acquire(key: "host") { try await dialer.dial() } }
        await gate.waitUntilEntered()
        let second = Task { try await pool.acquire(key: "host") { try await dialer.dial() } }
        let third = Task { try await pool.acquire(key: "host") { try await dialer.dial() } }
        try await waitUntil("both later acquirers should join the dial in flight") {
            await pool.waiterCountForTesting(key: "host") == 3
        }
        await gate.open()

        let sessions = try await [first.value, second.value, third.value]
        #expect(await dialer.dials == 1)
        #expect(sessions.allSatisfy { $0 === sessions[0] })
        #expect(await sessions[0].holds == 3)
    }

    @Test func everyAcquireIsOneHoldAndTheLastReleaseCloses() async throws {
        let pool = SSHSessionPool<FakePooledSession>()
        let dialer = FakeSessionDialer()

        let first = try await pool.acquire(key: "host") { try await dialer.dial() }
        let second = try await pool.acquire(key: "host") { try await dialer.dial() }
        #expect(first === second)
        #expect(await first.holds == 2)

        await first.release()
        #expect(await !first.isClosed)
        await second.release()
        #expect(await first.isClosed)

        let next = try await pool.acquire(key: "host") { try await dialer.dial() }
        #expect(next !== first)
        #expect(await dialer.dials == 2)
        #expect(await next.holds == 1)
    }

    @Test func aDeadSessionIsReplacedWhileItsHoldersKeepIt() async throws {
        let pool = SSHSessionPool<FakePooledSession>()
        let dialer = FakeSessionDialer()

        let dead = try await pool.acquire(key: "host") { try await dialer.dial() }
        await dead.dropConnection()
        let fresh = try await pool.acquire(key: "host") { try await dialer.dial() }

        #expect(fresh !== dead)
        #expect(await dialer.dials == 2)
        // The replacement takes no hold on the old session and does not close
        // it under its holder.
        #expect(await dead.holds == 1)
        #expect(await !dead.isClosed)
        let again = try await pool.acquire(key: "host") { try await dialer.dial() }
        #expect(again === fresh)
    }

    @Test func distinctKeysAndNilKeysDialTheirOwnSessions() async throws {
        let pool = SSHSessionPool<FakePooledSession>()
        let dialer = FakeSessionDialer()

        let a = try await pool.acquire(key: "a") { try await dialer.dial() }
        let b = try await pool.acquire(key: "b") { try await dialer.dial() }
        let privateFirst = try await pool.acquire(key: nil) { try await dialer.dial() }
        let privateSecond = try await pool.acquire(key: nil) { try await dialer.dial() }

        #expect(a !== b)
        #expect(privateFirst !== privateSecond)
        #expect(await dialer.dials == 4)
        #expect(await privateFirst.holds == 1)
    }

    @Test func aFailedDialFailsEveryWaiterAndTheNextAcquireDialsAgain() async throws {
        let pool = SSHSessionPool<FakePooledSession>()
        let dialer = FakeSessionDialer()
        let gate = DialGate()
        await dialer.holdNextDial(gate)
        await dialer.failNextDial(with: TransportError.authenticationFailed)

        let first = Task { try await pool.acquire(key: "host") { try await dialer.dial() } }
        await gate.waitUntilEntered()
        let second = Task { try await pool.acquire(key: "host") { try await dialer.dial() } }
        try await waitUntil("the second acquirer should join the failing dial") {
            await pool.waiterCountForTesting(key: "host") == 2
        }
        await gate.open()

        await #expect(throws: TransportError.authenticationFailed) { _ = try await first.value }
        await #expect(throws: TransportError.authenticationFailed) { _ = try await second.value }
        let retried = try await pool.acquire(key: "host") { try await dialer.dial() }
        #expect(await retried.holds == 1)
        #expect(await dialer.dials == 2)
    }

    @Test func aDialNobodyWaitsForIsCancelledAndItsSessionReleased() async throws {
        let pool = SSHSessionPool<FakePooledSession>()
        let dialer = FakeSessionDialer()
        let gate = DialGate()
        await dialer.holdNextDial(gate)

        let abandoned = Task { try await pool.acquire(key: "host") { try await dialer.dial() } }
        await gate.waitUntilEntered()
        abandoned.cancel()
        await #expect(throws: TransportError.cancelled) { _ = try await abandoned.value }

        // A new acquirer does not join the abandoned dial.
        let fresh = try await pool.acquire(key: "host") { try await dialer.dial() }
        #expect(await dialer.dials == 2)

        await gate.open()
        let orphan = await dialer.session(number: 2)
        #expect(orphan !== fresh)
        await orphan.waitUntilClosed()
        #expect(await !fresh.isClosed)
    }

    // MARK: Keeping a connection across a suspension (#105)

    @Test func retiringDuringKeepDoesNotRestoreTheRetiredHold() async throws {
        let pool = SSHSessionPool<FakePooledSession>()
        let dialer = FakeSessionDialer()
        let first = try await pool.acquire(key: "host", replacing: nil) { try await dialer.dial() }
        let connection = try #require(first.id)
        let gate = DialGate()
        await first.session.gateNextRetain(gate)
        let keeping = Task { await pool.keep(connection) }
        await gate.waitUntilEntered()
        await pool.retire(connection)
        await gate.open()

        #expect(await keeping.value == false)
        #expect(await first.session.holds == 1)
        let next = try await pool.acquire(key: "host") { try await dialer.dial() }
        #expect(next !== first.session)
        await first.session.release()
        #expect(await first.session.isClosed)
        await next.release()
    }

    @Test func aKeptSessionOutlivesItsLastHolderAndIsReusedWithoutADial() async throws {
        let pool = SSHSessionPool<FakePooledSession>()
        let dialer = FakeSessionDialer()
        let first = try await pool.acquire(key: "host", replacing: nil) { try await dialer.dial() }
        let connection = try #require(first.id)

        #expect(await pool.keep(connection))
        // The suspended Transport lets go: the keep alone holds it open.
        await first.session.release()
        #expect(await !first.session.isClosed)

        let returned = try await pool.acquire(key: "host", replacing: nil) {
            try await dialer.dial()
        }
        #expect(returned.session === first.session)
        #expect(returned.id == connection)
        #expect(await dialer.dials == 1)

        // Proven: the keep's hold goes back, the returning holder's stays.
        await pool.releaseKept(connection)
        try await waitUntil("the keep's hold should go back") {
            await first.session.holds == 1
        }
        #expect(await !first.session.isClosed)
    }

    @Test func aReplacementIsSharedOnlyOnceTheConnectionItReplacesIsRetired() async throws {
        let pool = SSHSessionPool<FakePooledSession>()
        let dialer = FakeSessionDialer()
        let kept = try await pool.acquire(key: "host", replacing: nil) { try await dialer.dial() }
        let keptID = try #require(kept.id)
        #expect(await pool.keep(keptID))
        await kept.session.release()

        let hedge = try await pool.acquire(key: "host", replacing: keptID) {
            try await dialer.dial()
        }
        #expect(hedge.session !== kept.session)
        #expect(hedge.id != keptID)
        #expect(await dialer.dials == 2)
        // The kept connection's probe may still answer: until its verdict,
        // everyone else is still handed the kept connection.
        let meanwhile = try await pool.acquire(key: "host") { try await dialer.dial() }
        #expect(meanwhile === kept.session)
        await meanwhile.release()

        await pool.retire(keptID)
        let after = try await pool.acquire(key: "host", replacing: nil) { try await dialer.dial() }
        #expect(after.session === hedge.session)
        #expect(after.id == hedge.id)
        #expect(await dialer.dials == 2)
        // The retired connection lost the keep's hold, its last one.
        await kept.session.waitUntilClosed()
    }

    @Test func aProvenKeptConnectionStaysSharedAndItsReplacementDoesNot() async throws {
        let pool = SSHSessionPool<FakePooledSession>()
        let dialer = FakeSessionDialer()
        let kept = try await pool.acquire(key: "host", replacing: nil) { try await dialer.dial() }
        let keptID = try #require(kept.id)
        #expect(await pool.keep(keptID))
        let hedge = try await pool.acquire(key: "host", replacing: keptID) {
            try await dialer.dial()
        }

        await pool.releaseKept(keptID)
        // A later failure retires it: still no hedge from back then.
        let after = try await pool.acquire(key: "host", replacing: nil) { try await dialer.dial() }
        #expect(after.session === kept.session)
        await pool.retire(keptID)
        let next = try await pool.acquire(key: "host", replacing: nil) { try await dialer.dial() }
        #expect(next.session !== hedge.session)
        #expect(await dialer.dials == 3)
    }

    @Test func retiringAKeptConnectionClosesItAndTheNextAcquireDials() async throws {
        let pool = SSHSessionPool<FakePooledSession>()
        let dialer = FakeSessionDialer()
        let kept = try await pool.acquire(key: "host", replacing: nil) { try await dialer.dial() }
        let keptID = try #require(kept.id)
        #expect(await pool.keep(keptID))

        // Found dead while its Transport still holds it open: no new
        // acquirer is handed it.
        await pool.retire(keptID)
        let next = try await pool.acquire(key: "host", replacing: nil) { try await dialer.dial() }
        #expect(next.session !== kept.session)
        #expect(await dialer.dials == 2)
        // The keep's hold went back with the retirement: the holder's
        // release is the last one.
        await kept.session.release()
        await kept.session.waitUntilClosed()
    }

    @Test func anAbandonedDialIsNotJoinedAndEndsWithItsLastWaiter() async throws {
        let pool = SSHSessionPool<FakePooledSession>()
        let dialer = FakeSessionDialer()
        let gate = DialGate()
        await dialer.holdNextDial(gate)
        let stuck = Task { try await pool.acquire(key: "host") { try await dialer.dial() } }
        await gate.waitUntilEntered()

        await pool.abandonDial(key: "host")
        let fresh = Task { try await pool.acquire(key: "host") { try await dialer.dial() } }
        try await waitUntil("a new acquirer should dial instead of joining") {
            await dialer.dials == 2
        }
        let session = try await fresh.value

        stuck.cancel()
        await #expect(throws: TransportError.cancelled) { _ = try await stuck.value }
        await gate.open()
        let orphan = await dialer.session(number: 2)
        #expect(orphan !== session)
        await orphan.waitUntilClosed()
        #expect(await !session.isClosed)
    }
}

/// A pooled session that counts holds and closes with its last release.
private actor FakePooledSession: SSHPooledSession {
    private(set) var holds = 1
    private(set) var isClosed = false
    private var connectionAlive = true
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    var isConnected: Bool { connectionAlive && !isClosed }

    private var retainGate: DialGate?

    func gateNextRetain(_ gate: DialGate) {
        retainGate = gate
    }

    func retain() async -> Bool {
        guard !isClosed else { return false }
        holds += 1
        let gate = retainGate
        retainGate = nil
        await gate?.enterAndWait()
        return true
    }

    func release() {
        guard holds > 0 else { return }
        holds -= 1
        guard holds == 0 else { return }
        isClosed = true
        let waiters = closeWaiters
        closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func dropConnection() {
        connectionAlive = false
    }

    func waitUntilClosed() async {
        guard !isClosed else { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }
}

private actor FakeSessionDialer {
    private(set) var dials = 0
    private var sessions: [FakePooledSession] = []
    private var sessionWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var gate: DialGate?
    private var failure: (any Error)?

    func holdNextDial(_ gate: DialGate) {
        self.gate = gate
    }

    func failNextDial(with error: any Error) {
        failure = error
    }

    /// The `number`th session a dial produced, in the order dials finished.
    func session(number: Int) async -> FakePooledSession {
        if sessions.count < number {
            await withCheckedContinuation { sessionWaiters.append((number, $0)) }
        }
        return sessions[number - 1]
    }

    func dial() async throws -> FakePooledSession {
        dials += 1
        let failure = failure
        self.failure = nil
        if let gate {
            self.gate = nil
            await gate.enterAndWait()
        }
        if let failure { throw failure }
        let session = FakePooledSession()
        sessions.append(session)
        let ready = sessionWaiters.filter { $0.count <= sessions.count }
        sessionWaiters.removeAll { $0.count <= sessions.count }
        for waiter in ready { waiter.continuation.resume() }
        return session
    }
}

/// Holds one dial until the test opens it, and tells the test when the dial
/// has started.
private actor DialGate {
    private var entered = false
    private var isOpen = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { openWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiters = openWaiters
        openWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
