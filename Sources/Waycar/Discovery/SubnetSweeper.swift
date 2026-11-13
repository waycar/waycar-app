import Darwin
import Foundation
import Network

/// What one probe of an address and port found.
enum SSHProbeResult: Equatable, Sendable {
    /// An SSH server answered; the line it sent first.
    case ssh(banner: String)
    /// Something answered, but not with an SSH banner.
    case notSSH
    case unreachable
    /// iOS refused the Local Network permission.
    case localNetworkDenied
}

protocol SSHPortProbing: Sendable {
    func probe(host: String, port: Int) async -> SSHProbeResult
}

/// What a sweep reports.
enum SweepEvent: Equatable, Sendable {
    case found(FoundComputer)
    /// The phone is not on a private Wi-Fi network, so nothing was tried.
    case unavailable
    case denied
    case finished
}

/// Looks for SSH servers across the phone's local network, on a tap and never
/// by itself. Bonjour comes first; this finds the computers that do not
/// advertise (a Linux server without avahi).
protocol NetworkSweeping: Sendable {
    func sweep() -> AsyncStream<SweepEvent>
}

struct SubnetSweeper: NetworkSweeping {
    var probe: any SSHPortProbing = NetworkSSHProbe()
    var localSubnet: @Sendable () -> IPv4Subnet? = { LocalWiFiSubnet.current() }
    var port = 22
    /// Probes in flight at once. A /24 has 253 targets; this keeps a sweep to
    /// a few seconds without opening hundreds of sockets.
    var maxConcurrent = 48

    func sweep() -> AsyncStream<SweepEvent> {
        AsyncStream { continuation in
            let task = Task {
                guard let subnet = localSubnet(), subnet.isPrivate else {
                    continuation.yield(.unavailable)
                    continuation.finish()
                    return
                }
                let targets = subnet.sweepTargets.map(IPv4Subnet.dotted)
                var denied = false
                await withTaskGroup(of: (String, SSHProbeResult).self) { group in
                    var inFlight = 0
                    func record(_ outcome: (String, SSHProbeResult)) {
                        switch outcome.1 {
                        case .ssh(let banner):
                            continuation.yield(
                                .found(
                                    FoundComputer(
                                        address: outcome.0, port: port, serviceName: nil,
                                        software: FoundComputer.software(fromBanner: banner),
                                        source: .sweep)))
                        case .localNetworkDenied:
                            denied = true
                        case .notSSH, .unreachable:
                            break
                        }
                    }
                    for address in targets {
                        if Task.isCancelled || denied { break }
                        if inFlight >= maxConcurrent, let outcome = await group.next() {
                            record(outcome)
                            inFlight -= 1
                        }
                        let probe = probe
                        let port = port
                        group.addTask { (address, await probe.probe(host: address, port: port)) }
                        inFlight += 1
                    }
                    if denied { group.cancelAll() }
                    for await outcome in group { record(outcome) }
                }
                continuation.yield(denied ? .denied : .finished)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// A TCP connect to the port that reads the server's first line. An SSH
/// server sends its banner unprompted, so one read tells SSH from anything
/// else that has the port open.
struct NetworkSSHProbe: SSHPortProbing {
    var timeout: Duration = .seconds(1.2)

    func probe(host: String, port: Int) async -> SSHProbeResult {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            return .unreachable
        }
        let attempt = ProbeAttempt(host: host, port: port, timeout: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                attempt.start(continuation: continuation)
            }
        } onCancel: {
            attempt.cancel()
        }
    }
}

/// One probe. Every callback runs on `queue`, which guards `continuation`, so
/// the class is safe to share by hand.
private final class ProbeAttempt: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.otreva.waycar.find-computers.probe")
    private let connection: NWConnection
    private var continuation: CheckedContinuation<SSHProbeResult, Never>?
    private var machine = SSHBannerProbeMachine()
    private var timeoutWork: DispatchWorkItem?
    private let timeout: Duration

    init(host: String, port: NWEndpoint.Port, timeout: Duration) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.timeout = timeout
    }

    func start(continuation: CheckedContinuation<SSHProbeResult, Never>) {
        queue.async { [self] in
            self.continuation = continuation
            send(.start)
        }
    }

    func cancel() {
        queue.async { [self] in send(.cancel) }
    }

    private func send(_ event: SSHBannerProbeMachine.Event) {
        for effect in machine.handle(event) {
            switch effect {
            case .connect:
                connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
                connection.start(queue: queue)
            case .armTimeout(let token):
                let work = DispatchWorkItem { [weak self] in self?.send(.timeout(token)) }
                timeoutWork = work
                let nanoseconds = Int(timeout.components.seconds) * 1_000_000_000
                    + Int(timeout.components.attoseconds / 1_000_000_000)
                queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds), execute: work)
            case .receive:
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) {
                    [weak self] data, _, complete, error in
                    self?.send(.received(data ?? Data(), complete: complete, failed: error != nil))
                }
            case .finish(let result):
                timeoutWork?.cancel()
                timeoutWork = nil
                connection.stateUpdateHandler = nil
                connection.cancel()
                let pending = continuation
                continuation = nil
                pending?.resume(returning: result)
            }
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            send(.connected)
        case .waiting(let error):
            if LocalNetworkDenial.isDenial(error)
                || connection.currentPath.map({ LocalNetworkDenial.isDenial($0.unsatisfiedReason) })
                    == true
            {
                send(.failed(.localNetworkDenied))
            } else if case .posix(let code) = error,
                [.ECONNREFUSED, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN].contains(code)
            {
                // Nobody home: do not wait out the timeout for it.
                send(.failed(.unreachable))
            }
        case .failed(let error):
            send(.failed(LocalNetworkDenial.isDenial(error) ? .localNetworkDenied : .unreachable))
        default:
            break
        }
    }

}

/// The phone's IPv4 address and netmask on its Wi-Fi (or wired) interface.
enum LocalWiFiSubnet {
    /// `en*` interfaces only: cellular (`pdp_ip*`), VPN tunnels (`utun*`) and
    /// the loopback carry no local network to look through.
    static func current() -> IPv4Subnet? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var candidates: [(name: String, subnet: IPv4Subnet)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                let address = entry.ifa_addr, let netmask = entry.ifa_netmask,
                address.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            let mask = netmask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            // 169.254/16 is a failed DHCP lease, not a network.
            guard ip >> 16 != 0xA9FE else { continue }
            candidates.append((name, IPv4Subnet(address: ip, mask: mask)))
        }
        return (candidates.first { $0.name == "en0" } ?? candidates.first)?.subnet
    }
}
