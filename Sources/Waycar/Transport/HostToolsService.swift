import Foundation

/// Where this Host's Waycar files live, resolved as the Host Tools resolve
/// them (design §4.5, `waycar config-dir`).
struct HostToolsLocation: Sendable, Equatable {
    /// The Host's one registration directory: the enabled `waycar` herdr
    /// plugin's config dir, else `${XDG_CONFIG_HOME:-$HOME/.config}/waycar`
    /// when the Host tools are installed; nil with neither.
    let configDirectory: String?
    /// The Host tools' CLI (`$HOME/.local/bin/waycar` when it is install.sh's
    /// symlink into a Waycar plugin root, else
    /// `${WAYCAR_PLUGIN_DIR:-$HOME/.local/share/waycar/plugin}/bin/waycar`);
    /// nil when not installed.
    let cli: String?
    /// The plugin install root the transcript reader (`waycar chat-read`)
    /// runs from: the Host tools' own (the CLI's symlinks followed, as
    /// `bin/waycar` finds it), else the enabled herdr plugin's
    /// `plugin_root`; nil with neither.
    let pluginRoot: String?

    init(configDirectory: String?, cli: String?, pluginRoot: String? = nil) {
        self.configDirectory = configDirectory
        self.cli = cli
        self.pluginRoot = pluginRoot
    }
}

/// The Transport members that read and write what Waycar's Host Tools keep
/// on a Host: the Notification Registration and config, Agent Summaries,
/// Chat Markers and transcripts, and the status hooks. One implementation
/// serves every transport that is not herdr's own: tmux and herdr-core read
/// the same files in the same config directory, so a Host with both is one
/// registration, not two. A conforming type provides its ``HostToolsService``
/// and its open check; the members come from this protocol's extension.
protocol HostToolsTransport: Transport {
    var hostTools: HostToolsService { get }
    /// Throws when this transport can no longer serve calls (closed, or
    /// replaced by a newer one).
    func ensureOpen() async throws
}

extension HostToolsTransport {
    func readNotificationRegistration() async throws -> Data? {
        try await ensureOpen()
        return try await hostTools.readNotificationRegistration()
    }

    func replaceNotificationRegistration(_ contents: Data) async throws {
        try await ensureOpen()
        try await hostTools.replaceNotificationRegistration(contents)
    }

    func readNotificationConfig() async throws -> Data? {
        try await ensureOpen()
        return try await hostTools.readNotificationConfig()
    }

    func replaceNotificationConfig(_ contents: Data) async throws {
        try await ensureOpen()
        try await hostTools.replaceNotificationConfig(contents)
    }

    func statusHooksReport() async throws -> StatusHooksReport {
        try await ensureOpen()
        return try await hostTools.runHooksCommand("status")
    }

    func installStatusHooks() async throws -> StatusHooksReport {
        try await ensureOpen()
        return try await hostTools.runHooksCommand("install")
    }

    func readAgentSummaries() async throws -> [String: AgentSummary] {
        try await ensureOpen()
        return try await hostTools.readAgentSummaries()
    }

    func refreshAgentSummaries() async throws {
        try await ensureOpen()
        try await hostTools.refreshAgentSummaries()
    }

    func readChatModeMarkers() async throws -> [ChatModeMarker] {
        try await ensureOpen()
        return try await hostTools.readChatModeMarkers()
    }

    func writeChatModeMarker(_ marker: ChatModeMarker) async throws {
        try await hostTools.writeChatModeMarker(marker)
    }

    func deleteChatModeMarker(paneID: String) async throws {
        try await hostTools.deleteChatModeMarker(paneID: paneID)
    }

    func readChatTranscript(_ request: ChatTranscriptRequest) async throws -> ChatTranscriptSnapshot {
        try await ensureOpen()
        return try await hostTools.readChatTranscript(request)
    }

    func readChatMedia(_ request: ChatMediaRequest) async throws -> Data {
        try await ensureOpen()
        return try await hostTools.readChatMedia(request)
    }
}

/// The Host Tools' reads and writes over one Host's SSH session (see
/// ``HostToolsTransport``). The Host's tools location is resolved once per
/// service, by one exec.
final class HostToolsService: Sendable {
    let session: any HostSSHServices
    private let location = SharedAsyncOperation<HostToolsLocation>(cachesSuccess: true)

