import Foundation
import Synchronization
import Testing
import WaycarSSH

@testable import Waycar

/// Waycar's Host Tools on a herdr-core Host: the same registration, config,
/// summary, Chat Mode and hooks members tmux has, served by `CoreTransport`
/// through `HostToolsTransport` over a Host with no herdr plugin.
@Suite("herdr-core Host Tools", .timeLimit(.minutes(1)))
struct CoreHostToolsTests {
    static let cli = "/home/me/.local/bin/waycar"
    static let toolsRoot = "/home/me/.local/share/waycar/plugin"
    static let configDirectory = "/xdg/waycar"

    /// A Host with core and no herdr: its Host tools probe answers `cli` and
    /// `root`, the login PATH exec answers, and `rule`s answer the rest by
    /// substring (the latest rule for a substring wins).
    private final class ScriptedHost: Sendable {
        private let rules = Mutex<[(String, SSHExecResult)]>([])
        private let probe: String

        init(cli: String = CoreHostToolsTests.cli, root: String = CoreHostToolsTests.toolsRoot) {
            probe = TmuxSummariesChatTests.probeOutput(
                pluginList: "", pluginDirs: [:], cli: cli, root: root)
        }

        func rule(_ match: String, _ result: SSHExecResult) {
            rules.withLock { rules in
                rules.removeAll { $0.0 == match }
                rules.append((match, result))
            }
        }

        var handler: FakeHostSSHServices.ExecHandler {
            { [self] command, input in
                if command == CoreLoginPath.command {
                    return CoreTransportTests.loginPathExec(command, input)
                }
                if command.contains("herdr plugin list") {
                    return FakeHostSSHServices.result(stdout: probe)
                }
                for (match, result) in rules.withLock({ $0 }) where command.contains(match) {
                    return result
                }
                return FakeHostSSHServices.result()
            }
        }
    }

    private static func open(
        _ host: ScriptedHost
    ) async throws -> (transport: CoreTransport, session: FakeHostSSHServices) {
        let rig = try await CoreTransportTests.open(CoreTransportTests.channel(), exec: host.handler)
        return (rig.transport, rig.session)
    }

    private static let request = ChatTranscriptRequest(
        paneID: "hc:t7", kind: "claude", sessionKind: "path",
        sessionValue: "/home/me/.claude/projects/r/abc.jsonl", cwd: "/home/me/repo",
        launchedAt: nil, status: .working, after: nil)

    // MARK: Registration and config

