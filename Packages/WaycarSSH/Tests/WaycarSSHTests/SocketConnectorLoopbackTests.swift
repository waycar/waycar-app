import Darwin
import Foundation
import Testing

@testable import WaycarSSH

/// Real sockets on loopback; the simulator shares the host's TCP stack.
@Suite("Socket racing on loopback", .serialized, .timeLimit(.minutes(1)))
struct SocketConnectorLoopbackTests {
    @Test("an unanswered first address loses to a live second one after the attempt delay, not its timeout")
    func unansweredFirstAddressLosesToLiveSecond() async throws {
        let unanswered = try LoopbackPort.unanswered()
        let listening = try LoopbackPort.listening()
        let recorder = RecordingSocketOperations()
        let started = ContinuousClock.now

        let descriptor = try await SocketConnector.connect(
            to: SSHEndpoint(host: "example.test", port: 22),
            until: started + .seconds(20),
            resolver: FixedSocketAddressResolver(
                addresses: [unanswered.address, listening.address]),
            operations: recorder.operations)
        let elapsed = ContinuousClock.now - started
        defer { close(descriptor) }

        // The live address starts only once the attempt delay passes, and it
        // wins long before the 10 s a sequential connect spends on the first.
        #expect(elapsed >= SocketConnector.connectionAttemptDelay)
        #expect(elapsed < .seconds(5))
        let opened = recorder.opened
        try #require(opened.count == 2)
        #expect(descriptor == opened[1])
        #expect(recorder.closed == [opened[0]])
        #expect(socketOption(descriptor, IPPROTO_TCP, TCP_NODELAY) != 0)
        #expect(socketOption(descriptor, SOL_SOCKET, SO_NOSIGPIPE) != 0)
    }

    @Test("a refused first address hands over at once instead of waiting out the attempt delay")
    func refusedFirstAddressFallsThroughImmediately() async throws {
        let refusing = try LoopbackPort.refusingAddress()
        let listening = try LoopbackPort.listening()
        let recorder = RecordingSocketOperations()
        let started = ContinuousClock.now

        let descriptor = try await SocketConnector.connect(
            to: SSHEndpoint(host: "example.test", port: 22),
            until: started + .seconds(50),
            resolver: FixedSocketAddressResolver(
                addresses: [refusing, listening.address]),
            operations: recorder.operations,
            attemptDelay: .seconds(30))
        let elapsed = ContinuousClock.now - started
        defer { close(descriptor) }

        #expect(elapsed < .seconds(10))
        let opened = recorder.opened
        try #require(opened.count == 2)
        #expect(descriptor == opened[1])
        #expect(recorder.closed == [opened[0]])
    }

    @Test("racing unanswered addresses still ends at the caller's deadline")
    func unansweredAddressesStopAtTheDeadline() async throws {
        let first = try LoopbackPort.unanswered()
        let second = try LoopbackPort.unanswered()
        let recorder = RecordingSocketOperations()
        let started = ContinuousClock.now

        await #expect(throws: SSHError.timedOut) {
            _ = try await SocketConnector.connect(
                to: SSHEndpoint(host: "example.test", port: 22),
                until: started + .seconds(1),
                resolver: FixedSocketAddressResolver(
                    addresses: [first.address, second.address]),
                operations: recorder.operations)
        }

        #expect(ContinuousClock.now - started < .seconds(5))
        // The attempt delay started the second address before the deadline
        // ended both, and neither descriptor outlives the failure.
        let opened = recorder.opened
        #expect(opened.count == 2)
        #expect(recorder.closed.sorted() == opened.sorted())
    }

    @Test("the connected socket libssh2 uses sends every segment immediately and never raises SIGPIPE")
    func connectedSocketSetsNoDelayAndNoSIGPIPE() async throws {
        let listening = try LoopbackPort.listening()

        let descriptor = try await SocketConnector.connect(
            to: SSHEndpoint(host: "127.0.0.1", port: listening.port),
            until: ContinuousClock.now + .seconds(5))
        defer { close(descriptor) }

        // Darwin answers with the raw flag bits (TF_NODELAY is 0x4) rather
        // than a normalized boolean; Linux answers 1. Nonzero is set.
        #expect(socketOption(descriptor, IPPROTO_TCP, TCP_NODELAY) != 0)
        #expect(socketOption(descriptor, SOL_SOCKET, SO_NOSIGPIPE) != 0)
    }
}

