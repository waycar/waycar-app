import CryptoKit
import Foundation
import WaycarSSH
import Testing

@testable import Waycar

@Suite(
    "WaycarSSH direct-streamlocal e2e",
    .enabled(
        if: RealSSHFixture.gate(DirectStreamLocalTestEnvironment.current != nil),
        "requires the disposable stream-local fixture"),
    .serialized)
struct WaycarSSHDirectStreamLocalE2ETests {
    @Test("partial request writes and response reads complete one line")
    func partialReadsAndWritesComplete() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.deviceKeyConnection(to: environment.endpoint)
        try await withClosingDirectConnection(connection) { connection in
            let padding = String(repeating: "x", count: 4 * 1024 * 1024)
            let request = requestLine(method: "partial", extra: padding)
            let response = try await connection.exchangeStreamLocal(
                socketPath: environment.socketPath,
                request: request,
                timeout: .sshdBudget(10))
            #expect(response.last == 0x0A)
            #expect(String(decoding: response, as: UTF8.self).contains("\"protocol\":17"))
        }
    }

    @Test("orderly EOF before a response line preserves connection reuse")
    func eofPreservesConnectionReuse() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.deviceKeyConnection(to: environment.endpoint)
        try await withClosingDirectConnection(connection) { connection in
            await #expect(throws: SSHError.unexpectedEOF) {
                _ = try await connection.exchangeStreamLocal(
                    socketPath: environment.socketPath,
                    request: requestLine(method: "eof"),
                    timeout: .sshdBudget(5))
            }
            try await expectPing(connection, socketPath: environment.socketPath)
        }
    }

    @Test("one MiB response bound preserves connection reuse")
    func responseBoundPreservesConnectionReuse() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.deviceKeyConnection(to: environment.endpoint)
        try await withClosingDirectConnection(connection) { connection in
            await #expect(throws: SSHError.responseTooLarge(limit: 1_048_576)) {
                _ = try await connection.exchangeStreamLocal(
                    socketPath: environment.socketPath,
                    request: requestLine(method: "oversized"),
                    timeout: .sshdBudget(5))
            }
            try await expectPing(connection, socketPath: environment.socketPath)
        }
    }

    @Test("cancellation closes only its channel and preserves connection reuse")
    func cancellationPreservesConnectionReuse() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.deviceKeyConnection(to: environment.endpoint)
        try await withClosingDirectConnection(connection) { connection in
            // The connection under test serializes libssh2 calls, so the fixture
            // acknowledgement must travel over a separate SSH session.
            let observer = try await environment.deviceKeyConnection(to: environment.endpoint)
            try await withClosingDirectConnection(observer) { observer in
                let requestID = UUID().uuidString
                let exchange = Task {
                    try await connection.exchangeStreamLocal(
                        socketPath: environment.socketPath,
                        request: requestLine(id: requestID, method: "hang"),
                        timeout: .sshdBudget(30))
                }
                defer { exchange.cancel() }
                try await environment.waitUntilHangRequestObserved(
                    requestID,
                    using: observer)
                exchange.cancel()
                await #expect(throws: SSHError.cancelled) { _ = try await exchange.value }
                try await expectPing(connection, socketPath: environment.socketPath)
            }
        }
    }

    @Test("a missing session maps from one read-only diagnostic without starting herdr")
    func missingSocketMapsToHerdrSessionNotFound() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let marker = environment.countFilePath + ".missing-start-\(UUID().uuidString.lowercased())"
        let quotedMarker = try #require(RemoteShellPath.quotedAbsolute(marker))
        var settings = try environment.settings(
            endpoint: environment.endpoint, wakeCommand: "touch \(quotedMarker)")
        settings.socket = .absolutePath(environment.missingSocketPath)
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        await #expect(
            throws: TransportError.herdrSessionNotFound(path: environment.missingSocketPath)
        ) {
            _ = try await transport.ping()
        }
        #expect(try await transport.readRemoteFileForTesting(at: marker) == nil)
    }

    @Test("stale socket reports the honest combined cause")
    func staleSocketMapsToCombinedFailure() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.deviceKeyConnection(to: environment.endpoint)
        let transport = WaycarSSHTransport(
            connection: connection,
            socketPath: environment.staleSocketPath)

        await #expect(
            throws: TransportError.streamLocalOpenFailed(path: environment.staleSocketPath)
        ) {
            _ = try await transport.ping()
        }
        try await transport.close()
    }

    @Test("global forwarding denial reports the honest combined cause")
    func globalPolicyDenialMapsToCombinedFailure() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.deviceKeyConnection(
            to: environment.globalPolicyEndpoint)
        let transport = WaycarSSHTransport(
            connection: connection,
            socketPath: environment.socketPath)

        await #expect(
            throws: TransportError.streamLocalOpenFailed(path: environment.socketPath)
        ) {
            _ = try await transport.ping()
        }
        try await transport.close()
    }

    @Test("authorized_keys forwarding denial reports the honest combined cause")
    func keyPolicyDenialMapsToCombinedFailure() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let connection = try await environment.deviceKeyConnection(
            to: environment.keyPolicyEndpoint)
        let transport = WaycarSSHTransport(
            connection: connection,
            socketPath: environment.socketPath)

        await #expect(
            throws: TransportError.streamLocalOpenFailed(path: environment.socketPath)
        ) {
            _ = try await transport.ping()
        }
        try await transport.close()
    }

    /// A denied stream-local open is diagnostic only: even a configured
    /// start command that would succeed must never run as a recovery attempt.
    @Test("a forwarding denial never runs the start command")
    func forwardingDenialNeverStartsHerdr() async throws {
        let environment = try #require(DirectStreamLocalTestEnvironment.current)
        let marker = environment.countFilePath + ".denied-start-\(UUID().uuidString.lowercased())"
        let quotedMarker = try #require(RemoteShellPath.quotedAbsolute(marker))
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.settings(
                endpoint: environment.globalPolicyEndpoint,
                wakeCommand: "touch \(quotedMarker)"))
        defer { Task { try? await transport.close() } }

        await #expect(
            throws: TransportError.streamLocalOpenFailed(path: environment.socketPath)
        ) {
            _ = try await transport.ping()
        }
        #expect(try await transport.readRemoteFileForTesting(at: marker) == nil)
    }
}