    @Test func registrationAndConfigLiveInTheHostToolsConfigDirectory() async throws {
        let (transport, session) = try await Self.open(ScriptedHost())
        let registration = Data(#"{"v":1}"#.utf8)
        let config = Data(#"{"core_enabled":true}"#.utf8)

        #expect(try await transport.readNotificationRegistration() == nil)
        try await transport.replaceNotificationRegistration(registration)
        try await transport.replaceNotificationConfig(config)

        let registrationPath =
            "\(Self.configDirectory)/\(WaycarSSHTransport.notificationRegistrationFileName)"
        let configPath = "\(Self.configDirectory)/\(WaycarSSHTransport.notificationConfigFileName)"
        #expect(await session.files[registrationPath] == registration)
        #expect(await session.files[configPath] == config)
        #expect(try await transport.readNotificationRegistration() == registration)
        #expect(try await transport.readNotificationConfig() == config)
        // One probe serves every call of the connection.
        #expect(await session.execs(containing: "herdr plugin list").count == 1)
        try await transport.close()
    }

    @Test func aHostWithoutHostToolsIsPluginNotInstalledEverywhere() async throws {
        let (transport, session) = try await Self.open(ScriptedHost(cli: "", root: ""))
        let marker = ChatModeMarker(
            paneID: "hc:t7", terminalID: nil, kind: "claude", cwd: nil, session: nil,
            launchedAt: Date(timeIntervalSince1970: 1_790_000_000))

        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await transport.readNotificationRegistration()
        }
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await transport.replaceNotificationConfig(Data())
        }
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await transport.readAgentSummaries()
        }
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await transport.refreshAgentSummaries()
        }
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await transport.readChatModeMarkers()
        }
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await transport.writeChatModeMarker(marker)
        }
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await transport.readChatTranscript(Self.request)
        }
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await transport.statusHooksReport()
        }
        #expect(await session.execs(containing: "hooks status").isEmpty)
        try await transport.close()
    }

    @Test func aClosedTransportServesNoHostToolsCall() async throws {
        let (transport, session) = try await Self.open(ScriptedHost())
        try await transport.close()

        await #expect(throws: TransportError.cancelled) {
            try await transport.readNotificationRegistration()
        }
        await #expect(throws: TransportError.cancelled) {
            try await transport.readAgentSummaries()
        }
        #expect(await session.execs(containing: "herdr plugin list").isEmpty)
    }

    // MARK: Summaries

    @Test func summariesOfCoreTerminalsComeFromTheSharedStore() async throws {
        let host = ScriptedHost()
        host.rule("/summaries\"", FakeHostSSHServices.result(stdout: [
            #"{"v":1,"pane":"hc:t7","status":"blocked","summary":"Wants to run rm","ts":2000,"hash":"ab"}"#,
            #"{"v":1,"pane":"tmux:%4","status":"idle","summary":null,"ts":3000,"hash":null}"#,
        ].joined(separator: "\n") + "\n"))
        let (transport, _) = try await Self.open(host)

        let summaries = try await transport.readAgentSummaries()
        #expect(summaries["hc:t7"]?.text == "Wants to run rm")
        #expect(summaries["hc:t7"]?.status == .blocked)
        #expect(summaries.keys.sorted() == ["hc:t7"])
        try await transport.close()
    }

    @Test func refreshRunsTheHostToolsCLI() async throws {
        let (transport, session) = try await Self.open(ScriptedHost())

        try await transport.refreshAgentSummaries()
        let exec = try #require(await session.execs(containing: "summaries refresh").first)
        #expect(exec.command.hasSuffix(" '\(Self.cli)'"))
        try await transport.close()
    }

    // MARK: Chat Mode

    @Test func chatMarkersOfCoreTerminalsAreWrittenReadAndDeleted() async throws {
        let marker = ChatModeMarker(
            paneID: "hc:t7", terminalID: "hc:b16ea034:t7", kind: "claude", cwd: "/home/me/repo",
            session: .init(kind: "id", value: "abc"),
            launchedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let host = ScriptedHost()
        host.rule("/chat\"", FakeHostSSHServices.result(
            stdout: String(decoding: try JSONEncoder().encode(marker), as: UTF8.self) + "\n"))
        let (transport, session) = try await Self.open(host)

        try await transport.writeChatModeMarker(marker)
        let path = "\(Self.configDirectory)/chat/\(ChatModeMarker.fileName(paneID: "hc:t7"))"
        let written = try #require(await session.files[path])
        #expect(try JSONDecoder().decode(ChatModeMarker.self, from: written) == marker)

        #expect(try await transport.readChatModeMarkers() == [marker])

        try await transport.deleteChatModeMarker(paneID: "hc:t7")
        #expect(await session.files[path] == nil)
        try await transport.close()
    }

    @Test func aCoreAgentsTranscriptIsReadFromTheHostToolsRoot() async throws {
        let host = ScriptedHost()
        host.rule("src/chat-read.js", FakeHostSSHServices.result(stdout: [
            #"{"type":"header","v":1,"kind":"claude","status":"ok","transcript":"/home/me/.claude/projects/r/abc.jsonl","activity":null,"turn_open":false,"truncated":false,"error":null}"#,
            #"{"type":"message","id":"u1","role":"user","text":"is it green?","ts":"2026-09-30T12:00:01Z"}"#,
        ].joined(separator: "\n") + "\n"))
        let (transport, session) = try await Self.open(host)

        let snapshot = try await transport.readChatTranscript(Self.request)
        #expect(snapshot.header.status == .ok)
        #expect(snapshot.messages.map(\.id) == ["u1"])
        let exec = try #require(await session.execs(containing: "src/chat-read.js").first)
        #expect(exec.command == HostSSHSession.cLocaleCommand(
            WaycarSSHTransport.chatTranscriptReadCommand(quotedPluginRoot: "'\(Self.toolsRoot)'")))
        let body = try #require(
            try JSONSerialization.jsonObject(with: Data(exec.input.utf8)) as? [String: Any])
        #expect(body["kind"] as? String == "claude")
        #expect(body["session_value"] as? String == "/home/me/.claude/projects/r/abc.jsonl")
        #expect(body["cwd"] as? String == "/home/me/repo")
        #expect(body["status"] as? String == "working")
        try await transport.close()
    }

    // MARK: Status hooks

    @Test func theHooksReportCarriesTheCoreBackend() async throws {
        let host = ScriptedHost()
        host.rule("hooks status --json", FakeHostSSHServices.result(stdout: """
            {"version":1,"hostTools":{"version":"2.2.1","pluginRoot":"\(Self.toolsRoot)"},\
            "backends":{"herdr":false,"tmux":null,"core":"0.1.14"},"configDir":"\(Self.configDirectory)",\
            "agents":[{"agent":"claude","installed":true,"configPath":"/home/me/.claude/settings.json",\
            "needsCodexReview":null}]}

            """))
        let (transport, session) = try await Self.open(host)

        let report = try await transport.statusHooksReport()
        #expect(report.backends == StatusHooksReport.Backends(herdr: false, tmux: nil, core: "0.1.14"))
        #expect(report.agents.map(\.agent) == ["claude"])
        let exec = try #require(await session.execs(containing: "hooks status --json").first)
        #expect(exec.command.hasSuffix(" '\(Self.cli)'"))
        try await transport.close()
    }

    @Test func aReportFromAnOlderPluginHasNoCoreBackend() throws {
        let old = Data("""
            {"version":1,"hostTools":{"version":"2.0.0","pluginRoot":"/r"},\
            "backends":{"herdr":true,"tmux":"3.4"},"configDir":null,"agents":[]}
            """.utf8)
        let report = try JSONDecoder().decode(StatusHooksReport.self, from: old)
        #expect(report.backends == StatusHooksReport.Backends(herdr: true, tmux: "3.4"))
        #expect(report.backends.core == nil)
    }

    // MARK: The terminal's session labels

    @Test func theHooksSessionLabelsBecomeTheAgentsSession() {
        func agent(_ labels: [String: String]) -> AgentInfo? {
            CoreSnapshotBuilder.agentInfo(
                for: CoreTerminal(
                    address: "t7", labels: labels, argv: ["claude"], cwd: "/home/me/repo",
                    state: "live", status: CoreStatus(state: "idle", app: "claude-code"),
                    reported: true),
                core: nil, overlay: CoreDoneOverlayMachine())
        }

        #expect(agent([:])?.agentSession == nil)
        #expect(agent(["waycar.session": "abc"])?.agentSession
            == AgentSessionInfo(agent: "claude", kind: .id, source: "core", value: "abc"))
        #expect(agent(["waycar.session": "/home/me/.codex/sessions/s.jsonl"])?.agentSession?.kind
            == .path)
        // The transcript path stands in until a session id is written, and
        // the session wins once both are.
        #expect(agent(["waycar.transcript": "/home/me/t.jsonl"])?.agentSession
            == AgentSessionInfo(
                agent: "claude", kind: .path, source: "core", value: "/home/me/t.jsonl"))
        #expect(agent(["waycar.session": "abc", "waycar.transcript": "/home/me/t.jsonl"])?
            .agentSession?.value == "abc")
        #expect(agent(["waycar.session": "  ", "waycar.transcript": ""])?.agentSession == nil)
    }
}