private func socketOption(_ descriptor: Int32, _ level: Int32, _ name: Int32) -> Int32? {
    var value: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(descriptor, level, name, &value, &length) == 0 else { return nil }
    return value
}

private struct LoopbackPortError: Error {
    let operation: String
    let code: Int32
}

/// A loopback IPv4 port in a known state, held until deinit.
private final class LoopbackPort {
    let port: UInt16
    private let descriptor: Int32

    var address: SocketAddress { .loopback(port: port) }

    /// The kernel completes handshakes into the listen queue; nothing accepts.
    static func listening() throws -> LoopbackPort {
        try LoopbackPort(listens: true)
    }

    /// Bound but never listening. Darwin drops a SYN for a closed TCP control
    /// block without a reset, so a connect stays unanswered the way it does
    /// across a dead route.
    static func unanswered() throws -> LoopbackPort {
        try LoopbackPort(listens: false)
    }

    /// A port nobody holds answers a SYN with a reset.
    static func refusingAddress() throws -> SocketAddress {
        try LoopbackPort(listens: false).address
    }

    private init(listens: Bool) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else {
            throw LoopbackPortError(operation: "socket", code: errno)
        }
        do {
            var address = sockaddr_in.loopback(port: 0)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                throw LoopbackPortError(operation: "bind", code: errno)
            }
            if listens, Darwin.listen(descriptor, 16) != 0 {
                throw LoopbackPortError(operation: "listen", code: errno)
            }
            var resolved = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let named = withUnsafeMutablePointer(to: &resolved) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard named == 0 else {
                throw LoopbackPortError(operation: "getsockname", code: errno)
            }
            port = UInt16(bigEndian: resolved.sin_port)
        } catch {
            close(descriptor)
            throw error
        }
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }
}

/// Live socket operations that record what the connector opens and closes.
private final class RecordingSocketOperations: @unchecked Sendable {
    private let lock = NSLock()
    private var openedDescriptors: [Int32] = []
    private var closedDescriptors: [Int32] = []

    var opened: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return openedDescriptors
    }

    var closed: [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return closedDescriptors
    }

    var operations: SocketConnector.Operations {
        let live = SocketConnector.Operations.live()
        return SocketConnector.Operations(
            now: live.now,
            sleep: live.sleep,
            makeSocket: { [self] family, type, socketProtocol in
                let descriptor = live.makeSocket(family, type, socketProtocol)
                if descriptor >= 0 {
                    lock.lock()
                    openedDescriptors.append(descriptor)
                    lock.unlock()
                }
                return descriptor
            },
            setNonBlocking: live.setNonBlocking,
            enableNoDelay: live.enableNoDelay,
            disableSIGPIPE: live.disableSIGPIPE,
            beginConnection: live.beginConnection,
            waitUntilWritable: live.waitUntilWritable,
            connectionSucceeded: live.connectionSucceeded,
            closeSocket: { [self] descriptor in
                lock.lock()
                closedDescriptors.append(descriptor)
                lock.unlock()
                live.closeSocket(descriptor)
            })
    }
}

private extension sockaddr_in {
    static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        return address
    }
}

private extension SocketAddress {
    static func loopback(port: UInt16) -> SocketAddress {
        var address = sockaddr_in.loopback(port: port)
        return SocketAddress(
            family: AF_INET,
            type: SOCK_STREAM,
            protocol: IPPROTO_TCP,
            bytes: Data(bytes: &address, count: MemoryLayout<sockaddr_in>.size))
    }
}
