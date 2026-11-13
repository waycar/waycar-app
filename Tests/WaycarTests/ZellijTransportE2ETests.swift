import CryptoKit
import Foundation
import Testing
import WaycarSSH

@testable import Waycar

/// The pinned Zellij behind the iOS lane's disposable, real sshd. Nothing
/// reaches the runner's HOME or sockets. Without the fixture these tests
/// skip; CI runs this suite separately with an exact count and no skips.
@Suite(
    "Zellij Transport e2e",
    .enabled(if: ZellijE2EEnvironment.current != nil, "requires the disposable Zellij sshd fixture"),
    .serialized)
struct ZellijTransportE2ETests {
    @Test
    func fixtureIsIsolated() async throws {
        try await withHost { host in
            let home = try await host.shell("printf %s \"$HOME\"")
            let socketDir = try await host.shell("printf %s \"$ZELLIJ_SOCKET_DIR\"")
            #expect(home == host.environment.fixture.home)
            #expect(socketDir == host.environment.fixture.socketDir)
            let resolvedBinary = try await host.shell("command -v zellij")
            #expect(resolvedBinary.trimmingCharacters(in: .whitespacesAndNewlines)
                == host.environment.fixture.zellij)
            let before = try await host.serverPIDs()
            #expect(before.isEmpty, "fixture already has a Zellij server: \(before)")
            let version = try await host.zellij("--version")
            #expect(version.exitStatus == 0)
            #expect(String(decoding: version.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "zellij 0.46.0")
            let listing = try await host.zellij("ls", "-n")
            #expect(listing.exitStatus == 1)
            #expect(String(decoding: listing.stdout + listing.stderr, as: UTF8.self)
                .contains("No active zellij sessions found."))
            let after = try await host.serverPIDs()
            #expect(after.isEmpty, "read-only commands started a Zellij server: \(after)")
        }
    }

    @Test
    func backgroundSessionListsPanes() async throws {
        try await withHost { host in
            let start = try await host.zellij("attach", "-b", host.session, "--", "fake-osc-agent")
            try #require(start.exitStatus == 0, "\(String(decoding: start.stderr, as: UTF8.self))")
            try await waitUntil("background pane reports the fake agent's root Idle status") {
                let result = try await host.zellij("-s", host.session, "action", "list-panes", "-j")
                try #require(result.exitStatus == 0, "\(String(decoding: result.stderr, as: UTF8.self))")
                // Zellij can return empty stdout with exit 0 during startup.
                guard !result.stdout.isEmpty else { return false }
                let panes = try JSONDecoder().decode([ZellijFixturePane].self, from: result.stdout)
                return panes.contains { pane in
                    !pane.is_plugin && (pane.program_status ?? []).contains {
                        $0.id == nil && $0.state == "Idle" && $0.app == "pi"
                    }
                }
            }
        }
    }

    @Test func transportInventoryStatusAndPromptExactlyOnce() async throws {
        try await withHost { host in
            _ = try await host.zellij("attach", "-b", host.session, "--", "fake-osc-agent")
            try await withTransport(host.environment) { transport in
                try await waitUntil { try await transport.listAgents().first?.status == .idle }
                let agent = try #require(try await transport.listAgents().first)
                #expect(agent.kind == "pi")
                // Background panes start at 50 columns: keep the complete reply on one row.
                let text = "HOLD-" + UUID().uuidString.prefix(8)
                _ = try await transport.promptAgent(AgentPromptParams(target: agent.paneID, text: text))
                try await waitUntil { try await transport.listAgents().first?.status == .working }
                _ = try await host.shell(": > \"$HOME/run/fake-osc-release\"")
                try await waitUntil { try await transport.listAgents().first?.status == .done }
                let read = try await transport.readAgent(AgentReadParams(source: .recent, target: agent.paneID, lines: 200))
                #expect(read.text.components(separatedBy: "fake-reply: " + text).count - 1 == 1)
            }
        }
    }

    @Test(arguments: [false, true])
    func newAgentWithAndWithoutDeskAndReconcileByTag(withClient: Bool) async throws {
        try await withHost { host in
            _ = try await host.zellij("attach", "-b", host.session, "--", "fake-osc-agent")
            try await host.waitForPane()
            let launch: () async throws -> Void = {
                try await withTransport(host.environment) { transport in
                    let tag = UUID()
                    let name = "launch-" + UUID().uuidString.prefix(8)
                    let request = AgentLaunchRequest(
                        kind: "fake-osc-agent", name: name, workspaceID: "zellij:" + host.session,
                        cwd: host.environment.fixture.home, launchID: tag)
                    let agent = try await transport.startAgent(request)
                    let pane = try #require(ZellijPaneID(agent.paneID))
                    #expect((pane.session == host.session) == withClient)
                    let rows = try await host.panes(session: pane.session)
                    let launched = rows.first { ZellijLaunchReconciliation.carries(tag: tag.uuidString, command: $0.terminalCommand ?? "") }
                    #expect(launched != nil)
                    // The Agent's name is its tab's name, in a new tab and a background session alike.
                    #expect(launched?.tabName == name)
                    let again = try await transport.startAgent(AgentLaunchRequest(
                        kind: request.kind, name: request.name, workspaceID: request.workspaceID,
                        cwd: request.cwd, launchID: tag, mayHaveStarted: true))
                    #expect(again.paneID == agent.paneID)
                    let after = try await host.panes(session: pane.session)
                    #expect(after.filter { ZellijLaunchReconciliation.carries(tag: tag.uuidString, command: $0.terminalCommand ?? "") }.count == 1)
                }
            }
            if withClient { try await withDesk(host) { try await launch() } }
            else { try await launch() }
        }
    }

    @Test func exactPaneAttachLeavesDeskFocusAndSizeAlone() async throws {
        try await withHost { host in
            _ = try await host.zellij("attach", "-b", host.session, "--", "fake-osc-agent")
            try await host.waitForPane()
            try await withDesk(host) {
                let beforeClients = try await host.clients()
                let desk = try #require(beforeClients.first)
                let deskPane = try #require(try await host.panes().first { $0.isPlugin != true })
                let tabBefore = try #require(try await host.tabs().first { $0.tab_id == deskPane.tabID })
                _ = try await host.zellij("-s", host.session, "action", "new-tab", "--no-focus", "--name", "phone", "--", "fake-osc-agent")
                try await waitUntil { try await host.panes().contains { $0.isPlugin != true && $0.tabID != deskPane.tabID } }
                let target = try #require(try await host.panes().first { $0.isPlugin != true && $0.tabID != deskPane.tabID })
                try await withTransport(host.environment) { transport in
                    let targetID = "zellij:\(host.session)/terminal_\(target.id)"
                    try await waitUntil { try await transport.sessionSnapshot().panes.contains { $0.paneID == targetID } }
                    let phone = try await transport.attachTerminal(TerminalAttachRequest(target: targetID, cols: 80, rows: 30))
                    let outcome: Result<Void, any Error>
                    do {
                        try await waitUntil {
                            let clients = try await host.clients()
                            return clients.count == 2 && clients.max(by: { $0.id < $1.id })?.pane == "terminal_\(target.id)"
                        }
                        try await waitUntil {
                            try await host.tabs().first { $0.tab_id == target.tabID }?.viewport_columns == 80
                        }
                        #expect(try await host.clients().first { $0.id == desk.id }?.pane == desk.pane)
                        let tabAfter = try #require(try await host.tabs().first { $0.tab_id == deskPane.tabID })
                        #expect(tabAfter.viewport_columns == tabBefore.viewport_columns)
                        #expect(tabAfter.viewport_rows == tabBefore.viewport_rows)
                        outcome = .success(())
                    } catch { outcome = .failure(error) }
                    await phone.end()
                    try outcome.get()
                }
            }
        }
    }

    @Test func closedSessionIsListedAndDeletedWithoutResurrection() async throws {
        try await withHost { host in
            _ = try await host.zellij("attach", "-b", host.session, "--", "fake-osc-agent")
            try await host.waitForPane()
            let pane = try #require(try await host.panes().first { $0.isPlugin != true })
            let marker = "saved-" + UUID().uuidString
            _ = try await host.zellij("-s", host.session, "action", "set-resurrect-command", "--pane-id", "terminal_\(pane.id)", "--", "/bin/echo", marker)
            // Zellij serializes the session into its cache: ~/.cache/zellij on Linux,
            // ~/Library/Caches/org.Zellij-Contributors.Zellij on macOS (CI's sshd). Either may
            // not exist yet, which is "not yet", not a failure.
            try await waitUntil {
                try await !host.shell(
                    "grep -rl \(ShellWord.quoted(marker)) \"$HOME/.cache\" \"$HOME/Library/Caches\" 2>/dev/null || true"
                ).isEmpty
            }
            try await withTransport(host.environment) { transport in
                _ = try await host.zellij("kill-session", host.session)
                try await waitUntil { try await transport.closedZellijSessions(refreshAge: false).contains { $0.name == host.session } }
                let closed = try await transport.closedZellijSessions(refreshAge: true)
                #expect(closed.first { $0.name == host.session }?.age != nil)
                #expect(try await host.serverPIDs().isEmpty)
                try await transport.deleteZellijSession(host.session)
                try await waitUntil { try await !transport.closedZellijSessions(refreshAge: true).contains { $0.name == host.session } }
                #expect(try await host.serverPIDs().isEmpty)
            }
        }
    }

    private func withTransport(
        _ environment: ZellijE2EEnvironment, _ body: (ZellijTransport) async throws -> Void
    ) async throws {
        let session = try await HostSSHSession.dial(settings: environment.settings())
        let transport: ZellijTransport
        do {
            transport = try await ZellijTransport.open(
                session: session, presence: ZellijPresence(version: "0.46.0", path: environment.fixture.zellij),
                configuration: .init(requestTimeout: .sshdBudget(15)))
        } catch { await session.release(); throw error }
        let outcome: Result<Void, any Error>
        do { try await body(transport); outcome = .success(()) }
        catch { outcome = .failure(error) }
        try await transport.close()
        try outcome.get()
    }

    private func withDesk(_ host: ZellijFixtureHost, _ body: () async throws -> Void) async throws {
        let session = try await HostSSHSession.dial(settings: host.environment.settings())
        let commands = try ZellijCommand(zellij: host.environment.fixture.zellij)
        let terminal: TerminalAttachSession
        do {
            terminal = try await session.attachTerminal(command: commands.attach(session: host.session),
                request: TerminalAttachRequest(target: "desk", cols: 200, rows: 50))
        } catch { await session.release(); throw error }
        let reader = Task { for try await _ in terminal.output {} }
        let outcome: Result<Void, any Error>
        do {
            try await waitUntil {
                let clients = try await host.clients()
                let tabs = try await host.tabs()
                return clients.count == 1 && tabs.contains { $0.viewport_columns == 200 }
            }
            try await body()
            outcome = .success(())
        } catch { outcome = .failure(error) }
        await terminal.end()
        reader.cancel()
        _ = try? await reader.value
        await session.release()
        try outcome.get()
    }

    private func withHost(_ body: (ZellijFixtureHost) async throws -> Void) async throws {
        let environment = try #require(ZellijE2EEnvironment.current)
        let host = try await ZellijFixtureHost.open(environment)
        let outcome: Result<Void, any Error>
        do {
            try await body(host)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        do {
            try await host.cleanUp()
        } catch {
            await host.close()
            throw error
        }
        await host.close()
        try outcome.get()
    }
}

