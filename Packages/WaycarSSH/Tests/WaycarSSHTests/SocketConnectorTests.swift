import Darwin
import Foundation
import Testing

@testable import WaycarSSH

// Hang-prone by construction: a race that waits for the wrong signal parks
// forever on a scripted attempt or attempt delay.
@Suite("Socket candidate racing", .serialized, .timeLimit(.minutes(1)))
struct SocketConnectorTests {
    @Test("an unanswered address gives way to the next one after the attempt delay")
    func unansweredCandidateYieldsAfterAttemptDelay() async throws {
        let start = ContinuousClock.now
        let deadline = start + .seconds(12)
        let fixture = ScriptedSocketFixture(
            now: start,
            outcomes: [.unanswered, .connected],
            attemptDelay: .immediate)

        let descriptor = try await SocketConnector.connect(
            to: SSHEndpoint(host: "example.test", port: 22),
            until: deadline,
            resolver: FixedSocketAddressResolver(families: [AF_INET6, AF_INET]),
            operations: fixture.operations)

        #expect(descriptor == 101)
        // Each attempt owns the caller's whole budget; the loser is closed.
        #expect(fixture.snapshot == ScriptedSocketFixture.Snapshot(
            openedFamilies: [AF_INET6, AF_INET],
            waitDeadlines: [deadline, deadline],
            closedDescriptors: [100],
            requestedDelays: [.milliseconds(250)]))
    }

    @Test("a refused address hands over at once and exhaustion keeps the last failure")
    func refusedCandidatesFallThroughWithoutTheAttemptDelay() async {
        let start = ContinuousClock.now
        let deadline = start + .seconds(12)
        // The attempt delay never elapses, so only the refusal can start the
        // second address.
        let fixture = ScriptedSocketFixture(
            now: start,
            outcomes: [.rejected, .rejected],
            attemptDelay: .parked)

        await #expect(throws: SSHError.connectionFailed) {
            _ = try await SocketConnector.connect(
                to: SSHEndpoint(host: "example.test", port: 22),
                until: deadline,
                resolver: FixedSocketAddressResolver(families: [AF_INET6, AF_INET]),
                operations: fixture.operations)
        }

        #expect(fixture.snapshot == ScriptedSocketFixture.Snapshot(
            openedFamilies: [AF_INET6, AF_INET],
            waitDeadlines: [deadline, deadline],
            closedDescriptors: [100, 101],
            requestedDelays: [.milliseconds(250)]))
    }

    @Test("addresses alternate families, starting with the resolver's first family")
    func candidatesInterleaveAddressFamilies() async {
        #expect(await openedFamilies(
            resolving: [AF_INET6, AF_INET6, AF_INET, AF_INET])
            == [AF_INET6, AF_INET, AF_INET6, AF_INET])
        #expect(await openedFamilies(
            resolving: [AF_INET, AF_INET, AF_INET, AF_INET6])
            == [AF_INET, AF_INET6, AF_INET, AF_INET])
    }

    @Test("caller cancellation closes every attempt in flight")
    func cancellationClosesEveryAttempt() async {
        let fixture = ScriptedSocketFixture(
            now: ContinuousClock.now,
            outcomes: [.unanswered, .unanswered],
            attemptDelay: .immediate)
        let task = Task {
            try await SocketConnector.connect(
                to: SSHEndpoint(host: "example.test", port: 22),
                until: ContinuousClock.now + .seconds(30),
                resolver: FixedSocketAddressResolver(families: [AF_INET6, AF_INET]),
                operations: fixture.operations)
        }
        await fixture.parkedAttempts.waitUntilParked(2)

        task.cancel()

        await #expect(throws: SSHError.cancelled) {
            _ = try await task.value
        }
        #expect(fixture.snapshot.openedFamilies == [AF_INET6, AF_INET])
        #expect(fixture.snapshot.closedDescriptors.sorted() == [100, 101])
    }

    @Test("an attempt that connects while the race settles is closed, not leaked")
    func lateConnectionIsClosed() async throws {
        let fixture = ScriptedSocketFixture(
            now: ContinuousClock.now,
            outcomes: [.connectsAsCancelled, .connected],
            attemptDelay: .immediate)

        let descriptor = try await SocketConnector.connect(
            to: SSHEndpoint(host: "example.test", port: 22),
            until: ContinuousClock.now + .seconds(30),
            resolver: FixedSocketAddressResolver(families: [AF_INET6, AF_INET]),
            operations: fixture.operations)

        #expect(descriptor == 101)
        #expect(fixture.snapshot.closedDescriptors == [100])
    }

    @Test("no address starts once the caller's deadline has passed")
    func noCandidateStartsAfterTheDeadline() async {
        let start = ContinuousClock.now
        let fixture = ScriptedSocketFixture(
            now: start,
            outcomes: [.timedOut, .connected],
            attemptDelay: .parked)

        await #expect(throws: SSHError.timedOut) {
            _ = try await SocketConnector.connect(
                to: SSHEndpoint(host: "example.test", port: 22),
                until: start + .seconds(12),
                resolver: FixedSocketAddressResolver(families: [AF_INET6, AF_INET]),
                operations: fixture.operations)
        }

        #expect(fixture.snapshot.openedFamilies == [AF_INET6])
        #expect(fixture.snapshot.closedDescriptors == [100])
    }

    /// Families in the order the connector opened sockets when every address
    /// refuses and the attempt delay never elapses.
    private func openedFamilies(resolving families: [Int32]) async -> [Int32] {
        let fixture = ScriptedSocketFixture(
            now: ContinuousClock.now,
            outcomes: [],
            attemptDelay: .parked)
        _ = try? await SocketConnector.connect(
            to: SSHEndpoint(host: "example.test", port: 22),
            until: ContinuousClock.now + .seconds(30),
            resolver: FixedSocketAddressResolver(families: families),
            operations: fixture.operations)
        return fixture.snapshot.openedFamilies
    }
}

