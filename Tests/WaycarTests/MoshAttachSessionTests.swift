import Darwin
import Foundation
import Synchronization
import Testing

@testable import Waycar

@Suite("Mosh attach session")
struct MoshAttachSessionTests {
    /// Nothing listens on the discard port, so the server stays silent the
    /// way a firewalled mosh UDP port does.
    private static let silentBootstrap = MoshBootstrap(
        host: "127.0.0.1", udpPort: "9", key: "MDEyMzQ1Njc4OWFiY2RlZg")

    private enum OutputOutcome: Sendable {
        case finished
        case failed(any Error)
        case stillWaiting
    }

    @Test func aSilentServerFailsTheOutputAfterTheFirstContactTimeout() async {
        let session = MoshAttachSession.make(
            bootstrap: Self.silentBootstrap, cols: 80, rows: 24,
            firstContactTimeout: .milliseconds(300))

        let outcome = await withTaskGroup(of: OutputOutcome.self) { group in
            group.addTask {
                do {
                    for try await _ in session.output {}
                    return .finished
                } catch {
                    return .failed(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return .stillWaiting
            }
            let first = await group.next() ?? .stillWaiting
            group.cancelAll()
            return first
        }

        guard
            case .failed(let error) = outcome,
            case .moshSessionFailed(let detail) = error as? TransportError
        else {
            Issue.record("Expected a thrown moshSessionFailed, got \(outcome)")
            await session.end()
            return
        }
        #expect(detail.contains("did not answer over UDP"))
        #expect(await session.link?.firstContact() == .timedOut)

        let elapsed = await ContinuousClock().measure {
            await session.end()
        }
        #expect(elapsed < .seconds(2))
    }

    // MARK: Lifecycle (MOSH-01)

    /// Reads `session`'s output to its end, within the wait ceiling.
    private func outcome(of session: TerminalAttachSession) async -> OutputOutcome {
        await withTaskGroup(of: OutputOutcome.self) { group in
            group.addTask {
                do {
                    for try await _ in session.output {}
                    return .finished
                } catch {
                    return .failed(error)
                }
            }
            group.addTask {
                try? await Task.sleep(for: .waitCeiling)
                return .stillWaiting
            }
            let first = await group.next() ?? .stillWaiting
            group.cancelAll()
            return first
        }
    }

    /// Abandoning before any server state ends the output cleanly, with no
    /// first contact and no wait for a shutdown acknowledgement; the
    /// first-contact watchdog never fires afterwards.
    @Test func abandoningBeforeFirstContactEndsCleanlyAtOnce() async throws {
        let registry = MoshSessionRegistry()
        let session = MoshAttachSession.make(
            bootstrap: Self.silentBootstrap, cols: 80, rows: 24,
            firstContactTimeout: .milliseconds(400), registry: registry)
        try await waitUntil("the started client should join the registry") { registry.count == 1 }
        let connectivity = try #require(session.link?.connectivity())

        let elapsed = await ContinuousClock().measure {
            await session.abandon()
        }
        #expect(elapsed < .seconds(1), "abandon skips the shutdown handshake")
        guard case .finished = await outcome(of: session) else {
            Issue.record("an abandoned session's output must finish cleanly")
            return
        }
        #expect(await session.link?.firstContact() == .ended)
        #expect(registry.count == 0)
        var updates: [TerminalLinkConnectivity] = []
        for await update in connectivity { updates.append(update) }
        #expect(!updates.contains(.stalled), "no stall was ever published: \(updates)")
        // Past the first-contact timeout: nothing settles twice.
        try await Task.sleep(for: .milliseconds(600))
        #expect(await session.link?.firstContact() == .ended)
    }

    /// Ending a started session before any server state quits with the
    /// handshake, which a silent server never acknowledges: the end is
    /// bounded by the handshake's deadline, and the output finishes cleanly.
    @Test func endingBeforeFirstContactFinishesCleanly() async throws {
        let registry = MoshSessionRegistry()
        let session = MoshAttachSession.make(
            bootstrap: Self.silentBootstrap, cols: 80, rows: 24,
            firstContactTimeout: .seconds(20), registry: registry)
        try await waitUntil("the started client should join the registry") { registry.count == 1 }
        let elapsed = await ContinuousClock().measure {
            await session.end()
        }
        #expect(elapsed < .seconds(5))
        #expect(registry.count == 0)
        guard case .finished = await outcome(of: session) else {
            Issue.record("an ended session's output must finish cleanly")
            return
        }
        #expect(await session.link?.firstContact() == .ended)
    }

    /// A port mosh-server could not have announced fails the output at once
    /// and never joins the registry.
    @Test func anUnusablePortFailsTheOutputAtOnce() async throws {
        let registry = MoshSessionRegistry()
        let session = MoshAttachSession.make(
            bootstrap: MoshBootstrap(host: "127.0.0.1", udpPort: "0", key: "MDEyMzQ1Njc4OWFiY2RlZg"),
            cols: 80, rows: 24, firstContactTimeout: .seconds(20), registry: registry)
        guard
            case .failed(let error) = await outcome(of: session),
            case .moshSessionFailed(let detail) = error as? TransportError
        else {
            Issue.record("an unusable port must fail the output")
            await session.end()
            return
        }
        #expect(detail.contains("unusable UDP port"))
        #expect(await session.link?.firstContact() == .ended)
        #expect(registry.count == 0)
        await session.end()
    }

    /// A first-contact timeout settles first contact once, as timed out,
    /// whatever ends the session afterwards; the timed-out session leaves
    /// the registry and its contact check reads silence.
    @Test func aFirstContactTimeoutSettlesOnceAndLeavesTheRegistry() async throws {
        let registry = MoshSessionRegistry()
        let session = MoshAttachSession.make(
            bootstrap: Self.silentBootstrap, cols: 80, rows: 24,
            firstContactTimeout: .milliseconds(300), registry: registry)
        guard case .failed = await outcome(of: session) else {
            Issue.record("a silent server must fail the output")
            await session.end()
            return
        }
        #expect(await session.link?.firstContact() == .timedOut)
        try await waitUntil("the timed-out session should leave the registry") { registry.count == 0 }
        #expect(await session.link?.awaitServerContact(within: .milliseconds(300)) == false)
        await session.abandon()
        #expect(await session.link?.firstContact() == .timedOut)
    }

    // MARK: A server that answers (MOSH-01)

    /// mosh-server's first state on base 0: "\e[H$ ready". Sealed with
    /// `silentBootstrap`'s key, server-to-client sequence 0, fragment 0.
    private static let readyState =
        "80000000000000003f6a271a1e2044267b25c05e3e26ec3d46915f39b4a7346bb8b33a440feaa9bf6b017830d8067593"
        + "dc5d754ce547e4b0f85798e8843ea2ab667129d42c41716b817e475e"
    /// Its shutdown state (`UInt64.max` on base 1, no diff): the command
    /// exited. Sequence 1, fragment 1.
    private static let shutdownState =
        "8000000000000001d852e7f98f18e6a7bca768fbc042767d8bc95a34a3342404f5afa37093f127d9f87cf83d89ee0312"
        + "533bb3f827cc1c4bf98b62ba"

    /// Reads an attach's output in the background, recording its bytes.
    private final class OutputReader: Sendable {
        private final class Record: Sendable {
            let received = Mutex(Data())
            let ended = Mutex<OutputOutcome?>(nil)
        }

        private let record = Record()

        init(_ session: TerminalAttachSession) {
            let record = record
            Task {
                do {
                    for try await bytes in session.output {
                        record.received.withLock { $0.append(bytes) }
                    }
                    record.ended.withLock { $0 = .finished }
                } catch {
                    record.ended.withLock { $0 = .failed(error) }
                }
            }
        }

        var text: String { String(decoding: record.received.withLock { $0 }, as: UTF8.self) }
        var outcome: OutputOutcome? { record.ended.withLock { $0 } }
        var hasEnded: Bool { outcome != nil }
        var finishedCleanly: Bool {
            if case .finished = outcome { true } else { false }
        }
    }

    private func answeringSession(
        _ server: LoopbackMoshServer, firstContactTimeout: Duration, registry: MoshSessionRegistry
    ) -> TerminalAttachSession {
        MoshAttachSession.make(
            bootstrap: MoshBootstrap(
                host: "127.0.0.1", udpPort: String(server.port), key: Self.silentBootstrap.key),
            cols: 80, rows: 24, firstContactTimeout: firstContactTimeout, registry: registry)
    }

    /// The server's first state reaches the output and settles first
    /// contact as answered; its shutdown state ends the output cleanly.
    @Test func aServerStateIsFirstContactAndItsShutdownEndsTheOutputCleanly() async throws {
        let server = try LoopbackMoshServer()
        let registry = MoshSessionRegistry()
        let session = answeringSession(server, firstContactTimeout: .seconds(20), registry: registry)
        let reader = OutputReader(session)
        #expect(await server.awaitClient(within: 30), "the client's first state must reach the server")
        let connectivity = try #require(session.link?.connectivity())
        #expect(server.send(hex: Self.readyState))

        try await waitUntil("the server's screen should reach the output") { reader.text.contains("ready") }
        #expect(await session.link?.firstContact() == .answered)
        try await waitUntil("the answered session should be registered") { registry.count == 1 }
        var updates = connectivity.makeAsyncIterator()
        let first = await updates.next()
        #expect(first == .connected)

        #expect(server.send(hex: Self.shutdownState))
        try await waitUntil("the server's shutdown should end the output") { reader.hasEnded }
        #expect(reader.finishedCleanly, "a command that exited ends the attach without an error")
        #expect(await session.link?.firstContact() == .answered)
        try await waitUntil("the ended session should leave the registry") { registry.count == 0 }
        await session.end()
    }

    /// An answer disarms the first-contact watchdog: past its timeout the
    /// session still runs, and abandoning it ends the output cleanly at once.
    @Test func anAnswerDisarmsTheFirstContactWatchdog() async throws {
        let server = try LoopbackMoshServer()
        let registry = MoshSessionRegistry()
        let session = answeringSession(server, firstContactTimeout: .seconds(5), registry: registry)
        let reader = OutputReader(session)
        #expect(await server.awaitClient(within: 30))
        #expect(server.send(hex: Self.readyState))
        try await waitUntil("the server's screen should reach the output") { reader.text.contains("ready") }

        try await Task.sleep(for: .seconds(6))
        #expect(!reader.hasEnded, "the watchdog fired after an answer: \(String(describing: reader.outcome))")
        #expect(await session.link?.firstContact() == .answered)

        let elapsed = await ContinuousClock().measure { await session.abandon() }
        #expect(elapsed < .seconds(1))
        try await waitUntil("the abandoned session's output should end") { reader.hasEnded }
        #expect(reader.finishedCleanly)
        #expect(registry.count == 0)
    }

    /// Ending an answered session quits with the shutdown handshake, which
    /// this server never acknowledges: the end is bounded by the handshake's
    /// deadline, and the output finishes cleanly.
    @Test func endingAnAnsweredSessionFinishesCleanly() async throws {
        let server = try LoopbackMoshServer()
        let registry = MoshSessionRegistry()
        let session = answeringSession(server, firstContactTimeout: .seconds(20), registry: registry)
        let reader = OutputReader(session)
        #expect(await server.awaitClient(within: 30))
        #expect(server.send(hex: Self.readyState))
        try await waitUntil("the server's screen should reach the output") { reader.text.contains("ready") }

        let elapsed = await ContinuousClock().measure { await session.end() }
        #expect(elapsed < .seconds(5))
        try await waitUntil("the ended session's output should end") { reader.hasEnded }
        #expect(reader.finishedCleanly)
        #expect(await session.link?.firstContact() == .answered)
        #expect(registry.count == 0)
    }
}

/// A stand-in mosh-server on loopback UDP: it learns the client's address
/// from the client's first datagram and replies with server datagrams
/// prepared ahead (sealed with the session's key), never reading what the
/// client says. Answering from the address the client sent to, as
/// `mosh-server new -s` does (#122).
private final class LoopbackMoshServer: @unchecked Sendable {
    let port: UInt16
    private let descriptor: Int32
    private let lock = NSLock()
    private var client: sockaddr_in?

    init() throws {
        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            close(descriptor)
            throw POSIXError(.EINVAL)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard bound == 0, named == 0 else {
            close(descriptor)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        var limit = timeval(tv_sec: 0, tv_usec: 100_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        self.descriptor = descriptor
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit {
        close(descriptor)
    }

    /// Waits up to `seconds` for a client datagram, off the cooperative
    /// pool, and remembers its sender.
    func awaitClient(within seconds: Double) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                let deadline = Date().addingTimeInterval(seconds)
                var buffer = [UInt8](repeating: 0, count: 2_048)
                while Date() < deadline {
                    var sender = sockaddr_in()
                    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let received = withUnsafeMutablePointer(to: &sender) { pointer in
                        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            recvfrom(descriptor, &buffer, buffer.count, 0, $0, &length)
                        }
                    }
                    if received > 0 {
                        lock.withLock { client = sender }
                        continuation.resume(returning: true)
                        return
                    }
                }
                continuation.resume(returning: false)
            }
        }
    }

    /// Sends one prepared datagram to the client heard from.
    func send(hex: String) -> Bool {
        guard var client = lock.withLock({ self.client }) else { return false }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return false }
            bytes.append(byte)
            index = next
        }
        let sent = withUnsafePointer(to: &client) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(descriptor, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return sent == bytes.count
    }
}
