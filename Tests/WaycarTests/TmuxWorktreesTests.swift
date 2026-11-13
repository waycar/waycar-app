import Foundation
import Synchronization
import Testing
import WaycarSSH

@testable import Waycar

@Suite("tmux worktrees")
struct TmuxWorktreesTests {
    static let worktreePath = "/home/me/.herdr/worktrees/proj/calm-river-0001"
    static let mintedBranch = "worktree/calm-river-0001"

    // MARK: Listing and metadata

    @Test func listMapsPorcelainOntoTheMainCheckoutAndLinkedEntries() async throws {
        let host = WorktreeHostScript.repository()
        let (transport, fake) = try await Self.open(host)

        let listing = try await transport.listWorktrees(forWorkspaceID: "tmux:$1")
        #expect(listing == WorktreeListResponse(
            source: WorktreeSourceInfo(
                repoKey: "/work/proj/.git", repoName: "proj", repoRoot: "/work/proj",
                sourceCheckoutPath: "/work/proj", sourceWorkspaceID: "tmux:$1"),
            worktrees: [
                WorktreeInfo(
                    isBare: false, isDetached: false, isLinkedWorktree: false, isPrunable: false,
                    label: "proj", path: "/work/proj", branch: "main", openWorkspaceID: "tmux:$1"),
                WorktreeInfo(
                    isBare: false, isDetached: false, isLinkedWorktree: true, isPrunable: false,
                    label: "feat-x", path: "/work/wt/feat-x", branch: "feat/x",
                    openWorkspaceID: "tmux:$2"),
                WorktreeInfo(
                    isBare: false, isDetached: true, isLinkedWorktree: true, isPrunable: false,
                    label: "det", path: "/work/wt/det"),
                WorktreeInfo(
                    isBare: false, isDetached: false, isLinkedWorktree: true, isPrunable: true,
                    label: "gone", path: "/work/wt/gone", branch: "old"),
            ]))
        #expect(await fake.execs(containing: Self.listMatch).last?.command
            .hasSuffix(" sh '/work/proj'") == true)

        // From the linked worktree's Workspace the source is still the main
        // checkout; git runs in the linked one.
        let linked = try await transport.listWorktrees(forWorkspaceID: "tmux:$2")
        #expect(linked.source.sourceCheckoutPath == "/work/proj")
        #expect(linked.source.sourceWorkspaceID == "tmux:$2")
        #expect(await fake.execs(containing: Self.listMatch).last?.command
            .hasSuffix(" sh '/work/wt/feat-x'") == true)
        try await transport.close()
    }

    @Test func snapshotCarriesMetadataForMainAndLinkedCheckoutsFromOneCachedLookup() async throws {
        let host = WorktreeHostScript.repository()
        host.update {
            $0.sessionRecords.append(WorktreeHostScript.session("$3", "home", path: "/home/me"))
            $0.windowRecords.append(WorktreeHostScript.window("@3", session: "$3"))
            $0.paneRecords.append(
                WorktreeHostScript.pane("%3", session: "$3", window: "@3", path: "/home/me"))
        }
        let (transport, fake) = try await Self.open(host)

        let snapshot = try await transport.sessionSnapshot()
        let worktrees = Dictionary(
            uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceID, $0.worktree) })
        #expect(worktrees["tmux:$1"] == WorkspaceWorktreeInfo(
            checkoutPath: "/work/proj", isLinkedWorktree: false, repoKey: "/work/proj/.git",
            repoName: "proj", repoRoot: "/work/proj"))
        #expect(worktrees["tmux:$2"] == WorkspaceWorktreeInfo(
            checkoutPath: "/work/wt/feat-x", isLinkedWorktree: true, repoKey: "/work/proj/.git",
            repoName: "proj", repoRoot: "/work/proj"))
        #expect(worktrees["tmux:$3"] == .some(nil))
        let lookups = await fake.execs(containing: Self.checkoutMatch)
        #expect(lookups.count == 1)
        #expect(lookups.first?.command.hasSuffix(" sh '/home/me' '/work/proj' '/work/wt/feat-x'") == true)

        // Every directory, the non-git one included, is cached.
        _ = try await transport.sessionSnapshot()
        #expect(await fake.execs(containing: Self.checkoutMatch).count == 1)
        try await transport.close()
    }

    @Test func nonGitWorkspaceIsNotAGitWorktreeAndCreatesNothing() async throws {
        let host = WorktreeHostScript.repository()
        host.update { $0.checkouts = "" }
        let (transport, fake) = try await Self.open(host)

        await #expect(throws: HerdrAPIError.self) {
            try await transport.listWorktrees(forWorkspaceID: "tmux:$1")
        }
        do {
            _ = try await transport.startAgentInNewWorktree(
                Self.agentRequest(), worktree: WorktreeSpec(branch: Self.mintedBranch),
                attempt: WorktreeLaunchAttempt())
            Issue.record("a launch from a non-git workspace succeeded")
        } catch let error as HerdrAPIError {
            #expect(error.code == "not_git_worktree")
        }
        #expect(await fake.execs(containing: Self.listMatch).isEmpty)
        #expect(await fake.execs(containing: "worktree add").isEmpty)
        try await transport.close()
    }

    @Test func linkedWorkspaceIsRefusedAsALaunchSource() async throws {
        let host = WorktreeHostScript.repository()
        let (transport, fake) = try await Self.open(host)

        await #expect(throws: WorktreeBaseResolutionError.linkedWorktreeSource) {
            try await transport.startAgentInNewWorktree(
                Self.agentRequest(workspaceID: "tmux:$2"),
                worktree: WorktreeSpec(branch: Self.mintedBranch, branchIsGenerated: true),
                attempt: WorktreeLaunchAttempt())
        }
        #expect(await fake.execs(containing: "worktree add").isEmpty)
        try await transport.close()
    }

    // MARK: Login-shell safety

    /// A quote or backslash reads differently in fish's single quotes, so a
    /// directory holding one never reaches the login shell: the snapshot's
    /// lookup skips it, a user-initiated listing is refused.
    @Test func directoriesTheLoginShellCannotQuoteNeverReachAnExec() async throws {
        let host = WorktreeHostScript.repository()
        let quote = "/home/me/x\\'; touch /tmp/pwned; echo '"
        let backslash = "/home/me/back\\slash"
        host.update {
            $0.sessionRecords.append(WorktreeHostScript.session("$3", "q", path: quote))
            $0.sessionRecords.append(WorktreeHostScript.session("$4", "b", path: backslash))
            $0.windowRecords.append(WorktreeHostScript.window("@3", session: "$3"))
            $0.windowRecords.append(WorktreeHostScript.window("@4", session: "$4"))
            $0.paneRecords.append(
                WorktreeHostScript.pane("%3", session: "$3", window: "@3", path: quote))
            $0.paneRecords.append(
                WorktreeHostScript.pane("%4", session: "$4", window: "@4", path: backslash))
        }
        let (transport, fake) = try await Self.open(host)

        let snapshot = try await transport.sessionSnapshot()
        let worktrees = Dictionary(
            uniqueKeysWithValues: snapshot.workspaces.map { ($0.workspaceID, $0.worktree) })
        #expect(worktrees["tmux:$3"] == .some(nil))
        #expect(worktrees["tmux:$4"] == .some(nil))
        #expect(worktrees["tmux:$1"]??.checkoutPath == "/work/proj")
        let lookups = await fake.execs(containing: Self.checkoutMatch)
        #expect(lookups.count == 1)
        #expect(lookups.first?.command.hasSuffix(" sh '/work/proj' '/work/wt/feat-x'") == true)

        await #expect(throws: TransportError.invalidDirectoryPath(path: quote)) {
            try await transport.listWorktrees(forWorkspaceID: "tmux:$3")
        }
        await #expect(throws: TransportError.invalidDirectoryPath(path: backslash)) {
            try await transport.startAgentInNewWorktree(
                Self.agentRequest(workspaceID: "tmux:$4"),
                worktree: WorktreeSpec(branch: Self.mintedBranch),
                attempt: WorktreeLaunchAttempt())
        }
        #expect(await fake.execs(containing: "pwned").isEmpty)
        #expect(await fake.execs(containing: "back\\slash").isEmpty)
        #expect(await fake.execs(containing: "worktree add").isEmpty)
        try await transport.close()
    }

    /// git allows a quote in a ref name, and `'\''` reads alike in POSIX
    /// shells and fish; a backslash, which git refuses, never reaches the
    /// login shell and records no dispatch.
    @Test func refNamesWithAQuoteReachGitAndABackslashIsRefusedBeforeDispatch() async throws {
        let checkout = "/home/me/.herdr/worktrees/proj/fix-mike's-bug"
        let host = WorktreeHostScript.repository()
        host.update {
            $0.add = FakeHostSSHServices.result(stdout: "__WAYCAR_WORKTREE__=\(checkout)\n")
        }
        let (transport, fake) = try await Self.open(host)

        let shell = try await transport.startShellTerminalInNewWorktree(
            ShellLaunchRequest(workspaceID: "tmux:$1"),
            worktree: WorktreeSpec(branch: "fix/mike's-bug", base: .ref("origin/it's")),
            attempt: WorktreeLaunchAttempt())
        #expect(shell.workspaceID == "tmux:$9")
        let add = try #require(await fake.execs(containing: "worktree add").first)
        #expect(add.command.hasSuffix(
            #" sh '/work/proj' 'fix/mike'\''s-bug' 'origin/it'\''s' 'proj' 'fix-mike'\''s-bug'"#))

        for spec in [
            WorktreeSpec(branch: "fix\\bug"),
            WorktreeSpec(branch: "fix/ok", base: .ref("origin\\main")),
        ] {
            let attempt = WorktreeLaunchAttempt()
            do {
                _ = try await transport.startAgentInNewWorktree(
                    Self.agentRequest(), worktree: spec, attempt: attempt)
                Issue.record("a launch on \(spec) succeeded")
            } catch let error as HerdrAPIError {
                #expect(error.code == "worktree_create_failed")
            }
            #expect(!attempt.current.createDispatched)
        }
        #expect(await fake.execs(containing: "worktree add").count == 1)
        try await transport.close()
    }

    // MARK: Launches

    @Test func launchAddsTheWorktreeThenASessionRunningTheAgentAndARetryAddsNothing() async throws {
        let host = WorktreeHostScript.repository()
        host.update {
            // The branch slug is taken as a session name: `-2`.
            $0.sessionRecords.append(
                WorktreeHostScript.session("$5", "calm-river-0001", path: "/elsewhere"))
            $0.add = FakeHostSSHServices.result(
                stdout: "__WAYCAR_WORKTREE__=\(Self.worktreePath)\n")
        }
        let (transport, fake) = try await Self.open(host)
        let attempt = WorktreeLaunchAttempt()
        let spec = WorktreeSpec(branch: Self.mintedBranch, branchIsGenerated: true)
        let steps = StepRecorder()

        let agent = try await LaunchProgress.$reporter.withValue({ steps.append($0) }) {
            try await transport.startAgentInNewWorktree(
                Self.agentRequest(), worktree: spec, attempt: attempt)
        }
        #expect(agent.paneID == "tmux:%9")
        #expect(agent.workspaceID == "tmux:$9")
        #expect(agent.kind == "claude")
        #expect(steps.values == [.creatingWorktree, .creatingWorkspace, .startingAgent])

        let add = try #require(await fake.execs(containing: "worktree add").first)
        #expect(add.command.hasSuffix(
            " sh '/work/proj' 'worktree/calm-river-0001' '' 'proj' 'calm-river-0001'"))
        let newSession = TmuxCommand.newSession(
            name: "calm-river-0001-2", cwd: Self.worktreePath,
            environment: TmuxTransport.windowEnvironment,
            command: TmuxCommand.loginShellWrapper(agentCommand: "claude"),
            printFormat: TmuxTransport.launchPrintFormat)
        let log = host.log
        let addIndex = try #require(log.firstIndex(of: "exec:add"))
        let sessionIndex = try #require(log.firstIndex(of: "line:" + newSession))
        #expect(addIndex < sessionIndex)
        #expect(attempt.current.createDispatched)
        #expect(attempt.current.worktree?.path == Self.worktreePath)
        #expect(attempt.current.agentStartDispatchedAt != nil)

        // A replay of the same launch finds the session it opened.
        host.update {
            $0.sessionRecords.append(
                WorktreeHostScript.session("$9", "calm-river-0001-2", path: Self.worktreePath))
            $0.windowRecords.append(WorktreeHostScript.window("@9", session: "$9"))
            $0.paneRecords.append(WorktreeHostScript.pane(
                "%9", session: "$9", window: "@9", path: Self.worktreePath, agent: "claude"))
        }
        let replayed = try await transport.startAgentInNewWorktree(
            Self.agentRequest(), worktree: spec, attempt: attempt)
        #expect(replayed.paneID == "tmux:%9")
        #expect(await fake.execs(containing: "worktree add").count == 1)
        #expect(host.log.filter { $0.hasPrefix("line:new-") }.count == 1)
        try await transport.close()
    }

    @Test func retryAfterAnUnansweredAddContinuesInTheMintedBranchsWorktree() async throws {
        let host = WorktreeHostScript.repository()
        host.update {
            $0.worktreeList = FakeHostSSHServices.result(stdout: WorktreeHostScript.porcelain + """
                worktree \(Self.worktreePath)
                HEAD eeee
                branch refs/heads/\(Self.mintedBranch)

                """)
        }
        let (transport, fake) = try await Self.open(host)
        let attempt = WorktreeLaunchAttempt()
        attempt.recordCreateDispatched()
        let steps = StepRecorder()

        let agent = try await LaunchProgress.$reporter.withValue({ steps.append($0) }) {
            try await transport.startAgentInNewWorktree(
                Self.agentRequest(),
                worktree: WorktreeSpec(branch: Self.mintedBranch, branchIsGenerated: true),
                attempt: attempt)
        }
        #expect(agent.paneID == "tmux:%9")
        #expect(await fake.execs(containing: "worktree add").isEmpty)
        #expect(steps.values.first == .checkingForCreatedWorktree)
        #expect(attempt.current.worktree?.path == Self.worktreePath)
        #expect(host.log.contains("line:" + TmuxCommand.newSession(
            name: "calm-river-0001", cwd: Self.worktreePath,
            environment: TmuxTransport.windowEnvironment,
            command: TmuxCommand.loginShellWrapper(agentCommand: "claude"),
            printFormat: TmuxTransport.launchPrintFormat)))
        try await transport.close()
    }

    @Test func existingBranchIsCheckedOutAsIsWithoutABase() async throws {
        let checkout = "/home/me/.herdr/worktrees/proj/feat-old"
        let host = WorktreeHostScript.repository()
        host.update {
            $0.baseResolution = FakeHostSSHServices.result(
                stdout: WorktreeBaseResolution.existingBranchMarker + "\n")
            $0.add = FakeHostSSHServices.result(stdout: "__WAYCAR_WORKTREE__=\(checkout)\n")
        }
        let (transport, fake) = try await Self.open(host)
        let attempt = WorktreeLaunchAttempt()
        let steps = StepRecorder()

        let shell = try await LaunchProgress.$reporter.withValue({ steps.append($0) }) {
            try await transport.startShellTerminalInNewWorktree(
                ShellLaunchRequest(workspaceID: "tmux:$1"),
                worktree: WorktreeSpec(branch: "feat/old", base: .latestDefaultBranch),
                attempt: attempt)
        }
        #expect(shell == ShellLaunchResult(
            paneID: "tmux:%9", tabID: "tmux:@9",
            terminalID: "tmux:%9@\(WorktreeHostScript.serverIdentity)", workspaceID: "tmux:$9"))
        #expect(steps.values == [
            .gettingLatestMain, .creatingWorktree, .creatingWorkspace, .openingShell,
        ])
        #expect(await fake.execs(containing: "ls-remote origin HEAD").first?.input
            == "/work/proj\nfeat/old\n")
        let add = try #require(await fake.execs(containing: "worktree add").first)
        #expect(add.command.hasSuffix(" sh '/work/proj' 'feat/old' '' 'proj' 'feat-old'"))
        #expect(host.log.contains("line:" + TmuxCommand.newSession(
            name: "feat-old", cwd: checkout, environment: TmuxTransport.windowEnvironment,
            command: nil, printFormat: TmuxTransport.launchPrintFormat)))
        #expect(attempt.current.shellTabDispatched)

        // A replay finds the session it opened and answers its first pane
        // with the same terminal id.
        host.update {
            $0.sessionRecords.append(WorktreeHostScript.session("$9", "feat-old", path: checkout))
            $0.windowRecords.append(WorktreeHostScript.window("@9", session: "$9"))
            $0.paneRecords.append(
                WorktreeHostScript.pane("%9", session: "$9", window: "@9", path: checkout))
        }
        let replayed = try await transport.startShellTerminalInNewWorktree(
            ShellLaunchRequest(workspaceID: "tmux:$1"),
            worktree: WorktreeSpec(branch: "feat/old", base: .latestDefaultBranch),
            attempt: attempt)
        #expect(replayed == shell)
        #expect(host.log.filter { $0.hasPrefix("line:new-") }.count == 1)
        try await transport.close()
    }

    @Test func typedBranchOpenInAWorktreeIsReused() async throws {
        let host = WorktreeHostScript.repository()
        host.update { $0.launched = "%7\u{241F}@7\u{241F}$2" }
        let (transport, fake) = try await Self.open(host)
        let spec = WorktreeSpec(branch: "feat/x")
        let steps = StepRecorder()

        let agent = try await LaunchProgress.$reporter.withValue({ steps.append($0) }) {
            try await transport.startAgentInNewWorktree(
                Self.agentRequest(), worktree: spec, attempt: WorktreeLaunchAttempt())
        }
        #expect(agent.paneID == "tmux:%2")
        #expect(steps.values == [.usingExistingWorktree, .joiningRunningAgent])
        #expect(host.log.allSatisfy { !$0.hasPrefix("line:new-") })

        let shell = try await transport.startShellTerminalInNewWorktree(
            ShellLaunchRequest(workspaceID: "tmux:$1"), worktree: spec,
            attempt: WorktreeLaunchAttempt())
        #expect(shell.workspaceID == "tmux:$2")
        #expect(shell.paneID == "tmux:%7")
        #expect(host.log.contains("line:" + TmuxCommand.newWindow(
            sessionTarget: "$2", cwd: "/work/wt/feat-x",
            environment: TmuxTransport.windowEnvironment,
            printFormat: TmuxTransport.launchPrintFormat)))
        #expect(await fake.execs(containing: "worktree add").isEmpty)
        try await transport.close()
    }

    /// git refused the add because the typed branch got checked out in a
    /// linked worktree meanwhile: the launch continues there, adopted,
    /// never owned.
    @Test func aRefusedAddOnATypedBranchThatAppearedIsAdopted() async throws {
        let host = WorktreeHostScript.repository()
        host.update {
            $0.add = FakeHostSSHServices.result(
                stderr: "fatal: 'feat/y' is already checked out\n", exitStatus: 128)
        }
        let (transport, fake) = try await Self.open(host)
        let attempt = WorktreeLaunchAttempt()
        let steps = StepRecorder()
        let (entered, release) = await Self.holdAdd(on: fake)
        let launch = Task {
            try await LaunchProgress.$reporter.withValue({ steps.append($0) }) {
                try await transport.startAgentInNewWorktree(
                    Self.agentRequest(), worktree: WorktreeSpec(branch: "feat/y"), attempt: attempt)
            }
        }
        var entry = entered.makeAsyncIterator()
        _ = await entry.next()
        host.update { $0.worktreeList = Self.listing(adding: "/work/wt/feat-y", branch: "feat/y") }
        release.yield(())

        let agent = try await launch.value
        #expect(agent.paneID == "tmux:%9")
        #expect(steps.values == [
            .creatingWorktree, .usingExistingWorktree, .creatingWorkspace, .startingAgent,
        ])
        #expect(attempt.current.createDispatched)
        #expect(attempt.current.worktree == nil)
        #expect(host.log.contains("line:" + TmuxCommand.newSession(
            name: "feat-y", cwd: "/work/wt/feat-y", environment: TmuxTransport.windowEnvironment,
            command: TmuxCommand.loginShellWrapper(agentCommand: "claude"),
            printFormat: TmuxTransport.launchPrintFormat)))
        try await transport.close()
    }

    /// git refused the add and no linked worktree has the branch: git's
    /// answer is the launch's, and nothing else is created.
    @Test func aRefusedAddWithoutTheBranchFailsWithGitsAnswer() async throws {
        let host = WorktreeHostScript.repository()
        host.update {
            $0.add = FakeHostSSHServices.result(
                stderr: "fatal: invalid reference: nope\n", exitStatus: 128)
        }
        let (transport, _) = try await Self.open(host)
        let attempt = WorktreeLaunchAttempt()
        do {
            _ = try await transport.startAgentInNewWorktree(
                Self.agentRequest(), worktree: WorktreeSpec(branch: "feat/y"), attempt: attempt)
            Issue.record("a refused add launched")
        } catch let error as HerdrAPIError {
            #expect(error.code == "worktree_create_failed")
        }
        #expect(attempt.current.createDispatched)
        #expect(attempt.current.worktree == nil)
        #expect(host.log.allSatisfy { !$0.hasPrefix("line:new-") })
        try await transport.close()
    }

    /// An add whose answer is lost is looked for by its exact minted
    /// branch; found, it is this launch's own and the launch continues.
    @Test func anUnansweredAddIsFoundByItsMintedBranch() async throws {
        let host = WorktreeHostScript.repository()
        host.update { $0.add = FakeHostSSHServices.result(stdout: "") }
        let (transport, fake) = try await Self.open(host)
        let attempt = WorktreeLaunchAttempt()
        let steps = StepRecorder()
        let (entered, release) = await Self.holdAdd(on: fake)
        let launch = Task {
            try await LaunchProgress.$reporter.withValue({ steps.append($0) }) {
                try await transport.startAgentInNewWorktree(
                    Self.agentRequest(),
                    worktree: WorktreeSpec(branch: Self.mintedBranch, branchIsGenerated: true),
                    attempt: attempt)
            }
        }
        var entry = entered.makeAsyncIterator()
        _ = await entry.next()
        host.update {
            $0.worktreeList = Self.listing(adding: Self.worktreePath, branch: Self.mintedBranch)
        }
        release.yield(())

        let agent = try await launch.value
        #expect(agent.paneID == "tmux:%9")
        #expect(steps.values == [
            .creatingWorktree, .checkingForCreatedWorktree, .creatingWorkspace, .startingAgent,
        ])
        #expect(attempt.current.worktree?.path == Self.worktreePath)
        #expect(attempt.current.agentStartDispatchedAt != nil)
        #expect(await fake.execs(containing: "worktree add").count == 1)
        try await transport.close()
    }

    /// A launch without a branch has nothing to find a lost add by: it
    /// stops unconfirmed, and never adds again.
    @Test func anUnansweredAddWithoutABranchIsUnconfirmed() async throws {
        let host = WorktreeHostScript.repository()
        host.update { $0.add = FakeHostSSHServices.result(stdout: "") }
        let (transport, fake) = try await Self.open(host)
        let attempt = WorktreeLaunchAttempt()
        let steps = StepRecorder()
        await #expect(throws: WorktreeLaunchError.createUnconfirmed) {
            try await LaunchProgress.$reporter.withValue({ steps.append($0) }) {
                _ = try await transport.startAgentInNewWorktree(
                    Self.agentRequest(), worktree: WorktreeSpec(), attempt: attempt)
            }
        }
        #expect(steps.values == [.creatingWorktree])
        #expect(attempt.current.createDispatched)
        await #expect(throws: WorktreeLaunchError.createUnconfirmed) {
            _ = try await transport.startAgentInNewWorktree(
                Self.agentRequest(), worktree: WorktreeSpec(), attempt: attempt)
        }
        #expect(await fake.execs(containing: "worktree add").count == 1)
        try await transport.close()
    }

    /// tmux refusing the new session after this try's own add removes that
    /// fresh worktree; once a try may have started an Agent there, a later
    /// refusal leaves it.
    @Test func aRefusedSessionRemovesOnlyAWorktreeNoAgentMayUse() async throws {
        let host = WorktreeHostScript.repository()
        host.update {
            $0.add = FakeHostSSHServices.result(
                stdout: "__WAYCAR_WORKTREE__=\(Self.worktreePath)\n")
            $0.newSessionRefusal = "create window failed"
        }
        let (transport, fake) = try await Self.open(host)
        let spec = WorktreeSpec(branch: Self.mintedBranch, branchIsGenerated: true)
        let attempt = WorktreeLaunchAttempt()
        await #expect(throws: HerdrAPIError.self) {
            _ = try await transport.startAgentInNewWorktree(
                Self.agentRequest(), worktree: spec, attempt: attempt)
        }
        let removals = await fake.execs(containing: "worktree remove")
        #expect(removals.count == 1)
        #expect(removals.first?.command.hasSuffix(" sh '\(Self.worktreePath)'") == true)

        await #expect(throws: HerdrAPIError.self) {
            _ = try await transport.startAgentInNewWorktree(
                Self.agentRequest(), worktree: spec, attempt: attempt)
        }
        #expect(await fake.execs(containing: "worktree remove").count == 1)
        #expect(await fake.execs(containing: "worktree add").count == 1)
        try await transport.close()
    }

    // MARK: Removal

    @Test func removalRefusesTheMainCheckoutAndAStaleIdentity() async throws {
        let host = WorktreeHostScript.repository()
        let (transport, fake) = try await Self.open(host)
        let authorized = StepRecorder()

        do {
            _ = try await transport.removeWorktree(
                Self.removal(workspaceID: "tmux:$1", checkoutPath: "/work/proj"),
                authorize: { _ in authorized.append(.opening) }, onDispatched: { _ in })
            Issue.record("removing the main checkout succeeded")
        } catch let error as HerdrAPIError {
            #expect(error.code == "not_linked_worktree")
        }
        await #expect(throws: WorktreeRemovalError.staleIdentity) {
            try await transport.removeWorktree(
                Self.removal(workspaceID: "tmux:$2", checkoutPath: "/work/wt/other"),
                authorize: { _ in authorized.append(.opening) }, onDispatched: { _ in })
        }
        #expect(authorized.values.isEmpty)
        #expect(await fake.execs(containing: "worktree remove").isEmpty)
        try await transport.close()
    }

    @Test func removalAuthorizesRemovesThenKillsTheCheckoutsSessions() async throws {
        let host = WorktreeHostScript.repository(linkedGroup: true)
        let (transport, fake) = try await Self.open(host)
        let removal = Self.removal(workspaceID: "tmux:$2", checkoutPath: "/work/wt/feat-x")

        let removed = try await transport.removeWorktree(
            removal,
            authorize: { request in
                #expect(request == removal)
                host.note("authorize")
            },
            onDispatched: { _ in host.note("dispatched") })
        #expect(removed == WorktreeRemovedResponse(
            forced: false, path: "/work/wt/feat-x", workspaceID: "tmux:$2"))
        #expect(host.log.filter { $0 != "exec:checkouts" } == [
            "authorize", "dispatched", "exec:remove",
            "line:kill-session -t '$2' ; kill-session -t '$4'",
        ])
        #expect(await fake.execs(containing: "worktree remove").first?.command
            .hasSuffix(" sh '/work/wt/feat-x'") == true)
        try await transport.close()
    }

    @Test func dirtyWorktreeNeedsForceAndKeepsItsSessions() async throws {
        let host = WorktreeHostScript.repository()
        host.update {
            $0.remove = FakeHostSSHServices.result(
                stderr: "fatal: '/work/wt/feat-x' contains modified or untracked files, "
                    + "use --force to delete it\n",
                exitStatus: 128)
        }
        let (transport, _) = try await Self.open(host)

        do {
            _ = try await transport.removeWorktree(
                Self.removal(workspaceID: "tmux:$2", checkoutPath: "/work/wt/feat-x"),
                authorize: { _ in }, onDispatched: { _ in host.note("dispatched") })
            Issue.record("a dirty worktree was removed")
        } catch let error as HerdrAPIError {
            #expect(error.code == "dirty_worktree_requires_force")
        }
        #expect(host.log.contains("dispatched"))
        #expect(host.log.allSatisfy { !$0.hasPrefix("line:kill-session") })
        try await transport.close()
    }

    // MARK: Helpers

    static let listMatch = "worktree list --porcelain) || exit"
    static let checkoutMatch = "rev-parse --show-toplevel"

    fileprivate static func open(
        _ host: WorktreeHostScript
    ) async throws -> (TmuxTransport, FakeHostSSHServices) {
        let fake = host.makeFake()
        let transport = try await TmuxTransport.open(
            session: fake, configuration: TmuxTransportTests.configuration())
        return (transport, fake)
    }

    /// Holds the next `git worktree add` until the test yields on the
    /// returned continuation; the stream says when it is held.
    static func holdAdd(
        on fake: FakeHostSSHServices
    ) async -> (entered: AsyncStream<Void>, release: AsyncStream<Void>.Continuation) {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        await fake.holdNextExec(
            containing: "worktree add", entered: entered.continuation, until: release.stream)
        return (entered.stream, release.continuation)
    }

    /// The repository's porcelain with a linked worktree on `branch` added.
    static func listing(adding path: String, branch: String) -> SSHExecResult {
        FakeHostSSHServices.result(stdout: WorktreeHostScript.porcelain + """
            worktree \(path)
            HEAD ffff
            branch refs/heads/\(branch)

            """)
    }

    static func agentRequest(workspaceID: String = "tmux:$1") -> AgentLaunchRequest {
        AgentLaunchRequest(kind: "claude", name: "", workspaceID: workspaceID)
    }

    static func removal(workspaceID: String, checkoutPath: String) -> WorktreeRemovalRequest {
        WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: UUID(), workspaceID: workspaceID,
                checkout: RepositoryCheckout(
                    repoKey: "/work/proj/.git", repoName: "proj", repoRoot: "/work/proj",
                    checkoutPath: checkoutPath, isLinkedWorktree: true)))
    }
}

