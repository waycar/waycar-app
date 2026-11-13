import Foundation

/// What one "Update Waycar on this Host" run asks the installer for (#209).
struct WaycarPluginUpdateRequest: Sendable, Equatable {
    /// The mode the Host's plugin is installed in; `.tmux` passes `--tmux`
    /// so a tmux install stays tmux even when herdr is also on the Host.
    /// Nil lets the installer pick (herdr when `herdr` resolves).
    var mode: WaycarPluginInstall.Mode?
    /// False passes `--no-hooks`: the agent status hooks and Chat Prompt
    /// extensions are left as they are.
    var refreshHooks: Bool
}

/// What a finished installer run reported.
struct WaycarPluginUpdateResult: Sendable, Equatable {
    /// The version from the installer's "installed Waycar …" line; nil when
    /// it printed none.
    var installedVersion: String?
    /// Every `waycar: warning:` line, in order.
    var warnings: [String]
    /// Whether the hooks step asked the user to trust Codex's hooks in `/hooks`.
    var codexHooksNeedReview: Bool
    /// Every line the run printed (stdout and stderr merged), marker excluded.
    var output: [String]
}

/// The update exec and the reading of its output: `install.sh` from
/// waycar.dev, downloaded to a temp file first and run with pairing off.
enum WaycarPluginUpdate {
    /// The last line the update exec prints: `<marker>=<installer exit status>`.
    /// The streaming exec reports no exit status, so the script prints it.
    static let exitMarker = "__WAYCAR_UPDATE_EXIT__"
    /// Installer runs (download, npm install, hooks) can take minutes.
    static let timeout: Duration = .seconds(300)

    static let errorPrefix = "waycar: error:"
    static let warningPrefix = "waycar: warning:"
    /// `agent-hooks.js` `CODEX_REVIEW_LINE`: "codex: open Codex and run
    /// /hooks to review and trust the Waycar hooks; …".
    static let codexReviewPhrase = "run /hooks to review"
    /// The error line when another update run holds the Host's lock.
    static let lockHeldMessage =
        "another Waycar update is running on this Host; try again in a few minutes"
    /// The error line when the lock directory cannot be created.
    static let lockCreateMessage = "could not create the update lock in ~/.local/share/waycar"

    /// A run that did not finish with exit status 0.
    struct Failure: Error, Sendable, Equatable {
        /// The last `waycar: error:` line, else the last non-empty line;
        /// nil when the run printed nothing.
        var line: String?
        /// The installer's exit status; nil when the exec ended without
        /// printing it (killed, or the connection dropped mid-run).
        var exitStatus: Int32?
        var output: [String]
    }

    /// One `/bin/sh -c` exec: no PTY, stdin closed, stderr merged into
    /// stdout, the herdr PATH added so `herdr` (and with it herdr mode),
    /// Homebrew curl and node resolve. `curl | sh` would hide a failed
    /// download behind sh's success, so the script downloads to a temp file,
    /// checks curl's status, then runs it. A `mkdir` lock under the user's
    /// `~/.local/share/waycar` keeps a Retry from racing an installer that
    /// outlived its channel (SIGPIPE is ignored before it is taken). The lock
    /// records its owner's pid: a live owner holds it; a dead owner's lock, or
    /// a pid-less one older than 10 minutes, is taken over; only the owning
    /// run removes it. The body holds no single quote.
    static func command(for request: WaycarPluginUpdateRequest) -> String {
        let url = WaycarPluginRequirement.installScriptURL
        let arguments = installerArguments(for: request)
        // EXIT and signal cleanup: the temp file, and the lock only when this
        // run took it (`k`) and still owns it; k is cleared so a signal's exit
        // cannot remove it twice.
        let cleanup = "[ -n \\\"\\$t\\\" ] && rm -f \\\"\\$t\\\"; "
            + "[ -n \\\"\\$k\\\" ] && [ \\\"\\$(cat \\\"\\$l/pid\\\" 2>/dev/null)\\\" = \\\"\\$\\$\\\" ] "
            + "&& rm -f \\\"\\$l/pid\\\" && rmdir \\\"\\$l\\\"; k="
        let lock = "mkdir -p \"$HOME/.local/share/waycar\" 2>/dev/null; "
            + "l=\"$HOME/.local/share/waycar/update.lock\"; "
            + "if mkdir \"$l\" 2>/dev/null; then k=1; "
            + "elif [ ! -d \"$l\" ]; then m=\"\(lockCreateMessage)\"; "
            + "else o=$(cat \"$l/pid\" 2>/dev/null); "
            + "if [ -n \"$o\" ] && kill -0 \"$o\" 2>/dev/null; then :; "
            + "elif [ -z \"$o\" ] && [ -z \"$(find \"$l\" -prune -mmin +10 2>/dev/null)\" ]; then :; "
            + "else rm -f \"$l/pid\"; rmdir \"$l\" 2>/dev/null && mkdir \"$l\" 2>/dev/null && k=1; fi; fi; "
            + "[ -n \"$k\" ] && echo $$ > \"$l/pid\"; "
        let script = "\(HerdrHostPath.pathExport); "
            + "s=1; t=; k=; m=; l=; "
            + "trap \"\(cleanup)\" EXIT; "
            + "trap \"\(cleanup); exit 129\" HUP INT TERM; "
            + "trap \"\" PIPE; "
            + lock
            + "if [ -n \"$m\" ]; then printf \"\(errorPrefix) %s\\n\" \"$m\"; "
            + "elif [ -z \"$k\" ]; then printf \"\(errorPrefix) %s\\n\" \"\(lockHeldMessage)\"; "
            + "elif ! command -v curl >/dev/null 2>&1; then "
            + "printf \"\(errorPrefix) %s\\n\" \"curl not found on this Host; install curl, then update again\"; "
            + "elif ! t=$(mktemp 2>/dev/null); then t=; "
            + "printf \"\(errorPrefix) %s\\n\" \"could not create a temporary file\"; "
            + "elif ! curl --proto =https --tlsv1.2 -fsSL \(url) -o \"$t\"; then "
            + "printf \"\(errorPrefix) could not download %s\\n\" \"\(url)\"; "
            + "else WAYCAR_NO_PAIR=1 sh \"$t\" \"$@\"; s=$?; fi; "
            + "printf \"\\n\(exitMarker)=%s\\n\" \"$s\"; exit $s"
        let suffix = arguments.isEmpty ? "" : " " + arguments.joined(separator: " ")
        return HostSSHSession.cLocaleCommand(
            "/bin/sh -c '\(script)' waycar-update\(suffix) </dev/null 2>&1")
    }

