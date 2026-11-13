import Foundation
import Testing

@testable import Waycar

/// The Agent Footer's Branch (#169) is one `git` exec on the Host: the cwd
/// must reach `git -C` as a single word whatever it holds, a cwd that cannot
/// travel safely never reaches a shell, and the field follows the reader
/// without ever failing loudly.
@MainActor
@Suite("Agent git branch")
struct AgentGitBranchTests {
    /// Answers the store's reads in order, recording what the store showed
    /// when each read began; past the script every read answers `fallback`.
    @MainActor
    private final class ScriptedReads {
        struct Failure: Error {}

        let store: AgentGitBranchStore
        var answers: [Result<String?, Failure>]
        let fallback: String?
        private(set) var cwds: [String] = []
        private(set) var branchesSeen: [String?] = []

        init(store: AgentGitBranchStore, answers: [Result<String?, Failure>], fallback: String? = nil) {
            self.store = store
            self.answers = answers
            self.fallback = fallback
        }

        func read(_ cwd: String) throws -> String? {
            cwds.append(cwd)
            branchesSeen.append(store.branch)
            guard !answers.isEmpty else { return fallback }
            return try answers.removeFirst().get()
        }

        var reader: GitBranchReader {
            { [self] cwd in try await self.read(cwd) }
        }
    }

    /// Holds each read until the test opens it with an answer.
    private actor GatedReads {
        private var pending: CheckedContinuation<String?, any Error>?

        /// Signals `started` only once the read is waiting, so `open` never misses it.
        func read(started: AsyncStream<Void>.Continuation) async throws -> String? {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.yield()
            }
        }

