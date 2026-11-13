import Foundation

/// One-shot POSIX execs, always the detected absolute binary; argv metadata passes through ShellWord.
/// Drafts travel on stdin, not in sshd's shell -c argument. Minted background names omit
/// controls, '/' and a leading '-' because attach takes its session name positionally.
struct ZellijCommand: Sendable {
    enum InputError: Error, LocalizedError {
        case invalidExecutable, draftTooLarge, containsNul
        var errorDescription: String? {
            switch self {
            case .invalidExecutable: "Zellij requires an absolute executable path."
            case .draftTooLarge: "Message exceeds Zellij's 100 KiB limit."
            case .containsNul: "Zellij arguments cannot contain NUL."
            }
        }
    }

    /// Pass both fields to runExec. POSIX $(cat) drops trailing LFs; Enter is a separate action.
    struct InputExec: Sendable, Equatable {
        let command: String
        let input: Data
    }

    let zellij: String
    init(zellij: String) throws {
        guard zellij.hasPrefix("/"), !zellij.contains("\0") else { throw InputError.invalidExecutable }
        self.zellij = zellij
    }

    private func command(_ words: [String]) -> String {
        ([zellij] + words).map(ShellWord.quoted).joined(separator: " ")
    }

    private func action(session: String, _ words: [String]) -> String {
        // Equals prevents a leading '-' in a session name from becoming a clap option.
        command(["-s=" + session, "action"] + words)
    }

    func listClients(session: String) -> String { action(session: session, ["list-clients"]) }
    func listPanes(session: String) -> String { action(session: session, ["list-panes", "-j"]) }
    func dumpScreen(_ pane: ZellijPaneID, full: Bool = false) -> String {
        action(session: pane.session, ["dump-screen", "--pane-id", pane.rawPane] + (full ? ["--full"] : []))
    }
    func paste(_ pane: ZellijPaneID, text: String) throws -> InputExec {
        try inputExec(script: pasteScript(pane), text: text)
    }

    private func pasteScript(_ pane: ZellijPaneID) -> String {
        // Paste.chars is positional (cli.rs); '--' accepts a leading '-' in the stdin payload.
        action(session: pane.session, ["paste", "--pane-id", pane.rawPane, "--"]) + " \"$(cat)\""
    }

    private func inputExec(script: String, text: String) throws -> InputExec {
        guard text.utf8.count <= 100 * 1024 else { throw InputError.draftTooLarge }
        guard !text.contains("\0") else { throw InputError.containsNul }
        return InputExec(command: "/bin/sh -c " + ShellWord.quoted(script), input: Data(text.utf8))
    }
    func sendKeys(_ pane: ZellijPaneID, keys: [String]) throws -> String {
        action(
            session: pane.session,
            ["send-keys", "--pane-id", pane.rawPane, "--"] + (try ZellijKeys.names(for: keys)))
    }
    func pasteAndEnter(_ pane: ZellijPaneID, text: String) throws -> InputExec {
        try inputExec(script: pasteScript(pane) + " && " + sendKeys(pane, keys: ["enter"]), text: text)
    }
    func closePane(_ pane: ZellijPaneID) -> String {
        action(session: pane.session, ["close-pane", "--pane-id", pane.rawPane])
    }
    func closeTab(session: String, tabID: Int) -> String {
        action(session: session, ["close-tab", "--tab-id", String(tabID)])
    }
    func renamePane(_ pane: ZellijPaneID, name: String) -> String {
        action(session: pane.session, ["rename-pane", "--pane-id", pane.rawPane, "--", name])
    }
    func renameTab(session: String, tabID: Int, name: String) -> String {
        action(session: session, ["rename-tab-by-id", String(tabID), "--", name])
    }
    func newTab(session: String, name: String, cwd: String, line: String) -> String {
        action(
            session: session,
            ["new-tab", "--no-focus", "--name=" + name, "--cwd=" + cwd, "--", "/bin/sh", "-c", line])
            + " && " + listPanes(session: session)
    }
    /// Client check and creation share one exec; exit-0 without a client creates nothing.
    func newTabIfAttached(session: String, name: String, cwd: String, line: String) -> String {
        let script = "clients=$(" + listClients(session: session) + ") || exit $?; "
            + "if printf '%s\\n' \"$clients\" | grep -q '^[[:space:]]*[0-9]'; then "
            + "printf 'waycar-zellij-client\\n'; "
            + newTab(session: session, name: name, cwd: cwd, line: line) + "; fi"
        return "/bin/sh -c " + ShellWord.quoted(script)
    }

