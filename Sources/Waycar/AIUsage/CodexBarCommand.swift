import Foundation

/// The Host-side commands behind AI Usage: finding the CodexBar CLI and
/// running it. Both run under POSIX `/bin/sh` because login shells do not
/// share syntax (#275), take user-supplied paths only as positional
/// arguments, and frame their answer with a marker so login-shell noise is
/// harmless.
enum CodexBarCommand {
    static let foundMarker = "__WAYCAR_CODEXBAR__="

    /// A non-interactive SSH exec's PATH omits Homebrew, linuxbrew and
    /// `~/.local/bin`, so auto-detection asks `command -v` under
    /// `HerdrHostPath`'s PATH first, then checks the macOS app bundle's
    /// helper (system and user Applications), which no PATH names. `$HOME`
    /// is expanded by the remote shell.
    static let appBundleCandidates = [
        "/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
        "$HOME/Applications/CodexBar.app/Contents/Helpers/CodexBarCLI",
    ]

    /// The app's whole budget for one `usage` run, channel wait included:
    /// ``hostDeadlineSeconds`` plus 5 seconds of slack (the watchdog checks
    /// once a second), so a run the app gave up on never keeps its SSH
    /// session (and a `MaxSessions` slot) busy.
    static let usageTimeout: Duration = .seconds(60)

    /// Each provider's web fetch gives up after this many seconds (CodexBar's
    /// own default is 60, longer than the whole budget).
    static let webTimeoutSeconds = 15

    /// The Host-side script stops by this many seconds after it starts:
    /// ``serveHealthSeconds`` and ``serveUsageSeconds`` on a server, then the
    /// CLI in whatever remains, at most ``watchdogSeconds``.
    static let hostDeadlineSeconds = 55

    /// The Host-side watchdog stops a CLI run still going after this many
    /// seconds, or sooner when ``hostDeadlineSeconds`` comes first. 30
    /// seconds still fits two providers' ``webTimeoutSeconds``.
    static let watchdogSeconds = 30

    /// How long the Host waits on a local `codexbar serve`'s `/health`. It
    /// answers in well under a millisecond, and a Host without one refuses
    /// the connection at once; only a hung server spends this.
    static let serveHealthSeconds = 2

    /// How long a healthy server gets to answer `/usage`: longer than the
    /// Keychain Fix's server works on any provider
    /// (``CodexBarServe/providerBudgetSeconds``; 24 seconds for one started
    /// with CodexBar's defaults). A warm server answers at once with its last
    /// report, but one whose last report had an error keeps none: it fetches
    /// every provider again, and its answer waits for the slowest. Claude's
    /// CLI fetch took 31 seconds on a Mac whose Claude plan shows no session
    /// window, so the old 10-second wait read that server as failed every
    /// time and fell back to the CLI, which over SSH cannot read Claude at
    /// all.
    static let serveUsageSeconds = 50

    /// The line the script prints before a server's answer, so the app
    /// knows the report came from the Host's GUI session, not the CLI.
    static let serverSourceMarker = "WAYCAR-CODEXBAR-SOURCE server"

    /// The line the script prints before a CLI run on a Mac (`uname -s` is
    /// Darwin), where some CLI errors mean the keychain is out of reach.
    static let macOSHostMarker = "WAYCAR-CODEXBAR-HOST macOS"

    /// CLI arrays are framed independently: a failed or interrupted account
    /// supplement must never hide the enabled-provider report.
    static let cliBaseStartMarker = "WAYCAR-CODEXBAR-BASE"
    static let cliBaseEndMarker = "WAYCAR-CODEXBAR-BASE-END"
    static let codexAccountsStartMarker = "WAYCAR-CODEXBAR-CODEX-ACCOUNTS"
    static let codexAccountsEndMarker = "WAYCAR-CODEXBAR-CODEX-ACCOUNTS-END"

    /// Auto-detection, or — with a custom path — a check of that path alone.
    /// Always exits 0; the marker line is the only answer.
    static func locateCommand(customPath: String?) throws -> String {
        let report = "printf \"\(foundMarker)%s\\n\" \"$c\""
        guard let customPath else {
            let candidates = appBundleCandidates.map { "\"\($0)\"" }.joined(separator: " ")
            let script = "\(HerdrHostPath.pathExport); "
                + "c=$(command -v codexbar 2>/dev/null); "
                + "case $c in /*) \(report); exit 0;; esac; "
                + "for c in \(candidates); do "
                + "if [ -f \"$c\" ] && [ -x \"$c\" ]; then \(report); exit 0; fi; done; exit 0"
            return "/bin/sh -c '\(script)' waycar-codexbar-probe"
        }
        let quoted = try quotedCustomPath(customPath)
        let script = "c=$1; "
            + "case $c in \"~/\"*) c=\"$HOME/${c#\"~/\"}\";; esac; "
            + "if [ -f \"$c\" ] && [ -x \"$c\" ]; then \(report); fi; exit 0"
        return "/bin/sh -c '\(script)' waycar-codexbar-probe \(quoted)"
    }

