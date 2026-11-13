import CryptoKit
import Foundation
import Synchronization
import Testing
import WaycarSSH

@testable import Waycar

@Suite(
    "WaycarSSH Transport behavior e2e",
    .enabled(
        if: RealSSHFixture.gate(WaycarSSHTransportBehaviorEnvironment.current != nil),
        "requires the disposable direct and Jump Host fixtures"),
    .serialized)
struct WaycarSSHTransportBehaviorE2ETests {
    /// Both directions of the floor, because a fix tested in one direction is
    /// untested in the direction that broke. This test replaces one that
    /// asserted protocol 18 was *refused*: that encoded the equality rule
    /// #140 removed, and a server above the generated version is now usable.
    @Test("the protocol floor admits newer servers and refuses older ones")
    func protocolFloorAdmitsNewerAndRefusesOlder() throws {
        #expect(WaycarSSHTransport.minimumProtocolVersion == 17)
        #expect(WaycarSSHTransport.generatedProtocolVersion == 22)

        // Below the floor: refused, because methods this app calls may be absent.
        #expect(
            throws: TransportError.protocolVersionMismatch(server: 16, supported: 17)
        ) {
            _ = try WaycarSSHTransport.serverInfo(
                from: PongResponse(protocolVersion: 16, version: "ancient"))
        }

        // Floor through generated (17–22): usable, no notice. 18 and 19 stay
        // connectable after the snapshot bump; the live fake-herdr fixture
        // still speaks 17 and is not rewritten to require 22 at runtime.
        for version in [
            WaycarSSHTransport.minimumProtocolVersion,
            18,
            19,
            20,
            21,
            WaycarSSHTransport.generatedProtocolVersion,
        ] {
            let info = try WaycarSSHTransport.serverInfo(
                from: PongResponse(protocolVersion: version, version: "known"))
            #expect(info.protocolVersion == version)
            #expect(!info.exceedsGeneratedProtocol)
        }