// MARK: - Scripted repository host

/// A tmux Host whose sessions sit in one repository: `$1` in the main
/// checkout `/work/proj` (a shell), `$2` in the linked worktree
/// `/work/wt/feat-x` (claude). Execs are told apart by their scripts; the
/// interesting ones, the control lines Waycar sends after startup (snapshots
/// aside) and test notes land in `log` in order.
private final class WorktreeHostScript: Sendable {
    struct State {
        var sessions = ["$1 off proj", "$2 off feat-x"]
        var sessionRecords: [String] = []
        var windowRecords: [String] = []
        var paneRecords: [String] = []
        /// The checkout lookup's stdout.
        var checkouts = ""
        var worktreeList = FakeHostSSHServices.result()
        var add = FakeHostSSHServices.result()
        var remove = FakeHostSSHServices.result()
        var baseResolution = FakeHostSSHServices.result()
        /// What `new-session` / `new-window` print.
        var launched = "%9\u{241F}@9\u{241F}$9"
        /// When set, `new-session` fails with this text.
        var newSessionRefusal: String?
        var log: [String] = []
    }

    static let porcelain = """
        worktree /work/proj
        HEAD aaaa
        branch refs/heads/main

        worktree /work/wt/feat-x
        HEAD bbbb
        branch refs/heads/feat/x

        worktree /work/wt/det
        HEAD cccc
        detached

        worktree /work/wt/gone
        HEAD dddd
        branch refs/heads/old
        prunable gitdir file points to non-existent location


        """

