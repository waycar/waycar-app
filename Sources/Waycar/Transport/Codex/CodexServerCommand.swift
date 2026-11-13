import Foundation

/// The only mutating Codex command in the connection/start path. Detection
/// uses `--version` and `daemon version` only (design X1–X4).
enum CodexServerCommand {
    /// Prefer the remembered login PATH; include installers absent from a
    /// bare SSH exec PATH. nvm's directories are expanded only when present.
    /// No single quotes: this lives inside a single-quoted POSIX script.
    static let pathScript = searchPATHScript(extraPATH: HerdrHostPath.extraPATH)

    /// `pathScript` with `extraPATH` in place of the shared tool directories
    /// (backend detection's, which real-SSH fixtures narrow).
    static func searchPATHScript(extraPATH: String) -> String {
        "export PATH=\"${1:-$PATH}:\(extraPATH):$HOME/.npm-global/bin:$HOME/.codex/packages/standalone/current\"; "
            + "for cb in \"$HOME\"/.nvm/versions/node/*/bin; do "
            + "[ ! -d \"$cb\" ] || PATH=\"$PATH:$cb\"; done; export PATH; "
    }

    static func start(path: String, loginPATH: String?, inLoginSession: Bool) -> HostServerStartExec {
        let login = inLoginSession
            ? HostLoginSessionStart.script(
                variables: [
                    "WAYCAR_CODEX_PATH=\"$p\"",
                    "${CODEX_HOME+CODEX_HOME=\"$CODEX_HOME\"}",
                ], ready: "true", capturesOutput: true)
            : ""
        return HostServerStartExec(
            command: "/bin/sh -c '\(pathScript)p=\"$2\"; \(login)"
                + "exec \"$p\" app-server daemon start < /dev/null' codex "
                + "\(ShellWord.quoted(loginPATH ?? "")) \(ShellWord.quoted(path))",
            input: inLoginSession
                ? Data(HostLoginSessionStart.job(
                    command: "c=$WAYCAR_CODEX_PATH && unset WAYCAR_CODEX_PATH && \"$c\" app-server daemon start",
                    capturesOutput: true).utf8)
                : Data())
    }

    struct DaemonResult: Decodable {
        let status: String
        let socketPath: String?
        let appServerVersion: String?
    }

    static func daemonResult(_ output: Data) -> DaemonResult? {
        try? JSONDecoder().decode(DaemonResult.self, from: output)
    }

    static func validateStart(exitStatus: Int32?, reachedEOF: Bool, stdout: Data, stderr: Data) throws {
        if exitStatus == 0, reachedEOF, let result = daemonResult(stdout),
            result.status == "started" || result.status == "alreadyRunning"
        {
            return
        }
        let diagnostics = String(decoding: stderr.prefix(200), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw HerdrStartError(output: diagnostics.isEmpty
            ? String(decoding: stdout.prefix(200), as: UTF8.self) : diagnostics)
    }
}
