import Foundation
import WaycarSSH

/// One `git worktree list --porcelain` entry.
struct TmuxWorktreeEntry: Sendable, Equatable {
    let path: String
    /// The short branch name (`refs/heads/` dropped); nil when detached or
    /// bare.
    let branch: String?
    let isBare: Bool
    let isDetached: Bool
    let isPrunable: Bool
}

/// herdr's worktree family on tmux (design §4.3, phase 4), in git over exec:
/// a Workspace's repository is the checkout its session's directory
/// (`session_path`) lies in, as the snapshot's worktree metadata resolved it.
///
/// New checkouts go where herdr puts them by default,
/// `~/.herdr/worktrees/<repo>/<branch slug>` (`-2`, `-3`… when taken), so a
/// Host with both backends keeps one worktree root and herdr's own
/// `worktree list` grouping. The slug is the branch with herdr's generated
/// `worktree/` prefix dropped and `/` written `-`. Each worktree opens as a
/// new session named after the checkout directory.
///
/// A typed branch already checked out in a linked worktree is reused (its
/// running Agent, else a new window there), and, unlike herdr, also when no
/// session shows it yet: the launch opens one at the checkout.
extension TmuxTransport {
    /// A Workspace's session and the git checkout its directory lies in.
    struct WorktreeSource: Sendable {
        /// App id, `tmux:$N`.
        let workspaceID: String
        let checkout: TmuxCheckout
    }

    /// Where a worktree launch continues once its worktree is settled.
    enum WorktreeTarget: Sendable, Equatable {
        /// This launch's own worktree. `continuing` is false only right after
        /// this try's own `git worktree add` answered; otherwise an earlier
        /// try may already have opened its session.
        case own(path: String, continuing: Bool)
        /// A worktree on the typed branch this launch did not make, or cannot
        /// tell it made. Never removed.
        case adopted(path: String)
    }

    static let worktreeMarker = "__WAYCAR_WORKTREE__="

    // MARK: Listing

    func listWorktrees(forWorkspaceID workspaceID: String) async throws -> WorktreeListResponse {
        try await worktreeListing(of: try await worktreeSource(workspaceID))
    }

    /// The Workspace's session and checkout from a fresh snapshot;
    /// `not_git_worktree` when its directory is not in a git work tree.
    func worktreeSource(_ workspaceID: String) async throws -> WorktreeSource {
        let rawID = try Self.rawSession(workspaceID)
        _ = try await sessionSnapshot()
        guard
            let session = TmuxInventory.visibleSessions(records.sessions)
                .first(where: { $0.id == rawID })
        else {
            throw HerdrAPIError(code: "workspace_not_found", message: "no tmux session \(rawID)")
        }
        guard let checkout = try await checkout(of: session) else {
            throw HerdrAPIError(
                code: "not_git_worktree",
                message: "the workspace directory is not in a git work tree")
        }
        return WorktreeSource(workspaceID: TmuxID.app(rawID), checkout: checkout)
    }

    /// The session's checkout as the last snapshot resolved it; resolved
    /// now, failing loudly, when that snapshot's lookup failed.
    private func checkout(of session: TmuxSessionRecord) async throws -> TmuxCheckout? {
        guard let directory = records.directory(of: session) else { return nil }
        if let entry = records.checkouts[directory] { return entry.checkout }
        let resolved = try await lookUpCheckouts([directory])[directory]
        records.checkouts[directory] = TmuxCheckoutEntry(checkout: resolved, resolvedAt: .now)
        return resolved
    }