    /// First asks a `codexbar serve` running in the Host's GUI session
    /// (``CodexBarServe``), which can read the login keychain an SSH session
    /// cannot: a `/health` probe bounded by ``serveHealthSeconds``, then
    /// `/usage` bounded by ``serveUsageSeconds``. Its answer counts only when
    /// it is a JSON array, and is printed after ``serverSourceMarker``.
    /// `curl -q` skips the user's `.curlrc` and `--noproxy` any proxy
    /// variables, so neither can redirect a loopback request. A healthy
    /// server that runs out of time ends the run as timed out (143): only it
    /// can read the keychain, so the CLI is no stand-in, and no time is left
    /// for one anyway. Otherwise — no server, no curl, an error or non-array
    /// body — prints ``macOSHostMarker`` on a Mac and runs the
    /// enabled-provider CLI report, then supplements Codex
    /// with a single-provider all-accounts report only when Codex was
    /// enabled. Both share one deadline, ``watchdogSeconds`` or what
    /// ``hostDeadlineSeconds`` leaves; the supplement gets only what remains
    /// and cannot change the base exit status. Paths stay positional, and
    /// `HerdrHostPath` lets CLI fallbacks find `codex` and `claude` in the
    /// SSH session.
    static func usageCommand(executablePath: String, port: Int = CodexBarServe.port) throws -> String {
        guard let quoted = RemoteShellPath.quotedAbsolute(executablePath) else {
            throw CodexBarError.invalidPath
        }
        let base = "http://127.0.0.1:\(port)"
        let curl = "curl -q -fsS --noproxy 127.0.0.1 --max-time"
        let serve = "end=$(($(date +%s) + \(hostDeadlineSeconds))); "
            + "if \(curl) \(serveHealthSeconds) \(base)/health >/dev/null 2>&1; then "
            + "out=$(\(curl) \(serveUsageSeconds) \(base)/usage 2>/dev/null); served=$?; "
            + "[ \"$served\" -ne 28 ] || exit \(HostWatchdog.stoppedStatus); "
            + "[ \"$served\" -eq 0 ] && case ${out#\"${out%%[![:space:]]*}\"} in \"[\"*) "
            + "printf \"%s\\n%s\\n\" \"\(serverSourceMarker)\" \"$out\"; exit 0;; esac; fi; "
        let fallback = "[ \"$(uname -s 2>/dev/null)\" != Darwin ] || "
            + "printf \"%s\\n\" \"\(macOSHostMarker)\"; "
            + "limit=$((end - $(date +%s))); "
            + "[ \"$limit\" -le \(watchdogSeconds) ] || limit=\(watchdogSeconds); "
            + "[ \"$limit\" -gt 0 ] || exit \(HostWatchdog.stoppedStatus); "
            + "deadline=$(($(date +%s) + limit)); "
            + "out=$(waycar_watch \"$limit\" "
            + "\"$1\" usage --format json --web-timeout \(webTimeoutSeconds)); status=$?; "
            + "printf \"%s\\n%s\\n%s\\n\" \"\(cliBaseStartMarker)\" \"$out\" \"\(cliBaseEndMarker)\"; "
            + "case $status in 126|127|143) exit \"$status\";; esac; "
            + "remaining=$((deadline - $(date +%s))); "
            + "if [ \"$remaining\" -gt 0 ] && "
            + "printf \"%s\\n\" \"$out\" | grep -Eq "
            + "\"\\\"provider\\\"[[:space:]]*:[[:space:]]*\\\"codex\\\"\"; then "
            + "accounts=$(waycar_watch \"$remaining\" \"$1\" usage --provider codex "
            + "--all-accounts --format json --web-timeout \(webTimeoutSeconds)); account_status=$?; "
            + "printf \"%s\\n%s\\n%s %s\\n\" \"\(codexAccountsStartMarker)\" \"$accounts\" "
            + "\"\(codexAccountsEndMarker)\" \"$account_status\"; fi; exit \"$status\""
        let script = "\(HerdrHostPath.pathExport); \(HostWatchdog.definition); "
            + serve + fallback
        return "/bin/sh -c '\(script)' waycar-codexbar \(quoted)"
    }

