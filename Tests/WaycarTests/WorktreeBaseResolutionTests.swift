import Foundation
import Testing

@testable import Waycar

// The latest-main step's stdin contract and its output parsing, pinned
// without sshd: the unit lane has no Host shell or git. The script's real
// behavior is exercised against real repositories over real SSH by
// WaycarSSHTransportBehaviorE2ETests.
@Suite("worktree base resolution")
struct WorktreeBaseResolutionTests {
    private let sha1 = String(repeating: "a1", count: 20)
    private let sha256 = String(repeating: "0f", count: 32)

    private func run(
        _ status: Int32, stdout: String = "", stderr: String = ""
    ) throws(WorktreeBaseResolutionError) -> WorktreeBaseResolution.Resolution {
        try WorktreeBaseResolution.resolution(
            exitStatus: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
    }

    private func commitLine(_ commit: String) -> String {
        "\(WorktreeBaseResolution.commitMarker)\(commit)\n"
    }

    // MARK: input

    @Test func quotesAndBackslashesReachTheHostVerbatim() throws {
        let input = try WorktreeBaseResolution.input(
            sourceCheckoutPath: "/Users/me/it's a \\ \"repo\"", branch: "task/fix-97")
        #expect(String(decoding: input, as: UTF8.self) == "/Users/me/it's a \\ \"repo\"\ntask/fix-97\n")
    }

    @Test func aGeneratedBranchIsAnEmptyLine() throws {
        let input = try WorktreeBaseResolution.input(sourceCheckoutPath: "/r", branch: nil)
        #expect(String(decoding: input, as: UTF8.self) == "/r\n\n")
    }

    @Test(arguments: ["repo", "", "/a\nb", "/a\rb", "/a\u{7F}b", "/a\u{85}b"])
    func unusableCheckoutPathsAreRefused(_ path: String) {
        let error = #expect(throws: WorktreeBaseResolutionError.self) {
            try WorktreeBaseResolution.input(sourceCheckoutPath: path, branch: nil)
        }
        guard case .unusableCheckoutPath = error else {
            Issue.record("expected unusableCheckoutPath, got \(String(describing: error))")
            return
        }
    }

    @Test func aBranchThatCouldSplitTheLinesIsSentEmpty() throws {
        let input = try WorktreeBaseResolution.input(sourceCheckoutPath: "/r", branch: "a\nb")
        #expect(String(decoding: input, as: UTF8.self) == "/r\n\n")
    }

    // MARK: output

    @Test func successReportsTheCommitDespiteNoiseAndCRLF() throws {
        let stdout = "Last login: yesterday\r\n" + "\(WorktreeBaseResolution.commitMarker)\(sha1)\r\n"
            + "bye\r\n"
        #expect(try run(0, stdout: stdout) == .commit(sha1))
    }

    @Test func anExistingBranchNeedsNoCommit() throws {
        let stdout = "motd\n\(WorktreeBaseResolution.existingBranchMarker)\nmore noise\n"
        #expect(try run(0, stdout: stdout) == .existingBranch)
    }

    @Test(arguments: [40, 64])
    func fullObjectNamesAreAccepted(_ length: Int) throws {
        let commit = String(repeating: "c", count: length)
        #expect(try run(0, stdout: commitLine(commit)) == .commit(commit))
    }

