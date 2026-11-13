import Darwin
import Foundation

/// The package-private transport seam used by nested SSH sessions. The inner
/// driver receives only a non-blocking byte descriptor; the outer libssh2
/// session and direct-tcpip channel never cross this boundary.
protocol SSHByteTransport: AnyObject, Sendable {
    func takeDescriptor() throws -> Int32
    func close(timeout: Duration) async throws
    func abort()
}

/// The descriptors' ownership and the pump's start are
/// `ByteTransportMachine`'s, under the lock; the transport keeps the pump
/// Task and performs the closes and the cancellation.
final class DirectTCPIPByteTransport: SSHByteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var machine: ByteTransportMachine
    private var pumpTask: Task<Result<Void, SSHError>, Never>?

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw SSHError.connectionFailed
        }
        do {
            try Self.makeNonBlocking(descriptors[0])
            try Self.makeNonBlocking(descriptors[1])
            try Self.disableSIGPIPE(descriptors[0])
            try Self.disableSIGPIPE(descriptors[1])
        } catch {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw error
        }
        machine = ByteTransportMachine(inner: descriptors[0], pump: descriptors[1])
    }

    func takePumpDescriptor() throws -> Int32 {
        try take(.takePumpDescriptor)
    }

    func start(_ task: Task<Result<Void, SSHError>, Never>) {
        lock.lock()
        _ = machine.handle(.startPump)
        pumpTask = task
        lock.unlock()
    }

    func takeDescriptor() throws -> Int32 {
        try take(.takeInner)
    }

    private func take(_ event: ByteTransportMachine.Event) throws -> Int32 {
        let effects = lock.withLock { machine.handle(event) }
        guard case .hand(let descriptor) = effects.first else {
            throw SSHError.connectionInvalidated
        }
        return descriptor
    }

    func close(timeout: Duration) async throws {
        let task = lock.withLock { pumpTask }
        guard let task else { return }

        let deadline = ContinuousClock.now.advanced(by: timeout)
        let result = await withTaskGroup(of: Result<Void, SSHError>.self) { group in
            group.addTask { await task.value }
            group.addTask {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                    return .failure(.timedOut)
                } catch {
                    return .failure(.cancelled)
                }
            }
            let first = await group.next() ?? .failure(.connectionFailed)
            // Out of time: the pump is cancelled here, inside the group. The
            // child awaiting `task.value` does not answer cancellation, and
            // the group waits for it before returning, so a pump cancelled
            // only after the group would never be cancelled at all (B-27).
            if case .failure(.timedOut) = first { task.cancel() }
            group.cancelAll()
            return first
        }
        try result.get()
    }

    func abort() {
        lock.lock()
        let effects = machine.handle(.abort)
        let task = pumpTask
        lock.unlock()
        for effect in effects {
            switch effect {
            case .closeDescriptor(let descriptor):
                Darwin.close(descriptor)
            case .cancelPump:
                task?.cancel()
            case .hand, .refuse:
                continue
            }
        }
    }

    deinit {
        abort()
    }

    private static func makeNonBlocking(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SSHError.connectionFailed
        }
    }

    private static func disableSIGPIPE(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &enabled,
                socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            throw SSHError.connectionFailed
        }
    }
}