    init(session: any HostSSHServices) {
        self.session = session
    }

    // MARK: Location

    static let pluginListBegin = "__WAYCAR_PLUGIN_LIST_BEGIN__"
    static let pluginListEnd = "__WAYCAR_PLUGIN_LIST_END__"
    static let pluginDirMarker = "__WAYCAR_PLUGIN_DIR__"
    static let fallbackConfigDirMarker = "__WAYCAR_FALLBACK_CONFIG_DIR__="
    static let cliMarker = "__WAYCAR_CLI__="
    static let pluginRootMarker = "__WAYCAR_PLUGIN_ROOT__="

    /// Plugin ids in preference order, as `SSHTransportSettings` and the
    /// Host Tools list them.
    static var notificationPluginIDs: [String] {
        [SSHTransportSettings.notificationPluginID]
            + SSHTransportSettings.legacyNotificationPluginIDs
    }

    /// One exec: the herdr plugin list (between markers; empty on a Host with
    /// no herdr), the config dir of each known plugin id the list mentions
    /// (`herdr plugin config-dir` creates a directory for any id, so unlisted
    /// ids are never asked), the fallback config dir, the Host tools' CLI and
    /// the plugin root it runs from, resolved by
    /// `WaycarHostToolsShell.resolveCLIAndRoot` (shared with backend
    /// detection).
    static var hostToolsProbeCommand: String {
        let pluginDirs = notificationPluginIDs.map { id in
            "case \"$list\" in *\"\\\"\(id)\\\"\"*) "
                + "printf \"\(pluginDirMarker)\(id)=%s\\n\" "
                + "\"$(herdr plugin config-dir \(id) 2>/dev/null)\";; esac; "
        }.joined()
        let script =
            "list=$(herdr plugin list --json 2>/dev/null); "
            + "printf \"\(pluginListBegin)\\n%s\\n\(pluginListEnd)\\n\" \"$list\"; "
            + pluginDirs
            + "case \"$XDG_CONFIG_HOME\" in /*) c=\"$XDG_CONFIG_HOME\";; *) c=\"$HOME/.config\";; esac; "
            + "printf \"\(fallbackConfigDirMarker)%s\\n\" \"$c/waycar\"; "
            + WaycarHostToolsShell.resolveCLIAndRoot
            + "printf \"\(cliMarker)%s\\n\" \"$cli\"; "
            + "printf \"\(pluginRootMarker)%s\\n\" \"$root\"; exit 0"
        return TmuxTransport.shellCommand(script, cLocale: true)
    }

    func resolvedHostTools() async throws -> HostToolsLocation {
        try await location.value { try await self.resolveHostTools() }
    }