    private let state = Mutex(State())

    /// The server's `#{start_time}.#{pid}` the startup line answers.
    static let serverIdentity = "1790979932.4242"

    /// `linkedGroup` groups `$2` with a Waycar attach session `$4`.
    static func repository(linkedGroup: Bool = false) -> WorktreeHostScript {
        let host = WorktreeHostScript()
        host.update {
            $0.sessionRecords = [
                session("$1", "proj", path: "/work/proj"),
                session("$2", "feat-x", path: "/work/wt/feat-x", group: linkedGroup ? "feat-x" : ""),
            ]
            if linkedGroup {
                $0.sessionRecords.append(
                    session("$4", "waycar-0a1b2c3d", path: "/work/wt/feat-x", group: "feat-x"))
            }
            $0.windowRecords = [window("@1", session: "$1"), window("@2", session: "$2")]
            $0.paneRecords = [
                pane("%1", session: "$1", window: "@1", path: "/work/proj"),
                pane("%2", session: "$2", window: "@2", path: "/work/wt/feat-x", agent: "claude"),
            ]
            $0.checkouts = [
                "\u{1E}/work/proj\u{1F}/work/proj\u{1F}/work/proj/.git\u{1F}/work/proj/.git\u{1F}/work/proj",
                "\u{1E}/work/wt/feat-x\u{1F}/work/wt/feat-x\u{1F}/work/proj/.git"
                    + "\u{1F}/work/proj/.git/worktrees/feat-x\u{1F}/work/proj",
            ].joined(separator: "\n") + "\n"
            $0.worktreeList = FakeHostSSHServices.result(stdout: porcelain)
        }
        return host
    }

