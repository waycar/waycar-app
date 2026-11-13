import CryptoKit
import Foundation
import Testing

@testable import Waycar
@testable import WaycarSSH

@Suite(
    "WaycarSSH Jump Host gate e2e",
    .enabled(
        if: RealSSHFixture.gate(WaycarSSHJumpHostTestEnvironment.current != nil),
        "requires the disposable two-sshd Jump Host fixture"),
    .serialized)
struct WaycarSSHJumpHostGateE2ETests {
    @Test("protocol 17 ping traverses independent SSH hops")
    func protocolPingTraversesBothHops() async throws {
        let environment = try #require(WaycarSSHJumpHostTestEnvironment.current)
        let teardown = SSHConnectionTeardownRecorder()
        let jump = try await environment.connectJump()
        let target = try await jump.connectThrough(
            to: environment.targetEndpoint,
            timeout: .sshdBudget(5),
            teardownObserver: { teardown.record($0) })

        #expect(jump.hostKey != target.hostKey)
        // The outer hop rides a TCP socket to the fixture's loopback address;
        // the target rides a socketpair, so it has no peer address for mosh
        // to pin its UDP to (#122).
        #expect(await jump.peerAddress == environment.host)
        #expect(await target.peerAddress == nil)
        try await environment.authenticate(target, privateKey: environment.deviceKey)
        try await expectPing(target, environment: environment, id: "jump-ping")
        try await target.close(timeout: .sshdBudget(3))
        #expect(teardown.steps == [.targetSession, .forwardingChannel, .jumpSession])

        await #expect(throws: SSHError.connectionInvalidated) {
            _ = try await jump.execute("printf poisoned", timeout: .sshdBudget(1))
        }
    }

    @Test("TOFU records both endpoints once and identifies either mismatch")
    func trustIsIndependentAtBothHops() async throws {
        let environment = try #require(WaycarSSHJumpHostTestEnvironment.current)
        let knownHosts = InMemoryKnownHostsStore()
        let confirmations = HostKeyConfirmationRecorder()
        let policy = HostKeyPolicy(knownHosts: knownHosts) { candidate in
            await confirmations.confirm(candidate)
        }

        let first = try await WaycarSSHTransport.connect(
            settings: environment.settings(policy: policy))
        _ = try await first.ping()
        try await first.close()
        let second = try await WaycarSSHTransport.connect(
            settings: environment.settings(policy: policy))
        try await second.close()

        #expect(await confirmations.endpoints == [
            "\(environment.host):\(environment.jumpPort)",
            "\(environment.targetHost):\(environment.targetPort)",
        ])

        let jumpFingerprint = try #require(
            await knownHosts.fingerprint(
                host: environment.host,
                port: Int(environment.jumpPort)))
        await knownHosts.setFingerprint(
            HostKeyFingerprint(
                digest: Data(repeating: 0xA5, count: 32),
                algorithm: jumpFingerprint.algorithm),
            host: environment.host,
            port: Int(environment.jumpPort))
        let jumpError = await #expect(throws: TransportError.self) {
            _ = try await WaycarSSHTransport.connect(
                settings: environment.settings(policy: policy))
        }
        guard case .jumpHostFailed(.hostKeyMismatch) = jumpError else {
            Issue.record("expected the mismatch to identify the Jump Host, got \(String(describing: jumpError))")
            return
        }

        await knownHosts.setFingerprint(
            jumpFingerprint,
            host: environment.host,
            port: Int(environment.jumpPort))
        let targetFingerprint = try #require(
            await knownHosts.fingerprint(
                host: environment.targetHost,
                port: Int(environment.targetPort)))
        await knownHosts.setFingerprint(
            HostKeyFingerprint(
                digest: Data(repeating: 0x5A, count: 32),
                algorithm: targetFingerprint.algorithm),
            host: environment.targetHost,
            port: Int(environment.targetPort))
        let targetError = await #expect(throws: TransportError.self) {
            _ = try await WaycarSSHTransport.connect(
                settings: environment.settings(policy: policy))
        }
        guard case .hostKeyMismatch = targetError else {
            Issue.record("expected the unwrapped mismatch to identify the Host, got \(String(describing: targetError))")
            return
        }
    }

    /// A Host trusted on first connect behind an already trusted Jump Host:
    /// the handshake that asked is closed (`SSHConnection.close` closes the
    /// Jump Host under it too) and the whole chain is dialed again. The new
    /// target handshake finds its key stored, so the user is asked once and
    /// the connection that answers ping is a fresh one.
    @Test("a Host first trusted behind a known Jump Host is asked once and connects")
    func targetTrustedBehindAKnownJumpHostConnects() async throws {
        let environment = try #require(WaycarSSHJumpHostTestEnvironment.current)
        let learned = InMemoryKnownHostsStore()
        let learning = try await WaycarSSHTransport.connect(
            settings: environment.settings(
                policy: HostKeyPolicy(knownHosts: learned) { _ in true }))
        try await learning.close()
        let jumpFingerprint = try #require(
            await learned.fingerprint(
                host: environment.host,
                port: Int(environment.jumpPort)))

        let knownHosts = InMemoryKnownHostsStore()
        await knownHosts.setFingerprint(
            jumpFingerprint, host: environment.host, port: Int(environment.jumpPort))
        let confirmations = HostKeyConfirmationRecorder()
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.settings(
                policy: HostKeyPolicy(knownHosts: knownHosts) { candidate in
                    await confirmations.confirm(candidate)
                }))
        #expect(try await transport.ping().protocolVersion == 17)
        try await transport.close()

        #expect(await confirmations.endpoints == [
            "\(environment.targetHost):\(environment.targetPort)",
        ])
    }

    @Test("outer and target authentication failures retain wrapping and retryability")
    func authenticationFailuresRemainDistinct() async throws {
        let environment = try #require(WaycarSSHJumpHostTestEnvironment.current)
        let policy = environment.acceptingPolicy()
        let unauthorized = Curve25519.Signing.PrivateKey()

        let outerError = await #expect(throws: TransportError.self) {
            _ = try await WaycarSSHTransport.connect(
                settings: environment.settings(
                    policy: policy,
                    jumpCredentials: .ed25519(unauthorized)))
        }
        #expect(outerError == .jumpHostFailed(.authenticationFailed))
        #expect(outerError?.isRetryable == false)

        let targetError = await #expect(throws: TransportError.self) {
            _ = try await WaycarSSHTransport.connect(
                settings: environment.settings(
                    policy: policy,
                    targetCredentials: .ed25519(unauthorized)))
        }
        #expect(targetError == .authenticationFailed)
        #expect(targetError?.isRetryable == false)
    }

    @Test("outer, target, and forwarding failures remain distinct")
    func reachabilityAndForwardingFailuresRemainDistinct() async throws {
        let environment = try #require(WaycarSSHJumpHostTestEnvironment.current)

        let outerError = await #expect(throws: TransportError.self) {
            _ = try await WaycarSSHTransport.connect(
                settings: environment.settings(jumpPort: 1))
        }
        guard case .jumpHostFailed(.sshUnreachable) = outerError else {
            Issue.record("expected wrapped Jump Host reachability, got \(String(describing: outerError))")
            return
        }
        #expect(outerError?.isRetryable == true)

        let targetError = await #expect(throws: TransportError.self) {
            _ = try await WaycarSSHTransport.connect(
                settings: environment.settings(targetPort: 1))
        }
        guard case .sshUnreachable = targetError else {
            Issue.record("expected unwrapped target reachability, got \(String(describing: targetError))")
            return
        }
        #expect(targetError?.isRetryable == true)

        let forwardingError = await #expect(throws: TransportError.self) {
            _ = try await WaycarSSHTransport.connect(
                settings: environment.settings(
                    jumpPort: environment.forwardingDeniedPort))
        }
        #expect(forwardingError == .jumpHostFailed(.tcpForwardingUnavailable))
        #expect(forwardingError?.isRetryable == false)
    }

    @Test("outer and inner handshake deadlines terminate promptly")
    func handshakeDeadlinesTerminatePromptly() async throws {
        let environment = try #require(WaycarSSHJumpHostTestEnvironment.current)
        let startedOuter = ContinuousClock.now
        let outerError = await #expect(throws: TransportError.self) {
            _ = try await WaycarSSHTransport.connect(
                settings: environment.settings(
                    jumpPort: environment.outerStallPort,
                    timeout: .milliseconds(150)))
        }
        #expect(outerError == .jumpHostFailed(.timedOut))
        #expect(ContinuousClock.now - startedOuter < .seconds(1))

        let jump = try await environment.connectJump()
        let startedInner = ContinuousClock.now
        await #expect(throws: SSHError.timedOut) {
            _ = try await jump.connectThrough(
                to: environment.innerStallEndpoint,
                timeout: .milliseconds(150))
        }
        #expect(ContinuousClock.now - startedInner < .seconds(1))
        await #expect(throws: SSHError.connectionInvalidated) {
            _ = try await jump.execute("printf poisoned", timeout: .sshdBudget(1))
        }
    }

    @Test("outer connect and forwarding open obey cancellation and deadlines")
    func outerAndForwardingCancellationTerminatePromptly() async throws {
        let environment = try #require(WaycarSSHJumpHostTestEnvironment.current)
        let outerConnect = Task {
            try await SSHConnection.connect(
                to: SSHEndpoint(host: environment.host, port: environment.outerStallPort),
                timeout: .sshdBudget(30))
        }
        try await Task.sleep(for: .milliseconds(100))
        let outerStarted = ContinuousClock.now
        outerConnect.cancel()
        await #expect(throws: SSHError.cancelled) { _ = try await outerConnect.value }
        #expect(ContinuousClock.now - outerStarted < .seconds(1))

        // Neither forwarding open below gets as far as a native channel: an
        // expired deadline or a cancellation stops it before it starts, so it
        // settles with nothing to reclaim and the Jump Host stays usable. An
        // open interrupted mid-flight is freed or costs the session (the
        // WaycarSSH package's interrupted-open tests).
        let deadlineJump = try await environment.connectJump()
        await #expect(throws: SSHError.timedOut) {
            _ = try await deadlineJump.connectThrough(
                to: environment.targetEndpoint,
                timeout: .zero)
        }
        let afterDeadline = try await deadlineJump.execute(
            "printf reusable", timeout: .sshdBudget(5))
        #expect(afterDeadline.stdout == Data("reusable".utf8))

        let cancelledJump = try await environment.connectJump()
        let forwardingOpen = Task {
            await Task.yield()
            return try await cancelledJump.connectThrough(
                to: environment.targetEndpoint,
                timeout: .sshdBudget(30))
        }
        forwardingOpen.cancel()
        await #expect(throws: SSHError.cancelled) { _ = try await forwardingOpen.value }
        let afterCancel = try await cancelledJump.execute(
            "printf reusable", timeout: .sshdBudget(5))
        #expect(afterCancel.stdout == Data("reusable".utf8))
    }

    @Test("inner handshake and authentication cancellation terminate promptly")
    func nestedCancellationTerminatesPromptly() async throws {
        let environment = try #require(WaycarSSHJumpHostTestEnvironment.current)
        let jump = try await environment.connectJump()
        let handshake = Task {
            try await jump.connectThrough(
                to: environment.innerStallEndpoint,
                timeout: .sshdBudget(30))
        }
        try await Task.sleep(for: .milliseconds(100))
        let startedHandshake = ContinuousClock.now
        handshake.cancel()
        await #expect(throws: SSHError.cancelled) { _ = try await handshake.value }
        #expect(ContinuousClock.now - startedHandshake < .seconds(1))

        let (secondJump, target) = try await environment.connectBothHops()
        let authentication = Task {
            await Task.yield()
            try await environment.authenticate(target, privateKey: environment.deviceKey)
        }
        authentication.cancel()
        await #expect(throws: SSHError.cancelled) { try await authentication.value }
        await #expect(throws: SSHError.connectionInvalidated) {
            try await environment.authenticate(target, privateKey: environment.deviceKey)
        }
        try await target.close(timeout: .sshdBudget(3))
        await #expect(throws: SSHError.connectionInvalidated) {
            _ = try await secondJump.execute("printf poisoned", timeout: .sshdBudget(1))
        }

        let (_, deadlineTarget) = try await environment.connectBothHops()
        await #expect(throws: SSHError.timedOut) {
            try await environment.authenticate(
                deadlineTarget,
                privateKey: environment.deviceKey,
                timeout: .zero)
        }
        await #expect(throws: SSHError.connectionInvalidated) {
            try await environment.authenticate(
                deadlineTarget,
                privateKey: environment.deviceKey)
        }
        try await deadlineTarget.close(timeout: .sshdBudget(3))
    }

    @Test("sequential and concurrent nested exchanges make bounded progress")
    func nestedStressMakesProgress() async throws {
        let environment = try #require(WaycarSSHJumpHostTestEnvironment.current)
        let (_, target) = try await environment.connectAuthenticatedTarget()
        let started = ContinuousClock.now

        for index in 0..<20 {
            try await expectPing(target, environment: environment, id: "sequential-\(index)")
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    try await expectPing(
                        target,
                        environment: environment,
                        id: "concurrent-\(index)")
                }
            }
            try await group.waitForAll()
        }

        #expect(ContinuousClock.now - started < .sshdBudget(15))
        try await target.close(timeout: .sshdBudget(3))
    }

    /// A direct dial by name pins mosh's UDP to the address the SSH socket
    /// reached, not the name resolved again (#122): `localhost` also
    /// resolves to `::1`, where the fixture does not listen.
    @Test("a direct dial by name pins mosh to the address SSH reached")
    func directDialByNamePinsMoshToThePeer() async throws {
        let environment = try #require(WaycarSSHJumpHostTestEnvironment.current)
        let session = try await HostSSHSession.dial(
            settings: try environment.directLocalhostSettings())
        #expect(session.moshUDPHost == "127.0.0.1")
        let bootstrap = try await session.runMoshBootstrap { bindsToPeer in
            #expect(bindsToPeer)
            return "printf 'MOSH CONNECT 60001 MDEyMzQ1Njc4OWFiY2RlZg\\n'"
        }
        #expect(bootstrap.host == "127.0.0.1")
        await session.release()
    }

    /// Runs the real `-s` guard of `moshServerInvocation(bindsToPeer:)`
    /// through sshd against a stub mosh-server that prints its arguments
    /// (#122). The fixture reaches sshd over 127.0.0.1, so `SSH_CONNECTION`
    /// is loopback and mosh-server stays unbound; an off-loopback arrival
    /// gets `-s`.
    @Test("the loopback guard adds -s only for an off-loopback arrival")
    func loopbackGuardBindsOnlyOffLoopback() async throws {
        let environment = try #require(WaycarSSHJumpHostTestEnvironment.current)
        let invocation = HostSSHSession.moshServerInvocation(bindsToPeer: true) + "-- true"
        let separator = "OFF-LOOPBACK"
        let script = [
            "d=$(mktemp -d) || exit 1",
            #"printf '%s\n' '#!/bin/sh' 'echo "ARGS: $*"' > "$d/mosh-server""#,
            #"chmod +x "$d/mosh-server""#,
            #"PATH="$d:$PATH"; export PATH"#,
            "( \(invocation) )",
            "echo \(separator)",
            "( SSH_CONNECTION='203.0.113.5 5 192.0.2.7 22'; \(invocation) )",
            #"rm -rf "$d""#,
        ].joined(separator: "; ")
        let command = "/bin/sh -c '" + script.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let session = try await HostSSHSession.dial(
            settings: try environment.directLocalhostSettings())
        let output = try await session.runHostCommand(command)
        await session.release()

        let runs = String(decoding: output, as: UTF8.self)
            .components(separatedBy: "\(separator)\n")
        try #require(runs.count == 2)
        func arguments(_ run: String) -> Substring? {
            run.split(separator: "\n").first { $0.hasPrefix("ARGS: ") }?.dropFirst("ARGS: ".count)
        }
        let loopback = try #require(arguments(runs[0]))
        let offLoopback = try #require(arguments(runs[1]))
        #expect(!loopback.split(separator: " ").contains("-s"))
        #expect(loopback.hasPrefix("new -c 256 -l LANG=en_US.UTF-8 -- true"))
        #expect(offLoopback.contains("new -s -c 256"))
    }

    /// Behind a Jump Host the Host's socket is a forwarded channel, so mosh
    /// stays on the Host name and mosh-server stays unbound.
    @Test("a Jump Host dial keeps mosh on the Host name")
    func jumpHostDialKeepsMoshOnTheHostName() async throws {
        let environment = try #require(WaycarSSHJumpHostTestEnvironment.current)
        let settings = environment.settings()
        let session = try await HostSSHSession.dial(settings: settings)
        #expect(session.moshUDPHost == nil)
        let bootstrap = try await session.runMoshBootstrap { bindsToPeer in
            #expect(!bindsToPeer)
            return "printf 'MOSH CONNECT 60001 MDEyMzQ1Njc4OWFiY2RlZg\\n'"
        }
        #expect(bootstrap.host == settings.host)
        await session.release()
    }
}

