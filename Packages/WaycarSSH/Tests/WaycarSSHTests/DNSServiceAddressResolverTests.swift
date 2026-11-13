import Foundation
import Testing
import dnssd

@testable import WaycarSSH

@Suite("DNS resolution lifecycle", .serialized)
struct DNSServiceAddressResolverTests {
    // The framework limit also records a failure if the awaited operation never
    // returns. Elapsed-time expects alone cannot catch that kind of hang.
    @Test("stalled resolution honors its deadline without opening a socket", .timeLimit(.minutes(1)))
    func stalledResolutionTimesOutAndReleasesResources() async {
        let fixture = StalledDNSServiceFixture()
        let socketCalls = LockedCounter()
        let started = ContinuousClock.now

        await #expect(throws: SSHError.timedOut) {
            _ = try await SocketConnector.connect(
                to: SSHEndpoint(host: "stalled-resolution.invalid", port: 22),
                until: ContinuousClock.now + .milliseconds(50),
                resolver: DNSServiceAddressResolver(functions: fixture.functions),
                makeSocket: { _, _, _ in
                    socketCalls.increment()
                    return -1
                })
        }

        // Resource release is the contract; allow a loaded runner time to resume.
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(fixture.snapshot == .completedOnce)
        #expect(socketCalls.value == 0)
    }

    @Test("caller cancellation stops stalled resolution without opening a socket", .timeLimit(.minutes(1)))
    func stalledResolutionCancellationReleasesResources() async throws {
        let fixture = StalledDNSServiceFixture()
        let socketCalls = LockedCounter()
        let task = Task {
            try await SocketConnector.connect(
                to: SSHEndpoint(host: "stalled-resolution.invalid", port: 22),
                until: ContinuousClock.now + .seconds(30),
                resolver: DNSServiceAddressResolver(functions: fixture.functions),
                makeSocket: { _, _, _ in
                    socketCalls.increment()
                    return -1
                })
        }
        defer { task.cancel() }
        try await fixture.waitUntilScheduled()
        let cancelledAt = ContinuousClock.now
        task.cancel()

        await #expect(throws: SSHError.cancelled) {
            _ = try await task.value
        }

        #expect(ContinuousClock.now - cancelledAt < .seconds(10))
        #expect(fixture.snapshot == .completedOnce)
        #expect(socketCalls.value == 0)
    }

    @Test("localhost resolves through the system resolver")
    func localhostResolutionSucceeds() async throws {
        let addresses = try await DNSServiceAddressResolver().resolve(
            SSHEndpoint(host: "localhost", port: 2222),
            until: ContinuousClock.now + .seconds(5))

        #expect(!addresses.isEmpty)
        #expect(addresses.allSatisfy { $0.family == AF_INET || $0.family == AF_INET6 })
        #expect(addresses.allSatisfy { $0.type == SOCK_STREAM })
        #expect(addresses.allSatisfy { $0.protocol == IPPROTO_TCP })
        #expect(addresses.allSatisfy { $0.port == 2222 })
    }

    @Test(arguments: ["127.0.0.1", "::1"])
    func numericAddressesPreserveFamilyAndPort(_ host: String) async throws {
        let addresses = try await DNSServiceAddressResolver().resolve(
            SSHEndpoint(host: host, port: 2022),
            until: ContinuousClock.now + .seconds(1))

        #expect(addresses.count == 1)
        #expect(addresses.first?.port == 2022)
        #expect(addresses.first?.family == (host.contains(":") ? AF_INET6 : AF_INET))
    }

    @Test("IPv4 literal uses the NAT64-synthesized IPv6 address")
    func ipv4LiteralUsesSynthesizedIPv6Address() async throws {
        let synthesized = SocketAddress.ipv6(host: "64:ff9b::c000:201", port: 22)
        let addresses = try await resolver(stub: { host, port in
            #expect(host == "192.0.2.1")
            #expect(port == 22)
            return [synthesized]
        }).resolve(
            SSHEndpoint(host: "192.0.2.1", port: 22),
            until: ContinuousClock.now + .seconds(1))

        #expect(addresses == [synthesized])
        #expect(addresses.first?.family == AF_INET6)
    }

    @Test("IPv4 literal keeps IPv4 when getaddrinfo returns IPv4")
    func ipv4LiteralKeepsIPv4Result() async throws {
        let ipv4 = SocketAddress.ipv4(host: "192.0.2.1", port: 22)
        let addresses = try await resolver(stub: { _, _ in [ipv4] }).resolve(
            SSHEndpoint(host: "192.0.2.1", port: 22),
            until: ContinuousClock.now + .seconds(1))

        #expect(addresses == [ipv4])
    }

    @Test("IPv4 literal falls back to the direct address when getaddrinfo fails")
    func ipv4LiteralFallsBackOnFailure() async throws {
        let addresses = try await resolver(stub: { _, _ in [] }).resolve(
            SSHEndpoint(host: "192.0.2.1", port: 2022),
            until: ContinuousClock.now + .seconds(1))

        #expect(addresses == [SocketAddress.ipv4(host: "192.0.2.1", port: 2022)])
    }

    @Test("bracketed IPv6 literal parses without a lookup")
    func bracketedIPv6LiteralParses() async throws {
        let lookups = LockedCounter()
        let addresses = try await resolver(stub: { _, _ in
            lookups.increment()
            return []
        }).resolve(
            SSHEndpoint(host: "[2001:db8::5]", port: 22),
            until: ContinuousClock.now + .seconds(1))

        #expect(addresses == [SocketAddress.ipv6(host: "2001:db8::5", port: 22)])
        #expect(lookups.value == 0)
    }

    private func resolver(
        stub: @escaping DNSServiceFunctions.ResolveNumericHost
    ) -> DNSServiceAddressResolver {
        let live = DNSServiceFunctions.live
        return DNSServiceAddressResolver(functions: DNSServiceFunctions(
            start: live.start,
            schedule: live.schedule,
            deallocate: live.deallocate,
            resolveNumericHost: stub))
    }
}

