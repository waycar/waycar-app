import Foundation
import Network
import Testing

@testable import Waycar

@Suite("Subnet sweeper")
struct SubnetSweeperTests {
    private static let home = IPv4Subnet(address: 0xC0A8_012A, mask: 0xFFFF_FF00)  // 192.168.1.42/24

    private func collect(_ stream: AsyncStream<SweepEvent>) async -> [SweepEvent] {
        var events: [SweepEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test func listsOnlyTheAddressesThatAnswerWithAnSSHBanner() async {
        let probe = ScriptedProbe { host in
            switch host {
            case "192.168.1.20": .ssh(banner: "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5")
            case "192.168.1.30": .notSSH
            case "192.168.1.99": .ssh(banner: "SSH-2.0-OpenSSH_9.8")
            default: .unreachable
            }
        }
        let sweeper = SubnetSweeper(probe: probe, localSubnet: { Self.home })

        let events = await collect(sweeper.sweep())

        let found = events.compactMap { event -> FoundComputer? in
            if case .found(let computer) = event { return computer }
            return nil
        }
        #expect(found.map(\.address).sorted() == ["192.168.1.20", "192.168.1.99"])
        #expect(found.first { $0.address == "192.168.1.20" }?.software == "OpenSSH_9.6p1 Ubuntu-3ubuntu13.5")
        #expect(found.allSatisfy { $0.source == .sweep && $0.port == 22 })
        #expect(events.last == .finished)
        #expect(await probe.hosts.count == 253)
        #expect(await probe.hosts.contains("192.168.1.42") == false)
    }

    @Test func neverRunsMoreProbesAtOnceThanItsLimit() async {
        let probe = ScriptedProbe(delay: .milliseconds(2)) { _ in .unreachable }
        let sweeper = SubnetSweeper(probe: probe, localSubnet: { Self.home }, maxConcurrent: 7)

        _ = await collect(sweeper.sweep())

        let peak = await probe.peakInFlight
        #expect(peak <= 7)
        #expect(peak > 1)
    }

    @Test func doesNothingOffAPrivateWiFi() async {
        let probe = ScriptedProbe { _ in .unreachable }
        let offNetwork = SubnetSweeper(probe: probe, localSubnet: { nil })
        let publicRange = SubnetSweeper(
            probe: probe,
            localSubnet: { IPv4Subnet(address: 0x0808_0808, mask: 0xFFFF_FF00) })

        #expect(await collect(offNetwork.sweep()) == [.unavailable])
        #expect(await collect(publicRange.sweep()) == [.unavailable])
        #expect(await probe.hosts.isEmpty)
    }

    @Test func stopsAtTheFirstLocalNetworkDenial() async {
        let probe = ScriptedProbe { _ in .localNetworkDenied }
        let sweeper = SubnetSweeper(probe: probe, localSubnet: { Self.home }, maxConcurrent: 4)

        let events = await collect(sweeper.sweep())

        #expect(events == [.denied])
        #expect(await probe.hosts.count < 253)
    }
}

/// Answers each probe from a script, and records which hosts were probed and
/// how many probes ran at once.
private actor ScriptedProbe: SSHPortProbing {
    private let answer: @Sendable (String) -> SSHProbeResult
    private let delay: Duration
    private(set) var hosts: [String] = []
    private var inFlight = 0
    private(set) var peakInFlight = 0

    init(delay: Duration = .zero, answer: @escaping @Sendable (String) -> SSHProbeResult) {
        self.answer = answer
        self.delay = delay
    }

    func probe(host: String, port: Int) async -> SSHProbeResult {
        hosts.append(host)
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        if delay > .zero { try? await Task.sleep(for: delay) }
        inFlight -= 1
        return answer(host)
    }
}

@Suite("SSH discovery probe")
struct SSHDiscoveryProbeTests {
    @Test func readsAFragmentedIdentificationAfterGreetingLines() async throws {
        let server = try DiscoveryProbeServer(
            pieces: ["Welcome to this computer\r\n", "S", "SH-2.0-", "OpenSSH_test\r\n"])
        defer { server.stop() }
        let port = try await server.start()

        let result = await NetworkSSHProbe(timeout: .seconds(3)).probe(
            host: "127.0.0.1", port: Int(port.rawValue))

        #expect(result == .ssh(banner: "SSH-2.0-OpenSSH_test"))
    }

    @Test func aSilentPortCannotHoldTheSweepOpen() async throws {
        let server = try DiscoveryProbeServer(pieces: [])
        defer { server.stop() }
        let port = try await server.start()

        let result = await NetworkSSHProbe(timeout: .milliseconds(100)).probe(
            host: "127.0.0.1", port: Int(port.rawValue))

        #expect(result == .unreachable)
    }
}

/// Real loopback TCP for the probe, with deliberately fragmented writes.
/// Connections and handlers belong to its serial queue.
private final class DiscoveryProbeServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "waycar.discovery-probe-tests")
    private let listener: NWListener
    private let pieces: [String]
    private var connections: [NWConnection] = []

    init(pieces: [String]) throws {
        self.pieces = pieces
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> NWEndpoint.Port {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    guard let port = listener.port else {
                        continuation.resume(throwing: NWError.posix(.EINVAL))
                        return
                    }
                    continuation.resume(returning: port)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.sendPiece(0, on: connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            listener.cancel()
            listener.newConnectionHandler = nil
            for connection in connections { connection.cancel() }
            connections = []
        }
    }

    private func sendPiece(_ index: Int, on connection: NWConnection) {
        guard pieces.indices.contains(index) else { return }
        connection.send(
            content: Data(pieces[index].utf8),
            completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { return }
                self.queue.asyncAfter(deadline: .now() + .milliseconds(20)) {
                    self.sendPiece(index + 1, on: connection)
                }
            })
    }
}
