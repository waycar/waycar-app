import Foundation
import Testing

@testable import Waycar

struct WaycarPluginUpdateTests {
    /// The single-quoted `/bin/sh -c` body and what follows the closing quote.
    private func split(_ command: String) -> (body: Substring, tail: Substring)? {
        guard let open = command.range(of: "/bin/sh -c '") else { return nil }
        let rest = command[open.upperBound...]
        guard let close = rest.firstIndex(of: "'") else { return nil }
        return (rest[..<close], rest[rest.index(after: close)...])
    }

    @Test(arguments: [
        (WaycarPluginUpdateRequest(mode: nil, refreshHooks: true), ""),
        (WaycarPluginUpdateRequest(mode: .herdr, refreshHooks: true), ""),
        (WaycarPluginUpdateRequest(mode: .tmux, refreshHooks: true), " --tmux"),
        (WaycarPluginUpdateRequest(mode: nil, refreshHooks: false), " --no-hooks"),
        (WaycarPluginUpdateRequest(mode: .tmux, refreshHooks: false), " --tmux --no-hooks"),
    ])
    func commandPassesArguments(request: WaycarPluginUpdateRequest, arguments: String) throws {
        let command = WaycarPluginUpdate.command(for: request)
        let parts = try #require(split(command))
        // The body closes at the only other quote: nothing after it reopens one.
        #expect(!parts.tail.contains("'"))
        #expect(parts.tail == " waycar-update\(arguments) </dev/null 2>&1")
    }

    @Test func commandDownloadsToATempFileBeforeRunning() throws {
        let command = WaycarPluginUpdate.command(for: .init(mode: nil, refreshHooks: true))
        #expect(command.hasPrefix("LC_ALL=C /bin/sh -c '"))
        let body = String(try #require(split(command)).body)
        #expect(body.hasPrefix(HerdrHostPath.pathExport + "; "))
        #expect(body.contains("t=$(mktemp"))
        #expect(body.contains("trap "))
        #expect(body.contains("command -v curl"))
        #expect(body.contains("curl --proto =https --tlsv1.2 -fsSL https://waycar.dev/install.sh -o \"$t\""))
        #expect(body.contains("waycar: error: could not download"))
        #expect(body.contains("WAYCAR_NO_PAIR=1 sh \"$t\" \"$@\""))
        #expect(!body.contains("| sh"))
        // Download precedes the run, and the exit marker comes last.
        let download = try #require(body.range(of: "curl --proto"))
        let run = try #require(body.range(of: "WAYCAR_NO_PAIR=1"))
        #expect(download.lowerBound < run.lowerBound)
        #expect(body.hasSuffix("printf \"\\n\(WaycarPluginUpdate.exitMarker)=%s\\n\" \"$s\"; exit $s"))
    }

    /// `scripts/ci/node-era-upgrade-check.sh` runs these exact commands over
    /// sshd against a Host that has the Node version installed. A change to
    /// the command must change the fixtures, so the proof keeps running what
    /// the app runs.
    @Test(arguments: [
        (WaycarPluginUpdateRequest(mode: .tmux, refreshHooks: true), "waycar-update-command.tmux.txt"),
        (WaycarPluginUpdateRequest(mode: .tmux, refreshHooks: false), "waycar-update-command.tmux-no-hooks.txt"),
    ])
    func commandMatchesTheUpgradeProofFixture(request: WaycarPluginUpdateRequest, fixture: String) throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WaycarTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let url = repoRoot.appendingPathComponent("scripts/ci/fixtures/\(fixture)")
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(WaycarPluginUpdate.command(for: request) + "\n" == text)
    }

    @Test func parsesHerdrSuccess() {
        let lines = [
            "waycar: downloading plugin 1.4.0",
            "waycar: installed Waycar plugin 1.4.0",
            "waycar: installing agent status hooks",
            "claude: updated ~/.claude/settings.json",
            "codex: open Codex and run /hooks to review and trust the Waycar hooks; Codex skips them until then",
            "waycar: warning: agent status hooks were not installed; retry: waycar hooks install",
            "\(WaycarPluginUpdate.exitMarker)=0",
        ]
        let result = WaycarPluginUpdate.result(fromOutput: lines)
        #expect(result.installedVersion == "1.4.0")
        #expect(result.codexHooksNeedReview)
        #expect(result.warnings == [lines[5]])
        #expect(result.output == Array(lines.dropLast()))
    }

