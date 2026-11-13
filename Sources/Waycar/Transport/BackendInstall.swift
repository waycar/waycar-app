import Foundation

/// What an "Install Herdr TUI", "Install tmux" or "Install herdr-core" run
/// installs (WAY-338, WAY-483).
enum BackendInstallTarget: Sendable, Equatable, Hashable {
    /// herdr's own installer from herdr.dev, run as the account: one file in
    /// `~/.local/bin`, no admin rights.
    case herdr
    /// herdr-core's own installer from releases.herdr.dev, run as the
    /// account: `herdr-core` in `~/.local/bin` (and an `hc` link there unless
    /// an `hc` exists), no admin rights.
    case core
    /// tmux from the Host's package manager.
    case tmux(HostPackageManager)

    var backend: HostBackend {
        switch self {
        case .herdr: .herdr
        case .core: .core
        case .tmux: .tmux
        }
    }
}

/// Why an install did not leave the backend on the Host, from a fixed list:
/// the UI maps each case to copy, never to a log line. Only `other` carries
/// text, and only for a "something else went wrong" row.
enum BackendInstallFailure: Error, Sendable, Equatable {
    /// herdr's installer needs curl and the Host has none.
    case noCurl
    /// herdr-core's installer needs tar (`hc: needs tar`) and the Host has
    /// none. Only the installer checks it, so only a run can find out.
    case noTar
    /// The Host could not download herdr's installer or what it fetches.
    case cannotReachInstaller
    /// The package manager needs root and `sudo -n` was refused, or the
    /// Host has no sudo. Waycar never asks for a password.
    case needsAdmin
    /// No manager Waycar can run (`HostPackageManager`).
    case noPackageManager
    /// The install worked, but tmux is under the floor (`minimumTmuxVersion`).
    /// `found` is the version `tmux -V` reports.
    case tmuxTooOld(found: String)
    /// herdr's or herdr-core's installer refuses the system (Android and
    /// Termux, other operating systems and architectures).
    case unsupportedSystem
    /// None of the above: the last line the run printed, if any.
    case other(lastLine: String?)
}

/// How a finished install ended. An install is found only when the fresh
/// backend detection after it finds the tool (ADR 0023).
enum BackendInstallResult: Sendable, Equatable {
    /// The re-check found the backend, and it is usable. `presence` is that
    /// re-check's answer.
    case found(HostBackendPresence)
    case failed(BackendInstallFailure)
    /// The SSH link failed before the run, or before it reported an end.
    /// The Host may or may not have changed: the panel offers Check Again.
    case hostUnreachable(TransportError)
}

/// One install, as the consent sheet shows it and the exec runs it.
struct BackendInstallPlan: Sendable, Equatable {
    let target: BackendInstallTarget
    /// The command ran through `sudo -n`. False for herdr, Homebrew and an
    /// account that is already root.
    let usesSudo: Bool
    /// The one command text. The consent sheet shows this string and the
    /// exec runs it unchanged inside the exec wrapper
    /// (`BackendInstall.execCommand`), which only adds checks and an exit
    /// marker around it.
    let command: String
    /// What a person types in a terminal on the Host: Copy Command. A
    /// separate value, since a person has a terminal and a password prompt
    /// (`sudo apt-get install -y tmux`).
    let copyCommand: String

    static let herdrInstallerURL = "https://herdr.dev/install.sh"
    static let coreInstallerURL = "https://releases.herdr.dev/core/install.sh"

    /// `runsAsRoot`: the account is uid 0, so a package manager runs
    /// without sudo.
    init(target: BackendInstallTarget, runsAsRoot: Bool = false) {
        self.target = target
        switch target {
        case .herdr, .core:
            usesSudo = false
            let url = target == .core ? Self.coreInstallerURL : Self.herdrInstallerURL
            // `curl | sh` would hide a failed download behind sh's success
            // (no pipefail in plain sh), so the installer lands in a temp
            // file first and runs only if curl exited 0.
            command = "t=$(mktemp) && curl --proto =https --tlsv1.2 -fsSL \(url) "
                + "-o \"$t\" && sh \"$t\""
            copyCommand = "curl -fsSL \(url) | sh"
        case .tmux(let manager):
            usesSudo = manager.needsAdmin && !runsAsRoot
            let tail = ([manager.rawValue] + manager.installArguments).joined(separator: " ")
            command = (usesSudo ? "sudo -n " : "") + tail
            copyCommand = (usesSudo ? "sudo " : "") + tail
        }
    }

