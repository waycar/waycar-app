import Foundation

/// The only command that starts OpenCode 2's shared server, run solely by
/// the user's Start OpenCode server (memory `no-auto-start-host-services`).
/// Detection uses `--version` and `service status` only (O2).
enum OpenCodeServerCommand {
    /// The remembered login PATH first, then both installers' homes and the
    /// usual tool directories a bare SSH exec lacks. No single quotes: this
    /// lives inside a single-quoted POSIX script.
    static let pathScript = searchPATHScript(extraPATH: HerdrHostPath.extraPATH)

    /// `pathScript` with `extraPATH` in place of the shared tool directories
    /// (backend detection's, which real-SSH fixtures narrow).
    static func searchPATHScript(extraPATH: String) -> String {
        "export PATH=\"${1:-$PATH}:$HOME/.opencode/bin:\(extraPATH):$HOME/.npm-global/bin\"; "
    }

    /// `opencode service start` (O3), in the macOS login session as a
    /// one-shot launchd job when there is one, because every tool the server
    /// runs inherits its starter's environment (O4); a plain exec elsewhere.
    /// The XDG folders travel along, so the server registers where
    /// detection reads it.
    static func start(path: String, loginPATH: String?, inLoginSession: Bool) -> HostServerStartExec {
        let login = inLoginSession
            ? HostLoginSessionStart.script(
                variables: [
                    "WAYCAR_OPENCODE_PATH=\"$p\"",
                    "${XDG_STATE_HOME+XDG_STATE_HOME=\"$XDG_STATE_HOME\"}",
                    "${XDG_CONFIG_HOME+XDG_CONFIG_HOME=\"$XDG_CONFIG_HOME\"}",
                    "${XDG_DATA_HOME+XDG_DATA_HOME=\"$XDG_DATA_HOME\"}",
                ], ready: "true", capturesOutput: true)
            : ""
        return HostServerStartExec(
            command: "/bin/sh -c '\(pathScript)p=\"$2\"; \(login)"
                + "exec \"$p\" service start < /dev/null' opencode "
                + "\(ShellWord.quoted(loginPATH ?? "")) \(ShellWord.quoted(path))",
            input: inLoginSession
                ? Data(HostLoginSessionStart.job(
                    command: "o=$WAYCAR_OPENCODE_PATH && unset WAYCAR_OPENCODE_PATH && \"$o\" service start",
                    capturesOutput: true).utf8)
                : Data())
    }

    /// `service start` prints the server's URL and exits 0, also when one
    /// already runs; anything else is a failed start with OpenCode's words.
    static func validateStart(exitStatus: Int32?, reachedEOF: Bool, stdout: Data, stderr: Data) throws {
        if exitStatus == 0, reachedEOF { return }
        let diagnostics = String(decoding: stderr.prefix(200), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw HerdrStartError(output: diagnostics.isEmpty
            ? String(decoding: stdout.prefix(200), as: UTF8.self) : diagnostics)
    }
}
