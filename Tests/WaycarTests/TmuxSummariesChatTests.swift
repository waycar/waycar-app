import Foundation
import Synchronization
import Testing
import WaycarSSH

@testable import Waycar

@Suite("tmux Agent Summaries and Chat Mode")
struct TmuxSummariesChatTests {
    static let toolsRoot = "/home/me/.local/share/waycar/plugin"
    static let cli = "/home/me/.local/bin/waycar"

    // MARK: Host tools

    @Test func pluginRootPrefersTheHostToolsOverTheHerdrPlugin() throws {
        let herdrList = #"{"result":{"plugins":[{"plugin_id":"waycar","enabled":true,"plugin_root":"/home/me/.config/herdr/plugins/waycar/src-root"}]}}"#
        let both = Self.probeOutput(
            pluginList: herdrList, pluginDirs: ["waycar": "/home/me/.config/herdr/plugins/waycar"],
            cli: Self.cli, root: Self.toolsRoot)
        #expect(try HostToolsService.hostTools(fromProbeOutput: both) == HostToolsLocation(
            configDirectory: "/home/me/.config/herdr/plugins/waycar", cli: Self.cli,
            pluginRoot: Self.toolsRoot))

        let herdrOnly = Self.probeOutput(
            pluginList: herdrList, pluginDirs: ["waycar": "/home/me/.config/herdr/plugins/waycar"],
            cli: "", root: "")
        #expect(try HostToolsService.hostTools(fromProbeOutput: herdrOnly).pluginRoot
            == "/home/me/.config/herdr/plugins/waycar/src-root")

        // A root the probe could not resolve, or one printed without a CLI,
        // is no root.
        let unresolved = Self.probeOutput(pluginList: "", pluginDirs: [:], cli: Self.cli, root: "")
        #expect(try HostToolsService.hostTools(fromProbeOutput: unresolved).pluginRoot == nil)
        let stray = Self.probeOutput(pluginList: "", pluginDirs: [:], cli: "", root: Self.toolsRoot)
        #expect(try HostToolsService.hostTools(fromProbeOutput: stray) == HostToolsLocation(
            configDirectory: nil, cli: nil))
    }

    // MARK: Agent Summaries

    @Test func summariesAreReadFromTheConfigDirInOneExec() async throws {
        let host = ScriptedHost()
        host.rule("/summaries\"", FakeHostSSHServices.result(stdout: [
            #"{"v":1,"pane":"tmux:%3","status":"working","summary":"Old","ts":1000,"hash":null}"#,
            #"{"v":1,"pane":"tmux:%3","status":"done","summary":"Tests pass","ts":2000,"hash":"ab"}"#,
            #"{"v":1,"pane":"tmux:%4","status":"idle","summary":null,"ts":3000,"hash":null}"#,
            "not json",
        ].joined(separator: "\n") + "\n"))
        let (transport, fake) = try await Self.open(host)

        let summaries = try await transport.readAgentSummaries()
        #expect(summaries == [
            "tmux:%3": AgentSummary(
                paneID: "tmux:%3", status: .done, text: "Tests pass", timestamp: 2000,
                declaresProgress: false)
        ])
        let exec = try #require(await fake.execs(containing: "/summaries\"").first)
        #expect(exec.command.hasPrefix("LC_ALL=C "))
        #expect(exec.command.hasSuffix(" waycar '/xdg/waycar'"))
        #expect(exec.command.contains("head -c 4096"))
        _ = try await transport.readAgentSummaries()
        #expect(await fake.execs(containing: "herdr plugin list").count == 1)
        try await transport.close()
    }

    @Test func aFailedSummaryReadIsAChannelFailure() async throws {
        let host = ScriptedHost()
        host.rule("/summaries\"", FakeHostSSHServices.result(exitStatus: 1))
        let (transport, _) = try await Self.open(host)
        await #expect(throws: TransportError.channelFailed(detail: "the Agent Summary read failed")) {
            try await transport.readAgentSummaries()
        }
        try await transport.close()
    }

    @Test(arguments: [
        (Int32(127), RefreshOutcome.pluginNotInstalled),
        (Int32(2), RefreshOutcome.actionUnavailable),
        (Int32(1), RefreshOutcome.failed),
        (Int32(0), RefreshOutcome.started),
    ])
    func refreshRunsTheCLIAndMapsItsStatus(status: Int32, expected: RefreshOutcome) async throws {
        let host = ScriptedHost()
        host.rule(
            "summaries refresh",
            FakeHostSSHServices.result(stderr: "waycar: unknown command: summaries", exitStatus: status))
        let (transport, fake) = try await Self.open(host)

        let outcome: RefreshOutcome
        do {
            try await transport.refreshAgentSummaries()
            outcome = .started
        } catch NotificationRegistrationError.pluginNotInstalled {
            outcome = .pluginNotInstalled
        } catch AgentSummaryRefreshError.actionUnavailable {
            outcome = .actionUnavailable
        } catch TransportError.channelFailed {
            outcome = .failed
        }
        #expect(outcome == expected)
        let exec = try #require(await fake.execs(containing: "summaries refresh").first)
        #expect(exec.command.hasSuffix(" '\(Self.cli)'"))
        // The refresh outlives the exec: its output never reaches the channel.
        #expect(exec.command.contains("summaries refresh </dev/null >/dev/null 2>&1 &"))
        try await transport.close()
    }

    @Test func summariesNeedTheHostToolsOrThePlugin() async throws {
        let host = ScriptedHost(cli: "", root: "")
        let (transport, fake) = try await Self.open(host)
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await transport.readAgentSummaries()
        }
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await transport.refreshAgentSummaries()
        }
        #expect(await fake.execs(containing: "summaries").isEmpty)
        try await transport.close()
    }

    // MARK: Chat Markers

    @Test func markersAreWrittenReadAndDeletedUnderChat() async throws {
        let marker = ChatModeMarker(
            paneID: "tmux:%3", terminalID: "tmux:%3@1790979932.4242", kind: "claude",
            cwd: "/home/me/repo",
            session: .init(kind: "id", value: "abc"),
            launchedAt: Date(timeIntervalSince1970: 1_790_000_000))
        let other = ChatModeMarker(
            paneID: "tmux:%7", terminalID: nil, kind: "codex", cwd: nil, session: nil,
            launchedAt: Date(timeIntervalSince1970: 1_790_000_100))
        let host = ScriptedHost()
        let lines = try [marker, other].map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        host.rule("/chat\"", FakeHostSSHServices.result(
            stdout: lines.joined(separator: "\n") + "\n" + #"{"v":2,"pane_id":"tmux:%9"}"# + "\n"))
        let (transport, fake) = try await Self.open(host)

        try await transport.writeChatModeMarker(marker)
        let path = "/xdg/waycar/chat/\(ChatModeMarker.fileName(paneID: "tmux:%3"))"
        let written = try #require(await fake.files[path])
        #expect(try JSONDecoder().decode(ChatModeMarker.self, from: written) == marker)

        #expect(try await transport.readChatModeMarkers() == [marker, other])
        let read = try #require(await fake.execs(containing: "/chat\"").first)
        #expect(read.command.hasPrefix("LC_ALL=C "))
        #expect(read.command.hasSuffix(" waycar '/xdg/waycar'"))

        try await transport.deleteChatModeMarker(paneID: "tmux:%3")
        #expect(await fake.files.keys.contains(path) == false)
        // Deleting an absent marker is fine.
        try await transport.deleteChatModeMarker(paneID: "tmux:%3")
        try await transport.close()
    }

    @Test func markersNeedTheHostToolsOrThePlugin() async throws {
        let host = ScriptedHost(cli: "", root: "")
        let (transport, _) = try await Self.open(host)
        let marker = ChatModeMarker(
            paneID: "tmux:%3", terminalID: nil, kind: "claude", cwd: nil, session: nil,
            launchedAt: Date(timeIntervalSince1970: 1_790_000_000))
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await transport.readChatModeMarkers()
        }
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await transport.writeChatModeMarker(marker)
        }
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await transport.deleteChatModeMarker(paneID: "tmux:%3")
        }
        try await transport.close()
    }

    // MARK: Transcripts

    @Test func transcriptRunsTheReaderFromTheHostToolsRoot() async throws {
        let host = ScriptedHost()
        host.rule("src/chat-read.js", FakeHostSSHServices.result(stdout: [
            #"{"type":"header","v":1,"kind":"claude","status":"ok","transcript":"/home/me/.claude/projects/r/abc.jsonl","activity":null,"turn_open":false,"truncated":false,"error":null}"#,
            #"{"type":"message","id":"u1","role":"user","text":"is it green?","ts":"2026-09-30T12:00:01Z"}"#,
        ].joined(separator: "\n") + "\n"))
        let (transport, fake) = try await Self.open(host)
        let request = ChatTranscriptRequest(
            paneID: "tmux:%3", kind: "claude", sessionKind: "path",
            sessionValue: "/home/me/.claude/projects/r/abc.jsonl", cwd: "/home/me/repo",
            launchedAt: nil, status: .working, after: "u0")

        let snapshot = try await transport.readChatTranscript(request)
        #expect(snapshot.header.status == .ok)
        #expect(snapshot.header.transcript == "/home/me/.claude/projects/r/abc.jsonl")
        #expect(snapshot.messages.map(\.id) == ["u1"])

        let exec = try #require(await fake.execs(containing: "src/chat-read.js").first)
        #expect(exec.command == HostSSHSession.cLocaleCommand(
            WaycarSSHTransport.chatTranscriptReadCommand(
                quotedPluginRoot: "'\(Self.toolsRoot)'")))
        let body = try #require(
            try JSONSerialization.jsonObject(with: Data(exec.input.utf8)) as? [String: Any])
        #expect(body["kind"] as? String == "claude")
        #expect(body["session_kind"] as? String == "path")
        #expect(body["session_value"] as? String == "/home/me/.claude/projects/r/abc.jsonl")
        #expect(body["cwd"] as? String == "/home/me/repo")
        #expect(body["status"] as? String == "working")
        #expect(body["after"] as? String == "u0")
        #expect(body["launched_at"] is NSNull)
        try await transport.close()
    }

    @Test func transcriptStatusesMapLikeHerdrs() async throws {
        let host = ScriptedHost()
        let (transport, _) = try await Self.open(host)
        let request = ChatTranscriptRequest(
            paneID: "tmux:%3", kind: "codex", sessionKind: nil, sessionValue: nil,
            cwd: "/home/me/repo", launchedAt: nil, status: nil, after: nil)

        host.rule("src/chat-read.js", FakeHostSSHServices.result(
            exitStatus: WaycarSSHTransport.chatReaderMissingStatus))
        await #expect(throws: ChatTranscriptError.readerUnavailable) {
            try await transport.readChatTranscript(request)
        }
        host.rule("src/chat-read.js", FakeHostSSHServices.result(exitStatus: HostWatchdog.stoppedStatus))
        await #expect(throws: TransportError.channelFailed(detail: "the chat transcript read ran too long")) {
            try await transport.readChatTranscript(request)
        }
        host.rule("src/chat-read.js", FakeHostSSHServices.result(stderr: "boom\n", exitStatus: 1))
        await #expect(throws: TransportError.channelFailed(detail: "the chat transcript read failed: boom")) {
            try await transport.readChatTranscript(request)
        }
        host.rule("src/chat-read.js", FakeHostSSHServices.result(stdout: "not a header\n"))
        await #expect(throws: ChatTranscriptError.malformedOutput) {
            try await transport.readChatTranscript(request)
        }
        try await transport.close()
    }

    @Test func transcriptNeedsAPluginRoot() async throws {
        let request = ChatTranscriptRequest(
            paneID: "tmux:%3", kind: "codex", sessionKind: nil, sessionValue: nil,
            cwd: nil, launchedAt: nil, status: nil, after: nil)

        let none = ScriptedHost(cli: "", root: "")
        let (bare, bareFake) = try await Self.open(none)
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await bare.readChatTranscript(request)
        }
        #expect(await bareFake.execs(containing: "chat-read").isEmpty)
        try await bare.close()

        let unresolved = ScriptedHost(cli: Self.cli, root: "")
        let (transport, fake) = try await Self.open(unresolved)
        await #expect(throws: NotificationRegistrationError.pluginProbeFailed(
            detail: "The Host tools did not report a usable plugin root.")
        ) {
            try await transport.readChatTranscript(request)
        }
        #expect(await fake.execs(containing: "chat-read").isEmpty)
        try await transport.close()
    }

    /// A plugin root or CLI the login shell cannot quote alike in POSIX sh
    /// and fish never reaches an exec.
    @Test func unquotableToolPathsNeverReachAnExec() async throws {
        let request = ChatTranscriptRequest(
            paneID: "tmux:%3", kind: "codex", sessionKind: nil, sessionValue: nil,
            cwd: nil, launchedAt: nil, status: nil, after: nil)
        let root = "/home/me/x\\'; touch /tmp/pwned; echo '"
        let host = ScriptedHost(cli: "/home/me/b\\in/waycar", root: root)
        let (transport, fake) = try await Self.open(host)

        await #expect(throws: NotificationRegistrationError.self) {
            try await transport.readChatTranscript(request)
        }
        await #expect(throws: TransportError.invalidDirectoryPath(path: "/home/me/b\\in/waycar")) {
            try await transport.refreshAgentSummaries()
        }
        #expect(await fake.execs(containing: "chat-read").isEmpty)
        #expect(await fake.execs(containing: "pwned").isEmpty)
        #expect(await fake.execs(containing: "b\\in").isEmpty)
        try await transport.close()
    }

    // MARK: Media

    static let mediaRequest = ChatMediaRequest.line(
        transcript: "/home/me/.claude/projects/r/abc.jsonl", offset: 1024,
        pointer: "/message/content/0/source/data", maxBytes: 8)

    @Test func mediaRunsTheReaderFromTheHostToolsRoot() async throws {
        let host = ScriptedHost()
        host.rule("src/chat-media.js", FakeHostSSHServices.result(stdout: "PNGBYTE"))
        let (transport, fake) = try await Self.open(host)

        let bytes = try await transport.readChatMedia(Self.mediaRequest)
        #expect(bytes == Data("PNGBYTE".utf8))

        let exec = try #require(await fake.execs(containing: "src/chat-media.js").first)
        #expect(exec.command == HostSSHSession.cLocaleCommand(
            WaycarSSHTransport.chatMediaReadCommand(
                quotedPluginRoot: "'\(Self.toolsRoot)'")))
        let body = try #require(
            try JSONSerialization.jsonObject(with: Data(exec.input.utf8)) as? [String: Any])
        #expect(body["transcript"] as? String == "/home/me/.claude/projects/r/abc.jsonl")
        #expect(body["offset"] as? Int == 1024)
        #expect(body["pointer"] as? String == "/message/content/0/source/data")
        #expect(body["max_bytes"] as? Int == 8)
        try await transport.close()
    }

    @Test func mediaStatusesMapLikeHerdrs() async throws {
        let host = ScriptedHost()
        let (transport, _) = try await Self.open(host)
        let request = Self.mediaRequest

        host.rule("src/chat-media.js", FakeHostSSHServices.result(
            exitStatus: WaycarSSHTransport.chatReaderMissingStatus))
        await #expect(throws: ChatMediaError.pluginOutdated) {
            try await transport.readChatMedia(request)
        }
        host.rule("src/chat-media.js", FakeHostSSHServices.result(
            exitStatus: WaycarSSHTransport.chatMediaUnavailableStatus))
        await #expect(throws: ChatMediaError.unavailable) {
            try await transport.readChatMedia(request)
        }
        host.rule("src/chat-media.js", FakeHostSSHServices.result(
            exitStatus: WaycarSSHTransport.chatMediaTooLargeStatus))
        await #expect(throws: ChatMediaError.tooLarge) {
            try await transport.readChatMedia(request)
        }
        host.rule("src/chat-media.js", FakeHostSSHServices.result(exitStatus: HostWatchdog.stoppedStatus))
        await #expect(throws: TransportError.channelFailed(detail: "the chat media read ran too long")) {
            try await transport.readChatMedia(request)
        }
        host.rule("src/chat-media.js", FakeHostSSHServices.result(stderr: "boom", exitStatus: 1))
        await #expect(throws: TransportError.channelFailed(detail: "the chat media read failed: boom")) {
            try await transport.readChatMedia(request)
        }
        host.rule("src/chat-media.js", FakeHostSSHServices.result(stdout: "more than eight"))
        await #expect(throws: ChatMediaError.tooLarge) {
            try await transport.readChatMedia(request)
        }
        try await transport.close()
    }

    @Test func mediaReadUsesTheChatMediaBudget() async throws {
        let host = ScriptedHost()
        host.rule("src/chat-media.js", FakeHostSSHServices.result(stdout: "PNG"))
        let (transport, fake) = try await Self.open(host)

        _ = try await transport.readChatMedia(Self.mediaRequest)
        let exec = try #require(await fake.execs(containing: "src/chat-media.js").first)
        #expect(exec.timeout == WaycarSSHTransport.chatMediaRequestBudget)
        try await transport.close()
    }

    @Test func aMediaReadEndingBeforeEOFIsAChannelFailure() async throws {
        let host = ScriptedHost()
        host.rule("src/chat-media.js", FakeHostSSHServices.result(stdout: "PNG", reachedEOF: false))
        let (transport, _) = try await Self.open(host)

        await #expect {
            try await transport.readChatMedia(Self.mediaRequest)
        } throws: { error in
            if case TransportError.channelFailed = error { return true }
            return false
        }
        try await transport.close()
    }

    @Test func anUnquotablePluginRootNeverReachesAMediaExec() async throws {
        let root = "/home/me/x\\'; touch /tmp/pwned; echo '"
        let host = ScriptedHost(cli: Self.cli, root: root)
        let (transport, fake) = try await Self.open(host)

        await #expect(throws: NotificationRegistrationError.self) {
            try await transport.readChatMedia(Self.mediaRequest)
        }
        #expect(await fake.execs(containing: "chat-media").isEmpty)
        #expect(await fake.execs(containing: "pwned").isEmpty)
        try await transport.close()
    }

    @Test func mediaNeedsAPluginRoot() async throws {
        let none = ScriptedHost(cli: "", root: "")
        let (bare, bareFake) = try await Self.open(none)
        await #expect(throws: NotificationRegistrationError.pluginNotInstalled) {
            try await bare.readChatMedia(Self.mediaRequest)
        }
        #expect(await bareFake.execs(containing: "chat-media").isEmpty)
        try await bare.close()

        let unresolved = ScriptedHost(cli: Self.cli, root: "")
        let (transport, fake) = try await Self.open(unresolved)
        await #expect(throws: NotificationRegistrationError.pluginProbeFailed(
            detail: "The Host tools did not report a usable plugin root.")
        ) {
            try await transport.readChatMedia(Self.mediaRequest)
        }
        #expect(await fake.execs(containing: "chat-media").isEmpty)
        try await transport.close()
    }

    // MARK: Helpers

    enum RefreshOutcome: Sendable, Equatable {
        case started, pluginNotInstalled, actionUnavailable, failed
    }

    fileprivate static func open(
        _ host: ScriptedHost
    ) async throws -> (TmuxTransport, FakeHostSSHServices) {
        let fake = host.makeFake()
        let transport = try await TmuxTransport.open(
            session: fake, configuration: TmuxTransport.Configuration(requestTimeout: .seconds(5)))
        return (transport, fake)
    }

    static func probeOutput(
        pluginList: String, pluginDirs: [String: String], cli: String, root: String
    ) -> String {
        var lines = ["login chatter", HostToolsService.pluginListBegin, pluginList, HostToolsService.pluginListEnd]
        for (id, directory) in pluginDirs.sorted(by: { $0.key < $1.key }) {
            lines.append("\(HostToolsService.pluginDirMarker)\(id)=\(directory)")
        }
        lines.append("\(HostToolsService.fallbackConfigDirMarker)/xdg/waycar")
        lines.append("\(HostToolsService.cliMarker)\(cli)")
        lines.append("\(HostToolsService.pluginRootMarker)\(root)")
        return lines.joined(separator: "\n") + "\n"
    }
}

/// A tmux Host with no server running (the transport stays idle) whose
/// Host tools probe answers `cli` and `root`, plus per-test exec rules by
/// substring (the latest rule for a substring wins).
private final class ScriptedHost: Sendable {
    private let rules = Mutex<[(String, SSHExecResult)]>([])
    private let probe: String

    init(
        cli: String = TmuxSummariesChatTests.cli, root: String = TmuxSummariesChatTests.toolsRoot
    ) {
        probe = TmuxSummariesChatTests.probeOutput(
            pluginList: "", pluginDirs: [:], cli: cli, root: root)
    }

    func rule(_ match: String, _ result: SSHExecResult) {
        rules.withLock { rules in
            rules.removeAll { $0.0 == match }
            rules.append((match, result))
        }
    }

    func makeFake() -> FakeHostSSHServices {
        FakeHostSSHServices(exec: { [self] command, _ in exec(command) })
    }

    private func exec(_ command: String) -> SSHExecResult {
        if command.contains("exec tmux -V") {
            return FakeHostSSHServices.result(stdout: "tmux 3.7c\n")
        }
        if command.contains("tmux ls -F") {
            return FakeHostSSHServices.result(
                stderr: "no server running on /tmp/tmux-1000/default\n", exitStatus: 1)
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