    static func session(_ id: String, _ name: String, path: String, group: String = "") -> String {
        "\u{241E}" + [id, group.isEmpty ? "0" : "1", "0", name, group, path]
            .joined(separator: "\u{241F}")
    }

    static func window(_ id: String, session: String) -> String {
        "\u{241E}" + [id, session, "1", "1", "0", "main"].joined(separator: "\u{241F}")
    }

    static func pane(
        _ id: String, session: String, window: String, path: String, agent: String = ""
    ) -> String {
        let fields = [
            id, session, window, "0", "1", "0", "0", "100", "/dev/ttys001", "80", "24",
            agent.isEmpty ? "zsh" : "2.1.286", agent.isEmpty ? "" : "idle", agent, "", "", "",
            path, "", "", "host", "", "",
        ]
        return "\u{241E}" + fields.joined(separator: "\u{241F}")
    }

    func update(_ body: (inout State) -> Void) {
        state.withLock { body(&$0) }
    }

    var log: [String] { state.withLock { $0.log } }

    func note(_ entry: String) {
        state.withLock { $0.log.append(entry) }
    }

    func makeFake() -> FakeHostSSHServices {
        FakeHostSSHServices(
            exec: { [self] command, _ in exec(command) },
            control: { [self] line in respond(line) })
    }

