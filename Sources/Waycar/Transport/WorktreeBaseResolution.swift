import Foundation

/// The Host-side step behind `WorktreeBase.latestDefaultBranch`: ask origin
/// which commit its default branch (`HEAD`) names, download that commit into
/// the source checkout herdr's `worktree.create` branches from, and report it.
///
/// herdr 0.9.1 never fetches before `git worktree add`, so without this a new
/// worktree starts from whatever the Host's checkout last pulled. The step
/// runs before `worktree.create`; a failure aborts the launch with nothing
/// created and never falls back to the stale checkout.
enum WorktreeBaseResolution {
    /// What the Host reported.
    enum Resolution: Sendable, Equatable {
        /// Origin's default branch names this commit, now present locally.
        case commit(String)
        /// The requested branch already exists in the checkout. herdr 0.9.1
        /// checks an existing local branch out as-is and ignores `base`, so
        /// nothing was fetched.
        case existingBranch
    }

    static let commitMarker = "__WAYCAR_WORKTREE_BASE_COMMIT__="
    static let existingBranchMarker = "__WAYCAR_WORKTREE_BASE_EXISTING_BRANCH__"

    /// `git ls-remote` or `git fetch` failed (no origin, offline, auth).
    static let fetchFailedStatus: Int32 = 81
    /// Origin reports no default branch, or its commit is not here after the
    /// fetch.
    static let defaultBranchUnresolvedStatus: Int32 = 82
    /// `git` is not on the exec PATH.
    static let gitMissingStatus: Int32 = 83
    /// The Host-side watchdog stopped the network steps.
    static let timedOutStatus: Int32 = 84
    /// The script got no usable input: two lines, the first an absolute path.
    static let unusableInputStatus: Int32 = 85
    /// The source checkout directory no longer exists on the Host.
    static let checkoutMissingStatus: Int32 = 86

    /// The Host-side limit on the network steps together, inside
    /// ``timeout`` so the Host gives up first and frees its SSH session.
    static let hostLimitSeconds = 50

    /// The app's whole budget for one resolution, channel wait included.
    static let timeout: Duration = .seconds(60)

