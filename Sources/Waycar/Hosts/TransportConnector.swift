import Foundation

/// Opens a connected Transport for the given settings: the seam between UI
/// stores and real SSH. Production is `SSHTransportConnector`; tests inject
/// a scripted fake, so screen logic never touches an SSH library (ADR 0011).
protocol TransportConnector: Sendable {
    /// herdr's Transport.
    func connect(settings: SSHTransportSettings) async throws -> any Transport
    /// The Transport of one backend on the Host (ADR 0026).
    func connect(settings: SSHTransportSettings, backend: HostBackend) async throws -> any Transport
    /// Which backends the Host has (design §4.1), with its Waycar plugin
    /// (#209): the one detection that probes the plugin.
    func detectBackends(settings: SSHTransportSettings) async throws -> HostBackendPresence
    /// Runs the official Waycar installer on the Host over SSH (#209),
    /// handing `progress` each output line as it arrives. Throws
    /// `WaycarPluginUpdate.Failure` when the installer fails.
    func updateWaycarPlugin(
        settings: SSHTransportSettings, request: WaycarPluginUpdateRequest,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> WaycarPluginUpdateResult
    /// What the Host has that decides which Install buttons the panel offers
    /// (WAY-338): one exec, run when the panel opens.
    func preflightInstall(settings: SSHTransportSettings) async throws -> HostInstallPreflight
    /// Runs `plan` on the Host over SSH, handing `progress` each output line
    /// as it arrives. A command that fails is a returned
    /// `BackendInstallRun`; only a failed link throws.
    func runBackendInstall(
        settings: SSHTransportSettings, plan: BackendInstallPlan,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> BackendInstallRun
    /// Starts herdr's server on the Host once: the user's Start Herdr TUI, or
    /// right after Install herdr. Nothing else may call it (#389).
    func wakeHerdr(settings: SSHTransportSettings) async throws
    /// Starts the Host's herdr-core once, in the macOS login session when
    /// there is one: the user's Start Herdr Core, or right after Install
    /// herdr-core. Nothing else may call it (#389). Throws `HerdrStartError`
    /// with herdr-core's output when its start fails.
    func startCore(settings: SSHTransportSettings) async throws
    /// Only the user's Start Codex server may start its shared daemon.
    func startCodex(settings: SSHTransportSettings) async throws
    /// A plain stream-local open only: notices an external daemon start
    /// without another exec. The expected path came from detection.
    func probeCodexServer(settings: SSHTransportSettings, presence: CodexPresence) async throws -> Bool
    /// Only the user's Start OpenCode server may start its shared server.
    func startOpenCode(settings: SSHTransportSettings) async throws
    /// A plain direct-tcpip open of the registered (or default) port only:
    /// notices an external start without another exec. Any refused open
    /// reads as still stopped.
    func probeOpenCodeServer(settings: SSHTransportSettings, presence: OpenCodePresence) async throws -> Bool

    /// `connect(settings:backend:)`, naming the pooled connection the
    /// Transport rides; nil when it rides none (#105). `replacing` names a
    /// connection the caller found unanswered: the Transport rides another
    /// one, a replacement someone already dialed or a new dial.
    func connect(
        settings: SSHTransportSettings, backend: HostBackend, replacing: PooledConnectionID?
    ) async throws -> SharedTransport
    /// Holds `connection` open across a suspension while no Transport rides
    /// it; false when it is gone.
    func keepConnection(_ connection: PooledConnectionID) async -> Bool
    /// Gives `keepConnection`'s hold back.
    func releaseKeptConnection(_ connection: PooledConnectionID) async
    /// Stops sharing a connection found dead: later connects dial anew.
    func retireConnection(_ connection: PooledConnectionID) async
    /// Later connects for `poolKey` no longer join the dial in flight.
    func abandonDial(poolKey: String) async
}

extension TransportConnector {
    /// Connectors that know only herdr: herdr's Transport, and no tmux or
    /// herdr-core.
    func connect(settings: SSHTransportSettings, backend: HostBackend) async throws -> any Transport {
        switch backend {
        case .herdr:
            return try await connect(settings: settings)
        case .ultimate:
            throw TransportError.channelFailed(detail: "Ultimate is not available on this Host.")
        case .codex:
            throw TransportError.channelFailed(detail: "Codex is not available on this Host.")
        case .opencode:
            throw TransportError.channelFailed(detail: "OpenCode is not available on this Host.")
        case .core:
            throw TransportError.coreNotInstalled
        case .zellij:
            throw TransportError.zellijNotInstalled
        case .tmux:
            throw TransportError.tmuxNotInstalled
        }
    }

    /// Connectors that know only herdr see every Host as herdr-only.
    func detectBackends(settings: SSHTransportSettings) async throws -> HostBackendPresence {
        .herdrOnly
    }

    /// Connectors without SSH cannot run the installer.
    func updateWaycarPlugin(
        settings: SSHTransportSettings, request: WaycarPluginUpdateRequest,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> WaycarPluginUpdateResult {
        throw TransportError.channelFailed(detail: "This Host cannot update Waycar.")
    }

    /// Connectors without SSH cannot install software.
    func preflightInstall(settings: SSHTransportSettings) async throws -> HostInstallPreflight {
        throw TransportError.channelFailed(detail: "This Host cannot install software.")
    }

    func runBackendInstall(
        settings: SSHTransportSettings, plan: BackendInstallPlan,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> BackendInstallRun {
        throw TransportError.channelFailed(detail: "This Host cannot install software.")
    }

    func wakeHerdr(settings: SSHTransportSettings) async throws {}

    func startCore(settings: SSHTransportSettings) async throws {}
    func startCodex(settings: SSHTransportSettings) async throws {}
    func probeCodexServer(settings: SSHTransportSettings, presence: CodexPresence) async throws -> Bool {
        false
    }
    func startOpenCode(settings: SSHTransportSettings) async throws {}
    func probeOpenCodeServer(settings: SSHTransportSettings, presence: OpenCodePresence) async throws -> Bool {
        false
    }

    /// Connectors without a pool: every Transport rides its own connection.
    func connect(
        settings: SSHTransportSettings, backend: HostBackend, replacing: PooledConnectionID?
    ) async throws -> SharedTransport {
        SharedTransport(
            transport: try await connect(settings: settings, backend: backend), connection: nil)
    }

    func keepConnection(_ connection: PooledConnectionID) async -> Bool { false }
    func releaseKeptConnection(_ connection: PooledConnectionID) async {}
    func retireConnection(_ connection: PooledConnectionID) async {}
    func abandonDial(poolKey: String) async {}
}

/// The one production SSH backend: libssh2 reaching the herdr socket over
/// direct-streamlocal (ADR 0011). There is deliberately no second path — a
/// Host that denies stream-local forwarding is a server policy to fix, not a
/// case to fall back from. Every Transport it opens rides the Host's pooled
/// `HostSSHSession` (`settings.poolKey`), so herdr and tmux on one Host share
/// one connection.
struct SSHTransportConnector: TransportConnector {
    var pool: HostSSHSessionPool = .shared

    func connect(settings: SSHTransportSettings) async throws -> any Transport {
        try await connect(settings: settings, backend: .herdr)
    }

    func connect(settings: SSHTransportSettings, backend: HostBackend) async throws -> any Transport {
        try await connect(settings: settings, backend: backend, replacing: nil).transport
    }

    func connect(
        settings: SSHTransportSettings, backend: HostBackend, replacing: PooledConnectionID?
    ) async throws -> SharedTransport {
        let acquired = try await pool.acquire(settings: settings, replacing: replacing)
        let session = acquired.session
        switch backend {
        case .herdr:
            return SharedTransport(
                transport: WaycarSSHTransport(session: session, settings: settings),
                connection: acquired.id)
        case .ultimate:
            do {
                let presence = try await session.detectBackends(probingPlugin: false)
                return SharedTransport(
                    transport: try await UltimateTransport.open(
                        session: session, instances: presence.ultimate ?? []),
                    connection: acquired.id)
            } catch {
                await session.release()
                throw error
            }
        case .core:
            // One detection exec: whether herdr-core is there, where, and
            // whether it is recent enough, before a channel is spent on it.
            do {
                let presence = try await session.detectBackends(probingPlugin: false)
                return SharedTransport(
                    transport: try await CoreTransport.open(
                        session: session, settings: settings, presence: presence),
                    connection: acquired.id)
            } catch {
                await session.release()
                throw error
            }
        case .zellij:
            do {
                let presence = try await session.detectBackends(probingPlugin: false)
                return SharedTransport(
                    transport: try await ZellijTransport.open(
                        session: session, settings: settings, presence: presence),
                    connection: acquired.id)
            } catch {
                await session.release()
                throw error
            }
        case .tmux:
            // One detection exec: tmux's version, and whether herdr shares
            // the Host, which decides how an idle tmux looks for sessions.
            // No plugin probe: nothing here reads it, and the Console's own
            // detection (`detectBackends(settings:)`) owns that answer.
            do {
                let presence = try await session.detectBackends(probingPlugin: false)
                return SharedTransport(
                    transport: try await TmuxTransport.open(
                        session: session, settings: settings, presence: presence),
                    connection: acquired.id)
            } catch {
                await session.release()
                throw error
            }
        case .codex:
            // One detection exec: whether Codex's server answers, and on
            // which socket. It starts nothing (design X1).
            do {
                let presence = try await session.detectBackends(probingPlugin: false)
                guard presence.codexRunning, let codex = presence.codex else {
                    throw TransportError.channelFailed(detail: "Codex's server is not running.")
                }
                return SharedTransport(
                    transport: try await CodexTransport.open(session: session, presence: codex),
                    connection: acquired.id)
            } catch {
                await session.release()
                throw error
            }
        case .opencode:
            // One detection exec: whether OpenCode 2's server answers, and
            // where. It starts nothing (O2). The transport reads the
            // password itself and keeps it in memory only.
            do {
                let presence = try await session.detectBackends(probingPlugin: false)
                guard presence.runningServerChats.contains(.opencode), let opencode = presence.opencode else {
                    throw TransportError.channelFailed(detail: "OpenCode's server is not running.")
                }
                return SharedTransport(
                    transport: try await OpenCodeTransport.open(session: session, presence: opencode),
                    connection: acquired.id)
            } catch {
                await session.release()
                throw error
            }
        }
    }

    func keepConnection(_ connection: PooledConnectionID) async -> Bool {
        await pool.keep(connection)
    }

    func releaseKeptConnection(_ connection: PooledConnectionID) async {
        await pool.releaseKept(connection)
    }

    func retireConnection(_ connection: PooledConnectionID) async {
        await pool.retire(connection)
    }

    func abandonDial(poolKey: String) async {
        await pool.abandonDial(key: poolKey)
    }

    func detectBackends(settings: SSHTransportSettings) async throws -> HostBackendPresence {
        let session = try await pool.acquire(settings: settings)
        do {
            let presence = try await session.detectBackends(probingPlugin: true)
            await session.release()
            return presence
        } catch {
            await session.release()
            throw error
        }
    }

    /// Dials (or joins) the Host's pooled session like `detectBackends`.
    func updateWaycarPlugin(
        settings: SSHTransportSettings, request: WaycarPluginUpdateRequest,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> WaycarPluginUpdateResult {
        let session = try await pool.acquire(settings: settings)
        do {
            let result = try await session.updateWaycarPlugin(request, progress: progress)
            await session.release()
            return result
        } catch {
            await session.release()
            throw error
        }
    }

    /// Dials (or joins) the Host's pooled session like `detectBackends`.
    func preflightInstall(settings: SSHTransportSettings) async throws -> HostInstallPreflight {
        let session = try await pool.acquire(settings: settings)
        do {
            let preflight = try await session.preflightInstall()
            await session.release()
            return preflight
        } catch {
            await session.release()
            throw error
        }
    }

    func runBackendInstall(
        settings: SSHTransportSettings, plan: BackendInstallPlan,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> BackendInstallRun {
        let session = try await pool.acquire(settings: settings)
        do {
            let run = try await session.runBackendInstall(plan, progress: progress)
            await session.release()
            return run
        } catch {
            await session.release()
            throw error
        }
    }

    func startCore(settings: SSHTransportSettings) async throws {
        let session = try await pool.acquire(settings: settings)
        do {
            let presence = try await session.detectBackends(probingPlugin: false)
            guard let core = presence.core else { throw TransportError.coreNotInstalled }
            let path: String?
            if let remembered = settings.connectionMemory?.loginPATH {
                path = remembered
            } else {
                path = await CoreLoginPath.resolve(on: session, timeout: .seconds(8))
                if let path { settings.connectionMemory?.rememberLoginPATH(path) }
            }
            try await session.startCoreServer(
                path: core.path, loginPATH: path, inLoginSession: settings.wakesInLoginSession)
            await session.release()
        } catch {
            await session.release()
            throw error
        }
    }

    func probeCodexServer(settings: SSHTransportSettings, presence: CodexPresence) async throws -> Bool {
        guard let path = presence.probeSocketPath ?? presence.socketPath else { return false }
        let session = try await pool.acquire(settings: settings)
        let running: Bool
        do {
            let channel = try await session.openCodexChannel(socketPath: path)
            try? await channel.close(timeout: .seconds(2))
            running = true
        } catch {
            running = false
        }
        await session.release()
        return running
    }

    func probeOpenCodeServer(settings: SSHTransportSettings, presence: OpenCodePresence) async throws -> Bool {
        let endpoint = presence.endpoint ?? OpenCodeEndpoint(host: "127.0.0.1", port: OpenCodePresence.defaultPort)
        let session = try await pool.acquire(settings: settings)
        let running: Bool
        do {
            let channel = try await session.openOpenCodeChannel(host: endpoint.host, port: endpoint.port)
            try? await channel.close(timeout: .seconds(2))
            running = true
        } catch {
            running = false
        }
        await session.release()
        return running
    }

    func startOpenCode(settings: SSHTransportSettings) async throws {
        let session = try await pool.acquire(settings: settings)
        do {
            let loginPATH: String?
            if let remembered = settings.connectionMemory?.loginPATH {
                loginPATH = remembered
            } else {
                loginPATH = await CoreLoginPath.resolve(on: session, timeout: .seconds(8))
                if let loginPATH { settings.connectionMemory?.rememberLoginPATH(loginPATH) }
            }
            let presence = try await session.detectBackends(
                probingPlugin: false, loginPATH: loginPATH)
            guard let opencode = presence.opencode else {
                throw HerdrStartError(output: "OpenCode 2 is not installed here.")
            }
            guard opencode.meetsFloor else {
                throw HerdrStartError(output: "Update OpenCode to use it here.")
            }
            try await session.startOpenCodeServer(
                path: opencode.path, loginPATH: loginPATH,
                inLoginSession: settings.wakesInLoginSession)
            await session.release()
        } catch {
            await session.release()
            throw error
        }
    }

    func startCodex(settings: SSHTransportSettings) async throws {
        let session = try await pool.acquire(settings: settings)
        do {
            let loginPATH: String?
            if let remembered = settings.connectionMemory?.loginPATH {
                loginPATH = remembered
            } else {
                loginPATH = await CoreLoginPath.resolve(on: session, timeout: .seconds(8))
                if let loginPATH { settings.connectionMemory?.rememberLoginPATH(loginPATH) }
            }
            let presence = try await session.detectBackends(
                probingPlugin: false, loginPATH: loginPATH)
            guard let codex = presence.codex else {
                throw HerdrStartError(output: "Codex is not installed here.")
            }
            guard codex.meetsFloor else {
                throw HerdrStartError(output: "Update Codex to use it here.")
            }
            try await session.startCodexServer(
                path: codex.path, loginPATH: loginPATH,
                inLoginSession: settings.wakesInLoginSession)
            await session.release()
        } catch {
            await session.release()
            throw error
        }
    }

    func wakeHerdr(settings: SSHTransportSettings) async throws {
        let session = try await pool.acquire(settings: settings)
        do {
            try await session.wakeHerdrServer(
                wakeCommand: settings.wakeCommand,
                inLoginSession: settings.wakesInLoginSession)
            await session.release()
        } catch {
            await session.release()
            throw error
        }
    }
}

extension SSHTransportSettings {
    /// Transport settings for a catalog Host, given resolved credentials and
    /// the TOFU policy the UI wires up.
    init(host: Host, credentials: SSHCredentials, hostKeyPolicy: HostKeyPolicy) {
        self.init(
            host: host.address,
            port: host.port,
            username: host.username,
            credentials: credentials,
            hostKeyPolicy: hostKeyPolicy,
            socket: host.socketLocation,
            // Both hops use the Host's resolved credential. Device Key is the
            // normal case; password Hosts require the same password at both hops.
            jump: host.usesJumpHost
                ? SSHJumpSettings(
                    host: host.jumpAddress.trimmingCharacters(in: .whitespaces),
                    port: host.jumpPort,
                    username: host.resolvedJumpUsername,
                    credentials: credentials)
                : nil)
        poolKey = Self.catalogPoolKey(for: host)
    }

    /// Everything that decides where the connection goes, as whom, how it
    /// authenticates, and which herdr socket its session probes: the Host id
    /// plus address, port, user, Jump Host and auth method, and the socket.
    /// A catalog Host's connection is pooled under this key.
    static func catalogPoolKey(for host: Host) -> String {
        let jumpPart =
            host.usesJumpHost
            ? "\(host.resolvedJumpUsername)@"
                + "\(host.jumpAddress.trimmingCharacters(in: .whitespaces)):\(host.jumpPort)"
            : "direct"
        let socketPart: String
        switch host.socketLocation {
        case .defaultSession: socketPart = "default"
        case .namedSession(let name): socketPart = "session:\(name)"
        case .absolutePath(let path): socketPart = "path:\(path)"
        }
        return [
            host.id.uuidString,
            "\(host.username)@\(host.address):\(host.port)",
            jumpPart,
            host.authMethod.rawValue,
            socketPart,
        ].joined(separator: "|")
    }
}
