import Foundation

/// Pure: a tmux pane's Agent kind and Agent Status (design §4.3).
///
/// Kind, first match wins: `@waycar_agent` (set by the hook), a known agent
/// executable as `pane_current_command`, the kind the transport resolved
/// from the tty's foreground process (claude shows its version as the
/// command, T11), else nil: a Shell (ADR 0018). While the foreground command
/// is a shell every `@waycar_*` option is ignored, since an Agent killed
/// without `SessionEnd` leaves them behind.
enum TmuxAgentDetection {
    /// Whether the transport must resolve this pane's foreground process
    /// (`ps -t <tty>`) before its kind is known: a live pane running neither
    /// a shell nor a known agent, with no `@waycar_agent`.
    static func needsForegroundResolution(_ pane: TmuxPaneRecord) -> Bool {
        !pane.dead && !ShellCommand.isShell(pane.currentCommand) && !pane.currentCommand.isEmpty
            && pane.waycarAgent.isEmpty
            && AgentKindDetection.knownKind(executable: pane.currentCommand) == nil
    }

    /// Whether this pane runs a server chat CLI (`ServerChatBackend`: codex,
    /// opencode) whose command line names or joins its session
    /// (`ServerSessionLinks`): it is resolved in the same batched `ps` read
    /// on every snapshot, since that session can change while the pane's
    /// process and foreground command stay the same.
    static func needsServerSessionLinkFacts(_ pane: TmuxPaneRecord, resolvedKind: String?) -> Bool {
        kind(for: pane, resolvedKind: resolvedKind).map(serverChatKinds.contains) == true
    }

    private static let serverChatKinds = Set(ServerChatBackend.allCases.map(\.agentKind.rawValue))

    static func panesNeedingForegroundResolution(_ panes: [TmuxPaneRecord]) -> [TmuxPaneRecord] {
        panes.filter(needsForegroundResolution)
    }

    /// The pane's Agent kind; nil means a Shell.
    /// - Parameter resolvedKind: the kind of the pane's foreground process,
    ///   when the transport resolved one.
    static func kind(for pane: TmuxPaneRecord, resolvedKind: String?) -> String? {
        guard !pane.dead, !ShellCommand.isShell(pane.currentCommand) else { return nil }
        let hooked = pane.waycarAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hooked.isEmpty { return hooked }
        if let known = AgentKindDetection.knownKind(executable: pane.currentCommand) { return known }
        guard let resolvedKind, !resolvedKind.isEmpty else { return nil }
        return resolvedKind
    }

    /// The `kind(for:resolvedKind:)` form taking the foreground command line.
    static func kind(for pane: TmuxPaneRecord, foregroundCommandLine: String?) -> String? {
        kind(
            for: pane,
            resolvedKind: foregroundCommandLine.flatMap(AgentKindDetection.kind(commandLine:)))
    }

    /// A Shell pane's Shell Activity; nil for an Agent, a dead pane or an
    /// unknown foreground. The command line is never logged.
    /// - Parameter commandLine: the foreground process group leader's
    ///   `args` from `ps`, when resolved; else `pane_current_command`.
    static func shellActivity(
        for pane: TmuxPaneRecord, resolvedKind: String?, commandLine: String?
    ) -> ShellActivity? {
        guard !pane.dead, !pane.currentCommand.isEmpty,
            kind(for: pane, resolvedKind: resolvedKind) == nil
        else { return nil }
        if ShellCommand.isShell(pane.currentCommand) { return .idle }
        return ShellActivity.runningCommand(commandLine ?? "")
            ?? ShellActivity.runningCommand(pane.currentCommand)
    }

    /// The pane's Agent Status: `@waycar_status`, else a third-party
    /// plugin's status, else Unknown. Unknown while a shell is in front.
    static func status(for pane: TmuxPaneRecord) -> AgentStatus {
        guard !ShellCommand.isShell(pane.currentCommand) else { return .unknown }
        if let status = waycarStatus(pane.waycarStatus) { return status }
        return sidebarStatus(pane.sidebarStatus) ?? workmuxStatus(pane.workmuxStatus) ?? .unknown
    }

    /// `@waycar_status` (`working|blocked|done|idle`); nil when unset or
    /// unrecognised.
    static func waycarStatus(_ raw: String) -> AgentStatus? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "working": .working
        case "blocked": .blocked
        case "done": .done
        case "idle": .idle
        default: nil
        }
    }

    /// tmux-agent-sidebar's `@pane_status`.
    static func sidebarStatus(_ raw: String) -> AgentStatus? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "running": .working
        case "waiting", "error": .blocked
        case "idle": .idle
        default: nil
        }
    }

    /// workmux's `@workmux_pane_status` icon.
    static func workmuxStatus(_ raw: String) -> AgentStatus? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("🤖") { return .working }
        if value.contains("💬") { return .blocked }
        if value.contains("✅") { return .done }
        return nil
    }
}
