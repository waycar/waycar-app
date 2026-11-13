import Darwin

/// Reads the numeric address of the peer a connected TCP socket reached.
///
/// A configured Host name can resolve to several addresses, and resolving it
/// again later need not land on the one this socket connected to. Mosh has to
/// send its UDP to that same address, so the answer comes from the socket
/// itself (#122).
enum PeerAddress {
    /// The peer's numeric host, such as `192.0.2.7` or `fe80::1%en0`. Nil for
    /// anything that is not an IPv4 or IPv6 socket, such as the AF_UNIX
    /// socketpair a Jump Host transport hands over, and whenever a lookup
    /// fails. See ``format(storage:length:)`` for how IPv6 peers read.
    static func read(descriptor: Int32) -> String? {
        guard descriptor >= 0 else { return nil }

        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(descriptor, $0, &length)
            }
        }
        guard named == 0 else { return nil }
        return format(storage: storage, length: length)
    }

    /// The numeric host of an IPv4 or IPv6 socket address. An IPv4-mapped
    /// (`::ffff:0:0/96`) or NAT64 well-known-prefix (`64:ff9b::/96`, RFC 6052)
    /// IPv6 address reads as the dotted IPv4 it carries. A link-local IPv6
    /// address keeps its `%scope`. Nil for any other family, or when the
    /// lookup fails.
    static func format(storage: sockaddr_storage, length: socklen_t) -> String? {
        switch Int32(storage.ss_family) {
        case AF_INET:
            return numericHost(of: storage, length: length)
        case AF_INET6:
            let address = withUnsafeBytes(of: storage) { bytes in
                bytes.loadUnaligned(as: sockaddr_in6.self)
            }
            if let embedded = embeddedIPv4(address) {
                return numericHost(
                    of: embedded,
                    length: socklen_t(MemoryLayout<sockaddr_in>.size))
            }
            return numericHost(of: storage, length: length)
        default:
            return nil
        }
    }

    /// The IPv4 address an `::ffff:a.b.c.d` or `64:ff9b::a.b.c.d` peer
    /// carries, or nil for any other IPv6 peer.
    private static func embeddedIPv4(_ address: sockaddr_in6) -> sockaddr_in? {
        let bytes = withUnsafeBytes(of: address.sin6_addr) { Array($0) }
        guard bytes.count == 16 else { return nil }
        let prefix = bytes[0..<12]
        let mapped = prefix.elementsEqual(
            [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF])
        let nat64 = prefix.elementsEqual(
            [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0])
        guard mapped || nat64 else { return nil }

        var ipv4 = sockaddr_in()
        ipv4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        ipv4.sin_family = sa_family_t(AF_INET)
        ipv4.sin_port = address.sin6_port
        withUnsafeMutableBytes(of: &ipv4.sin_addr) { destination in
            destination.copyBytes(from: bytes[12..<16])
        }
        return ipv4
    }

    private static func numericHost<Address>(
        of address: Address,
        length: socklen_t
    ) -> String? {
        var address = address
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let hostCapacity = socklen_t(host.count)
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, hostCapacity, nil, 0, NI_NUMERICHOST)
            }
        }
        guard status == 0 else { return nil }

        let text = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard !text.isEmpty else { return nil }
        return String(decoding: text, as: UTF8.self)
    }
}