    /// `git worktree list --porcelain` of the source's repository. The
    /// source checkout is the main worktree (git's first entry); every other
    /// entry is linked. `open_workspace_id` is the first shown session in
    /// that checkout, from the records `source` was resolved with.
    private func worktreeListing(of source: WorktreeSource) async throws -> WorktreeListResponse {
        let result = try await session.runExec(
            Self.shellCommand(
                Self.worktreeListScript, arguments: [source.checkout.path], cLocale: true),
            input: Data(), timeout: nil)
        guard result.exitStatus == 0 else {
            throw Self.gitError(result, code: "worktree_list_failed")
        }
        let entries = Self.parseWorktreeList(Self.text(result.stdout))
        guard let main = entries.first else {
            throw TransportError.malformedResponse("git listed no worktrees")
        }
        let open = openWorkspaceIDs()
        let worktrees = entries.enumerated().map { offset, entry in
            WorktreeInfo(
                isBare: entry.isBare, isDetached: entry.isDetached, isLinkedWorktree: offset > 0,
                isPrunable: entry.isPrunable, label: Self.basename(entry.path), path: entry.path,
                branch: entry.branch, openWorkspaceID: open[entry.path])
        }
        return WorktreeListResponse(
            source: WorktreeSourceInfo(
                repoKey: source.checkout.commonDir, repoName: Self.basename(main.path),
                repoRoot: main.path, sourceCheckoutPath: main.path,
                sourceWorkspaceID: source.workspaceID),
            worktrees: worktrees)
    }

    /// Per checkout path, the first shown session in it (app id).
    private func openWorkspaceIDs() -> [String: String] {
        var open: [String: String] = [:]
        for session in TmuxInventory.visibleSessions(records.sessions) {
            guard let checkout = records.checkout(of: session), open[checkout.path] == nil
            else { continue }
            open[checkout.path] = TmuxID.app(session.id)
        }
        return open
    }

    /// `git worktree list --porcelain` with each path's symlinks resolved,
    /// as the snapshot's checkout paths are.
    static let worktreeListScript =
        #"unset CDPATH; command -v git >/dev/null 2>&1 || exit 127; "#
        + #"o=$(git -C "$1" worktree list --porcelain) || exit; "#
        + #"printf "%s\n" "$o" | while IFS= read -r l; do case $l in "#
        + #""worktree "*) p=${l#worktree }; r=$(cd "$p" 2>/dev/null && pwd -P) || r=$p; "#
        + #"printf "worktree %s\n" "$r";; *) printf "%s\n" "$l";; esac; done"#