    /// One POSIX `/bin/sh` run (dash and bash-as-sh alike). Its inputs come
    /// on stdin, never argv, so any path survives: line 1 is the source
    /// checkout, line 2 the requested branch (empty for a generated one).
    /// It fails closed: missing lines, a relative path or a vanished
    /// directory stop it before git runs anywhere else (such as `$HOME`).
    ///
    /// Git's terminal prompt is off (`GIT_TERMINAL_PROMPT=0`,
    /// `GCM_INTERACTIVE=never`, `SSH_ASKPASS_REQUIRE=never`,
    /// `credential.interactive=never`, stdin from `/dev/null`). Configured
    /// askpass programs and credential helpers still run, bounded by the
    /// watchdog, so the user's SSH and HTTPS setup keeps working.
    /// `ls-remote origin HEAD`
    /// is the authoritative, read-only answer for the default branch. The
    /// fetch has an empty refmap, so it downloads that commit and updates no
    /// refs and no tags: nothing the user or another agent holds a ref lock
    /// on is touched. `FETCH_HEAD` is never read, since concurrent fetches
    /// race on it. Git's stderr is the failure detail; the network steps
    /// write it to a temporary file first, so an ssh or helper process that
    /// outlives a stopped git cannot hold the exec channel open.
    static let command: String = {
        let script = "\(HerdrHostPath.pathExport); "
            + "export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never SSH_ASKPASS_REQUIRE=never; "
            + "{ IFS= read -r d && IFS= read -r b; } || "
            + "{ echo \"the Host did not receive the checkout path\" >&2; exit \(unusableInputStatus); }; "
            + "exec </dev/null; "
            + "case $d in /*) ;; *) echo \"the checkout path is not absolute\" >&2; "
            + "exit \(unusableInputStatus);; esac; "
            + "[ -d \"$d\" ] || { printf \"the checkout %s is gone from the Host\\n\" \"$d\" >&2; "
            + "exit \(checkoutMissingStatus); }; "
            + "command -v git >/dev/null 2>&1 || "
            + "{ echo \"git is not on the Host PATH for SSH commands\" >&2; exit \(gitMissingStatus); }; "
            + "if [ -n \"$b\" ] && git -C \"$d\" show-ref --verify --quiet \"refs/heads/$b\"; then "
            + "echo \(existingBranchMarker); exit 0; fi; "
            + "\(HostWatchdog.definition); "
            + "e=$(mktemp) || exit \(fetchFailedStatus); trap \"rm -f \\\"\\$e\\\"\" EXIT; "
            + "t=$(($(date +%s) + \(hostLimitSeconds))); "
            + "o=$(waycar_watch $((t - $(date +%s))) git -c credential.interactive=never "
            + "-C \"$d\" ls-remote origin HEAD 2>\"$e\"); "
            + "s=$?; [ $s -ne \(HostWatchdog.stoppedStatus) ] || exit \(timedOutStatus); "
            + "[ $s -eq 0 ] || { cat \"$e\" >&2; exit \(fetchFailedStatus); }; "
            + "c=$(printf \"%s\\n\" \"$o\" | awk \"\\$2 == \\\"HEAD\\\" { print \\$1; exit }\"); "
            + "[ -n \"$c\" ] || { echo \"origin does not report a default branch (HEAD)\" >&2; "
            + "exit \(defaultBranchUnresolvedStatus); }; "
            + "waycar_watch $((t - $(date +%s))) git -c gc.auto=0 -c maintenance.auto=false "
            + "-c credential.interactive=never "
            + "-C \"$d\" fetch --no-tags --no-recurse-submodules --refmap= origin HEAD "
            + ">\"$e\" 2>&1; s=$?; "
            + "[ $s -ne \(HostWatchdog.stoppedStatus) ] || exit \(timedOutStatus); "
            + "[ $s -eq 0 ] || { cat \"$e\" >&2; exit \(fetchFailedStatus); }; "
            + "git -C \"$d\" cat-file -e \"$c^{commit}\" 2>/dev/null || "
            + "{ echo \"origin moved its default branch during the fetch\" >&2; "
            + "exit \(defaultBranchUnresolvedStatus); }; "
            + "printf \"\(commitMarker)%s\\n\" \"$c\""
        return "/bin/sh -c '\(script)' waycar-worktree-base"
    }()

    /// The stdin ``command`` reads. The checkout must be absolute and free
    /// of control characters (a newline would split the lines); quotes and
    /// backslashes are fine, since the shell never parses it. A branch with
    /// a control character is sent empty: git refuses such names, so it can
    /// never be an existing branch, and herdr reports the bad name itself.
    static func input(
        sourceCheckoutPath: String, branch: String?
    ) throws(WorktreeBaseResolutionError) -> Data {
        guard sourceCheckoutPath.hasPrefix("/"), !hasControlCharacter(sourceCheckoutPath) else {
            throw .unusableCheckoutPath(
                detail: "the source checkout path \(sourceCheckoutPath.debugDescription) "
                    + "cannot be passed to the Host")
        }
        let branchLine = branch.flatMap { hasControlCharacter($0) ? nil : $0 } ?? ""
        return Data("\(sourceCheckoutPath)\n\(branchLine)\n".utf8)
    }