struct FixedSocketAddressResolver: SocketAddressResolving {
    let addresses: [SocketAddress]

    init(addresses: [SocketAddress]) {
        self.addresses = addresses
    }

    /// Placeholder addresses for scripted operations, which never read the
    /// bytes; each is distinct so equality still tells them apart.
    init(families: [Int32]) {
        addresses = families.enumerated().map { index, family in
            SocketAddress(
                family: family,
                type: SOCK_STREAM,
                protocol: IPPROTO_TCP,
                bytes: Data([UInt8(index)]))
        }
    }

    func resolve(
        _ endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant
    ) async throws -> [SocketAddress] {
        addresses
    }
}

private enum ScriptedCandidateOutcome: Sendable, Equatable {
    /// The wait expires; the fixture clock jumps to its deadline.
    case timedOut
    /// The wait ends and SO_ERROR reports a failure.
    case rejected
    case connected
    /// Parks until the race cancels it.
    case unanswered
    /// Parks until the race cancels it, then reports a connection anyway.
    case connectsAsCancelled
}

private enum ScriptedAttemptDelay: Sendable {
    case immediate
    /// Elapses only by cancellation, like `Task.sleep`.
    case parked
}

private final class ScriptedSocketFixture: @unchecked Sendable {
    struct Snapshot: Equatable {
        let openedFamilies: [Int32]
        let waitDeadlines: [ContinuousClock.Instant]
        let closedDescriptors: [Int32]
        let requestedDelays: [Duration]
    }

    let parkedAttempts = ParkedTasks()
    private let parkedDelays = ParkedTasks()
    private let lock = NSLock()
    private let outcomes: [ScriptedCandidateOutcome]
    private let attemptDelay: ScriptedAttemptDelay
    private var currentTime: ContinuousClock.Instant
    private var openedFamilies: [Int32] = []
    private var waitDeadlines: [ContinuousClock.Instant] = []
    private var closedDescriptors: [Int32] = []
    private var requestedDelays: [Duration] = []