    @Test func parsesTmuxSuccessWithoutCodex() {
        let result = WaycarPluginUpdate.result(fromOutput: [
            "waycar: setting Waycar up for tmux (--tmux)",
            "waycar: installed Waycar 1.4.0-beta.1 for tmux in /home/me/.local/share/waycar",
        ])
        #expect(result.installedVersion == "1.4.0-beta.1")
        #expect(!result.codexHooksNeedReview)
        #expect(result.warnings.isEmpty)
    }

    @Test func noInstalledLineMeansNoVersion() {
        let result = WaycarPluginUpdate.result(fromOutput: ["waycar: installed Waycar somewhere else"])
        #expect(result.installedVersion == nil)
    }

    @Test func failurePrefersTheLastErrorLine() {
        let failure = WaycarPluginUpdate.failure(
            fromOutput: [
                "curl: (22) The requested URL returned error: 503",
                "waycar: error: could not download https://waycar.dev/install.sh",
                "",
                "\(WaycarPluginUpdate.exitMarker)=1",
            ],
            exitStatus: 1)
        #expect(failure.line == "waycar: error: could not download https://waycar.dev/install.sh")
        #expect(failure.exitStatus == 1)
        #expect(failure.output.count == 3)
    }

    @Test func failureFallsBackToTheLastNonEmptyLine() {
        let failure = WaycarPluginUpdate.failure(
            fromOutput: ["npm ERR! network", "  ", ""], exitStatus: nil)
        #expect(failure.line == "npm ERR! network")
        #expect(failure.exitStatus == nil)
        #expect(WaycarPluginUpdate.failure(fromOutput: [], exitStatus: 2).line == nil)
    }

    @Test func readsTheExitMarker() {
        #expect(WaycarPluginUpdate.exitStatus(fromMarkerLine: "__WAYCAR_UPDATE_EXIT__=127") == 127)
        #expect(WaycarPluginUpdate.exitStatus(fromMarkerLine: "__WAYCAR_UPDATE_EXIT__=") == nil)
        #expect(WaycarPluginUpdate.exitStatus(fromMarkerLine: "waycar: done") == nil)
    }

    @Test func splitsCRLFOutput() {
        #expect(WaycarPluginUpdate.lines(fromOutput: Data("a\r\nb\rc\n".utf8)) == ["a", "b", "c"])
    }
    @Test func failureDescribesItself() {
        let download = WaycarPluginUpdate.Failure(
            line: "waycar: error: could not download x", exitStatus: 1, output: [])
        #expect(download.errorDescription == "Could not download x")
        let other = WaycarPluginUpdate.Failure(line: "npm ERR! network", exitStatus: 1, output: [])
        #expect(other.errorDescription == "npm ERR! network (exit status 1)")
    }

