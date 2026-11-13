import Foundation

/// Asks git on the Host which branch an Agent's working directory has
/// checked out, for the Agent Footer's Branch field (#169).
///
/// One exec per read, on herdr and tmux Hosts alike: the answer is a plain
/// `git` run, not a backend request. `symbolic-ref` names the branch (an
/// unborn one too); a detached HEAD falls back to the short SHA.
enum GitBranchProbe {
    /// How long git may run on the Host before `waycar_watch` stops it, so
    /// a git stuck on a slow mount costs the field and nothing else.
    static let hostLimitSeconds = 5

    /// A read that could not get a channel within ``admissionBudget`` or
    /// outlived ``execBudget``: says nothing about the branch, so the field
    /// keeps its last value. Deliberately not `TransportError.timedOut`, so
    /// the Console never takes a slow git for a dead link.
    struct Skipped: Error, Equatable {}

    /// Largest stdout parsed; a branch name is far shorter.
    static let outputLimit = 4 * 1024

    /// Longest branch shown, in grapheme clusters.
    static let nameLimit = 80

    /// How long a read waits for an ordinary session channel. A saturated
    /// connection skips the read (``Skipped``) rather than queueing behind work; only
    /// this wait is bounded from outside, because cancelling an exec mid
    /// channel-open would make the SSH layer invalidate the connection.
    static let admissionBudget: Duration = .seconds(2)

    /// The exec's own SSH deadline: the Host-side limit plus a slow
    /// non-interactive shell start, so the watchdog normally answers first.
    static let execBudget: Duration = .seconds(hostLimitSeconds + 3)

    /// `/bin/sh -c '<script>' waycar-git-branch '<cwd>'`, with the cwd as
    /// `$1` so the script itself holds no Host value. nil for a cwd
    /// `RemoteShellPath` will not quote: such a directory shows no branch.
    static func command(cwd: String) -> String? {
        guard let quotedCwd = RemoteShellPath.quotedAbsolute(cwd) else { return nil }
        let script = "\(HerdrHostPath.pathExport); \(HostWatchdog.definition); "
            + "waycar_branch() { git -C \"$1\" symbolic-ref --short -q HEAD 2>/dev/null "
            + "|| git -C \"$1\" rev-parse --short HEAD 2>/dev/null; }; "
            + "waycar_watch \(hostLimitSeconds) waycar_branch \"$1\""
        return "/bin/sh -c '\(script)' waycar-git-branch \(quotedCwd)"
    }

    /// The last non-blank line of a successful run, normalized by
    /// `HostText.normalizedLine`; nil when git printed nothing or more than
    /// ``outputLimit``. Taking the last line keeps login-shell noise ahead
    /// of git's answer out of the field.
    static func branch(in output: Data) -> String? {
        guard output.count <= outputLimit else { return nil }
        return String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { HostText.normalizedLine(String($0), limit: nameLimit) }
            .last
    }
}
