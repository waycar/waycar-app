import Foundation

/// A package manager Waycar can run to install tmux on a Host.
enum HostPackageManager: String, Sendable, Equatable, Hashable, CaseIterable {
    case aptGet = "apt-get"
    case dnf
    case yum
    case zypper
    case pacman
    case apk
    case brew

    /// Every manager but Homebrew changes system packages and needs root.
    var needsAdmin: Bool { self != .brew }

    /// The arguments that install tmux without asking anything.
    var installArguments: [String] {
        switch self {
        case .aptGet, .dnf, .yum: ["install", "-y", "tmux"]
        case .zypper: ["--non-interactive", "install", "tmux"]
        case .pacman: ["-S", "--noconfirm", "tmux"]
        case .apk: ["add", "tmux"]
        case .brew: ["install", "tmux"]
        }
    }
}

/// What one install preflight found on a Host (WAY-338): the facts the
/// install panel needs before it offers a button. One exec, run when the
/// panel opens, never on every backend detection.
struct HostInstallPreflight: Sendable, Equatable {
    /// `uname -s`: "Linux", "Darwin"; empty when the Host printed none.
    var operatingSystem: String
    /// `uname -m`: "x86_64", "aarch64", "arm64".
    var architecture: String
    /// Termux and other Android userlands (`uname -o` is "Android").
    var isAndroid: Bool
    var hasCurl: Bool
    /// Every manager from `HostPackageManager` the Host's exec PATH resolves,
    /// system managers first, Homebrew last.
    var packageManagers: [HostPackageManager]
    /// The account is uid 0: it installs packages with no sudo at all.
    var isRoot: Bool
    /// `sudo -n true` succeeded: sudo runs without asking for a password.
    var sudoWithoutPassword: Bool

    /// The account can change system packages without a password.
    var canAdminister: Bool { isRoot || sudoWithoutPassword }

    /// herdr's release binaries: Linux or macOS on x86_64 or arm64, not
    /// Android (`herdr.dev/install.sh` refuses everything else).
    var herdrSupported: Bool {
        guard !isAndroid, operatingSystem == "Linux" || operatingSystem == "Darwin" else {
            return false
        }
        return ["x86_64", "amd64", "aarch64", "arm64"].contains(architecture)
    }

    /// The manager an Install tmux run would use. A system manager when the
    /// account can administer, since Homebrew is the user-space route: on a
    /// Host without admin rights Homebrew is the only one that can succeed.
    /// Without admin rights and without Homebrew the first system manager
    /// is returned, and the run stops at `needsAdmin`. Nil: none found.
    var usablePackageManager: HostPackageManager? {
        let system = packageManagers.first { $0.needsAdmin }
        if !canAdminister, packageManagers.contains(.brew) { return .brew }
        return system ?? packageManagers.first
    }
}

extension HostInstallPreflight {
    static let beginMarker = "__WAYCAR_PREFLIGHT__"
    static let endMarker = "__WAYCAR_PREFLIGHT_END__"

    /// The preflight exec: facts as `key=value` lines between markers, so
    /// login-shell chatter is ignored. Only reads; `sudo -n true` is the one
    /// command with an effect, and it asks nothing (stdin is closed).
    static var command: String {
        let managers = HostPackageManager.allCases.map(\.rawValue).joined(separator: " ")
        let script = "\(HerdrHostPath.pathExport); "
            + "printf \"\(beginMarker)\\n\"; "
            + "printf \"os=%s\\n\" \"$(uname -s 2>/dev/null)\"; "
            + "printf \"arch=%s\\n\" \"$(uname -m 2>/dev/null)\"; "
            + "if [ \"$(uname -o 2>/dev/null)\" = Android ]; then printf \"android=1\\n\"; "
            + "else printf \"android=0\\n\"; fi; "
            + "if command -v curl >/dev/null 2>&1; then printf \"curl=1\\n\"; "
            + "else printf \"curl=0\\n\"; fi; "
            + "for m in \(managers); do "
            + "if command -v \"$m\" >/dev/null 2>&1; then printf \"pm=%s\\n\" \"$m\"; fi; done; "
            + "if [ \"$(id -u 2>/dev/null)\" = 0 ]; then printf \"root=1\\n\"; "
            + "else printf \"root=0\\n\"; fi; "
            + "if command -v sudo >/dev/null 2>&1 && sudo -n true </dev/null >/dev/null 2>&1; "
            + "then printf \"sudo=1\\n\"; else printf \"sudo=0\\n\"; fi; "
            + "printf \"\(endMarker)\\n\"; exit 0"
        return HostSSHSession.cLocaleCommand("/bin/sh -c '\(script)' waycar-preflight </dev/null 2>&1")
    }

    /// Reads the preflight output: the lines between the last begin marker
    /// and the end marker after it. Nil when the markers are missing, so a
    /// truncated or foreign answer is never read as "nothing found".
    init?(fromOutput output: Data) {
        let lines = String(decoding: output, as: UTF8.self)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard
            let end = lines.lastIndex(of: Substring(Self.endMarker)),
            let begin = lines[..<end].lastIndex(of: Substring(Self.beginMarker))
        else { return nil }
        var facts = HostInstallPreflight(
            operatingSystem: "", architecture: "", isAndroid: false, hasCurl: false,
            packageManagers: [], isRoot: false, sudoWithoutPassword: false)
        var found: Set<HostPackageManager> = []
        for line in lines[(begin + 1)..<end] {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals]
            let value = String(line[line.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "os": facts.operatingSystem = value
            case "arch": facts.architecture = value
            case "android": facts.isAndroid = value == "1"
            case "curl": facts.hasCurl = value == "1"
            case "root": facts.isRoot = value == "1"
            case "sudo": facts.sudoWithoutPassword = value == "1"
            case "pm":
                if let manager = HostPackageManager(rawValue: value) { found.insert(manager) }
            default: break
            }
        }
        facts.packageManagers = HostPackageManager.allCases.filter(found.contains)
        self = facts
    }
}