    @Test func signalsCleanUpAndExitAndADroppedChannelCannotKillTheInstaller() throws {
        let body = String(try #require(split(WaycarPluginUpdate.command(for: .init(mode: nil, refreshHooks: true)))).body)
        // EXIT only cleans; HUP/INT/TERM clean and exit. The lock goes only
        // when this run took it and its pid file still names this shell, and once.
        let cleanup = "[ -n \\\"\\$t\\\" ] && rm -f \\\"\\$t\\\"; "
            + "[ -n \\\"\\$k\\\" ] && [ \\\"\\$(cat \\\"\\$l/pid\\\" 2>/dev/null)\\\" = \\\"\\$\\$\\\" ] "
            + "&& rm -f \\\"\\$l/pid\\\" && rmdir \\\"\\$l\\\"; k="
        #expect(body.contains("trap \"\(cleanup)\" EXIT; "))
        #expect(body.contains("trap \"\(cleanup); exit 129\" HUP INT TERM; "))
        // SIGPIPE is ignored after the signal traps and before the lock, so
        // the installer inherits it.
        let signals = try #require(body.range(of: " HUP INT TERM; "))
        let pipe = try #require(body.range(of: "trap \"\" PIPE; "))
        let take = try #require(body.range(of: "if mkdir \"$l\" 2>/dev/null; then k=1; "))
        let run = try #require(body.range(of: "WAYCAR_NO_PAIR=1 sh"))
        #expect(signals.upperBound <= pipe.lowerBound)
        #expect(pipe.upperBound <= take.lowerBound)
        #expect(take.upperBound <= run.lowerBound)
    }

    @Test func aPerUserLockIsTakenBeforeTheDownload() throws {
        let body = String(try #require(split(WaycarPluginUpdate.command(for: .init(mode: nil, refreshHooks: true)))).body)
        #expect(body.contains("mkdir -p \"$HOME/.local/share/waycar\" 2>/dev/null; "))
        #expect(body.contains("l=\"$HOME/.local/share/waycar/update.lock\"; "))
        #expect(!body.contains("TMPDIR"))
        // A lock that cannot be created fails with its own message.
        #expect(body.contains("elif [ ! -d \"$l\" ]; then m=\"\(WaycarPluginUpdate.lockCreateMessage)\"; "))
        #expect(body.contains("if [ -n \"$m\" ]; then printf \"waycar: error: %s\\n\" \"$m\"; "))
        // A live owner holds the lock; a dead owner's, or a pid-less one
        // older than 10 minutes, is taken over and stamped with this pid.
        #expect(body.contains("o=$(cat \"$l/pid\" 2>/dev/null); "))
        #expect(body.contains("if [ -n \"$o\" ] && kill -0 \"$o\" 2>/dev/null; then :; "))
        #expect(body.contains(
            "elif [ -z \"$o\" ] && [ -z \"$(find \"$l\" -prune -mmin +10 2>/dev/null)\" ]; then :; "))
        #expect(body.contains("else rm -f \"$l/pid\"; rmdir \"$l\" 2>/dev/null && mkdir \"$l\" 2>/dev/null && k=1; fi; fi; "))
        #expect(body.contains("[ -n \"$k\" ] && echo $$ > \"$l/pid\"; "))
        #expect(body.contains(
            "printf \"waycar: error: %s\\n\" \"another Waycar update is running on this Host; try again in a few minutes\"; "))
        // Traps, then the lock, then the held checks, then the download.
        let traps = try #require(body.range(of: " PIPE; "))
        let take = try #require(body.range(of: "if mkdir \"$l\" 2>/dev/null; then k=1; "))
        let stamp = try #require(body.range(of: "echo $$ > \"$l/pid\"; "))
        let held = try #require(body.range(of: "if [ -n \"$m\" ]; then "))
        let download = try #require(body.range(of: "curl --proto"))
        #expect(traps.upperBound <= take.lowerBound)
        #expect(take.upperBound <= stamp.lowerBound)
        #expect(stamp.upperBound <= held.lowerBound)
        #expect(held.upperBound <= download.lowerBound)
        #expect(!body.contains("'"))
        let failure = WaycarPluginUpdate.failure(
            fromOutput: ["waycar: error: \(WaycarPluginUpdate.lockHeldMessage)"], exitStatus: 1)
        #expect(failure.errorDescription == "Another Waycar update is running on this Host; try again in a few minutes")
    }

    @Test func markerAfterAnUnterminatedLineStillParses() {
        let lines = WaycarPluginUpdate.lines(
            fromOutput: Data("waycar: installed Waycar plugin 1.4.0\npartial\n\(WaycarPluginUpdate.exitMarker)=0\n".utf8))
        #expect(lines == ["waycar: installed Waycar plugin 1.4.0", "partial", "\(WaycarPluginUpdate.exitMarker)=0"])
        #expect(WaycarPluginUpdate.exitStatus(fromMarkerLine: lines[2]) == 0)
        #expect(WaycarPluginUpdate.result(fromOutput: lines).output == Array(lines.prefix(2)))
    }

    @Test(arguments: [
        (WaycarPluginUpdateRequest(mode: nil, refreshHooks: true), "curl -fsSL https://waycar.dev/install.sh | sh"),
        (WaycarPluginUpdateRequest(mode: .herdr, refreshHooks: true), "curl -fsSL https://waycar.dev/install.sh | sh"),
        (WaycarPluginUpdateRequest(mode: .tmux, refreshHooks: true), "curl -fsSL https://waycar.dev/install.sh | sh -s -- --tmux"),
        (WaycarPluginUpdateRequest(mode: nil, refreshHooks: false), "curl -fsSL https://waycar.dev/install.sh | sh -s -- --no-hooks"),
        (WaycarPluginUpdateRequest(mode: .tmux, refreshHooks: false),
         "curl -fsSL https://waycar.dev/install.sh | sh -s -- --tmux --no-hooks"),
    ])
    func manualCommandMatchesTheRequest(request: WaycarPluginUpdateRequest, expected: String) {
        #expect(WaycarPluginUpdate.manualCommand(for: request) == expected)
    }

    @Test func warningsDisplayWithoutThePrefix() {
        #expect(WaycarPluginUpdate.displayWarning("waycar: warning: hooks skipped") == "hooks skipped")
        #expect(WaycarPluginUpdate.displayWarning("plain") == "plain")
    }
}