        func open(_ answer: Result<String?, any Error>) {
            pending?.resume(with: answer)
            pending = nil
        }
    }

    @Test("the cwd reaches git as one quoted word, spaces included")
    func cwdIsQuoted() throws {
        let command = try #require(GitBranchProbe.command(cwd: "/Users/me/my repo"))
        #expect(command.hasPrefix("/bin/sh -c '"))
        #expect(command.contains(HerdrHostPath.pathExport))
        #expect(command.contains(HostWatchdog.definition))
        #expect(command.contains(#"git -C "$1" symbolic-ref --short -q HEAD 2>/dev/null"#))
        #expect(command.contains(#"|| git -C "$1" rev-parse --short HEAD 2>/dev/null"#))
        #expect(command.contains(
            "waycar_watch \(GitBranchProbe.hostLimitSeconds) waycar_branch \"$1\"'"))
        #expect(command.hasSuffix(#"' waycar-git-branch '/Users/me/my repo'"#))
        // The script is one single-quoted word: the cwd is its only Host value.
        let script = try #require(command.components(separatedBy: " waycar-git-branch ").first)
        #expect(script.filter { $0 == "'" }.count == 2)
    }

    @Test("a cwd RemoteShellPath will not quote never reaches a shell")
    func unsafeCwdIsRefused() {
        for bad in [
            "", "repo", "~/repo", "/repo\nrm -rf /", "/repo\r", "/repo\u{7}", "/repo\u{7F}",
            "/repo\\x", "/Users/me/it's",
        ] {
            #expect(GitBranchProbe.command(cwd: bad) == nil, "\(bad.debugDescription)")
        }
        #expect(GitBranchProbe.command(cwd: "/") != nil)
        #expect(GitBranchProbe.command(cwd: "/Users/me/café") != nil)
    }

    @Test("the answer is git's last line, trimmed")
    func outputIsParsed() {
        #expect(GitBranchProbe.branch(in: Data("main\n".utf8)) == "main")
        #expect(GitBranchProbe.branch(in: Data("feature/agent-footer".utf8)) == "feature/agent-footer")
        #expect(GitBranchProbe.branch(in: Data("a1b2c3d\n".utf8)) == "a1b2c3d")
        #expect(GitBranchProbe.branch(in: Data("  main \r\n".utf8)) == "main")
        // Login-shell noise ahead of git's answer is not the branch.
        #expect(GitBranchProbe.branch(in: Data("Welcome to the Host\nmain\n\n".utf8)) == "main")
        #expect(GitBranchProbe.branch(in: Data()) == nil)
        #expect(GitBranchProbe.branch(in: Data("\n  \n".utf8)) == nil)
    }

    @Test("a bidi override in the name is stripped")
    func bidiIsStripped() {
        #expect(GitBranchProbe.branch(in: Data("evil\u{202E}gnp.exe\n".utf8)) == "evilgnp.exe")
        #expect(GitBranchProbe.branch(in: Data("main\n\u{202E}\u{200B}\n".utf8)) == "main")
    }

    @Test("output over the limit is no branch")
    func oversizeOutputIsRejected() {
        let big = Data(repeating: UInt8(ascii: "a"), count: GitBranchProbe.outputLimit + 1)
        #expect(GitBranchProbe.branch(in: big) == nil)
        let fits = Data(repeating: UInt8(ascii: "a"), count: GitBranchProbe.outputLimit)
        #expect(GitBranchProbe.branch(in: fits) != nil)
    }

    @Test("a skipped read keeps the previous branch")
    func skippedReadKeepsBranch() async throws {
        let store = AgentGitBranchStore(interval: .zero)
        let gates = GatedReads()
        let starts = AsyncStream<Void>.makeStream()
        let reader: GitBranchReader = { _ in try await gates.read(started: starts.continuation) }
        var started = starts.stream.makeAsyncIterator()
        let follow = Task { await store.follow(cwd: "/repo", read: reader) }

        _ = await started.next()
        await gates.open(.success("main"))
        try await waitUntil("the first read should set the branch") { store.branch == "main" }

        _ = await started.next()
        #expect(store.branch == "main")
        await gates.open(.failure(GitBranchProbe.Skipped()))
        // Read 3 starting proves read 2 finished and the store looped.
        _ = await started.next()
        #expect(store.branch == "main")

        await gates.open(.success("dev"))
        try await waitUntil("the next read should set the branch") { store.branch == "dev" }

        _ = await started.next()
        follow.cancel()
        await gates.open(.success(nil))
        await follow.value
        #expect(store.branch == "dev")
    }

    @Test("the first read sets the branch at once, then the store waits")
    func firstReadSetsBranch() async throws {
        let store = AgentGitBranchStore()
        let reads = ScriptedReads(store: store, answers: [.success("main")])
        let follow = Task { await store.follow(cwd: "/repo", read: reads.reader) }
        try await waitUntil("the first read should set the branch") { store.branch == "main" }
        follow.cancel()
        await follow.value
        #expect(reads.cwds == ["/repo"])
        #expect(store.branch == "main")
    }

    @Test("a read error clears the branch and polling continues")
    func readErrorClearsBranchAndKeepsPolling() async throws {
        let store = AgentGitBranchStore(interval: .milliseconds(1))
        let reads = ScriptedReads(
            store: store,
            answers: [.success("main"), .failure(ScriptedReads.Failure())],
            fallback: "dev")
        let follow = Task { await store.follow(cwd: "/repo", read: reads.reader) }
        try await waitUntil("polling should go on after the error") { store.branch == "dev" }
        follow.cancel()
        await follow.value
        // What the store showed as each of the first three reads began.
        #expect(Array(reads.branchesSeen.prefix(3)) == [nil, "main", nil])
    }

    @Test("a nil cwd pauses: the branch stays and the same cwd resumes without clearing")
    func nilCwdPausesAndKeepsBranch() async throws {
        let store = AgentGitBranchStore()
        let gates = GatedReads()
        let starts = AsyncStream<Void>.makeStream()
        let reader: GitBranchReader = { _ in try await gates.read(started: starts.continuation) }
        var started = starts.stream.makeAsyncIterator()
        let follow = Task { await store.follow(cwd: "/repo", read: reader) }
        _ = await started.next()
        await gates.open(.success("main"))
        try await waitUntil("the first read should set the branch") { store.branch == "main" }
        follow.cancel()
        await follow.value

        await store.follow(cwd: nil, read: reader)
        #expect(store.branch == "main")

        let resumed = Task { await store.follow(cwd: "/repo", read: reader) }
        _ = await started.next()
        // The same cwd keeps the branch while its read is pending.
        #expect(store.branch == "main")
        resumed.cancel()
        await gates.open(.success(nil))
        await resumed.value
        #expect(store.branch == "main")
    }

    @Test("a new cwd clears the old branch before its first read")
    func newCwdClearsBranch() async throws {
        let store = AgentGitBranchStore()
        let reads = ScriptedReads(store: store, answers: [.success("main"), .success("dev")])
        let first = Task { await store.follow(cwd: "/a", read: reads.reader) }
        try await waitUntil("the first read should set the branch") { store.branch == "main" }
        first.cancel()
        await first.value

        // Resuming the same cwd keeps the branch while its read runs.
        let resumed = Task { await store.follow(cwd: "/a", read: reads.reader) }
        try await waitUntil("the resumed read should run") { reads.cwds.count == 2 }
        resumed.cancel()
        await resumed.value
        #expect(reads.branchesSeen == [nil, "main"])

        let moved = Task { await store.follow(cwd: "/b", read: reads.reader) }
        try await waitUntil("the new cwd's read should run") { reads.cwds.count == 3 }
        moved.cancel()
        await moved.value
        #expect(reads.cwds == ["/a", "/a", "/b"])
        #expect(reads.branchesSeen.last == .some(nil))
    }

    @Test("cancelling mid-read lets the read finish but writes nothing")
    func cancelMidReadDoesNotWrite() async throws {
        let store = AgentGitBranchStore()
        let gate = AsyncStream<String?>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        let cancelledSeen = AsyncStream<Bool>.makeStream()
        let reader: GitBranchReader = { _ in
            started.continuation.yield()
            var answers = gate.stream.makeAsyncIterator()
            let answer = await answers.next() ?? nil
            cancelledSeen.continuation.yield(Task.isCancelled)
            return answer
        }
        let follow = Task { await store.follow(cwd: "/repo", read: reader) }
        var starts = started.stream.makeAsyncIterator()
        _ = await starts.next()
        follow.cancel()
        gate.continuation.yield("main")
        await follow.value
        #expect(store.branch == nil)
        var cancelled = cancelledSeen.stream.makeAsyncIterator()
        // The read runs in its own task: the view's cancel never reaches it.
        #expect(await cancelled.next() == false)
    }
}
