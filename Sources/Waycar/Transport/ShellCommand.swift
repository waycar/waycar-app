import Foundation

/// Backend-neutral shell-name predicate: herdr's pane-shell names plus the
/// common POSIX shells. Used by tmux detection and Shell Activity.
enum ShellCommand {
    static let names: Set<String> = [
        "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "oksh", "pdksh",
        "tcsh", "csh", "nu", "elvish", "xonsh", "pwsh", "powershell", "ash",
        "yash",
    ]

    /// Whether `name` is a shell, including a login shell's `-zsh` and a
    /// path like `/bin/zsh`.
    static func isShell(_ name: String) -> Bool {
        names.contains(normalized(name))
    }

    /// `name` reduced to its last path component, a login shell's leading
    /// `-` stripped.
    static func normalized(_ name: String) -> String {
        let trimmed = name.hasPrefix("-") ? String(name.dropFirst()) : name
        return trimmed.split(separator: "/", omittingEmptySubsequences: true).last
            .map(String.init) ?? trimmed
    }
}