    private func resolveHostTools() async throws -> HostToolsLocation {
        let result = try await session.runExec(
            Self.hostToolsProbeCommand, input: Data(), timeout: nil)
        guard result.exitStatus == 0, result.reachedEOF else {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "The Host tools probe failed.")
        }
        return try Self.hostTools(fromProbeOutput: TmuxTransport.text(result.stdout))
    }

    /// The probe's answer. An enabled herdr plugin whose config dir is not
    /// an absolute path fails rather than falling back: a second
    /// registration file would split the Host's devices.
    static func hostTools(fromProbeOutput output: String) throws -> HostToolsLocation {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        func marker(_ prefix: String) -> String? {
            lines.last(where: { $0.hasPrefix(prefix) }).map { String($0.dropFirst(prefix.count)) }
        }
        let cli = marker(cliMarker).flatMap { $0.hasPrefix("/") ? $0 : nil }
        let toolsRoot = cli == nil
            ? nil : marker(pluginRootMarker).flatMap { $0.hasPrefix("/") ? $0 : nil }
        if let plugin = enabledPlugin(inPluginList: pluginList(lines)) {
            guard let directory = marker("\(pluginDirMarker)\(plugin.id)="), directory.hasPrefix("/")
            else {
                throw NotificationRegistrationError.pluginProbeFailed(
                    detail: "The plugin config directory response was invalid.")
            }
            let herdrRoot = plugin.root.flatMap { $0.hasPrefix("/") ? $0 : nil }
            return HostToolsLocation(
                configDirectory: directory, cli: cli, pluginRoot: toolsRoot ?? herdrRoot)
        }
        guard cli != nil else { return HostToolsLocation(configDirectory: nil, cli: nil) }
        let fallback = marker(fallbackConfigDirMarker).flatMap { $0.hasPrefix("/") ? $0 : nil }
        return HostToolsLocation(configDirectory: fallback, cli: cli, pluginRoot: toolsRoot)
    }

    private static func pluginList(_ lines: [String]) -> String {
        guard let begin = lines.firstIndex(of: pluginListBegin),
            let end = lines[(begin + 1)...].firstIndex(of: pluginListEnd)
        else { return "" }
        return lines[(begin + 1)..<end].joined(separator: "\n")
    }

    /// The first known id enabled in `herdr plugin list --json`, with the
    /// `plugin_root` herdr reports for it; nil when herdr is absent, its
    /// answer is not JSON, or no such plugin is enabled.
    static func enabledPlugin(inPluginList json: String) -> (id: String, root: String?)? {
        guard let data = json.data(using: .utf8),
            let list = try? JSONDecoder().decode(PluginListEnvelope.self, from: data)
        else { return nil }
        let enabled = list.result.plugins.filter { $0.enabled != false }
        for id in notificationPluginIDs {
            if let entry = enabled.first(where: { $0.pluginID == id }) {
                return (id, entry.pluginRoot)
            }
        }
        return nil
    }

    private struct PluginListEnvelope: Decodable {
        struct ResultBody: Decodable {
            let plugins: [Entry]
        }

        struct Entry: Decodable {
            let pluginID: String?
            let enabled: Bool?
            let pluginRoot: String?

            private enum CodingKeys: String, CodingKey {
                case pluginID = "plugin_id"
                case enabled
                case pluginRoot = "plugin_root"
            }
        }

        let result: ResultBody
    }

    // MARK: Notification files

    /// The Host's config dir (``HostToolsLocation/configDirectory``); the
    /// notification files, Agent Summaries and Chat Markers live there.
    func registrationDirectory() async throws -> String {
        guard let directory = try await resolvedHostTools().configDirectory else {
            throw NotificationRegistrationError.pluginNotInstalled
        }
        return directory
    }

    func readNotificationRegistration() async throws -> Data? {
        try await session.readConfigFile(
            named: WaycarSSHTransport.notificationRegistrationFileName,
            inDirectory: try await registrationDirectory())
    }

    func replaceNotificationRegistration(_ contents: Data) async throws {
        try await session.replaceConfigFile(
            named: WaycarSSHTransport.notificationRegistrationFileName,
            inDirectory: try await registrationDirectory(), subdirectory: nil, contents: contents)
    }

    func readNotificationConfig() async throws -> Data? {
        try await session.readConfigFile(
            named: WaycarSSHTransport.notificationConfigFileName,
            inDirectory: try await registrationDirectory())
    }

    func replaceNotificationConfig(_ contents: Data) async throws {
        try await session.replaceConfigFile(
            named: WaycarSSHTransport.notificationConfigFileName,
            inDirectory: try await registrationDirectory(), subdirectory: nil, contents: contents)
    }

    // MARK: Status hooks

    /// `<cli> hooks <action> --json`, decoded whatever the exit status (the
    /// report says what failed).
    func runHooksCommand(_ action: String) async throws -> StatusHooksReport {
        guard let cli = try await resolvedHostTools().cli else {
            throw NotificationRegistrationError.pluginNotInstalled
        }
        let result = try await session.runExec(
            TmuxTransport.shellCommand("exec \"$1\" hooks \(action) --json", arguments: [cli]),
            input: Data(), timeout: nil)
        if result.exitStatus == 127 { throw NotificationRegistrationError.pluginNotInstalled }
        guard let report = Self.statusHooksReport(fromOutput: result.stdout) else {
            let detail = TmuxTransport.preview(
                TmuxTransport.text(result.stderr) + "\n" + TmuxTransport.text(result.stdout))
            throw TransportError.malformedResponse("waycar hooks \(action) printed: \(detail)")
        }
        return report
    }

    /// The report: the whole output, else its last line that decodes (shell
    /// chatter may precede the JSON line).
    static func statusHooksReport(fromOutput output: Data) -> StatusHooksReport? {
        let decoder = JSONDecoder()
        if let report = try? decoder.decode(StatusHooksReport.self, from: output) { return report }
        for line in TmuxTransport.text(output).split(whereSeparator: \.isNewline).reversed()
        where line.hasPrefix("{") {
            if let report = try? decoder.decode(StatusHooksReport.self, from: Data(line.utf8)) {
                return report
            }
        }
        return nil
    }

    // MARK: Agent Summaries

    /// How long the refresh exec waits for `waycar summaries refresh` to end
    /// on its own before leaving it running and answering: long enough for
    /// a CLI that predates the subcommand to fail with its usage error.
    static let summaryRefreshWaitSeconds = 2

    /// One exec over the config dir's `summaries/` (one file per pane,
    /// `tmux:%N` and `hc:<address>` ids included), with the bounds herdr's
    /// read uses (`AgentSummary.readCommand`).
    func readAgentSummaries() async throws -> [String: AgentSummary] {
        let directory = try await registrationDirectory()
        guard let quoted = RemoteShellPath.quotedAbsolute(directory) else {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "The plugin config directory cannot be quoted safely.")
        }
        let command = AgentSummary.readCommand(quotedConfigDirectory: quoted)
        let result = try await session.runExec(
            HostSSHSession.cLocaleCommand(command), input: Data(), timeout: nil)
        guard result.exitStatus == 0, result.reachedEOF else {
            throw TransportError.channelFailed(detail: "the Agent Summary read failed")
        }
        return AgentSummary.latestByPane(fromNDJSON: result.stdout)
    }

    /// Starts `<cli> summaries refresh` on the Host and returns once it is
    /// running (or already done), as herdr's `plugin action invoke` returns
    /// once the action spawned: the new summaries land in the store the
    /// next ``readAgentSummaries()`` reads. A missing CLI is
    /// `NotificationRegistrationError.pluginNotInstalled`; a CLI without the
    /// subcommand (its usage error, exit 2) is
    /// `AgentSummaryRefreshError.actionUnavailable`.
    func refreshAgentSummaries() async throws {
        guard let cli = try await resolvedHostTools().cli else {
            throw NotificationRegistrationError.pluginNotInstalled
        }
        let result = try await session.runExec(
            try Self.summaryRefreshCommand(cli: cli), input: Data(), timeout: nil)
        switch result.exitStatus {
        case 0:
            return
        case 127:
            throw NotificationRegistrationError.pluginNotInstalled
        default:
            throw AgentSummary.refreshFailure(exitStatus: result.exitStatus, stderr: result.stderr)
        }
    }

    /// Runs the CLI in the background with its output detached from the
    /// exec, so the SSH channel can close while the refresh goes on. The
    /// exec waits for the CLI; a timer subshell signals the script after
    /// ``summaryRefreshWaitSeconds``, whose trap ends the wait with 0 and
    /// leaves the refresh running. Otherwise the CLI's own status: 127 for
    /// a missing CLI, 2 for an unknown subcommand.
    static func summaryRefreshCommand(cli: String) throws -> String {
        try TmuxTransport.shellCommand(
            "[ -x \"$1\" ] || exit 127; trap \"exit 0\" USR1; "
                + "\"$1\" summaries refresh </dev/null >/dev/null 2>&1 & p=$!; "
                + "(sleep \(summaryRefreshWaitSeconds); kill -USR1 $$) </dev/null >/dev/null 2>&1 & w=$!; "
                + "wait $p; s=$?; kill $w 2>/dev/null; wait $w 2>/dev/null; exit $s",
            arguments: [cli])
    }

    // MARK: Chat Mode

    /// One exec over the config dir's `chat/`, like the Agent Summaries read.
    func readChatModeMarkers() async throws -> [ChatModeMarker] {
        let directory = try await registrationDirectory()
        guard let quoted = RemoteShellPath.quotedAbsolute(directory) else {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "The plugin config directory cannot be quoted safely.")
        }
        let command = WaycarSSHTransport.chatModeMarkerReadCommand(quotedConfigDirectory: quoted)
        let result = try await session.runExec(
            HostSSHSession.cLocaleCommand(command), input: Data(), timeout: nil)
        guard result.exitStatus == 0, result.reachedEOF else {
            throw TransportError.channelFailed(detail: "the Chat Marker read failed")
        }
        return WaycarSSHTransport.chatModeMarkers(fromNDJSON: result.stdout)
    }

    func writeChatModeMarker(_ marker: ChatModeMarker) async throws {
        let contents: Data
        do {
            contents = try JSONEncoder().encode(marker)
        } catch {
            throw NotificationRegistrationError.writeFailed(
                detail: "The Chat Marker could not be encoded.")
        }
        try await session.replaceConfigFile(
            named: ChatModeMarker.fileName(paneID: marker.paneID),
            inDirectory: try await registrationDirectory(),
            subdirectory: WaycarSSHTransport.chatModeMarkerDirectoryName,
            contents: contents)
    }

    /// An already-absent marker is fine.
    func deleteChatModeMarker(paneID: String) async throws {
        try await session.deleteConfigFile(
            named: ChatModeMarker.fileName(paneID: paneID),
            inDirectory: try await registrationDirectory(),
            subdirectory: WaycarSSHTransport.chatModeMarkerDirectoryName)
    }

    /// The plugin root, quoted for the readers' command lines.
    private func quotedPluginRoot() async throws -> String {
        let tools = try await resolvedHostTools()
        guard let root = tools.pluginRoot else {
            if tools.configDirectory == nil { throw NotificationRegistrationError.pluginNotInstalled }
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "The Host tools did not report a usable plugin root.")
        }
        guard let quotedRoot = RemoteShellPath.quotedAbsolute(root) else {
            throw NotificationRegistrationError.pluginProbeFailed(
                detail: "The plugin root cannot be quoted safely.")
        }
        return quotedRoot
    }

    /// Runs the transcript reader from the plugin root the Host tools probe
    /// resolved (``HostToolsLocation/pluginRoot``) in one exec, bounded on
    /// the Host by `waycar_watch`, with herdr's command, request JSON, Host
    /// watchdog and exit statuses.
    func readChatTranscript(_ request: ChatTranscriptRequest) async throws -> ChatTranscriptSnapshot {
        let command = WaycarSSHTransport.chatTranscriptReadCommand(
            quotedPluginRoot: try await quotedPluginRoot())
        let input = try WaycarSSHTransport.chatTranscriptRequestJSON(request)
        let result = try await session.runExec(
            HostSSHSession.cLocaleCommand(command), input: input, timeout: nil)
        switch result.exitStatus {
        case 0:
            break
        case WaycarSSHTransport.chatReaderMissingStatus:
            throw ChatTranscriptError.readerUnavailable
        case HostWatchdog.stoppedStatus:
            throw TransportError.channelFailed(detail: "the chat transcript read ran too long")
        default:
            throw TransportError.channelFailed(
                detail: "the chat transcript read failed: "
                    + TmuxTransport.preview(TmuxTransport.text(result.stderr)))
        }
        guard result.reachedEOF else {
            throw TransportError.channelFailed(detail: "the chat transcript read closed before EOF")
        }
        return try ChatTranscriptDecoding.decode(result.stdout)
    }

    /// Runs the plugin's media reader from the same plugin root as the
    /// transcript reader, with herdr's command, request JSON, budget,
    /// exit statuses and size cap; its stdout is the decoded bytes.
    func readChatMedia(_ request: ChatMediaRequest) async throws -> Data {
        let command = WaycarSSHTransport.chatMediaReadCommand(
            quotedPluginRoot: try await quotedPluginRoot())
        let input = try WaycarSSHTransport.chatMediaRequestJSON(request)
        let result = try await session.runExec(
            HostSSHSession.cLocaleCommand(command), input: input,
            timeout: WaycarSSHTransport.chatMediaRequestBudget)
        if let failure = WaycarSSHTransport.chatMediaFailure(
            exitStatus: result.exitStatus, stderr: result.stderr)
        {
            throw failure
        }
        guard result.reachedEOF else {
            throw TransportError.channelFailed(detail: "the chat media read closed before EOF")
        }
        guard result.stdout.count <= request.maxBytes else { throw ChatMediaError.tooLarge }
        return result.stdout
    }
}