        // Above the generated version: still usable — this is the case that
        // made the user's 0.8.0 Host unusable — and it carries the notice.
        let newer = try WaycarSSHTransport.serverInfo(
            from: PongResponse(
                protocolVersion: WaycarSSHTransport.generatedProtocolVersion + 1,
                version: "future"))
        #expect(newer.exceedsGeneratedProtocol)
        #expect(newer.version == "future")
    }

    /// The exact reply the user's live herdr 0.8.0 returns, captured from
    /// `~/.config/herdr/herdr.sock`. Pins the regression itself rather than a
    /// synthetic version number.
    @Test("the live herdr 0.8.0 pong connects rather than being refused")
    func liveZeroEightZeroPongIsAccepted() throws {
        let pong = try JSONDecoder().decode(
            PongResponse.self,
            from: Data(
                #"""
                {"type":"pong","version":"0.8.0","protocol":19,
                 "capabilities":{"live_handoff":true,"detached_server_daemon":true}}
                """#.utf8))
        let info = try WaycarSSHTransport.serverInfo(from: pong)

        #expect(info.version == "0.8.0")
        #expect(info.protocolVersion == 19)
        #expect(!info.exceedsGeneratedProtocol)
    }

    /// Protocol 20 remains supported. A 0.8.2-shaped pong must not
    /// raise the "newer than this app was built against" notice.
    @Test("a protocol 20 pong does not set the generated-protocol notice")
    func protocolTwentyPongDoesNotExceedGenerated() throws {
        let pong = try JSONDecoder().decode(
            PongResponse.self,
            from: Data(
                #"""
                {"type":"pong","version":"0.8.2","protocol":20,
                 "capabilities":{"live_handoff":true,"detached_server_daemon":true}}
                """#.utf8))
        let info = try WaycarSSHTransport.serverInfo(from: pong)

        #expect(info.version == "0.8.2")
        #expect(info.protocolVersion == 20)
        #expect(!info.exceedsGeneratedProtocol)
    }

    @Test("direct Host ordinary RPCs preserve the Transport seam")
    func directOrdinaryRPCs() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseOrdinaryRPCs(settings: environment.directSettings())
    }

    @Test("RSA credentials authenticate when the Host accepts only RSA-SHA2-512")
    func rsaSHA512Authenticates() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseOrdinaryRPCs(settings: environment.rsaSettings())
    }

    @Test("RSA authenticates both hops when each Host accepts only RSA-SHA2-512")
    func jumpRSAAuthenticatesBothHops() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseOrdinaryRPCs(settings: environment.jumpRSASettings())
    }

    @Test("Jump Host ordinary RPCs preserve the same Transport seam")
    func jumpOrdinaryRPCs() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseOrdinaryRPCs(settings: environment.jumpSettings())
    }

    /// The ADR 0011 Host contract in one test: SSH access plus a running herdr.
    /// Nothing here is injected — the catalog Host maps straight onto production
    /// settings, so the connection resolves the default-session socket over the
    /// real home probe and reaches herdr with no Host-side helper in the path.
    /// Only the login-session wake is off: on the fixture's Mac that session
    /// is the developer's own.
    @Test("the production connector reaches a direct Host")
    func productionConnectorReachesADirectHost() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseProductionConnector(host: environment.directHost())
    }

    @Test("the production connector reaches a Jump Host target")
    func productionConnectorReachesAJumpHostTarget() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseProductionConnector(host: environment.jumpHost())
    }

    @Test("direct Host notification files preserve atomic SFTP behavior")
    func directNotificationFiles() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseNotificationFiles(
            settings: environment.directSettings(),
            homePath: environment.homePath)
    }

    @Test("Jump Host notification files preserve atomic SFTP behavior")
    func jumpNotificationFiles() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseNotificationFiles(
            settings: environment.jumpSettings(),
            homePath: environment.homePath)
    }

    /// "Not installed" is a recoverable instruction to the user; anything else
    /// is a Host problem. Collapsing the two would tell someone to install a
    /// plugin that is already there, so every way the probe can fail stays
    /// distinct from absence.
    @Test("a disabled or unprobeable notification plugin stays distinguishable")
    func notificationPluginProbeFailuresStayTyped() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)

        // Installed but switched off: herdr will not run it, so it counts as
        // not installed rather than as a broken Host.
        var disabled = environment.directSettings()
        disabled.pluginListCommand =
            "printf '%s' '{\"id\":\"cli:plugin\",\"result\":{\"plugins\":["
            + "{\"plugin_id\":\"\(SSHTransportSettings.notificationPluginID)\",\"enabled\":false}]}}'"
        #expect(
            try await notificationRegistrationFailure(settings: disabled)
                == .pluginNotInstalled)

        // herdr missing from the Host's PATH: the probe exits nonzero.
        var missingBinary = environment.directSettings()
        missingBinary.pluginListCommand = "/nonexistent/herdr plugin list --json"
        try await expectPluginProbeFailure(
            settings: missingBinary, "a Host without herdr on PATH")

        // The probe runs and succeeds but answers with something that is not
        // a plugin list.
        var unparseable = environment.directSettings()
        unparseable.pluginListCommand = "printf '%s' 'herdr: not json'"
        try await expectPluginProbeFailure(
            settings: unparseable, "an unparseable plugin list")

        // The plugin resolves, but the config-directory probe answers without
        // its marker, so there is no directory to trust.
        var unmarkedDirectory = environment.directSettings()
        unmarkedDirectory.pluginListCommand = Self.installedPluginListCommand
        unmarkedDirectory.notificationConfigDirCommand = "printf 'no marker here\\n'"
        try await expectPluginProbeFailure(
            settings: unmarkedDirectory, "a config directory probe without its marker")
    }

    /// A Host still running the plugin under an earlier id keeps accepting
    /// Notification Registration: the matched id is substituted into the
    /// config-dir probe, so the file lands in the directory that plugin
    /// actually reads — and the current id wins when both are installed.
    @Test("a legacy plugin id routes registration into that plugin's config dir")
    func legacyNotificationPluginIDKeepsRegistrationWorking() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let baseDirectory =
            "\(environment.homePath)/.waycar-ci/notify-legacy-\(UUID().uuidString.lowercased())"
        let tokenConfigDirCommand =
            "/bin/sh -c 'umask 077; mkdir -p \"$1\" || exit 1; "
            + "printf \"__WAYCAR_PLUGIN_CONFIG_DIR__=%s\\n\" \"$1\"' notify "
            + (try #require(RemoteShellPath.quotedAbsolute(
                "\(baseDirectory)/\(SSHTransportSettings.notificationPluginIDToken)")))
        let registration = Data(#"{"v":1,"devices":[]}"#.utf8)

        var legacyOnly = environment.directSettings()
        legacyOnly.pluginListCommand =
            "printf '%s' '{\"id\":\"cli:plugin\",\"result\":{\"plugins\":["
            + "{\"plugin_id\":\"herdr-mobile.pairing\",\"enabled\":true}]}}'"
        legacyOnly.notificationConfigDirCommand = tokenConfigDirCommand
        let legacyTransport = try await WaycarSSHTransport.connect(settings: legacyOnly)
        try await legacyTransport.replaceNotificationRegistration(registration)
        #expect(
            try await legacyTransport.readRemoteFileForTesting(
                at: "\(baseDirectory)/herdr-mobile.pairing/notifications.json")
                == registration)
        try await legacyTransport.close()

        // Legacy listed first must not outrank the current id.
        var bothInstalled = environment.directSettings()
        bothInstalled.pluginListCommand =
            "printf '%s' '{\"id\":\"cli:plugin\",\"result\":{\"plugins\":["
            + "{\"plugin_id\":\"herdr-mobile.pairing\",\"enabled\":true},"
            + "{\"plugin_id\":\"\(SSHTransportSettings.notificationPluginID)\",\"enabled\":true}]}}'"
        bothInstalled.notificationConfigDirCommand = tokenConfigDirCommand
        let preferredTransport = try await WaycarSSHTransport.connect(settings: bothInstalled)
        try await preferredTransport.replaceNotificationRegistration(registration)
        #expect(
            try await preferredTransport.readRemoteFileForTesting(
                at: "\(baseDirectory)/\(SSHTransportSettings.notificationPluginID)/notifications.json")
                == registration)
        try await preferredTransport.close()
    }

    @Test("direct Host Events preserve framing, concurrency, and slot reuse")
    func directEventsStream() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseEventsStream(settings: environment.directSettings())
    }

    @Test("Jump Host Events preserve framing, concurrency, and slot reuse")
    func jumpEventsStream() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseEventsStream(settings: environment.jumpSettings())
    }

    @Test("direct Host Attach preserves PTY IO, resize, end, and reuse")
    func directAttach() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseAttach(
            settings: environment.directSettings(),
            socketPath: environment.socketPath)
    }

    @Test("Jump Host Attach preserves PTY IO, resize, end, and reuse")
    func jumpAttach() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseAttach(
            settings: environment.jumpSettings(),
            socketPath: environment.socketPath)
    }

    @Test("direct Host ordinary terminal Attach preserves PTY behavior")
    func directShellTerminalAttach() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseShellTerminalAttach(
            settings: environment.directSettings(),
            socketPath: environment.socketPath)
    }

    @Test("Jump Host ordinary terminal Attach preserves PTY behavior")
    func jumpShellTerminalAttach() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseShellTerminalAttach(
            settings: environment.jumpSettings(),
            socketPath: environment.socketPath)
    }

    @Test("direct Host RPC does not stall Attach")
    func directRPCDoesNotStallAttach() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseRPCDoesNotStallAttach(settings: environment.directSettings())
    }

    @Test("Jump Host RPC does not stall Attach")
    func jumpRPCDoesNotStallAttach() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseRPCDoesNotStallAttach(settings: environment.jumpSettings())
    }

    @Test("direct Host clean Attach exit frees the reserved channel")
    func directCleanAttachExit() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseCleanAttachExit(settings: environment.directSettings())
    }

    @Test("Jump Host clean Attach exit frees the reserved channel")
    func jumpCleanAttachExit() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseCleanAttachExit(settings: environment.jumpSettings())
    }

    @Test("distinct targets attach concurrently while each target has one owner")
    func attachIsExclusivePerTarget() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let first = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:pane", cols: 80, rows: 24))
        var iterator = first.output.makeAsyncIterator()
        var output = ""
        try await expectAttachOutput(&iterator, accumulated: &output, contains: "TTY-OK")
        await #expect(throws: TransportError.terminalChannelAlreadyOpen) {
            _ = try await transport.attachTerminal(
                TerminalAttachRequest(target: "fixture:pane", cols: 80, rows: 24))
        }
        let second = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:second", cols: 80, rows: 24))
        var secondIterator = second.output.makeAsyncIterator()
        var secondOutput = ""
        try await expectAttachOutput(&secondIterator, accumulated: &secondOutput, contains: "TTY-OK")
        await second.end()

        await first.end()
        let replacement = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:replacement", cols: 80, rows: 24))
        await replacement.end()
    }

    @Test("nonzero Attach exit reports the primary channel failure and wakes input")
    func failedAttachExitFreesChannel() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let failed = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:failure", cols: 80, rows: 24))
        var iterator = failed.output.makeAsyncIterator()
        var output = ""
        try await expectAttachOutput(&iterator, accumulated: &output, contains: "TTY-OK")
        failed.send(Data("__fail__\n".utf8))
        await #expect(
            throws: TransportError.channelFailed(
                detail: "attach channel: remote exit status 23")
        ) {
            while try await iterator.next() != nil {}
        }

        let replacement = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:replacement", cols: 80, rows: 24))
        await replacement.end()
        #expect(try await transport.ping().protocolVersion == 17)
    }

    @Test("remote Events close is typed and frees only the reserved channel")
    func remoteEventsClosePreservesConnection() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let stream = try await transport.subscribeToEvents([
            .pane(.agentStatusChanged, paneID: "fixture:remote-close")
        ])
        var iterator = stream.events.makeAsyncIterator()
        #expect(try await iterator.next()?.data["pane_id"] == .string("fixture:remote-close"))
        await #expect(
            throws: TransportError.channelFailed(detail: "events channel closed by remote")
        ) {
            _ = try await iterator.next()
        }

        #expect(try await transport.ping().protocolVersion == 17)
        let replacement = try await transport.subscribeToEvents([.global(.paneCreated)])
        await replacement.end()
        #expect(await transport.isConnected)
    }

    @Test("rejected Events ack frees the reserved channel")
    func rejectedEventsAckPreservesConnection() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        await #expect(
            throws: HerdrAPIError(code: "fixture_rejected", message: "scripted rejection")
        ) {
            _ = try await transport.subscribeToEvents([
                .pane(.agentStatusChanged, paneID: "fixture:reject")
            ])
        }

        let replacement = try await transport.subscribeToEvents([.global(.paneCreated)])
        await replacement.end()
        #expect(try await transport.ping().protocolVersion == 17)
    }

    @Test("missing Events ack times out and frees the reserved channel")
    func missingEventsAckPreservesConnection() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        var settings = environment.directSettings()
        // Fixture never ACKs, so the first assertion stays deterministic at any
        // finite budget. 100ms was a scheduling assertion under load (#145): the
        // same timeout also bounds the replacement subscribe and ping that prove
        // the channel was freed.
        settings.requestTimeout = .seconds(1)
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        await #expect(throws: TransportError.timedOut) {
            _ = try await transport.subscribeToEvents([
                .pane(.agentStatusChanged, paneID: "fixture:no-ack")
            ])
        }

        let replacement = try await transport.subscribeToEvents([.global(.paneCreated)])
        await replacement.end()
        #expect(try await transport.ping().protocolVersion == 17)
    }

    @Test("Host exec discovery and home-relative sockets match on direct and Jump paths")
    func hostExecDiscoveryMatchesBothPaths() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        try await exerciseHostExecOperations(
            settings: environment.directSettings(socket: .defaultSession),
            homePath: environment.homePath)
        try await exerciseHostExecOperations(
            settings: environment.jumpSettings(socket: .namedSession("fixture")),
            homePath: environment.homePath)
    }

    /// The dial starts the `$HOME` exec before any request asks for it (#87,
    /// WS2), so every request here races that dial-time probe. The fixture
    /// holds it in flight for a second: all twelve pings arrive while it runs
    /// and must join it, and the ping after them must find the home cached,
    /// one exec in all. The count file is new to this run. Resetting it with
    /// a request on this connection worked while the probe waited for the
    /// first request; now that request races the dial's exec and usually
    /// erases its count.
    @Test("concurrent first-use home probes share work and cache only success")
    func firstUseHomeProbeIsSingleFlight() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let probePath =
            environment.countFilePath + ".home-probe-\(UUID().uuidString.lowercased())"
        var settings = environment.directSettings(socket: .defaultSession)
        settings.homeCommand = environment.countingHomeCommand(probePath, holdSeconds: 1)
        settings.agentDiscoveryCommand = environment.countAssertionCommand(
            probePath,
            expected: 1)
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        try await withThrowingTaskGroup(of: ServerInfo.self) { group in
            for _ in 0..<12 {
                group.addTask { try await transport.ping() }
            }
            for try await info in group {
                #expect(info.protocolVersion == 17)
            }
        }
        #expect(try await transport.availableAgentKinds() == [.codex])
        _ = try await transport.ping()
        #expect(try await transport.availableAgentKinds() == [.codex])
    }

    /// The dial-time probe fails, held in flight so the first ping joins it
    /// and gets that failure. Nothing is cached: the next ping runs the exec
    /// again and succeeds, two execs in all. A new count file, as above.
    @Test("failed first-use home probes retry instead of caching failure")
    func failedHomeProbeRetries() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let probePath =
            environment.countFilePath + ".home-retry-\(UUID().uuidString.lowercased())"
        var settings = environment.directSettings(socket: .defaultSession)
        settings.homeCommand = environment.failOnceHomeCommand(probePath, holdSeconds: 1)
        settings.agentDiscoveryCommand = environment.countAssertionCommand(
            probePath,
            expected: 2)
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        await #expect(throws: TransportError.self) { _ = try await transport.ping() }
        #expect(try await transport.ping().protocolVersion == 17)
        #expect(try await transport.availableAgentKinds() == [.codex])
    }

    /// A `$HOME` an earlier connection proved spares the dial its home exec
    /// (#105): neither the prewarm nor the first request runs it.
    @Test("a remembered home runs no home exec")
    func rememberedHomeRunsNoHomeExec() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let probePath =
            environment.countFilePath + ".home-remembered-\(UUID().uuidString.lowercased())"
        var settings = environment.directSettings(socket: .defaultSession)
        settings.homeCommand = environment.countingHomeCommand(probePath)
        settings.connectionMemory = RememberedFacts(homeDirectory: environment.homePath)
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        #expect(try await transport.ping().protocolVersion == 17)
        // A wrongly-started exec is on the wire from the dial on; the poll
        // keeps the negative assertion from passing only because a read
        // raced it.
        let deadline = ContinuousClock.now + .seconds(1)
        var count = 0
        repeat {
            count = try await countHomeExecs(transport, probePath)
            if count > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        #expect(count == 0, "a remembered home must not run the home exec")
    }

    /// A remembered `$HOME` the socket is no longer under (#105): the
    /// request that finds no socket re-resolves `$HOME` over exec, once,
    /// retries at the corrected path, and the corrected home is remembered.
    @Test("a stale remembered home re-resolves once and the request succeeds")
    func staleRememberedHomeReResolves() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let probePath =
            environment.countFilePath + ".home-stale-\(UUID().uuidString.lowercased())"
        let memory = RememberedFacts(homeDirectory: environment.homePath + "/moved-away")
        var settings = environment.directSettings(socket: .defaultSession)
        settings.homeCommand = environment.countingHomeCommand(probePath)
        settings.connectionMemory = memory
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        #expect(try await transport.ping().protocolVersion == 17)
        #expect(memory.homeDirectory == environment.homePath)
        #expect(try await transport.ping().protocolVersion == 17)
        #expect(try await countHomeExecs(transport, probePath) == 1)
    }

    /// The dial starts resolving `$HOME` before any request asks for it
    /// (#87, WS2): the count appears with no first request in flight, and the
    /// first timed request — readiness and ping — never repeats the exec.
    @Test("the dial prewarms the home probe and the first request never repeats it")
    func dialPrewarmsTheHomeProbe() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let probePath = environment.countFilePath + ".home-prewarm"
        var settings = environment.directSettings(socket: .defaultSession)
        settings.homeCommand = environment.countingHomeCommand(probePath)
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        let prewarmDeadline = ContinuousClock.now + .waitCeiling
        var prewarmCount = 0
        while ContinuousClock.now < prewarmDeadline {
            prewarmCount = try await countHomeExecs(transport, probePath)
            if prewarmCount == 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(
            prewarmCount == 1,
            "the dial-time prewarm must run the home exec exactly once, unprompted")

        await transport.awaitSocketPathReadiness()
        #expect(try await transport.ping().protocolVersion == 17)
        #expect(
            try await countHomeExecs(transport, probePath) == 1,
            "the first request must join the prewarm, not run a second exec")
    }

    /// A Host whose socket path is absolute resolves nothing over exec —
    /// neither the dial-time prewarm nor the first request (#87, WS2).
    @Test("an absolute socket path runs no home exec at all")
    func absoluteSocketPathRunsNoHomeExec() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let probePath = environment.countFilePath + ".home-absolute"
        var settings = environment.directSettings()
        settings.homeCommand = environment.countingHomeCommand(probePath)
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        await transport.awaitSocketPathReadiness()
        #expect(try await transport.ping().protocolVersion == 17)
        // A wrongly-started prewarm has its exec on the wire from the dial on,
        // so it would be counted during the reads above; the poll keeps the
        // negative assertion from passing only because a read raced it.
        let deadline = ContinuousClock.now + .seconds(1)
        var count = 0
        repeat {
            count = try await countHomeExecs(transport, probePath)
            if count > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        #expect(
            count == 0,
            "an absolute socket path must not run the home exec")
    }

    /// The home exec count file the fixture's `countingHomeCommand` appends
    /// to; one byte per run. nil reads as zero.
    private func countHomeExecs(
        _ transport: WaycarSSHTransport, _ probePath: String
    ) async throws -> Int {
        (try await transport.readRemoteFileForTesting(at: probePath))?.count ?? 0
    }

    /// A stale socket never starts herdr on a request. Only an explicit
    /// start can recover it; a failed or ineffective start leaves it stale.
    @Test("a stale socket stays stopped until an explicit start")
    func staleSocketRequiresExplicitStart() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        var recovering = environment.directSettings(
            socket: .absolutePath(environment.staleSocketPath))
        recovering.sessionListCommand = environment.resetStaleSocketCommand(
            environment.staleSocketPath)
        recovering.wakeCommand =
            "printf x >> \"$HERDR_SOCKET_PATH-wakes\"; " + environment.linkWakeCommand
        let stopped = try await WaycarSSHTransport.connect(settings: recovering)
        _ = try await stopped.listSessions()
        await #expect(
            throws: TransportError.streamLocalOpenFailed(path: environment.staleSocketPath)
        ) {
            _ = try await stopped.ping()
        }
        #expect(
            try await stopped.readRemoteFileForTesting(at: environment.staleSocketPath + "-wakes")
                == nil)
        try await stopped.close()

        // The production button path accepts these nil-poolKey settings:
        // it dials a private session and releases it when the start ends.
        let connector = SSHTransportConnector()
        try await connector.wakeHerdr(settings: recovering)
        let recovered = try await WaycarSSHTransport.connect(settings: recovering)
        #expect(try await recovered.ping().protocolVersion == 17)
        #expect(
            try await recovered.readRemoteFileForTesting(at: environment.staleSocketPath + "-wakes")?
                .count == 1)
        try await recovered.close()

        var failing = environment.directSettings(
            socket: .absolutePath(environment.wakeFailureStaleSocketPath))
        failing.sessionListCommand = environment.resetStaleSocketCommand(
            environment.wakeFailureStaleSocketPath)
        failing.wakeCommand = "false"
        let failed = try await WaycarSSHTransport.connect(settings: failing)
        _ = try await failed.listSessions()
        await #expect(throws: HerdrStartError(output: "")) {
            try await connector.wakeHerdr(settings: failing)
        }
        await #expect(
            throws: TransportError.streamLocalOpenFailed(
                path: environment.wakeFailureStaleSocketPath)
        ) {
            _ = try await failed.ping()
        }
        try await failed.close()

        var ineffective = environment.directSettings(
            socket: .absolutePath(environment.wakeFailureStaleSocketPath))
        ineffective.sessionListCommand = environment.resetStaleSocketCommand(
            environment.wakeFailureStaleSocketPath)
        ineffective.wakeCommand = "true"
        let unrecovered = try await WaycarSSHTransport.connect(settings: ineffective)
        _ = try await unrecovered.listSessions()
        try await connector.wakeHerdr(settings: ineffective)
        await #expect(
            throws: TransportError.streamLocalOpenFailed(
                path: environment.wakeFailureStaleSocketPath)
        ) {
            _ = try await unrecovered.ping()
        }
        try await unrecovered.close()
    }

    /// A request classifies the stale socket without running the hung
    /// command. An explicit start runs it and is bounded by the deadline.
    @Test("a hung explicit start times out while requests only classify the socket")
    func hungExplicitStartSurfacesTimedOut() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let socketPath = environment.wakeFailureStaleSocketPath
        var resetting = environment.directSettings(socket: .absolutePath(socketPath))
        resetting.sessionListCommand = environment.resetStaleSocketCommand(socketPath)
        let reset = try await WaycarSSHTransport.connect(settings: resetting)
        _ = try await reset.listSessions()
        try await reset.close()

        var settings = environment.directSettings(socket: .absolutePath(socketPath))
        // Hung for this test's purpose: it outlives the 2 s request deadline
        // and the 30 s bound below. Detached from the closed channel, it must
        // still end with the fixture, so it stops once the socket's directory
        // is gone and after 60 s at most. No single quote: the wake runs
        // inside a single-quoted `sh -c`.
        settings.wakeCommand =
            #"i=0; while [ -d "${HERDR_SOCKET_PATH%/*}" ] && [ $i -lt 600 ]; "#
            + #"do sleep 0.1; i=$((i+1)); done"#
        settings.requestTimeout = .seconds(2)
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        await #expect(throws: TransportError.streamLocalOpenFailed(path: socketPath)) {
            _ = try await transport.ping()
        }
        let started = ContinuousClock.now
        await #expect(throws: TransportError.timedOut) {
            try await SSHTransportConnector().wakeHerdr(settings: settings)
        }
        #expect(started.duration(to: .now) < .seconds(30))
    }

    /// A socket missing from an existing folder, with herdr on the PATH,
    /// stays stopped until the user explicitly starts it through the connector.
    @Test("a stopped herdr is not woken by requests and recovers after an explicit start")
    func stoppedHerdrRequiresExplicitStart() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let scratch =
            "\(environment.homePath)/.waycar-ci/stopped-\(UUID().uuidString.lowercased())"
        let socketPath = scratch + ".sock"
        var recovering = environment.directSettings(socket: .absolutePath(socketPath))
        recovering.wakeCommand =
            "printf x >> \"$HERDR_SOCKET_PATH-wakes\"; " + environment.linkWakeCommand
        let stopped = try await WaycarSSHTransport.connect(settings: recovering)
        await #expect(throws: TransportError.herdrNotRunning(path: socketPath)) {
            _ = try await stopped.ping()
        }
        await #expect(throws: TransportError.herdrNotRunning(path: socketPath)) {
            _ = try await stopped.subscribeToEvents([.global(.paneCreated)])
        }
        #expect(try await stopped.readRemoteFileForTesting(at: socketPath + "-wakes") == nil)
        try await stopped.close()

        let connector = SSHTransportConnector()
        try await connector.wakeHerdr(settings: recovering)
        let recovered = try await WaycarSSHTransport.connect(settings: recovering)
        #expect(try await recovered.ping().protocolVersion == 17)
        let wakes = try await recovered.readRemoteFileForTesting(at: socketPath + "-wakes")
        #expect(wakes?.count == 1)
        try await recovered.close()

        let failingPath = scratch + "-failing.sock"
        var failing = environment.directSettings(socket: .absolutePath(failingPath))
        failing.wakeCommand = "printf \"  fixture start refused  \\n\" >&2; exit 1"
        await #expect(throws: HerdrStartError(output: "fixture start refused")) {
            try await connector.wakeHerdr(settings: failing)
        }
        let failed = try await WaycarSSHTransport.connect(settings: failing)
        await #expect(throws: TransportError.herdrNotRunning(path: failingPath)) {
            _ = try await failed.ping()
        }
        try await failed.close()
    }

    /// herdr counts a named session only once its folder exists, and a start
    /// would create it: a session whose folder is missing stays
    /// `.herdrSessionNotFound` and is never started.
    @Test("a missing named session is distinguished without attempting start")
    func missingSocketStaysTyped() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let session = "absent-\(UUID().uuidString.lowercased())"
        let marker = "\(environment.homePath)/.waycar-ci/\(session)-woken"
        let quotedMarker = try #require(RemoteShellPath.quotedAbsolute(marker))
        var settings = environment.directSettings(socket: .namedSession(session))
        settings.wakeCommand = "touch \(quotedMarker)"
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        let missingPath =
            HerdrSocketLocation.namedSession(session).path(homeDirectory: environment.homePath)
        await #expect(throws: TransportError.herdrSessionNotFound(path: missingPath)) {
            _ = try await transport.ping()
        }
        #expect(try await transport.readRemoteFileForTesting(at: marker) == nil)
        #expect(await transport.isConnected)
    }

    @Test("cancellation closes one RPC channel and preserves later reuse")
    func cancelledRequestPreservesReuse() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }
        var observerSettings = environment.directSettings()
        observerSettings.requestTimeout = .seconds(25)
        let observer = try await WaycarSSHTransport.connect(settings: observerSettings)
        defer { Task { try? await observer.close() } }

        let hangToken = UUID().uuidString
        let request = Task {
            try await transport.readPane(
                PaneReadParams(paneID: "fixture:hang:\(hangToken)", source: .recent))
        }
        defer { request.cancel() }
        let observation = try await observer.readPane(
            PaneReadParams(paneID: "fixture:await-hang:\(hangToken)", source: .recent))
        try #require(observation.text == "observed")
        request.cancel()
        await #expect(throws: TransportError.cancelled) { _ = try await request.value }
        #expect(try await transport.ping().protocolVersion == 17)
        #expect(await transport.isConnected)
    }

    @Test("a timed out RPC closes its channel and preserves later reuse")
    func timedOutRequestPreservesReuse() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        var settings = environment.directSettings()
        // Hang fixture never answers, so the first assertion stays deterministic
        // at any finite budget. 100ms was a scheduling assertion under load
        // (#145): the same timeout also bounds the post-timeout ping that proves
        // the channel was freed for reuse.
        settings.requestTimeout = .seconds(1)
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        await #expect(throws: TransportError.timedOut) {
            _ = try await transport.readPane(
                PaneReadParams(paneID: "hang", source: .recent))
        }
        #expect(try await transport.ping().protocolVersion == 17)
        #expect(await transport.isConnected)
    }

    @Test("concurrent ordinary RPCs use one fresh channel each")
    func concurrentRPCsUseFreshChannels() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        var settings = environment.directSettings()
        settings.sessionListCommand = environment.connectionCountCommand
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        let before = try await connectionCount(from: transport)
        try await withThrowingTaskGroup(of: ServerInfo.self) { group in
            for _ in 0..<12 { group.addTask { try await transport.ping() } }
            for try await info in group { #expect(info.protocolVersion == 17) }
        }
        let after = try await connectionCount(from: transport)
        #expect(after - before == 12)
    }

    /// CLAUDE.md's load-bearing herdr 0.7.5 fact: `agent.start` on a pane whose
    /// shell has not reached its prompt is refused with `agent_pane_busy`, and
    /// the Transport waits the shell out rather than surfacing it. herdr 0.8.0
    /// did not open that window; 0.9.1 opens it again while a fresh pane's
    /// shell rc is still running, so the retry is live again. The fixture
    /// holds the behavior still so a refactor cannot silently drop it.
    @Test("agent start waits out a fresh pane's booting shell")
    func agentStartRetriesWhileTheFreshPaneShellBoots() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("busy2")
        let agent = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "codex",
                name: "fixture",
                workspaceID: "workspace-1",
                cwd: "/fixture/\(token)"))

        #expect(agent.paneID == "pane:\(token)")
        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(recorded.filter { $0.hasPrefix("agent.start ") }.count == 3)
        #expect(!recorded.contains { $0.hasPrefix("pane.close ") })
    }

    /// The other end of the same retry: a pane that never becomes an available
    /// shell must surface herdr's refusal rather than retry forever, and it
    /// must keep retrying for the whole budget before it does so. The budget
    /// is shortened here; its production default must still cover a real
    /// shell's boot.
    @Test("a shell that never boots exhausts the retry budget and surfaces herdr's refusal")
    func agentStartStopsRetryingWhenTheShellNeverBoots() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        // A slow shell boot observed on a real Host took >10 s to its prompt.
        #expect(SSHTransportSettings.defaultShellReadinessBudget > .seconds(10))
        let budget: Duration = .seconds(2)
        let retryDelay: Duration = .milliseconds(50)
        var settings = environment.directSettings()
        settings.shellReadinessBudget = budget
        settings.shellReadinessRetryDelay = retryDelay
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("busyforever")
        let started = ContinuousClock.now
        await #expect(
            throws: HerdrAPIError(
                code: "agent_pane_busy",
                message: "pane is not an available shell")
        ) {
            _ = try await transport.startAgent(
                AgentLaunchRequest(
                    kind: "codex",
                    name: "fixture",
                    workspaceID: "workspace-1",
                    cwd: "/fixture/\(token)"))
        }
        // A band, not a point. The lower bound is load-safe because the wait
        // is a deadline rather than work — a slow machine cannot finish it
        // early; the last retry is skipped once it would land past the
        // deadline. The upper bound stays generous because load pushes only
        // that way.
        let elapsed = started.duration(to: .now)
        #expect(elapsed >= budget - retryDelay)
        #expect(elapsed < budget + .seconds(30))

        // Retried rather than refused once or slept out the budget in one go.
        // Far below the ~40 attempts an idle machine fits into the budget, so
        // slow round trips on a loaded runner cannot fail it.
        let attempts = try await Self.recordedRequests(from: transport, token: token)
            .filter { $0.hasPrefix("agent.start ") }
            .count
        #expect(attempts >= 3)
    }

    /// The tab is created before the agent, so a refused launch would otherwise
    /// strand an empty pane on the Host. Only the failing launch may clean it
    /// up — nothing later knows the pane was ever meant to hold an agent.
    @Test("a refused agent start closes the pane it created")
    func refusedAgentStartClosesTheFreshPane() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("startfails")
        await #expect(throws: Self.refusedStart) {
            _ = try await transport.startAgent(
                AgentLaunchRequest(
                    kind: "codex",
                    name: "fixture",
                    workspaceID: "workspace-1",
                    cwd: "/fixture/\(token)"))
        }

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        try #require(recorded.count == 3)
        #expect(recorded[0].hasPrefix("tab.create "))
        #expect(recorded[1].hasPrefix("agent.start "))
        #expect(recorded[2] == #"pane.close {"pane_id":"pane:\#(token)"}"#)
    }

    /// The worktree half of the same compensation, and the only caller of
    /// `removeWorktree`. A refused launch here would otherwise leave a checkout
    /// and a workspace behind, which is worse than a stranded pane.
    @Test("a refused worktree agent start removes the worktree it created")
    func refusedWorktreeAgentStartRemovesTheWorktree() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("startfails")
        await #expect(throws: Self.refusedStart) {
            _ = try await transport.startAgentInNewWorktree(
                AgentLaunchRequest(
                    kind: "codex",
                    name: "fixture",
                    workspaceID: "workspace-1"),
                worktree: WorktreeSpec(branch: "task/\(token)", base: .ref("main")),
                attempt: WorktreeLaunchAttempt())
        }

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        try #require(recorded.count == 4)
        // No label: herdr names the new worktree Workspace after its branch,
        // so the agent's name must appear only on the later tab.rename — a
        // label here rebranded the whole Workspace after the agent.
        #expect(
            recorded[0]
                == #"worktree.create {"base":"main","branch":"task/\#(token)","focus":false,"workspace_id":"workspace-1"}"#)
        #expect(
            recorded[1]
                == #"tab.rename {"label":"fixture","tab_id":"tab:\#(token)"}"#)
        #expect(
            recorded[2]
                == #"agent.start {"args":["--no-daemon"],"kind":"codex","name":"fixture","pane_id":"pane:\#(token)"}"#)
        #expect(recorded[3] == #"worktree.remove {"workspace_id":"workspace:\#(token)"}"#)
    }

    /// herdr 0.9.1 never fetches before `git worktree add`, so a Host whose
    /// checkout had fallen behind origin started every new worktree from
    /// stale code. Real git on the fixture Host: origin moves ahead of the
    /// source checkout, and the launch must branch from origin's new tip, as
    /// a SHA, having downloaded that commit without moving any ref the user
    /// or another agent holds: local `main`, HEAD, `origin/main`.
    @Test("a latest-main worktree agent start branches from origin's fetched tip")
    func latestMainWorktreeAgentStartBranchesFromTheFetchedOriginTip() async throws {
        try await exerciseLatestMainStartFromFetchedTip(.agent)
    }

    /// The New Terminal launch shares the resolution but not the create path.
    @Test("a latest-main worktree shell start branches from origin's fetched tip")
    func latestMainWorktreeShellStartBranchesFromTheFetchedOriginTip() async throws {
        try await exerciseLatestMainStartFromFetchedTip(.shell)
    }

    /// Origin's default branch is whatever its HEAD names, not `main`, and
    /// the checkout's own `origin/HEAD` is neither needed nor written: here
    /// it is deleted, and stays deleted.
    @Test("a latest-main start follows origin's HEAD to a non-main default branch")
    func latestMainStartFollowsOriginHEADToANonMainDefaultBranch() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let token = Self.scriptToken("ok")
        try await Self.withWorktreeSourceScratch(environment: environment, token: token) {
            host, root in
            // git >= 2.48 fetch recreates a missing origin/HEAD unless told not to.
            let (staleHead, originTip) = try await Self.seedStaleCheckout(
                defaultBranch: "trunk",
                afterClone: """
                    git -C "$c" remote set-head origin -d
                    git -C "$c" config remote.origin.followRemoteHEAD never
                    """,
                root: root, on: host)

            let transport = try await WaycarSSHTransport.connect(
                settings: environment.directSettings())
            defer { Task { try? await transport.close() } }
            try await Self.startLatestMainWorktree(.agent, token: token, on: transport)

            let recorded = try await Self.recordedRequests(from: transport, token: token)
            try #require(recorded.count == 4)
            #expect(
                recorded[1]
                    == #"worktree.create {"base":"\#(originTip)","branch":"task/\#(token)","focus":false,"workspace_id":"workspace:\#(token)"}"#)
            let after = try await Self.runGit(
                """
                git -C "$c" rev-parse refs/heads/trunk HEAD refs/remotes/origin/trunk
                git -C "$c" symbolic-ref --quiet refs/remotes/origin/HEAD || echo absent
                git -C "$c" cat-file -t \(originTip)
                """,
                root: root, on: host)
            #expect(after == [staleHead, staleHead, staleHead, "absent", "commit"])
        }
    }

    /// herdr ignores `base` for a branch that already exists, so asking
    /// origin would be a wasted round trip that can still fail the launch.
    /// This checkout has no origin at all: any network step would throw.
    @Test("a latest-main start of an existing branch sends no base and needs no origin")
    func latestMainStartOfAnExistingBranchSendsNoBase() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let token = Self.scriptToken("ok")
        try await Self.withWorktreeSourceScratch(environment: environment, token: token) {
            host, root in
            _ = try await Self.runGit(
                """
                git init --quiet --initial-branch=main "$c"
                git -C "$c" commit --quiet --allow-empty -m only
                git -C "$c" branch task/existing
                """,
                root: root, on: host)

            let transport = try await WaycarSSHTransport.connect(
                settings: environment.directSettings())
            defer { Task { try? await transport.close() } }
            try await Self.startLatestMainWorktree(
                .agent, token: token, branch: "task/existing", on: transport)

            let recorded = try await Self.recordedRequests(from: transport, token: token)
            try #require(recorded.count == 4)
            #expect(recorded[0] == #"worktree.list {"workspace_id":"workspace:\#(token)"}"#)
            #expect(
                recorded[1]
                    == #"worktree.create {"branch":"task/existing","focus":false,"workspace_id":"workspace:\#(token)"}"#)
        }
    }

    /// herdr refuses a linked worktree as the source checkout
    /// (`linked_worktree_source`). Saying so up front beats a fetch in the
    /// wrong checkout followed by herdr's refusal. The fixture's source
    /// checkout does not even exist, so any Host step would fail differently.
    @Test("a latest-main start from a linked worktree is refused before any Host work")
    func latestMainStartFromALinkedWorktreeIsRefused() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let token = Self.scriptToken("linkedsource")
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }
        await #expect(throws: WorktreeBaseResolutionError.linkedWorktreeSource) {
            try await Self.startLatestMainWorktree(.agent, token: token, on: transport)
        }
        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(recorded == [#"worktree.list {"workspace_id":"workspace:\#(token)"}"#])
    }

    /// A checkout whose origin cannot be fetched must stop the launch before
    /// `worktree.create`: falling back to the stale checkout is the bug.
    @Test("an unfetchable origin fails a latest-main start before anything is created")
    func unfetchableOriginFailsALatestMainStartBeforeCreating() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let token = Self.scriptToken("ok")
        try await Self.withWorktreeSourceScratch(environment: environment, token: token) {
            host, root in
            let head = try await Self.runGit(
                """
                git init --quiet --initial-branch=main "$c"
                git -C "$c" commit --quiet --allow-empty -m only
                git -C "$c" rev-parse HEAD
                """,
                root: root, on: host)
            try #require(head.count == 1)

            let transport = try await WaycarSSHTransport.connect(
                settings: environment.directSettings())
            defer { Task { try? await transport.close() } }
            let error = await #expect(throws: WorktreeBaseResolutionError.self) {
                try await Self.startLatestMainWorktree(.agent, token: token, on: transport)
            }
            guard case .fetchFailed(let detail) = error else {
                Issue.record("expected fetchFailed, got \(String(describing: error))")
                return
            }
            // git's own reason reaches the sheet.
            #expect(detail.contains("'origin' does not appear to be a git repository"))

            let recorded = try await Self.recordedRequests(from: transport, token: token)
            #expect(recorded == [#"worktree.list {"workspace_id":"workspace:\#(token)"}"#])
            #expect(
                try await Self.runGit(#"git -C "$c" rev-parse HEAD"#, root: root, on: host)
                    == head)
        }
    }

    /// `HostWatchdog` bounds the Host side of the worktree base resolution
    /// and of CodexBar: past its limit the command must end with 143 and
    /// take its children with it, or an abandoned exec keeps an SSH session
    /// (a `MaxSessions` slot) and a stray process alive on the user's Host.
    /// A foreground child (`sleep; exit 1`) and a backgrounded one (`sleep &
    /// wait`) are the two shapes git's ssh and remote helpers take.
    @Test("the Host watchdog stops an overrunning command and its children")
    func hostWatchdogStopsAnOverrunningCommandAndItsChildren() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let host = try await environment.hostConnection()
        do {
            for body in ["sleep %@; exit 1", "sleep %@ & wait"] {
                // A unique duration names this run's sleep, so the survivor
                // check cannot see any other process on the Host.
                let marker = "30.\(UInt32.random(in: 100_000_000...999_999_999))"
                let command = body.replacingOccurrences(of: "%@", with: marker)
                let started = ContinuousClock.now
                let result = try await host.execute(
                    "/bin/sh -c '\(HostWatchdog.definition); waycar_watch 1 sh -c \"\(command)\"'",
                    timeout: .sshdBudget(40))
                let elapsed = ContinuousClock.now - started
                #expect(result.reachedEOF)
                #expect(result.exitStatus == HostWatchdog.stoppedStatus, "\(command)")
                // A one-second limit against a thirty-second sleep: anything
                // near thirty means the watchdog never fired.
                #expect(elapsed < .seconds(15), "\(command) took \(elapsed)")
                // The bracket keeps pgrep from matching this check's own shell.
                // A signalled sleep can take a moment to be reaped; a survivor
                // would linger for the full thirty seconds.
                let survivor = try await host.execute(
                    "/bin/sh -c 'i=0; while pgrep -f \"[s]leep \(marker)\" >/dev/null; do "
                        + "[ $i -lt 20 ] || { pgrep -lf \"[s]leep \(marker)\"; exit 1; }; "
                        + "sleep 0.1; i=$((i+1)); done'",
                    timeout: .sshdBudget(10))
                #expect(
                    survivor.exitStatus == 0,
                    "\(command) left \(String(decoding: survivor.stdout, as: UTF8.self))")
            }
        } catch {
            try? await host.close(timeout: .sshdBudget(2))
            throw error
        }
        try await host.close(timeout: .sshdBudget(2))
    }

    /// `LaunchPromptWriter`'s script run for real by the Host's `/bin/sh`
    /// in a scratch directory, `$TMPDIR` set with a trailing slash: every
    /// file reads back byte-exact from the path it reported, the stage
    /// directory and a Codex home it had to create (one with a space in
    /// its path) are 0700 and the files 0600, and the next Codex profile
    /// write, through a Codex home that is a symlink, sweeps Waycar's
    /// `waycar-<uuid>` profiles older than ten minutes while keeping fresh
    /// ones, a user's own `waycar-review` and the user's other profiles.
    /// Where the Host has Python 3.11+, `tomllib` also reads the profile's
    /// `developer_instructions` back as the prompt itself.
    @Test("Launch Prompt Files are written byte-exact and private, and only stale Waycar Codex profiles are swept")
    func launchPromptFilesAreWrittenExactlyAndStaleProfilesSwept() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let host = try await environment.hostConnection()
        try await Self.withLaunchPromptScratch(on: host) { scratch in
            try await Self.exerciseLaunchPromptWriter(on: host, scratch: scratch)
        }
    }

    private static func exerciseLaunchPromptWriter(
        on host: SSHConnection, scratch: String
    ) async throws {
        let quotedScratch = try #require(RemoteShellPath.quotedAbsolute(scratch))

        /// One writer exec the way `HostSSHSession` runs it, by default
        /// under the scratch 0700 `$TMPDIR` spelled with a trailing slash.
        func write(
            _ files: [LaunchPromptFile], codexHome: String,
            environment: String = "TMPDIR=\(quotedScratch)/tmp/"
        ) async throws -> [StagedLaunchPromptFile] {
            let plan = try LaunchPromptWriter.plan(for: files, codexHome: codexHome)
            let result = try await host.execute(
                "\(environment) " + HostSSHSession.cLocaleCommand(plan.command),
                input: plan.input, timeout: .sshdBudget(20))
            try #require(
                result.exitStatus == 0 && result.reachedEOF,
                "writer: \(String(decoding: result.stderr, as: UTF8.self))")
            return try LaunchPromptWriter.stagedFiles(files, from: result.stdout)
        }

        func mode(of path: String) async throws -> String {
            let quoted = try #require(RemoteShellPath.quotedAbsolute(path))
            let result = try await host.execute(
                #"/bin/sh -c 'ls -ld "$1"' mode "# + quoted, timeout: .sshdBudget(10))
            return String(String(decoding: result.stdout, as: UTF8.self).prefix(10))
        }

        let chatPrompt = """
            You are in Chat Mode. Quote "this", keep 'that', never run $(rm -rf ~) or `id`.
            Back\\slash, tab\there, émoji 🚗, 漢字, and ''' and \"\"\" stay as typed.

            """
        let firstMessage = String(repeating: "Read the keychain notes line by line.\n", count: 150)
        let profilePrompt = chatPrompt + "Control \u{01}\u{1F}\u{7F} bytes\r\n end."
        let profileName = "waycar-\(UUID().uuidString.lowercased())"
        let codexHome = "\(scratch)/codex home"
        let files = [
            LaunchPromptFile(destination: .stageDirectory, name: "chat-prompt.md", contents: chatPrompt),
            LaunchPromptFile(
                destination: .stageDirectory, name: "first-message.md", contents: firstMessage),
            LaunchPromptFile(destination: .codexProfile, name: profileName, contents: profilePrompt),
        ]
        let staged = try await write(files, codexHome: codexHome)

        #expect(staged.map(\.file) == files)
        let stageDirectory = (staged[0].path as NSString).deletingLastPathComponent
        #expect(stageDirectory.hasPrefix("\(scratch)/tmp/waycar."))
        #expect(staged[0].path == "\(stageDirectory)/chat-prompt.md")
        #expect(staged[1].path == "\(stageDirectory)/first-message.md")
        #expect(staged[2].path == "\(codexHome)/\(profileName).config.toml")
        #expect(try await Self.hostBytes(at: staged[0].path, on: host) == Data(chatPrompt.utf8))
        #expect(try await Self.hostBytes(at: staged[1].path, on: host) == Data(firstMessage.utf8))
        #expect(
            try await Self.hostBytes(at: staged[2].path, on: host)
                == Data(CodexProfileTOML.render(developerInstructions: profilePrompt).utf8))
        #expect(try await mode(of: stageDirectory) == "drwx------")
        #expect(try await mode(of: codexHome) == "drwx------")
        for file in staged {
            #expect(try await mode(of: file.path) == "-rw-------", "\(file.path)")
        }

        let quotedProfile = try #require(RemoteShellPath.quotedAbsolute(staged[2].path))
        let parsed = try await host.execute(
            "/bin/sh -c 'command -v python3 >/dev/null 2>&1 || exit 3; "
                + #"python3 -c "import tomllib" 2>/dev/null || exit 3; "#
                + #"exec python3 -c "import sys, tomllib; "#
                + #"sys.stdout.buffer.write(tomllib.load(open(sys.argv[1], \"rb\"))"#
                + #"[\"developer_instructions\"].encode())" "$1"' toml "# + quotedProfile,
            timeout: .sshdBudget(10))
        if parsed.exitStatus != 3 {
            #expect(parsed.exitStatus == 0, "\(String(decoding: parsed.stderr, as: UTF8.self))")
            #expect(parsed.stdout == Data(profilePrompt.utf8))
        }

        // Through a symlinked Codex home: an hour-old Waycar profile goes; a
        // fresh one, the user's own old `waycar-review` and other profiles
        // stay.
        let staleName = "waycar-\(UUID().uuidString.lowercased())"
        let freshName = "waycar-\(UUID().uuidString.lowercased())"
        let planted = try await Self.hostScript(
            #"mkdir "$1/codex-real" && ln -s "$1/codex-real" "$1/codex-link" && "#
                + #"cd "$1/codex-real" && "#
                + "touch -t 200001010000 \(staleName).config.toml waycar-review.config.toml "
                + "mine.config.toml && touch \(freshName).config.toml",
            scratch: scratch, on: host)
        try #require(planted.exitStatus == 0)
        let nextName = "waycar-\(UUID().uuidString.lowercased())"
        let swept = try await write(
            [LaunchPromptFile(destination: .codexProfile, name: nextName, contents: "Next.")],
            codexHome: "\(scratch)/codex-link")
        #expect(swept.map(\.path) == ["\(scratch)/codex-link/\(nextName).config.toml"])
        let listing = try await Self.hostScript(
            #"cd "$1/codex-real" && ls"#, scratch: scratch, on: host)
        let remaining = Set(
            String(decoding: listing.stdout, as: UTF8.self).split(separator: "\n").map(String.init))
        #expect(
            remaining == [
                "mine.config.toml", "waycar-review.config.toml",
                "\(freshName).config.toml", "\(nextName).config.toml",
            ])

        // A `$TMPDIR` other users can enter is passed over: a plain
        // absolute `$XDG_RUNTIME_DIR` takes the stage directory, and
        // without one `$HOME/.cache/waycar/launch-prompts`, made 0700.
        let opened = try await Self.hostScript(
            #"mkdir -m 755 "$1/open" && mkdir -m 700 "$1/xdg" && mkdir "$1/home""#,
            scratch: scratch, on: host)
        try #require(opened.exitStatus == 0)
        let stageFile = [
            LaunchPromptFile(destination: .stageDirectory, name: "chat-prompt.md", contents: "Hi.")
        ]
        let viaXDG = try await write(
            stageFile, codexHome: codexHome,
            environment: "TMPDIR=\(quotedScratch)/open XDG_RUNTIME_DIR=\(quotedScratch)/xdg/")
        #expect(viaXDG.first?.path.hasPrefix("\(scratch)/xdg/waycar.") == true)
        let viaHome = try await write(
            stageFile, codexHome: codexHome,
            environment: "TMPDIR=\(quotedScratch)/open XDG_RUNTIME_DIR= HOME=\(quotedScratch)/home")
        let cache = "\(scratch)/home/.cache/waycar/launch-prompts"
        #expect(viaHome.first?.path.hasPrefix("\(cache)/waycar.") == true)
        #expect(try await mode(of: cache) == "drwx------")
        #expect(try await Self.hostBytes(at: viaHome[0].path, on: host) == Data("Hi.".utf8))
    }

    /// The live Transport stages a Chat Mode launch's files in one exec
    /// under the Host session's own `$TMPDIR`: each comes back as an
    /// absolute, plain path in one fresh `waycar.*` directory, so it can
    /// ride the typed launch line, and reads back byte-exact.
    @Test("the Transport stages Launch Prompt Files at plain paths the launch line can carry")
    func transportStagesLaunchPromptFilesAtPlainPaths() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(settings: environment.directSettings())
        defer { Task { try? await transport.close() } }
        let host = try await environment.hostConnection()
        let files = [
            LaunchPromptFile(
                destination: .stageDirectory, name: LaunchPromptStager.chatPromptFileName,
                contents: ChatModePrompt.defaultText),
            LaunchPromptFile(
                destination: .stageDirectory, name: LaunchPromptStager.initialPromptFileName,
                contents: Self.keychainSizedMessage),
        ]
        try await Self.removingStageDirectories(on: host) { stageDirectories in
            let staged = try await transport.stageLaunchPromptFiles(files)
            let directories = Set(staged.map { ($0.path as NSString).deletingLastPathComponent })
            stageDirectories.formUnion(directories)

            #expect(staged.map(\.file) == files)
            #expect(staged.allSatisfy { LaunchPromptWriter.isPlainAbsolutePath($0.path) })
            #expect(directories.count == 1)
            let directory = try #require(directories.first)
            #expect((directory as NSString).lastPathComponent.hasPrefix("waycar."))
            #expect(staged.map(\.path) == files.map { "\(directory)/\($0.name)" })
            for file in staged {
                #expect(
                    try await Self.hostBytes(at: file.path, on: host) == Data(file.file.contents.utf8))
            }
        }
    }

    /// The capability probe through a live Transport, against stub `claude`
    /// and `codex` scripts first on its PATH. The Host's own CLIs could sit
    /// on the probe's appended install prefixes, so a missing CLI is a stub
    /// exiting 127 the way `sh` reports one. Help that names the file
    /// routes, wrapped across lines, reads as both routes; older help and
    /// missing CLIs read as neither. The probe runs once per connection,
    /// and its Codex home is the one the pane's interactive shell sets (via
    /// `$ENV`), not the exec's: a Codex profile staged afterwards lands
    /// there. A `--help` that hangs past the watchdog fails the probe within
    /// its limit, and the failure is not cached.
    @Test("the Launch Prompt capability probe reads wrapped help once per connection and caches no failure")
    func launchPromptCapabilityProbeReadsTheHostsCLIs() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let host = try await environment.hostConnection()
        try await Self.withLaunchPromptScratch(on: host) { scratch in
            try await Self.exerciseLaunchPromptCapabilityProbe(
                environment: environment, host: host, scratch: scratch)
        }
    }

    private static func exerciseLaunchPromptCapabilityProbe(
        environment: WaycarSSHTransportBehaviorEnvironment, host: SSHConnection, scratch: String
    ) async throws {
        let quotedScratch = try #require(RemoteShellPath.quotedAbsolute(scratch))
        let made = try await hostScript(
            #"mkdir "$1/good" "$1/old" "$1/missing" "$1/slow""#, scratch: scratch, on: host)
        try #require(made.exitStatus == 0)
        let count = "\(scratch)/count"
        let goodClaude = """
            #!/bin/sh
            echo claude >> "\(count)"
            echo "Usage: claude [options]"
            echo "  --append-system-prompt <prompt>    Append a system prompt to the default"
            echo "                                     --append-system-prompt[-file], --add-dir"

            """
        let goodCodex = """
            #!/bin/sh
            echo codex >> "\(count)"
            echo "  -p, --profile <CONFIG_PROFILE_V2>"
            echo "          Layer \\$CODEX_HOME/<name>.config.toml on top of the"
            echo "          base user config"

            """
        let stubs: [(String, String)] = [
            ("good/claude", goodClaude), ("good/codex", goodCodex),
            ("old/claude", "#!/bin/sh\necho \"  --append-system-prompt <prompt>  Append\"\n"),
            ("old/codex", "#!/bin/sh\necho \"  -p, --profile <CONFIG_PROFILE>  Configuration profile\"\n"),
            ("missing/claude", "#!/bin/sh\nexit 127\n"), ("missing/codex", "#!/bin/sh\nexit 127\n"),
            ("slow/claude", "#!/bin/sh\nexec sleep 30\n"), ("slow/codex", goodCodex),
        ]
        for (path, body) in stubs {
            try await installHostScript(body, at: "\(scratch)/\(path)", on: host)
        }
        let paneCodexHome = "\(scratch)/pane codex"
        try await installHostScript(
            "export CODEX_HOME=\"\(paneCodexHome)\"\n", at: "\(scratch)/rc.sh", on: host)
        try await installHostScript(
            "#!/bin/sh\ntrap \"\" TERM\nsleep 60\n", at: "\(scratch)/stuck-shell", on: host)

        /// A Transport whose probe finds the stubs in `directory` first, in
        /// a pane shell (`/bin/sh`, reading `rc.sh` as `$ENV`, unless
        /// `shell` replaces it) that sets another `CODEX_HOME` than the
        /// exec's.
        func transport(
            stubs directory: String, shell: String = "/bin/sh"
        ) async throws -> WaycarSSHTransport {
            var settings = environment.directSettings()
            settings.launchPromptProbeCommand =
                "PATH=\(quotedScratch)/\(directory):$PATH SHELL=\(shell) ENV=\(quotedScratch)/rc.sh "
                + "CODEX_HOME=\(quotedScratch)/exec-codex "
                + LaunchPromptWriter.capabilityProbeCommand
            return try await WaycarSSHTransport.connect(settings: settings)
        }

        func probeRuns() async throws -> [String] {
            let result = try await hostScript(#"cat "$1/count""#, scratch: scratch, on: host)
            return String(decoding: result.stdout, as: UTF8.self)
                .split(separator: "\n").map(String.init)
        }

        let both = LaunchPromptCapabilities(claudeAppendSystemPromptFile: true, codexProfileFile: true)
        let good = try await transport(stubs: "good")
        defer { Task { try? await good.close() } }
        #expect(await good.launchPromptCapabilities() == both)
        #expect(await good.launchPromptCapabilities() == both)
        let profileName = "waycar-\(UUID().uuidString.lowercased())"
        let profile = try await good.stageLaunchPromptFiles([
            LaunchPromptFile(destination: .codexProfile, name: profileName, contents: "Be brief.")
        ])
        #expect(profile.map(\.path) == ["\(paneCodexHome)/\(profileName).config.toml"])
        #expect(try await probeRuns() == ["claude", "codex"])

        let again = try await transport(stubs: "good")
        defer { Task { try? await again.close() } }
        #expect(await again.launchPromptCapabilities() == both)
        #expect(try await probeRuns() == ["claude", "codex", "claude", "codex"])

        for directory in ["old", "missing"] {
            let other = try await transport(stubs: directory)
            defer { Task { try? await other.close() } }
            #expect(
                await other.launchPromptCapabilities() == LaunchPromptCapabilities.none, "\(directory)")
        }

        let slow = try await transport(stubs: "slow")
        defer { Task { try? await slow.close() } }
        let started = ContinuousClock.now
        #expect(await slow.launchPromptCapabilities() == LaunchPromptCapabilities.none)
        #expect(started.duration(to: .now) < .seconds(15))
        try await installHostScript(goodClaude, at: "\(scratch)/slow/claude", on: host)
        #expect(await slow.launchPromptCapabilities() == both)

        // A pane shell that ignores SIGTERM and never finishes starting is
        // killed at its limit; the probe falls back to the exec's Codex home.
        let stuck = try await transport(stubs: "good", shell: "\(quotedScratch)/stuck-shell")
        defer { Task { try? await stuck.close() } }
        let stuckStarted = ContinuousClock.now
        #expect(await stuck.launchPromptCapabilities() == both)
        #expect(stuckStarted.duration(to: .now) < .seconds(9))
        let fallbackName = "waycar-\(UUID().uuidString.lowercased())"
        let fallback = try await stuck.stageLaunchPromptFiles([
            LaunchPromptFile(destination: .codexProfile, name: fallbackName, contents: "Be brief.")
        ])
        #expect(fallback.map(\.path) == ["\(scratch)/exec-codex/\(fallbackName).config.toml"])
    }

    /// A Chat Mode claude launch end to end: the planner reads the Host's
    /// file route, the live Transport stages the Chat Prompt and a
    /// Keychain-Fix-sized first message, and `agent.start` carries exactly
    /// the planned arguments. The line herdr would type stays under the
    /// tty's `MAX_CANON` budget, and the files it points at hold the
    /// prompts.
    @Test("a staged Chat Mode launch types a short line that points at its staged prompts")
    func stagedChatModeLaunchTypesAShortLine() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.settingsWithoutLaunchSettle(environment))
        defer { Task { try? await transport.close() } }
        let host = try await environment.hostConnection()
        try await Self.removingStageDirectories(on: host) { stageDirectories in
            let promptHost = LaunchPromptHost(
                capabilities: {
                    LaunchPromptCapabilities(claudeAppendSystemPromptFile: true, codexProfileFile: false)
                },
                stage: { try await transport.stageLaunchPromptFiles($0) },
                homeDirectory: { try await transport.remoteHomeDirectory() })
            let arguments = try await LaunchPromptStager.launchCommand(
                kind: .claude, chatOptions: ChatModeLaunchOptions(prompt: ChatModePrompt.defaultText),
                sessionPin: UUID(), userArguments: [], initialPrompt: Self.keychainSizedMessage,
                host: promptHost, hostName: "Fixture"
            ).arguments
            let flag = try #require(arguments.firstIndex(of: "--append-system-prompt-file"))
            try #require(flag + 1 < arguments.count)
            let chatPath = arguments[flag + 1]
            let pointer = try #require(arguments.last)
            let lead = "Read and follow "
            try #require(pointer.hasPrefix(lead))
            let firstPath = String(pointer.dropFirst(lead.count))
            stageDirectories.formUnion(
                [chatPath, firstPath].map { ($0 as NSString).deletingLastPathComponent })

            let token = Self.scriptToken("ok")
            _ = try await transport.startAgent(
                AgentLaunchRequest(
                    kind: "claude", name: "fixture", arguments: arguments,
                    workspaceID: "workspace-1", cwd: "/fixture/\(token)"))

            let recorded = try await Self.recordedRequests(from: transport, token: token)
            let start = try #require(recorded.first { $0.hasPrefix("agent.start ") })
            let params = try JSONDecoder().decode(
                RecordedAgentStart.self, from: Data(start.dropFirst("agent.start ".count).utf8))
            #expect(params.args == arguments)
            #expect(
                LaunchPromptStager.typedLineBytes(executable: "claude", arguments: arguments)
                    <= LaunchPromptStager.typedLineBudget)
            #expect(
                try await Self.hostBytes(at: chatPath, on: host) == Data(ChatModePrompt.defaultText.utf8))
            #expect(
                try await Self.hostBytes(at: firstPath, on: host) == Data(Self.keychainSizedMessage.utf8))
        }
    }

    /// The arguments of a recorded `agent.start`.
    private struct RecordedAgentStart: Decodable {
        let args: [String]?
    }

    /// About the size of the Keychain Fix's first user message (~3.5 KB).
    private static let keychainSizedMessage = String(
        repeating: "Read the keychain notes line by line, then fix the entry.\n", count: 60)

    /// Runs `body` with a fresh scratch directory on the fixture Host
    /// (holding an empty `tmp`), then removes it and closes `host`.
    /// Cancelled when the Host's temporary directory is not plain.
    private static func withLaunchPromptScratch(
        on host: SSHConnection, _ body: (String) async throws -> Void
    ) async throws {
        let outcome: Result<Void, any Error>
        var scratch: String?
        do {
            let preflight = try await host.execute(
                #"/bin/sh -c 'd=$(mktemp -d) && mkdir -m 700 "$d/tmp" && printf "%s\n" "$d"'"#,
                timeout: .sshdBudget(10))
            try #require(preflight.exitStatus == 0 && preflight.reachedEOF)
            let directory = String(decoding: preflight.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            scratch = directory
            guard LaunchPromptWriter.isPlainAbsolutePath(directory) else {
                try Test.cancel("the fixture Host's temporary directory \(directory) is not plain")
            }
            try await body(directory)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        if let scratch, let quoted = RemoteShellPath.quotedAbsolute(scratch) {
            _ = try? await host.execute(
                #"/bin/sh -c 'rm -rf "$1"' cleanup "# + quoted, timeout: .sshdBudget(10))
        }
        try? await host.close(timeout: .sshdBudget(2))
        try outcome.get()
    }

    /// Runs `body`, then removes every stage directory it recorded and
    /// closes `host`.
    private static func removingStageDirectories(
        on host: SSHConnection, _ body: (inout Set<String>) async throws -> Void
    ) async throws {
        var directories: Set<String> = []
        let outcome: Result<Void, any Error>
        do {
            try await body(&directories)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        for directory in directories where directory.contains("/waycar.") {
            if let quoted = RemoteShellPath.quotedAbsolute(directory) {
                _ = try? await host.execute(
                    #"/bin/sh -c 'rm -rf "$1"' cleanup "# + quoted, timeout: .sshdBudget(10))
            }
        }
        try? await host.close(timeout: .sshdBudget(2))
        try outcome.get()
    }

    /// Runs `script` under `/bin/sh` with `scratch` as `$1`.
    private static func hostScript(
        _ script: String, scratch: String, on host: SSHConnection
    ) async throws -> SSHExecResult {
        precondition(!script.contains("'"), "the Host script is single-quoted")
        let quoted = try #require(RemoteShellPath.quotedAbsolute(scratch))
        return try await host.execute(
            "/bin/sh -c '\(script)' launch-prompt-e2e \(quoted)", timeout: .sshdBudget(10))
    }

    /// Writes `body` to the Host file at `path`, executable.
    private static func installHostScript(
        _ body: String, at path: String, on host: SSHConnection
    ) async throws {
        let quoted = try #require(RemoteShellPath.quotedAbsolute(path))
        let result = try await host.execute(
            #"/bin/sh -c 'cat > "$1" && chmod 755 "$1"' install "# + quoted,
            input: Data(body.utf8), timeout: .sshdBudget(10))
        try #require(result.exitStatus == 0, "\(path) was not written")
    }

    private static func hostBytes(at path: String, on host: SSHConnection) async throws -> Data {
        let quoted = try #require(RemoteShellPath.quotedAbsolute(path))
        let result = try await host.execute(
            #"/bin/sh -c 'cat "$1"' read "# + quoted, timeout: .sshdBudget(10))
        try #require(result.exitStatus == 0, "\(path) is unreadable")
        return result.stdout
    }

    /// Executes the generated POSIX command on the fixture Host. A local
    /// static HTTP server that can answer late stands in for `codexbar
    /// serve`; a flag-aware CLI
    /// serves independent base and all-account payloads. Covers both account
    /// recovery after server failure and preserving the working report when
    /// an old CLI rejects --all-accounts or one account fails.
    @Test("the CodexBar usage command asks a local codexbar serve first and falls back to the CLI")
    func codexBarUsageAsksTheLocalServerThenFallsBackToTheCLI() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let host = try await environment.hostConnection()
        let outcome: Result<Void, any Error>
        do {
            try await Self.exerciseCodexBarServeFallback(on: host)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        try? await host.close(timeout: .sshdBudget(2))
        try outcome.get()
    }

    private static func exerciseCodexBarServeFallback(on host: SSHConnection) async throws {
        // A free loopback port, so a real `codexbar serve` on the Host's
        // own port cannot answer in the stand-in's place.
        let preflight = try await host.execute(
            "/bin/sh -c '"
                + "command -v python3 >/dev/null 2>&1 || exit 3; "
                + "command -v curl >/dev/null 2>&1 || exit 4; "
                + #"python3 -c "import socket; s = socket.socket(); s.bind((\"127.0.0.1\", 0)); "#
                + #"print(s.getsockname()[1])" || exit 5; "#
                + #"d=$(mktemp -d) && mkdir "$d/srv" && printf "%s\n" "$d"'"#,
            timeout: .sshdBudget(10))
        switch preflight.exitStatus {
        case 0: break
        case 3: try Test.cancel("the fixture Host has no python3 to stand in for codexbar serve")
        case 4: try Test.cancel("the fixture Host has no curl, so the usage command never asks a server")
        default:
            Issue.record("preflight failed: \(String(decoding: preflight.stderr, as: UTF8.self))")
            return
        }
        let lines = String(decoding: preflight.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        try #require(lines.count == 2, "preflight output: \(lines)")
        let port = try #require(Int(lines[0]), "free port: \(lines[0])")
        let directory = lines[1]
        let quotedDirectory = try #require(RemoteShellPath.quotedAbsolute(directory))

        /// Runs `script` with the scratch directory as `$1` and `input` on
        /// stdin; fails the test unless it exits 0. No single quotes.
        func run(_ script: String, input: String = "") async throws {
            precondition(!script.contains("'"), "the Host script is single-quoted")
            let result = try await host.execute(
                "/bin/sh -c '\(script)' codexbar-serve-e2e \(quotedDirectory)",
                input: Data(input.utf8), timeout: .sshdBudget(20))
            try #require(
                result.reachedEOF && result.exitStatus == 0,
                "\(script): \(String(decoding: result.stderr, as: UTF8.self))")
        }

        let usageCommand = try CodexBarCommand.usageCommand(
            executablePath: "\(directory)/codex bar", port: port)

        /// One usage run: its output decoded, and whether the CLI ran.
        func usage(_ label: String, expectedExitStatus: Int32 = 0) async throws
            -> (report: AIUsageReport, stdout: String, cliRan: Bool)
        {
            try await run(#"rm -f "$1/cli-ran""#)
            let result = try await host.execute(usageCommand, timeout: .sshdBudget(60))
            #expect(result.reachedEOF, "\(label)")
            #expect(
                result.exitStatus == expectedExitStatus,
                "\(label): \(String(decoding: result.stderr, as: UTF8.self))")
            let check = try await host.execute(
                "/bin/sh -c '[ -e \"$1/cli-ran\" ]' cli-ran \(quotedDirectory)",
                timeout: .sshdBudget(10))
            let report = try AIUsageReport.decode(result.stdout)
            return (report, String(decoding: result.stdout, as: UTF8.self), check.exitStatus == 0)
        }

        let outcome: Result<Void, any Error>
        do {
            try await run(
                #"cat > "$1/codex bar" && chmod +x "$1/codex bar""#,
                input: """
                    #!/bin/sh
                    d=${0%/*}
                    touch "$d/cli-ran"
                    all=0
                    provider=
                    while [ "$#" -gt 0 ]; do
                      case "$1" in
                        usage) ;;
                        --all-accounts) all=1 ;;
                        --provider) shift; provider=$1 ;;
                        --format) shift; [ "$1" = json ] || exit 64 ;;
                        --web-timeout) shift ;;
                        *) exit 64 ;;
                      esac
                      shift
                    done
                    if [ "$all" = 1 ]; then
                      [ "$provider" = codex ] || exit 64
                      if [ -e "$d/legacy" ]; then
                        printf '%s\\n' '[{"provider":"cli","error":{"message":"Unknown option --all-accounts"}}]'
                        exit 64
                      fi
                      cat "$d/accounts.json"
                      exit "$(cat "$d/accounts-status")"
                    fi
                    [ -z "$provider" ] || exit 64
                    cat "$d/base.json"
                    exit "$(cat "$d/base-status")"

                    """)
            let cliError = #"[{"provider":"codex","error":{"message":"from the CLI"}}]"#
            try await run(#"cat > "$1/base.json""#, input: cliError)
            try await run(#"cat > "$1/accounts.json""#, input: cliError)
            try await run(#"printf 0 > "$1/base-status"; printf 0 > "$1/accounts-status""#)

            // (a) Nothing listens: the CLI answers, saying whether it ran
            // on a Mac.
            let none = try await usage("no server")
            #expect(!none.stdout.contains(CodexBarCommand.serverSourceMarker))
            #expect(none.cliRan, "no server")
            #expect(none.report.source == .cli)
            #expect(none.report.providers.map(\.providerID) == ["codex"])
            let uname = try await host.execute("/bin/sh -c 'uname -s'", timeout: .sshdBudget(10))
            let isMac = String(decoding: uname.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "Darwin"
            #expect(none.report.isMacOSHost == isMac)

            let base = #"""
                [{"provider":"codex","account":"Work","cacheAccountKey":"fake-work","usage":{"primary":{"usedPercent":20}}},{"provider":"claude","usage":{"primary":{"usedPercent":35}}},{"provider":"gemini","error":{"message":"signed out"}}]
                """#
            let accounts = #"""
                [{"provider":"codex","account":"Work","cacheAccountKey":"fake-work","usage":{"primary":{"usedPercent":10}}},{"provider":"codex","account":"Personal","cacheAccountKey":"fake-personal","usage":{"primary":{"usedPercent":70}}}]
                """#
            try await run(#"cat > "$1/base.json""#, input: base)
            try await run(#"cat > "$1/accounts.json""#, input: accounts)
            try await run(#"printf 1 > "$1/base-status""#)
            let recovered = try await usage("all accounts after server failure", expectedExitStatus: 1)
            let codex = recovered.report.providers.filter { $0.providerID == "codex" }
            #expect(codex.count == 2)
            #expect(Set(codex.map(\.id)).count == 2)
            #expect(codex.first { $0.account == "Work" }?.windows.first?.usedPercent == 10)
            #expect(codex.first { $0.account == "Personal" }?.windows.first?.usedPercent == 70)
            #expect(recovered.report.providers.first { $0.providerID == "claude" }?.windows.first?.usedPercent == 35)
            #expect(recovered.report.providers.first { $0.providerID == "gemini" }?.errorMessage == "signed out")
            #expect(recovered.report.commandError == nil)

            try await run(
                #"cat > "$1/accounts.json""#,
                input: #"""
                    [{"provider":"codex","account":"Work","cacheAccountKey":"fake-work","error":{"message":"The request timed out."}},{"provider":"codex","account":"Personal","cacheAccountKey":"fake-personal","usage":{"primary":{"usedPercent":70}}}]
                    """#)
            try await run(#"printf 1 > "$1/accounts-status""#)
            let partial = try await usage("one account fails", expectedExitStatus: 1)
            let work = try #require(partial.report.providers.first { $0.account == "Work" })
            #expect(work.windows.first?.usedPercent == 20)
            #expect(work.errorMessage == nil)
            #expect(partial.report.providers.first { $0.account == "Personal" }?.windows.first?.usedPercent == 70)
            #expect(partial.report.commandError == nil)

            try await run(#"touch "$1/legacy""#)
            let legacy = try await usage("legacy CLI rejects all-accounts", expectedExitStatus: 1)
            #expect(legacy.report.providers == (try AIUsageReport.decode(Data(base.utf8))).providers)
            #expect(legacy.report.commandError == nil)

            // Even a supplemental inventory must not bring back a provider
            // the user disabled in CodexBar.
            let disabled = #"[{"provider":"claude","usage":{"primary":{"usedPercent":35}}}]"#
            try await run(#"cat > "$1/base.json""#, input: disabled)
            try await run(#"cat > "$1/accounts.json""#, input: accounts)
            try await run(
                #"rm "$1/legacy"; printf 0 > "$1/accounts-status"; printf 0 > "$1/base-status""#)
            let withoutCodex = try await usage("Codex disabled")
            #expect(withoutCodex.report.providers.map(\.providerID) == ["claude"])
            #expect(withoutCodex.report.providers.first?.windows.first?.usedPercent == 35)

            try await run(#"cat > "$1/base.json""#, input: cliError)
            try await run(#"cat > "$1/accounts.json""#, input: cliError)

            try await run(#"printf ok > "$1/srv/health""#)
            try await run(
                #"cat > "$1/srv/usage""#,
                input: "\n  [{\"provider\":\"claude\",\"error\":{\"message\":\"from the server\"}}]\n")
            // Serves `srv/<name>`, after `srv/<name>.delay` seconds when that
            // file exists, like a `codexbar serve` still fetching.
            try await run(
                #"cat > "$1/serve.py""#,
                input: """
                    import http.server, pathlib, sys, time
                    root = pathlib.Path(sys.argv[2])
                    class Handler(http.server.BaseHTTPRequestHandler):
                        def do_GET(self):
                            name = self.path.lstrip("/")
                            delay = root / (name + ".delay")
                            if delay.is_file():
                                time.sleep(float(delay.read_text()))
                            path = root / name
                            if not path.is_file():
                                self.send_error(404)
                                return
                            body = path.read_bytes()
                            self.send_response(200)
                            self.send_header("Content-Length", str(len(body)))
                            self.end_headers()
                            self.wfile.write(body)
                        def log_message(self, *args):
                            pass
                    server = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
                    server.serve_forever()

                    """)
            try await run(
                "python3 \"$1/serve.py\" \(port) \"$1/srv\" "
                    + #">"$1/server.log" 2>&1 </dev/null & printf "%s" "$!" > "$1/server.pid"; "#
                    + "i=0; until curl -s -o /dev/null http://127.0.0.1:\(port)/health; do "
                    + #"[ $i -lt 50 ] || { cat "$1/server.log" >&2; exit 1; }; "#
                    + "sleep 0.2; i=$((i+1)); done")

            // (b) A healthy server's array, even after leading whitespace,
            // is the report and the CLI never runs.
            let served = try await usage("server array")
            #expect(served.stdout.contains(CodexBarCommand.serverSourceMarker))
            #expect(!served.stdout.contains(CodexBarCommand.macOSHostMarker))
            #expect(!served.cliRan, "a server answer must not also run the CLI")
            #expect(served.report.source == .server)
            #expect(served.report.providers.map(\.providerID) == ["claude"])

            // (b2) A server still fetching a slow provider answers late; the
            // old 10-second wait ran the CLI instead, which cannot read
            // Claude over SSH.
            try await run(#"printf 12 > "$1/srv/usage.delay""#)
            let slow = try await usage("slow server array")
            #expect(slow.stdout.contains(CodexBarCommand.serverSourceMarker))
            #expect(!slow.cliRan, "a slow server answer must not also run the CLI")
            #expect(slow.report.source == .server)
            #expect(slow.report.providers.map(\.providerID) == ["claude"])
            try await run(#"rm "$1/srv/usage.delay""#)

            // (c) A body that is not an array is no answer.
            try await run(
                #"cat > "$1/srv/usage""#,
                input: "{\"provider\":\"claude\",\"error\":{\"message\":\"from the server\"}}\n")
            let object = try await usage("server object")
            #expect(!object.stdout.contains(CodexBarCommand.serverSourceMarker))
            #expect(object.cliRan, "server object")
            #expect(object.report.source == .cli)
            #expect(object.report.providers.map(\.providerID) == ["codex"])

            // (d) Healthy, but `/usage` fails (404).
            try await run(#"rm "$1/srv/usage""#)
            let missing = try await usage("usage 404")
            #expect(!missing.stdout.contains(CodexBarCommand.serverSourceMarker))
            #expect(missing.cliRan, "usage 404")
            #expect(missing.report.source == .cli)
            #expect(missing.report.providers.map(\.providerID) == ["codex"])
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        let cleanup = try? await host.execute(
            #"/bin/sh -c '[ -f "$1/server.pid" ] && kill "$(cat "$1/server.pid")"; rm -rf "$1"' "#
                + "cleanup \(quotedDirectory)",
            timeout: .sshdBudget(10))
        try outcome.get()
        #expect(cleanup?.exitStatus == 0, "scratch \(directory) was not removed")
    }

    /// herdr answers `worktree.create` only after `git worktree add`, which
    /// on a large repository outlives the request budget while the worktree
    /// is made anyway. Found on the branch this launch minted, it is the
    /// launch's own: the Agent starts in its root pane (after checking no
    /// Agent already runs there), and no second `worktree.create` is sent.
    @Test("an unanswered worktree create is found and started in, never sent twice")
    func unansweredWorktreeCreateIsFoundNotSentTwice() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.worktreeLaunchSettings(environment))
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("createhangs")
        let wire = WorktreeLaunchWire(token: token)

        let launch = try await Self.launchWorktreeAgent(
            on: transport, token: token, branchIsGenerated: true)

        let agent = try launch.result.get()
        #expect(agent.paneID == "pane:\(token)")
        #expect(agent.workspaceID == "workspace:\(token)")
        #expect(
            launch.recorded == [
                wire.list, wire.create, wire.list, wire.snapshot, wire.rename,
                wire.agentList, wire.rootAgentStart,
            ])
        #expect(launch.steps == [.creatingWorktree, .checkingForCreatedWorktree, .startingAgent])
    }

    /// After a link failure the Console replays the launch with the same
    /// attempt. The lost try's `worktree.create` reached herdr, so the replay
    /// looks for the worktree it made, before any latest-main fetch, and
    /// continues there instead of creating again.
    @Test("a replayed worktree launch continues in its lost try's worktree without fetching")
    func replayedWorktreeLaunchContinuesInTheLostTrysWorktree() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.worktreeLaunchSettings(environment))
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("lostcreate")
        let wire = WorktreeLaunchWire(token: token)
        let attempt = WorktreeLaunchAttempt()
        attempt.recordCreateDispatched()

        // The fixture's source checkout does not exist: a fetch would fail.
        let launch = try await Self.launchWorktreeAgent(
            on: transport, token: token, branchIsGenerated: true,
            base: .latestDefaultBranch, attempt: attempt)

        #expect(try launch.result.get().paneID == "pane:\(token)")
        #expect(
            launch.recorded == [
                wire.list, wire.snapshot, wire.rename, wire.agentList, wire.rootAgentStart,
            ])
        #expect(launch.steps == [.checkingForCreatedWorktree, .startingAgent])
    }

    @Test("a tagged retry returns its earlier Agent without creating or joining")
    func taggedRetryReturnsEarlierAgent() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.worktreeLaunchSettings(environment))
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("rootagent")
        _ = try await transport.listWorktrees(forWorkspaceID: "source:\(token)")
        let steps = LaunchStepLog()
        let agent = try await steps.recording {
            try await transport.startAgent(AgentLaunchRequest(
                kind: "codex", name: "Fixture", workspaceID: "workspace:\(token)",
                launchID: UUID(), mayHaveStarted: true))
        }
        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(agent.paneID == "pane:\(token)")
        #expect(!recorded.contains { $0.hasPrefix("tab.create ") || $0.hasPrefix("agent.start ") })
        #expect(!steps.all.contains(.joiningRunningAgent))
    }

    @Test("a tagged tab with a kind-less pending Agent is returned without starting again")
    func taggedPendingAgentBeforeKindDetectionIsReturned() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.worktreeLaunchSettings(environment))
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("pendingagent")
        _ = try await transport.listWorktrees(forWorkspaceID: "source:\(token)")
        let agent = try await transport.startAgent(AgentLaunchRequest(
            kind: "opencode", name: "Fixture", workspaceID: "workspace:\(token)",
            launchID: UUID(), mayHaveStarted: true))
        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(agent.paneID == "pane:\(token)")
        #expect(agent.kind == Agent.unidentifiedKind)
        #expect(!recorded.contains { $0.hasPrefix("agent.start ") || $0.hasPrefix("tab.create ") })
    }

    @Test("a tagged tab without an Agent resumes the start in its own pane")
    func taggedOrphanTabStartsInItsPane() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.worktreeLaunchSettings(environment))
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("lostcreate")
        _ = try await transport.listWorktrees(forWorkspaceID: "source:\(token)")
        let agent = try await transport.startAgent(AgentLaunchRequest(
            kind: "codex", name: "Fixture", workspaceID: "workspace:\(token)",
            launchID: UUID(), mayHaveStarted: true))
        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(agent.paneID == "pane:\(token)")
        #expect(!recorded.contains { $0.hasPrefix("tab.create ") })
        #expect(recorded.contains {
            $0 == #"agent.start {"args":["--no-daemon"],"kind":"codex","name":"Fixture","pane_id":"pane:\#(token)"}"#
        })
    }

    /// A replay whose earlier try already dispatched `agent.start` in its own
    /// worktree finds that Agent in the root pane and returns it: a second
    /// `agent.start` would be refused, or start a second Agent.
    @Test("a replay after a dispatched agent start returns the Agent already running")
    func replayAfterADispatchedAgentStartReturnsTheRunningAgent() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.worktreeLaunchSettings(environment))
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("rootagent")
        let wire = WorktreeLaunchWire(token: token)
        let attempt = WorktreeLaunchAttempt()
        attempt.recordCreateDispatched()
        attempt.recordWorktree(
            WorktreeLaunchAttempt.Worktree(
                workspaceID: "workspace:\(token)",
                tabID: "tab:\(token)",
                rootPaneID: "pane:\(token)",
                path: "/tmp/worktree/\(token)"))
        attempt.recordAgentStartDispatched(at: .now)

        let launch = try await Self.launchWorktreeAgent(
            on: transport, token: token, branchIsGenerated: true, attempt: attempt)

        #expect(try launch.result.get().paneID == "pane:\(token)")
        #expect(launch.recorded == [wire.rename, wire.agentList])
        #expect(launch.steps.isEmpty)
    }

    /// An env-carrying launch runs its Agent in a tab of its own, never the
    /// root pane. A replay after its dispatch finds that Agent at once,
    /// without waiting on the root pane, and closes the bare root shell.
    @Test("a replayed env-carrying worktree launch returns its tab's Agent and closes the root shell")
    func replayedEnvLaunchReturnsItsTabsAgentAndClosesTheRootShell() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.worktreeLaunchSettings(environment))
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("envagent")
        let wire = WorktreeLaunchWire(token: token)
        let attempt = Self.ownWorktreeAttempt(token: token)

        let launch = try await Self.launchWorktreeAgent(
            on: transport, token: token, branchIsGenerated: true, attempt: attempt,
            environment: ["HERMES_EPHEMERAL_SYSTEM_PROMPT": "Text back."])

        #expect(try launch.result.get().paneID == "env-pane:\(token)")
        #expect(launch.recorded == [wire.rename, wire.agentList, wire.paneClose])
        #expect(launch.steps.isEmpty)
    }

    /// A replay whose lost try opened the env-carrying tab but no Agent
    /// came up there starts the Agent in that tab, not a second one.
    @Test("a replayed env-carrying worktree launch starts in the tab its lost try opened")
    func replayedEnvLaunchStartsInTheTabItsLostTryOpened() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.worktreeLaunchSettings(environment))
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("envorphan")
        let wire = WorktreeLaunchWire(token: token)
        let attempt = Self.ownWorktreeAttempt(token: token)

        let launch = try await Self.launchWorktreeAgent(
            on: transport, token: token, branchIsGenerated: true, attempt: attempt,
            environment: ["HERMES_EPHEMERAL_SYSTEM_PROMPT": "Text back."])

        #expect(try launch.result.get().paneID == "env-pane:\(token)")
        #expect(launch.recorded.first == wire.rename)
        // Waits out the lost try's start, then reuses its tab.
        #expect(launch.recorded.dropFirst().prefix { $0 == wire.agentList }.count > 1)
        #expect(!launch.recorded.contains { $0.hasPrefix("tab.create ") })
        #expect(
            Array(launch.recorded.suffix(3)) == [
                wire.snapshot,
                #"agent.start {"args":["--no-daemon"],"kind":"codex","name":"fixture","pane_id":"env-pane:\#(token)"}"#,
                wire.paneClose,
            ])
        #expect(launch.steps == [.startingAgent])
    }

    /// An attempt whose lost try settled `token`'s own worktree and
    /// dispatched the Agent's start.
    private static func ownWorktreeAttempt(token: String) -> WorktreeLaunchAttempt {
        let attempt = WorktreeLaunchAttempt()
        attempt.recordCreateDispatched()
        attempt.recordWorktree(
            WorktreeLaunchAttempt.Worktree(
                workspaceID: "workspace:\(token)",
                tabID: "tab:\(token)",
                rootPaneID: "pane:\(token)",
                path: "/tmp/worktree/\(token)"))
        attempt.recordAgentStartDispatched(at: .now)
        return attempt
    }

    /// A worktree create that never answers and never made anything: with
    /// nothing on its branch within the reconcile budget, the launch stops
    /// and says so rather than sending a second `worktree.create`.
    @Test("an unanswered worktree create that made nothing fails unconfirmed after one create")
    func unansweredWorktreeCreateThatMadeNothingFailsUnconfirmed() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        var settings = Self.worktreeLaunchSettings(environment)
        settings.worktreeReconcileBudget = .seconds(2)
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("hungnothing")
        let wire = WorktreeLaunchWire(token: token)

        let launch = try await Self.launchWorktreeAgent(
            on: transport, token: token, branchIsGenerated: true)

        #expect(throws: WorktreeLaunchError.createUnconfirmed) { try launch.result.get() }
        try #require(launch.recorded.count >= 3)
        #expect(Array(launch.recorded.prefix(2)) == [wire.list, wire.create])
        // Only reconcile polls follow: no second create, no start, no removal.
        #expect(launch.recorded.dropFirst(2).allSatisfy { $0 == wire.list })
        #expect(launch.steps == [.creatingWorktree, .checkingForCreatedWorktree])
    }

    /// A launch's own worktree, found after its create went unanswered, is
    /// removed when herdr refuses the Agent: nothing else can be using it.
    @Test("a refused agent start removes the own worktree found after an unanswered create")
    func refusedAgentStartRemovesTheOwnWorktreeFoundAfterAnUnansweredCreate() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.worktreeLaunchSettings(environment))
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("hungrefuse")
        let wire = WorktreeLaunchWire(token: token)

        let launch = try await Self.launchWorktreeAgent(
            on: transport, token: token, branchIsGenerated: true)

        #expect(throws: Self.refusedStart) { try launch.result.get() }
        #expect(
            launch.recorded == [
                wire.list, wire.create, wire.list, wire.snapshot, wire.rename,
                wire.agentList, wire.rootAgentStart, wire.remove,
            ])
    }

    /// On a typed branch, a worktree found after an unanswered create may be
    /// someone else's: it is adopted with a new tab, and a refused Agent
    /// closes only that tab's pane, never the worktree.
    @Test("a typed-branch worktree found after an unanswered create is adopted, never removed")
    func typedBranchWorktreeFoundAfterAnUnansweredCreateIsAdopted() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.worktreeLaunchSettings(environment))
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("hungrefuse")
        let wire = WorktreeLaunchWire(token: token)

        let launch = try await Self.launchWorktreeAgent(on: transport, token: token)

        #expect(throws: Self.refusedStart) { try launch.result.get() }
        #expect(
            launch.recorded == [
                wire.list, wire.create, wire.list, wire.agentList, wire.adoptedTab,
                wire.rootAgentStart, wire.paneClose,
            ])
        #expect(
            launch.steps == [
                .creatingWorktree, .checkingForCreatedWorktree, .usingExistingWorktree,
                .creatingTab, .startingAgent,
            ])
    }

    /// A create answered after the ordinary request budget but inside
    /// `worktreeCreateTimeout` is an answer: nothing is reconciled.
    @Test("a slow worktree create inside its own budget needs no reconcile")
    func slowWorktreeCreateInsideItsBudgetNeedsNoReconcile() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        var settings = Self.worktreeLaunchSettings(environment)
        // The fixture answers after 4 s.
        settings.requestTimeout = .seconds(2)
        settings.worktreeCreateTimeout = .sshdBudget(10)
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("slowcreate")
        let wire = WorktreeLaunchWire(token: token)

        let launch = try await Self.launchWorktreeAgent(on: transport, token: token)

        #expect(try launch.result.get().paneID == "pane:\(token)")
        #expect(launch.recorded == [wire.list, wire.create, wire.rename, wire.rootAgentStart])
        #expect(launch.steps == [.creatingWorktree, .startingAgent])
    }

    /// A typed branch already checked out in an open worktree cannot be
    /// created again; with an Agent already running there, that Agent is
    /// the launch's answer, found before any latest-main fetch.
    @Test("a worktree launch on a branch already open with an Agent joins it without fetching")
    func worktreeLaunchOnAnOpenBranchWithAnAgentJoinsIt() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.worktreeLaunchSettings(environment))
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("existingagent")
        let wire = WorktreeLaunchWire(token: token)

        // The fixture's source checkout does not exist: a fetch would fail.
        let launch = try await Self.launchWorktreeAgent(
            on: transport, token: token, base: .latestDefaultBranch)

        let agent = try launch.result.get()
        #expect(agent.paneID == "existing-pane:\(token)")
        #expect(agent.workspaceID == "workspace:\(token)")
        #expect(launch.recorded == [wire.list, wire.agentList])
        #expect(launch.steps == [.usingExistingWorktree, .joiningRunningAgent])
    }

    /// Joining prefers an Agent of the requested kind over whichever herdr
    /// lists first.
    @Test("joining an open worktree prefers an Agent of the requested kind")
    func joiningAnOpenWorktreePrefersTheRequestedKind() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.worktreeLaunchSettings(environment))
        defer { Task { try? await transport.close() } }
        // agent.list: a claude Agent, then the codex one.
        let token = Self.scriptToken("existingkinds")

        let launch = try await Self.launchWorktreeAgent(on: transport, token: token)

        let agent = try launch.result.get()
        #expect(agent.paneID == "existing-pane:\(token)")
        #expect(agent.kind == "codex")
    }

    /// The same open worktree without an Agent: the launch opens a tab in
    /// that Workspace at the worktree's checkout and starts the Agent there.
    @Test("a worktree launch on a branch already open without an Agent starts one there")
    func worktreeLaunchOnAnOpenBranchWithoutAnAgentStartsOne() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.worktreeLaunchSettings(environment))
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("existingidle")
        let wire = WorktreeLaunchWire(token: token)

        let launch = try await Self.launchWorktreeAgent(on: transport, token: token)

        #expect(try launch.result.get().paneID == "pane:\(token)")
        #expect(
            launch.recorded == [wire.list, wire.agentList, wire.adoptedTab, wire.rootAgentStart])
        #expect(launch.steps == [.usingExistingWorktree, .creatingTab, .startingAgent])
    }

    /// An adopted worktree is never removed: a refused Agent closes only the
    /// tab's pane the launch opened in it.
    @Test("a refused agent start in an adopted worktree closes only its pane")
    func refusedAgentStartInAnAdoptedWorktreeClosesOnlyItsPane() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.worktreeLaunchSettings(environment))
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("existingrefuse")
        let wire = WorktreeLaunchWire(token: token)

        let launch = try await Self.launchWorktreeAgent(on: transport, token: token)

        #expect(throws: Self.refusedStart) { try launch.result.get() }
        #expect(
            launch.recorded == [
                wire.list, wire.agentList, wire.adoptedTab, wire.rootAgentStart, wire.paneClose,
            ])
    }

    /// The New Terminal launch on an already open branch: one marked shell
    /// tab in that Workspace at the worktree's checkout, nothing created.
    @Test("a shell worktree launch on a branch already open opens a marked tab there")
    func shellWorktreeLaunchOnAnOpenBranchOpensAMarkedTab() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.worktreeLaunchSettings(environment))
        defer { Task { try? await transport.close() } }
        let token = Self.scriptToken("existingshell")
        let steps = LaunchStepLog()

        let shell = try await steps.recording {
            try await transport.startShellTerminalInNewWorktree(
                ShellLaunchRequest(name: "fixture", workspaceID: "source:\(token)"),
                worktree: WorktreeSpec(branch: "task/\(token)"),
                attempt: WorktreeLaunchAttempt())
        }

        #expect(shell.paneID == "pane:\(token)")
        #expect(shell.workspaceID == "workspace:\(token)")
        #expect(
            try await Self.recordedRequests(from: transport, token: token) == [
                #"worktree.list {"workspace_id":"source:\#(token)"}"#,
                #"tab.create {"cwd":"/tmp/worktree/\#(token)","env":{"WAYCAR_SHELL":"1"},"focus":false,"label":"fixture","workspace_id":"workspace:\#(token)"}"#,
            ])
        #expect(steps.all == [.usingExistingWorktree, .openingShell])
    }

    /// New Workspace (#230) creates the Workspace first, then starts in its
    /// root pane. `tab.create` would open a second tab inside a Workspace
    /// that already has one.
    @Test("a new-workspace agent start creates the workspace then starts in its root pane")
    func newWorkspaceAgentStartCreatesThenStartsWithoutATab() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.settingsWithoutLaunchSettle(environment))
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("ok")
        let agent = try await transport.startAgentInNewWorkspace(
            AgentLaunchRequest(kind: "codex", name: "fixture"),
            workspace: NewWorkspaceSpec(directory: "/fixture/\(token)", label: "App"))

        #expect(agent.paneID == "pane:\(token)")
        #expect(agent.workspaceID == "workspace:\(token)")
        let recorded = try await Self.recordedRequests(from: transport, token: token)
        try #require(recorded.count == 3)
        #expect(
            recorded[0]
                == #"workspace.create {"cwd":"/fixture/\#(token)","focus":false,"label":"App"}"#)
        // The fresh Workspace's tab carries the agent's name, not the
        // Workspace itself.
        #expect(
            recorded[1]
                == #"tab.rename {"label":"fixture","tab_id":"tab:\#(token)"}"#)
        #expect(
            recorded[2]
                == #"agent.start {"args":["--no-daemon"],"kind":"codex","name":"fixture","pane_id":"pane:\#(token)"}"#)
        #expect(!recorded.contains { $0.hasPrefix("tab.create ") })
    }

    /// The New Agent sheet awaits this call. herdr 0.8.0+ accepts
    /// `agent.start` seconds before the agent is promptable, and the
    /// Transport settles that launch in the background. A registration poll
    /// here once held the sheet open for its whole 10 s budget. The fixture
    /// never lists the started agent, so any wait for it would spend its
    /// entire budget.
    @Test("an agent start returns without waiting for the launch to settle")
    func agentStartReturnsWithoutWaitingForTheLaunchToSettle() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.settingsWithoutLaunchSettle(environment))
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("ok")
        let started = ContinuousClock.now
        let agent = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "codex",
                name: "fixture",
                workspaceID: "workspace-1",
                cwd: "/fixture/\(token)"))

        #expect(agent.paneID == "pane:\(token)")
        // The time bound is the guard: two local RPCs finish well inside it
        // even on a loaded runner, and any wait for a registration the
        // fixture never reports would spend its whole budget. `agent.list`
        // carries no token, so the method list below only rules out
        // token-carrying follow-ups such as a pane-scoped read.
        #expect(started.duration(to: .now) < .seconds(3))
        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(recorded.map { String($0.prefix { $0 != " " }) } == ["tab.create", "agent.start"])
    }

    /// herdr 0.9.1 promotes a pending launch only on a reconcile (`agent.get`
    /// or a status change) once its settle has passed. On one Host, omp with
    /// herdr's integration reported idle before then and never changed again,
    /// so without an `agent.get` every prompt was refused `agent_not_ready`
    /// (#17). The `launchrace` fixture scales that race down (settle 1.5 s,
    /// deadline 4 s after `agent.start`); prompts here never reconcile it, so
    /// only the Transport's settle can.
    @Test("a launch herdr leaves pending becomes promptable with no composer")
    func pendingLaunchSettlesWithoutAComposer() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        var settings = environment.directSettings()
        settings.launchSettleDelay = .milliseconds(200)
        settings.launchSettleInterval = .milliseconds(100)
        settings.launchSettleWindow = .seconds(3)
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("launchrace")
        let agent = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "codex",
                name: "fixture",
                workspaceID: "workspace-1",
                cwd: "/fixture/\(token)"))
        let acknowledged = ContinuousClock.now

        // Accepted before the fixture's deadline, so by promotion, not by a
        // late `agent.get` clearing the gate along with the name.
        let prompted = try await Self.promptOnceLaunchSettles(
            transport,
            paneID: agent.paneID,
            until: acknowledged + .milliseconds(3500))
        #expect(prompted.name == "fixture")
        let settled = try await Self.recordedRequests(from: transport, token: token)
        let polls = settled.filter { $0.hasPrefix("agent.get ") }
        // The first `agent.get` lands well before the fixture's settle, so
        // the launch was promoted by a repeat.
        #expect(polls.count >= 2)
        #expect(polls.allSatisfy { $0 == #"agent.get {"target":"pane:\#(token)"}"# })

        // Promotion ends the settle: past the fixture's deadline nothing
        // more was asked, and nothing cleared the name.
        try await Task.sleep(until: acknowledged + .seconds(5), clock: .continuous)
        let final = try await Self.recordedRequests(from: transport, token: token)
        #expect(final.filter { $0.hasPrefix("agent.get ") }.count == polls.count)
        #expect(!final.contains(Self.launchNameCleared))
    }

    /// The other end of the settle: a launch still working when the window
    /// closes is polled only inside it. An `agent.get` after herdr's launch
    /// deadline clears the name (and gate) of an Agent still pending and not
    /// blocked, instead of promoting it.
    @Test("a launch that never settles is polled only inside the settle window")
    func unsettledLaunchIsPolledOnlyInsideTheWindow() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let window: Duration = .milliseconds(1500)
        var settings = environment.directSettings()
        settings.launchSettleDelay = .milliseconds(200)
        settings.launchSettleInterval = .milliseconds(100)
        settings.launchSettleWindow = window
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("launchworking")
        let agent = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "codex",
                name: "fixture",
                workspaceID: "workspace-1",
                cwd: "/fixture/\(token)"))
        let acknowledged = ContinuousClock.now

        try await Task.sleep(until: acknowledged + window + .milliseconds(1500), clock: .continuous)
        let afterWindow = try await Self.recordedRequests(from: transport, token: token)
            .filter { $0.hasPrefix("agent.get ") }
            .count
        // Polled while pending, rather than asked once and dropped.
        #expect(afterWindow >= 2)

        // Past the fixture's 4 s deadline: no `agent.get` after the window,
        // so the launch is still pending and keeps its name.
        try await Task.sleep(until: acknowledged + .seconds(5), clock: .continuous)
        let final = try await Self.recordedRequests(from: transport, token: token)
        #expect(final.filter { $0.hasPrefix("agent.get ") }.count == afterWindow)
        #expect(!final.contains(Self.launchNameCleared))
        await #expect(
            throws: HerdrAPIError(
                code: "agent_not_ready",
                message: "agent \(agent.paneID) is not an active named agent")
        ) {
            _ = try await transport.promptAgent(
                AgentPromptParams(target: agent.paneID, text: "fixture prompt"))
        }
    }

    /// herdr 0.9.1 promotes an opencode launch about 3.5 s after
    /// `agent.start` and acks `agent.prompt` from then on, but opencode's TUI
    /// drops typed input until its input box draws (11–42 s on a 2-vCPU
    /// test Host), so an acked prompt was lost. The `opencodebox` pane is
    /// blank on its first read and shows the box after: the first prompt
    /// reads the screen and sends nothing, the next goes out, and once the
    /// box was seen no prompt reads the screen again.
    @Test("an early prompt to a fresh opencode Agent waits for its input box")
    func opencodePromptWaitsForTheInputBox() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.settingsWithoutLaunchSettle(environment))
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("opencodebox")
        let agent = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "opencode",
                name: "fixture",
                workspaceID: "workspace-1",
                cwd: "/fixture/\(token)"))
        let params = AgentPromptParams(target: agent.paneID, text: "fixture prompt")
        let screenRead = #"pane.read {"pane_id":"pane:\#(token)","source":"visible"}"#
        let prompt = #"agent.prompt {"target":"pane:\#(token)","text":"fixture prompt"}"#

        await #expect(throws: AgentInputNotReadyError.self) {
            _ = try await transport.promptAgent(params)
        }
        let held = try await Self.recordedRequests(from: transport, token: token)
        #expect(Self.methods(held) == ["tab.create", "agent.start", "pane.read"])
        #expect(held.last == screenRead)

        _ = try await transport.promptAgent(params)
        _ = try await transport.promptAgent(params)
        let delivered = try await Self.recordedRequests(from: transport, token: token)
        #expect(Array(delivered.dropFirst(2)) == [screenRead, screenRead, prompt, prompt])
    }

    /// A box that never draws holds prompts only until
    /// `inputReadyTimeout` after the launch; then they go out unread.
    @Test("an opencode input gate opens unread once its timeout passes")
    func opencodeInputGateOpensAfterItsTimeout() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let timeout: Duration = .seconds(3)
        var settings = Self.settingsWithoutLaunchSettle(environment)
        settings.inputReadyTimeout = timeout
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("opencodeblank")
        let agent = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "opencode",
                name: "fixture",
                workspaceID: "workspace-1",
                cwd: "/fixture/\(token)"))
        let acknowledged = ContinuousClock.now
        let params = AgentPromptParams(target: agent.paneID, text: "fixture prompt")

        do {
            _ = try await transport.promptAgent(params)
            Issue.record("a prompt went out before opencode drew its input box")
        } catch let held as AgentInputNotReadyError {
            #expect(held.kind == "opencode")
            #expect(held.target == agent.paneID)
            #expect(held.opensAt <= acknowledged + timeout)
        }

        try await Task.sleep(until: acknowledged + timeout, clock: .continuous)
        _ = try await transport.promptAgent(params)
        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(
            Self.methods(recorded) == ["tab.create", "agent.start", "pane.read", "agent.prompt"])
    }

    /// kilo (an opencode fork) drops early input the same way, behind the
    /// same `┃` box, and cline until its `❯` composer row draws: on herdr
    /// 0.9.3 a kilo prompt acked ~1 s after promotion was lost in 3 of 4
    /// runs (docs/research/harnesses/herdr-backend.md).
    @Test("an early prompt to a fresh kilo or cline Agent waits for its input marker")
    func markerKindsWaitForTheirInput() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.settingsWithoutLaunchSettle(environment))
        defer { Task { try? await transport.close() } }

        for (kind, behavior) in [("kilo", "opencodebox"), ("cline", "clinerow")] {
            let token = Self.scriptToken(behavior)
            let agent = try await transport.startAgent(
                AgentLaunchRequest(
                    kind: kind, name: "fixture", workspaceID: "workspace-1",
                    cwd: "/fixture/\(token)"))
            let params = AgentPromptParams(target: agent.paneID, text: "fixture prompt")

            await #expect(throws: AgentInputNotReadyError.self) {
                _ = try await transport.promptAgent(params)
            }
            _ = try await transport.promptAgent(params)
            _ = try await transport.promptAgent(params)
            let recorded = try await Self.recordedRequests(from: transport, token: token)
            #expect(
                Self.methods(recorded)
                    == ["tab.create", "agent.start", "pane.read", "pane.read", "agent.prompt",
                        "agent.prompt"],
                "\(kind)")
        }
    }

    /// herdr 0.9.3 reports cursor's, devin's and kiro's sign-in screens idle
    /// and ready, and a prompt's Enter drives the login. The prompt is
    /// refused with nothing typed, and the screen is checked before every
    /// prompt to that launch, also once the Host is signed in.
    @Test("a prompt to an Agent on its sign-in screen is refused, nothing typed")
    func signInScreenRefusesPrompts() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.settingsWithoutLaunchSettle(environment))
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("signin")
        let agent = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "cursor", name: "fixture", workspaceID: "workspace-1",
                cwd: "/fixture/\(token)"))
        let params = AgentPromptParams(target: agent.paneID, text: "fixture prompt")

        await #expect(throws: AgentSignInRequiredError(kind: "cursor", target: agent.paneID)) {
            _ = try await transport.promptAgent(params)
        }
        let refused = try await Self.recordedRequests(from: transport, token: token)
        #expect(Self.methods(refused) == ["tab.create", "agent.start", "pane.read"])

        _ = try await transport.promptAgent(params)
        _ = try await transport.promptAgent(params)
        let delivered = try await Self.recordedRequests(from: transport, token: token)
        #expect(
            Array(Self.methods(delivered).dropFirst(3))
                == ["pane.read", "agent.prompt", "pane.read", "agent.prompt"])
    }

    /// The sign-in check follows the Agent's kind, not a launch this
    /// Transport saw: after a reconnect (a new Transport), or for an Agent
    /// started elsewhere, one `agent.get` names the kind, remembered for
    /// later prompts.
    @Test("a prompt over a new Transport to an Agent on its sign-in screen is refused")
    func signInScreenRefusesPromptsAfterAReconnect() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let launcher = try await WaycarSSHTransport.connect(
            settings: Self.settingsWithoutLaunchSettle(environment))
        let token = Self.scriptToken("signin")
        let agent = try await launcher.startAgent(
            AgentLaunchRequest(
                kind: "cursor", name: "fixture", workspaceID: "workspace-1",
                cwd: "/fixture/\(token)"))
        try await launcher.close()

        let transport = try await WaycarSSHTransport.connect(
            settings: Self.settingsWithoutLaunchSettle(environment))
        defer { Task { try? await transport.close() } }
        let params = AgentPromptParams(target: agent.paneID, text: "fixture prompt")
        await #expect(throws: AgentSignInRequiredError(kind: "cursor", target: agent.paneID)) {
            _ = try await transport.promptAgent(params)
        }
        _ = try await transport.promptAgent(params)
        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(
            Self.methods(recorded)
                == ["tab.create", "agent.start", "agent.get", "pane.read", "pane.read",
                    "agent.prompt"])
    }

    /// herdr 0.9.3 reads grok's folder-trust dialog as idle and ready, and
    /// grok takes a typed `y` as "trust" (grok.md §12): every prompt to a
    /// grok Agent reads the screen and is refused, nothing typed, while the
    /// dialog shows.
    @Test("a prompt to an Agent on its folder-trust dialog is refused, nothing typed")
    func trustDialogRefusesPrompts() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.settingsWithoutLaunchSettle(environment))
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("groktrust")
        let agent = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "grok", name: "fixture", workspaceID: "workspace-1",
                cwd: "/fixture/\(token)"))
        let params = AgentPromptParams(target: agent.paneID, text: "fixture prompt")

        await #expect(throws: AgentFolderTrustRequiredError(kind: "grok", target: agent.paneID)) {
            _ = try await transport.promptAgent(params)
        }
        let refused = try await Self.recordedRequests(from: transport, token: token)
        #expect(Self.methods(refused) == ["tab.create", "agent.start", "pane.read"])

        _ = try await transport.promptAgent(params)
        let delivered = try await Self.recordedRequests(from: transport, token: token)
        #expect(Array(Self.methods(delivered).dropFirst(3)) == ["pane.read", "agent.prompt"])
    }

    /// copilot lost a paste 0.3 s after launch (copilot.md) with nothing on
    /// screen to tell: its prompts are held, unread, for the kind's
    /// minimum delay after the start, then go out with no screen read.
    @Test("a fresh copilot Agent is held for its minimum delay without a screen read")
    func minimumDelayKindsAreHeldUnread() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.settingsWithoutLaunchSettle(environment))
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("ok")
        let started = ContinuousClock.now
        let agent = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "copilot", name: "fixture", workspaceID: "workspace-1",
                cwd: "/fixture/\(token)"))
        let acknowledged = ContinuousClock.now
        let params = AgentPromptParams(target: agent.paneID, text: "fixture prompt")
        let delay = AgentScreen.readiness(kind: "copilot").minimumDelay

        do {
            _ = try await transport.promptAgent(params)
            Issue.record("a prompt went out inside copilot's minimum delay")
        } catch let held as AgentInputNotReadyError {
            #expect(held.opensAt >= started + delay && held.opensAt <= acknowledged + delay)
            try await Task.sleep(until: held.opensAt, clock: .continuous)
        }
        _ = try await transport.promptAgent(params)
        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(Self.methods(recorded) == ["tab.create", "agent.start", "agent.prompt"])
    }

    /// Kinds with no input marker, minimum delay or sign-in screen are
    /// prompted at once, with no screen read in front.
    @Test("a prompt to a fresh Agent of another kind reads no screen first")
    func otherKindsArePromptedWithoutAScreenRead() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: Self.settingsWithoutLaunchSettle(environment))
        defer { Task { try? await transport.close() } }

        for kind in ["claude", "codex", "omp", "pi"] {
            let token = Self.scriptToken("ok")
            let agent = try await transport.startAgent(
                AgentLaunchRequest(
                    kind: kind,
                    name: "fixture",
                    workspaceID: "workspace-1",
                    cwd: "/fixture/\(token)"))
            _ = try await transport.promptAgent(
                AgentPromptParams(target: agent.paneID, text: "fixture prompt"))
            let recorded = try await Self.recordedRequests(from: transport, token: token)
            #expect(Self.methods(recorded) == ["tab.create", "agent.start", "agent.prompt"])
        }
    }

    /// The new-Workspace half of the same compensation: a refused launch
    /// would otherwise leave an empty Workspace behind.
    @Test("a refused new-workspace agent start closes the workspace it created")
    func refusedNewWorkspaceAgentStartClosesTheWorkspace() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("startfails")
        await #expect(throws: Self.refusedStart) {
            _ = try await transport.startAgentInNewWorkspace(
                AgentLaunchRequest(kind: "codex", name: "fixture"),
                workspace: NewWorkspaceSpec(directory: "/fixture/\(token)"))
        }

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        try #require(recorded.count == 4)
        #expect(
            recorded[0]
                == #"workspace.create {"cwd":"/fixture/\#(token)","focus":false}"#)
        #expect(
            recorded[1]
                == #"tab.rename {"label":"fixture","tab_id":"tab:\#(token)"}"#)
        #expect(
            recorded[2]
                == #"agent.start {"args":["--no-daemon"],"kind":"codex","name":"fixture","pane_id":"pane:\#(token)"}"#)
        #expect(recorded[3] == #"workspace.close {"workspace_id":"workspace:\#(token)"}"#)
        #expect(!recorded.contains { $0.hasPrefix("tab.create ") })
    }

    /// Closing the channel without a herdr error envelope is ambiguous: the
    /// Agent may already exist on the Host. Compensating `workspace.close`
    /// would destroy a possibly successful result.
    @Test("an ambiguous new-workspace agent start does not close the workspace")
    func ambiguousNewWorkspaceAgentStartPreservesTheWorkspace() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        var settings = environment.directSettings()
        settings.requestTimeout = .seconds(1)
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("startdrop")
        await #expect(throws: TransportError.self) {
            _ = try await transport.startAgentInNewWorkspace(
                AgentLaunchRequest(kind: "codex", name: "fixture"),
                workspace: NewWorkspaceSpec(directory: "/fixture/\(token)"))
        }

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        try #require(recorded.count == 3)
        #expect(recorded[0].hasPrefix("workspace.create "))
        #expect(recorded[1] == #"tab.rename {"label":"fixture","tab_id":"tab:\#(token)"}"#)
        #expect(recorded[2].hasPrefix("agent.start "))
        #expect(!recorded.contains { $0.hasPrefix("workspace.close ") })
        #expect(!recorded.contains { $0.hasPrefix("tab.create ") })
    }

    @Test("confirmed worktree removal crosses the real wire dispatch seam")
    func confirmedWorktreeRemovalCrossesTheRealWireDispatchSeam() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("remove")
        let checkout = RepositoryCheckout(
            repoKey: "/tmp/repo/.git",
            repoName: "repo",
            repoRoot: "/tmp/repo",
            checkoutPath: "/tmp/worktree/\(token)",
            isLinkedWorktree: true)
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: UUID(),
                workspaceID: "workspace:\(token)",
                checkout: checkout))
        let boundary = WorktreeWireBoundaryRecorder()

        let response = try await transport.removeWorktree(
            request,
            authorize: { candidate in await boundary.authorize(candidate) },
            onDispatched: { candidate in await boundary.recordDispatch(candidate) })

        #expect(response.workspaceID == request.identity.workspaceID)
        #expect(response.path == request.identity.checkoutPath)
        #expect(await boundary.authorized == [request])
        #expect(await boundary.dispatched == [request])
        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(
            recorded == [
                #"worktree.remove {"force":false,"workspace_id":"workspace:\#(token)"}"#
            ])
    }

    @Test("stale worktree authorization writes no request bytes")
    func staleWorktreeAuthorizationWritesNoRequestBytes() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("stale")
        let checkout = RepositoryCheckout(
            repoKey: "/tmp/repo/.git",
            repoName: "repo",
            repoRoot: "/tmp/repo",
            checkoutPath: "/tmp/worktree/\(token)",
            isLinkedWorktree: true)
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: UUID(),
                workspaceID: "workspace:\(token)",
                checkout: checkout))
        let boundary = WorktreeWireBoundaryRecorder()

        await #expect(throws: WorktreeRemovalError.staleIdentity) {
            _ = try await transport.removeWorktree(
                request,
                authorize: { _ in throw WorktreeRemovalError.staleIdentity },
                onDispatched: { candidate in await boundary.recordDispatch(candidate) })
        }

        #expect(await boundary.dispatched.isEmpty)
        #expect(try await Self.recordedRequests(from: transport, token: token).isEmpty)
    }

    /// A launch started from another agent's screen carries that agent's
    /// directory. Dropping the cwd is invisible in the reply — herdr answers
    /// with a healthy tab either way — so only the request proves it went.
    @Test("agent start places the fresh tab in the requested directory")
    func agentStartPlacesTheFreshTabInTheRequestedDirectory() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("ok")
        _ = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "codex",
                name: "fixture",
                workspaceID: "workspace-1",
                cwd: "/fixture/\(token)"))

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        // tab.create names the tab after the agent at creation time.
        #expect(
            recorded.first
                == #"tab.create {"cwd":"/fixture/\#(token)","focus":false,"label":"fixture","workspace_id":"workspace-1"}"#
        )
    }

    /// A Chat Prompt route that lives in the pane's environment (Copilot's
    /// instructions directory, Hermes's ephemeral prompt) goes in
    /// `tab.create`'s `env`: `agent.start` takes arguments only.
    @Test("agent start carries the launch environment in the fresh tab")
    func agentStartCarriesTheLaunchEnvironment() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("ok")
        _ = try await transport.startAgent(
            AgentLaunchRequest(
                kind: "hermes",
                name: "fixture",
                arguments: ["chat"],
                workspaceID: "workspace-1",
                cwd: "/fixture/\(token)",
                environment: ["HERMES_EPHEMERAL_SYSTEM_PROMPT": "Text back."]))

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(
            recorded.first
                == #"tab.create {"cwd":"/fixture/\#(token)","env":{"HERMES_EPHEMERAL_SYSTEM_PROMPT":"Text back."},"focus":false,"label":"fixture","workspace_id":"workspace-1"}"#
        )
    }

    @Test("shell terminal creation sends one exact tab create request")
    func shellTerminalCreationSendsOneExactTabCreateRequest() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("shell")
        let identity = try await transport.createShellTerminal(
            ShellTerminalCreationRequest(
                workspaceID: "workspace-1",
                cwd: "/fixture/\(token)"))

        #expect(!identity.paneID.isEmpty)
        #expect(!identity.tabID.isEmpty)
        #expect(!identity.terminalID.isEmpty)
        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(
            recorded
                == [
                    #"tab.create {"cwd":"/fixture/\#(token)","env":{"WAYCAR_SHELL":"1"},"focus":false,"workspace_id":"workspace-1"}"#
                ])
    }

    /// A named session becomes a directory component of the remote socket path,
    /// so discovery output is not trusted to stay inside herdr's grammar. One
    /// bad name fails the whole list rather than being dropped from it: a
    /// partial list would silently hide a session the Host really has.
    @Test("session discovery refuses a name outside herdr's grammar")
    func sessionDiscoveryRefusesNamesOutsideTheGrammar() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        var settings = environment.directSettings()
        settings.sessionListCommand =
            "printf '%s\\n' '{\"sessions\":["
            + "{\"name\":\"fixture\",\"default\":true,\"running\":true},"
            + "{\"name\":\"../escape\",\"default\":false,\"running\":false}]}'"
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        await #expect(
            throws: TransportError.malformedResponse(
                "herdr session list returned an invalid session name")
        ) {
            _ = try await transport.listSessions()
        }
    }

    /// The probe runs through the Host's login shell, so its stdout carries
    /// whatever that shell prints. Only marker-prefixed lines count, only kinds
    /// this build knows survive, and the answer is a stable ordered set — a
    /// banner that merely says "gemini" must not install an agent.
    @Test("agent discovery ignores login noise, unknown kinds, and duplicates")
    func agentDiscoveryIgnoresLoginNoiseUnknownKindsAndDuplicates() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        var settings = environment.directSettings()
        settings.agentDiscoveryCommand =
            "printf '%s\\n' 'Welcome to the Host' 'gemini' "
            + "'__WAYCAR_AGENT_KIND__=codex' "
            + "'__WAYCAR_AGENT_KIND__=notarealagent' "
            + "'__WAYCAR_AGENT_KIND__=codex' "
            + "'__WAYCAR_AGENT_KIND__=claude' "
            + "'__WAYCAR_AGENT_KIND__=qwen' "
            + "'last login: never'"
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        #expect(try await transport.availableAgentKinds() == [.claude, .codex, .qwen])
    }

    /// The home probe also runs through the login shell, and its answer becomes
    /// a directory component of the socket path every later request opens. A
    /// banner, a trailing login line, and a stale marker printed by a sourced
    /// profile must all leave the resolved home exact — the last marker wins.
    @Test("home resolution ignores login-shell stdout around its marker")
    func homeResolutionIgnoresLoginShellNoise() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let quotedHome = try #require(RemoteShellPath.quotedAbsolute(environment.homePath))
        var settings = environment.directSettings(socket: .defaultSession)
        settings.homeCommand =
            "/bin/sh -c 'printf \"Welcome to the Host\\n"
            + "__WAYCAR_HOME__=/wrong/home\\n"
            + "__WAYCAR_HOME__=%s\\n"
            + "last login: never\\n\" \"$1\"' home \(quotedHome)"
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        // The home-relative socket only resolves onto the fixture if both the
        // banner and the stale earlier marker were discarded.
        #expect(try await transport.ping().protocolVersion == 17)
        let skills = try await transport.listSkills(SkillListQuery(kind: .codex))
        let skill = try #require(skills.first { $0.name == "fixture" })
        #expect(skill.path == "\(environment.homePath)/.codex/skills/fixture/SKILL.md")
    }

    /// The first request against a home-relative socket pays for the home probe
    /// as well as the exchange. Both must come out of one budget: giving each
    /// its own would let a Host that is slow in both halves overrun the deadline
    /// the caller was promised, silently, and only on the first request.
    @Test("the first home-relative request spends one deadline, not two")
    func firstHomeRelativeRequestSpendsOneTotalDeadline() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let quotedHome = try #require(RemoteShellPath.quotedAbsolute(environment.homePath))
        var settings = environment.directSettings(socket: .defaultSession)
        settings.requestTimeout = .seconds(4)
        // Three quarters of the budget spent resolving the home, then a pane
        // read the fixture never answers. One deadline expires at four seconds;
        // two stacked budgets would run to seven.
        settings.homeCommand =
            "/bin/sh -c 'sleep 3; printf \"__WAYCAR_HOME__=%s\\n\" \"$1\"' home \(quotedHome)"
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        let started = ContinuousClock.now
        await #expect(throws: TransportError.timedOut) {
            _ = try await transport.readPane(
                PaneReadParams(paneID: "hang", source: .recent))
        }
        // Bounded on both sides: overrunning is the stacked-budget bug, and
        // expiring early would mean the probe never came out of this budget.
        let elapsed = started.duration(to: .now)
        #expect(elapsed > .seconds(3))
        #expect(elapsed < .seconds(5.5))
    }

    /// A mosh bootstrap returns on mosh-server's `MOSH CONNECT` line, not
    /// the exec's EOF (#105): the detached server's channel winds down in the
    /// background while the client already starts, aimed at the address the
    /// SSH connection reached.
    @Test("a mosh bootstrap returns on its banner line before the exec ends")
    func moshBootstrapReturnsOnItsBannerLine() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let session = try await HostSSHSession.dial(settings: environment.directSettings())
        // The banner first, then a channel that stays open well past it, as
        // mosh-server's detaching child keeps it. Waiting for the exec's end
        // would take 30 s, past both the bound below and the 15 s request
        // budget; the bound leaves a loaded runner room (one took 14 s for the
        // whole test). Releasing the session closes the connection, so the
        // test never waits the sleep out.
        let command =
            "printf 'mosh-server (mosh 1.4.0)\\r\\n\\r\\nMOSH CONNECT 60001 MDEyMzQ1Njc4OWFiY2RlZg\\r\\n';"
            + " sleep 30"

        let started = ContinuousClock.now
        let outcome: Result<MoshBootstrap, any Error>
        do {
            outcome = .success(try await session.runMoshBootstrap { _ in command })
        } catch {
            outcome = .failure(error)
        }
        let elapsed = started.duration(to: .now)
        let peer = session.moshUDPHost
        await session.release()
        let bootstrap = try outcome.get()
        #expect(elapsed < .seconds(20))
        #expect(bootstrap.udpPort == "60001")
        #expect(bootstrap.key == "MDEyMzQ1Njc4OWFiY2RlZg")
        #expect(peer != nil)
        #expect(bootstrap.host == peer)
    }

    /// A path tapped in terminal output is remote-controlled text. The read
    /// is SFTP alone, so the name is data wherever it goes; only a regular
    /// file within the limit is read, whole, from one handle.
    @Test("a tapped path previews only a regular file within the limit")
    func tappedPathPreviewIsBoundedToRegularFiles() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let fileManager = FileManager.default
        let root = "\(environment.homePath)/.waycar-preview-\(UUID().uuidString)"
        try fileManager.createDirectory(
            atPath: "\(root)/folder", withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(atPath: root) }
        let hostile = "\(root)/it's a b;$(touch pwned)`touch pwned2`&&x.png"
        // Several of the SFTP layer's 64 KiB reads.
        let contents = Data((0..<200_007).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try contents.write(to: URL(fileURLWithPath: hostile))
        try Data(count: 11).write(to: URL(fileURLWithPath: "\(root)/eleven.bin"))
        try fileManager.createSymbolicLink(
            atPath: "\(root)/link.bin", withDestinationPath: "\(root)/eleven.bin")
        #expect(mkfifo("\(root)/pipe", 0o600) == 0)
        try Data("secret".utf8).write(to: URL(fileURLWithPath: "\(root)/secret.bin"))
        try fileManager.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: "\(root)/secret.bin")
        let large = Data(repeating: 0xA5, count: 4 * 1_024 * 1_024)
        try large.write(to: URL(fileURLWithPath: "\(root)/large.bin"))
        let small = Data("the other file".utf8)
        try small.write(to: URL(fileURLWithPath: "\(root)/small.txt"))

        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        #expect(
            try await transport.readPreviewFile(atPath: hostile, maxBytes: contents.count)
                == contents)
        for directory in [root, environment.homePath] {
            #expect(!fileManager.fileExists(atPath: "\(directory)/pwned"))
            #expect(!fileManager.fileExists(atPath: "\(directory)/pwned2"))
        }
        #expect(
            try await transport.readPreviewFile(atPath: "\(root)/link.bin", maxBytes: 11)
                == Data(count: 11))
        await #expect(throws: RemoteFilePreviewError.tooLarge(size: 11, limit: 10)) {
            _ = try await transport.readPreviewFile(atPath: "\(root)/eleven.bin", maxBytes: 10)
        }
        await #expect(throws: RemoteFilePreviewError.directory) {
            _ = try await transport.readPreviewFile(atPath: "\(root)/folder", maxBytes: 10)
        }
        await #expect(throws: RemoteFilePreviewError.missing) {
            _ = try await transport.readPreviewFile(atPath: "\(root)/absent", maxBytes: 10)
        }
        // Refused from its type before anything opens it, so the read does
        // not wait out a writer that never comes.
        let started = ContinuousClock.now
        await #expect(throws: RemoteFilePreviewError.notRegularFile) {
            _ = try await transport.readPreviewFile(atPath: "\(root)/pipe", maxBytes: 10)
        }
        #expect(started.duration(to: .now) < .seconds(5))
        // Stat-ed fine, refused at the open.
        await #expect(throws: RemoteFilePreviewError.unreadable) {
            _ = try await transport.readPreviewFile(atPath: "\(root)/secret.bin", maxBytes: 10)
        }
        await #expect(throws: RemoteFilePreviewError.unresolvablePath) {
            _ = try await transport.readPreviewFile(atPath: "relative.png", maxBytes: 10)
        }

        // Tapping another path while one still loads cancels the first read
        // wherever it is. The second still comes back whole and as its own
        // file's bytes, the first gives its channel back, and the session
        // stays up.
        let channelsBefore = await transport.notificationFileStateForTesting().ordinarySessionCount
        for delay in [0, 1, 5, 20, 80] {
            let first = Task {
                try await transport.readPreviewFile(atPath: "\(root)/large.bin", maxBytes: large.count)
            }
            try await Task.sleep(for: .milliseconds(delay))
            first.cancel()
            #expect(
                try await transport.readPreviewFile(atPath: "\(root)/small.txt", maxBytes: 64)
                    == small,
                "cancelled \(delay) ms in")
            switch await first.result {
            case .success(let data):
                #expect(data == large, "cancelled \(delay) ms in")
            case .failure(let error):
                #expect(error as? TransportError == .cancelled, "cancelled \(delay) ms in")
            }
        }
        #expect(
            await transport.notificationFileStateForTesting().ordinarySessionCount
                == channelsBefore)
        #expect(await transport.isConnected)
    }

    @Test("agent focus sends the exact opaque target through the RPC channel")
    func agentFocusSendsItsTargetExactly() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("wire")
        try await transport.focusAgent(AgentTarget(target: token))

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(recorded == [#"agent.focus {"target":"\#(token)"}"#])
    }

    /// Tab close is a destructive write against real Host state, so the `ok`
    /// reply alone is not evidence. Record the request at the Unix-socket
    /// fixture boundary and pin the exact JSON params.
    @Test("a tab close records tab.close with the tab id")
    func tabCloseSendsItsTabIDExactly() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("wire")
        try await transport.closeTab(TabTarget(tabID: token))

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(recorded == [#"tab.close {"tab_id":"\#(token)"}"#])
    }

    /// herdr 0.9.x refuses emptying a main checkout's Workspace with
    /// `confirmation_required`, since it would take the worktree group; the
    /// user's Close was the confirmation, so the group closes once the
    /// Workspace is checked to still hold only that tab.
    @Test("a refused worktree-group tab close closes the group")
    func tabCloseOfAWorktreeGroupClosesTheGroup() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("worktreegroup")
        try await transport.closeTab(TabTarget(tabID: "tab:\(token)"))

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(
            recorded == [
                #"tab.close {"tab_id":"tab:\#(token)"}"#,
                #"tab.get {"tab_id":"tab:\#(token)"}"#,
                #"tab.list {"workspace_id":"workspace:\#(token)"}"#,
                #"workspace.close {"close_group":true,"workspace_id":"workspace:\#(token)"}"#,
            ])
    }

    @Test("a refused worktree-group pane close closes the group")
    func paneCloseOfAWorktreeGroupClosesTheGroup() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("worktreegroup")
        try await transport.closePane(
            PaneTarget(paneID: "pane:\(token)"), closesWorktreeGroup: true)

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(
            recorded == [
                #"pane.close {"pane_id":"pane:\#(token)"}"#,
                #"pane.get {"pane_id":"pane:\#(token)"}"#,
                #"tab.get {"tab_id":"tab:\#(token)"}"#,
                #"tab.list {"workspace_id":"workspace:\#(token)"}"#,
                #"workspace.close {"close_group":true,"workspace_id":"workspace:\#(token)"}"#,
            ])
    }

    /// A tab opened in the Workspace after herdr's refusal would go with the
    /// group, so the close stops instead, as herdr's confirm overlay does.
    @Test("a worktree-group close whose Workspace gained a tab closes nothing")
    func worktreeGroupCloseStopsWhenTheWorkspaceChanged() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("worktreegroupraced")
        await #expect(throws: HerdrAPIError.self) {
            try await transport.closeTab(TabTarget(tabID: "tab:\(token)"))
        }

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(!recorded.contains { $0.hasPrefix("workspace.close ") })
        #expect(recorded.last == #"tab.list {"workspace_id":"workspace:\#(token)"}"#)
    }

    /// A close the user did not ask for (backing out of a resume) keeps
    /// herdr's refusal: it must never take a worktree group with it.
    @Test("a pane close not confirmed by the user leaves a worktree group")
    func unconfirmedPaneCloseLeavesTheWorktreeGroup() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("worktreegroup")
        await #expect(throws: HerdrAPIError.self) {
            try await transport.closePane(
                PaneTarget(paneID: "pane:\(token)"), closesWorktreeGroup: false)
        }

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(recorded == [#"pane.close {"pane_id":"pane:\#(token)"}"#])
    }

    /// A custom Agent name is a write against real Host state, so the response
    /// alone is not evidence that the requested value reached herdr. Record the
    /// request at the Unix-socket fixture boundary and pin the exact JSON params.
    @Test("agent rename sends its custom name and target exactly")
    func agentRenameSendsItsCustomNameAndTargetExactly() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("wire")
        try await transport.renameAgent(AgentRenameParams(target: token, name: "reviewer"))

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(recorded == [#"agent.rename {"name":"reviewer","target":"\#(token)"}"#])
    }

    /// Omission clears a custom name in herdr 0.7.5. JSON null is not the wire
    /// contract: this assertion distinguishes an absent key from a present null.
    @Test("agent rename omits name when clearing a custom name")
    func agentRenameOmitsNameWhenClearingACustomName() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("wire")
        try await transport.renameAgent(AgentRenameParams(target: token))

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(recorded == [#"agent.rename {"target":"\#(token)"}"#])
    }

    /// Workspace labels accept a wider grammar than Agent names. Pin both the
    /// label and snake-cased workspace id at the real Transport boundary.
    @Test("workspace rename sends its label and workspace id exactly")
    func workspaceRenameSendsItsLabelAndWorkspaceIDExactly() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("wire")
        try await transport.renameWorkspace(
            WorkspaceRenameParams(label: "Review workspace", workspaceID: token))

        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(
            recorded
                == [
                    #"workspace.rename {"label":"Review workspace","workspace_id":"\#(token)"}"#
                ])
    }

    /// `pane.read` has no cursor and the options choose what herdr samples.
    /// Assert both directions: exact params into herdr, typed result back out.
    @Test("pane read sends exact params and round trips the result")
    func paneReadSendsExactParamsAndRoundTripsTheResult() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        let token = Self.scriptToken("wire")
        let read = try await transport.readPane(
            PaneReadParams(
                paneID: token,
                source: .recentUnwrapped,
                format: .ansi,
                lines: 5,
                stripANSI: false))

        #expect(read.paneID == token)
        #expect(read.source == .recentUnwrapped)
        #expect(read.format == .ansi)
        #expect(read.text == "fixture output")
        #expect(read.revision == 1)
        #expect(!read.truncated)
        let recorded = try await Self.recordedRequests(from: transport, token: token)
        #expect(
            recorded
                == [
                    #"pane.read {"format":"ansi","lines":5,"pane_id":"\#(token)","source":"recent_unwrapped","strip_ansi":false}"#
                ])
    }

    /// A syntactically valid herdr error envelope is not a channel failure.
    /// Numeric codes normalize to strings in the Transport's domain error.
    @Test("a herdr error envelope surfaces as a typed API rejection")
    func herdrErrorEnvelopeSurfacesAsATypedAPIRejection() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let transport = try await WaycarSSHTransport.connect(
            settings: environment.directSettings())
        defer { Task { try? await transport.close() } }

        await #expect(throws: HerdrAPIError(code: "500", message: "scripted failure")) {
            try await transport.renameAgent(
                AgentRenameParams(target: "api-error", name: "reviewer"))
        }
    }

    /// The session boundary converts the Transport's typed herdr rejection to
    /// the public failure taxonomy that drives reconnect and user guidance.
    /// The rejected set is installed as a live one: a seed (the initial set,
    /// #105) falls back to the global set once on any rejection, which would
    /// connect before the mapping is ever observed.
    @Test("the session maps a herdr rejection to apiRejected")
    func eventsSessionMapsAHerdrRejectionToAPIRejected() async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let settings = environment.directSettings()
        let session = EventsSession(
            subscriptions: [],
            connect: { try await WaycarSSHTransport.connect(settings: settings) },
            reconnectPolicy: ReconnectPolicy(
                initialDelay: .seconds(30), multiplier: 1, maxDelay: .seconds(30)),
            keepalive: nil)
        await session.updateSubscriptions(
            [.pane(.agentStatusChanged, paneID: "fixture:reject")])
        var updates = session.updates.makeAsyncIterator()

        await session.resume()
        #expect(await updates.next() == .status(.connecting))
        let update = try #require(await updates.next())
        guard case .status(
            .reconnecting(
                attempt: 1,
                delay: .seconds(30),
                failure: .apiRejected(
                    code: "fixture_rejected",
                    message: "scripted rejection"))) = update
        else {
            Issue.record("Expected apiRejected reconnect status, got \(update)")
            await session.end()
            return
        }
        await session.end()
    }

    /// What the `startfails` script answers `agent.start` with. Any code but
    /// `agent_pane_busy` takes the compensating path, so the fixture uses one
    /// of its own rather than guessing at herdr's — 0.7.5's refusal of an
    /// unsupported kind is recorded by its message alone.
    private static let refusedStart = HerdrAPIError(
        code: "fixture_agent_start_refused",
        message: "scripted non-retryable agent.start failure")

    /// One scripted run of the fixture, keyed so its recorded requests cannot
    /// be confused with another test's. The behavior word steers the fixture;
    /// see `scripts/fixtures/fake-herdr-streamlocal.py`.
    private static func scriptToken(_ behavior: String) -> String {
        "fixture:\(behavior):\(UUID().uuidString.lowercased())"
    }

    /// What the launch-race fixture records when an `agent.get` past its
    /// deadline clears the managed name instead of promoting the launch.
    private static let launchNameCleared = "fixture.launch_name_cleared"

    /// Direct settings whose post-start settle outlives the test, so a
    /// stalled runner cannot slip its `agent.get` into an exact request list.
    private static func settingsWithoutLaunchSettle(
        _ environment: WaycarSSHTransportBehaviorEnvironment
    ) -> SSHTransportSettings {
        var settings = environment.directSettings()
        settings.launchSettleDelay = .seconds(600)
        return settings
    }

    /// Prompts `paneID` until herdr stops answering `agent_not_ready`, with no
    /// nudge or `agent.get` of its own, failing with herdr's refusal once
    /// `deadline` has passed.
    private static func promptOnceLaunchSettles(
        _ transport: WaycarSSHTransport,
        paneID: String,
        until deadline: ContinuousClock.Instant
    ) async throws -> Agent {
        let params = AgentPromptParams(target: paneID, text: "fixture prompt")
        while true {
            do {
                return try await transport.promptAgent(params)
            } catch let error as HerdrAPIError
                where error.code == "agent_not_ready" && ContinuousClock.now < deadline
            {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// Every request the fixture served under `token`, in order, as
    /// `<method> <compact-json-params>`.
    private static func recordedRequests(
        from transport: WaycarSSHTransport,
        token: String
    ) async throws -> [String] {
        let read = try await transport.readPane(
            PaneReadParams(paneID: "record:\(token)", source: .recent))
        return read.text.split(separator: "\n").map(String.init)
    }

    /// The method of each recorded request, in order.
    private static func methods(_ recorded: [String]) -> [String] {
        recorded.map { String($0.prefix { $0 != " " }) }
    }

    /// The two launches that can start from the latest main.
    private enum WorktreeLaunchVariant {
        case agent
        case shell
    }

    private func exerciseLatestMainStartFromFetchedTip(
        _ variant: WorktreeLaunchVariant
    ) async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        let token = Self.scriptToken("ok")
        try await Self.withWorktreeSourceScratch(environment: environment, token: token) {
            host, root in
            let (staleHead, originTip) = try await Self.seedStaleCheckout(
                defaultBranch: "main", root: root, on: host)

            let transport = try await WaycarSSHTransport.connect(
                settings: environment.directSettings())
            defer { Task { try? await transport.close() } }
            try await Self.startLatestMainWorktree(variant, token: token, on: transport)

            let recorded = try await Self.recordedRequests(from: transport, token: token)
            try #require(recorded.count == 4)
            #expect(recorded[0] == #"worktree.list {"workspace_id":"workspace:\#(token)"}"#)
            #expect(
                recorded[1]
                    == #"worktree.create {"base":"\#(originTip)","branch":"task/\#(token)","focus":false,"workspace_id":"workspace:\#(token)"}"#)
            switch variant {
            case .agent:
                #expect(recorded[2].hasPrefix("tab.rename "))
                #expect(recorded[3].hasPrefix("agent.start "))
            case .shell:
                #expect(recorded[2].hasPrefix("tab.create "))
                #expect(recorded[3] == #"tab.close {"tab_id":"tab:\#(token)"}"#)
            }

            // The commit arrived in exactly that checkout, and no ref moved.
            let after = try await Self.runGit(
                """
                git -C "$c" rev-parse refs/heads/main HEAD refs/remotes/origin/main
                git -C "$c" cat-file -t \(originTip)
                """,
                root: root, on: host)
            #expect(after == [staleHead, staleHead, staleHead, "commit"])
        }
    }

    /// Direct fixture settings whose worktree create and reconcile budgets
    /// fit a test: the fixture's unanswered creates wait for the client to
    /// give up.
    private static func worktreeLaunchSettings(
        _ environment: WaycarSSHTransportBehaviorEnvironment
    ) -> SSHTransportSettings {
        var settings = environment.directSettings()
        settings.worktreeCreateTimeout = .sshdBudget(3)
        settings.worktreeReconcileBudget = .sshdBudget(10)
        settings.worktreeReconcileInterval = .milliseconds(200)
        return settings
    }

    /// One worktree agent launch of `codex` named `fixture`, from the source
    /// Workspace `source:<token>` (which carries the token into the
    /// fixture's `worktree.list`) on branch `task/<token>`: how it ended, the
    /// steps it reported, and the requests the fixture recorded for it.
    /// Reading those records ends the fixture's script for `token`.
    private static func launchWorktreeAgent(
        on transport: WaycarSSHTransport,
        token: String,
        branchIsGenerated: Bool = false,
        base: WorktreeBase = .sourceHead,
        attempt: WorktreeLaunchAttempt = WorktreeLaunchAttempt(),
        environment: [String: String] = [:]
    ) async throws -> (result: Result<Agent, any Error>, steps: [LaunchStep], recorded: [String]) {
        let steps = LaunchStepLog()
        let result: Result<Agent, any Error>
        do {
            result = .success(
                try await steps.recording {
                    try await transport.startAgentInNewWorktree(
                        AgentLaunchRequest(
                            kind: "codex", name: "fixture", workspaceID: "source:\(token)",
                            environment: environment),
                        worktree: WorktreeSpec(
                            branch: "task/\(token)", base: base,
                            branchIsGenerated: branchIsGenerated),
                        attempt: attempt)
                })
        } catch {
            result = .failure(error)
        }
        let recorded = try await recordedRequests(from: transport, token: token)
        return (result, steps.all, recorded)
    }

    private static func startLatestMainWorktree(
        _ variant: WorktreeLaunchVariant,
        token: String,
        branch: String? = nil,
        on transport: WaycarSSHTransport
    ) async throws {
        let worktree = WorktreeSpec(
            branch: branch ?? "task/\(token)", base: .latestDefaultBranch)
        switch variant {
        case .agent:
            let agent = try await transport.startAgentInNewWorktree(
                AgentLaunchRequest(
                    kind: "codex",
                    name: "fixture",
                    workspaceID: "workspace:\(token)"),
                worktree: worktree,
                attempt: WorktreeLaunchAttempt())
            #expect(agent.paneID == "pane:\(token)")
        case .shell:
            let shell = try await transport.startShellTerminalInNewWorktree(
                ShellLaunchRequest(name: "fixture", workspaceID: "workspace:\(token)"),
                worktree: worktree,
                attempt: WorktreeLaunchAttempt())
            #expect(shell.workspaceID == "workspace:\(token)")
        }
    }

    /// A bare origin whose HEAD names `defaultBranch`, a source checkout
    /// cloned from it (then adjusted by `afterClone`), and a second commit
    /// pushed to origin that the checkout has never fetched. Returns the
    /// checkout's HEAD, which is also its local `defaultBranch`, and origin's
    /// new tip.
    private static func seedStaleCheckout(
        defaultBranch: String,
        afterClone: String = ":",
        root: String,
        on host: SSHConnection
    ) async throws -> (staleHead: String, originTip: String) {
        let lines = try await runGit(
            """
            git init --quiet --bare --initial-branch=\(defaultBranch) "$r/origin.git"
            git init --quiet --initial-branch=\(defaultBranch) "$r/seed"
            git -C "$r/seed" commit --quiet --allow-empty -m first
            git -C "$r/seed" push --quiet "$r/origin.git" \(defaultBranch)
            git clone --quiet "$r/origin.git" "$c"
            \(afterClone)
            git -C "$r/seed" commit --quiet --allow-empty -m second
            git -C "$r/seed" push --quiet "$r/origin.git" \(defaultBranch)
            git -C "$c" rev-parse refs/heads/\(defaultBranch) HEAD
            git -C "$r/origin.git" rev-parse refs/heads/\(defaultBranch)
            """,
            root: root, on: host)
        try #require(lines.count == 3)
        try #require(lines[0] == lines[1])
        try #require(lines[0] != lines[2])
        return (lines[0], lines[2])
    }

    /// Runs `body` with an exec connection to the fixture Host and the scratch
    /// root the fixture's scripted `worktree.list` answers under for `token`
    /// (its source checkout is `$c` in ``runGit(_:root:on:)``), then deletes
    /// that root on the Host whether or not `body` threw.
    private static func withWorktreeSourceScratch(
        environment: WaycarSSHTransportBehaviorEnvironment,
        token: String,
        _ body: (SSHConnection, String) async throws -> Void
    ) async throws {
        let unique = try #require(token.split(separator: ":").last)
        let root = (environment.countFilePath as NSString).deletingLastPathComponent
            + "/worktree-\(unique)"
        let host = try await environment.hostConnection()
        let outcome: Result<Void, any Error>
        do {
            try await body(host, root)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        let removal = try? await runGit(#"rm -rf "$r""#, root: root, on: host)
        try? await host.close(timeout: .sshdBudget(2))
        try outcome.get()
        try #require(removal != nil, "scratch \(root) was not removed")
    }

    /// Runs a newline-separated `/bin/sh -e` script on the fixture Host with
    /// the scratch root as `$r` and the source checkout the fixture reports
    /// as `$c`, git isolated from the account's own config, and returns its
    /// stdout lines. A failing step fails the test with git's stderr. The
    /// script must not contain a single quote.
    private static func runGit(
        _ script: String,
        root: String,
        on host: SSHConnection
    ) async throws -> [String] {
        precondition(!script.contains("'"), "the Host script is single-quoted")
        let quotedRoot = try #require(RemoteShellPath.quotedAbsolute(root))
        let prelude = [
            "set -e",
            "export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1",
            "export GIT_AUTHOR_NAME=Waycar GIT_AUTHOR_EMAIL=ci@waycar.invalid",
            "export GIT_COMMITTER_NAME=Waycar GIT_COMMITTER_EMAIL=ci@waycar.invalid",
            #"r=$1; q=$(printf "\047"); c="$r/it${q}s a \"checkout\" \\ dir"; mkdir -p "$r""#,
        ].joined(separator: "\n")
        let result = try await host.execute(
            "/bin/sh -c '\(prelude)\n\(script)' worktree-source \(quotedRoot)",
            timeout: .sshdBudget(30))
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        try #require(result.reachedEOF && result.exitStatus == 0, "Host script failed: \(stderr)")
        return String(decoding: result.stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map(String.init)
    }

    private func exerciseProductionConnector(host: Host) async throws {
        let environment = try #require(WaycarSSHTransportBehaviorEnvironment.current)
        var settings = SSHTransportSettings(
            host: host,
            credentials: environment.credentials,
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true })
        settings.wakesInLoginSession = false

        let transport = try await SSHTransportConnector().connect(settings: settings)
        defer { Task { try? await transport.close() } }

        #expect(transport is WaycarSSHTransport)
        #expect(try await transport.ping() == ServerInfo(version: "fake", protocolVersion: 17))
        #expect(try await transport.listAgents().isEmpty)
    }

    private func exerciseOrdinaryRPCs(settings: SSHTransportSettings) async throws {
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        #expect(try await transport.ping() == ServerInfo(version: "fake", protocolVersion: 17))
        #expect(try await transport.listAgents().isEmpty)
        #expect(try await transport.sessionSnapshot().agents.isEmpty)
        #expect(
            try await transport.readPane(PaneReadParams(paneID: "pane-1", source: .recent)).text
                == "fixture output")
        let agentRead = try await transport.readAgent(
            AgentReadParams(
                source: .visible, target: "pane-1", format: .ansi,
                stripANSI: false))
        #expect(agentRead.text == "\u{1B}[31mfixture agent output\u{1B}[0m")
        #expect(agentRead.source == .visible)
        #expect(agentRead.format == .ansi)
        let prompted = try await transport.promptAgent(
            AgentPromptParams(target: "pane-1", text: "fixture prompt"))
        #expect(prompted.paneID == "pane-1")
        #expect(prompted.status == .working)
        try await transport.sendAgentKeys(
            AgentSendKeysParams(keys: ["ctrl+c", "enter"], target: "pane-1"))
        try await transport.closePane(PaneTarget(paneID: "pane-1"), closesWorktreeGroup: false)
        try await transport.renameAgent(AgentRenameParams(target: "pane-1", name: "fixture"))
        try await transport.renameWorkspace(
            WorkspaceRenameParams(label: "Fixture", workspaceID: "workspace-1"))
        #expect(
            try await transport.startAgent(
                AgentLaunchRequest(
                    kind: "codex",
                    name: "fixture",
                    workspaceID: "workspace-1"))
                .paneID == "pane-new")
        #expect(
            try await transport.startAgentInNewWorktree(
                AgentLaunchRequest(
                    kind: "codex",
                    name: "fixture-worktree",
                    workspaceID: "workspace-1"),
                worktree: WorktreeSpec(branch: "task/fixture", base: .ref("main")),
                attempt: WorktreeLaunchAttempt())
                .workspaceID == "workspace-worktree")
        #expect(
            try await transport.startAgentInNewWorkspace(
                AgentLaunchRequest(kind: "codex", name: "fixture-workspace"),
                workspace: NewWorkspaceSpec(directory: "/tmp/project", label: "Fixture"))
                .workspaceID == "workspace-new")
        await #expect(
            throws: HerdrAPIError(
                code: "500",
                message: "scripted failure")
        ) {
            try await transport.renameAgent(
                AgentRenameParams(target: "api-error", name: "fixture"))
        }
    }

    private func exerciseNotificationFiles(
        settings baseSettings: SSHTransportSettings,
        homePath: String
    ) async throws {
        let configDirectory =
            "\(homePath)/.waycar-ci/notify-\(UUID().uuidString.lowercased())"
        let quotedDirectory = try #require(RemoteShellPath.quotedAbsolute(configDirectory))

        var missingSettings = baseSettings
        missingSettings.pluginListCommand =
            "printf '%s' '{\"id\":\"cli:plugin\",\"result\":{\"plugins\":[]}}'"
        missingSettings.notificationConfigDirCommand = "/bin/sh -c 'exit 99'"
        let missingTransport = try await WaycarSSHTransport.connect(settings: missingSettings)
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            _ = try await missingTransport.readNotificationRegistration()
        }
        try await missingTransport.close()

        var settings = baseSettings
        settings.pluginListCommand =
            "printf '%s' '{\"id\":\"cli:plugin\",\"result\":{\"plugins\":["
            + "{\"plugin_id\":\"\(SSHTransportSettings.notificationPluginID)\",\"enabled\":true}]}}'"
        settings.notificationConfigDirCommand =
            "/bin/sh -c 'umask 077; mkdir -p \"$1\" || exit 1; "
            + "printf \"__WAYCAR_PLUGIN_CONFIG_DIR__=%s\\n\" \"$1\"' notify "
            + quotedDirectory
        settings.sessionListCommand = notificationInspectionCommand(
            quotedDirectory: quotedDirectory)

        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        #expect(try await transport.readNotificationRegistration() == nil)
        #expect(try await transport.readNotificationConfig() == nil)
        #expect(try await transport.readSidebarLayout() == nil)

        let snapshot = Data(
            #"{"v":1,"agent_panel_sort":"priority","sidebar":{"agents":{"row_gap":0,"rows":[[{"token":"agent"}]],"rows_by_agent":{}}}}"#
                .utf8)
        try await transport.replacePluginConfigFileForTesting(
            named: WaycarSSHTransport.sidebarLayoutFileName,
            contents: snapshot)
        #expect(try await transport.readSidebarLayout() == snapshot)

        let firstRegistration = Data(
            #"{"v":1,"devices":[{"token":"private-device-token","key":"private-notification-key"}]}"#.utf8)
        try await transport.replaceNotificationRegistration(firstRegistration)
        #expect(try await transport.readNotificationRegistration() == firstRegistration)

        let configuration = Data(
            #"{"relay_url":"https://relay.example.test/","future_knob":"kept"}"#.utf8)
        try await transport.replaceNotificationConfig(configuration)
        let decodedConfiguration = try NotificationConfigFile.decode(
            try await transport.readNotificationConfig())
        #expect(decodedConfiguration.relayURL == "https://relay.example.test")

        let previousLive = Data(#"{"v":1,"devices":[]}"#.utf8)
        try await transport.replaceNotificationRegistration(previousLive)
        #expect(try await transport.readNotificationRegistration() == previousLive)

        await transport.delayNextNotificationSFTPWriteForTesting(.seconds(60))
        let cancellation = Task {
            try await transport.replaceNotificationRegistration(
                Data(repeating: 0x61, count: 1_024 * 1_024))
        }
        let writeEntryDeadline = ContinuousClock.now + .waitCeiling
        var activeState = await transport.notificationFileStateForTesting()
        while !activeState.writeIsDelayed, ContinuousClock.now < writeEntryDeadline {
            try await Task.sleep(for: .milliseconds(10))
            activeState = await transport.notificationFileStateForTesting()
        }
        try #require(activeState.writeIsDelayed)
        #expect(activeState.activeClientCount == 1)
        #expect(activeState.ordinarySessionCount == 1)
        #expect(activeState.connectionChannelCount == 1)
        #expect(activeState.temporaryPaths.count == 1)
        let temporaryPath = try #require(activeState.temporaryPaths.first)

        let cancellationStarted = ContinuousClock.now
        cancellation.cancel()
        await #expect(throws: TransportError.cancelled) {
            try await cancellation.value
        }
        #expect(cancellationStarted.duration(to: .now) < .waitCeiling, "cancel must not wait out the delayed write")

        let settledState = await transport.notificationFileStateForTesting()
        #expect(!settledState.writeIsDelayed)
        #expect(settledState.activeClientCount == 0)
        #expect(settledState.temporaryPaths.isEmpty)
        #expect(settledState.ordinarySessionCount == 0)
        #expect(settledState.connectionChannelCount == 0)
        #expect(try await transport.readRemoteFileForTesting(at: temporaryPath) == nil)
        #expect(
            try await transport.readNotificationRegistration() == previousLive)

        _ = try await transport.listSessions()
        do {
            try await transport.replaceNotificationRegistration(
                Data("replacement".utf8))
            Issue.record("A failed atomic rename unexpectedly succeeded.")
        } catch let error as NotificationRegistrationError {
            guard case .writeFailed = error else {
                Issue.record("Expected writeFailed, got \(error).")
                return
            }
        }
        _ = try await transport.listSessions()

        try await transport.close()
        do {
            _ = try await transport.readNotificationRegistration()
            Issue.record("A disconnected notification read unexpectedly succeeded.")
        } catch let error as NotificationRegistrationError {
            guard case .readFailed = error else {
                Issue.record("Expected readFailed, got \(error).")
                return
            }
        }
        do {
            try await transport.replaceNotificationConfig(Data("{}".utf8))
            Issue.record("A disconnected notification write unexpectedly succeeded.")
        } catch let error as NotificationRegistrationError {
            guard case .writeFailed = error else {
                Issue.record("Expected writeFailed, got \(error).")
                return
            }
        }
    }

    private func notificationInspectionCommand(quotedDirectory: String) -> String {
        "/bin/sh -c 'directory=$1; "
            + "mode() { stat -c \"%a\" \"$1\" 2>/dev/null || stat -f \"%Lp\" \"$1\"; }; "
            + "if [ ! -e \"$directory/.failure-mode\" ]; then "
            + "[ \"$(mode \"$directory\")\" = 700 ] || exit 31; "
            + "[ \"$(mode \"$directory/notifications.json\")\" = 600 ] || exit 32; "
            + "[ \"$(mode \"$directory/notify.json\")\" = 600 ] || exit 33; "
            + "[ -z \"$(find \"$directory\" -maxdepth 1 -name \"*.tmp-*\" -print -quit)\" ] "
            + "|| exit 34; "
            + "rm -f \"$directory/notifications.json\" || exit 35; "
            + "mkdir \"$directory/notifications.json\" || exit 36; "
            + "touch \"$directory/.failure-mode\" || exit 37; "
            + "else "
            + "[ -d \"$directory/notifications.json\" ] || exit 38; "
            + "[ -z \"$(find \"$directory\" -maxdepth 1 -name \"*.tmp-*\" -print -quit)\" ] "
            + "|| exit 39; "
            + "chmod 700 \"$directory\"; rm -rf -- \"$directory\" || exit 40; "
            + "fi; printf \"{\\\"sessions\\\":[]}\\n\"' inspect "
            + quotedDirectory
    }

    private func exerciseEventsStream(settings: SSHTransportSettings) async throws {
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }

        #expect(try await transport.ping().protocolVersion == 17)
        let stream = try await transport.subscribeToEvents([.global(.paneCreated)])
        await #expect(throws: TransportError.eventsChannelAlreadyOpen) {
            _ = try await transport.subscribeToEvents([.global(.paneCreated)])
        }

        try await withThrowingTaskGroup(of: ServerInfo.self) { group in
            for _ in 0..<WaycarSSHTransport.maxConcurrentForwardingChannels {
                group.addTask { try await transport.ping() }
            }
            for try await info in group {
                #expect(info.protocolVersion == 17)
            }
        }

        var iterator = stream.events.makeAsyncIterator()
        let unknown = try await iterator.next()
        #expect(unknown?.kind == HerdrEventKind(name: "future_herdr_event"))
        #expect(unknown?.data["value"] == .string("preserved"))

        let canonical = try await iterator.next()
        #expect(canonical?.kind == GlobalEventKind.paneCreated.kind)
        #expect(canonical?.data["pane_id"] == .string("fixture:event"))
        #expect(try await iterator.next() == canonical)

        await stream.end()
        let replacement = try await transport.subscribeToEvents([.global(.paneCreated)])
        await replacement.end()
        #expect(try await transport.ping().protocolVersion == 17)
    }

    private func exerciseRPCDoesNotStallAttach(
        settings: SSHTransportSettings
    ) async throws {
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        let session = try await transport.attachTerminal(
            TerminalAttachRequest(
                target: "fixture:pane",
                takeover: true,
                cols: 80,
                rows: 24))
        var iterator = session.output.makeAsyncIterator()
        var output = ""
        try await expectAttachOutput(&iterator, accumulated: &output, contains: "24 80")
        #expect(output.hasPrefix("TTY-OK"))

        var observerSettings = settings
        observerSettings.requestTimeout = .seconds(25)
        let observer = try await WaycarSSHTransport.connect(settings: observerSettings)
        defer { Task { try? await observer.close() } }

        let delayToken = UUID().uuidString
        let delayedStarted = ContinuousClock.now
        let delayedCompletion = RPCCompletionFlag()
        let delayed = Task {
            let result = try await transport.readPane(
                PaneReadParams(paneID: "fixture:delay:\(delayToken)", source: .recent))
            await delayedCompletion.markCompleted()
            return result
        }
        defer { delayed.cancel() }
        let observation = try await observer.readPane(
            PaneReadParams(paneID: "fixture:await-delay:\(delayToken)", source: .recent))
        try #require(observation.text == "observed")

        let echoStarted = ContinuousClock.now
        let marker = "rpc-hol-\(UUID().uuidString.prefix(8))"
        session.send(Data("\(marker)\n".utf8))
        try await expectAttachOutput(
            &iterator,
            accumulated: &output,
            contains: "GOT:\(marker)")
        let echoElapsed = echoStarted.duration(to: .now)
        #expect(await delayedCompletion.completed == false)
        #expect(echoElapsed < .seconds(2), "Attach echoed in \(echoElapsed)")

        let delayedResult = try await delayed.value
        #expect(await delayedCompletion.completed)
        #expect(delayedResult.text == "delayed")
        // The fixture holds a `fixture:delay:` read for 3 s.
        #expect(delayedStarted.duration(to: .now) >= .seconds(2.7))
        #expect(try await transport.ping().protocolVersion == 17)
        await session.end()
        #expect(await transport.isConnected)
    }

    private func exerciseAttach(
        settings: SSHTransportSettings,
        socketPath: String
    ) async throws {
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        let session = try await transport.attachTerminal(
            TerminalAttachRequest(
                target: "fixture:pane",
                takeover: true,
                cols: 80,
                rows: 24))
        var iterator = session.output.makeAsyncIterator()
        var output = ""
        try await expectAttachOutput(&iterator, accumulated: &output, contains: "24 80")
        #expect(output.hasPrefix("TTY-OK"))
        #expect(output.contains("ARGS:fixture:pane --takeover"))
        #expect(output.contains("SOCKET:\(socketPath)"))
        #expect(!output.contains("HERDR_SOCKET_PATH"))
        #expect(!output.contains("waycar-attach"))

        session.send(Data("raw-\u{1B}[A\n".utf8))
        try await expectAttachOutput(
            &iterator,
            accumulated: &output,
            contains: "GOT:raw-\u{1B}[A")
        session.resize(cols: 109, rows: 47)
        session.send(Data("probe\n".utf8))
        try await expectAttachOutput(&iterator, accumulated: &output, contains: "47 109")

        session.send(Data("__end_race__\n".utf8))
        try await expectAttachOutput(
            &iterator,
            accumulated: &output,
            contains: "END-RACE-READY")
        // The fixture writes another chunk after one second, then waits ten
        // seconds before a final chunk. Sleeping two seconds deliberately
        // leaves the first tail unread and the second scheduled after end.
        try await Task.sleep(for: .seconds(2))
        let started = ContinuousClock.now
        await session.end()
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(try await iterator.next() == nil)
        #expect(try await transport.ping().protocolVersion == 17)

        let replacement = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:replacement", cols: 80, rows: 24))
        await replacement.end()
    }

    private func exerciseShellTerminalAttach(
        settings: SSHTransportSettings,
        socketPath: String
    ) async throws {
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        let session = try await transport.attachTerminal(
            TerminalAttachRequest(
                target: .terminal("fixture:terminal"),
                takeover: true,
                cols: 80,
                rows: 24))
        var iterator = session.output.makeAsyncIterator()
        var output = ""
        try await expectAttachOutput(&iterator, accumulated: &output, contains: "24 80")
        #expect(output.hasPrefix("TTY-OK"))
        #expect(output.contains("ARGS:fixture:terminal --takeover"))
        #expect(output.contains("SOCKET:\(socketPath)"))

        session.send(Data("shell-input\n".utf8))
        try await expectAttachOutput(
            &iterator,
            accumulated: &output,
            contains: "GOT:shell-input")
        session.resize(cols: 101, rows: 43)
        session.send(Data("probe\n".utf8))
        try await expectAttachOutput(&iterator, accumulated: &output, contains: "43 101")
        await session.end()
        #expect(try await transport.ping().protocolVersion == 17)
    }

    private func exerciseCleanAttachExit(settings: SSHTransportSettings) async throws {
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        let session = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:clean", cols: 80, rows: 24))
        var iterator = session.output.makeAsyncIterator()
        var output = ""
        try await expectAttachOutput(&iterator, accumulated: &output, contains: "TTY-OK")
        session.send(Data("__exit__\n".utf8))
        while let chunk = try await iterator.next() {
            output += String(decoding: chunk, as: UTF8.self)
        }

        let replacement = try await transport.attachTerminal(
            TerminalAttachRequest(target: "fixture:replacement", cols: 80, rows: 24))
        await replacement.end()
        #expect(try await transport.ping().protocolVersion == 17)
    }

    private func expectAttachOutput(
        _ iterator: inout AsyncThrowingStream<Data, any Error>.AsyncIterator,
        accumulated: inout String,
        contains marker: String
    ) async throws {
        while !accumulated.contains(marker) {
            let chunk = try #require(try await iterator.next())
            accumulated += String(decoding: chunk, as: UTF8.self)
        }
    }

    private func exerciseHostExecOperations(
        settings: SSHTransportSettings,
        homePath: String
    ) async throws {
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        #expect(try await transport.ping().protocolVersion == 17)
        #expect(try await transport.listSessions().map(\.name) == ["fixture"])
        #expect(try await transport.availableAgentKinds() == [.codex, .gemini])
        let skills = try await transport.listSkills(SkillListQuery(kind: .codex))
        let skill = try #require(skills.first { $0.name == "fixture" })
        #expect(skill.path == "\(homePath)/.codex/skills/fixture/SKILL.md")
        #expect(try await transport.readSkillFile(atPath: skill.path).contains("Fixture body."))
    }

    private static let installedPluginListCommand =
        "printf '%s' '{\"id\":\"cli:plugin\",\"result\":{\"plugins\":["
        + "{\"plugin_id\":\"\(SSHTransportSettings.notificationPluginID)\",\"enabled\":true}]}}'"

    /// The `NotificationRegistrationError` a registration read raises on a
    /// Host connected with `settings`, or nil if the read succeeded.
    private func notificationRegistrationFailure(
        settings: SSHTransportSettings
    ) async throws -> NotificationRegistrationError? {
        let transport = try await WaycarSSHTransport.connect(settings: settings)
        defer { Task { try? await transport.close() } }
        do {
            _ = try await transport.readNotificationRegistration()
            return nil
        } catch let error as NotificationRegistrationError {
            return error
        }
    }

    private func expectPluginProbeFailure(
        settings: SSHTransportSettings,
        _ subject: String
    ) async throws {
        let failure = try await notificationRegistrationFailure(settings: settings)
        let error = try #require(
            failure,
            Comment(rawValue: "\(subject) must not read as success"))
        guard case .pluginProbeFailed = error else {
            Issue.record(
                Comment(rawValue: "\(subject) expected pluginProbeFailed, got \(error)"))
            return
        }
    }

    private func connectionCount(from transport: WaycarSSHTransport) async throws -> Int {
        let session = try #require(try await transport.listSessions().first)
        return try #require(Int(session.name.dropFirst("count-".count)))
    }
}

private actor WorktreeWireBoundaryRecorder {
    private(set) var authorized: [WorktreeRemovalRequest] = []
    private(set) var dispatched: [WorktreeRemovalRequest] = []

    func authorize(_ request: WorktreeRemovalRequest) {
        authorized.append(request)
    }

    func recordDispatch(_ request: WorktreeRemovalRequest) {
        dispatched.append(request)
    }
}

struct WaycarSSHTransportBehaviorEnvironment: Sendable {
    let host: String
    let port: UInt16
    let username: String
    let deviceKey: Curve25519.Signing.PrivateKey
    let rsaKey: RSAKey
    let socketPath: String
    let staleSocketPath: String
    let wakeFailureStaleSocketPath: String
    let countFilePath: String
    let homePath: String
    let jumpPort: UInt16
    let targetHost: String
    let targetPort: UInt16
    /// The unprivileged impairment proxy in front of the direct fixture sshd,
    /// and the control port that steers it. Optional in the wire format so an
    /// older fixture still decodes; the weak-network suite `#require`s them, so
    /// under the merge gate a fixture without a proxy fails rather than skips.
    let weakNetworkPort: UInt16?
    let weakNetworkControlPort: UInt16?

    static let current: WaycarSSHTransportBehaviorEnvironment? = {
        guard
            let directEncoded = ProcessInfo.processInfo.environment["WAYCAR_SSH_E2E_CONFIG"],
            let directData = Data(base64Encoded: directEncoded),
            let jumpEncoded = ProcessInfo.processInfo.environment["WAYCAR_SSH_JUMP_E2E_CONFIG"],
            let jumpData = Data(base64Encoded: jumpEncoded),
            let direct = try? JSONDecoder().decode(DirectFixture.self, from: directData),
            let jump = try? JSONDecoder().decode(JumpFixture.self, from: jumpData),
            let deviceKey = try? RealSSHFixture.deviceKey(seed: direct.deviceKeySeed),
            let rsaKeyData = Data(base64Encoded: direct.rsaKeyDER),
            let rsaKey = try? RSAKey(privateKeyDER: rsaKeyData)
        else { return nil }
        return WaycarSSHTransportBehaviorEnvironment(
            host: direct.host,
            port: direct.port,
            username: direct.username,
            deviceKey: deviceKey,
            rsaKey: rsaKey,
            socketPath: direct.socketPath,
            staleSocketPath: direct.staleSocketPath,
            wakeFailureStaleSocketPath: direct.wakeFailureStaleSocketPath,
            countFilePath: direct.countFilePath,
            homePath: direct.homePath,
            jumpPort: jump.jumpPort,
            targetHost: jump.targetHost,
            targetPort: jump.targetPort,
            weakNetworkPort: direct.weakNetworkPort,
            weakNetworkControlPort: direct.weakNetworkControlPort)
    }()

    /// The fixture authorizes one throwaway Device Key. Everything but the two
    /// dedicated password tests authenticates with it, which is also what a real
    /// Host does.
    var credentials: SSHCredentials { .ed25519(deviceKey) }

    /// A bare exec connection to the direct fixture, for Host-side setup the
    /// Transport has no business exposing (building real git repositories).
    func hostConnection() async throws -> SSHConnection {
        let key = DeviceKey(privateKey: deviceKey)
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: host, port: port), timeout: .sshdBudget(5))
        do {
            try await connection.authenticate(
                username: username,
                publicKey: key.publicKeyBlob,
                signer: { data in try key.privateKey.signature(for: data) },
                timeout: .sshdBudget(5))
            return connection
        } catch {
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
    }

    func directSettings(
        socket: HerdrSocketLocation? = nil
    ) -> SSHTransportSettings {
        settings(
            host: host,
            port: port,
            credentials: credentials,
            jump: nil,
            socket: socket)
    }

    func rsaSettings() -> SSHTransportSettings {
        settings(
            host: host,
            port: port,
            credentials: .rsaSHA512(rsaKey),
            jump: nil,
            socket: nil)
    }

    func jumpRSASettings() -> SSHTransportSettings {
        let credentials = SSHCredentials.rsaSHA512(rsaKey)
        return settings(
            host: targetHost,
            port: targetPort,
            credentials: credentials,
            jump: SSHJumpSettings(
                host: host,
                port: Int(jumpPort),
                username: username,
                credentials: credentials),
            socket: nil)
    }

    func jumpSettings(
        socket: HerdrSocketLocation? = nil
    ) -> SSHTransportSettings {
        let credentials = self.credentials
        return settings(
            host: targetHost,
            port: targetPort,
            credentials: credentials,
            jump: SSHJumpSettings(
                host: host,
                port: Int(jumpPort),
                username: username,
                credentials: credentials),
            socket: socket)
    }

    /// The same direct fixture reached through the impairment proxy, so the
    /// whole SSH byte stream — RPC, SFTP, PTY and the forwarded herdr socket
    /// alike — crosses a link the test controls.
    func weakNetworkSettings(
        port: UInt16,
        socket: HerdrSocketLocation? = nil
    ) -> SSHTransportSettings {
        settings(
            host: host,
            port: port,
            credentials: credentials,
            jump: nil,
            socket: socket)
    }

    /// A catalog Host for the direct fixture, exactly as onboarding would save
    /// it: a blank session name resolves the default socket over the Host's own
    /// home directory.
    func directHost() -> Host {
        Host(
            name: "Fixture",
            address: host,
            port: Int(port),
            username: username,
            authMethod: .deviceKey)
    }

    /// The same fixture reached through the Jump Host hop. Both hops share the
    /// account and credential, which is what the Host model already assumes.
    func jumpHost() -> Host {
        Host(
            name: "Fixture behind a Jump Host",
            address: targetHost,
            port: Int(targetPort),
            username: username,
            authMethod: .deviceKey,
            jumpAddress: host,
            jumpPort: Int(jumpPort))
    }

    private func settings(
        host: String,
        port: UInt16,
        credentials: SSHCredentials,
        jump: SSHJumpSettings?,
        socket: HerdrSocketLocation?
    ) -> SSHTransportSettings {
        var settings = SSHTransportSettings(
            host: host,
            port: Int(port),
            username: username,
            credentials: credentials,
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            socket: socket ?? .absolutePath(socketPath),
            jump: jump)
        settings.sessionListCommand =
            "printf '%s\\n' '{\"sessions\":[{\"name\":\"fixture\","
            + "\"default\":true,\"running\":true}]}'"
        settings.agentDiscoveryCommand =
            "printf '__WAYCAR_AGENT_KIND__=codex\\n__WAYCAR_AGENT_KIND__=gemini\\n'"
        // The fixture's codex knows --no-daemon, as every supported Codex
        // does, whatever codex the Mac running the suite has installed.
        settings.codexHelpCommand = "printf '%s\\n' '      --no-daemon'"
        settings.wakesInLoginSession = false
        settings.detectionSearchesSystemDirectories = false
        guard let quotedHome = RemoteShellPath.quotedAbsolute(homePath) else {
            return settings
        }
        settings.homeCommand =
            "/bin/sh -c 'printf \"__WAYCAR_HOME__=%s\\n\" \"$1\"' home \(quotedHome)"
        settings.attachCommand = "\(homePath)/.waycar-ci/fake-attach"
        settings.terminalAttachCommand = "\(homePath)/.waycar-ci/fake-attach"
        settings.stageDirectoryCommand =
            "/bin/sh -c 'umask 077; "
            + "directory=$(mktemp -d \"$1/waycar.XXXXXXXX\") || exit 1; "
            + "printf \"__WAYCAR_STAGE_DIR__=%s\\n\" \"$directory\"' stage \(quotedHome)/.waycar-ci"
        return settings
    }

    var connectionCountCommand: String {
        let path = RemoteShellPath.quotedAbsolute(countFilePath) ?? "''"
        return "/bin/sh -c 'count=$(cat \"$1\"); "
            + "printf \"{\\\"sessions\\\":[{\\\"name\\\":\\\"count-%s\\\","
            + "\\\"default\\\":true,\\\"running\\\":true}]}\\n\" \"$count\"' count \(path)"
    }

    /// The fixture's `$HOME`, appending one byte to `path` per run. With a
    /// hold, the exec keeps running that many seconds after it counts, so
    /// requests sent meanwhile find the probe in flight.
    func countingHomeCommand(_ path: String, holdSeconds: Int = 0) -> String {
        let quotedPath = RemoteShellPath.quotedAbsolute(path) ?? "''"
        let quotedHome = RemoteShellPath.quotedAbsolute(homePath) ?? "''"
        let hold = holdSeconds > 0 ? "sleep \(holdSeconds); " : ""
        return "/bin/sh -c 'printf x >> \"$1\"; \(hold)"
            + "printf \"__WAYCAR_HOME__=%s\\n\" \"$2\"' home \(quotedPath) \(quotedHome)"
    }

    /// `countingHomeCommand` whose first run (an empty count) answers a
    /// relative home, which fails resolution. Every run holds `holdSeconds`
    /// before it answers.
    func failOnceHomeCommand(_ path: String, holdSeconds: Int) -> String {
        let quotedPath = RemoteShellPath.quotedAbsolute(path) ?? "''"
        let quotedHome = RemoteShellPath.quotedAbsolute(homePath) ?? "''"
        return "/bin/sh -c 'count=$(wc -c < \"$1\" 2>/dev/null || printf 0); "
            + "printf x >> \"$1\"; sleep \(holdSeconds); if [ \"$count\" -eq 0 ]; then "
            + "printf \"__WAYCAR_HOME__=relative\\n\"; else "
            + "printf \"__WAYCAR_HOME__=%s\\n\" \"$2\"; fi' home \(quotedPath) \(quotedHome)"
    }

    func countAssertionCommand(_ path: String, expected: Int) -> String {
        let quoted = RemoteShellPath.quotedAbsolute(path) ?? "''"
        return "/bin/sh -c '[ \"$(wc -c < \"$1\")\" -eq \"$2\" ] && "
            + "printf \"__WAYCAR_AGENT_KIND__=codex\\n\"' count \(quoted) \(expected)"
    }

    func resetStaleSocketCommand(_ path: String) -> String {
        let quoted = RemoteShellPath.quotedAbsolute(path) ?? "''"
        return "/usr/bin/python3 -c 'import os,socket,sys; p=sys.argv[1]; "
            + "os.path.lexists(p) and os.unlink(p); s=socket.socket(socket.AF_UNIX); "
            + "s.bind(p); s.close()' \(quoted); "
            + "printf '%s\\n' '{\"sessions\":[]}'"
    }

    var linkWakeCommand: String {
        let active = RemoteShellPath.quotedAbsolute(socketPath) ?? "''"
        return "rm -f \"$HERDR_SOCKET_PATH\"; "
            + "ln -s \(active) \"$HERDR_SOCKET_PATH\""
    }

    private struct DirectFixture: Decodable {
        let host: String
        let port: UInt16
        let username: String
        let deviceKeySeed: String
        let rsaKeyDER: String
        let socketPath: String
        let staleSocketPath: String
        let wakeFailureStaleSocketPath: String
        let countFilePath: String
        let homePath: String
        let weakNetworkPort: UInt16?
        let weakNetworkControlPort: UInt16?
    }

    private struct JumpFixture: Decodable {
        let jumpPort: UInt16
        let targetHost: String
        let targetPort: UInt16
    }
}

/// The requests a fixture worktree launch script for `token` records, as
/// `recordedRequests` spells them. The launch starts from `source:<token>`
/// on `task/<token>`; its worktree is `workspace:<token>` with tab
/// `tab:<token>` and root pane `pane:<token>` at `/tmp/worktree/<token>`.
private struct WorktreeLaunchWire {
    let list: String
    let create: String
    let snapshot = "session.snapshot {}"
    let agentList = "agent.list {}"
    let rename: String
    /// `agent.start` on `pane:<token>`: the worktree's root pane, and also
    /// the pane the fixture's `tab.create` answers with.
    let rootAgentStart: String
    /// The Agent's tab in an adopted worktree.
    let adoptedTab: String
    let paneClose: String
    let remove: String

    init(token: String) {
        list = #"worktree.list {"workspace_id":"source:\#(token)"}"#
        create =
            #"worktree.create {"branch":"task/\#(token)","focus":false,"workspace_id":"source:\#(token)"}"#
        rename = #"tab.rename {"label":"fixture","tab_id":"tab:\#(token)"}"#
        rootAgentStart =
            #"agent.start {"args":["--no-daemon"],"kind":"codex","name":"fixture","pane_id":"pane:\#(token)"}"#
        adoptedTab =
            #"tab.create {"cwd":"/tmp/worktree/\#(token)","focus":false,"label":"fixture","workspace_id":"workspace:\#(token)"}"#
        paneClose = #"pane.close {"pane_id":"pane:\#(token)"}"#
        remove = #"worktree.remove {"workspace_id":"workspace:\#(token)"}"#
    }
}

/// Collects the steps `LaunchProgress` reports while `recording` runs.
final class LaunchStepLog: Sendable {
    private let steps = Mutex<[LaunchStep]>([])

    var all: [LaunchStep] { steps.withLock { $0 } }

    func recording<Result: Sendable>(
        _ operation: () async throws -> Result
    ) async throws -> Result {
        try await LaunchProgress.$reporter.withValue({ step in
            self.steps.withLock { $0.append(step) }
        }) {
            try await operation()
        }
    }
}

private actor RPCCompletionFlag {
    private(set) var completed = false

    func markCompleted() {
        completed = true
    }
}
