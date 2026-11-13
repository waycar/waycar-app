import Foundation

/// Where `herdr` actually lives on Hosts that install it via Homebrew,
/// linuxbrew, cargo, or a user-local prefix.
///
/// SSH exec is not a login shell: sshd's default `PATH` is typically
/// `/usr/bin:/bin`, so a Host that can run `herdr` interactively still
/// answers `exec: herdr: not found` (exit 127) on Attach. The API socket
/// path does not need the binary — that is why the Console can list Agents
/// while the PTY Attach dies (#206).
///
/// Extra prefixes are appended after the session `PATH` so an existing
/// `herdr` keeps priority. There is no separate probe to discover the
/// `herdr` path; the agent-availability probe reuses this export in its
/// shell body instead of adding another SSH round trip.
///
/// Two ways the prefixes get onto a command, pick by how `herdr` is spelled:
/// - ``wrappingBareHerdr(_:)`` at the exec site when the command *word* is
///   still an unpathed `herdr` (session list, plugin list, and those
///   overrides).
/// - Bake ``pathExport`` into an existing `/bin/sh -c` body when a bare
///   `herdr` or an agent probe lives inside that body. The default plugin
///   config-dir and agent-discovery commands use this form. Wrapping looks
///   only at the command word, so it cannot see an inner `herdr`.
enum HerdrHostPath: Sendable {
    /// Directories appended to `PATH` on herdr CLI and Agent discovery
    /// execs. `$HOME` and the parameter expansions are evaluated by the
    /// remote `/bin/sh`, not by Swift.
    ///
    /// mise exposes its tools to non-interactive shells through its shims
    /// directory (#293); `mise activate` lives in interactive rc files the
    /// probe never reads. The expansion follows mise's own resolution order,
    /// `MISE_DATA_DIR`, then `XDG_DATA_HOME/mise`, then
    /// `~/.local/share/mise`, but only sees a value that reaches the
    /// non-interactive environment. One set solely in `.zshrc` or `.bashrc`
    /// still resolves to the default.
    static let extraPATH = "\(homeExtraPATH):\(systemExtraPATH)"

    /// `extraPATH`'s directories in the account's own home (mise's shims
    /// included), searched first.
    static let homeExtraPATH =
        "$HOME/.local/bin:\(miseShims):$HOME/.linuxbrew/bin:$HOME/.cargo/bin:$HOME/.bun/bin"

    /// `extraPATH`'s machine-wide install prefixes. Real-SSH fixtures leave
    /// them out of backend detection (`SSHTransportSettings
    /// .detectionSearchesSystemDirectories`): they hold the runner's own CLIs.
    static let systemExtraPATH = "/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin"

    /// The Herdr app's own search list for herdr-core beyond `extraPATH`
    /// (design C14): the Nix profile and NixOS's system profile. Kept apart
    /// from `extraPATH`, which commands pinned against the plugin share, so
    /// only herdr-core's detection and exec lines carry them.
    static let coreExtraPATH = "\(coreHomeExtraPATH):/run/current-system/sw/bin"

    /// `coreExtraPATH`'s directory in the account's home.
    static let coreHomeExtraPATH = "$HOME/.nix-profile/bin"

    /// POSIX sh expansion of mise's shims directory.
    static let miseShims = "${MISE_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/mise}/shims"

    static var pathAssignment: String {
        "PATH=\"$PATH:\(extraPATH)\""
    }

    static var pathExport: String {
        "export \(pathAssignment)"
    }

    /// `pathExport` plus herdr-core's directories, for the lines that run
    /// `herdr-core`.
    static var corePathExport: String {
        "export PATH=\"$PATH:\(extraPATH):\(coreExtraPATH)\""
    }

    /// True when `command` invokes an unpathed `herdr` as its command word.
    /// Leading `NAME=value` assignments are skipped, so `HERDR_X=1 herdr …`
    /// still counts. Quoted literals (`'herdr: not json'`), `ENV=herdr` in
    /// front of another command, and absolute injectables (`/opt/herdr-wake`,
    /// `/nonexistent/herdr`) stay false.
    static func isBareHerdrCommand(_ command: String) -> Bool {
        commandWord(in: command) == "herdr"
    }

    /// The same for an unpathed `herdr-core`, the binary the app runs for
    /// herdr-core (never bare `hc`: some window managers ship another `hc`).
    static func isBareCoreCommand(_ command: String) -> Bool {
        commandWord(in: command) == "herdr-core"
    }

    /// Wraps a still-bare `herdr …` or `herdr-core …` in `/bin/sh` so the
    /// extra prefixes are visible even when the account shell is fish
    /// (`$PATH` is a list there). The wrap therefore runs under POSIX sh, not
    /// the login shell: a `herdr` that exists only as a shell function or
    /// alias is not visible. Injectable commands whose command word is
    /// neither are unchanged. Embedded single quotes are escaped with `'\''`
    /// so a per-Host override such as `herdr --config '/x/y' session list`
    /// still gets the PATH fix.
    static func wrappingBareHerdr(_ command: String) -> String {
        let isCore = isBareCoreCommand(command)
        guard isBareHerdrCommand(command) || isCore else { return command }
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        return "/bin/sh -c '\(isCore ? corePathExport : pathExport); exec \(escaped)'"
    }

    /// Exit 127 from a still-bare `herdr` is the PATH miss (#206); from one
    /// of herdr-core's own exec lines (`CoreConnectCommand`, which exits 127
    /// only when it finds no binary) it is `coreNotInstalled`, and their own
    /// exit 125 is the socket probe's `coreNotRunning`. Any other status, or
    /// an injectable command, is left for the caller.
    static func missingBinaryError(
        exitStatus: Int32, command: String
    ) -> TransportError? {
        if exitStatus == CoreConnectCommand.notRunningStatus, CoreConnectCommand.isCoreLine(command) {
            return .coreNotRunning
        }
        guard exitStatus == 127 else { return nil }
        if CoreConnectCommand.isCoreLine(command) { return .coreNotInstalled }
        guard isBareHerdrCommand(command) else { return nil }
        return .herdrBinaryNotFound
    }

    private static func commandWord(in command: String) -> Substring? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(whereSeparator: \.isWhitespace)
            .first { !isEnvironmentAssignment($0) }
    }

    /// POSIX `NAME=value` words a shell would consume before the command.
    private static func isEnvironmentAssignment(_ word: Substring) -> Bool {
        guard let separator = word.firstIndex(of: "="), separator > word.startIndex else {
            return false
        }
        let name = word[..<separator]
        guard let first = name.first, first.isASCII else { return false }
        guard first.isLetter || first == "_" else { return false }
        return name.dropFirst().allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "_")
        }
    }
}