    /// Reads one run of ``command``. Marker lines are the only answer, so
    /// login-shell noise around them is harmless.
    static func resolution(
        exitStatus: Int32, stdout: Data, stderr: Data
    ) throws(WorktreeBaseResolutionError) -> Resolution {
        switch exitStatus {
        case 0:
            break
        case fetchFailedStatus:
            throw .fetchFailed(detail: detail(stderr, fallback: "git fetch failed"))
        case defaultBranchUnresolvedStatus:
            throw .defaultBranchUnresolved(
                detail: detail(stderr, fallback: "origin does not report a default branch"))
        case gitMissingStatus:
            throw .gitMissing
        case timedOutStatus:
            throw .timedOut(detail: "git fetch did not finish within \(hostLimitSeconds) seconds")
        case unusableInputStatus:
            throw .unusableCheckoutPath(
                detail: detail(stderr, fallback: "the Host did not receive the checkout path"))
        case checkoutMissingStatus:
            throw .checkoutMissing(
                detail: detail(stderr, fallback: "the checkout is gone from the Host"))
        default:
            throw .invalidOutput(
                detail: detail(stderr, fallback: "the Host command exited with status \(exitStatus)"))
        }
        let lines = String(decoding: stdout, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(existingBranchMarker) { return .existingBranch }
        guard
            let commit = lines.last(where: { $0.hasPrefix(commitMarker) })?
                .dropFirst(commitMarker.count),
            isCommitHash(commit)
        else {
            throw .invalidOutput(detail: "the Host did not report a commit")
        }
        return .commit(String(commit))
    }

    /// A full SHA-1 or SHA-256 object name, as `ls-remote` prints it.
    private static func isCommitHash(_ value: Substring) -> Bool {
        (value.count == 40 || value.count == 64)
            && value.unicodeScalars.allSatisfy {
                ("0"..."9").contains($0) || ("a"..."f").contains($0)
            }
    }

    private static func hasControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// How many characters of git's stderr a failure detail keeps.
    static let detailLimit = 400

    /// The last ``detailLimit`` characters of git's stderr, as one line:
    /// decoded first so no character is split, then cut at a line boundary
    /// from the end (git's last `fatal:` line is the one that matters), with
    /// URL credentials (`://user:token@`) removed.
    private static func detail(_ stderr: Data, fallback: String) -> String {
        let lines = String(decoding: stderr, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map {
                $0.trimmingCharacters(in: .whitespaces)
                    .replacing(#/:\/\/[^\/@\s]+@/#, with: "://")
            }
            .filter { !$0.isEmpty }
        var kept: [String] = []
        var length = 0
        for line in lines.reversed() {
            let added = line.count + (kept.isEmpty ? 0 : 1)
            if length + added > detailLimit {
                if kept.isEmpty { kept.append(String(line.suffix(detailLimit))) }
                break
            }
            kept.insert(line, at: 0)
            length += added
        }
        var joined = kept.joined(separator: " ")
        while joined.last == "." { joined.removeLast() }
        return joined.isEmpty ? fallback : joined
    }
}

/// Why `WorktreeBase.latestDefaultBranch` could not be resolved. Every case
/// is thrown before `worktree.create`, so nothing exists to clean up; none
/// is `TransportError.timedOut`, so the Console neither redials nor replays
/// the launch.
enum WorktreeBaseResolutionError: Error, Equatable, Sendable {
    /// What a resolution run throws for `error`: running out of the app's
    /// budget (its deadline or the SSH exec's own) is ``timedOut(detail:)``,
    /// never `TransportError.timedOut`, which `EventsSession` takes for a
    /// dead link and answers by redialing and replaying the launch.
    /// Cancellation is `TransportError.cancelled`; everything else passes
    /// through.
    static func replacingTimeout(_ error: any Error) -> any Error {
        if error is CancellationError { return TransportError.cancelled }
        if error as? AsyncDeadlineError == .timedOut || error as? TransportError == .timedOut {
            return WorktreeBaseResolutionError.timedOut(detail: "the Host did not answer in time")
        }
        return error
    }

    /// `git ls-remote` or `git fetch` against origin failed.
    case fetchFailed(detail: String)
    /// Origin names no default branch, or its commit did not arrive.
    case defaultBranchUnresolved(detail: String)
    /// `git` is not on the Host's PATH for SSH commands.
    case gitMissing
    /// The Host-side watchdog stopped git, or the Host did not answer
    /// within the app's budget.
    case timedOut(detail: String)
    /// The source checkout path cannot be sent to the Host, or the Host
    /// did not receive a usable one.
    case unusableCheckoutPath(detail: String)
    /// The source checkout directory is gone from the Host.
    case checkoutMissing(detail: String)
    /// The workspace is a linked worktree; herdr refuses those as a source.
    case linkedWorktreeSource
    /// The Host's answer was unreadable.
    case invalidOutput(detail: String)

    var detail: String {
        switch self {
        case .fetchFailed(let detail), .defaultBranchUnresolved(let detail),
            .timedOut(let detail), .unusableCheckoutPath(let detail),
            .checkoutMissing(let detail), .invalidOutput(let detail):
            detail
        case .gitMissing:
            "git isn't on the Host's PATH for SSH commands"
        case .linkedWorktreeSource:
            "this workspace is itself a worktree"
        }
    }
}