    @Test(arguments: [7, 39, 41, 63, 65])
    func otherLengthsAreInvalid(_ length: Int) {
        #expect(throws: WorktreeBaseResolutionError.invalidOutput(
            detail: "the Host did not report a commit")
        ) {
            try run(0, stdout: commitLine(String(repeating: "c", count: length)))
        }
    }

    @Test func garbageOutputIsInvalid() {
        let noCommit = WorktreeBaseResolutionError.invalidOutput(
            detail: "the Host did not report a commit")
        #expect(throws: noCommit) { try run(0, stdout: "hello\n") }
        #expect(throws: noCommit) { try run(0) }
        #expect(throws: noCommit) { try run(0, stdout: commitLine("not-a-sha")) }
    }

    @Test func fetchFailureCarriesGitStderrAsOneLine() {
        #expect(throws: WorktreeBaseResolutionError.fetchFailed(
            detail: "fatal: 'origin' does not appear to be a git repository "
                + "fatal: Could not read from remote repository")
        ) {
            try run(
                WorktreeBaseResolution.fetchFailedStatus,
                stderr: "fatal: 'origin' does not appear to be a git repository\n"
                    + "fatal: Could not read from remote repository.\n\n")
        }
        #expect(throws: WorktreeBaseResolutionError.fetchFailed(detail: "git fetch failed")) {
            try run(WorktreeBaseResolution.fetchFailedStatus)
        }
    }

    @Test func anUnresolvedDefaultBranchPassesItsDetailThrough() {
        #expect(throws: WorktreeBaseResolutionError.defaultBranchUnresolved(
            detail: "origin moved its default branch during the fetch")
        ) {
            try run(
                WorktreeBaseResolution.defaultBranchUnresolvedStatus,
                stderr: "origin moved its default branch during the fetch\n")
        }
        #expect(throws: WorktreeBaseResolutionError.defaultBranchUnresolved(
            detail: "origin does not report a default branch")
        ) {
            try run(WorktreeBaseResolution.defaultBranchUnresolvedStatus)
        }
    }

    @Test func aMissingGitIsItsOwnFailure() {
        #expect(throws: WorktreeBaseResolutionError.gitMissing) {
            try run(WorktreeBaseResolution.gitMissingStatus, stderr: "anything\n")
        }
    }

    @Test func unusableInputAndAVanishedCheckoutAreTheirOwnFailures() {
        #expect(throws: WorktreeBaseResolutionError.unusableCheckoutPath(
            detail: "the checkout path is not absolute")
        ) {
            try run(
                WorktreeBaseResolution.unusableInputStatus,
                stderr: "the checkout path is not absolute\n")
        }
        #expect(throws: WorktreeBaseResolutionError.unusableCheckoutPath(
            detail: "the Host did not receive the checkout path")
        ) {
            try run(WorktreeBaseResolution.unusableInputStatus)
        }
        #expect(throws: WorktreeBaseResolutionError.checkoutMissing(
            detail: "the checkout /src/it's gone is gone from the Host")
        ) {
            try run(
                WorktreeBaseResolution.checkoutMissingStatus,
                stderr: "the checkout /src/it's gone is gone from the Host\n")
        }
        #expect(throws: WorktreeBaseResolutionError.checkoutMissing(
            detail: "the checkout is gone from the Host")
        ) {
            try run(WorktreeBaseResolution.checkoutMissingStatus)
        }
    }

    @Test func theHostWatchdogIsATimeoutNamingItsLimit() {
        #expect(throws: WorktreeBaseResolutionError.timedOut(
            detail: "git fetch did not finish within 50 seconds")
        ) {
            try run(WorktreeBaseResolution.timedOutStatus)
        }
        #expect(.seconds(WorktreeBaseResolution.hostLimitSeconds) < WorktreeBaseResolution.timeout)
    }

    @Test func anUnexpectedStatusKeepsItsDetail() {
        #expect(throws: WorktreeBaseResolutionError.invalidOutput(detail: "sh: Permission denied")) {
            try run(126, stderr: "sh: Permission denied\n")
        }
        #expect(throws: WorktreeBaseResolutionError.invalidOutput(
            detail: "the Host command exited with status 2")
        ) {
            try run(2)
        }
    }

    /// Running out of the app's budget is the resolution's own failure;
    /// `TransportError.timedOut` would make EventsSession redial the Host and
    /// replay the launch. Cancellation and every other failure keep their
    /// meaning.
    @Test func runningOutOfTimeIsTheResolutionsFailureNotALinkFailure() {
        let timedOut = WorktreeBaseResolutionError.timedOut(detail: "the Host did not answer in time")
        #expect(
            WorktreeBaseResolutionError.replacingTimeout(AsyncDeadlineError.timedOut)
                as? WorktreeBaseResolutionError == timedOut)
        #expect(
            WorktreeBaseResolutionError.replacingTimeout(TransportError.timedOut)
                as? WorktreeBaseResolutionError == timedOut)
        #expect(
            WorktreeBaseResolutionError.replacingTimeout(CancellationError())
                as? TransportError == .cancelled)
        #expect(
            WorktreeBaseResolutionError.replacingTimeout(TransportError.cancelled)
                as? TransportError == .cancelled)
        let unreachable = TransportError.sshUnreachable(detail: "gone")
        #expect(
            WorktreeBaseResolutionError.replacingTimeout(unreachable) as? TransportError
                == unreachable)
        #expect(
            WorktreeBaseResolutionError.replacingTimeout(WorktreeBaseResolutionError.gitMissing)
                as? WorktreeBaseResolutionError == .gitMissing)
    }

    // MARK: detail

    @Test func longStderrKeepsItsLastLinesWholeAndBounded() throws {
        let chatter = (0..<200).map { "remote: counting objects é \($0)" }.joined(separator: "\n")
        let stderr = chatter + "\nfatal: unable to access 'https://example.com/r.git/'\n"
        // A multi-byte character split at a byte boundary before decoding
        // would surface as U+FFFD.
        let detail = try #require(fetchFailureDetail(stderr))
        #expect(detail.hasSuffix("fatal: unable to access 'https://example.com/r.git/'"))
        #expect(detail.count <= WorktreeBaseResolution.detailLimit)
        #expect(!detail.contains("\u{FFFD}"))
        #expect(detail.hasPrefix("remote: counting objects é"))
    }

    @Test func aSingleOverlongLineKeepsItsEnd() throws {
        let line = String(repeating: "é", count: 1_000) + " fatal: end"
        let detail = try #require(fetchFailureDetail(line))
        #expect(detail.count == WorktreeBaseResolution.detailLimit)
        #expect(detail.hasSuffix(" fatal: end"))
        #expect(!detail.contains("\u{FFFD}"))
    }

    @Test func urlCredentialsAreRedacted() throws {
        let detail = try #require(fetchFailureDetail(
            "fatal: unable to access 'https://mike:ghp_s3cret@github.com/o/r.git/': 403\n"
                + "fatal: could not read from ssh://git@host:22/r.git\n"))
        #expect(!detail.contains("ghp_s3cret"))
        #expect(!detail.contains("mike"))
        #expect(detail.contains("'https://github.com/o/r.git/'"))
        #expect(detail.contains("ssh://host:22/r.git"))
    }

    private func fetchFailureDetail(_ stderr: String) -> String? {
        do {
            _ = try run(WorktreeBaseResolution.fetchFailedStatus, stderr: stderr)
            return nil
        } catch {
            guard case .fetchFailed(let detail) = error else { return nil }
            return detail
        }
    }
}