    private func exec(_ command: String) -> SSHExecResult {
        let result: SSHExecResult = state.withLock { state in
            if command.contains("exec tmux -V") {
                return FakeHostSSHServices.result(stdout: "tmux 3.7c\n")
            }
            if command.contains("tmux ls -F") {
                return FakeHostSSHServices.result(stdout: state.sessions.map { $0 + "\n" }.joined())
            }
            let rules: [(String, String, SSHExecResult)] = [
                (TmuxWorktreesTests.checkoutMatch, "checkouts",
                 FakeHostSSHServices.result(stdout: state.checkouts)),
                (TmuxWorktreesTests.listMatch, "list", state.worktreeList),
                ("worktree add", "add", state.add),
                ("worktree remove", "remove", state.remove),
                ("ls-remote origin HEAD", "base", state.baseResolution),
            ]
            for (match, name, answer) in rules where command.contains(match) {
                state.log.append("exec:" + name)
                return answer
            }
            return FakeHostSSHServices.result()
        }
        return result
    }

    private func respond(_ line: String) -> [FakeTmuxBlock] {
        let blocks: [FakeTmuxBlock] = state.withLock { state in
            if line.hasPrefix(TmuxTransport.versionFlagsCommand) {
                return [
                    .ok(["3.7c\u{241F}no-output,no-detach-on-destroy\u{241F}1790979932\u{241F}4242"]),
                    .ok([]), .ok([]),
                ]
            }
            if line.hasPrefix("list-sessions") {
                return [.ok(state.sessionRecords), .ok(state.windowRecords), .ok(state.paneRecords)]
            }
            state.log.append("line:" + line)
            if line.hasPrefix("new-session"), let refusal = state.newSessionRefusal {
                return [.error([refusal])]
            }
            if line.hasPrefix("new-session") || line.hasPrefix("new-window") {
                return [.ok([state.launched])]
            }
            return line.components(separatedBy: " ; ").map { _ in .ok([]) }
        }
        return blocks
    }
}

/// Launch steps (or any marker) a `@Sendable` callback reported, in order.
private final class StepRecorder: Sendable {
    private let state = Mutex<[LaunchStep]>([])

    func append(_ step: LaunchStep) {
        state.withLock { $0.append(step) }
    }

    var values: [LaunchStep] { state.withLock { $0 } }
}