    /// The plan for installing `backend` on a Host the preflight described,
    /// or the failure that already decides it, so the UI never offers a run
    /// that cannot work.
    static func make(
        installing backend: HostBackend, preflight: HostInstallPreflight
    ) -> Result<BackendInstallPlan, BackendInstallFailure> {
        switch backend {
        // OpenCode installs itself (its own installer or a package manager).
        case .ultimate, .codex, .opencode, .zellij:
            return .failure(.unsupportedSystem)
        case .herdr:
            guard preflight.herdrSupported else { return .failure(.unsupportedSystem) }
            guard preflight.hasCurl else { return .failure(.noCurl) }
            return .success(BackendInstallPlan(target: .herdr))
        case .core:
            // The same system rules as herdr's: Linux or macOS on x86_64 or
            // arm64, no Android (`hc runs on Linux and macOS for now`).
            guard preflight.herdrSupported else { return .failure(.unsupportedSystem) }
            guard preflight.hasCurl else { return .failure(.noCurl) }
            return .success(BackendInstallPlan(target: .core))
        case .tmux:
            guard !preflight.isAndroid else { return .failure(.unsupportedSystem) }
            guard let manager = preflight.usablePackageManager else {
                return .failure(.noPackageManager)
            }
            return .success(
                BackendInstallPlan(target: .tmux(manager), runsAsRoot: preflight.isRoot))
        }
    }
}

/// What the install exec reported, before the re-check.
struct BackendInstallRun: Sendable, Equatable {
    /// The reason the exec wrapper's marker names. `failed` is any failure it
    /// has no status for.
    enum Reason: String, Sendable, Equatable {
        case ok
        case noCurl = "nocurl"
        /// curl exited non-zero before the installer ran.
        case download
        /// `sudo -n true` failed, so the package manager never ran.
        case admin
        case noPackageManager = "nomanager"
        case failed
    }

    /// The command's exit status; nil when the exec ended without printing
    /// the marker (the process was killed, or the link dropped mid-run).
    var exitStatus: Int32?
    var reason: Reason?
    /// Every line the run printed (stdout and stderr merged, escape codes
    /// removed), marker excluded.
    var output: [String]

    var succeeded: Bool { exitStatus == 0 && reason == .ok }

