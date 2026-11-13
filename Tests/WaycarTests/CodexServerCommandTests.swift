import Foundation
import Testing

@testable import Waycar

@Suite("Codex server start")
struct CodexServerCommandTests {
    @Test func plainStartExecsDetectedBinaryWithoutALocaleWrapper() {
        let start = CodexServerCommand.start(
            path: "/opt/codex cli/codex", loginPATH: "/login/bin:/usr/bin", inLoginSession: false)
        #expect(start.command.contains("exec \"$p\" app-server daemon start"))
        #expect(start.command.contains(ShellWord.quoted("/opt/codex cli/codex")))
        #expect(start.command.contains(ShellWord.quoted("/login/bin:/usr/bin")))
        #expect(!start.command.contains("LC_ALL"))
        #expect(!start.command.contains("launchctl"))
        #expect(start.input.isEmpty)
    }

    @Test func loginStartReusesTheSharedJobAndPreservesItsJSON() {
        let start = CodexServerCommand.start(
            path: "/opt/homebrew/bin/codex", loginPATH: "/login/bin", inLoginSession: true)
        let job = String(decoding: start.input, as: UTF8.self)
        #expect(start.command.contains("launchctl bootstrap"))
        #expect(start.command.contains("Interactive"))
        #expect(start.command.contains("CODEX_HOME"))
        #expect(start.command.contains("cat <&5"))
        #expect(start.command.contains("exec \"$p\" app-server daemon start")) // fallback
        #expect(job.contains("cd \"$HOME\""))
        #expect(job.contains("unset WAYCAR_CODEX_PATH"))
        #expect(job.contains("app-server daemon start"))
        #expect(job.contains("> \"$d/out\""))
        #expect(!job.contains("LC_ALL"))
        #expect(!start.command.contains("SSH_CONNECTION="))
    }

    @Test(arguments: ["started", "alreadyRunning"])
    func successfulJSONIsRequired(status: String) throws {
        try CodexServerCommand.validateStart(
            exitStatus: 0, reachedEOF: true,
            stdout: Data("{\"status\":\"\(status)\",\"socketPath\":\"/tmp/codex.sock\"}".utf8),
            stderr: Data("install diagnostics".utf8))
    }

    @Test(arguments: ["junk", "{}", #"{"status":"running"}"#, #"{"status":"stopped"}"#])
    func exitZeroAloneIsNotSuccess(output: String) {
        #expect(throws: HerdrStartError.self) {
            try CodexServerCommand.validateStart(
                exitStatus: 0, reachedEOF: true, stdout: Data(output.utf8), stderr: Data())
        }
    }

    @Test func failedCommandKeepsDiagnostics() {
        #expect(throws: HerdrStartError(output: "package incomplete")) {
            try CodexServerCommand.validateStart(
                exitStatus: 1, reachedEOF: true, stdout: Data(),
                stderr: Data("package incomplete\n".utf8))
        }
    }
}
