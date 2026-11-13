import Darwin
import Foundation
import Testing

@testable import WaycarSSH

@Suite("TCP peer address", .serialized)
struct PeerAddressTests {
    @Test("an IPv4 loopback connection reads its numeric peer")
    func ipv4LoopbackPeer() throws {
        let listen = try #require(SocketAddress.ipv4("127.0.0.1"))
        let pair = try #require(LoopbackPair.connect(listeningOn: listen))
        defer { pair.close() }

        #expect(PeerAddress.read(descriptor: pair.client) == "127.0.0.1")
    }

    @Test("an IPv6 loopback connection reads its numeric peer")
    func ipv6LoopbackPeer() throws {
        let listen = try #require(SocketAddress.ipv6("::1"))
        let pair = try #require(LoopbackPair.connect(listeningOn: listen))
        defer { pair.close() }

        #expect(PeerAddress.read(descriptor: pair.client) == "::1")
    }

    /// A dual-stack IPv6 socket that reaches an IPv4 Host sees it as
    /// `::ffff:a.b.c.d`; mosh needs the plain IPv4 form.
    @Test("a v4-mapped peer reads as dotted IPv4")
    func mappedPeerReadsAsIPv4() throws {
        let listen = try #require(SocketAddress.ipv4("127.0.0.1"))
        let pair = try #require(LoopbackPair.connect(
            listeningOn: listen,
            dualStackClient: true,
            target: { bound in
                SocketAddress.ipv6("::ffff:127.0.0.1", port: SocketAddress.port(of: bound))
            }))
        defer { pair.close() }

        #expect(PeerAddress.read(descriptor: pair.client) == "127.0.0.1")
    }

    /// A link-local address means nothing without its interface, so the
    /// scope has to survive into the address mosh dials.
    @Test("a link-local peer keeps its scope")
    func linkLocalPeerKeepsScope() throws {
        let scope = if_nametoindex("lo0")
        try #require(scope != 0)
        let listen = try #require(SocketAddress.ipv6("fe80::1", scope: scope))
        let pair = try #require(LoopbackPair.connect(listeningOn: listen))
        defer { pair.close() }

        #expect(PeerAddress.read(descriptor: pair.client) == "fe80::1%lo0")
    }

    /// On an IPv6-only network the resolver synthesizes `64:ff9b::/96`
    /// addresses for an IPv4 Host; the peer reads as the IPv4 it embeds.
    @Test("a NAT64 well-known-prefix peer reads as its embedded IPv4")
    func nat64PeerReadsAsEmbeddedIPv4() throws {
        let address = try #require(SocketAddress.ipv6("64:ff9b::c000:207", port: 22))
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { destination in
            address.withUnsafeBytes { destination.copyMemory(from: $0) }
        }

        #expect(
            PeerAddress.format(storage: storage, length: socklen_t(address.count))
                == "192.0.2.7")
    }

    /// The AF_UNIX socketpair a Jump Host transport hands over is not a
    /// network socket.
    @Test("a non-IP socket has no peer address")
    func nonIPSocketHasNoPeer() throws {
        var descriptors: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
        }

        #expect(PeerAddress.read(descriptor: descriptors[0]) == nil)
    }

    @Test("an invalid descriptor has no peer address")
    func invalidDescriptorHasNoPeer() {
        #expect(PeerAddress.read(descriptor: -1) == nil)
    }
}

/// Raw `sockaddr` bytes for the addresses these tests listen on and dial.
private enum SocketAddress {
    static func ipv4(_ host: String, port: in_port_t = 0) -> Data? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Data($0) }
    }

    static func ipv6(_ host: String, port: in_port_t = 0, scope: UInt32 = 0) -> Data? {
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = port
        address.sin6_scope_id = scope
        guard inet_pton(AF_INET6, host, &address.sin6_addr) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Data($0) }
    }

    static func family(of address: Data) -> Int32 {
        address.withUnsafeBytes { bytes in
            Int32(bytes.loadUnaligned(as: sockaddr.self).sa_family)
        }
    }

    /// The port in network byte order, which IPv4 and IPv6 keep at the same
    /// offset.
    static func port(of address: Data) -> in_port_t {
        address.withUnsafeBytes { bytes in
            bytes.loadUnaligned(as: sockaddr_in.self).sin_port
        }
    }
}

/// A listener bound to a local address and a client connected to it. The
/// kernel completes the connection from the listen backlog, so nothing has
/// to accept it.
private struct LoopbackPair {
    let listener: Int32
    let client: Int32

    /// Binds a listener to `address` on an ephemeral port and connects a
    /// client to it, or to `target` of the bound address when given. A
    /// `dualStackClient` is an IPv6 socket that may reach IPv4 peers.
    static func connect(
        listeningOn address: Data,
        dualStackClient: Bool = false,
        target: (Data) -> Data? = { $0 }
    ) -> LoopbackPair? {
        let family = SocketAddress.family(of: address)
        let listener = socket(family, SOCK_STREAM, 0)
        guard listener >= 0 else { return nil }
        guard let bound = bind(listener, to: address),
              Darwin.listen(listener, 1) == 0,
              let destination = target(bound)
        else {
            Darwin.close(listener)
            return nil
        }

        let client = socket(SocketAddress.family(of: destination), SOCK_STREAM, 0)
        guard client >= 0 else {
            Darwin.close(listener)
            return nil
        }
        var v6Only: Int32 = 0
        let configured = !dualStackClient || setsockopt(
            client, IPPROTO_IPV6, IPV6_V6ONLY,
            &v6Only, socklen_t(MemoryLayout<Int32>.size)) == 0
        let connected = destination.withUnsafeBytes { bytes in
            bytes.withMemoryRebound(to: sockaddr.self) { pointer in
                configured
                    && Darwin.connect(client, pointer.baseAddress, socklen_t(bytes.count)) == 0
            }
        }
        guard connected else {
            Darwin.close(client)
            Darwin.close(listener)
            return nil
        }
        return LoopbackPair(listener: listener, client: client)
    }

    func close() {
        Darwin.close(client)
        Darwin.close(listener)
    }

    /// Binds `listener` to `address` and returns the bound address, port
    /// included, as raw `sockaddr` bytes.
    private static func bind(_ listener: Int32, to address: Data) -> Data? {
        var request = address
        let length = socklen_t(request.count)
        let bound = request.withUnsafeBytes { bytes in
            bytes.withMemoryRebound(to: sockaddr.self) { pointer in
                Darwin.bind(listener, pointer.baseAddress, length)
            }
        }
        guard bound == 0 else { return nil }

        var resolvedLength = length
        let named = request.withUnsafeMutableBytes { bytes in
            bytes.withMemoryRebound(to: sockaddr.self) { pointer in
                getsockname(listener, pointer.baseAddress, &resolvedLength)
            }
        }
        guard named == 0, resolvedLength == length else { return nil }
        return request
    }
}