private final class SSHConnectionTeardownRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSteps: [SSHConnectionTeardownStep] = []

    var steps: [SSHConnectionTeardownStep] {
        lock.withLock { recordedSteps }
    }

    func record(_ step: SSHConnectionTeardownStep) {
        lock.withLock { recordedSteps.append(step) }
    }
}

private actor HostKeyConfirmationRecorder {
    private(set) var endpoints: [String] = []

    func confirm(_ candidate: HostKeyCandidate) -> Bool {
        endpoints.append("\(candidate.host):\(candidate.port)")
        return true
    }
}

private struct WaycarSSHJumpHostTestEnvironment: Decodable, Sendable {
    let host: String
    let jumpPort: UInt16
    let forwardingDeniedPort: UInt16
    let targetHost: String
    let targetPort: UInt16
    let outerStallPort: UInt16
    let innerStallHost: String
    let innerStallPort: UInt16
    let username: String
    let deviceKeySeed: String
    let socketPath: String

    var jumpEndpoint: SSHEndpoint { SSHEndpoint(host: host, port: jumpPort) }
    var targetEndpoint: SSHEndpoint { SSHEndpoint(host: targetHost, port: targetPort) }
    var innerStallEndpoint: SSHEndpoint {
        SSHEndpoint(host: innerStallHost, port: innerStallPort)
    }
    var deviceKey: Curve25519.Signing.PrivateKey {
        get throws { try RealSSHFixture.deviceKey(seed: deviceKeySeed) }
    }

