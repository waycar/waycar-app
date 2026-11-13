import Darwin
import Foundation
import Network
import Synchronization

/// Which network the device is on, as far as a connection cares (#105,
/// C-NET): the primary interface's kind and name, and its local address's
/// network prefix. Opaque to consumers — compare keys, key caches by them —
/// so it can grow finer without touching them. A Wi-Fi network change keeps
/// `interface` and usually changes `addressPrefix`; moving to cellular
/// changes both.
struct NetworkPathKey: Hashable, Sendable {
    enum Interface: String, Hashable, Sendable {
        case wifi, cellular, wiredEthernet, loopback, other
    }

    let interface: Interface
    /// The primary interface's BSD name (`en0`, `pdp_ip0`); nil when the
    /// path source does not know it.
    let interfaceName: String?
    /// The primary local address's network: the first three octets of an
    /// IPv4 address, the first four groups of an IPv6 one. nil when the
    /// interface has no address worth naming.
    let addressPrefix: String?

    /// `address`'s network prefix (see `addressPrefix`); nil for text that is
    /// not an IP address.
    static func prefix(ofAddress address: String) -> String? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4.s_addr) { Array($0) }
            return bytes.prefix(3).map(String.init).joined(separator: ".")
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            return stride(from: 0, to: 8, by: 2)
                .map { String(format: "%x", UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1])) }
                .joined(separator: ":")
        }
        return nil
    }
}

/// One reading of the device's network path, as a `NetworkPathSource`
/// reports it.
struct NetworkPathSnapshot: Equatable, Sendable {
    var isSatisfied: Bool
    var interface: NetworkPathKey.Interface?
    var interfaceName: String?
    /// The primary interface's local address, if it has one.
    var localAddress: String?

    /// The path's identity; nil while no usable path exists.
    var key: NetworkPathKey? {
        guard isSatisfied, let interface else { return nil }
        return NetworkPathKey(
            interface: interface, interfaceName: interfaceName,
            addressPrefix: localAddress.flatMap(NetworkPathKey.prefix(ofAddress:)))
    }
}

/// Where `NetworkPathMonitor` reads the path from. Production is
/// `SystemNetworkPathSource`; tests inject readings.
protocol NetworkPathSource: Sendable {
    /// Delivers the current reading and every later one to `handler`, on
    /// any thread, until `cancel()`. Called at most once.
    func start(_ handler: @escaping @Sendable (NetworkPathSnapshot) -> Void)
    func cancel()
}

/// The system's path, from `NWPathMonitor`, with the primary interface's
/// local address read from `getifaddrs`.
final class SystemNetworkPathSource: NetworkPathSource {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.otreva.waycar.network-path")

    func start(_ handler: @escaping @Sendable (NetworkPathSnapshot) -> Void) {
        monitor.pathUpdateHandler = { path in
            handler(Self.snapshot(of: path))
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        monitor.cancel()
    }

    private static func snapshot(of path: NWPath) -> NetworkPathSnapshot {
        let primary = path.availableInterfaces.first
        return NetworkPathSnapshot(
            isSatisfied: path.status == .satisfied,
            interface: primary.map { interface(of: $0.type) },
            interfaceName: primary?.name,
            localAddress: primary.flatMap { localAddress(ofInterfaceNamed: $0.name) })
    }

    private static func interface(of type: NWInterface.InterfaceType) -> NetworkPathKey.Interface {
        switch type {
        case .wifi: .wifi
        case .cellular: .cellular
        case .wiredEthernet: .wiredEthernet
        case .loopback: .loopback
        case .other: .other
        @unknown default: .other
        }
    }

    /// The interface's IPv4 address, else its first IPv6 address that is
    /// not link-local (fe80::/10, which every interface has).
    static func localAddress(ofInterfaceNamed name: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var ipv6: String?
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr,
                String(cString: entry.pointee.ifa_name) == name
            else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                if let text = numericHost(address) { return text }
            case AF_INET6 where ipv6 == nil:
                if let text = numericHost(address), !text.lowercased().hasPrefix("fe80") {
                    ipv6 = text
                }
            default:
                continue
            }
        }
        return ipv6
    }

    private static func numericHost(_ address: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard
            getnameinfo(
                address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                nil, 0, NI_NUMERICHOST) == 0
        else { return nil }
        let bytes = host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let text = String(decoding: bytes, as: UTF8.self)
        // A scoped IPv6 address carries its zone (`%en0`): not part of it.
        return text.split(separator: "%").first.map(String.init)
    }
}