    func backgroundSession(name: String, cwd: String, line: String) -> String {
        "cd " + ShellWord.quoted(cwd) + " && "
            + command(["attach", "-b", Self.backgroundSessionName(name), "--", "/bin/sh", "-c", line])
    }
    func listSessions(namesOnly: Bool = false) -> String { command(["ls", namesOnly ? "-s" : "-n"]) }
    func deleteSession(name: String) -> String { command(["delete-session", "--", name]) }

    static func uniqueSessionName(_ name: String, listing: String) -> String {
        let used = Set(listing.split(whereSeparator: \.isNewline).map(String.init))
        let base = backgroundSessionName(name)
        var candidate = base
        var suffix = 2
        while used.contains(candidate) {
            candidate = base + "-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    static func backgroundSessionName(_ name: String) -> String {
        let cleaned = String(
            String.UnicodeScalarView(
                name.unicodeScalars.map {
                    CharacterSet.controlCharacters.contains($0) || $0 == "/" ? "-" : $0
                }))
        let base = String(cleaned.drop(while: { $0 == "-" || $0.isWhitespace }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "agent" : base
    }

    /// Tag is outside the login shell, so terminal_command retains it before hooks can run.
    static func launchLine(
        request: AgentLaunchRequest, tag: String,
        codexSupportsNoDaemon: @Sendable () async -> Bool
    ) async throws -> String {
        let agent = try await AgentLaunchBuilder.shellLine(
            for: request, codexSupportsNoDaemon: codexSupportsNoDaemon)
        return "env " + ShellWord.quoted("WAYCAR_LAUNCH=" + tag) + " /bin/sh -c "
            + ShellWord.quoted(TmuxCommand.loginShellWrapper(agentCommand: agent))
    }

    static func shellLaunchLine(tag: String) -> String {
        "env " + ShellWord.quoted("WAYCAR_LAUNCH=" + tag) + " WAYCAR_SHELL=1 \"$SHELL\" -l"
    }

    /// Only the explicit saved-session Resume path uses this command (no focus claim).
    func resumeSession(name: String) -> String {
        let script = "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; exec "
            + command(["attach", name])
        return "/bin/sh -c " + ShellWord.quoted(script)
    }

    func attach(session: String, claim: ZellijAttachMachine.Claim = .default) -> String {
        // A standby's command may run long after bootstrap. Recheck on the Host immediately
        // before attach, so a session closed in that gap is not resurrected by an Agent tap.
        let script = listPanes(session: session)
            + " >/dev/null 2>&1 || { printf '%s\\n' 'This Zellij session is no longer running.' >&2; exit 125; }; "
            + "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; exec "
            + command(["attach", session, "options", "--default-mode", claim.mode])
        return "/bin/sh -c " + ShellWord.quoted(script)
    }

    static let clientsBefore = "\u{1E}Cbefore"
    static let clientsAfter = "\u{1E}Cafter"
    static let clientsEnd = "\u{1E}Cend"

    /// Stable sentinels separate the two tables from focus-pane's harmless diagnostics.
    func navigate(_ pane: ZellijPaneID, tabID: Int) -> String {
        "printf '\\036Cbefore\\n'; " + listClients(session: pane.session)
            + "; " + restore(pane, tabID: tabID)
            + "; printf '\\036Cafter\\n'; " + listClients(session: pane.session)
            + "; printf '\\036Cend\\n'"
    }

    /// Acts on the last typist (the client the navigation check saw move), never a claimed takeover.
    func restore(_ pane: ZellijPaneID, tabID: Int) -> String {
        restore(session: pane.session, tabID: tabID, rawPane: pane.rawPane)
    }

    /// Restoration must not silently succeed on a lost/refused command. Focus returns 2 when
    /// already focused; both it and 0 are successful, every other exit remains a failure.
    func restoreChecked(session: String, tabID: Int, rawPane: String) -> String {
        let script = action(session: session, ["go-to-tab-by-id", String(tabID)])
            + " || exit $?; "
            + action(session: session, ["focus-pane-id", "--", rawPane])
            + "; r=$?; [ \"$r\" = 0 ] || [ \"$r\" = 2 ]"
        return "/bin/sh -c " + ShellWord.quoted(script)
    }

    func restore(session: String, tabID: Int, rawPane: String) -> String {
        // Already-focused panes exit 2; only the client tables verify navigation.
        action(session: session, ["go-to-tab-by-id", String(tabID)]) + "; "
            + action(session: session, ["focus-pane-id", "--", rawPane])
    }
}