    /// The installer flags a request implies.
    static func installerArguments(for request: WaycarPluginUpdateRequest) -> [String] {
        var arguments: [String] = []
        if request.mode == .tmux { arguments.append("--tmux") }
        if !request.refreshHooks { arguments.append("--no-hooks") }
        return arguments
    }

    /// The command to run by hand on the Host for the same request.
    static func manualCommand(for request: WaycarPluginUpdateRequest) -> String {
        let base = "curl -fsSL \(WaycarPluginRequirement.installScriptURL) | sh"
        let arguments = installerArguments(for: request)
        return arguments.isEmpty ? base : base + " -s -- " + arguments.joined(separator: " ")
    }

    /// A `waycar: warning:` line without its prefix, for display.
    static func displayWarning(_ line: String) -> String {
        guard let range = line.range(of: warningPrefix) else { return line }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    /// The exit status from a marker line, nil for any other line.
    static func exitStatus(fromMarkerLine line: String) -> Int32? {
        let prefix = exitMarker + "="
        guard line.hasPrefix(prefix) else { return nil }
        return Int32(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces))
    }

    /// Reads a successful run's lines.
    static func result(fromOutput lines: [String]) -> WaycarPluginUpdateResult {
        let output = lines.filter { exitStatus(fromMarkerLine: $0) == nil }
        return WaycarPluginUpdateResult(
            installedVersion: output.reversed().lazy.compactMap(installedVersion(in:)).first,
            warnings: output.filter { $0.contains(warningPrefix) },
            codexHooksNeedReview: output.contains { $0.contains(codexReviewPhrase) },
            output: output)
    }

    /// `install.sh` prints "waycar: installed Waycar plugin <v>" (herdr) or
    /// "waycar: installed Waycar <v> in <dir>" (the Host Tools alone: tmux or
    /// herdr-core). Plugins before 2.2.1 wrote the second as "... <v> for
    /// tmux in <dir>", also on a Host with no tmux; both read.
    static func installedVersion(in line: String) -> String? {
        let herdr = "waycar: installed Waycar plugin "
        let tools = "waycar: installed Waycar "
        let rest: Substring
        if line.hasPrefix(herdr) {
            rest = line.dropFirst(herdr.count)
        } else if line.hasPrefix(tools), line.contains(" in ") {
            rest = line.dropFirst(tools.count)
        } else {
            return nil
        }
        return rest.split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    /// The failure a run's lines describe: the last error line, else the
    /// last non-empty line.
    static func failure(fromOutput lines: [String], exitStatus: Int32?) -> Failure {
        let output = lines.filter { self.exitStatus(fromMarkerLine: $0) == nil }
        let trimmed = output.map { $0.trimmingCharacters(in: .whitespaces) }
        let line = trimmed.last { $0.contains(errorPrefix) } ?? trimmed.last { !$0.isEmpty }
        return Failure(line: line, exitStatus: exitStatus, output: output)
    }

    /// Splits exec output into lines, `\r\n` and `\r` included; empty
    /// lines (such as the one before the exit marker) are dropped.
    static func lines(fromOutput output: Data) -> [String] {
        String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }
}

extension WaycarPluginUpdate.Failure: LocalizedError {
    /// The installer's error line without `waycar: error: `, capitalized,
    /// else the last line with the exit status.
    var errorDescription: String? {
        let status = exitStatus.map { " (exit status \($0))" } ?? ""
        guard let line else { return "The Waycar installer failed\(status)." }
        if let range = line.range(of: WaycarPluginUpdate.errorPrefix) {
            let message = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let first = message.first else { return "The Waycar installer failed\(status)." }
            return first.uppercased() + message.dropFirst()
        }
        return line + status
    }
}
