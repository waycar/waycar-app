import Foundation
import Testing

@testable import Waycar

@Suite("herdr-core exec lines", .timeLimit(.minutes(1)))
struct CoreConnectCommandTests {
    /// The line's `sh -c` arguments after the script: `core`, the login PATH
    /// and the binary (and the address, for an attach).
    private static func arguments(of line: String) -> String {
        guard let end = line.range(of: "' core ", options: .backwards) else { return "" }
        return String(line[end.upperBound...])
    }

    @Test func theConnectLineExportsTheLoginPathAndPrintsTheMarkerBeforeExec() {
        let line = CoreConnectCommand.connect(
            path: "/home/dev/.local/bin/herdr-core", loginPATH: "/opt/tools/bin:/usr/bin")
        #expect(line.hasPrefix("/bin/sh -c '"))
        #expect(
            Self.arguments(of: line) == "/opt/tools/bin:/usr/bin /home/dev/.local/bin/herdr-core")
        let script = line.components(separatedBy: "' core ")[0]
        // The marker goes out immediately before the exec, and nothing is
        // printed between them.
        #expect(
            script.hasSuffix(
                "printf \"%s\\n\" \"\(CoreConnectCommand.connectMarker)\"; exec \"$p\" connect"))
        // The not-installed text and exit 127 come from the line itself.
        #expect(script.contains("echo \"\(CoreConnectCommand.notInstalledText)\" >&2; exit 127"))
        // The usual directories follow the PATH, so a directory that did not
        // exist when it was resolved is still searched.
        #expect(script.contains("$HOME/.local/bin"))
        // One single-quoted script: no quote inside it.
        #expect(!script.dropFirst("/bin/sh -c '".count).contains("'"))
        // The probe adds no backslash; the marker's `\n` is the only one.
        #expect(!script.replacingOccurrences(of: "%s\\n", with: "").contains("\\"))
        #expect(!script.contains("\n"))
        #expect(script.contains(CoreConnectCommand.socketScript))
        #expect(script.contains(CoreConnectCommand.runningProbeScript))
        #expect(script.contains("echo \"\(CoreConnectCommand.notRunningText)\" >&2; exit 125"))
        #expect(script.contains("export HC_SOCKET=\"$h\""))
        // Python only off macOS, where `python3` may be the CLT stub.
        #expect(script.contains("[ \"$(uname -s)\" != Darwin ] && command -v python3"))
    }

    @Test func aHostValueNeverReachesTheScript() {
        let hostile = "/bin:/x'; touch /tmp/pwned; echo '"
        let line = CoreConnectCommand.connect(path: "/opt/it's/herdr-core", loginPATH: hostile)
        let script = line.components(separatedBy: "' core ")[0]
        #expect(!script.contains("pwned"))
        #expect(!script.contains("it's"))
        // Both values arrive as quoted positional arguments.
        let arguments = Self.arguments(of: line)
        #expect(arguments.contains(#"'/bin:/x'\''; touch /tmp/pwned; echo '\'''"#))
        #expect(arguments.contains(#"'/opt/it'\''s/herdr-core'"#))
    }

    @Test func withoutValuesTheLineFallsBackToThePathAndTheInstallersDirectory() throws {
        let line = CoreConnectCommand.connect(path: nil, loginPATH: nil)
        #expect(Self.arguments(of: line) == "'' ''")
        // No login PATH: the usual directories go ahead of the SSH PATH.
        let script = line.components(separatedBy: "' core ")[0]
        let fallback = try #require(script.range(of: "else export PATH=\""))
        #expect(script[fallback.upperBound...].hasPrefix(HerdrHostPath.extraPATH))
        #expect(script[fallback.upperBound...].contains(":$PATH\""))
        #expect(line.contains("command -v herdr-core"))
        #expect(line.contains("$HOME/.local/bin/herdr-core"))
    }

    @Test(arguments: [false, true])
    func explicitStartUsesTheConnectPathAndNoLocale(inLoginSession: Bool) {
        let start = CoreConnectCommand.start(
            path: "/opt/core/herdr-core", loginPATH: "/opt/tools:/usr/bin",
            inLoginSession: inLoginSession)
        let script = start.command.components(separatedBy: "' core ")[0]
            .dropFirst("/bin/sh -c '".count)
        #expect(!script.contains("'"))
        #expect(!script.contains("\\"))
        #expect(!script.contains("LC_ALL"))
        #expect(start.command.hasSuffix("/opt/tools:/usr/bin /opt/core/herdr-core"))
        #expect(script.contains(CoreConnectCommand.socketScript))
        #expect(script.contains("export PATH=\"$1:"))
        #expect(script.hasSuffix("\"$p\" server status >/dev/null < /dev/null"))
        #expect(start.input.isEmpty == !inLoginSession)
        if inLoginSession {
            #expect(script.contains("launchctl bootstrap \"gui/$u\""))
            #expect(script.contains("<key>ProcessType</key><string>Interactive</string>"))
            #expect(script.contains("env -i PATH=\"$PATH\" HOME=\"$HOME\" HC_SOCKET=\"$HC_SOCKET\""))
            for name in ["HC_SESSION", "XDG_RUNTIME_DIR", "XDG_STATE_HOME"] {
                #expect(script.contains("${\(name)+\(name)=\"$\(name)\"}"))
            }
            let job = String(decoding: start.input, as: UTF8.self)
            // The binary's path is unset before `hc` starts the core, so no
            // terminal inherits it.
            #expect(job.contains(
                "cd \"$HOME\" && c=$WAYCAR_CORE_PATH && unset WAYCAR_CORE_PATH && \"$c\" server status >/dev/null"))
            #expect(job.contains("launchctl bootout"))
            #expect(!job.contains("LC_ALL"))
        }
    }

    @Test func theAttachLineIsAPtyExecOfAttachWithTheApcMarker() throws {
        let line = try CoreConnectCommand.attach(
            address: "box/t3", path: "/home/dev/.local/bin/herdr-core", loginPATH: nil)
        let script = line.components(separatedBy: "' core ")[0]
        #expect(
            script.hasSuffix(
                "printf \"\(AttachBootstrapHandshake.markerPrintfFormat)\"; exec \"$p\" attach \"$3\""))
        #expect(Self.arguments(of: line) == "'' /home/dev/.local/bin/herdr-core box/t3")
        // A core that stopped after the connection came up is never started
        // by the attach: the same socket probe runs first and exits 125.
        #expect(script.contains(CoreConnectCommand.socketScript))
        #expect(script.contains(
            "\(CoreConnectCommand.runningProbeScript) || { echo \"\(CoreConnectCommand.notRunningText)\" >&2; exit 125; }"))
        #expect(!script.dropFirst("/bin/sh -c '".count).contains("'"))
        // Exit 127 from this line is "not installed", 125 "not running".
        #expect(CoreConnectCommand.isCoreLine(line))
        #expect(
            HerdrHostPath.missingBinaryError(exitStatus: 127, command: line) == .coreNotInstalled)
        #expect(
            HerdrHostPath.missingBinaryError(exitStatus: 125, command: line) == .coreNotRunning)
        #expect(HerdrHostPath.missingBinaryError(exitStatus: 1, command: line) == nil)
        #expect(HerdrHostPath.missingBinaryError(exitStatus: 125, command: "herdr agent attach x") == nil)
    }

    @Test(arguments: ["", "t1'", "t1\\", "t\u{7}1", "t1\n"])
    func anAddressThatCannotBeQuotedIsRefused(_ address: String) {
        #expect(throws: TransportError.self) {
            _ = try CoreConnectCommand.attach(address: address, path: nil, loginPATH: nil)
        }
    }

    @Test func theLoginPathIsTheTextBetweenTheMarkersWhateverTheShellPrintedAround() {
        let marker = "@@WAYCAR-LOGIN-PATH@@"
        #expect(
            CoreLoginPath.parse("Welcome back\n\(marker)/home/a/.local/bin:/usr/bin\(marker)\nbye\n")
                == "/home/a/.local/bin:/usr/bin")
        #expect(CoreLoginPath.parse("no markers here: /usr/bin") == nil)
        #expect(CoreLoginPath.parse("\(marker)\(marker)") == nil)
        #expect(CoreLoginPath.parse("\(marker)/usr/bin\n:/bin\(marker)") == nil)
        #expect(CoreLoginPath.parse("\(marker)/usr/bin") == nil)
    }
}
