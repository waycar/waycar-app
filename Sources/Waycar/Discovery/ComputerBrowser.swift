import Foundation
import Network

/// What a Bonjour browse reports.
enum BrowseEvent: Equatable, Sendable {
    case ready
    /// Every `_ssh._tcp` computer the browser currently sees, whole each time.
    case computers([FoundComputer])
    /// iOS refused the Local Network permission.
    case denied
    /// The browser failed for another reason.
    case failed
}

/// Finds computers that advertise SSH over Bonjour. A protocol so
/// `FindComputersStore` runs against scripted browsers in tests.
protocol ComputerBrowsing: Sendable {
    /// Starts a browse. Cancelling the consumer, or ending its iteration,
    /// stops the browser.
    func events() -> AsyncStream<BrowseEvent>
}

/// iOS reports a denied Local Network permission as a policy-denied DNS
/// service error (Apple TN3179). It is the one signal there is: no API reads
/// the permission itself.
enum LocalNetworkDenial {
    /// `kDNSServiceErr_PolicyDenied`
    static let dnsErrorCode: Int32 = -65570

    static func isDenial(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == dnsErrorCode }
        return false
    }

    static func isDenial(_ reason: NWPath.UnsatisfiedReason) -> Bool {
        reason == .localNetworkDenied
    }
}

/// `NWBrowser` on `_ssh._tcp`. The service type is declared in the app's
/// `NSBonjourServices`; iOS shows the Local Network prompt on the first
/// browse.
struct NetworkComputerBrowser: ComputerBrowsing {
    static let serviceType = "_ssh._tcp"

    func events() -> AsyncStream<BrowseEvent> {
        AsyncStream { continuation in
            let session = BonjourSession(continuation: continuation)
            continuation.onTermination = { _ in session.stop() }
            session.start()
        }
    }
}

/// One browse. Every handler runs on `queue`, which also guards the state, so
/// the class is safe to share by hand.
private final class BonjourSession: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.otreva.waycar.find-computers.bonjour")
    private let continuation: AsyncStream<BrowseEvent>.Continuation
    private var browser: NWBrowser?
    /// Keyed by the service endpoint's description, so no closure has to
    /// capture a browse result.
    private var resolvers: [String: ServiceResolver] = [:]
    private var found: [String: FoundComputer] = [:]
    private var stopped = false

    init(continuation: AsyncStream<BrowseEvent>.Continuation) {
        self.continuation = continuation
    }

    func start() {
        queue.async { [self] in
            guard !stopped else { return }
            let browser = NWBrowser(
                for: .bonjour(type: NetworkComputerBrowser.serviceType, domain: nil),
                using: .tcp)
            self.browser = browser
            browser.stateUpdateHandler = { [weak self] state in
                self?.handle(state: state)
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.handle(results: results)
            }
            browser.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            browser?.cancel()
            browser = nil
            for resolver in resolvers.values { resolver.cancel() }
            resolvers = [:]
        }
    }

    private func handle(state: NWBrowser.State) {
        guard !stopped else { return }
        switch state {
        case .ready:
            continuation.yield(.ready)
        case .waiting(let error):
            // Waiting is not an end: an undecided prompt waits here, and the
            // browser resumes by itself once the user answers.
            if LocalNetworkDenial.isDenial(error) { continuation.yield(.denied) }
        case .failed(let error):
            continuation.yield(LocalNetworkDenial.isDenial(error) ? .denied : .failed)
            continuation.finish()
        default:
            break
        }
    }

    private func handle(results: Set<NWBrowser.Result>) {
        guard !stopped else { return }
        var current: Set<String> = []
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint else { continue }
            let key = "\(result.endpoint)"
            current.insert(key)
            guard resolvers[key] == nil else { continue }
            let resolver = ServiceResolver(endpoint: result.endpoint, queue: queue) {
                [weak self] address, port in
                guard let self, !self.stopped, self.resolvers[key] != nil else { return }
                self.found[key] = FoundComputer(
                    address: address, port: port, serviceName: name, software: nil,
                    source: .bonjour)
                self.publish()
            }
            resolvers[key] = resolver
            resolver.start()
        }
        for key in Array(resolvers.keys) where !current.contains(key) {
            resolvers[key]?.cancel()
            resolvers[key] = nil
            found[key] = nil
        }
        publish()
    }

    private func publish() {
        // Keep every interface until the store merges by name using the
        // phone's subnet; sweeping an alternate interface must enrich it too.
        continuation.yield(.computers(Array(found.values)))
    }
}

/// Turns a Bonjour service into an IPv4 address by connecting to it once and
/// reading where the connection landed. IPv4 only: the address becomes a
/// Host's address, and a link-local IPv6 one would not survive a network
/// change.
private final class ServiceResolver: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let resolved: @Sendable (String, Int) -> Void
    private var finished = false

    init(
        endpoint: NWEndpoint, queue: DispatchQueue,
        resolved: @escaping @Sendable (String, Int) -> Void
    ) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        connection = NWConnection(to: endpoint, using: parameters)
        self.queue = queue
        self.resolved = resolved
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.finished else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = self.connection.currentPath?.remoteEndpoint,
                    case .ipv4(let address) = host
                {
                    self.finish()
                    self.resolved(Self.dotted(address), Int(port.rawValue))
                } else {
                    self.finish()
                }
            case .failed:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() { finish() }

    private func finish() {
        finished = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private static func dotted(_ address: IPv4Address) -> String {
        address.rawValue.map(String.init).joined(separator: ".")
    }
}