    /// What a `usage` exit status says before its output is read: 126/127
    /// are the shell failing to run the path, 143 (SIGTERM) the run out of
    /// time (the watchdog stopping the CLI, or a server that never
    /// answered). Any other status still carries a report — the CLI exits
    /// nonzero whenever one provider failed.
    static func usageFailure(exitStatus: Int32) -> CodexBarError? {
        switch exitStatus {
        case 126, 127: .executableMissing
        case 128 + SIGTERM: .timedOut
        default: nil
        }
    }

    /// The executable the probe reported, or nil when it found none. Only an
    /// absolute, shell-quotable path counts: it is what the usage command
    /// will be handed.
    static func locatedPath(in output: Data) -> String? {
        String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .reversed()
            .lazy
            .compactMap { line -> String? in
                guard line.hasPrefix(foundMarker) else { return nil }
                var value = String(line.dropFirst(foundMarker.count))
                if value.last == "\r" { value.removeLast() }
                return RemoteShellPath.isQuotableAbsolute(value) ? value : nil
            }
            .first
    }

    /// A custom path must be absolute or home-relative (`~/…`); quotes,
    /// backslashes and control characters are refused like every other
    /// remote path.
    static func quotedCustomPath(_ path: String) throws -> String {
        if path.hasPrefix("~/"),
            let quoted = RemoteShellPath.quotedAbsolute("/" + path.dropFirst(2))
        {
            return "'~/" + quoted.dropFirst(2)
        }
        guard let quoted = RemoteShellPath.quotedAbsolute(path) else {
            throw CodexBarError.invalidPath
        }
        return quoted
    }

    static func isValidCustomPath(_ path: String) -> Bool {
        (try? quotedCustomPath(path)) != nil
    }
}

/// A `codexbar serve` the user runs as a LaunchAgent in the Host's GUI
/// session. Over SSH the login keychain is locked away, so the CLI cannot
/// read browser cookies; the server, started in the GUI session, can.
enum CodexBarServe {
    static let port = 48731
    static let launchAgentLabel = "dev.waycar.codexbar-serve"

    /// The `--request-timeout` the Keychain Fix gives the server. CodexBar's
    /// default, 30 seconds, leaves each provider 24, and Claude's CLI fetch
    /// can take 31 (CodexBar 0.84.0 waits out its whole 20-second `/usage`
    /// capture when the plan shows no session window, then runs `/status`).
    static let requestTimeoutSeconds = 60

    /// How long CodexBar 0.84.0's server works on one provider for `/usage`
    /// before it answers that provider with "<provider> usage timed out":
    /// 0.8 of its request timeout (`serveProviderTimeout`, source review).
    static let providerBudgetSeconds = requestTimeoutSeconds * 4 / 5
}

/// CodexBar's own failures. None is a link failure: a slow or broken CLI
/// must never make the Console redial the Host or replay the run.
enum CodexBarError: Error, Equatable, Sendable {
    /// What a CodexBar run or probe throws for `error`: running out of time
    /// — the app's deadline or the SSH exec's own — is ``timedOut``, never
    /// `TransportError.timedOut`, which the Console takes for a dead link.
    /// Everything else passes through.
    static func replacingTimeout(_ error: any Error) -> any Error {
        if error as? AsyncDeadlineError == .timedOut || error as? TransportError == .timedOut {
            return CodexBarError.timedOut
        }
        return error
    }

    /// A custom path that is not absolute (or `~/`) or cannot be quoted.
    case invalidPath
    /// The detected executable is gone (exit 126/127).
    case executableMissing
    /// The run (or probe) outlasted its budget or was stopped by the
    /// Host-side watchdog.
    case timedOut
    /// The CLI printed nothing parseable.
    case unreadableOutput(detail: String)

    var message: String {
        switch self {
        case .invalidPath:
            "The path must start with / or ~/ and cannot contain quotes or backslashes."
        case .executableMissing:
            "CodexBar is no longer at the detected path."
        case .timedOut:
            "CodexBar took too long to answer."
        case .unreadableOutput(let detail):
            detail.isEmpty ? "CodexBar returned no usage data." : detail
        }
    }
}
