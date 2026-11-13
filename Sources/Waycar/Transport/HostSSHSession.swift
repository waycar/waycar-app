import Foundation
import os
import Synchronization
import WaycarSSH

/// One Host's SSH connection and every service on it that never speaks a
/// backend's protocol (ADR 0026, design §4.8): the dial (Jump Host, host key
/// policy, credentials), the one `SSHChannelAdmission` every channel on the
/// connection is admitted through (ADR 0011), the `$HOME` cache, Host
/// commands, Host files, attachment staging, mosh, and the generic PTY Attach.
///
/// herdr's `WaycarSSHTransport` and tmux's `TmuxTransport` take the same
/// session, so a Host running both dials once and shares one channel budget.
/// Each holder owns one hold (`retain()` / `release()`); the connection
/// closes with the last. `HostSSHSessionPool` hands out shared sessions.
actor HostSSHSession: HostSSHServices {
    nonisolated let sshHost: String
    /// Where the mosh client sends its UDP when the dial pinned it (#122):
    /// nil through a Jump Host, whose transport is a socketpair rather than
    /// the Host's address; the Host address itself, brackets stripped, when
    /// it is a numeric IPv4 or IPv6 literal (an IPv6 one may carry a
    /// `%scope`); else the numeric address the SSH socket connected to
    /// (`SSHConnection.peerAddress`), nil when that cannot be read. Nil
    /// leaves mosh on `sshHost`.
    ///
    /// When set, mosh-server is launched with `-s`, which binds it to the
    /// address the SSH connection arrived on at the Host (the local half of
    /// `SSH_CONNECTION`), so its UDP answers leave from the address the
    /// client's SSH reached. A loopback arrival means a TCP proxy sits in
    /// front of sshd (sslh, HAProxy, stunnel); `-s` would bind loopback
    /// there, so mosh-server stays unbound
    /// (`moshServerInvocation(bindsToPeer:)`). Only
    /// `runMoshBootstrap(command:missingBanner:)` acts on it.
    nonisolated let moshUDPHost: String?
    nonisolated let requestTimeout: Duration

    let connection: SSHConnection
    /// The herdr socket the dial settings named. Backend detection and the
    /// mosh probe read it; herdr's Transport resolves its own.
    let socketLocation: HerdrSocketLocation
    let homeCommand: String
    let stageDirectoryCommand: String
    let agentDiscoveryCommand: String
    let launchPromptProbeCommand: String
    /// `SSHTransportSettings.detectionSearchesSystemDirectories`.
    let detectionSearchesSystemDirectories: Bool
    let channelAdmission: SSHChannelAdmission
    /// The connection's `$HOME`: remembered from an earlier connection, or
    /// resolved over exec once (#105).
    let homeDirectory: HomeDirectoryResolver
    let connectionMemory: (any HostConnectionMemory)?
    /// Which Launch Prompt File routes the Host's harness CLIs take and
    /// where its panes' Codex home is, asked once per connection
    /// (`launchPromptCapabilities()`).
    let launchPromptCapabilityProbe =
        SharedAsyncOperation<LaunchPromptWriter.ProbeAnswer>(cachesSuccess: true)
    /// Holds, invalidation and close (`HostSessionLifetimeMachine`).
    private var lifetime = HostSessionLifetimeMachine()
    /// False once the connection has been found invalidated or the session
    /// closed: nothing new is started on it.
    var connected: Bool { lifetime.isOpen }
    private var closed: Bool { lifetime.isClosed }

    var imageStageClients: [UUID: SSHSFTPClient] = [:]
    var notificationFileClients: [UUID: SSHSFTPClient] = [:]
    var notificationTemporaryPaths: [UUID: String] = [:]
    /// One SFTP channel held for ranged Host-file reads (#325). Sessions are
    /// followed, not staged, so this one outlives any single request — and so
    /// does its admission lease, which is what keeps the server-side channel
    /// budget honest.
    var sessionFileClient: SSHSFTPClient?
    var sessionFileClientLease: SSHChannelAdmissionLease?
    /// The open in flight, so readers that arrive while nothing is open yet
    /// share it: the actor is re-entered at every await inside that open, and
    /// two independent opens would each keep a channel, one of them unowned.
    var sessionFileClientOpening: Task<SSHSFTPClient, any Error>?
    /// Whether the holder is empty, opening or open, and the reads on it
    /// (`RangedFileHolderMachine`).
    var sessionFileHolder = RangedFileHolderMachine()
    /// Returns the channel once no follower has read for a while. A screen
    /// that stopped looking does not tell the Transport so; without this the
    /// channel and its lease would stay spent until the Host disconnects.
    var sessionFileClientIdleRelease: Task<Void, Never>?
    static let sessionFileClientIdleTimeout: Duration = .seconds(30)
#if DEBUG
    var stagingPhaseHoldsForTesting:
        [AttachmentStagingPhaseForTesting: @Sendable () async -> Void] = [:]
#endif

    /// A session on an already authenticated connection, held once by its
    /// creator. Command defaults come from `SSHTransportSettings` statics so
    /// fixtures cannot drift from the production path (#133).
    init(
        connection: SSHConnection,
        host: String,
        socketLocation: HerdrSocketLocation,
        requestTimeout: Duration = SSHTransportSettings.defaultRequestTimeout,
        homeCommand: String = SSHTransportSettings.defaultHomeCommand,
        stageDirectoryCommand: String = SSHTransportSettings.defaultStageDirectoryCommand,
        agentDiscoveryCommand: String = SSHTransportSettings.defaultAgentDiscoveryCommand,
        launchPromptProbeCommand: String = SSHTransportSettings.defaultLaunchPromptProbeCommand,
        detectionSearchesSystemDirectories: Bool = true,
        connectionMemory: (any HostConnectionMemory)? = nil,
        moshUDPHost: String? = nil
    ) {
        self.connection = connection
        self.connectionMemory = connectionMemory
        sshHost = host
        self.moshUDPHost = moshUDPHost
        self.socketLocation = socketLocation
        self.requestTimeout = requestTimeout
        self.homeCommand = homeCommand
        self.stageDirectoryCommand = stageDirectoryCommand
        self.agentDiscoveryCommand = agentDiscoveryCommand
        self.launchPromptProbeCommand = launchPromptProbeCommand
        self.detectionSearchesSystemDirectories = detectionSearchesSystemDirectories
        channelAdmission = SSHChannelAdmission()
        homeDirectory = HomeDirectoryResolver(memory: connectionMemory)
    }

    init(connection: SSHConnection, settings: SSHTransportSettings, moshUDPHost: String?) {
        self.init(
            connection: connection,
            host: settings.host,
            socketLocation: settings.socket,
            requestTimeout: settings.requestTimeout,
            homeCommand: settings.homeCommand,
            stageDirectoryCommand: settings.stageDirectoryCommand,
            agentDiscoveryCommand: settings.agentDiscoveryCommand,
            launchPromptProbeCommand: settings.launchPromptProbeCommand,
            detectionSearchesSystemDirectories: settings.detectionSearchesSystemDirectories,
            connectionMemory: settings.connectionMemory,
            moshUDPHost: moshUDPHost)
    }

    // MARK: Dial

    /// Dials and authenticates the connection `settings` describe through the
    /// app-owned credentials and TOFU policy; the session comes back held
    /// once, by the caller. Unless an earlier connection's `$HOME` is
    /// remembered (`HostConnectionMemory`), the session starts resolving it
    /// in the background as soon as it exists (`prewarmHomeDirectory()`), so
    /// the first herdr RPC on it finds the socket path's home cached or in
    /// flight.
    ///
    /// A hop whose key the user trusts on first connect is dialed again before
    /// anything authenticates on it. The handshake that presented the key sat
    /// idle while they read the fingerprint (behind the iOS Save Password
    /// sheet, perhaps), and the server does not wait: sshd drops a connection
    /// still unauthenticated after `LoginGraceTime` (60 s on a hardened test Host),
    /// and a network change can drop it sooner. The fresh connection is checked
    /// against the key just trusted, so it never asks again and a different key
    /// fails as a mismatch. A Jump Host chain can ask once per hop.
    static func dial(settings: SSHTransportSettings) async throws -> HostSSHSession {
        let interval = NetworkInterval("ssh dial")
        var redials = settings.jump == nil ? 1 : 2
        do {
            while true {
                if let connection = try await openConnection(
                    settings: settings,
                    redialsAfterTrust: redials > 0)
                {
                    interval.end("connected")
                    let moshUDPHost = await pinnedMoshUDPHost(
                        settings: settings, connection: connection)
                    let session = HostSSHSession(
                        connection: connection, settings: settings, moshUDPHost: moshUDPHost)
                    await session.prewarmHomeDirectory()
                    return session
                }
                redials -= 1
            }
        } catch {
            interval.end(NetworkAnalytics.Failure(error).rawValue)
            throw error
        }
    }

    /// The dial's `moshUDPHost`, by the rule that property documents.
    private static func pinnedMoshUDPHost(
        settings: SSHTransportSettings, connection: SSHConnection
    ) async -> String? {
        // A Jump Host's transport is a socketpair, not the Host's address.
        guard settings.jump == nil else { return nil }
        if let literal = numericAddressLiteral(settings.host) { return literal }
        return await connection.peerAddress
    }

    /// `host` with any surrounding `[` `]` stripped when that is a numeric
    /// IPv4 or IPv6 literal (an IPv6 one may carry a `%scope`); nil for a
    /// name.
    static func numericAddressLiteral(_ host: String) -> String? {
        let literal = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast())
            : host
        var ipv4 = in_addr()
        if inet_pton(AF_INET, literal, &ipv4) == 1 { return literal }
        let parts = literal.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        var ipv6 = in6_addr()
        guard parts.count == 1 || !parts[1].isEmpty,
            inet_pton(AF_INET6, String(parts[0]), &ipv6) == 1
        else { return nil }
        return literal
    }

    /// The authenticated connection `settings` describe, or nil when
    /// `redialsAfterTrust` and the user trusted a hop's key just now. Every
    /// connection that waited for that answer is closed by then, and the
    /// caller dials again.
    private static func openConnection(
        settings: SSHTransportSettings,
        redialsAfterTrust: Bool
    ) async throws -> SSHConnection? {
        let targetEndpoint = try endpoint(host: settings.host, port: settings.port)
        guard let jump = settings.jump else {
            do {
                return try await connectDirect(
                    endpoint: targetEndpoint,
                    username: settings.username,
                    credentials: settings.credentials,
                    policy: settings.hostKeyPolicy,
                    timeout: settings.requestTimeout,
                    redialsAfterTrust: redialsAfterTrust)
            } catch {
                // Every other hop maps before it throws; the direct hop must
                // too, or a raw SSHError escapes the TransportError taxonomy
                // the app and preflight classify against.
                throw mapConnect(error)
            }
        }

        let jumpEndpoint = try endpoint(host: jump.host, port: jump.port)
        let jumpConnection: SSHConnection
        do {
            guard
                let connection = try await connectDirect(
                    endpoint: jumpEndpoint,
                    username: jump.username,
                    credentials: jump.credentials,
                    policy: settings.hostKeyPolicy,
                    timeout: settings.requestTimeout,
                    redialsAfterTrust: redialsAfterTrust)
            else { return nil }
            jumpConnection = connection
        } catch {
            throw TransportError.jumpHostFailed(mapConnect(error))
        }

        let targetConnection: SSHConnection
        do {
            targetConnection = try await jumpConnection.connectThrough(
                to: targetEndpoint,
                timeout: settings.requestTimeout)
        } catch SSHError.forwardingDenied {
            throw TransportError.jumpHostFailed(.tcpForwardingUnavailable)
        } catch SSHError.targetUnreachable {
            throw TransportError.sshUnreachable(detail: "the Host is unreachable from the Jump Host")
        } catch {
            throw mapConnect(error)
        }

        do {
            let verdict = try await WaycarSSHHostKeyVerifier(
                host: settings.host,
                port: settings.port,
                policy: settings.hostKeyPolicy)
                .verify(targetConnection.hostKey)
            if verdict == .trustedOnFirstConnect, redialsAfterTrust {
                // Closes the Jump Host under it too; the next dial redoes both.
                try? await targetConnection.close(timeout: .seconds(2))
                return nil
            }
            try await authenticate(
                targetConnection,
                username: settings.username,
                credentials: settings.credentials,
                timeout: settings.requestTimeout)
            return targetConnection
        } catch {
            try? await targetConnection.close(timeout: .seconds(2))
            throw mapConnect(error)
        }
    }

    /// The authenticated connection to `endpoint`, or nil when
    /// `redialsAfterTrust` and the user trusted its key just now, after
    /// closing the connection that waited for them (see `dial(settings:)`).
    private static func connectDirect(
        endpoint: SSHEndpoint,
        username: String,
        credentials: SSHCredentials,
        policy: HostKeyPolicy,
        timeout: Duration,
        redialsAfterTrust: Bool
    ) async throws -> SSHConnection? {
        let handshake = NetworkInterval("ssh handshake")
        let connection: SSHConnection
        do {
            connection = try await SSHConnection.connect(to: endpoint, timeout: timeout)
        } catch {
            handshake.end("failed")
            throw error
        }
        let handshakeTime = handshake.end("done")
        if let tcp = connection.tcpConnectDuration {
            NetworkLog.logger.info(
                "ssh tcp connect \(tcp.wholeMilliseconds, privacy: .public) ms, key exchange \((handshakeTime - tcp).wholeMilliseconds, privacy: .public) ms"
            )
        }
        var auth: NetworkInterval?
        do {
            let verdict = try await WaycarSSHHostKeyVerifier(
                host: endpoint.host,
                port: Int(endpoint.port),
                policy: policy)
                .verify(connection.hostKey)
            if verdict == .trustedOnFirstConnect, redialsAfterTrust {
                try? await connection.close(timeout: .seconds(2))
                return nil
            }
            auth = NetworkInterval("ssh auth")
            try await authenticate(
                connection,
                username: username,
                credentials: credentials,
                timeout: timeout)
            auth?.end("done")
            return connection
        } catch {
            auth?.end("failed")
            try? await connection.close(timeout: .seconds(2))
            throw error
        }
    }

    private static func authenticate(
        _ connection: SSHConnection,
        username: String,
        credentials: SSHCredentials,
        timeout: Duration
    ) async throws {
        switch credentials {
        case .password(let password):
            try await connection.authenticate(
                username: username,
                password: password,
                timeout: timeout)
        case .ed25519(let privateKey):
            let deviceKey = DeviceKey(privateKey: privateKey)
            try await connection.authenticate(
                username: username,
                publicKey: deviceKey.publicKeyBlob,
                signer: { data in try deviceKey.privateKey.signature(for: data) },
                timeout: timeout)
        case .rsaSHA512(let rsaKey):
            do {
                try await connection.authenticate(
                    username: username,
                    publicKey: rsaKey.publicKeyBlob,
                    signer: { data in try rsaKey.signature(for: data) },
                    timeout: timeout)
            } catch SSHError.algorithmNegotiationFailed {
                // The handshake already succeeded, so during authentication
                // this can only mean no RSA-SHA2-512 signature was possible.
                throw TransportError.rsaSignatureUnsupported
            }
        }
    }

    private static func endpoint(host: String, port: Int) throws -> SSHEndpoint {
        guard let port = UInt16(exactly: port), !host.isEmpty else {
            throw TransportError.sshUnreachable(detail: "the address or port is not valid")
        }
        return SSHEndpoint(host: host, port: port)
    }

    // MARK: Holds and lifetime

    /// Whether the connection is still alive: not closed, not found
    /// invalidated, and reusable at the SSH layer.
    var isConnected: Bool {
        get async {
            guard connected else { return false }
            return await connection.isConnected
        }
    }

    /// Whether the session is still open as far as this app knows, without
    /// asking the SSH layer: false after close or a seen invalidation.
    var isOpen: Bool { connected }

    /// One more hold for a new holder; false once the session has closed, so
    /// the caller dials a fresh one instead.
    func retain() -> Bool {
        lifetime.handle(.retain) == [.retained]
    }

    func release() async {
        try? await releaseReportingTeardown()
    }

    /// `release()`, reporting a failed connection teardown when this was the
    /// last hold: herdr's `close()` has always surfaced it.
    func releaseReportingTeardown() async throws {
        guard lifetime.handle(.release).contains(.tearDown) else { return }
        try await tearDown()
    }

    /// The SSH layer reported the connection invalidated: nothing new starts
    /// on it, and its last release leaves it as it is.
    func noteConnectionInvalidated() {
        _ = lifetime.handle(.connectionInvalidated)
    }

    /// Ends every channel the session itself holds and closes the connection,
    /// after the last release of a session still open. A connection already
    /// found invalidated is left as it is, as the herdr Transport always
    /// left it.
    private func tearDown() async throws {
        let stagingClients = Array(imageStageClients.values)
        imageStageClients.removeAll()
        let notificationClients = Array(notificationFileClients.values)
        notificationFileClients.removeAll()
        var fileReader: SSHSFTPClient?
        var fileReaderLease: SSHChannelAdmissionLease?
        for effect in sessionFileHolder.handle(.sessionClosed) {
            switch effect {
            case .cancelIdleRelease:
                cancelSessionFileClientIdleRelease()
            case .close:
                fileReader = sessionFileClient
                sessionFileClient = nil
                fileReaderLease = sessionFileClientLease
                sessionFileClientLease = nil
            case .use, .joinOpening, .open, .armIdleRelease:
                continue
            }
        }
        for sftp in stagingClients {
            try? await sftp.close(timeout: .seconds(2))
        }
        for sftp in notificationClients {
            try? await sftp.close(timeout: .seconds(2))
        }
        if let fileReader {
            try? await fileReader.close(timeout: .seconds(2))
        }
        await fileReaderLease?.release()
        do {
            try await connection.close(timeout: .seconds(2))
        } catch {
            throw mapOperationError(error)
        }
    }

    // MARK: Channels for backends

    /// Admits one channel of `channelClass`; the caller holds the lease for
    /// as long as the channel is open.
    nonisolated func acquireChannel(
        _ channelClass: SSHChannelAdmission.ChannelClass
    ) async throws -> SSHChannelAdmissionLease {
        try await channelAdmission.acquire(channelClass)
    }

    /// Runs `operation` under one admitted channel of `channelClass`.
    nonisolated func withChannel<Value: Sendable>(
        _ channelClass: SSHChannelAdmission.ChannelClass,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await channelAdmission.withChannel(channelClass, operation: operation)
    }

    /// Runs `operation` under one admitted channel of `channelClass` that
    /// stays admitted until the release `operation` is handed runs: for a
    /// one-shot whose channel closes after the call returns
    /// (`SSHChannelAdmission.withChannel(_:releasedBy:)`).
    nonisolated func withChannel<Value: Sendable>(
        _ channelClass: SSHChannelAdmission.ChannelClass,
        releasedBy operation: @escaping @Sendable (
            _ release: @escaping @Sendable () async -> Void
        ) async throws -> Value
    ) async throws -> Value {
        try await channelAdmission.withChannel(channelClass, releasedBy: operation)
    }

    /// One request/response exchange on a fresh direct-streamlocal channel,
    /// for herdr's RPC. The caller admits it (`.ordinaryForwarding`, held
    /// until `onChannelReleased`: the channel closes after the response is
    /// returned) and maps the raw `SSHError`, since only it knows how to
    /// classify a socket that would not open.
    nonisolated func exchangeStreamLocal(
        socketPath: String,
        request: Data,
        maximumResponseBytes: Int,
        timeout: Duration,
        beforeRequestWrite: (@Sendable () async throws -> Void)?,
        onRequestWritten: (@Sendable () async -> Void)?,
        onChannelReleased: (@Sendable () async -> Void)?
    ) async throws -> Data {
        try await connection.exchangeStreamLocal(
            socketPath: socketPath,
            request: request,
            maximumResponseBytes: maximumResponseBytes,
            timeout: timeout,
            beforeRequestWrite: beforeRequestWrite,
            onRequestWritten: onRequestWritten,
            onChannelReleased: onChannelReleased)
    }

    /// Opens one long-lived direct-streamlocal channel, for herdr's events.
    /// The caller admits it (`.events`) and maps the raw `SSHError`.
    nonisolated func openStreamLocal(socketPath: String) async throws -> SSHStreamLocalChannel {
        try await connection.openStreamLocal(socketPath: socketPath, timeout: requestTimeout)
    }

    /// Opens tmux's control client under one `.control` lease. The lease is
    /// one per connection, and its holder can be a transport that is going
    /// away: waiting for it is bounded by `requestTimeout`
    /// (`TransportError.timedOut`), so an open never hangs on a slot that is
    /// not coming back.
    func openControlChannel(command: String) async throws -> any HostControlChannel {
        try await openExecChannel(command: command, channelClass: .control)
    }

    /// Opens herdr-core's connection under one `.core` lease, bounded like
    /// `openControlChannel(command:)`.
    func openCoreChannel(command: String) async throws -> any HostControlChannel {
        try await openExecChannel(command: command, channelClass: .core)
    }

    func openZellijChannel(command: String) async throws -> any HostControlChannel {
        try await openExecChannel(command: command, channelClass: .zellij)
    }

    private func openExecChannel(
        command: String, channelClass: SSHChannelAdmission.ChannelClass
    ) async throws -> any HostControlChannel {
        guard connected else {
            throw TransportError.sshUnreachable(detail: "the SSH connection is closed")
        }
        let lease: SSHChannelAdmissionLease
        do {
            lease = try await channelAdmission.acquire(channelClass, within: requestTimeout)
        } catch is CancellationError {
            throw TransportError.cancelled
        }
        do {
            let channel = try await connection.openExecStream(
                command: command,
                timeout: requestTimeout)
            return HostSSHControlChannel(channel: channel, lease: lease, session: self)
        } catch {
            await lease.release()
            throw mapOperationError(error)
        }
    }

    /// direct-tcpip is not an sshd session channel (MaxSessions does not
    /// apply). HTTP owns and closes each channel, including the SSE reader.
    func openUltimateChannel(port: UInt16) async throws -> any UltimateByteChannel {
        guard connected, !closed else { throw TransportError.cancelled }
        do {
            return try await connection.openDirectTCP(
                host: "127.0.0.1", port: port, timeout: requestTimeout)
        } catch {
            throw mapOperationError(error)
        }
    }

    /// Like herdr events this is direct-streamlocal, not an sshd session.
    /// Use ordinary forwarding so Codex can coexist with herdr's one events
    /// channel without spending tmux/core's MaxSessions budget.
    func openCodexChannel(socketPath: String) async throws -> any UltimateByteChannel {
        guard connected, !closed else { throw TransportError.cancelled }
        do {
            let lease = try await channelAdmission.acquire(.ordinaryForwarding, within: requestTimeout)
            do {
                guard connected, !closed else { throw TransportError.cancelled }
                let channel = try await connection.openStreamLocal(socketPath: socketPath, timeout: requestTimeout)
                return LeasedForwardingChannel(channel: channel, lease: lease)
            } catch {
                await lease.release()
                throw error
            }
        } catch { throw mapOperationError(error) }
    }

    /// direct-tcpip to OpenCode 2's loopback server, one channel per HTTP
    /// request plus its event stream, admitted like Codex's channel. sshd
    /// refusing it (`AllowTcpForwarding no` or `remote`, `PermitOpen none`,
    /// O7) is the Host's policy, named with its fix: the generic TCP
    /// forwarding error speaks of a Jump Host.
    func openOpenCodeChannel(host: String, port: UInt16) async throws -> any UltimateByteChannel {
        guard connected, !closed else { throw TransportError.cancelled }
        do {
            let lease = try await channelAdmission.acquire(.ordinaryForwarding, within: requestTimeout)
            do {
                guard connected, !closed else { throw TransportError.cancelled }
                let channel = try await connection.openDirectTCP(host: host, port: port, timeout: requestTimeout)
                return LeasedForwardingChannel(channel: channel, lease: lease)
            } catch {
                await lease.release()
                throw error
            }
        } catch SSHError.forwardingDenied {
            throw Self.openCodeForwardingDenied
        } catch { throw mapOperationError(error) }
    }

    static let openCodeForwardingDenied = TransportError.channelFailed(
        detail: "the Host refused SSH TCP forwarding to the OpenCode server. Set AllowTcpForwarding "
            + "local (or yes) in its sshd_config, and allow the server's port in PermitOpen")

    // MARK: Backend detection

    private var detectedCodexPresence: CodexPresence?
    var codexPresence: CodexPresence? {
        // Memory reads the authoritative presence record each time, including
        // explicit starts/stops. Do not shadow its absence with an older copy.
        if let connectionMemory { return connectionMemory.codexPresence }
        return detectedCodexPresence
    }

    /// Which backends this Host has, from one exec (`HostBackendDetection`);
    /// `probingPlugin` also reads its Waycar plugin, else that stays nil.
    func detectBackends(
        probingPlugin: Bool, loginPATH: String? = nil
    ) async throws -> HostBackendPresence {
        let command = HostBackendDetection.command(
            socket: socketLocation, probesPlugin: probingPlugin,
            loginPATH: loginPATH ?? connectionMemory?.loginPATH,
            searchesSystemDirectories: detectionSearchesSystemDirectories)
        let result = try await withRequestDeadline {
            try await self.runExec(command)
        }
        guard let presence = HostBackendDetection.presence(fromOutput: result.stdout) else {
            throw TransportError.channelFailed(
                detail: "backend detection printed: \(Self.preview(result.stdout))")
        }
        detectedCodexPresence = presence.codex
        detectedOpenCodePresence = presence.opencode
        return presence
    }

    private var detectedOpenCodePresence: OpenCodePresence?
    /// Like `codexPresence`: the presence record when memory has one.
    var opencodePresence: OpenCodePresence? {
        if let connectionMemory { return connectionMemory.opencodePresence }
        return detectedOpenCodePresence
    }

    // MARK: Host commands

    /// Starts the `$HOME` exec in the background the moment the session is
    /// dialed, so herdr's first RPC on it finds the socket path's home cached
    /// or in flight (#87, WS2). Paying for that exec inside the first request
    /// put 2–3 round trips plus the first channel's session setup on the
    /// timed ping path; `EventsSession` additionally awaits readiness before
    /// starting the latency clock. The resolution stays single-flight — the
    /// first request joins this run, so the exec still runs exactly once —
    /// and a Host whose socket path is absolute, or whose `$HOME` an earlier
    /// connection proved (#105), needs no exec at all.
    func prewarmHomeDirectory() async {
        guard connected, !closed else { return }
        if case .absolutePath = socketLocation { return }
        guard await !homeDirectory.hasRememberedValue else { return }
        Task { try? await self.remoteHomeDirectory() }
    }

    func remoteHomeDirectory() async throws -> String {
        try await withRequestDeadline {
            try await self.homeDirectory.value(resolvingWith: self.homeDirectoryResolution())
        }
    }

    /// A herdr request found no socket at `failedPath`, a path `location`
    /// resolved against this connection's `$HOME`. Returns whether a
    /// remembered `$HOME` was stale and the path moved, so the request
    /// deserves one retry (`HomeDirectoryResolver.refresh`).
    func refreshHomeDirectory(
        afterFailureAt failedPath: String, location: HerdrSocketLocation
    ) async -> Bool {
        let resolve = homeDirectoryResolution()
        let refreshed = try? await withRequestDeadline {
            await self.homeDirectory.refresh(
                afterFailureAt: failedPath, location: location, resolvingWith: resolve)
        }
        return refreshed ?? false
    }

    /// The home exec. Callers bound their wait by the request deadline; the
    /// exec itself runs to its end (see `SharedAsyncOperation`).
    private nonisolated func homeDirectoryResolution() -> @Sendable () async throws -> String {
        { [self] in
            let result = try await runExec(Self.cLocaleCommand(homeCommand))
            guard
                result.exitStatus == 0,
                let home = Self.markerValue(
                    in: result.stdout,
                    prefix: Self.homeOutputPrefix),
                RemoteShellPath.isQuotableAbsolute(home)
            else {
                throw TransportError.homeDirectoryUnresolvable(
                    detail: "home command printed: \(Self.preview(result.stdout))")
            }
            return home
        }
    }

    /// The dial settings' herdr socket as an absolute path.
    func resolvedSocketPath() async throws -> String {
        if case .absolutePath(let path) = socketLocation { return path }
        return socketLocation.path(homeDirectory: try await remoteHomeDirectory())
    }

    /// Runs `command` (bare `herdr` words get the Host PATH fix) in the C
    /// locale under the request deadline and returns its stdout.
    func runHostCommand(_ command: String) async throws -> Data {
        do {
            return try await withRequestDeadline {
                let result = try await self.runExec(
                    Self.cLocaleCommand(HerdrHostPath.wrappingBareHerdr(command)))
                if let missing = HerdrHostPath.missingBinaryError(
                    exitStatus: result.exitStatus, command: command)
                {
                    throw missing
                }
                guard result.reachedEOF else {
                    throw TransportError.channelFailed(
                        detail: "Host command closed before EOF")
                }
                return result.stdout
            }
        } catch TransportError.timedOut {
            // The SSH layer already named the phase; this names the command
            // whose request budget it was spent on (#343).
            SSHDiagnostics.note("Host command budget \(requestTimeout) expired: \(command)")
            throw TransportError.timedOut
        }
    }

    func runExec(
        _ command: String, input: Data = Data(), timeout: Duration? = nil
    ) async throws -> SSHExecResult {
        try await channelAdmission.withChannel(.ordinarySession) {
            do {
                return try await self.connection.execute(
                    command,
                    input: input,
                    timeout: timeout ?? self.requestTimeout)
            } catch {
                throw await self.mapOperationError(error)
            }
        }
    }

    nonisolated func withRequestDeadline<T: Sendable>(
        _ budget: Duration? = nil,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await Self.withDeadline(budget ?? requestTimeout, operation)
    }

    /// Runs `operation` within `budget`: running out is
    /// `TransportError.timedOut`, cancellation `TransportError.cancelled`.
    static func withDeadline<T: Sendable>(
        _ budget: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await AsyncDeadline.run(for: budget, operation: operation)
        } catch AsyncDeadlineError.timedOut {
            throw TransportError.timedOut
        } catch is CancellationError {
            throw TransportError.cancelled
        }
    }

    static let homeOutputPrefix = "__WAYCAR_HOME__="
    static let stageDirectoryOutputPrefix = "__WAYCAR_STAGE_DIR__="

    /// The value of the last stdout line starting with `prefix`, so login
    /// shell chatter printed before it is ignored.
    static func markerValue(in output: Data, prefix: String) -> String? {
        String(decoding: output, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .reversed()
            .first { $0.hasPrefix(prefix) }
            .map { line in
                var value = String(line.dropFirst(prefix.count))
                if value.last == "\r" { value.removeLast() }
                return value
            }
    }

    static func preview(_ data: Data) -> String {
        String(decoding: data.prefix(200), as: UTF8.self)
    }

    static func cLocaleCommand(_ command: String) -> String {
        "LC_ALL=C \(command)"
    }

    // MARK: Error mapping

    /// Maps a post-connect failure, marking the session closed when the SSH
    /// layer reports the connection invalidated.
    func mapOperationError(_ error: any Error) -> TransportError {
        if error as? SSHError == .connectionInvalidated {
            noteConnectionInvalidated()
        }
        return Self.mapOperation(error)
    }

    static func mapConnect(_ error: any Error) -> TransportError {
        if let error = error as? TransportError { return error }
        guard let error = error as? SSHError else {
            return .sshUnreachable(detail: String(describing: error))
        }
        // Shared cases resolve here before any connect-only arm, so a later
        // generic `.channelFailed` list cannot reclassify them (#133).
        if let shared = sharedClassification(for: error) {
            return shared
        }
        switch error {
        case .targetUnreachable, .connectionFailed, .invalidEndpoint,
            .algorithmNegotiationFailed, .connectionInvalidated:
            return .sshUnreachable(detail: sshErrorDetail(for: error))
        case .channelFailed, .ptyDenied, .streamLocalOpenFailed, .unexpectedEOF,
            .responseTooLarge, .sftpUnavailable, .sftpFailure:
            return .channelFailed(detail: sshErrorDetail(for: error))
        case .authenticationFailed, .timedOut, .cancelled, .forwardingDenied:
            // Exhaustiveness only: `sharedClassification` is total over these.
            return .channelFailed(detail: sshErrorDetail(for: error))
        }
    }

    static func mapOperation(_ error: any Error) -> TransportError {
        guard let error = error as? SSHError else {
            return .channelFailed(detail: String(describing: error))
        }
        // Shared cases resolve here before any operation-only arm, so a later
        // generic `.channelFailed` list cannot reclassify them (#133).
        if let shared = sharedClassification(for: error) {
            return shared
        }
        switch error {
        case .unexpectedEOF:
            return .malformedResponse("stream-local channel closed before a response line")
        case .responseTooLarge(let limit):
            return .malformedResponse("response line exceeds \(limit) bytes")
        case .connectionInvalidated:
            return .sshUnreachable(detail: "the SSH connection is no longer reusable")
        // `.streamLocalOpenFailed` falls here on purpose. Only herdr's
        // `classifyStreamLocalOpenFailure` may produce the path-bearing
        // `TransportError` of the same name, because only it knows the socket
        // path and has run `test -S` against it. Both stream-local open sites
        // catch the SSH error before reaching this generic mapper; were one to
        // stop doing so, a diagnostic-free `.channelFailed` is honest where a
        // fabricated path would not be.
        case .invalidEndpoint, .connectionFailed, .algorithmNegotiationFailed,
            .channelFailed, .ptyDenied, .streamLocalOpenFailed,
            .targetUnreachable, .sftpUnavailable, .sftpFailure:
            return .channelFailed(detail: sshErrorDetail(for: error))
        case .authenticationFailed, .timedOut, .cancelled, .forwardingDenied:
            // Exhaustiveness only: `sharedClassification` is total over these.
            return .channelFailed(detail: sshErrorDetail(for: error))
        }
    }

    /// Classifications that both connect-time (`mapConnect`) and post-connect
    /// (`mapOperation`) apply first for the same `SSHError`. Path-specific
    /// arms never see these cases while this returns non-nil (#133).
    private static func sharedClassification(for error: SSHError) -> TransportError? {
        switch error {
        case .authenticationFailed:
            return .authenticationFailed
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case .forwardingDenied:
            return .tcpForwardingUnavailable
        case .invalidEndpoint, .connectionFailed, .algorithmNegotiationFailed,
            .channelFailed, .ptyDenied, .streamLocalOpenFailed, .unexpectedEOF,
            .responseTooLarge, .connectionInvalidated,
            .targetUnreachable, .sftpUnavailable, .sftpFailure:
            return nil
        }
    }

    /// Short, plain words for an SSH failure, used as the Detail of its
    /// Transport Error Presentation ("SSH unavailable: could not connect.").
    /// `String(describing:)` would show the case name, e.g. "connectionFailed".
    private static func sshErrorDetail(for error: SSHError) -> String {
        switch error {
        case .invalidEndpoint: "the address or port is not valid"
        case .connectionFailed: "could not connect"
        case .algorithmNegotiationFailed: "no SSH settings in common with the Host"
        case .authenticationFailed: "the login was refused"
        case .timedOut: "no answer in time"
        case .cancelled: "cancelled"
        case .channelFailed: "an SSH channel failed"
        case .ptyDenied: "the Host refused a terminal (PTY) for this login"
        case .forwardingDenied: "the Host does not allow forwarding"
        case .targetUnreachable: "the Host could not be reached"
        case .streamLocalOpenFailed: "the herdr socket could not be opened"
        case .unexpectedEOF: "the Host closed the channel early"
        case .responseTooLarge(let limit): "the reply was over \(limit) bytes"
        case .sftpUnavailable: "file transfer is not available"
        case .sftpFailure(let status): "file transfer failed with code \(status)"
        case .connectionInvalidated: "the SSH connection closed"
        }
    }
}