private struct ZellijE2EEnvironment: Sendable {
    let fixture: Fixture
    let deviceKey: Curve25519.Signing.PrivateKey

    static let current: ZellijE2EEnvironment? = {
        guard
            let encoded = ProcessInfo.processInfo.environment["WAYCAR_ZELLIJ_E2E_CONFIG"],
            let data = Data(base64Encoded: encoded),
            let fixture = try? JSONDecoder().decode(Fixture.self, from: data),
            let deviceKey = try? RealSSHFixture.deviceKey(seed: fixture.deviceKeySeed)
        else { return nil }
        return ZellijE2EEnvironment(fixture: fixture, deviceKey: deviceKey)
    }()

    func settings() -> SSHTransportSettings {
        var settings = SSHTransportSettings(
            host: fixture.host, port: Int(fixture.port), username: fixture.username,
            credentials: .ed25519(deviceKey),
            hostKeyPolicy: HostKeyPolicy(knownHosts: InMemoryKnownHostsStore()) { _ in true },
            socket: .defaultSession)
        settings.requestTimeout = .sshdBudget(15)
        settings.wakesInLoginSession = false
        settings.detectionSearchesSystemDirectories = false
        return settings
    }

    struct Fixture: Decodable, Sendable {
        let host: String
        let port: UInt16
        let username: String
        let deviceKeySeed: String
        let zellij: String
        let home: String
        let socketDir: String
    }
}