    static func parseWorktreeList(_ output: String) -> [TmuxWorktreeEntry] {
        var entries: [TmuxWorktreeEntry] = []
        var path: String?
        var branch: String?
        var bare = false
        var detached = false
        var prunable = false
        func flush() {
            if let path {
                entries.append(TmuxWorktreeEntry(
                    path: path, branch: branch, isBare: bare, isDetached: detached,
                    isPrunable: prunable))
            }
            path = nil
            branch = nil
            bare = false
            detached = false
            prunable = false
        }
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                let ref = line.dropFirst("branch ".count)
                branch = String(ref.hasPrefix("refs/heads/") ? ref.dropFirst("refs/heads/".count) : ref)
            } else if line == "bare" {
                bare = true
            } else if line == "detached" {
                detached = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                prunable = true
            }
        }
        flush()
        return entries
    }

    // MARK: Launches

    /// A new session at a fresh checkout running the agent through the
    /// login-shell wrapper, like `startAgentInNewWorkspace`. `attempt` makes
    /// every try after the one that ran `git worktree add` continue there.
    func startAgentInNewWorktree(
        _ request: AgentLaunchRequest, worktree: WorktreeSpec,
        attempt: WorktreeLaunchAttempt
    ) async throws -> Agent {
        guard let sourceWorkspaceID = request.workspaceID else {
            throw TransportError.channelFailed(detail: "a worktree launch needs a workspace")
        }
        // An unknown kind fails before anything is created.
        _ = try await agentCommandLine(request)
        switch try await worktreeLaunchTarget(
            worktree, sourceWorkspaceID: sourceWorkspaceID, attempt: attempt)
        {
        case .adopted(let path):
            if let sessionID = try await sessionShowing(checkout: path) {
                if let earlier = try await earlierAgentLaunch(
                    request, workspaceID: TmuxID.app(sessionID)) { return earlier }
                if let running = runningAgent(
                    inSession: sessionID, preferringKind: request.kind,
                    excludingLaunchID: request.mayHaveStarted ? request.launchID : nil)
                {
                    LaunchProgress.report(.joiningRunningAgent)
                    return running
                }
                return try await startAgent(
                    Self.agentRequest(request, workspaceID: TmuxID.app(sessionID), cwd: path))
            }
            return try await startAgentInNewWorkspace(
                request, workspace: Self.worktreeWorkspace(path))
        case .own(let path, let continuing):
            if continuing, let sessionID = try await sessionShowing(checkout: path) {
                if let earlier = try await earlierAgentLaunch(
                    request, workspaceID: TmuxID.app(sessionID)) { return earlier }
                if let running = runningAgent(
                    inSession: sessionID, preferringKind: request.kind,
                    excludingLaunchID: request.mayHaveStarted ? request.launchID : nil)
                {
                    return running
                }
                // An earlier try's new-session ran the agent as its first
                // window; detection may not have caught up yet.
                if !request.mayHaveStarted, attempt.current.agentStartDispatchedAt != nil,
                    let pane = firstPane(ofSession: sessionID)
                {
                    return agent(forPane: pane.id, kind: request.kind)
                }
                return try await startAgent(
                    Self.agentRequest(request, workspaceID: TmuxID.app(sessionID), cwd: path))
            }
            let mayRemove = attempt.current.mayRemoveWorktreeOnFailure
            attempt.recordAgentStartDispatched(at: .now)
            do {
                return try await startAgentInNewWorkspace(
                    request, workspace: Self.worktreeWorkspace(path))
            } catch let error as HerdrAPIError {
                // tmux refused the session: no Agent started there.
                if mayRemove { try? await removeCreatedWorktree(path) }
                throw error
            }
        }
    }

    /// A new session at a fresh checkout whose first window is the marked
    /// shell (`WAYCAR_SHELL=1`); a reused worktree gets a new window.
    func startShellTerminalInNewWorktree(
        _ request: ShellLaunchRequest, worktree: WorktreeSpec,
        attempt: WorktreeLaunchAttempt
    ) async throws -> ShellLaunchResult {
        guard let sourceWorkspaceID = request.workspaceID else {
            throw TransportError.channelFailed(detail: "a shell launch needs a workspace")
        }
        switch try await worktreeLaunchTarget(
            worktree, sourceWorkspaceID: sourceWorkspaceID, attempt: attempt)
        {
        case .adopted(let path):
            if let sessionID = try await sessionShowing(checkout: path) {
                return try await startShellTerminal(
                    ShellLaunchRequest(
                        name: request.name, workspaceID: TmuxID.app(sessionID), cwd: path,
                        launchID: request.launchID, mayHaveStarted: request.mayHaveStarted))
            }
            return try await startShellTerminalInNewWorkspace(
                request, workspace: Self.worktreeWorkspace(path))
        case .own(let path, let continuing):
            if continuing, let sessionID = try await sessionShowing(checkout: path) {
                // An earlier try's new-session is the shell.
                if !request.mayHaveStarted, attempt.current.shellTabDispatched,
                    let pane = firstPane(ofSession: sessionID)
                {
                    return ShellLaunchResult(
                        paneID: TmuxID.app(pane.id), tabID: TmuxID.app(pane.windowID),
                        terminalID: terminalID(forPane: pane.id),
                        workspaceID: TmuxID.app(sessionID))
                }
                return try await startShellTerminal(
                    ShellLaunchRequest(
                        name: request.name, workspaceID: TmuxID.app(sessionID), cwd: path,
                        launchID: request.launchID, mayHaveStarted: request.mayHaveStarted))
            }
            let mayRemove = attempt.current.mayRemoveWorktreeOnFailure
            attempt.recordShellTabDispatched()
            do {
                return try await startShellTerminalInNewWorkspace(
                    request, workspace: Self.worktreeWorkspace(path))
            } catch let error as HerdrAPIError {
                if mayRemove { try? await removeCreatedWorktree(path) }
                throw error
            }
        }
    }

    /// Settles the worktree one try continues in, running `git worktree add`
    /// at most once per `attempt` (``TmuxWorktreeTargetMachine``, whose
    /// steps this performs). A worktree is recognised only by its exact
    /// branch. A re-list after git's refusal that fails keeps git's own
    /// answer; a link failure while looking for an unanswered add reaches
    /// `EventsSession`, whose replay continues with the add dispatched.
    private func worktreeLaunchTarget(
        _ worktree: WorktreeSpec, sourceWorkspaceID: String, attempt: WorktreeLaunchAttempt
    ) async throws -> WorktreeTarget {
        var machine = TmuxWorktreeTargetMachine(
            branch: worktree.branch, branchIsGenerated: worktree.branchIsGenerated)
        var source: WorktreeSource?
        var listing: WorktreeListResponse?
        var addCommand = ""
        var refusal: HerdrAPIError?
        var effects = machine.handle(.begin(knownWorktreePath: attempt.current.worktree?.path))
        while true {
            var next: TmuxWorktreeTargetMachine.Event?
            for effect in effects {
                switch effect {
                case .report(let step):
                    LaunchProgress.report(step)
                case .recordCreateDispatched:
                    attempt.recordCreateDispatched()
                case .recordWorktree(let path, let workspaceID):
                    attempt.recordWorktree(
                        WorktreeLaunchAttempt.Worktree(
                            workspaceID: workspaceID, tabID: "", rootPaneID: "", path: path))
                case .settle(let target):
                    return target
                case .fail(.createUnconfirmed):
                    throw WorktreeLaunchError.createUnconfirmed
                case .fail(.linkedWorktreeSource):
                    throw WorktreeBaseResolutionError.linkedWorktreeSource
                case .fail(.addRefused):
                    throw refusal ?? HerdrAPIError(
                        code: "worktree_create_failed", message: "git refused the worktree")
                case .list:
                    let resolved = try await worktreeSource(sourceWorkspaceID)
                    let listed = try await worktreeListing(of: resolved)
                    source = resolved
                    listing = listed
                    next = .listed(
                        createDispatched: attempt.current.createDispatched,
                        onBranch: Self.found(in: listed, branch: worktree.branch),
                        sourceIsLinked: resolved.checkout.isLinked, now: .now)
                case .resolveBase:
                    guard let listing else { throw Self.unlistedWorktreeLaunch }
                    let base = try await worktreeBase(
                        worktree, sourceCheckoutPath: listing.source.sourceCheckoutPath)
                    let branch = worktree.branch ?? GeneratedWorktreeBranch.mint()
                    // Built before the dispatch is recorded: a refused ref ran
                    // nothing.
                    addCommand = try Self.worktreeAddCommand(
                        sourceCheckoutPath: listing.source.sourceCheckoutPath,
                        repoName: listing.source.repoName, branch: branch, base: base)
                    next = .addReady
                case .add:
                    do {
                        next = .added(path: try await addWorktree(addCommand))
                    } catch let error as HerdrAPIError {
                        refusal = error
                        next = .addRefused
                    } catch {
                        next = .addUnanswered(now: .now)
                    }
                case .relist:
                    guard let source else { throw Self.unlistedWorktreeLaunch }
                    let relisted = try? await worktreeListing(of: source)
                    next = .relisted(
                        onBranch: relisted.flatMap { Self.found(in: $0, branch: worktree.branch) })
                case .poll(let delay):
                    guard let source else { throw Self.unlistedWorktreeLaunch }
                    if let delay { try await Task.sleep(for: delay) }
                    let listed = try await worktreeListing(of: source)
                    next = .polled(
                        onBranch: Self.found(in: listed, branch: worktree.branch), now: .now)
                }
            }
            guard let next else { throw Self.unlistedWorktreeLaunch }
            effects = machine.handle(next)
        }
    }

    /// A step `TmuxWorktreeTargetMachine` only asks for after the listing
    /// ran without one: not reached.
    private static let unlistedWorktreeLaunch = TransportError.malformedResponse(
        "the tmux worktree launch has no listing")

    /// The linked worktree on exactly `branch` in `listing`, as the target
    /// machine takes it; nil without a branch.
    private static func found(
        in listing: WorktreeListResponse, branch: String?
    ) -> TmuxWorktreeTargetMachine.Found? {
        guard let branch, let worktree = linkedWorktree(in: listing.worktrees, branch: branch)
        else { return nil }
        return TmuxWorktreeTargetMachine.Found(
            path: worktree.path, openWorkspaceID: worktree.openWorkspaceID)
    }

    /// The one linked, present worktree on exactly `branch`, open in a
    /// session or not; nil when there is none, or several.
    static func linkedWorktree(in worktrees: [WorktreeInfo], branch: String) -> WorktreeInfo? {
        let matches = worktrees.filter {
            $0.isLinkedWorktree && !$0.isPrunable && $0.branch == branch
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// The commit-ish `git worktree add` starts a new branch from; nil for
    /// the source checkout's HEAD. `.latestDefaultBranch` resolves origin's
    /// default branch in the source checkout (`WorktreeBaseResolution`) and
    /// passes the SHA; a requested branch that already exists gets none,
    /// since it is checked out as-is.
    private func worktreeBase(
        _ worktree: WorktreeSpec, sourceCheckoutPath: String
    ) async throws -> String? {
        switch worktree.base {
        case .sourceHead:
            return nil
        case .ref(let ref):
            return ref
        case .latestDefaultBranch:
            LaunchProgress.report(.gettingLatestMain)
            let input = try WorktreeBaseResolution.input(
                sourceCheckoutPath: sourceCheckoutPath, branch: worktree.branch)
            let command = HostSSHSession.cLocaleCommand(WorktreeBaseResolution.command)
            let timeout = WorktreeBaseResolution.timeout
            let session = self.session
            let result: SSHExecResult
            do {
                result = try await AsyncDeadline.run(for: timeout) {
                    try await session.runExec(command, input: input, timeout: timeout)
                }
            } catch {
                throw WorktreeBaseResolutionError.replacingTimeout(error)
            }
            guard result.reachedEOF else {
                throw TransportError.channelFailed(detail: "Host command closed before EOF")
            }
            switch try WorktreeBaseResolution.resolution(
                exitStatus: result.exitStatus, stdout: result.stdout, stderr: result.stderr)
            {
            case .commit(let commit): return commit
            case .existingBranch: return nil
            }
        }
    }

    /// The `git worktree add` exec for `branch` (checked out as-is when it
    /// exists, else made from `base`) under the herdr worktree root. A
    /// branch or base the login shell cannot quote (backslash or control
    /// character, which git refuses anyway) gets git's own refusal.
    static func worktreeAddCommand(
        sourceCheckoutPath: String, repoName: String, branch: String, base: String?
    ) throws -> String {
        guard isLoginShellSafeRef(branch) else {
            throw HerdrAPIError(
                code: "worktree_create_failed", message: "'\(branch)' is not a valid branch name")
        }
        if let base, !isLoginShellSafeRef(base) {
            throw HerdrAPIError(
                code: "worktree_create_failed", message: "invalid reference: \(base)")
        }
        return try shellCommand(
            worktreeAddScript,
            arguments: [
                .path(sourceCheckoutPath), .ref(branch), .ref(base ?? ""), .path(repoName),
                .ref(worktreeSlug(branch)),
            ],
            cLocale: true)
    }

    /// Runs `command` (``worktreeAddCommand(sourceCheckoutPath:repoName:branch:base:)``)
    /// and returns the checkout path, symlinks resolved.
    private func addWorktree(_ command: String) async throws -> String {
        let result = try await session.runExec(
            command, input: Data(), timeout: SSHTransportSettings.defaultWorktreeCreateTimeout)
        guard result.exitStatus == 0 else {
            throw Self.gitError(result, code: "worktree_create_failed")
        }
        guard
            let path = Self.text(result.stdout).split(whereSeparator: \.isNewline)
                .last(where: { $0.hasPrefix(Self.worktreeMarker) })
                .map({ String($0.dropFirst(Self.worktreeMarker.count)) }),
            path.hasPrefix("/")
        else {
            throw TransportError.malformedResponse("git worktree add reported no checkout")
        }
        return path
    }

    /// `$1` source checkout, `$2` branch, `$3` base (empty: HEAD), `$4` repo
    /// name, `$5` slug. git's own output goes to stderr; stdout carries only
    /// the marker line.
    static let worktreeAddScript =
        #"exec </dev/null; unset CDPATH; command -v git >/dev/null 2>&1 || exit 127; "#
        + #"r="$HOME/.herdr/worktrees/$4"; p="$r/$5"; n=2; "#
        + #"while [ -e "$p" ]; do p="$r/$5-$n"; n=$((n + 1)); done; "#
        + #"mkdir -p "$r" || exit; "#
        + #"if git -C "$1" show-ref --verify --quiet "refs/heads/$2"; "#
        + #"then git -C "$1" worktree add "$p" "$2"; "#
        + #"elif [ -n "$3" ]; then git -C "$1" worktree add -b "$2" "$p" "$3"; "#
        + #"else git -C "$1" worktree add -b "$2" "$p"; fi >&2 || exit; "#
        + #"cd "$p" && printf "__WAYCAR_WORKTREE__=%s\n" "$(pwd -P)""#

    /// herdr's branch slug: its generated `worktree/` prefix dropped, `/`
    /// written `-`.
    static func worktreeSlug(_ branch: String) -> String {
        let prefix = GeneratedWorktreeBranch.prefix
        let name = branch.hasPrefix(prefix) ? String(branch.dropFirst(prefix.count)) : branch
        let slug = name.replacingOccurrences(of: "/", with: "-")
        return slug.isEmpty ? "worktree" : slug
    }

    /// The new session for a checkout: named after its directory (the branch
    /// slug), `-2`… on collision (`startAgentInNewWorkspace`).
    private static func worktreeWorkspace(_ path: String) -> NewWorkspaceSpec {
        NewWorkspaceSpec(directory: path, label: basename(path))
    }

    private static func agentRequest(
        _ request: AgentLaunchRequest, workspaceID: String, cwd: String
    ) -> AgentLaunchRequest {
        AgentLaunchRequest(
            kind: request.kind, name: request.name, arguments: request.arguments,
            workspaceID: workspaceID, cwd: cwd, environment: request.environment,
            launchID: request.launchID, mayHaveStarted: request.mayHaveStarted,
            joinsCodexServer: request.joinsCodexServer)
    }

    /// The first shown session in the checkout at `path` (raw id), from a
    /// fresh snapshot.
    private func sessionShowing(checkout path: String) async throws -> String? {
        _ = try await sessionSnapshot()
        return TmuxInventory.visibleSessions(records.sessions).first { session in
            records.directory(of: session) == path || records.checkout(of: session)?.path == path
        }?.id
    }

    /// The first pane of the session's first window, from the last snapshot.
    private func firstPane(ofSession rawID: String) -> TmuxPaneRecord? {
        guard
            let window = records.windows.filter({ $0.sessionID == rawID })
                .min(by: { $0.index < $1.index })
        else { return nil }
        return records.panes.filter { $0.sessionID == rawID && $0.windowID == window.id }
            .min { $0.index < $1.index }
    }

    /// An Agent the last snapshot shows in the session: the first of `kind`,
    /// else the first of any kind.
    private func runningAgent(
        inSession rawID: String, preferringKind kind: String, excludingLaunchID: UUID? = nil
    ) -> Agent? {
        let excluded = excludingLaunchID.map {
            taggedLaunchPanes($0, workspaceID: TmuxID.app(rawID))
        } ?? []
        let agents = (lastSnapshot?.agents ?? []).filter {
            $0.workspaceID == TmuxID.app(rawID) && !excluded.contains($0.paneID)
        }
        return (agents.first { $0.agent == kind } ?? agents.first).map(Agent.init)
    }

    // MARK: Removal

    /// Removes the exact linked worktree `removal` names: the session must
    /// still be in a linked checkout with the same repository and path.
    /// `authorize` runs before git does; `onDispatched` as `git worktree
    /// remove` goes out (an exec has no later point that is still before
    /// its answer). git refuses a dirty checkout (no force, as on herdr).
    /// Then every session in that checkout, with its group, is killed; the
    /// branch survives.
    func removeWorktree(
        _ removal: WorktreeRemovalRequest,
        authorize: @escaping @Sendable (WorktreeRemovalRequest) async throws -> Void,
        onDispatched: @escaping @Sendable (WorktreeRemovalRequest) async -> Void
    ) async throws -> WorktreeRemovedResponse {
        let identity = removal.identity
        let rawID = try Self.rawSession(identity.workspaceID)
        _ = try await sessionSnapshot()
        guard
            let session = TmuxInventory.visibleSessions(records.sessions)
                .first(where: { $0.id == rawID })
        else {
            throw HerdrAPIError(code: "workspace_not_found", message: "no tmux session \(rawID)")
        }
        guard let checkout = try await checkout(of: session), checkout.isLinked else {
            throw HerdrAPIError(
                code: "not_linked_worktree", message: "the workspace is not a linked worktree")
        }
        guard checkout.commonDir == identity.repoKey, checkout.path == identity.checkoutPath else {
            throw WorktreeRemovalError.staleIdentity
        }
        let doomed = sessionsShowing(checkout: checkout.path)
        try await authorize(removal)
        await onDispatched(removal)
        try await runWorktreeRemove(checkout.path)
        forgetCheckout(checkout.path)
        // The checkout is gone whatever tmux answers: a session that
        // outlives it is not a reason to report the removal failed.
        if !doomed.isEmpty {
            _ = try? await run(doomed.map { "kill-session -t \(TmuxCommand.target($0))" })
        }
        return WorktreeRemovedResponse(
            forced: false, path: checkout.path, workspaceID: identity.workspaceID)
    }

    /// A failed launch's cleanup of its own fresh worktree.
    private func removeCreatedWorktree(_ path: String) async throws {
        try await runWorktreeRemove(path)
        forgetCheckout(path)
    }

    private func runWorktreeRemove(_ path: String) async throws {
        let result = try await session.runExec(
            Self.shellCommand(Self.worktreeRemoveScript, arguments: [path], cLocale: true),
            input: Data(), timeout: nil)
        guard result.exitStatus == 0 else {
            throw Self.gitError(result, code: "worktree_remove_failed")
        }
    }

    static let worktreeRemoveScript =
        #"exec </dev/null; unset CDPATH; command -v git >/dev/null 2>&1 || exit 127; "#
        + #"git -C "$1" worktree remove "$1""#

    /// Raw ids of every session in the checkout at `path` (its directory
    /// there or below, or resolved to it), with the rest of their groups.
    private func sessionsShowing(checkout path: String) -> [String] {
        let inside = records.sessions.filter { session in
            guard let directory = records.directory(of: session) else { return false }
            return directory == path || directory.hasPrefix(path + "/")
                || records.checkout(of: session)?.path == path
        }
        let groups = Set(inside.filter(\.grouped).map(\.group))
        let ids = Set(inside.map(\.id))
        return records.sessions
            .filter { ids.contains($0.id) || ($0.grouped && groups.contains($0.group)) }
            .map(\.id)
    }

    /// Drops cached resolutions in or of the removed checkout.
    private func forgetCheckout(_ path: String) {
        records.checkouts = records.checkouts.filter { directory, entry in
            !(directory == path || directory.hasPrefix(path + "/") || entry.checkout?.path == path)
        }
    }

    // MARK: Errors

    /// herdr's codes for a failed git exec: `dirty_worktree_requires_force`
    /// when git wants `--force`, `not_git_worktree` outside a repository,
    /// `git_not_found` without git, else `code`, git's message attached.
    static func gitError(_ result: SSHExecResult, code: String) -> HerdrAPIError {
        if result.exitStatus == 127 {
            return HerdrAPIError(
                code: "git_not_found", message: "git is not on the Host PATH for SSH commands")
        }
        let stderr = preview(text(result.stderr))
        let message = stderr.isEmpty ? "git exited with status \(result.exitStatus)" : stderr
        if stderr.contains("use --force") {
            return HerdrAPIError(code: "dirty_worktree_requires_force", message: message)
        }
        if stderr.contains("not a git repository") {
            return HerdrAPIError(code: "not_git_worktree", message: message)
        }
        return HerdrAPIError(code: code, message: message)
    }
}