private final class StalledDNSServiceFixture: @unchecked Sendable {
    struct Snapshot: Equatable {
        let starts: Int
        let schedules: Int
        let deallocations: Int

        static let completedOnce = Snapshot(starts: 1, schedules: 1, deallocations: 1)
    }

    private let condition = NSCondition()
    private var starts = 0
    private var schedules = 0
    private var deallocations = 0
    private let reference = DNSServiceRef(bitPattern: 1)

    var functions: DNSServiceFunctions {
        DNSServiceFunctions(
            start: { [self] output, _, _, _ in
                condition.lock()
                starts += 1
                output.pointee = reference
                condition.broadcast()
                condition.unlock()
                return DNSServiceErrorType(kDNSServiceErr_NoError)
            },
            schedule: { [self] _, _ in
                condition.lock()
                schedules += 1
                condition.broadcast()
                condition.unlock()
                return DNSServiceErrorType(kDNSServiceErr_NoError)
            },
            deallocate: { [self] _ in
                condition.lock()
                deallocations += 1
                condition.broadcast()
                condition.unlock()
            })
    }

    var snapshot: Snapshot {
        condition.lock()
        defer { condition.unlock() }
        return Snapshot(
            starts: starts,
            schedules: schedules,
            deallocations: deallocations)
    }

    func waitUntilScheduled() async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while snapshot.schedules == 0 {
            guard ContinuousClock.now < deadline else {
                throw FixtureError.didNotStart
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private enum FixtureError: Error {
        case didNotStart
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

private extension SocketAddress {
    var port: UInt16? {
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            switch family {
            case AF_INET:
                return UInt16(bigEndian: baseAddress
                    .assumingMemoryBound(to: sockaddr_in.self)
                    .pointee
                    .sin_port)
            case AF_INET6:
                return UInt16(bigEndian: baseAddress
                    .assumingMemoryBound(to: sockaddr_in6.self)
                    .pointee
                    .sin6_port)
            default:
                return nil
            }
        }
    }

    static func ipv4(host: String, port: UInt16) -> SocketAddress {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        _ = inet_pton(AF_INET, host, &address.sin_addr)
        return SocketAddress(
            family: AF_INET,
            type: SOCK_STREAM,
            protocol: IPPROTO_TCP,
            bytes: Data(bytes: &address, count: MemoryLayout<sockaddr_in>.size))
    }

    static func ipv6(host: String, port: UInt16) -> SocketAddress {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port.bigEndian
        _ = inet_pton(AF_INET6, host, &address.sin6_addr)
        return SocketAddress(
            family: AF_INET6,
            type: SOCK_STREAM,
            protocol: IPPROTO_TCP,
            bytes: Data(bytes: &address, count: MemoryLayout<sockaddr_in6>.size))
    }
}