    /// The last non-empty line.
    var lastLine: String? {
        output.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// The install exec, the reading of its output, and the failure list.
enum BackendInstall {
    /// The last line the exec prints:
    /// `<marker>=<exit status> reason=<BackendInstallRun.Reason>`.
    /// The streaming exec reports no exit status, so the script prints it.
    static let exitMarker = "__WAYCAR_INSTALL_EXIT__"
    /// A distro package install or herdr's download can take minutes.
    static let timeout: Duration = .seconds(600)
    /// Output the exec may print before its marker. A package manager's
    /// progress and download lines can pass the SSH layer's 64 KB default,
    /// and exceeding the cap would report a still-running install as an
    /// unreachable Host.
    static let maximumOutputBytes = 4 * 1_048_576

    /// One `/bin/sh -c` exec: no PTY, stdin closed, stderr merged into
    /// stdout, the herdr PATH added so Homebrew and `~/.local/bin` resolve.
    /// Before the plan's command runs, the script checks what the command
    /// needs and prints the reason it stopped: curl (herdr), the package
    /// manager and `sudo -n true` (tmux). A herdr download that fails is
    /// told from an installer that fails by the temp file being empty. A
    /// package manager run ignores SIGPIPE, so a link that drops mid-run
    /// does not kill the transaction half done; herdr's installer does not,
    /// since its own `printf | awk` pipelines print "I/O error" under it.
    /// The body holds no single quote.
    static func execCommand(for plan: BackendInstallPlan) -> String {
        let guards: String
        let ignoresSIGPIPE: Bool
        switch plan.target {
        case .herdr, .core:
            guards = "if ! command -v curl >/dev/null 2>&1; then r=nocurl; "
            ignoresSIGPIPE = false
        case .tmux(let manager):
            ignoresSIGPIPE = true
            guards = "if ! command -v \(manager.rawValue) >/dev/null 2>&1; then r=nomanager; "
                + (plan.usesSudo
                    ? "elif ! sudo -n true </dev/null >/dev/null 2>&1; then r=admin; " : "")
        }
        let script = "\(HerdrHostPath.pathExport); s=1; r=failed; t=; "
            + "cleanup() { [ -z \"$t\" ] || rm -f \"$t\"; }; "
            + "trap cleanup EXIT; trap \"cleanup; exit 129\" HUP INT TERM; "
            + (ignoresSIGPIPE ? "trap \"\" PIPE; " : "")
            + guards
            + "else \(plan.command); s=$?; "
            + "if [ $s -eq 0 ]; then r=ok; "
            + "elif [ -n \"$t\" ] && [ ! -s \"$t\" ]; then r=download; fi; fi; "
            + "printf \"\\n\(exitMarker)=%s reason=%s\\n\" \"$s\" \"$r\"; exit $s"
        return HostSSHSession.cLocaleCommand(
            "/bin/sh -c '\(script)' waycar-install </dev/null 2>&1")
    }

    /// The marker line's exit status and reason; nil for any other line.
    static func marker(fromLine line: String) -> (status: Int32, reason: BackendInstallRun.Reason?)? {
        let prefix = exitMarker + "="
        let line = line.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix(prefix) else { return nil }
        let words = line.dropFirst(prefix.count).split(separator: " ")
        guard let status = words.first.flatMap({ Int32($0) }) else { return nil }
        let reasonPrefix = "reason="
        let reason = words.dropFirst().first { $0.hasPrefix(reasonPrefix) }
            .flatMap { BackendInstallRun.Reason(rawValue: String($0.dropFirst(reasonPrefix.count))) }
        return (status, reason)
    }

    /// Reads a finished exec's lines.
    static func run(fromOutput lines: [String]) -> BackendInstallRun {
        let marker = lines.reversed().lazy.compactMap { Self.marker(fromLine: $0) }.first
        return BackendInstallRun(
            exitStatus: marker?.status, reason: marker?.reason,
            output: lines.filter { Self.marker(fromLine: $0) == nil })
    }

    /// Splits exec output into lines (`\r\n` and `\r` included), drops the
    /// terminal escape codes installers print, and drops empty lines (such
    /// as the one before the exit marker).
    static func lines(fromOutput output: Data) -> [String] {
        String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { stripTerminalEscapes(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// `line` without ANSI escape sequences (`ESC [ … final byte`; a lone
    /// ESC is dropped too): herdr's installer colours its progress lines.
    static func stripTerminalEscapes(_ line: String) -> String {
        var result = String.UnicodeScalarView()
        var scalars = line.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\u{1B}" else {
                result.append(scalar)
                continue
            }
            guard let next = scalars.next() else { break }
            guard next == "[" else {
                if next != "\u{1B}" { result.append(next) }
                continue
            }
            while let code = scalars.next(), !(0x40...0x7E).contains(code.value) {}
        }
        return String(result)
    }

    /// The failure a run that did not succeed describes: the wrapper's
    /// reason when it names one; else, since the installers print their own
    /// refusals, the line that says so. Anything else is `other`.
    static func failure(for target: BackendInstallTarget, run: BackendInstallRun) -> BackendInstallFailure {
        switch run.reason {
        case .noCurl: return .noCurl
        case .download: return .cannotReachInstaller
        case .admin: return .needsAdmin
        case .noPackageManager: return .noPackageManager
        case .ok, .failed, nil: break
        }
        let text = run.output.map { $0.lowercased() }
        func printed(_ phrases: [String]) -> Bool {
            text.contains { line in phrases.contains { line.contains($0) } }
        }
        switch target {
        case .core:
            // releases.herdr.dev/core/install.sh: `hc: needs curl`, `hc: needs
            // tar`, `hc: cannot reach <manifest>`, `hc: download failed: <url>`,
            // `hc runs on Linux and macOS for now`, `no build for <arch>` (and
            // `no build for <target> in <manifest>`). A damaged download
            // (checksum mismatch) and a binary that does not run are `other`.
            if printed(["hc: needs curl"]) { return .noCurl }
            if printed(["hc: needs tar"]) { return .noTar }
            if printed(["hc: cannot reach", "hc: download failed"]) { return .cannotReachInstaller }
            if printed(["hc runs on linux and macos", "no build for"]) { return .unsupportedSystem }
        case .herdr:
            // herdr.dev/install.sh `need curl`, `can't reach …latest.json`,
            // `download failed from …`, and its platform checks.
            if printed(["requires 'curl'"]) { return .noCurl }
            if printed(["can't reach", "download failed from"]) { return .cannotReachInstaller }
            if printed([
                "unsupported os", "unsupported architecture", "is not currently supported",
                "does not include a binary for",
            ]) { return .unsupportedSystem }
        case .tmux:
            // A sudoers rule that allows `sudo -n true` but not this command.
            if printed([
                "a password is required", "no tty present", "askpass", "must have a tty",
                "may not run sudo", "not in the sudoers",
            ]) { return .needsAdmin }
        }
        return .other(lastLine: run.lastLine)
    }

    /// The result of a run whose command exited 0, from the fresh backend
    /// detection after it. Found only when that detection finds the tool;
    /// tmux below the floor is `tmuxTooOld` however well the install went.
    static func result(
        afterInstalling target: BackendInstallTarget, run: BackendInstallRun,
        presence: HostBackendPresence
    ) -> BackendInstallResult {
        switch target {
        case .herdr:
            return presence.herdr ? .found(presence) : .failed(.other(lastLine: run.lastLine))
        case .core:
            // Found only at or above the floor: a core Waycar cannot drive
            // is no install, however clean the installer's run was.
            return presence.core?.meetsFloor == true
                ? .found(presence) : .failed(.other(lastLine: run.lastLine))
        case .tmux:
            guard let version = presence.tmuxVersion else {
                return .failed(.other(lastLine: run.lastLine))
            }
            return HostBackendPresence.meetsTmuxFloor(version)
                ? .found(presence) : .failed(.tmuxTooOld(found: version))
        }
    }
}
