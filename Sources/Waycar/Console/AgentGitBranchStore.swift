import Foundation
import Observation

/// The branch checked out at `cwd` on the Host, or the short SHA when
/// detached; nil when `cwd` is not in a git work tree. Throws
/// `GitBranchProbe.Skipped` when the read could not run in time.
typealias GitBranchReader = @Sendable (_ cwd: String) async throws -> String?

/// The Agent Footer's Branch field (#169) for one Agent screen. The caller
/// starts `follow` only while Branch is on a shown footer line, so nothing
/// polls for a field nobody sees; it keeps polling while a keyboard hides
/// the footer.
@MainActor @Observable
final class AgentGitBranchStore {
    private(set) var branch: String?

    /// A checkout changes the branch rarely and each read costs an exec,
    /// so the field may trail a `git switch` by this much.
    @ObservationIgnored private let interval: Duration

    /// The cwd the shown branch belongs to, so a new cwd never shows the
    /// old directory's branch while its first read runs.
    @ObservationIgnored private var followedCwd: String?

    init(interval: Duration = .seconds(30)) {
        self.interval = interval
    }

    /// Reads now, then every interval until the task is cancelled. A nil
    /// cwd is a pause (background, Branch not shown): returns, keeping the
    /// branch. A new cwd clears the branch first; the same cwd keeps it.
    /// A skipped read keeps the branch; any other error clears it. Polling
    /// continues either way.
    func follow(cwd: String?, read: @escaping GitBranchReader) async {
        guard let cwd else { return }
        if cwd != followedCwd { update(nil) }
        followedCwd = cwd
        while !Task.isCancelled {
            // Unstructured, so cancelling the view never cancels an
            // in-flight exec (that can invalidate the whole SSH session);
            // awaiting `value` does not forward cancellation.
            let value: String?
            do {
                value = try await Task { try await read(cwd) }.value
            } catch is GitBranchProbe.Skipped {
                value = branch
            } catch {
                value = nil
            }
            guard !Task.isCancelled else { return }
            update(value)
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    /// Assigns only a change, so an unchanged branch does not re-render the
    /// footer every poll.
    private func update(_ value: String?) {
        if branch != value { branch = value }
    }
}