private struct DirectStreamLocalTestEnvironment: Decodable, Sendable {
    let host: String
    let port: UInt16
    let globalPolicyPort: UInt16
    let keyPolicyPort: UInt16
    let username: String
    let deviceKeySeed: String
    let socketPath: String
    let staleSocketPath: String
    let missingSocketPath: String
    let countFilePath: String

    var endpoint: SSHEndpoint { SSHEndpoint(host: host, port: port) }
    var globalPolicyEndpoint: SSHEndpoint {
        SSHEndpoint(host: host, port: globalPolicyPort)
    }
    var keyPolicyEndpoint: SSHEndpoint { SSHEndpoint(host: host, port: keyPolicyPort) }

    static let current: DirectStreamLocalTestEnvironment? = {
        guard
            let encoded = ProcessInfo.processInfo.environment["WAYCAR_SSH_E2E_CONFIG"],
            let data = Data(base64Encoded: encoded)
        else {
            return nil
        }
        return try? JSONDecoder().decode(DirectStreamLocalTestEnvironment.self, from: data)
    }()

    /// Reaches a fixture through the full `connect(settings:)` path, with an
    /// observable start command that no request may run.
    func settings(
        endpoint: SSHEndpoint,
        wakeCommand: String
    ) throws -> SSHTransportSettings {
        var settings = SSHTransportSettings(
            host: endpoint.host,
            port: Int(endpoint.port),
            username: username,
            credentials: .ed25519(try RealSSHFixture.deviceKey(seed: deviceKeySeed)),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            socket: .absolutePath(socketPath),
            jump: nil)
        settings.wakeCommand = wakeCommand
        settings.wakesInLoginSession = false
        settings.detectionSearchesSystemDirectories = false
        return settings
    }

    func deviceKeyConnection(to endpoint: SSHEndpoint) async throws -> SSHConnection {
        let deviceKey = DeviceKey(privateKey: try RealSSHFixture.deviceKey(seed: deviceKeySeed))
        let connection = try await SSHConnection.connect(to: endpoint, timeout: .sshdBudget(5))
        do {
            try await connection.authenticate(
                username: username,
                publicKey: deviceKey.publicKeyBlob,
                signer: { data in try deviceKey.privateKey.signature(for: data) },
                timeout: .sshdBudget(5))
            return connection
        } catch {
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
    }

    func connectionCount(using connection: SSHConnection) async throws -> Int {
        let quotedPath = try #require(RemoteShellPath.quotedAbsolute(countFilePath))
        let result = try await connection.execute("cat \(quotedPath)", timeout: .sshdBudget(5))
        return try #require(Int(String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func waitUntilHangRequestObserved(
        _ requestID: String,
        using connection: SSHConnection
    ) async throws {
        let response = try await connection.exchangeStreamLocal(
            socketPath: socketPath,
            request: requestLine(method: "fixture.await_hang", extra: requestID),
            timeout: .sshdBudget(25))
        let observation = try JSONDecoder().decode(HangObservation.self, from: response)
        try #require(observation.result.observed)
    }
}

private struct HangObservation: Decodable {
    struct Result: Decodable {
        let observed: Bool
    }

    let result: Result
}

private func requestLine(
    id: String = UUID().uuidString,
    method: String,
    extra: String? = nil
) -> Data {
    var object: [String: String] = ["id": id, "method": method]
    if let extra { object["extra"] = extra }
    let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    var line = encoded ?? Data()
    line.append(0x0A)
    return line
}

private func expectPing(_ connection: SSHConnection, socketPath: String) async throws {
    let response = try await connection.exchangeStreamLocal(
        socketPath: socketPath,
        request: requestLine(method: "ping"),
        timeout: .sshdBudget(5))
    #expect(response.last == 0x0A)
    #expect(String(decoding: response, as: UTF8.self).contains("\"protocol\":17"))
}

private func withClosingDirectConnection<Result>(
    _ connection: SSHConnection,
    operation: (SSHConnection) async throws -> Result
) async throws -> Result {
    do {
        let result = try await operation(connection)
        try await connection.close(timeout: .sshdBudget(2))
        return result
    } catch {
        try? await connection.close(timeout: .sshdBudget(2))
        throw error
    }
}
