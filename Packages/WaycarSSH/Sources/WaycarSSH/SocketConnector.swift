import Darwin
import Dispatch
import Foundation

enum SocketConnector {
    /// RFC 8305 §5's recommended Connection Attempt Delay: how long one
    /// address may stay unanswered before the next one starts racing it.
    static let connectionAttemptDelay: Duration = .milliseconds(250)

    enum ConnectionState: Sendable {
        case connected
        case inProgress
        case failed
    }

    struct Operations: Sendable {
        let now: @Sendable () -> ContinuousClock.Instant
        let sleep: @Sendable (Duration) async throws -> Void
        let makeSocket: @Sendable (Int32, Int32, Int32) -> Int32
        let setNonBlocking: @Sendable (Int32) -> Bool
        let enableNoDelay: @Sendable (Int32) -> Bool
        let disableSIGPIPE: @Sendable (Int32) -> Bool
        let beginConnection: @Sendable (Int32, SocketAddress) -> ConnectionState
        let waitUntilWritable:
            @Sendable (Int32, ContinuousClock.Instant) async throws -> Void
        let connectionSucceeded: @Sendable (Int32) -> Bool
        let closeSocket: @Sendable (Int32) -> Void

        static func live(
            makeSocket: @escaping @Sendable (Int32, Int32, Int32) -> Int32 = {
                socket($0, $1, $2)
            }
        ) -> Self {
            Operations(
                now: { ContinuousClock.now },
                sleep: { try await Task.sleep(for: $0) },
                makeSocket: makeSocket,
                setNonBlocking: { descriptor in
                    let flags = fcntl(descriptor, F_GETFL, 0)
                    return flags >= 0
                        && fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0
                },
                enableNoDelay: { descriptor in
                    // libssh2 writes small packets back to back (channel open
                    // then data, EOF then close). Without TCP_NODELAY, Nagle
                    // holds each second write until the peer's delayed ACK
                    // arrives — one round trip plus the ACK delay, several
                    // times per connect and per one-shot RPC.
                    var enabled: Int32 = 1
                    let result = setsockopt(
                        descriptor,
                        IPPROTO_TCP,
                        TCP_NODELAY,
                        &enabled,
                        socklen_t(MemoryLayout<Int32>.size))
                    return result == 0
                },
                disableSIGPIPE: { descriptor in
                    // A write after the server resets the connection must
                    // fail with EPIPE, not raise SIGPIPE and end the app.
                    var enabled: Int32 = 1
                    return setsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_NOSIGPIPE,
                        &enabled,
                        socklen_t(MemoryLayout<Int32>.size)) == 0
                },
                beginConnection: { descriptor, address in
                    let result = address.bytes.withUnsafeBytes { bytes -> Int32 in
                        guard let baseAddress = bytes.baseAddress else { return -1 }
                        return Darwin.connect(
                            descriptor,
                            baseAddress.assumingMemoryBound(to: sockaddr.self),
                            socklen_t(bytes.count))
                    }
                    if result == 0 { return .connected }
                    return errno == EINPROGRESS ? .inProgress : .failed
                },
                waitUntilWritable: { descriptor, deadline in
                    try await SocketReadiness.wait(
                        descriptor: descriptor,
                        directions: .write,
                        until: deadline)
                },
                connectionSucceeded: { descriptor in
                    var socketError: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    return getsockopt(
                        descriptor,
                        SOL_SOCKET,
                        SO_ERROR,
                        &socketError,
                        &length) == 0 && socketError == 0
                },
                closeSocket: { descriptor in
                    _ = Darwin.close(descriptor)
                })
        }
    }

    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant
    ) async throws -> Int32 {
        try await connect(
            to: endpoint,
            until: deadline,
            resolver: DNSServiceAddressResolver(),
            operations: .live())
    }

    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant,
        resolver: any SocketAddressResolving,
        makeSocket: @escaping @Sendable (Int32, Int32, Int32) -> Int32
    ) async throws -> Int32 {
        try await connect(
            to: endpoint,
            until: deadline,
            resolver: resolver,
            operations: .live(makeSocket: makeSocket))
    }

    static func connect(
        to endpoint: SSHEndpoint,
        until deadline: ContinuousClock.Instant,
        resolver: any SocketAddressResolving,
        operations: Operations,
        attemptDelay: Duration = connectionAttemptDelay
    ) async throws -> Int32 {
        guard !endpoint.host.isEmpty, endpoint.port > 0 else {
            throw SSHError.invalidEndpoint
        }

        try checkProgress(until: deadline, now: operations.now())
        let addresses = try await resolver.resolve(endpoint, until: deadline)
        return try await race(
            interleavingFamilies(addresses),
            until: deadline,
            attemptDelay: attemptDelay,
            operations: operations)
    }

    /// A candidate whose non-blocking connect has been issued. A pending or
    /// connected descriptor belongs to whoever holds the attempt.
    private enum Attempt: Sendable {
        case pending(Int32)
        case connected(Int32)
        case failed(any Error)
    }

    private enum RaceEvent: Sendable {
        case connected(Int32)
        case failed(any Error)
        case attemptDelayElapsed(generation: Int)
    }

    /// Happy Eyeballs (RFC 8305 §5). Candidates start in order, each one
    /// `attemptDelay` after the previous unless that one has already failed;
    /// every attempt may use the caller's whole deadline. The first connected
    /// socket wins and every other attempt is closed before this returns.
    private static func race(
        _ candidates: [SocketAddress],
        until deadline: ContinuousClock.Instant,
        attemptDelay: Duration,
        operations: Operations
    ) async throws -> Int32 {
        let result = await withTaskGroup(
            of: RaceEvent.self,
            returning: Result<Int32, any Error>.self
        ) { group in
            var nextCandidate = candidates.startIndex
            var attemptsInFlight = 0
            var delayGeneration = 0
            var launchDue = true
            var lastError: any Error = SSHError.connectionFailed
            var outcome: Result<Int32, any Error>?

            while outcome == nil {
                if launchDue, nextCandidate < candidates.endIndex {
                    launchDue = false
                    do {
                        try checkProgress(until: deadline, now: operations.now())
                    } catch {
                        outcome = .failure(error)
                        break
                    }
                    // Issued here, not in the child, so sockets open in
                    // candidate order.
                    let attempt = beginAttempt(
                        to: candidates[nextCandidate],
                        operations: operations)
                    nextCandidate += 1
                    attemptsInFlight += 1
                    group.addTask {
                        await completeAttempt(attempt, until: deadline, operations: operations)
                    }
                    if case .pending = attempt, nextCandidate < candidates.endIndex {
                        // A newer generation supersedes this timer when an
                        // attempt fails first and starts the next candidate.
                        delayGeneration += 1
                        let generation = delayGeneration
                        group.addTask {
                            // Cancellation only arrives once the race is
                            // over or the caller gave up; the loop rechecks
                            // progress before starting anything.
                            try? await operations.sleep(attemptDelay)
                            return .attemptDelayElapsed(generation: generation)
                        }
                    }
                }
                // Every failure makes a launch due, so nothing in flight here
                // means no candidate is left.
                guard attemptsInFlight > 0, let event = await group.next() else {
                    outcome = .failure(lastError)
                    break
                }
                switch event {
                case .connected(let descriptor):
                    outcome = .success(descriptor)
                case .failed(let error):
                    attemptsInFlight -= 1
                    if Task.isCancelled || error as? SSHError == .cancelled {
                        outcome = .failure(SSHError.cancelled)
                    } else {
                        lastError = error
                        launchDue = true
                    }
                case .attemptDelayElapsed(let generation):
                    if generation == delayGeneration { launchDue = true }
                }
            }

            group.cancelAll()
            // An attempt can connect while the race settles; close it here so
            // the winner never leaks a rival.
            for await event in group {
                if case .connected(let descriptor) = event {
                    operations.closeSocket(descriptor)
                }
            }
            return outcome ?? .failure(lastError)
        }
        return try result.get()
    }

    private static func beginAttempt(
        to address: SocketAddress,
        operations: Operations
    ) -> Attempt {
        let descriptor = operations.makeSocket(address.family, address.type, address.protocol)
        guard descriptor >= 0 else { return .failed(SSHError.connectionFailed) }
        guard operations.setNonBlocking(descriptor) else {
            operations.closeSocket(descriptor)
            return .failed(SSHError.connectionFailed)
        }
        switch operations.beginConnection(descriptor, address) {
        case .connected:
            return .connected(descriptor)
        case .inProgress:
            return .pending(descriptor)
        case .failed:
            operations.closeSocket(descriptor)
            return .failed(SSHError.connectionFailed)
        }
    }

    /// Runs as a race child, which owns the attempt's descriptor until it
    /// reports the connection.
    private static func completeAttempt(
        _ attempt: Attempt,
        until deadline: ContinuousClock.Instant,
        operations: Operations
    ) async -> RaceEvent {
        let descriptor: Int32
        switch attempt {
        case .failed(let error):
            return .failed(error)
        case .connected(let connected):
            descriptor = connected
        case .pending(let pending):
            do {
                try await operations.waitUntilWritable(pending, deadline)
            } catch {
                operations.closeSocket(pending)
                return .failed(error)
            }
            guard operations.connectionSucceeded(pending) else {
                operations.closeSocket(pending)
                return .failed(SSHError.connectionFailed)
            }
            descriptor = pending
        }

        // The connected socket is the one libssh2 speaks on — both for the
        // direct session and for a Jump Host's outer hop (the nested session
        // rides the outer hop's socket; its DirectTCPIPByteTransport is an
        // AF_UNIX socketpair, where Nagle does not apply). A socket that
        // refuses either option fails like a refused connect.
        guard operations.enableNoDelay(descriptor),
              operations.disableSIGPIPE(descriptor)
        else {
            operations.closeSocket(descriptor)
            return .failed(SSHError.connectionFailed)
        }
        return .connected(descriptor)
    }

    /// RFC 8305 §4 with a First Address Family Count of one: alternate
    /// families, starting with the family the resolver listed first, keeping
    /// the resolver's order within each family.
    private static func interleavingFamilies(_ addresses: [SocketAddress]) -> [SocketAddress] {
        guard let firstFamily = addresses.first?.family else { return [] }
        let preferred = addresses.filter { $0.family == firstFamily }
        let others = addresses.filter { $0.family != firstFamily }
        var ordered: [SocketAddress] = []
        ordered.reserveCapacity(addresses.count)
        for index in 0..<max(preferred.count, others.count) {
            if index < preferred.count { ordered.append(preferred[index]) }
            if index < others.count { ordered.append(others[index]) }
        }
        return ordered
    }

    private static func checkProgress(
        until deadline: ContinuousClock.Instant,
        now: ContinuousClock.Instant
    ) throws {
        if Task.isCancelled { throw SSHError.cancelled }
        if now >= deadline { throw SSHError.timedOut }
    }
}

struct SocketAddress: Sendable, Equatable {
    let family: Int32
    let type: Int32
    let `protocol`: Int32
    let bytes: Data
}