    init(
        now: ContinuousClock.Instant,
        outcomes: [ScriptedCandidateOutcome],
        attemptDelay: ScriptedAttemptDelay
    ) {
        currentTime = now
        self.outcomes = outcomes
        self.attemptDelay = attemptDelay
    }

    var operations: SocketConnector.Operations {
        SocketConnector.Operations(
            now: { [self] in now() },
            sleep: { [self] duration in try await sleep(for: duration) },
            makeSocket: { [self] family, _, _ in openSocket(family: family) },
            setNonBlocking: { _ in true },
            enableNoDelay: { _ in true },
            disableSIGPIPE: { _ in true },
            beginConnection: { _, _ in .inProgress },
            waitUntilWritable: { [self] descriptor, deadline in
                try await wait(descriptor: descriptor, until: deadline)
            },
            connectionSucceeded: { [self] descriptor in
                let outcome = outcome(for: descriptor)
                return outcome == .connected || outcome == .connectsAsCancelled
            },
            closeSocket: { [self] descriptor in closeSocket(descriptor) })
    }

    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            openedFamilies: openedFamilies,
            waitDeadlines: waitDeadlines,
            closedDescriptors: closedDescriptors,
            requestedDelays: requestedDelays)
    }

    private func now() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return currentTime
    }

    private func sleep(for duration: Duration) async throws {
        recordDelay(duration)
        switch attemptDelay {
        case .immediate:
            return
        case .parked:
            await parkedDelays.park()
            throw CancellationError()
        }
    }

    private func recordDelay(_ duration: Duration) {
        lock.lock()
        requestedDelays.append(duration)
        lock.unlock()
    }

    private func openSocket(family: Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        let descriptor = Int32(100 + openedFamilies.count)
        openedFamilies.append(family)
        return descriptor
    }

    private func wait(
        descriptor: Int32,
        until deadline: ContinuousClock.Instant
    ) async throws {
        switch recordWait(descriptor: descriptor, until: deadline) {
        case .timedOut:
            throw SSHError.timedOut
        case .rejected, .connected:
            return
        case .unanswered:
            await parkedAttempts.park()
            throw SSHError.cancelled
        case .connectsAsCancelled:
            await parkedAttempts.park()
        }
    }

    private func recordWait(
        descriptor: Int32,
        until deadline: ContinuousClock.Instant
    ) -> ScriptedCandidateOutcome {
        lock.lock()
        defer { lock.unlock() }
        waitDeadlines.append(deadline)
        let outcome = outcomeLocked(for: descriptor)
        if outcome == .timedOut { currentTime = deadline }
        return outcome
    }

    private func outcome(for descriptor: Int32) -> ScriptedCandidateOutcome {
        lock.lock()
        defer { lock.unlock() }
        return outcomeLocked(for: descriptor)
    }

    private func outcomeLocked(for descriptor: Int32) -> ScriptedCandidateOutcome {
        let index = Int(descriptor - 100)
        guard outcomes.indices.contains(index) else { return .rejected }
        return outcomes[index]
    }

    private func closeSocket(_ descriptor: Int32) {
        lock.lock()
        closedDescriptors.append(descriptor)
        lock.unlock()
    }
}

/// Parks tasks until they are cancelled and counts arrivals, so a test can
/// wait until a given number of attempts are in flight.
private final class ParkedTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var parkedCount = 0
    private var arrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func park() async {
        let latch = CancellationLatch()
        await withTaskCancellationHandler {
            await latch.wait { [self] in arrived() }
        } onCancel: {
            latch.open()
        }
    }

    func waitUntilParked(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if parkedCount >= count {
                lock.unlock()
                continuation.resume()
            } else {
                arrivalWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    private func arrived() {
        lock.lock()
        parkedCount += 1
        let ready = arrivalWaiters.filter { $0.count <= parkedCount }
        arrivalWaiters.removeAll { $0.count <= parkedCount }
        lock.unlock()
        for waiter in ready {
            waiter.continuation.resume()
        }
    }
}

private final class CancellationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait(onParked: () -> Void) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
            onParked()
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