/// Watches the device's network path (#105, C-NET): `currentKey` is the
/// path the latest reading names, and `changes()` reports each path the
/// device settles on — after `debounce` without another reading, and only
/// when it differs from the last one reported — so a burst of readings
/// while an interface comes up is one change. The first path read is the
/// baseline, not a change.
///
/// Readiness only: nothing here reconnects anything. Consumers decide what
/// a new path means for them (a mosh rebind, a hedged redial, a per-network
/// cache key).
final class NetworkPathMonitor: Sendable {
    private struct State {
        var started = false
        var currentKey: NetworkPathKey?
        /// The last settled key; nil before the first reading, its baseline.
        var settled: NetworkPathKey??
        var debounce: Task<Void, Never>?
        /// The reading the armed debounce belongs to: a debounce that ran
        /// out after a newer reading arrived settles nothing (B-26).
        var debounceToken: UInt64 = 0
        var subscribers: [UUID: Subscriber] = [:]
    }

    private struct Subscriber {
        let continuation: AsyncStream<NetworkPathKey?>.Continuation
        let wantsBaseline: Bool
    }

    private let source: any NetworkPathSource
    private let debounce: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let afterDebounce: @Sendable () async -> Void
    private let state = Mutex(State())

    /// - Parameters:
    ///   - debounce: how long a path must stand before `changes()` reports it.
    ///   - sleep: waits out `debounce`; tests replace it to settle at will.
    ///   - afterDebounce: runs once a debounce has run out, before it
    ///     settles; tests deliver newer readings there (B-26).
    init(
        source: any NetworkPathSource = SystemNetworkPathSource(),
        debounce: Duration = .milliseconds(750),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        afterDebounce: @escaping @Sendable () async -> Void = {}
    ) {
        self.source = source
        self.debounce = debounce
        self.sleep = sleep
        self.afterDebounce = afterDebounce
    }

    deinit {
        stop()
    }

    /// The path the latest reading names; nil before the first reading and
    /// while no usable path exists.
    var currentKey: NetworkPathKey? {
        state.withLock { $0.currentKey }
    }

    /// Settled path changes from now on: each one the new path's key, nil
    /// when the device has no usable path. Each call is its own stream.
    /// `includingBaseline` first yields the baseline: at once when the
    /// first reading is already in, else when it arrives. Such a stream
    /// buffers every element, so a change settling before the baseline is
    /// read cannot replace it.
    func changes(includingBaseline: Bool = false) -> AsyncStream<NetworkPathKey?> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: NetworkPathKey?.self,
            bufferingPolicy: includingBaseline ? .unbounded : .bufferingNewest(1))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        state.withLock { state in
            if includingBaseline, case .some(let settled) = state.settled {
                continuation.yield(settled)
            }
            state.subscribers[id] = Subscriber(
                continuation: continuation,
                wantsBaseline: includingBaseline && state.settled == nil)
        }
        return stream
    }

    /// Starts reading the path. Idempotent.
    func start() {
        let starts = state.withLock { state in
            defer { state.started = true }
            return !state.started
        }
        guard starts else { return }
        source.start { [weak self] snapshot in
            self?.receive(snapshot)
        }
    }

    /// Stops reading the path and finishes every `changes()` stream.
    func stop() {
        let (debounce, subscribers) = state.withLock { state in
            defer {
                state.debounce = nil
                state.subscribers = [:]
            }
            return (state.debounce, Array(state.subscribers.values))
        }
        debounce?.cancel()
        source.cancel()
        for subscriber in subscribers { subscriber.continuation.finish() }
    }

    /// The first reading is the baseline; every later one waits out the
    /// debounce, replacing the wait of the reading before it.
    private func receive(_ snapshot: NetworkPathSnapshot) {
        let key = snapshot.key
        let reading: (baseline: [Subscriber]?, token: UInt64) = state.withLock { state in
            state.currentKey = key
            state.debounceToken &+= 1
            guard state.settled == nil else { return (nil, state.debounceToken) }
            state.settled = .some(key)
            return (state.subscribers.values.filter(\.wantsBaseline), state.debounceToken)
        }
        if let baselineSubscribers = reading.baseline {
            for subscriber in baselineSubscribers { subscriber.continuation.yield(key) }
            return
        }
        let token = reading.token
        let delay = debounce
        let sleep = sleep
        let afterDebounce = afterDebounce
        let task = Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            await afterDebounce()
            self?.settle(key, token: token)
        }
        let previous = state.withLock { state in
            defer { state.debounce = task }
            return state.debounce
        }
        previous?.cancel()
    }

    private func settle(_ key: NetworkPathKey?, token: UInt64) {
        let subscribers: [Subscriber] = state.withLock { state in
            // A newer reading arrived since this one, even one naming the
            // same path again: its own debounce settles instead (B-26).
            guard state.debounceToken == token, state.currentKey == key,
                state.settled != .some(key)
            else { return [] }
            state.settled = .some(key)
            return Array(state.subscribers.values)
        }
        for subscriber in subscribers { subscriber.continuation.yield(key) }
    }
}