/// Own only this forwarding channel and its admission lease, never the shared SSH session.
private struct LeasedForwardingChannel: UltimateByteChannel {
    let channel: SSHStreamLocalChannel
    let lease: SSHChannelAdmissionLease

    func write(_ data: Data, timeout: Duration) async throws {
        try await channel.write(data, timeout: timeout)
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        try await channel.read(maximumBytes: maximumBytes, timeout: timeout)
    }

    func close(timeout: Duration) async throws {
        do { try await channel.close(timeout: timeout) }
        catch { await lease.release(); throw error }
        await lease.release()
    }
}

/// `HostSSHSession`'s long-lived exec channel (tmux's control client,
/// herdr-core's connection): one PTY-less exec stream and
/// its admission lease, returned exactly once on `close()`. I/O failures map
/// like every other operation on the session.
final class HostSSHControlChannel: HostControlChannel {
    private let channel: SSHExecStreamChannel
    private let lease: SSHChannelAdmissionLease
    private let session: HostSSHSession
    private let closed = Mutex(false)

    init(channel: SSHExecStreamChannel, lease: SSHChannelAdmissionLease, session: HostSSHSession) {
        self.channel = channel
        self.lease = lease
        self.session = session
    }

    func write(_ data: Data, timeout: Duration) async throws {
        do {
            try await channel.write(data, timeout: timeout)
        } catch {
            throw await session.mapOperationError(error)
        }
    }

    func read(maximumBytes: Int, timeout: Duration) async throws -> Data? {
        do {
            return try await channel.read(maximumBytes: maximumBytes, timeout: timeout)
        } catch {
            throw await session.mapOperationError(error)
        }
    }

    func exitStatus(timeout: Duration) async throws -> Int32 {
        do {
            return try await channel.exitStatus(timeout: timeout)
        } catch {
            throw await session.mapOperationError(error)
        }
    }

    func standardErrorTail() async -> String {
        await channel.standardErrorTail()
    }

    func close() async {
        let first = closed.withLock { closed in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard first else { return }
        try? await channel.close(timeout: .seconds(2))
        await lease.release()
    }
}