private struct ZellijFixturePane: Decodable {
    let is_plugin: Bool
    let program_status: [ProgramStatus]?

    struct ProgramStatus: Decodable {
        let id: String?
        let state: String
        let app: String?
    }
}

private actor ZellijFixtureHost {
    nonisolated let environment: ZellijE2EEnvironment
    nonisolated let session = "e2e-\(UUID().uuidString.lowercased().prefix(8))"
    private let connection: SSHConnection

    private init(environment: ZellijE2EEnvironment, connection: SSHConnection) {
        self.environment = environment
        self.connection = connection
    }

    static func open(_ environment: ZellijE2EEnvironment) async throws -> ZellijFixtureHost {
        let settings = environment.settings()
        let key = DeviceKey(privateKey: environment.deviceKey)
        let connection = try await SSHConnection.connect(
            to: SSHEndpoint(host: settings.host, port: environment.fixture.port),
            timeout: .sshdBudget(5))
        do {
            try await connection.authenticate(
                username: settings.username,
                publicKey: key.publicKeyBlob,
                signer: { data in try key.privateKey.signature(for: data) },
                timeout: .sshdBudget(5))
        } catch {
            try? await connection.close(timeout: .sshdBudget(2))
            throw error
        }
        let host = ZellijFixtureHost(environment: environment, connection: connection)
        _ = try await host.shell(
            "mkdir -p \"$HOME/.config/zellij\"; printf '%s\\n' 'serialization_interval 1' "
            + "'show_startup_tips false' 'show_release_notes false' > \"$HOME/.config/zellij/config.kdl\"")
        return host
    }

    func close() async {
        try? await connection.close(timeout: .sshdBudget(2))
    }

    func zellij(_ arguments: String...) async throws -> SSHExecResult {
        try await connection.execute(
            ([environment.fixture.zellij] + arguments).map(ShellWord.quoted).joined(separator: " "),
            timeout: .sshdBudget(15))
    }

    func shell(_ command: String) async throws -> String {
        let result = try await connection.execute(command, timeout: .sshdBudget(15))
        guard result.exitStatus == 0 else {
            throw ZellijE2EError.commandFailed(
                command: command, exitStatus: result.exitStatus,
                stderr: String(decoding: result.stderr, as: UTF8.self))
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    func panes(session name: String? = nil) async throws -> [ZellijPaneRecord] {
        let result = try await zellij("-s", name ?? session, "action", "list-panes", "-j")
        guard result.exitStatus == 0, !result.stdout.isEmpty else { return [] }
        return try JSONDecoder().decode([ZellijPaneRecord].self, from: result.stdout)
    }

    func waitForPane() async throws {
        try await waitUntil { try await self.panes().contains { $0.isPlugin != true && $0.rootStatus != nil } }
    }

    func clients() async throws -> [ZellijClient] {
        let result = try await zellij("-s", session, "action", "list-clients")
        return ZellijClients.parse(String(decoding: result.stdout, as: UTF8.self))
    }

    func tabs() async throws -> [ZellijFixtureTab] {
        let result = try await zellij("-s", session, "action", "list-tabs", "-j")
        return try JSONDecoder().decode([ZellijFixtureTab].self, from: result.stdout)
    }

    func serverPIDs() async throws -> String {
        // Exact executable/argument fields exclude this shell and awk itself.
        try await shell(
            "ps -axo pid=,command= | awk -v binary=\(ShellWord.quoted(environment.fixture.zellij)) "
                + "'$2 == binary && $3 == \"--server\" { print $1 }'")
    }

    func cleanUp() async throws {
        // This fixture's private HOME/socket directory contains only this serialized suite's sessions.
        let listing = try await zellij("ls", "-n")
        for row in ZellijSessionRecord.listing(String(decoding: listing.stdout, as: UTF8.self)) where !row.closed {
            _ = try await zellij("kill-session", row.name)
        }
        try await waitUntil("fixture Zellij servers exit after their sessions are killed") {
            try await self.serverPIDs().isEmpty
        }
        let closed = try await zellij("ls", "-n")
        for row in ZellijSessionRecord.listing(String(decoding: closed.stdout, as: UTF8.self)) where row.closed {
            _ = try await zellij("delete-session", row.name)
        }
        _ = try await shell("rm -f \"$HOME/run/fake-osc-release\"")
    }
}

private struct ZellijFixtureTab: Decodable, Sendable {
    let tab_id: Int
    let viewport_columns: Int
    let viewport_rows: Int
}

private enum ZellijE2EError: Error, CustomStringConvertible {
    case commandFailed(command: String, exitStatus: Int32, stderr: String)

    var description: String {
        switch self {
        case let .commandFailed(command, exitStatus, stderr):
            "\(command): exit \(exitStatus): \(stderr)"
        }
    }
}
