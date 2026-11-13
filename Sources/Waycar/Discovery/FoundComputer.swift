import Foundation

/// A computer Find Computers saw with SSH on. SSH is all it can know: herdr
/// has no network listener of its own, so nothing here names it. The app
/// names herdr only after the user signs in and the Host's own checks run.
struct FoundComputer: Identifiable, Hashable, Sendable {
    enum Source: Hashable, Sendable {
        /// Advertised `_ssh._tcp` over Bonjour (a Mac with Remote Login on,
        /// or a Linux machine running avahi).
        case bonjour
        /// Answered on port 22 during a sweep the user asked for.
        case sweep
    }

    /// What to dial: an IPv4 address.
    let address: String
    let port: Int
    /// The Bonjour service name ("Mike's Mac mini"), or nil for a sweep find,
    /// which only knows the address.
    let serviceName: String?
    /// The software part of the SSH banner ("OpenSSH_9.6p1 Ubuntu-3ubuntu13"),
    /// when the computer answered a probe with one.
    let software: String?
    let source: Source

    var id: String { serviceName.map { "bonjour:\($0.lowercased())" } ?? "\(address):\(port)" }

    /// The row title: the computer's own name when it advertises one.
    var title: String { serviceName ?? address }

    /// The address under a named title; nil when the address is the title.
    var subtitle: String? { serviceName == nil ? nil : address }

    /// The SSH software the banner names, from `SSH-2.0-OpenSSH_9.6p1 Ubuntu`
    /// to `OpenSSH_9.6p1 Ubuntu`. Nil unless the line is an SSH banner.
    static func software(fromBanner banner: String) -> String? {
        let line = banner.split(whereSeparator: \.isNewline).first.map(String.init) ?? banner
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("SSH-") else { return nil }
        // "SSH-<protocol>-<software> <comments>": the software starts after
        // the second dash.
        let parts = trimmed.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let software = parts[2].trimmingCharacters(in: .whitespaces)
        return software.isEmpty ? nil : software
    }

    /// `computers` without duplicates and in a stable order: named Bonjour
    /// computers first by name, then the rest by address. A computer both
    /// sources saw keeps its Bonjour name and gains the sweep's banner.
    static func merged(_ computers: [FoundComputer], subnet: IPv4Subnet? = nil) -> [FoundComputer] {
        let named = Dictionary(grouping: computers.filter { $0.serviceName != nil }, by: \.id)
        let namedAddresses = Set(named.values.flatMap { $0.map(\.address) })
        let unnamed = Dictionary(
            grouping: computers.filter { $0.serviceName == nil && !namedAddresses.contains($0.address) },
            by: \.id)
        let rows = named.values.map { interfaces in
            // Prefer the interface on this Wi-Fi, then the lowest address.
            let ordered = interfaces.sorted { lhs, rhs in
                let leftIsLocal = subnet?.contains(lhs.address) == true
                let rightIsLocal = subnet?.contains(rhs.address) == true
                if leftIsLocal != rightIsLocal { return leftIsLocal }
                let left = IPv4Subnet.numericValue(of: lhs.address) ?? 0
                let right = IPv4Subnet.numericValue(of: rhs.address) ?? 0
                if left != right { return left < right }
                if lhs.port != rhs.port { return lhs.port < rhs.port }
                return (lhs.serviceName ?? "") < (rhs.serviceName ?? "")
            }
            // Each group is nonempty, but avoid an unchecked subscript here.
            return ordered.first.map { preferred in
                let addresses = Set(interfaces.map(\.address))
                let software = computers.filter { addresses.contains($0.address) }
                    .compactMap(\.software).sorted().first
                return FoundComputer(
                    address: preferred.address, port: preferred.port,
                    serviceName: preferred.serviceName, software: software, source: .bonjour)
            }
        }.compactMap { $0 } + unnamed.values.compactMap { duplicates in
            duplicates.sorted { ($0.software ?? "") > ($1.software ?? "") }.first
        }
        return rows.sorted { lhs, rhs in
            switch (lhs.serviceName, rhs.serviceName) {
            case (.some(let left), .some(let right)):
                let order = left.localizedStandardCompare(right)
                return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil):
                return IPv4Subnet.numericValue(of: lhs.address) ?? 0
                    < IPv4Subnet.numericValue(of: rhs.address) ?? 0
            }
        }
    }
}

/// An IPv4 network as the phone sees it, and the addresses a sweep may try.
struct IPv4Subnet: Equatable, Sendable {
    /// The phone's own address and the interface's netmask.
    let address: UInt32
    let mask: UInt32

    init(address: UInt32, mask: UInt32) {
        self.address = address
        self.mask = mask
    }

    /// Private ranges only (RFC 1918): a home or office network. A sweep never
    /// runs on any other address, so it cannot probe a public range.
    var isPrivate: Bool {
        let first = address >> 24
        let second = (address >> 16) & 0xFF
        return first == 10 || (first == 172 && (16...31).contains(second))
            || (first == 192 && second == 168)
    }

    func contains(_ candidate: String) -> Bool {
        guard let value = Self.numericValue(of: candidate) else { return false }
        return value & mask == address & mask
    }

    /// The addresses to probe: the network the phone is on, narrowed to the
    /// /24 around it when the network is bigger (a /16 would be 65,534
    /// probes), never the phone itself, the network address or the broadcast.
    var sweepTargets: [UInt32] {
        let effective = mask | 0xFFFF_FF00
        let network = address & effective
        let broadcast = network | ~effective
        guard broadcast - network > 1 else { return [] }
        return ((network + 1)..<broadcast).filter { $0 != address }
    }

    static func dotted(_ value: UInt32) -> String {
        "\(value >> 24).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }

    /// The address as a number, or nil unless it is a dotted IPv4 address.
    static func numericValue(of address: String) -> UInt32? {
        let parts = address.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt8(part) else { return nil }
            value = value << 8 | UInt32(octet)
        }
        return value
    }
}