    static let current: WaycarSSHJumpHostTestEnvironment? = {
        guard
            let encoded = ProcessInfo.processInfo.environment["WAYCAR_SSH_JUMP_E2E_CONFIG"],
            let data = Data(base64Encoded: encoded)
        else {
            return nil
        }
        return try? JSONDecoder().decode(WaycarSSHJumpHostTestEnvironment.self, from: data)
    }()

    func acceptingPolicy() -> HostKeyPolicy {
        HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true }
    }

    /// The jump sshd dialed as a plain direct Host named `localhost`.
    func directLocalhostSettings() throws -> SSHTransportSettings {
        var settings = SSHTransportSettings(
            host: "localhost",
            port: Int(jumpPort),
            username: username,
            credentials: .ed25519(try deviceKey),
            hostKeyPolicy: acceptingPolicy(),
            socket: .absolutePath(socketPath))
        settings.requestTimeout = .sshdBudget(5)
        settings.wakesInLoginSession = false
        settings.detectionSearchesSystemDirectories = false
        return settings
    }

    func settings(
        policy: HostKeyPolicy? = nil,
        jumpPort: UInt16? = nil,
        targetPort: UInt16? = nil,
        jumpCredentials: SSHCredentials? = nil,
        targetCredentials: SSHCredentials? = nil,
        timeout: Duration = .sshdBudget(5)
    ) -> SSHTransportSettings {
        let key = try? deviceKey
        let credentials = targetCredentials ?? key.map(SSHCredentials.ed25519)
            ?? .password("unavailable")
        let jumpCredentials = jumpCredentials ?? key.map(SSHCredentials.ed25519)
            ?? .password("unavailable")
        var settings = SSHTransportSettings(
            host: targetHost,
            port: Int(targetPort ?? self.targetPort),
            username: username,
            credentials: credentials,
            hostKeyPolicy: policy ?? acceptingPolicy(),
            socket: .absolutePath(socketPath),
            jump: SSHJumpSettings(
                host: host,
                port: Int(jumpPort ?? self.jumpPort),
                username: username,
                credentials: jumpCredentials))
        settings.requestTimeout = timeout
        settings.wakesInLoginSession = false
        settings.detectionSearchesSystemDirectories = false
        return settings
    }

    func connectJump() async throws -> SSHConnection {
        let connection = try await SSHConnection.connect(to: jumpEndpoint, timeout: .sshdBudget(5))
        do {
            try await authenticate(connection, privateKey: deviceKey)
            return connection
        } catch {
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
    }

    func connectBothHops() async throws -> (SSHConnection, SSHConnection) {
        let jump = try await connectJump()
        do {
            let target = try await jump.connectThrough(to: targetEndpoint, timeout: .sshdBudget(5))
            return (jump, target)
        } catch {
            try? await jump.close(timeout: .sshdBudget(2))
            throw error
        }
    }

    func connectAuthenticatedTarget() async throws -> (SSHConnection, SSHConnection) {
        let (jump, target) = try await connectBothHops()
        do {
            try await authenticate(target, privateKey: deviceKey)
            return (jump, target)
        } catch {
            try? await target.close(timeout: .sshdBudget(2))
            throw error
        }
    }

    func authenticate(
        _ connection: SSHConnection,
        privateKey: Curve25519.Signing.PrivateKey,
        timeout: Duration = .sshdBudget(5)
    ) async throws {
        let deviceKey = DeviceKey(privateKey: privateKey)
        try await connection.authenticate(
            username: username,
            publicKey: deviceKey.publicKeyBlob,
            signer: { data in try deviceKey.privateKey.signature(for: data) },
            timeout: timeout)
    }
}

private func requestLine(id: String, method: String = "ping") -> Data {
    Data("{\"id\":\"\(id)\",\"method\":\"\(method)\",\"params\":{}}\n".utf8)
}

private func expectPing(
    _ connection: SSHConnection,
    environment: WaycarSSHJumpHostTestEnvironment,
    id: String
) async throws {
    let response = try await connection.exchangeStreamLocal(
        socketPath: environment.socketPath,
        request: requestLine(id: id),
        timeout: .sshdBudget(5))
    #expect(
        response
            == Data(
                "{\"id\":\"\(id)\",\"result\":{\"protocol\":17,\"version\":\"fake\"}}\n"
                    .utf8))
}
