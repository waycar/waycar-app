import Foundation
import SwiftUI
import Synchronization
import Testing
import UIKit

@testable import Waycar

/// New-agent form logic (#12, #97, #230) against scripted discovery and start
/// closures: argument parsing, Host/workspace/Agent selection, param assembly,
/// and outcome mapping — no SSH, no ConsoleStore.
@MainActor
@Suite("Start agent store")
struct StartAgentStoreTests {
    /// Records the starts the store dispatches and scripts their outcome.
    @MainActor
    private final class StartRecorder {
        var params: [AgentLaunchRequest] = []
        var shellParams: [ShellLaunchRequest] = []
        var destinations: [StartAgentStore.LaunchDestination] = []
        /// One entry per start, aligned with `params`; nil is a plain
        /// workspace launch, non-nil the fresh-worktree variant (#97).
        var worktrees: [WorktreeSpec?] {
            destinations.map {
                if case .newWorktree(let spec) = $0 { return spec }
                return nil
            }
        }
        var hostIDs: [Host.ID] = []
        /// The backend each start passed, aligned with `destinations`.
        var backends: [HostBackend?] = []
        var error: (any Error)?
        var agent = Agent(.fixture(paneID: "w1:pnew", status: .working))
        var shellResult = ShellLaunchResult(
            paneID: "w1:p-shell", tabID: "w1:t-shell", terminalID: "term-shell",
            workspaceID: "w1")
        var gate: ScriptedTransportCallGate?
        /// Steps each start reports before `gate`, playing the Transport.
        var reportsBeforeGate: [LaunchStep] = []
        /// Steps each start reports after `gate` opens, before it returns.
        var reportsAfterGate: [LaunchStep] = []

        func record(
            _ params: AgentLaunchRequest,
            _ destination: StartAgentStore.LaunchDestination,
            _ hostID: Host.ID,
            _ backend: HostBackend? = nil
        ) async throws -> Agent {
            self.params.append(params)
            destinations.append(destination)
            hostIDs.append(hostID)
            backends.append(backend)
            reportsBeforeGate.forEach(LaunchProgress.report)
            await gate?.waitUntilOpen()
            reportsAfterGate.forEach(LaunchProgress.report)
            if let error { throw error }
            return agent
        }

        func recordShell(
            _ params: ShellLaunchRequest,
            _ destination: StartAgentStore.LaunchDestination,
            _ hostID: Host.ID,
            _ backend: HostBackend? = nil
        ) async throws -> ShellLaunchResult {
            shellParams.append(params)
            destinations.append(destination)
            hostIDs.append(hostID)
            backends.append(backend)
            reportsBeforeGate.forEach(LaunchProgress.report)
            await gate?.waitUntilOpen()
            reportsAfterGate.forEach(LaunchProgress.report)
            if let error { throw error }
            return shellResult
        }
    }

    /// The first messages the store hands to an Agent's Composer queue.
    @MainActor
    private final class LaunchMessageRecorder {
        struct Queued: Equatable {
            let text: String
            let agent: QueuedMessage.AgentIdentity
            let hostID: Host.ID
        }

        private(set) var messages: [Queued] = []

        func record(_ text: String, _ agent: QueuedMessage.AgentIdentity, _ hostID: Host.ID) {
            messages.append(Queued(text: text, agent: agent, hostID: hostID))
        }
    }

    /// Mints the store's generated branches from a seeded generator and
    /// keeps them in order, so a test can name the branch each launch got.
    @MainActor
    private final class BranchMinter {
        private var generator = SeededRandomNumberGenerator(seed: 97)
        private(set) var minted: [String] = []

        func mint() -> String {
            let branch = GeneratedWorktreeBranch.mint(using: &generator)
            minted.append(branch)
            return branch
        }

        /// The spec a launch carries with the `index`th minted branch.
        func spec(_ index: Int = 0, base: WorktreeBase) -> WorktreeSpec {
            WorktreeSpec(
                branch: minted.indices.contains(index) ? minted[index] : nil,
                base: base, branchIsGenerated: true)
        }
    }

    /// A throwaway defaults domain per test, so the remembered-workspace
    /// persistence is real but isolated.
    private func makeRecents() -> RecentWorkspaceStore {
        let name = "recent-workspace-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return RecentWorkspaceStore(defaults: defaults)
    }

    /// A throwaway defaults domain per test, so the remembered Host and Agent
    /// kind persistence is real but isolated.
    private func makeSelections() -> RecentSelectionsStore {
        let name = "recent-selections-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return RecentSelectionsStore(defaults: defaults)
    }

    private func makeStore(
        hosts: [Host],
        workspaces: @escaping (Host.ID) -> [ConsoleWorkspace] = { _ in [] },
        existingAgentNames: @escaping (Host.ID) -> Set<String> = { _ in [] },
        agentKinds: @escaping (Host.ID) async throws -> [SupportedAgentKind] = { _ in
            [.claude]
        },
        cachedAgentKinds: @escaping (Host.ID) -> CachedAgentKinds? = { _ in nil },
        remoteHome: @escaping (Host.ID) async throws -> String = { _ in "/home/you" },
        awaitAgentVisible: @escaping (ConsoleAgent.ID) async -> Void = { _ in },
        origin: StartAgentStore.LaunchOrigin? = nil,
        recents: RecentWorkspaceStore? = nil,
        selections: RecentSelectionsStore? = nil,
        reviewPrompt: ReviewPromptStore? = nil,
        backends: @escaping (Host.ID) -> [HostBackend] = { _ in [.herdr] },
        defaultBackend: @escaping (Host.ID) -> HostBackend = { _ in .herdr },
        minter: BranchMinter = BranchMinter(),
        recorder: StartRecorder,
        preset: AgentLaunchPreset? = nil,
        quickChat: NewChatPreferences? = nil,
        promptHost: FakeLaunchPromptHost = FakeLaunchPromptHost(),
        launchMessages: LaunchMessageRecorder = LaunchMessageRecorder(),
        backendPresence: @escaping (Host.ID) -> HostBackendPresence? = { _ in nil },
        launchQueue: StartAgentStore.LaunchQueue? = nil,
        hasLiveSnapshot: @escaping (Host.ID) -> Bool = { _ in true },
        foundDiscoveryRetryDelay: Duration = .zero
    ) -> StartAgentStore {
        StartAgentStore(
            hosts: hosts, workspaces: workspaces,
            existingAgentNames: existingAgentNames,
            discoverAgentKinds: agentKinds,
            cachedAgentKinds: cachedAgentKinds,
            remoteHome: remoteHome,
            start: { params, destination, hostID, backend in
                try await recorder.record(params, destination, hostID, backend)
            },
            startShell: { params, destination, hostID, backend in
                try await recorder.recordShell(params, destination, hostID, backend)
            },
            backends: backends,
            defaultBackend: defaultBackend,
            awaitAgentVisible: awaitAgentVisible,
            origin: origin,
            reviewPrompt: reviewPrompt,
            recents: recents ?? makeRecents(),
            selections: selections ?? makeSelections(),
            mintWorktreeBranch: { minter.mint() },
            launchPromptHost: { _ in promptHost.host },
            queueLaunchMessage: { launchMessages.record($0, $1, $2) },
            launchQueue: launchQueue,
            quickChat: quickChat,
            preset: preset,
            hasLiveSnapshot: hasLiveSnapshot,
            backendPresence: backendPresence,
            foundDiscoveryRetryDelay: foundDiscoveryRetryDelay)
    }

    /// The `.started` state a default-recorder agent submit lands in: the
    /// recorder's fixture pane on the submitting Host.
    private func started(on host: Host, paneID: String = "w1:pnew") -> StartAgentStore.State {
        .started(ConsoleAgent.ID(hostID: host.id, paneID: paneID))
    }

    /// The `.started` state a default-recorder shell submit lands in: the
    /// recorder's fixture shell pane on the submitting Host — a row identity
    /// exactly like an Agent's.
    private func shellStarted(on host: Host, paneID: String = "w1:p-shell")
        -> StartAgentStore.State
    {
        .started(ConsoleAgent.ID(hostID: host.id, paneID: paneID))
    }

    @Test func aDiscoveryThatClearsTheKindDuringHomeLookupLeavesTheFormEditable() async throws {
        let host = Host.fixture()
        let gate = ScriptedTransportCallGate()
        let kinds = LiveKinds()
        kinds.kinds = [.claude]
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host], agentKinds: { _ in kinds.kinds },
            remoteHome: { _ in
                await gate.waitUntilOpen()
                return "/home/you"
            }, recorder: recorder, preset: Self.preset())
        await store.discoverAgents()
        store.launchTarget = .newWorkspace
        store.name = "project"
        store.newWorkspaceDirectory = ""
        #expect(store.canSubmit)
        let submit = Task { await store.submit() }
        await gate.waitForEntry()
        kinds.kinds = []
        await store.discoverAgents()
        #expect(store.selectedAgentKind == nil)
        await gate.open()
        await submit.value
        #expect(store.state == .editing)
        #expect(recorder.params.isEmpty)
    }

    private struct PreparationImage: ImageSelection {
        let gate: ScriptedTransportCallGate
        let data: Data

        func loadData() async throws -> Data {
            await gate.waitUntilOpen()
            return data
        }
    }

    @Test(arguments: [true, false])
    func attachmentPreparationKeepsTheSubmittingHostsWorkspace(live: Bool) async throws {
        let first = Host.fixture()
        let second = Host.fixture()
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = QueuedLaunchStore(directory: directory)
        let recorder = StartRecorder()
        let gate = ScriptedTransportCallGate()
        let store = makeStore(
            hosts: [first, second], workspaces: { hostID in
                [.init(id: hostID == first.id ? "first-workspace" : "second-workspace", label: "Project")]
            }, recorder: recorder,
            launchQueue: .init(store: saved, enqueue: { try saved.save($0) }),
            hasLiveSnapshot: { _ in live })
        store.selectedHostID = first.id
        await store.discoverAgents()
        let data = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).jpegData(
            withCompressionQuality: 1) { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
        #expect(store.addFirstMessageAttachments([.photo(PreparationImage(gate: gate, data: data))]) == 1)
        let submit = Task { await store.submit() }
        await gate.waitForEntry()
        // A duplicate submit must not dispatch while preparation suspends.
        await store.submit()
        store.selectedHostID = second.id
        await store.discoverAgents()
        #expect(store.selectedWorkspaceID == "second-workspace")
        await gate.open()
        await submit.value
        if live {
            #expect(recorder.hostIDs == [first.id])
            #expect(recorder.params.map(\.workspaceID) == ["first-workspace"])
        } else {
            let launch = try #require(saved.launches(on: first.id).first)
            #expect(launch.draft.workspaceID == "first-workspace")
            #expect(saved.launches(on: second.id).isEmpty)
            #expect(recorder.params.isEmpty)
        }
        store.discardFirstMessageAttachments()
    }

    // MARK: Cached Agent kinds

    /// What the live detection answers, settable between rounds.
    @MainActor
    private final class LiveKinds {
        var kinds: [SupportedAgentKind] = []
    }

    /// The Host's last detected kinds load before it answers, so Start works
    /// with no connection; the live answer replaces them, keeping the pick
    /// while it is still offered and preselecting again once it is not.
    @Test func cachedAgentKindsLoadFirstAndTheLiveAnswerReplacesThem() async throws {
        let host = Host.fixture()
        let seenAt = Date(timeIntervalSince1970: 1_800_000_000)
        let detection = ScriptedTransportCallGate()
        let live = LiveKinds()
        live.kinds = [.codex, .claude]
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in
                await detection.waitUntilOpen()
                return live.kinds
            },
            cachedAgentKinds: { _ in CachedAgentKinds(kinds: [.claude, .omp], verifiedAt: seenAt) },
            recorder: StartRecorder())

        let discovery = Task { await store.discoverAgents() }
        await detection.waitForEntry()
        #expect(store.agentDiscoveryState == .loaded)
        #expect(store.availableAgentKinds == [.claude, .omp])
        #expect(store.selectedAgentKind == .claude)
        #expect(store.agentKindsAreCached)
        #expect(store.agentKindsSeenAt == seenAt)
        #expect(store.canSubmit)

        await detection.open()
        await discovery.value
        #expect(store.availableAgentKinds == [.codex, .claude])
        #expect(store.selectedAgentKind == .claude, "the pick is still offered")
        #expect(!store.agentKindsAreCached)
        #expect(store.agentKindsSeenAt == nil)

        // A live answer without the pick preselects as a first detection does.
        live.kinds = [.codex]
        await store.discoverAgents()
        #expect(store.availableAgentKinds == [.codex])
        #expect(store.selectedAgentKind == .codex)
        #expect(store.agentDiscoveryState == .loaded)
    }

    @Test func anOlderDiscoveryFailureCannotReplaceANewerSuccess() async {
        let gate = ScriptedTransportCallGate()
        let attempts = LiveKinds()
        let store = makeStore(
            hosts: [.fixture()], agentKinds: { _ in
                if attempts.kinds.isEmpty {
                    attempts.kinds = [.codex]
                    await gate.waitUntilOpen()
                    throw TransportError.timedOut
                }
                return attempts.kinds
            }, recorder: StartRecorder())
        let older = Task { await store.discoverAgents() }
        await gate.waitForEntry()
        await store.discoverAgents()
        #expect(store.agentDiscoveryState == .loaded)
        await gate.open()
        await older.value
        #expect(store.agentDiscoveryState == .loaded)
        #expect(store.availableAgentKinds == [.codex])
        #expect(store.selectedAgentKind == .codex)
    }

    /// A Host out of reach keeps its cached kinds loaded, and Start usable,
    /// instead of failing detection.
    @Test func cachedAgentKindsStayLoadedWhenTheHostCannotBeAsked() async {
        let seenAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = makeStore(
            hosts: [Host.fixture()],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in throw TransportError.sshUnreachable(detail: "down") },
            cachedAgentKinds: { _ in CachedAgentKinds(kinds: [.codex], verifiedAt: seenAt) },
            recorder: StartRecorder())

        await store.discoverAgents()

        #expect(store.agentDiscoveryState == .loaded)
        #expect(store.availableAgentKinds == [.codex])
        #expect(store.selectedAgentKind == .codex)
        #expect(store.agentKindsAreCached)
        #expect(store.agentKindsSeenAt == seenAt)
        #expect(store.canSubmit)
    }

    @Test func aDiscoveryForThePreviousHostCannotPublishAfterSwitchingBack() async {
        let first = Host.fixture()
        let second = Host.fixture()
        let gate = ScriptedTransportCallGate()
        let calls = CallCounter()
        let store = makeStore(
            hosts: [first, second], agentKinds: { _ in
                if calls.next() == 1 {
                    await gate.waitUntilOpen()
                    return [.claude]
                }
                return [.codex]
            }, recorder: StartRecorder())
        store.selectedHostID = first.id
        let old = Task { await store.discoverAgents() }
        await gate.waitForEntry()
        store.selectedHostID = second.id
        store.selectedHostID = first.id
        await store.discoverAgents()
        await gate.open()
        await old.value
        #expect(store.availableAgentKinds == [.codex])
        #expect(store.selectedAgentKind == .codex)
    }

    @Test func switchingBackWithoutANewDiscoveryStillAcceptsThatHostsAnswer() async {
        let first = Host.fixture()
        let second = Host.fixture()
        let gate = ScriptedTransportCallGate()
        let store = makeStore(hosts: [first, second], agentKinds: { _ in
            await gate.waitUntilOpen()
            return [.claude]
        }, recorder: StartRecorder())
        store.selectedHostID = first.id
        let discovery = Task { await store.discoverAgents() }
        await gate.waitForEntry()
        store.selectedHostID = second.id
        store.selectedHostID = first.id
        await gate.open()
        await discovery.value
        #expect(store.agentDiscoveryState == .loaded)
        #expect(store.selectedAgentKind == .claude)
    }

    @Test func cachedKindsStayUsableWhenDiscoveryIsCancelled() async {
        let seen = Date(timeIntervalSince1970: 1)
        let store = makeStore(
            hosts: [.fixture()], agentKinds: { _ in throw CancellationError() },
            cachedAgentKinds: { _ in .init(kinds: [.omp], verifiedAt: seen) },
            recorder: StartRecorder())
        await store.discoverAgents()
        #expect(store.agentDiscoveryState == .loaded)
        #expect(store.availableAgentKinds == [.omp])
        #expect(store.agentKindsAreCached && store.agentKindsSeenAt == seen)
    }

    @Test func browsingSelectsANewWorkspaceAndClearsWorktreeDraft() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Existing")] },
            recorder: recorder)
        await store.discoverAgents()
        store.startsInNewWorktree = true
        store.worktreeBranch = "feature"
        store.applyBrowsedDirectory("/home/you/new-project")

        #expect(store.launchTarget == .newWorkspace)
        #expect(!store.startsInNewWorktree)
        #expect(store.worktreeBranch.isEmpty)
        #expect(recorder.destinations.isEmpty)
        await store.submit()
        #expect(recorder.destinations == [
            .newWorkspace(NewWorkspaceSpec(directory: "/home/you/new-project", label: nil))
        ])
    }

    @Test func selectingAnExistingWorkspaceReplacesTheBrowsedDestination() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Existing")] },
            recorder: recorder)
        await store.discoverAgents()
        store.applyBrowsedDirectory("/home/you/new-project")
        store.selectExistingWorkspace("w1")
        #expect(store.launchTarget == .existingWorkspace)
        #expect(store.selectedWorkspaceID == "w1")
        await store.submit()
        #expect(recorder.destinations == [.existingWorkspace])
        #expect(recorder.params.first?.workspaceID == "w1")
    }

    @Test func latestDirectoryRemainsSelectableAfterChoosingAnExistingWorkspace() async {
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [Host.fixture()],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Existing")] },
            recorder: recorder)
        await store.discoverAgents()
        store.applyBrowsedDirectory("/home/you/old-project")
        store.applyBrowsedDirectory("/home/you/latest-project")
        store.selectExistingWorkspace("w1")
        #expect(store.newWorkspaceDirectory == "/home/you/latest-project")
        store.selectNewWorkspace()
        #expect(store.launchTarget == .newWorkspace)
        #expect(recorder.destinations.isEmpty)
        await store.submit()
        #expect(recorder.destinations == [
            .newWorkspace(NewWorkspaceSpec(directory: "/home/you/latest-project", label: nil))
        ])
    }

    @Test func switchingHostsDropsTheLatestDirectoryOption() {
        let hosts = [Host.fixture(), Host.fixture()]
        let store = makeStore(hosts: hosts, recorder: StartRecorder())
        store.applyBrowsedDirectory("/home/you/project")
        store.selectedHostID = hosts[1].id
        #expect(store.newWorkspaceDirectory.isEmpty)
        // The stale directory is dropped, but a name-only New Workspace needs
        // no directory: switching targets still works.
        store.selectNewWorkspace()
        #expect(store.launchTarget == .newWorkspace)
    }

    @Test func nameOnlyNewWorkspaceFallsBackToHomeDirectory() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(hosts: [host], recorder: recorder)
        await store.discoverAgents()
        store.selectNewWorkspace()
        store.newWorkspaceLabel = "Fresh"
        #expect(store.canSubmit)
        await store.submit()
        #expect(recorder.destinations == [
            .newWorkspace(NewWorkspaceSpec(directory: "/home/you", label: "Fresh"))
        ])
    }

    @Test func nameOnlyNewWorkspaceReportsWhenHomeCannotBeResolved() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        struct ProbeFailed: Error {}
        let store = makeStore(
            hosts: [host],
            remoteHome: { _ in throw ProbeFailed() },
            recorder: recorder)
        await store.discoverAgents()
        store.selectNewWorkspace()
        await store.submit()
        #expect(recorder.destinations.isEmpty)
        guard case .failed = store.state else {
            #expect(false, "expected a failed state, got \(store.state)")
            return
        }
    }

    @Test func invalidDirectoryAndStaleWorkspaceDoNotReplaceTheSelection() {
        let store = makeStore(
            hosts: [Host.fixture()],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Existing")] },
            recorder: StartRecorder())
        store.applyBrowsedDirectory("relative/path")
        #expect(store.launchTarget == .existingWorkspace)
        #expect(store.newWorkspaceDirectory.isEmpty)
        store.applyBrowsedDirectory("/home/you/new-project")
        store.selectExistingWorkspace("gone")
        #expect(store.launchTarget == .newWorkspace)
    }

    @Test func argumentParserSupportsQuotesEscapesAndEmptyArguments() throws {
        #expect(
            StartAgentStore.parseArguments(
                #" --model "gpt 5" 'literal value' escaped\ value "" prefix" suffix" "#)
                == .success([
                    "--model", "gpt 5", "literal value", "escaped value", "", "prefix suffix",
                ]))
        #expect(try StartAgentStore.parseArguments("   \n ").get() == [])
    }

    @Test func smartPunctuationNormalizesBackToASCII() {
        // The iOS keyboard rewrites "--" to an em dash and quotes to curly
        // variants even with autocorrection disabled. The editor prevents the
        // rewrite, and parsing remains defensive for pasted text.
        #expect(StartAgentStore.normalizeSmartPunctuation("\u{2014}yolo") == "--yolo")
        #expect(StartAgentStore.normalizeSmartPunctuation("\u{2013}v") == "-v")
        #expect(
            StartAgentStore.normalizeSmartPunctuation(
                "--label \u{201C}code review\u{201D} \u{2018}x\u{2019}")
                == #"--label "code review" 'x'"#)
        #expect(StartAgentStore.normalizeSmartPunctuation("--plain 'ascii'") == "--plain 'ascii'")
    }

    @Test func editingArgumentsDefersSmartPunctuationNormalizationUntilParsing() {
        let store = makeStore(hosts: [.fixture()], recorder: StartRecorder())
        store.arguments = "\u{2014}yolo --label \u{201C}code review\u{201D}"

        #expect(store.arguments == "\u{2014}yolo --label \u{201C}code review\u{201D}")
        #expect(store.parsedArguments == .success(["--yolo", "--label", "code review"]))
    }

    @Test func argumentEditorDisablesEverySmartPunctuationTrait() {
        let textView = UITextView()

        AgentArgumentsTextView.configure(textView)

        #expect(textView.autocapitalizationType == .none)
        #expect(textView.autocorrectionType == .no)
        #expect(textView.spellCheckingType == .no)
        #expect(textView.smartDashesType == .no)
        #expect(textView.smartQuotesType == .no)
        #expect(textView.smartInsertDeleteType == .no)
    }

    @Test func argumentEditorAtomicallyRejectsASmartDashReplacement() {
        let recorder = TextBindingRecorder()
        let coordinator = AgentArgumentsTextView.Coordinator(text: recorder.binding)
        let textView = UITextView()
        textView.text = "--"

        let accepted = coordinator.textView(
            textView, shouldChangeTextIn: NSRange(location: 0, length: 2),
            replacementText: "\u{2014}")

        #expect(!accepted)
        #expect(textView.text == "--")
        #expect(recorder.value == "--")
        #expect(textView.selectedRange == NSRange(location: 2, length: 0))
    }

    @Test func argumentParserReportsIncompleteAndUnsafeInput() {
        #expect(StartAgentStore.parseArguments(#""unfinished"#) == .failure(.unclosedDoubleQuote))
        #expect(StartAgentStore.parseArguments("'unfinished") == .failure(.unclosedSingleQuote))
        #expect(StartAgentStore.parseArguments(#"--flag\"#) == .failure(.danglingEscape))
        #expect(StartAgentStore.parseArguments("\"line\nbreak\"") == .failure(.controlCharacter))
    }

    @MainActor
    private final class TextBindingRecorder {
        var value = ""

        var binding: Binding<String> {
            Binding(
                get: { self.value },
                set: { self.value = $0 })
        }
    }

    @Test func supportedAgentCatalogListsKnownKinds() {
        #expect(SupportedAgentKind.allCases.map(\.rawValue) == [
            "pi", "claude", "codex", "gemini", "cursor", "devin", "agy",
            "cline", "omp", "mastracode", "opencode", "copilot", "kimi",
            "kiro", "droid", "amp", "grok", "hermes", "kilo", "qodercli",
            "maki", "muse", "qwen",
        ])
        #expect(SupportedAgentKind.muse.rawValue == "muse")
        #expect(SupportedAgentKind.muse.displayName == "Muse")
        #expect(SupportedAgentKind.muse.executable == "muse")
        #expect(SupportedAgentKind.qwen.rawValue == "qwen")
        #expect(SupportedAgentKind.qwen.displayName == "Qwen Code")
        #expect(SupportedAgentKind.qwen.executable == "qwen")
        #expect(SupportedAgentKind.cursor.executable == "cursor-agent")
        #expect(SupportedAgentKind.kiro.executable == "kiro-cli")
        #expect(
            SupportedAgentKind.allCases
                .filter { $0 != .cursor && $0 != .kiro }
                .allSatisfy { $0.executable == $0.rawValue })
    }

    @Test func agentDiscoveryCommandPrintsMuseWhenOnPath() {
        let command = SSHTransportSettings.defaultAgentDiscoveryCommand
        #expect(
            command.contains(
                "command -v muse >/dev/null 2>&1"
                    + " && printf \"__WAYCAR_AGENT_KIND__=%s\\n\" \"muse\""))
    }

    @Test func agentDiscoveryParsesMuseInStableOrderAndDropsUnknownKinds() {
        let output = """
            Welcome to the Host
            gemini
            __WAYCAR_AGENT_KIND__=qwen
            __WAYCAR_AGENT_KIND__=muse
            __WAYCAR_AGENT_KIND__=notarealagent
            __WAYCAR_AGENT_KIND__=muse
            last login: never
            """
        #expect(SSHTransportSettings.discoveredAgentKinds(from: output) == [.muse, .qwen])
    }

    @Test func preSelectsTheOnlyHost() {
        let host = Host.fixture()
        let single = makeStore(hosts: [host], recorder: StartRecorder())
        #expect(single.selectedHostID == host.id)

        let many = makeStore(
            hosts: [host, .fixture(address: "b.example")], recorder: StartRecorder())
        #expect(many.selectedHostID == nil)
    }

    @Test func discoveryPublishesHostKindsAndSelectsTheFirst() async {
        let host = Host.fixture()
        let store = makeStore(
            hosts: [host],
            agentKinds: { requestedHost in
                #expect(requestedHost == host.id)
                return [.codex, .claude]
            },
            recorder: StartRecorder())

        await store.discoverAgents()

        #expect(store.agentDiscoveryState == .loaded)
        #expect(store.availableAgentKinds == [.codex, .claude])
        #expect(store.selectedAgentKind == .codex)
    }

    @Test func discoverySurfacesFailureAndSupportsAnEmptyResult() async {
        let host = Host.fixture()
        let failing = makeStore(
            hosts: [host],
            agentKinds: { _ in throw TransportError.timedOut },
            recorder: StartRecorder())

        await failing.discoverAgents()
        #expect(failing.agentDiscoveryState == .failed("Agent detection timed out."))
        #expect(failing.availableAgentKinds.isEmpty)

        let empty = makeStore(
            hosts: [host], agentKinds: { _ in [] }, recorder: StartRecorder())
        await empty.discoverAgents()
        #expect(empty.agentDiscoveryState == .loaded)
        #expect(empty.availableAgentKinds.isEmpty)
        #expect(empty.selectedAgentKind == nil)
        // With no Agent found, Default Shell is preselected so Start works.
        #expect(empty.selectedLaunchIsShell)
        #expect(empty.shellAutoSelectedForEmptyDetection)
    }

    @Test func emptyDetectionFallbackYieldsToAFoundAgentButNotForAUserPick() async {
        let host = Host.fixture()
        let kinds = Mutex<[SupportedAgentKind]>([])
        let store = makeStore(
            hosts: [host], agentKinds: { _ in kinds.withLock { $0 } },
            recorder: StartRecorder())

        await store.discoverAgents()
        #expect(store.selectedLaunchIsShell)
        #expect(store.shellAutoSelectedForEmptyDetection)

        // Detect Again finds an Agent: the automatic fallback yields to it.
        kinds.withLock { $0 = [.claude] }
        await store.discoverAgents()
        #expect(!store.selectedLaunchIsShell)
        #expect(!store.shellAutoSelectedForEmptyDetection)
        #expect(store.selectedAgentKind == .claude)

        // The user's own Shell pick is explicit and sticks across detection.
        store.selectedLaunchIsShell = true
        #expect(!store.shellAutoSelectedForEmptyDetection)
        await store.discoverAgents()
        #expect(store.selectedLaunchIsShell)

        // An empty detection over that explicit pick does not demote it to
        // the automatic fallback, so a later find cannot replace it.
        kinds.withLock { $0 = [] }
        await store.discoverAgents()
        #expect(store.selectedLaunchIsShell)
        #expect(!store.shellAutoSelectedForEmptyDetection)
        kinds.withLock { $0 = [.claude] }
        await store.discoverAgents()
        #expect(store.selectedLaunchIsShell)
    }

    @Test func detectionFailureAfterEmptyFallbackStillReadsAsAFailure() async {
        let host = Host.fixture()
        let failure = Mutex<TransportError?>(nil)
        let store = makeStore(
            hosts: [host],
            agentKinds: { _ in
                if let failure = failure.withLock({ $0 }) { throw failure }
                return []
            },
            recorder: StartRecorder())

        await store.discoverAgents()
        #expect(store.selectedLaunchIsShell)

        // Detect Again fails: the error must surface despite the fallback.
        failure.withLock { $0 = .timedOut }
        await store.discoverAgents()
        #expect(store.agentDiscoveryState == .failed("Agent detection timed out."))
        #expect(store.shellAutoSelectedForEmptyDetection)
    }

    @Test func staleDiscoveryCannotOverwriteANewHostSelection() async throws {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let gate = ScriptedTransportCallGate()
        let store = makeStore(
            hosts: [hostA, hostB],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { hostID in
                if hostID == hostA.id {
                    await gate.waitUntilOpen()
                    return [.claude]
                }
                return [.codex]
            },
            recorder: StartRecorder())

        store.selectedHostID = hostA.id
        let stale = Task { await store.discoverAgents() }
        try await waitUntil("the first Host discovery should reach the gate") {
            await gate.entryCount == 1
        }

        store.selectedHostID = hostB.id
        await store.discoverAgents()
        #expect(store.availableAgentKinds == [.codex])
        #expect(store.selectedAgentKind == .codex)

        await gate.open()
        await stale.value
        #expect(store.availableAgentKinds == [.codex])
        #expect(store.selectedAgentKind == .codex)
    }

    @Test func canSubmitRequiresAHostWorkspaceAndDetectedAgent() async {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let store = makeStore(
            hosts: [hostA, hostB],
            workspaces: {
                $0 == hostA.id ? [ConsoleWorkspace(id: "w1", label: "Proj")] : []
            },
            recorder: StartRecorder())

        #expect(store.canSubmit == false)
        store.selectedHostID = hostA.id
        #expect(store.canSubmit == false)  // Agent discovery has not completed
        await store.discoverAgents()
        #expect(store.canSubmit == true)  // the name is optional
        store.name = "1reviewer"
        #expect(store.canSubmit == false)  // a leading digit violates herdr's rule
        store.name = "reviewer"
        #expect(store.canSubmit == true)
        store.arguments = #""unfinished"#
        #expect(store.canSubmit == false)
    }

    @Test func anEmptyNameFallsBackToTheKindSkippingTakenNames() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            existingAgentNames: { _ in ["claude", "claude-2"] },
            recorder: recorder)
        await store.discoverAgents()
        #expect(store.defaultAgentName == "claude-3")

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.params.map(\.name) == ["claude-3"])
    }

    @Test func aFreshKindNeedsNoSuffix() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            existingAgentNames: { _ in ["reviewer"] },
            recorder: recorder)
        await store.discoverAgents()
        store.name = "   "

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.params.map(\.name) == ["claude"])
    }

    @Test func anInvalidNameBlocksSubmission() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        await store.discoverAgents()
        store.name = "2nd Agent"

        #expect(store.nameErrorMessage != nil)
        #expect(store.canSubmit == false)
        await store.submit()
        #expect(store.state == .editing)
        #expect(recorder.params.isEmpty)
    }

    @Test func agentNameInputIsRewrittenTowardHerdrsRule() async {
        let store = makeStore(
            hosts: [Host.fixture()],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: StartRecorder())
        await store.discoverAgents()

        store.name = "My Agent"
        #expect(store.name == "my-agent")
        #expect(store.canSubmit == true)

        // A shell tab label is free-form until the launch becomes an Agent.
        store.launchSelection.wrappedValue = .shell
        store.name = "Ops Box"
        #expect(store.name == "Ops Box")
        store.launchSelection.wrappedValue = .agent(.claude)
        #expect(store.name == "ops-box")
    }

    @Test func aSpaceShowsAsAHyphenAndATrailingOneIsNotSubmitted() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        await store.discoverAgents()

        store.name = "my "
        #expect(store.name == "my-")
        store.name = "my- "
        #expect(store.name == "my-")
        #expect(store.canSubmit == true)

        await store.submit()

        #expect(recorder.params.map(\.name) == ["my"])
    }

    @Test func worktreeBranchMirrorsIntoTheNameUntilTheNameDiverges() async {
        let store = makeStore(
            hosts: [Host.fixture()],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: StartRecorder())
        await store.discoverAgents()
        store.startsInNewWorktree = true

        store.worktreeBranch = "Fix Login"
        #expect(store.worktreeBranch == "Fix-Login")
        #expect(store.name == "fix-login")
        store.worktreeBranch = "feat/Fix Login"
        #expect(store.name == "feat-fix-login")

        store.name = "reviewer"
        store.worktreeBranch = "feat/other"
        #expect(store.name == "reviewer")

        // Clearing the name hands it back to the branch.
        store.name = ""
        store.worktreeBranch = "feat/again"
        #expect(store.name == "feat-again")
    }

    @Test func aMirroredShellLabelFollowsTheSwitchToAnAgent() async {
        let store = makeStore(
            hosts: [Host.fixture()],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: StartRecorder())
        await store.discoverAgents()
        store.launchSelection.wrappedValue = .shell
        store.startsInNewWorktree = true

        store.worktreeBranch = "Feat/X"
        #expect(store.name == "Feat/X")  // a tab label takes the branch verbatim

        store.launchSelection.wrappedValue = .agent(.claude)
        #expect(store.name == "feat-x")
        store.worktreeBranch = "Feat/Y"
        #expect(store.name == "feat-y")
    }

    @Test func aMirroredAgentNameStartsWithALetter() async {
        let store = makeStore(
            hosts: [Host.fixture()],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: StartRecorder())
        await store.discoverAgents()
        store.startsInNewWorktree = true

        store.worktreeBranch = "97-fix"

        #expect(store.worktreeBranch == "97-fix")
        #expect(store.name == "fix")
        #expect(store.canSubmit == true)
    }

    @Test func switchingHostClearsAMirroredNameAndMirroringResumes() async {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let store = makeStore(
            hosts: [hostA, hostB],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: StartRecorder())
        store.selectedHostID = hostA.id
        await store.discoverAgents()
        store.startsInNewWorktree = true
        store.worktreeBranch = "task/fix"
        #expect(store.name == "task-fix")

        store.selectedHostID = hostB.id
        await store.discoverAgents()
        #expect(store.name.isEmpty)

        store.startsInNewWorktree = true
        store.worktreeBranch = "task/other"
        #expect(store.name == "task-other")
    }

    @Test func aShellTabLabelSurvivesAHostSwitchWhenShellIsRemembered() async {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let selections = makeSelections()
        selections.rememberShell(hostID: hostA.id)
        let store = makeStore(
            hosts: [hostA, hostB],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            selections: selections,
            recorder: StartRecorder())
        #expect(store.selectedHostID == hostA.id)
        await store.discoverAgents()
        #expect(store.selectedLaunchIsShell)
        store.name = "Ops Box"

        // The switch clears the shell pick until discovery restores it; the
        // label must not be rewritten under the agent-name rule meanwhile.
        store.selectedHostID = hostB.id
        #expect(store.name == "Ops Box")
        await store.discoverAgents()

        #expect(store.selectedLaunchIsShell)
        #expect(store.name == "Ops Box")
    }

    /// A typed branch goes out as typed, never minted and never marked
    /// generated, so a worktree found on it is adopted, not the launch's own.
    @Test func aBranchWithATrailingSpaceSubmitsTrimmed() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let minter = BranchMinter()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            minter: minter, recorder: recorder)
        await store.discoverAgents()
        store.startsInNewWorktree = true

        store.worktreeBranch = "task/fix "
        #expect(store.worktreeBranch == "task/fix-")
        #expect(store.name == "task-fix-")
        #expect(store.canSubmit == true)

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.params.map(\.name) == ["task-fix"])
        #expect(
            recorder.worktrees == [WorktreeSpec(branch: "task/fix", base: .latestDefaultBranch)])
        #expect(minter.minted.isEmpty)
    }

    @Test func aHyphenAfterASlashIsKeptSoTheBranchStaysValid() async {
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [Host.fixture()],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.name = "reviewer"
        await store.discoverAgents()
        store.startsInNewWorktree = true

        store.worktreeBranch = "feat/ "
        #expect(store.worktreeBranch == "feat/-")
        #expect(store.worktreeBranchErrorMessage == nil)

        await store.submit()

        #expect(
            recorder.worktrees == [WorktreeSpec(branch: "feat/-", base: .latestDefaultBranch)])
    }

    @Test func cannotSubmitUntilTheHostReportsAWorkspace() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(hosts: [host], recorder: recorder)
        store.name = "reviewer"
        await store.discoverAgents()

        #expect(store.launchTarget == .existingWorkspace)
        #expect(store.canSubmit == false)
        await store.submit()
        #expect(store.state == .editing)
        #expect(recorder.params.isEmpty)
    }

    @Test func newWorkspaceCanSubmitWithZeroReportedWorkspaces() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(hosts: [host], recorder: recorder)
        await store.discoverAgents()

        #expect(store.canSubmit == false)
        store.launchTarget = .newWorkspace
        // Name-only launches are complete without a directory: submit falls
        // back to the Host's home directory.
        #expect(store.canSubmit == true)
        store.newWorkspaceDirectory = "   "
        #expect(store.canSubmit == true)
        store.newWorkspaceDirectory = "  /home/you/src/app  "
        #expect(store.canSubmit == true)

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.params.first?.workspaceID == nil)
        #expect(recorder.params.first?.cwd == nil)
        #expect(
            recorder.destinations
                == [.newWorkspace(NewWorkspaceSpec(directory: "/home/you/src/app"))])
    }

    @Test func newWorkspaceTrimsDirectoryAndDropsAnEmptyLabel() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        await store.discoverAgents()
        store.launchTarget = .newWorkspace
        store.newWorkspaceDirectory = "\n /tmp/project \t"
        store.newWorkspaceLabel = "   "

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.params.first?.workspaceID == nil)
        #expect(
            recorder.destinations
                == [.newWorkspace(NewWorkspaceSpec(directory: "/tmp/project", label: nil))])
    }

    @Test func newWorkspaceSubmitRemembersTheReturnedWorkspaceAndWaits() async throws {
        let host = Host.fixture()
        let recents = makeRecents()
        let recorder = StartRecorder()
        recorder.agent = Agent(
            .fixture(paneID: "nw1:pnew", status: .working, workspaceID: "nw1"))
        let visibilityGate = ScriptedTransportCallGate()
        final class SeenBox { var ids: [ConsoleAgent.ID] = [] }
        let seen = SeenBox()
        let store = makeStore(
            hosts: [host],
            awaitAgentVisible: { id in
                seen.ids.append(id)
                await visibilityGate.waitUntilOpen()
            },
            recents: recents,
            recorder: recorder)
        await store.discoverAgents()
        store.launchTarget = .newWorkspace
        store.newWorkspaceDirectory = "/src/app"
        store.newWorkspaceLabel = "  App  "

        let submit = Task { await store.submit() }
        try await waitUntil("the visibility wait should begin") {
            await visibilityGate.entryCount == 1
        }
        #expect(store.state == .starting)

        await visibilityGate.open()
        await submit.value

        #expect(store.state == started(on: host, paneID: "nw1:pnew"))
        #expect(seen.ids == [ConsoleAgent.ID(hostID: host.id, paneID: "nw1:pnew")])
        #expect(
            recorder.destinations
                == [.newWorkspace(NewWorkspaceSpec(directory: "/src/app", label: "App"))])

        let next = makeStore(
            hosts: [host],
            workspaces: { _ in
                [ConsoleWorkspace(id: "w1", label: "Old"),
                    ConsoleWorkspace(id: "nw1", label: "App")]
            },
            recents: recents,
            recorder: StartRecorder())
        #expect(next.selectedWorkspaceID == "nw1")
    }

    @Test func newWorkspaceServerRejectionUsesExistingErrorPresentation() async {
        let host = Host.fixture()
        let recents = makeRecents()
        let recorder = StartRecorder()
        recorder.error = HerdrAPIError(code: "cwd_not_found", message: "no such directory")
        let store = makeStore(hosts: [host], recents: recents, recorder: recorder)
        await store.discoverAgents()
        store.launchTarget = .newWorkspace
        store.newWorkspaceDirectory = "/missing"

        await store.submit()

        #expect(store.state == .failed("Herdr TUI rejected the command: no such directory"))
        let next = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recents: recents,
            recorder: StartRecorder())
        #expect(next.selectedWorkspaceID == "w1")
    }

    @Test func switchingHostClearsStaleWorkspaceAndAgentPicks() async {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let store = makeStore(
            hosts: [hostA, hostB],
            workspaces: {
                $0 == hostA.id
                    ? [ConsoleWorkspace(id: "w1", label: "Proj"),
                        ConsoleWorkspace(id: "w2", label: "Other")]
                    : []
            },
            recorder: StartRecorder())

        store.selectedHostID = hostA.id
        await store.discoverAgents()
        store.selectedWorkspaceID = "w2"
        #expect(store.selectedAgentKind == .claude)
        #expect(store.workspaces.map(\.id) == ["w1", "w2"])

        store.selectedHostID = hostB.id
        #expect(store.selectedWorkspaceID == nil)
        #expect(store.selectedAgentKind == nil)
        #expect(store.agentDiscoveryState == .idle)
        #expect(store.workspaces.isEmpty)
    }

    @Test func defaultsToTheHostsFirstWorkspaceWithNothingRemembered() {
        let host = Host.fixture()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in
                [ConsoleWorkspace(id: "w1", label: "Proj"),
                    ConsoleWorkspace(id: "w2", label: "Other")]
            },
            recorder: StartRecorder())

        #expect(store.selectedWorkspaceID == "w1")
    }

    @Test func fallsBackWhenTheExplicitWorkspaceDisappearsBeforeSubmit() async {
        let host = Host.fixture()
        final class Snapshot {
            var workspaces = [
                ConsoleWorkspace(id: "w1", label: "Proj"),
                ConsoleWorkspace(id: "w2", label: "Other"),
            ]
        }
        let snapshot = Snapshot()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host], workspaces: { _ in snapshot.workspaces }, recorder: recorder)
        store.selectedWorkspaceID = "w2"

        snapshot.workspaces = [ConsoleWorkspace(id: "w1", label: "Proj")]
        store.name = "reviewer"
        await store.discoverAgents()
        await store.submit()

        #expect(store.state == started(on: host))
        #expect(store.selectedWorkspaceID == "w1")
        #expect(recorder.params.map(\.workspaceID) == ["w1"])
    }

    /// The snapshot often lands after the sheet opens; the default has to
    /// follow it rather than latch on the empty list.
    @Test func defaultFollowsAWorkspaceListThatArrivesLate() {
        let host = Host.fixture()
        final class Snapshot { var workspaces: [ConsoleWorkspace] = [] }
        let snapshot = Snapshot()
        let store = makeStore(
            hosts: [host], workspaces: { _ in snapshot.workspaces }, recorder: StartRecorder())

        #expect(store.selectedWorkspaceID == nil)
        snapshot.workspaces = [ConsoleWorkspace(id: "w1", label: "Proj")]
        #expect(store.selectedWorkspaceID == "w1")
    }

    @Test func defaultsToTheWorkspaceLastStartedInOnThatHost() async {
        let host = Host.fixture()
        let other = Host.fixture(address: "b.example")
        let recents = makeRecents()
        let workspaces: (Host.ID) -> [ConsoleWorkspace] = { _ in
            [ConsoleWorkspace(id: "w1", label: "Proj"), ConsoleWorkspace(id: "w2", label: "Other")]
        }

        let first = makeStore(
            hosts: [host], workspaces: workspaces, recents: recents, recorder: StartRecorder())
        first.selectedWorkspaceID = "w2"
        first.name = "reviewer"
        await first.discoverAgents()
        await first.submit()
        #expect(first.state == started(on: host))

        let next = makeStore(
            hosts: [host], workspaces: workspaces, recents: recents, recorder: StartRecorder())
        #expect(next.selectedWorkspaceID == "w2")

        // Remembered per Host: another Host falls back to its own first.
        let elsewhere = makeStore(
            hosts: [other], workspaces: workspaces, recents: recents, recorder: StartRecorder())
        #expect(elsewhere.selectedWorkspaceID == "w1")
    }

    @Test func ignoresARememberedWorkspaceTheHostNoLongerReports() async {
        let host = Host.fixture()
        let recents = makeRecents()
        let gone = makeStore(
            hosts: [host], workspaces: { _ in [ConsoleWorkspace(id: "w9", label: "Gone")] },
            recents: recents, recorder: StartRecorder())
        gone.name = "reviewer"
        await gone.discoverAgents()
        await gone.submit()

        let next = makeStore(
            hosts: [host], workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recents: recents, recorder: StartRecorder())
        #expect(next.selectedWorkspaceID == "w1")
    }

    @Test func aFailedStartIsNotRemembered() async {
        let host = Host.fixture()
        let recents = makeRecents()
        let recorder = StartRecorder()
        recorder.error = HerdrAPIError(code: "400", message: "no such workspace")
        let workspaces: (Host.ID) -> [ConsoleWorkspace] = { _ in
            [ConsoleWorkspace(id: "w1", label: "Proj"), ConsoleWorkspace(id: "w2", label: "Other")]
        }
        let store = makeStore(
            hosts: [host], workspaces: workspaces, recents: recents, recorder: recorder)
        store.selectedWorkspaceID = "w2"
        store.name = "reviewer"
        await store.discoverAgents()
        await store.submit()

        let next = makeStore(
            hosts: [host], workspaces: workspaces, recents: recents, recorder: StartRecorder())
        #expect(next.selectedWorkspaceID == "w1")
    }

    @Test func submitForwardsTheAssembledParamsAndSucceeds() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.selectedWorkspaceID = "w1"
        store.name = "reviewer"
        store.arguments = #"—yolo --continue --label "code review""#
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.hostIDs == [host.id])
        #expect(recorder.params.first?.kind == "claude")
        #expect(recorder.params.first?.name == "reviewer")
        #expect(
            recorder.params.first?.arguments
                == ["--yolo", "--continue", "--label", "code review"])
        #expect(recorder.params.first?.workspaceID == "w1")
        #expect(recorder.destinations == [.existingWorkspace])
        #expect(recorder.worktrees == [nil])
    }

    @Test func submitDispatchesAgentStartWithQwenKind() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [.qwen] },
            recorder: recorder)
        await store.discoverAgents()
        #expect(store.selectedAgentKind == .qwen)

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.params.first?.kind == "qwen")
    }

    @Test func submitDispatchesAgentStartWithMuseKind() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [.muse] },
            recorder: recorder)
        await store.discoverAgents()
        #expect(store.selectedAgentKind == .muse)

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.params.first?.kind == "muse")
    }

    @Test func submitSurfacesUnsupportedMuseKindWithRecoveryAdvice() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        // herdr v0.8.2 / v0.9.0: code unsupported_agent_kind, message without a colon.
        recorder.error = HerdrAPIError(
            code: "unsupported_agent_kind",
            message: "unsupported interactive agent kind muse")
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [.muse] },
            recorder: recorder)
        await store.discoverAgents()

        await store.submit()

        #expect(
            store.state
                == .failed(
                    "Herdr TUI rejected the command: unsupported interactive agent kind muse. "
                        + "Update herdr on this Host to v0.9.0 or later for Muse support, "
                        + "or choose another supported Agent."))
        #expect(recorder.params.map(\.kind) == ["muse"])
    }

    @Test func submitKeepsGenericCopyForUnrelatedAgentStartErrors() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        recorder.error = HerdrAPIError(code: "400", message: "no such workspace")
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [.muse] },
            recorder: recorder)
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == .failed("Herdr TUI rejected the command: no such workspace"))
    }

    @Test func submitKeepsGenericCopyWhenNonMuseKindIsUnsupported() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        recorder.error = HerdrAPIError(
            code: "unsupported_agent_kind",
            message: "unsupported interactive agent kind qwen")
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [.qwen] },
            recorder: recorder)
        await store.discoverAgents()

        await store.submit()

        #expect(
            store.state
                == .failed("Herdr TUI rejected the command: unsupported interactive agent kind qwen"))
        #expect(recorder.params.map(\.kind) == ["qwen"])
    }

    @Test func unsupportedMuseAdviceUsesTheCapturedLaunchKind() async throws {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let gate = ScriptedTransportCallGate()
        recorder.gate = gate
        recorder.error = HerdrAPIError(
            code: "unsupported_agent_kind",
            message: "unsupported interactive agent kind muse")
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [.muse, .qwen] },
            recorder: recorder)
        await store.discoverAgents()
        #expect(store.selectedAgentKind == .muse)

        let submit = Task { await store.submit() }
        try await waitUntil("the Muse start should reach the gate") {
            await gate.entryCount == 1
        }
        store.selectedAgentKind = .qwen
        await gate.open()
        await submit.value

        #expect(
            store.state
                == .failed(
                    "Herdr TUI rejected the command: unsupported interactive agent kind muse. "
                        + "Update herdr on this Host to v0.9.0 or later for Muse support, "
                        + "or choose another supported Agent."))
        #expect(recorder.params.map(\.kind) == ["muse"])
    }

    /// Launching from an agent's own screen: Host, workspace, and directory
    /// come from that agent, so the new tab lands beside it rather than at
    /// the workspace root.
    @Test func originLaunchInheritsTheAgentsHostWorkspaceAndDirectory() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host, .fixture(id: UUID(), name: "other")],
            workspaces: { _ in [ConsoleWorkspace(id: "w9", label: "Other")] },
            origin: StartAgentStore.LaunchOrigin(
                hostID: host.id, workspaceID: "w1", cwd: "/Users/dev/proj/api"),
            recorder: recorder)
        // Two Hosts would otherwise leave the picker unset.
        #expect(store.selectedHostID == host.id)
        #expect(store.selectedWorkspaceID == "w1")
        store.name = "reviewer"
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.hostIDs == [host.id])
        #expect(recorder.params.first?.workspaceID == "w1")
        #expect(recorder.params.first?.cwd == "/Users/dev/proj/api")
        #expect(recorder.worktrees == [nil])
    }

    /// A worktree launch lands in a brand-new checkout, which contradicts the
    /// inherited directory. The form drops the option, and a stale toggle
    /// cannot smuggle it back in.
    @Test func originLaunchNeverTakesTheWorktreeVariant() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            origin: StartAgentStore.LaunchOrigin(
                hostID: host.id, workspaceID: "w1", cwd: "/Users/dev/proj"),
            recorder: recorder)
        #expect(!store.offersWorktree)
        store.startsInNewWorktree = true
        store.worktreeBranch = "task/fix"
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.worktrees == [nil])
        #expect(recorder.params.first?.cwd == "/Users/dev/proj")
    }

    /// New Workspace would open a different directory and drop the origin
    /// Workspace. The origin flow hides the choice, and forcing the fields
    /// cannot smuggle it onto the request.
    @Test func originLaunchNeverExposesOrTakesNewWorkspace() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            origin: StartAgentStore.LaunchOrigin(
                hostID: host.id, workspaceID: "w1", cwd: "/Users/dev/proj"),
            recorder: recorder)
        #expect(!store.offersNewWorkspace)
        store.launchTarget = .newWorkspace
        store.newWorkspaceDirectory = "/tmp/elsewhere"
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.destinations == [.existingWorkspace])
        #expect(recorder.params.first?.workspaceID == "w1")
        #expect(recorder.params.first?.cwd == "/Users/dev/proj")
    }

    /// The origin agent proves its workspace exists, so it outranks both the
    /// remembered pick and the snapshot the Host happens to report.
    @Test func originWorkspaceOutranksTheRememberedAndReportedOnes() async {
        let host = Host.fixture()
        let recents = makeRecents()
        recents.remember("w7", for: host.id)
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in
                [ConsoleWorkspace(id: "w7", label: "Remembered")]
            },
            origin: StartAgentStore.LaunchOrigin(
                hostID: host.id, workspaceID: "w1", cwd: "/Users/dev/proj"),
            recents: recents,
            recorder: recorder)

        #expect(store.selectedWorkspaceID == "w1")
        store.selectedWorkspaceID = "w7"
        #expect(store.selectedWorkspaceID == "w1", "the origin workspace is not user-overridable")
    }

    /// Without an origin the launch carries no directory, leaving herdr to
    /// place the tab at the workspace's own.
    @Test func consoleLaunchCarriesNoDirectory() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.name = "reviewer"
        await store.discoverAgents()

        await store.submit()

        #expect(store.offersWorktree)
        #expect(recorder.params.first?.cwd == nil)
    }

    @Test func worktreeSubmitWithLatestMainOffForwardsTheTrimmedBase() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.name = "reviewer"
        store.startsInNewWorktree = true
        store.startsFromLatestMain = false
        store.worktreeBranch = "task/fix-97"
        store.worktreeBase = " origin/main "
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.params.first?.workspaceID == "w1")
        #expect(
            recorder.destinations
                == [.newWorktree(WorktreeSpec(branch: "task/fix-97", base: .ref("origin/main")))])
        #expect(
            recorder.worktrees == [WorktreeSpec(branch: "task/fix-97", base: .ref("origin/main"))])
    }

    /// A blank Branch field sends a branch the sheet minted, marked as
    /// generated so the Transport may treat a worktree found on it as the
    /// launch's own; the name never shows in the Branch or Name fields.
    /// Latest main is the default base.
    @Test func aBlankBranchSendsAMintedGeneratedBranchFromLatestMain() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let minter = BranchMinter()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            minter: minter, recorder: recorder)
        store.startsInNewWorktree = true
        await store.discoverAgents()
        #expect(store.startsFromLatestMain)

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(minter.minted.count == 1)
        #expect(recorder.worktrees == [minter.spec(base: .latestDefaultBranch)])
        #expect(store.worktreeBranch.isEmpty)
        #expect(store.name.isEmpty)
        #expect(recorder.params.first?.name == "claude")
    }

    /// Tapping Start again after a failure, with nothing changed, sends the
    /// same minted branch so the retry finds the worktree the failed try may
    /// have made instead of creating a second one.
    @Test(arguments: [false, true])
    func aRetryWithUnchangedInputsSendsTheSameMintedBranch(launchesShell: Bool) async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        recorder.error = WorktreeLaunchError.createUnconfirmed
        let minter = BranchMinter()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            minter: minter, recorder: recorder)
        await store.discoverAgents()
        store.selectedLaunchIsShell = launchesShell
        store.startsInNewWorktree = true

        await store.submit()
        recorder.error = nil
        await store.submit()

        #expect(store.state == (launchesShell ? shellStarted(on: host) : started(on: host)))
        #expect(minter.minted.count == 1)
        let sent = minter.spec(base: .latestDefaultBranch)
        #expect(recorder.worktrees == [sent, sent])
    }

    @Test func retryReplacesFailedProgressBeforePublishingSuccessMetadata() async {
        let recorder = StartRecorder()
        recorder.error = TransportError.apiRejected(code: "failed", message: "No start")
        recorder.reportsBeforeGate = [.creatingTab, .startingAgent]
        let store = makeStore(hosts: [.fixture()], workspaces: { _ in [.init(id: "w1", label: "Project")] },
            recorder: recorder)
        await store.discoverAgents()
        await store.submit()
        #expect(store.launchSteps.map(\.status) == [.done, .failed])
        #expect(store.launchedAgentKind == nil)
        recorder.error = nil
        recorder.reportsBeforeGate = [.creatingWorkspace, .startingAgent, .startingAgent]
        await store.submit()
        #expect(store.launchSteps.map(\.step) == [.creatingWorkspace, .startingAgent, .opening])
        #expect(store.launchSteps.map(\.status) == [.done, .done, .running])
        #expect(store.launchedAgentKind == .claude)
    }

    /// Form Retry currently reuses only the generated branch. Unlike a
    /// persisted Queued Launch, it mints a new Launch Tag and session pin.
    /// Pin this distinction before a compile-in-the-loop identity conversion.
    @Test func formRetryReusesTheBranchButMintsANewTagAndSession() async throws {
        let host = Host.fixture()
        let recorder = StartRecorder()
        recorder.error = WorktreeLaunchError.createUnconfirmed
        let minter = BranchMinter()
        let store = makeStore(hosts: [host], workspaces: { _ in [.init(id: "w1", label: "Project")] },
            minter: minter, recorder: recorder)
        await store.discoverAgents()
        store.chatMode = false
        store.startsInNewWorktree = true
        await store.submit()
        await store.submit()
        #expect(recorder.params.count == 2)
        let first = try #require(recorder.params.first)
        let retry = try #require(recorder.params.last)
        #expect(first.launchID != nil && retry.launchID != nil && first.launchID != retry.launchID)
        #expect(first.name == retry.name)
        #expect(first.arguments != retry.arguments, "Each ordinary form Retry currently pins a new session")
        #expect(minter.minted.count == 1)
        #expect(recorder.worktrees == [minter.spec(base: .latestDefaultBranch), minter.spec(base: .latestDefaultBranch)])
    }

    /// A lost answer keeps the resolved name and branch on disk. A fresh
    /// replay store must not remint either when the first Agent owns its name.
    @Test(arguments: [false, true])
    func aKeptDraftReplaysTheSameNameTagAndBranchFromAFreshStore(launchesShell: Bool) async throws {
        let host = Host.fixture()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "launch-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = QueuedLaunchStore(directory: directory)
        let recorder = StartRecorder()
        recorder.error = TransportError.sshUnreachable(detail: "The answer was lost.")
        let minter = BranchMinter()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            minter: minter, recorder: recorder,
            launchQueue: .init(store: queue, enqueue: { try queue.save($0) }))
        await store.discoverAgents()
        store.selectedLaunchIsShell = launchesShell
        store.chatMode = false
        store.startsInNewWorktree = true
        await store.submit()

        let kept = try #require(queue.launches(on: host.id).first)
        #expect(kept.state == .waiting)
        #expect(kept.mayHaveStarted == true)
        #expect(kept.draft.launchName == (launchesShell ? nil : "claude"))
        #expect(kept.draft.worktreeBranch == minter.minted.first)
        let replayMinter = BranchMinter()
        let replay = makeStore(
            hosts: [host],
            existingAgentNames: { _ in Set(recorder.params.map(\.name)) },
            minter: replayMinter, recorder: recorder)
        let draft = replay.prepareLaunchDraft(kept.draft)
        recorder.error = nil
        _ = await replay.launch(draft, mayHaveStarted: kept.mayHaveStarted == true)

        #expect(recorder.worktrees == [minter.spec(base: .latestDefaultBranch),
                                      minter.spec(base: .latestDefaultBranch)])
        #expect(replayMinter.minted.isEmpty)
        if launchesShell {
            #expect(recorder.shellParams.map(\.launchID) == [draft.id, draft.id])
            #expect(recorder.shellParams.map(\.mayHaveStarted) == [false, true])
            #expect(recorder.shellParams.map(\.name) == [nil, nil])
        } else {
            #expect(recorder.params.map(\.name) == ["claude", "claude"])
            #expect(recorder.params.map(\.launchID) == [draft.id, draft.id])
            #expect(recorder.params.map(\.mayHaveStarted) == [false, true])
            let pin = try #require(draft.sessionPin)
            let arguments = try #require(recorder.params.first?.arguments)
            #expect(arguments.contains(pin.uuidString.lowercased()))
            #expect(recorder.params.map(\.arguments) == [arguments, arguments])
        }
    }

    /// A kept launch takes its branch with it: the form's next Start from
    /// the same inputs is another launch, so it mints another branch, Tag
    /// and session, while the kept draft's identity stays pinned however
    /// often it is prepared again.
    @Test(arguments: [false, true])
    func aKeptLaunchTakesItsBranchAndTheNextStartMintsAnother(launchesShell: Bool) async throws {
        let host = Host.fixture()
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "launch-identity-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = QueuedLaunchStore(directory: directory)
        let recorder = StartRecorder()
        recorder.error = TransportError.sshUnreachable(detail: "The answer was lost.")
        let minter = BranchMinter()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            minter: minter, recorder: recorder,
            launchQueue: .init(store: queue, enqueue: { try queue.save($0) }))
        await store.discoverAgents()
        store.selectedLaunchIsShell = launchesShell
        store.chatMode = false
        store.startsInNewWorktree = true
        await store.submit()
        let kept = try #require(queue.launches(on: host.id).first)
        #expect(store.state == .queued(kept.id))

        recorder.error = nil
        await store.submit()

        #expect(minter.minted.count == 2)
        #expect(recorder.worktrees == [minter.spec(0, base: .latestDefaultBranch),
                                      minter.spec(1, base: .latestDefaultBranch)])
        #expect(try #require(queue.launches(on: host.id).first) == kept)
        #expect(kept.draft.worktreeBranch == minter.minted.first)
        let launchIDs = launchesShell
            ? recorder.shellParams.map(\.launchID) : recorder.params.map(\.launchID)
        #expect(launchIDs.count == 2 && launchIDs.first == kept.id && launchIDs.last != kept.id)
        if !launchesShell {
            #expect(recorder.params.first?.arguments != recorder.params.last?.arguments)
        }
        #expect(store.prepareLaunchDraft(kept.draft) == kept.draft)
        let replay = makeStore(hosts: [host], recorder: StartRecorder())
        #expect(replay.prepareLaunchDraft(replay.prepareLaunchDraft(kept.draft)) == kept.draft)
    }

    /// A started Default Shell drops the minted branch too.
    @Test func aSuccessfulShellLaunchDropsTheMintedBranch() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        recorder.error = WorktreeLaunchError.createUnconfirmed
        let minter = BranchMinter()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            minter: minter, recorder: recorder)
        await store.discoverAgents()
        store.selectedLaunchIsShell = true
        store.startsInNewWorktree = true

        await store.submit()
        recorder.error = nil
        await store.submit()
        await store.submit()

        #expect(store.state == shellStarted(on: host))
        #expect(minter.minted.count == 2)
        #expect(
            recorder.worktrees == [
                minter.spec(0, base: .latestDefaultBranch),
                minter.spec(0, base: .latestDefaultBranch),
                minter.spec(1, base: .latestDefaultBranch),
            ])
    }

    enum WorktreeInputChange: CaseIterable {
        case host
        case workspace
        case base
    }

    /// A failed try's branch belongs to its Host, source Workspace and base;
    /// changing any of them sends a freshly minted branch.
    @Test(arguments: WorktreeInputChange.allCases)
    func changingALaunchInputMintsANewBranch(_ change: WorktreeInputChange) async {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let recorder = StartRecorder()
        recorder.error = WorktreeLaunchError.createUnconfirmed
        let minter = BranchMinter()
        let store = makeStore(
            hosts: [hostA, hostB],
            workspaces: { _ in
                [ConsoleWorkspace(id: "w1", label: "Proj"), ConsoleWorkspace(id: "w2", label: "Other")]
            },
            minter: minter, recorder: recorder)
        store.selectedHostID = hostA.id
        await store.discoverAgents()
        store.startsInNewWorktree = true
        await store.submit()

        var base = WorktreeBase.latestDefaultBranch
        switch change {
        case .host:
            store.selectedHostID = hostB.id
            await store.discoverAgents()
            store.startsInNewWorktree = true
        case .workspace:
            store.selectExistingWorkspace("w2")
        case .base:
            store.startsFromLatestMain = false
            base = .sourceHead
        }
        await store.submit()

        #expect(minter.minted.count == 2)
        #expect(
            recorder.worktrees
                == [minter.spec(0, base: .latestDefaultBranch), minter.spec(1, base: base)])
    }

    /// A successful launch drops the minted branch: the next launch from the
    /// same inputs is a new worktree, not a return to the last one.
    @Test func aSuccessfulLaunchDropsTheMintedBranch() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        recorder.error = WorktreeLaunchError.createUnconfirmed
        let minter = BranchMinter()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            minter: minter, recorder: recorder)
        await store.discoverAgents()
        store.startsInNewWorktree = true

        await store.submit()
        recorder.error = nil
        await store.submit()
        await store.submit()

        #expect(minter.minted.count == 2)
        #expect(
            recorder.worktrees == [
                minter.spec(0, base: .latestDefaultBranch),
                minter.spec(0, base: .latestDefaultBranch),
                minter.spec(1, base: .latestDefaultBranch),
            ])
    }

    @Test func worktreeSubmitWithLatestMainOffAndEmptyFieldsUsesHerdrsDefaults() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let minter = BranchMinter()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            minter: minter, recorder: recorder)
        store.name = "reviewer"
        store.startsInNewWorktree = true
        store.startsFromLatestMain = false
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.worktrees == [minter.spec(base: .sourceHead)])
    }

    @Test func latestMainIgnoresATypedBaseButKeepsItInTheField() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let minter = BranchMinter()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            minter: minter, recorder: recorder)
        store.name = "reviewer"
        store.startsInNewWorktree = true
        store.startsFromLatestMain = false
        store.worktreeBase = "release/1.2"
        store.startsFromLatestMain = true
        await store.discoverAgents()

        await store.submit()

        #expect(recorder.worktrees == [minter.spec(base: .latestDefaultBranch)])
        // Turning the switch off again brings the typed Base back.
        #expect(store.worktreeBase == "release/1.2")
    }

    @Test func latestMainOffAgainSubmitsTheTypedBase() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let minter = BranchMinter()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            minter: minter, recorder: recorder)
        store.name = "reviewer"
        store.startsInNewWorktree = true
        store.startsFromLatestMain = false
        store.worktreeBase = "release/1.2"
        store.startsFromLatestMain = true
        store.startsFromLatestMain = false
        await store.discoverAgents()

        await store.submit()

        #expect(recorder.worktrees == [minter.spec(base: .ref("release/1.2"))])
    }

    @Test func aWhitespaceOnlyBaseWithLatestMainOffIsHerdrsDefault() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let minter = BranchMinter()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            minter: minter, recorder: recorder)
        store.name = "reviewer"
        store.startsInNewWorktree = true
        store.startsFromLatestMain = false
        store.worktreeBase = " \t "
        await store.discoverAgents()

        await store.submit()

        #expect(recorder.worktrees == [minter.spec(base: .sourceHead)])
    }

    @Test func aSuccessfulWorktreeLaunchRemembersTheLatestMainChoice() async {
        let host = Host.fixture()
        let selections = makeSelections()
        let workspaces: (Host.ID) -> [ConsoleWorkspace] = { _ in
            [ConsoleWorkspace(id: "w1", label: "Proj")]
        }
        let off = makeStore(
            hosts: [host], workspaces: workspaces, selections: selections,
            recorder: StartRecorder())
        off.name = "reviewer"
        off.startsInNewWorktree = true
        off.startsFromLatestMain = false
        await off.discoverAgents()
        await off.submit()
        #expect(off.state == started(on: host))

        let reopened = makeStore(
            hosts: [host], workspaces: workspaces, selections: selections,
            recorder: StartRecorder())
        #expect(reopened.startsFromLatestMain == false)

        // A shell launch with it back on restores the default.
        reopened.selectedLaunchIsShell = true
        reopened.startsInNewWorktree = true
        reopened.startsFromLatestMain = true
        await reopened.submit()
        #expect(reopened.state == shellStarted(on: host))

        let third = makeStore(
            hosts: [host], workspaces: workspaces, selections: selections,
            recorder: StartRecorder())
        #expect(third.startsFromLatestMain)
    }

    /// Remembered OFF, then a launch with it ON fails: the next sheet still
    /// opens OFF, for Agents and Default Shell alike.
    @Test(arguments: [false, true])
    func aFailedWorktreeLaunchLeavesTheLatestMainChoiceAlone(launchesShell: Bool) async {
        let host = Host.fixture()
        let selections = makeSelections()
        selections.rememberStartsFromLatestMain(false)
        let failing = StartRecorder()
        let minter = BranchMinter()
        failing.error = WorktreeBaseResolutionError.fetchFailed(detail: "offline")
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            selections: selections, minter: minter, recorder: failing)
        await store.discoverAgents()
        store.name = "reviewer"
        store.selectedLaunchIsShell = launchesShell
        store.startsInNewWorktree = true
        #expect(store.startsFromLatestMain == false)
        store.startsFromLatestMain = true

        await store.submit()

        guard case .failed = store.state else {
            Issue.record("expected a failed launch, got \(store.state)")
            return
        }
        #expect(failing.worktrees == [minter.spec(base: .latestDefaultBranch)])
        let reopened = makeStore(hosts: [host], selections: selections, recorder: StartRecorder())
        #expect(reopened.startsFromLatestMain == false)
    }

    @Test func aLaunchIntoTheWorkspaceItselfLeavesTheLatestMainChoiceAlone() async {
        let host = Host.fixture()
        let selections = makeSelections()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            selections: selections, recorder: StartRecorder())
        store.name = "reviewer"
        store.startsFromLatestMain = false
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == started(on: host))
        let reopened = makeStore(hosts: [host], selections: selections, recorder: StartRecorder())
        #expect(reopened.startsFromLatestMain)
    }

    @Test func anInvalidWorktreeBranchBlocksSubmission() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.name = "reviewer"
        await store.discoverAgents()
        #expect(store.canSubmit == true)

        store.startsInNewWorktree = true
        store.worktreeBranch = "ends.lock"
        #expect(store.worktreeBranchErrorMessage != nil)
        #expect(store.canSubmit == false)
        await store.submit()
        #expect(store.state == .editing)
        #expect(recorder.params.isEmpty)

        // The same text is fine while the toggle is off: it never reaches git.
        store.startsInNewWorktree = false
        #expect(store.worktreeBranchErrorMessage == nil)
        #expect(store.canSubmit == true)
    }

    @Test func switchingHostResetsTheWorktreeFieldsButNotLatestMain() {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let store = makeStore(hosts: [hostA, hostB], recorder: StartRecorder())
        store.selectedHostID = hostA.id
        store.startsInNewWorktree = true
        store.startsFromLatestMain = false
        store.worktreeBranch = "task/fix-97"
        store.worktreeBase = "origin/main"

        store.selectedHostID = hostB.id

        #expect(store.startsInNewWorktree == false)
        #expect(store.worktreeBranch.isEmpty)
        #expect(store.worktreeBase.isEmpty)
        #expect(store.startsFromLatestMain == false)
    }

    @Test func switchingToNewWorkspaceDropsAnActiveWorktreeRequest() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        await store.discoverAgents()
        store.startsInNewWorktree = true
        store.startsFromLatestMain = false
        store.worktreeBranch = "task/fix"
        store.worktreeBase = "origin/main"
        #expect(store.offersWorktree)

        store.launchTarget = .newWorkspace

        #expect(!store.offersWorktree)
        #expect(store.startsInNewWorktree == false)
        #expect(store.worktreeBranch.isEmpty)
        #expect(store.worktreeBase.isEmpty)
        #expect(store.startsFromLatestMain == false)
        store.newWorkspaceDirectory = "/src/app"
        await store.submit()

        #expect(
            recorder.destinations
                == [.newWorkspace(NewWorkspaceSpec(directory: "/src/app"))])
        #expect(recorder.worktrees == [nil])
        #expect(recorder.params.first?.workspaceID == nil)
    }

    @Test func switchingHostResetsNewWorkspaceFields() {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let store = makeStore(hosts: [hostA, hostB], recorder: StartRecorder())
        store.selectedHostID = hostA.id
        store.launchTarget = .newWorkspace
        store.newWorkspaceDirectory = "/src/app"
        store.newWorkspaceLabel = "App"

        store.selectedHostID = hostB.id

        #expect(store.launchTarget == .existingWorkspace)
        #expect(store.newWorkspaceDirectory.isEmpty)
        #expect(store.newWorkspaceLabel.isEmpty)
        #expect(store.offersWorktree)
    }

    @Test func worktreeFailuresGetFirstClassCopy() async {
        let host = Host.fixture()
        let workspaces: (Host.ID) -> [ConsoleWorkspace] = { _ in
            [ConsoleWorkspace(id: "w1", label: "Proj")]
        }

        // The dedicated code for a non-git workspace cwd.
        let notGit = StartRecorder()
        notGit.error = HerdrAPIError(
            code: "not_git_worktree",
            message: "Herdr worktree actions require a workspace inside a Git work tree")
        let first = makeStore(hosts: [host], workspaces: workspaces, recorder: notGit)
        first.name = "reviewer"
        first.startsInNewWorktree = true
        await first.discoverAgents()
        await first.submit()
        #expect(
            first.state
                == .failed(
                    "This workspace is not inside a Git repository, so no worktree can be created from it."
                ))

        // Everything else collapses into raw git stderr; pass it through.
        let gitFailure = StartRecorder()
        gitFailure.error = HerdrAPIError(
            code: "worktree_create_failed",
            message: "fatal: 'task/fix-97' is already used by worktree at '/w'")
        let second = makeStore(hosts: [host], workspaces: workspaces, recorder: gitFailure)
        second.name = "reviewer"
        second.startsInNewWorktree = true
        await second.discoverAgents()
        await second.submit()
        #expect(
            second.state
                == .failed(
                    "Creating the worktree failed: fatal: 'task/fix-97' is already used by worktree at '/w'"
                ))

        // Latest main: a failed fetch aborts with its git detail and names
        // the switch that avoids it.
        let fetchFailure = StartRecorder()
        fetchFailure.error = WorktreeBaseResolutionError.fetchFailed(
            detail: "fatal: Could not read from remote repository")
        let third = makeStore(hosts: [host], workspaces: workspaces, recorder: fetchFailure)
        third.name = "reviewer"
        third.startsInNewWorktree = true
        await third.discoverAgents()
        await third.submit()
        guard case .failed(let message) = third.state else {
            Issue.record("expected a failed launch, got \(third.state)")
            return
        }
        #expect(message.contains("fatal: Could not read from remote repository"))
        #expect(message.contains(StartAgentStore.latestMainToggleTitle))

        // A linked-worktree source is refused before any network work.
        let linked = StartRecorder()
        linked.error = WorktreeBaseResolutionError.linkedWorktreeSource
        let fourth = makeStore(hosts: [host], workspaces: workspaces, recorder: linked)
        fourth.name = "reviewer"
        fourth.startsInNewWorktree = true
        await fourth.discoverAgents()
        await fourth.submit()
        #expect(
            fourth.state
                == .failed(
                    "This workspace is itself a worktree. "
                        + "Start new worktrees from the repository's main workspace."))
    }

    @Test func startInFlightPreventsDismissalAndDuplicateSubmit() async throws {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let gate = ScriptedTransportCallGate()
        recorder.gate = gate
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.name = "reviewer"
        await store.discoverAgents()

        let first = Task { await store.submit() }
        try await waitUntil("the first start should reach the gate") {
            await gate.entryCount == 1
        }
        #expect(store.state == .starting)
        #expect(store.canDismiss == false)

        let second = Task { await store.submit() }
        await second.value
        #expect(await gate.entryCount == 1)
        #expect(recorder.params.count == 1)

        await gate.open()
        await first.value

        #expect(store.state == started(on: host))
        #expect(store.canDismiss == true)
    }

    /// The owner navigates to the started Agent, so the store stays in
    /// `.starting` until the Console reports the row — and the `.started`
    /// payload names exactly the pane the visibility wait was given.
    @Test func submitAwaitsTheStartedAgentsVisibilityBeforeFinishing() async throws {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let visibilityGate = ScriptedTransportCallGate()
        final class SeenBox { var ids: [ConsoleAgent.ID] = [] }
        let seen = SeenBox()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            awaitAgentVisible: { id in
                seen.ids.append(id)
                await visibilityGate.waitUntilOpen()
            },
            recorder: recorder)
        store.name = "reviewer"
        await store.discoverAgents()

        let submit = Task { await store.submit() }
        try await waitUntil("the visibility wait should begin") {
            await visibilityGate.entryCount == 1
        }
        #expect(store.state == .starting)

        await visibilityGate.open()
        await submit.value

        #expect(store.state == started(on: host))
        #expect(seen.ids == [ConsoleAgent.ID(hostID: host.id, paneID: "w1:pnew")])
    }

    @Test func submitSurfacesAServerRejection() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        recorder.error = HerdrAPIError(code: "400", message: "no such workspace")
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.name = "reviewer"
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == .failed("Herdr TUI rejected the command: no such workspace"))
    }

    @Test func submitIsANoOpWithoutAHostOrDetectedAgent() async {
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [.fixture(address: "a.example"), .fixture(address: "b.example")],
            recorder: recorder)
        await store.submit()

        #expect(store.state == .editing)
        #expect(recorder.params.isEmpty)
    }

    // MARK: Remembered Host and Agent kind

    @Test func rememberedHostPreselectsWhenItStillExists() {
        let rememberedHost = Host.fixture(address: "a.example")
        let selections = makeSelections()
        selections.remember(hostID: rememberedHost.id, kind: .codex)
        let store = makeStore(
            hosts: [Host.fixture(address: "z.example"), rememberedHost],
            selections: selections,
            recorder: StartRecorder())
        #expect(store.selectedHostID == rememberedHost.id)
    }

    @Test func rememberedHostFallsBackToNilWhenGone() {
        let selections = makeSelections()
        selections.remember(hostID: UUID(), kind: .codex)
        let store = makeStore(
            hosts: [Host.fixture(address: "a.example"), Host.fixture(address: "b.example")],
            selections: selections,
            recorder: StartRecorder())
        #expect(store.selectedHostID == nil)
    }

    @Test func rememberedAgentKindPreselectsWhenAvailable() async {
        let selections = makeSelections()
        selections.remember(hostID: UUID(), kind: .codex)
        let store = makeStore(
            hosts: [Host.fixture()],
            agentKinds: { _ in [.claude, .codex] },
            selections: selections,
            recorder: StartRecorder())
        await store.discoverAgents()
        #expect(store.selectedAgentKind == .codex)
    }

    @Test func rememberedAgentKindFallsBackToFirstWhenUnavailable() async {
        let selections = makeSelections()
        selections.remember(hostID: UUID(), kind: .codex)
        let store = makeStore(
            hosts: [Host.fixture()],
            agentKinds: { _ in [.claude] },
            selections: selections,
            recorder: StartRecorder())
        await store.discoverAgents()
        #expect(store.selectedAgentKind == .claude)
    }

    @Test func submitPersistsHostAndKindForTheNextSheet() async {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let selections = makeSelections()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [hostA, hostB],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            selections: selections,
            recorder: recorder)
        store.selectedHostID = hostB.id
        await store.discoverAgents()
        store.selectedAgentKind = .gemini
        store.name = "reviewer"
        await store.submit()
        #expect(store.state == started(on: hostB))

        // A fresh store over the same defaults suite restores both picks.
        let reopened = makeStore(
            hosts: [hostA, hostB],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [.claude, .gemini] },
            selections: selections,
            recorder: StartRecorder())
        #expect(reopened.selectedHostID == hostB.id)
        await reopened.discoverAgents()
        #expect(reopened.selectedAgentKind == .gemini)
    }

    @Test func failedSubmitDoesNotRememberTheSelections() async {
        let host = Host.fixture()
        let selections = makeSelections()
        let recorder = StartRecorder()
        recorder.error = HerdrAPIError(code: "400", message: "no such workspace")
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            selections: selections,
            recorder: recorder)
        store.name = "reviewer"
        await store.discoverAgents()
        await store.submit()

        #expect(selections.lastHostID == nil)
        #expect(selections.lastAgentKind == nil)
    }

    @Test func originLaunchIgnoresRememberedHostAndKind() {
        let originHost = Host.fixture(address: "a.example")
        let selections = makeSelections()
        selections.remember(hostID: Host.fixture(address: "b.example").id, kind: .codex)
        let store = makeStore(
            hosts: [originHost],
            origin: .init(hostID: originHost.id, workspaceID: "w1", cwd: "/home/you/proj"),
            selections: selections,
            recorder: StartRecorder())
        #expect(store.selectedHostID == originHost.id)
    }

    // MARK: Default Shell launches

    @Test func shellSelectionSubmitsWithoutAgentDetection() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        // No workspaces reported: the shell still cannot launch until a
        // destination exists, but no agent detection is required.
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [] },
            recorder: recorder)
        await store.discoverAgents()
        #expect(store.availableAgentKinds.isEmpty)

        store.selectedLaunchIsShell = true
        #expect(store.canSubmit)
        await store.submit()

        #expect(store.state == shellStarted(on: host))
        #expect(recorder.params.isEmpty, "no agent.start may fire for a shell launch")
        #expect(recorder.shellParams.count == 1)
        #expect(recorder.shellParams.first?.name == nil)
        #expect(recorder.shellParams.first?.workspaceID == "w1")
        #expect(recorder.destinations == [.existingWorkspace])
    }

    @Test func shellLaunchInheritsTheOriginDirectory() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            origin: StartAgentStore.LaunchOrigin(
                hostID: host.id, workspaceID: "w1", cwd: "/Users/dev/proj/api"),
            recorder: recorder)
        store.selectedLaunchIsShell = true

        await store.submit()

        #expect(store.state == shellStarted(on: host))
        #expect(recorder.shellParams.first?.workspaceID == "w1")
        #expect(recorder.shellParams.first?.cwd == "/Users/dev/proj/api")
        #expect(recorder.destinations == [.existingWorkspace])
    }

    @Test func shellLaunchInANewWorktreeForwardsTheSpec() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.selectedLaunchIsShell = true
        store.startsInNewWorktree = true
        store.worktreeBranch = "task/fix "
        // Ignored while Start From Latest Main is on (the default).
        store.worktreeBase = "origin/main"

        await store.submit()

        #expect(store.state == shellStarted(on: host))
        #expect(
            recorder.destinations
                == [.newWorktree(WorktreeSpec(branch: "task/fix", base: .latestDefaultBranch))])
        #expect(recorder.shellParams.first?.workspaceID == "w1")
        #expect(recorder.shellParams.first?.name == "task/fix")  // mirrored from the branch
    }

    @Test func shellLaunchInANewWorkspaceResolvesHomeAndRemembersIt() async {
        let host = Host.fixture()
        let recents = makeRecents()
        let selections = makeSelections()
        let recorder = StartRecorder()
        recorder.shellResult = ShellLaunchResult(
            paneID: "nw1:p-shell", tabID: "nw1:t-shell", terminalID: "term-shell",
            workspaceID: "nw1")
        let store = makeStore(
            hosts: [host], recents: recents, selections: selections, recorder: recorder)
        await store.discoverAgents()
        store.selectedLaunchIsShell = true
        store.launchTarget = .newWorkspace
        store.newWorkspaceDirectory = "/src/app"

        await store.submit()

        #expect(store.state == shellStarted(on: host, paneID: "nw1:p-shell"))
        #expect(recorder.shellParams.first?.workspaceID == nil)
        #expect(
            recorder.destinations
                == [.newWorkspace(NewWorkspaceSpec(directory: "/src/app", label: nil))])
        #expect(selections.lastSelectionWasShell)
        #expect(recents.workspaceID(for: host.id) == "nw1")
    }

    @Test func shellFailureSurfacesShellCopyAndRemembersNothing() async {
        let host = Host.fixture()
        let recents = makeRecents()
        let selections = makeSelections()
        let recorder = StartRecorder()
        recorder.error = HerdrAPIError(code: "400", message: "no such workspace")
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recents: recents,
            selections: selections,
            recorder: recorder)
        store.selectedLaunchIsShell = true

        await store.submit()

        #expect(store.state == .failed("Herdr TUI rejected the command: no such workspace"))
        #expect(selections.lastHostID == nil)
        #expect(!selections.lastSelectionWasShell)
        #expect(recents.workspaceID(for: host.id) == nil)
    }

    @Test func shellSubmitWaitsForItsConsoleRow() async throws {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let visibilityGate = ScriptedTransportCallGate()
        final class Seen {
            var waits: [ConsoleAgent.ID] = []
        }
        let seen = Seen()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            awaitAgentVisible: { id in
                seen.waits.append(id)
                await visibilityGate.waitUntilOpen()
            },
            recorder: recorder)
        store.selectedLaunchIsShell = true

        let submit = Task { await store.submit() }
        try await waitUntil("the row visibility wait should begin") {
            await visibilityGate.entryCount == 1
        }
        #expect(store.state == .starting)

        await visibilityGate.open()
        await submit.value

        #expect(store.state == shellStarted(on: host))
        #expect(seen.waits == [ConsoleAgent.ID(hostID: host.id, paneID: "w1:p-shell")])
    }

    @Test func shellTabNameFallsBackToDefaultShellSkippingTakenLabels() async {
        #expect(StartAgentStore.defaultShellName(taken: []) == "Default Shell")
        #expect(StartAgentStore.defaultShellName(taken: ["Default Shell"]) == "Default Shell 2")
        #expect(
            StartAgentStore.defaultShellName(taken: ["Default Shell", "Default Shell 2"])
                == "Default Shell 3")
    }

    @Test func anExplicitShellTabNameIsSentVerbatim() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.selectedLaunchIsShell = true
        store.name = "  ops box  "

        await store.submit()

        #expect(store.state == shellStarted(on: host))
        #expect(recorder.shellParams.first?.name == "ops box")
    }

    @Test func shellTabNamesSkipTheAgentNameRule() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        store.selectedLaunchIsShell = true
        store.name = "Ops Box"

        // A tab label is not an agent name: herdr's lowercase rule does not
        // govern it, so spaces and capitals launch fine.
        #expect(store.nameErrorMessage == nil)
        #expect(store.canSubmit)
        await store.submit()
        #expect(store.state == shellStarted(on: host))
        #expect(recorder.shellParams.first?.name == "Ops Box")
    }

    /// The Arguments field disappears under Default Shell; text typed for a
    /// kind before the switch must not block (or leak into) the launch.
    @Test func staleInvalidArgumentsDoNotBlockAShellSubmit() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        await store.discoverAgents()
        store.arguments = "'unclosed"
        #expect(!store.canSubmit, "invalid arguments block an agent launch")
        store.selectedLaunchIsShell = true
        #expect(store.canSubmit)

        await store.submit()

        #expect(store.state == shellStarted(on: host))
        #expect(recorder.params.isEmpty, "the agent path must never fire for a shell launch")
        #expect(recorder.shellParams.count == 1)
    }

    /// A failed probe must not leave the picker claiming an Agent is
    /// selected while Start is disabled for no visible reason.
    @Test func failedDetectionLeavesThePickerUnselected() async {
        let host = Host.fixture()
        let store = makeStore(
            hosts: [host],
            agentKinds: { _ in throw TransportError.timedOut },
            recorder: StartRecorder())

        await store.discoverAgents()

        #expect(store.agentDiscoveryState == .failed("Agent detection timed out."))
        #expect(store.launchSelection.wrappedValue == nil)
        #expect(!store.canSubmit)
    }

    @Test func rememberedShellSelectionPreselectsShellOnReopen() async {
        let host = Host.fixture(address: "a.example")
        let selections = makeSelections()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            selections: selections,
            recorder: recorder)
        store.selectedLaunchIsShell = true
        await store.submit()
        #expect(store.state == shellStarted(on: host))

        // A fresh store over the same defaults suite restores the Host and
        // preselects Default Shell once detection lands, even though kinds
        // are available.
        let reopened = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [.claude] },
            selections: selections,
            recorder: StartRecorder())
        #expect(reopened.selectedHostID == host.id)
        await reopened.discoverAgents()
        #expect(reopened.selectedLaunchIsShell)

        // An agent submit after the shell flips the memory back.
        let afterAgent = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [.claude] },
            selections: selections,
            recorder: StartRecorder())
        afterAgent.selectedLaunchIsShell = false
        afterAgent.selectedAgentKind = .claude
        afterAgent.name = "reviewer"
        await afterAgent.submit()
        #expect(selections.lastAgentKind == .claude)
        #expect(!selections.lastSelectionWasShell)
    }

    @Test func switchingHostResetsTheShellSelection() async {
        let hostA = Host.fixture(address: "a.example")
        let hostB = Host.fixture(address: "b.example")
        let store = makeStore(
            hosts: [hostA, hostB],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: StartRecorder())
        store.selectedHostID = hostA.id
        await store.discoverAgents()
        store.selectedLaunchIsShell = true

        store.selectedHostID = hostB.id
        await store.discoverAgents()

        #expect(!store.selectedLaunchIsShell)
        #expect(store.selectedAgentKind == .claude, "the pick resets to the first kind")
    }

    // MARK: Launch bar

    private func steps(_ store: StartAgentStore)
        -> [LaunchStep]
    { store.launchSteps.map(\.step) }

    private func statuses(_ store: StartAgentStore)
        -> [StartAgentStore.LaunchStepProgress.Status]
    { store.launchSteps.map(\.status) }

    private func existingWorkspaceStore(
        host: Host = .fixture(), recorder: StartRecorder
    ) -> StartAgentStore {
        makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
    }

    @Test func launchStepsArriveInOrderAndEachNewStepCompletesThePrevious() async throws {
        let recorder = StartRecorder()
        let gate = ScriptedTransportCallGate()
        recorder.gate = gate
        recorder.reportsBeforeGate = [.gettingLatestMain, .creatingWorktree]
        recorder.reportsAfterGate = [.startingAgent]
        let store = existingWorkspaceStore(recorder: recorder)
        await store.discoverAgents()

        let submit = Task { await store.submit() }
        try await waitUntil("both reported steps should reach the store") {
            store.launchSteps.count == 2
        }
        #expect(steps(store) == [.gettingLatestMain, .creatingWorktree])
        #expect(statuses(store) == [.done, .running])
        #expect(store.state == .starting)

        await gate.open()
        await submit.value
        #expect(steps(store) == [.gettingLatestMain, .creatingWorktree, .startingAgent, .opening])
        #expect(statuses(store) == [.done, .done, .done, .running])
    }

    @Test func failedLaunchMarksTheRunningStepFailedAndKeepsTheError() async {
        let recorder = StartRecorder()
        recorder.reportsBeforeGate = [.creatingTab, .waitingForShell]
        recorder.error = TransportError.timedOut
        let store = existingWorkspaceStore(recorder: recorder)
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == .failed("The Host did not answer in time."))
        #expect(steps(store) == [.creatingTab, .waitingForShell])
        #expect(statuses(store) == [.done, .failed])
    }

    @Test func secondSubmitStartsWithAnEmptyStepList() async throws {
        let recorder = StartRecorder()
        recorder.reportsBeforeGate = [.creatingTab, .startingAgent]
        recorder.error = TransportError.timedOut
        let store = existingWorkspaceStore(recorder: recorder)
        await store.discoverAgents()
        await store.submit()
        #expect(store.launchSteps.count == 2)

        let gate = ScriptedTransportCallGate()
        recorder.gate = gate
        recorder.error = nil
        recorder.reportsBeforeGate = []
        let submit = Task { await store.submit() }
        try await waitUntil("the second start should reach the gate") {
            await gate.entryCount == 1
        }
        #expect(store.state == .starting)
        #expect(store.launchSteps.isEmpty)

        await gate.open()
        await submit.value
        #expect(steps(store) == [.opening])
    }

    @Test func shellLaunchReportsItsStepsAndOpensTheShell() async {
        let recorder = StartRecorder()
        recorder.reportsBeforeGate = [.creatingTab, .openingShell]
        let host = Host.fixture()
        let store = existingWorkspaceStore(host: host, recorder: recorder)
        await store.discoverAgents()
        store.launchSelection.wrappedValue = .shell

        await store.submit()

        #expect(store.state == shellStarted(on: host))
        #expect(steps(store) == [.creatingTab, .openingShell, .opening])
        #expect(statuses(store) == [.done, .done, .running])
    }

    /// A replayed Transport call reports its steps again; the store keeps
    /// one entry per step instead of listing the running one twice.
    @Test func aRepeatedStepDoesNotAddARow() async {
        let recorder = StartRecorder()
        recorder.reportsBeforeGate = [
            .gettingLatestMain, .creatingWorktree, .creatingWorktree, .startingAgent, .startingAgent,
        ]
        let store = existingWorkspaceStore(recorder: recorder)
        await store.discoverAgents()
        store.startsInNewWorktree = true

        await store.submit()

        #expect(steps(store) == [.gettingLatestMain, .creatingWorktree, .startingAgent, .opening])
        #expect(statuses(store) == [.done, .done, .done, .running])
    }

    @Test func anUnconfirmedWorktreeFailsTheRunningStepWithItsMessage() async {
        let recorder = StartRecorder()
        recorder.reportsBeforeGate = [.creatingWorktree, .checkingForCreatedWorktree]
        recorder.error = WorktreeLaunchError.createUnconfirmed
        let store = existingWorkspaceStore(recorder: recorder)
        await store.discoverAgents()
        store.startsInNewWorktree = true

        await store.submit()

        #expect(store.state == .failed(WorktreeLaunchError.createUnconfirmed.message))
        #expect(steps(store) == [.creatingWorktree, .checkingForCreatedWorktree])
        #expect(statuses(store) == [.done, .failed])
    }

    /// Opening an Agent that already runs in an adopted worktree is not a
    /// new launch: no launched kind is reported. A launch that started its
    /// own Agent reports it.
    @Test(arguments: [false, true])
    func joiningARunningAgentIsNotANewLaunch(joined: Bool) async {
        let recorder = StartRecorder()
        recorder.reportsBeforeGate =
            joined
            ? [.usingExistingWorktree, .joiningRunningAgent]
            : [.creatingWorktree, .startingAgent]
        let host = Host.fixture()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder)
        await store.discoverAgents()
        store.startsInNewWorktree = true
        store.worktreeBranch = "task/fix"

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(store.launchedAgentKind == (joined ? nil : .claude))
    }

    /// The Review Prompt counts a launch that started its own Agent, once;
    /// a failed or cancelled launch and a joined Agent count nothing.
    enum ReviewOutcome: CaseIterable {
        case success, failure, cancelled, joined
    }

    @Test(arguments: ReviewOutcome.allCases)
    func theReviewPromptCountsOnlyASuccessfulLaunch(_ outcome: ReviewOutcome) async throws {
        let name = "review-start-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let prompts = ReviewPromptStore(defaults: defaults)
        let recorder = StartRecorder()
        switch outcome {
        case .success: break
        case .failure: recorder.error = WorktreeLaunchError.createUnconfirmed
        case .cancelled: recorder.error = CancellationError()
        case .joined: recorder.reportsBeforeGate = [.usingExistingWorktree, .joiningRunningAgent]
        }
        let store = makeStore(
            hosts: [Host.fixture()],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            reviewPrompt: prompts, recorder: recorder)
        await store.discoverAgents()
        if outcome == .joined {
            store.startsInNewWorktree = true
            store.worktreeBranch = "task/fix"
        }

        await store.submit()

        #expect(prompts.state.valueEventCount == (outcome == .success ? 1 : 0))
    }

    @Test func aLaunchWithNoReviewPromptStoreStillStarts() async {
        let host = Host.fixture()
        let store = makeStore(
            hosts: [host], workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: StartRecorder())
        await store.discoverAgents()
        await store.submit()
        #expect(store.state == started(on: host))
    }

    // MARK: herdr | tmux (ADR 0026)

    private static let mixedWorkspaces = [
        ConsoleWorkspace(id: "w1", label: "app"),
        ConsoleWorkspace(id: "tmux:$1", label: "main", backend: .tmux),
    ]

    /// herdr-only Hosts look and launch exactly as before: no switch, no
    /// marks, and every launch leaves routing to the Console.
    @Test func aHerdrOnlyHostOffersNoBackendChoice() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "app")] },
            recorder: recorder)
        await store.discoverAgents()
        #expect(!store.offersBackendChoice)
        #expect(!store.marksAsTmux(ConsoleWorkspace(id: "w1", label: "app")))

        store.applyBrowsedDirectory("/home/you/new-project")
        #expect(!store.offersBackendChoice)
        await store.submit()

        #expect(recorder.backends == [nil])
    }

    /// A tmux-only Host has nothing to choose between and nothing to tell
    /// apart: its sessions are just Workspaces.
    @Test func aTmuxOnlyHostOffersNoBackendChoiceOrMarks() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let session = ConsoleWorkspace(id: "tmux:$1", label: "main", backend: .tmux)
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [session] },
            backends: { _ in [.tmux] },
            defaultBackend: { _ in .tmux },
            recorder: recorder)
        await store.discoverAgents()
        #expect(!store.marksAsTmux(session))

        store.applyBrowsedDirectory("/home/you/new-project")
        #expect(!store.offersBackendChoice)
        await store.submit()

        #expect(recorder.backends == [nil])
    }

    @Test func zellijIsOfferedAfterTmuxAndReceivesTheNewWorkspaceLaunch() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host], backends: { _ in [.herdr, .tmux, .zellij] }, recorder: recorder,
            backendPresence: { _ in HostBackendPresence(herdr: true, tmuxVersion: "3.4",
                zellij: ZellijPresence(version: "0.46.0", path: "/bin/zellij")) })
        await store.discoverAgents()
        #expect(store.launchableBackends == [.herdr, .tmux, .zellij])
        store.applyBrowsedDirectory("/home/you/work")
        store.newWorkspaceBackend = .zellij
        await store.submit()
        #expect(recorder.backends == [.zellij])
    }

    @Test func aDualHostMarksOnlyItsTmuxSessions() async {
        let host = Host.fixture()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in Self.mixedWorkspaces },
            backends: { _ in [.herdr, .tmux] },
            recorder: StartRecorder())

        #expect(!store.marksAsTmux(Self.mixedWorkspaces[0]))
        #expect(store.marksAsTmux(Self.mixedWorkspaces[1]))
    }

    /// The switch is for launches that create a Workspace; an existing one
    /// already decides its backend.
    @Test func aDualHostOffersTheSwitchOnlyForANewWorkspace() async {
        let host = Host.fixture()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in Self.mixedWorkspaces },
            backends: { _ in [.herdr, .tmux] },
            recorder: StartRecorder())
        await store.discoverAgents()
        #expect(!store.offersBackendChoice)

        store.selectNewWorkspace()
        #expect(store.offersBackendChoice)
        #expect(store.hostBackends == [.herdr, .tmux])
        #expect(store.hostBackends.map(\.displayName) == ["Herdr TUI", "tmux"])

        store.selectExistingWorkspace("tmux:$1")
        #expect(!store.offersBackendChoice)
    }

    @Test(arguments: [HostBackend.herdr, .tmux])
    func theSwitchStartsAtTheHostsDefault(_ preference: HostBackend) async {
        let host = Host.fixture()
        let store = makeStore(
            hosts: [host],
            backends: { _ in [.herdr, .tmux] },
            defaultBackend: { _ in preference },
            recorder: StartRecorder())
        store.selectNewWorkspace()

        #expect(store.newWorkspaceBackend == preference)
    }

    @Test(arguments: [HostBackend.herdr, .tmux])
    func aNewWorkspaceAgentLaunchPassesTheChosenBackend(_ chosen: HostBackend) async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            backends: { _ in [.herdr, .tmux] },
            recorder: recorder)
        await store.discoverAgents()
        store.applyBrowsedDirectory("/home/you/new-project")
        store.newWorkspaceBackend = chosen

        await store.submit()

        #expect(recorder.backends == [chosen])
        #expect(recorder.destinations == [
            .newWorkspace(NewWorkspaceSpec(directory: "/home/you/new-project", label: nil))
        ])
    }

    @Test func aNewWorkspaceDefaultShellPassesTheChosenBackend() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            backends: { _ in [.herdr, .tmux] },
            recorder: recorder)
        await store.discoverAgents()
        store.launchSelection.wrappedValue = .shell
        store.applyBrowsedDirectory("/home/you/new-project")
        store.newWorkspaceBackend = .tmux

        await store.submit()

        #expect(recorder.shellParams.count == 1)
        #expect(recorder.backends == [.tmux])
    }

    /// Picking a Workspace picks its backend: the Console routes the launch
    /// by the Workspace's owner, whatever the switch last said.
    @Test func anExistingWorkspaceLaunchLeavesRoutingToTheConsole() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in Self.mixedWorkspaces },
            backends: { _ in [.herdr, .tmux] },
            recorder: recorder)
        await store.discoverAgents()
        store.selectNewWorkspace()
        store.newWorkspaceBackend = .tmux
        store.selectExistingWorkspace("w1")

        await store.submit()

        #expect(recorder.backends == [nil])
        #expect(recorder.params.first?.workspaceID == "w1")
    }

    /// Switching Hosts restores each Host's own remembered launch choice.
    @Test func switchingHostsRestoresTheBackendPick() async {
        let first = Host.fixture()
        let second = Host.fixture()
        let store = makeStore(
            hosts: [first, second],
            backends: { _ in [.herdr, .tmux] },
            recorder: StartRecorder())
        store.selectedHostID = first.id
        store.selectNewWorkspace()
        store.newWorkspaceBackend = .tmux

        store.selectedHostID = second.id
        #expect(store.newWorkspaceBackend == .herdr)
        store.selectedHostID = first.id
        store.selectNewWorkspace()

        #expect(store.newWorkspaceBackend == .tmux)
    }

    @Test func aTmuxRejectionNamesTmux() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let rejection = HerdrAPIError(code: "400", message: "duplicate session")
        recorder.error = rejection
        let store = makeStore(
            hosts: [host],
            backends: { _ in [.herdr, .tmux] },
            recorder: recorder)
        await store.discoverAgents()
        store.applyBrowsedDirectory("/home/you/new-project")
        store.newWorkspaceBackend = .tmux

        await store.submit()

        guard case .failed(let message) = store.state else {
            Issue.record("expected .failed, got \(String(describing: store.state))")
            return
        }
        #expect(message.contains(HostBackend.tmux.displayName))
        #expect(!message.contains(HostBackend.herdr.displayName))
        #expect(message.contains(rejection.message))
    }

    nonisolated private static let fixPrompt = "Fix AI Usage on Studio"
    nonisolated private static let fixFile = LaunchPromptFile(
        destination: .stageDirectory, name: LaunchPromptStager.initialPromptFileName, contents: fixPrompt)
    nonisolated private static let fixPointer = "Read and follow \(FakeLaunchPromptHost.path(for: fixFile))"

    /// A preset like the Keychain Fix's; `hostID` nil keeps the usual Host.
    private static func preset(
        hostID: Host.ID? = nil, locksHost: Bool = false, suggestedName: String? = nil,
        firstMessage: String = fixPrompt
    ) -> AgentLaunchPreset {
        AgentLaunchPreset(
            title: "Fix AI Usage", hostID: hostID, locksHost: locksHost, suggestedName: suggestedName,
            attachmentTitle: "Fix instructions", firstMessage: firstMessage)
    }

    /// A preset preselects its Host over Last Used and its name as if typed,
    /// leaves the rest at the usual defaults, and starts nothing on its own.
    @Test func aPresetPrefillsItsHostAndNameButDoesNotStart() async {
        let other = Host.fixture()
        let target = Host.fixture()
        let recorder = StartRecorder()
        let selections = makeSelections()
        selections.remember(hostID: other.id, kind: .codex)
        let store = makeStore(
            hosts: [other, target],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [.claude, .codex] },
            selections: selections,
            recorder: recorder,
            preset: Self.preset(hostID: target.id, suggestedName: "Help: Mosh"))
        #expect(store.selectedHostID == target.id)
        #expect(store.name == "help-mosh")

        await store.discoverAgents()
        await store.runQuickChat()

        #expect(recorder.params.isEmpty)
        #expect(store.state == .editing)
        #expect(store.selectedAgentKind == .codex, "the remembered kind takes a first message")
        #expect(store.selectedWorkspaceID == "w1")
        #expect(store.launchTarget == .existingWorkspace)
        #expect(!store.startsInNewWorktree)
        #expect(!store.chatMode)
        #expect(!store.showsChatModeToggle)
        #expect(store.canSubmit)
    }

    /// A suggested name an Agent on the Host already has is bumped while the
    /// user leaves it alone, follows the Host when it changes, and is
    /// submitted unique; a name the user typed is theirs.
    @Test func aTakenSuggestedNameIsMadeUniqueOnItsHost() async throws {
        let busy = Host.fixture()
        let free = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [busy, free],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            existingAgentNames: { hostID in hostID == busy.id ? ["help-mosh", "help-mosh-2"] : [] },
            recorder: recorder,
            preset: Self.preset(hostID: busy.id, suggestedName: "help-mosh"))
        #expect(store.name == "help-mosh-3")

        store.hostSelection.wrappedValue = free.id
        #expect(store.name == "help-mosh")
        store.hostSelection.wrappedValue = busy.id
        #expect(store.name == "help-mosh-3")

        await store.discoverAgents()
        await store.submit()
        let request = try #require(recorder.params.first)
        #expect(request.name == "help-mosh-3")

        let typed = makeStore(
            hosts: [busy, free],
            existingAgentNames: { _ in ["help-mosh"] },
            recorder: StartRecorder(),
            preset: Self.preset(hostID: free.id, suggestedName: "help-mosh"))
        typed.name = "mine"
        typed.hostSelection.wrappedValue = busy.id
        #expect(typed.name == "mine")
    }

    /// The Keychain Fix's name, taken by a fix Agent still running, is
    /// submitted as another name rather than failing at Start.
    /// The name is taken only after the sheet opened (the Host's inventory
    /// arrived late), so only the Start-time check can catch it.
    @Test func aPresetSubmitsAFreeNameWhenItsSuggestionIsTaken() async throws {
        final class NamesBox { var names: Set<String> = [] }
        let taken = NamesBox()
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            existingAgentNames: { _ in taken.names },
            recorder: recorder,
            preset: Self.preset(hostID: host.id, locksHost: true, suggestedName: "fix-ai-usage"))
        #expect(store.name == "fix-ai-usage")
        await store.discoverAgents()
        taken.names.insert("fix-ai-usage")
        await store.submit()
        let request = try #require(recorder.params.first)
        #expect(request.name != "fix-ai-usage")
        #expect(request.name == "fix-ai-usage-2")
    }

    /// A suffix never pushes the name past herdr's 32 characters.
    @Test func aSuffixedSuggestionStaysWithinTheNameLimit() {
        let base = String(repeating: "a", count: 31) + "b"
        let unique = StartAgentStore.uniqueSuggestedName(base, taken: [base])
        #expect(unique == String(repeating: "a", count: 30) + "-2")
        #expect(AgentName.validationError(unique) == nil)
    }

    /// A preset is never auto-started, even when New Chat defaults that
    /// would resolve are passed along with it.
    @Test func aPresetNeverArmsQuickChat() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder,
            preset: Self.preset(hostID: host.id),
            quickChat: NewChatPreferences(
                destination: ChatDestination(
                    hostID: host.id, workspaceID: "w1", workspaceLabel: "Proj", cwd: "/work/w1"),
                kind: .claude))
        #expect(!store.isQuickChat)
        #expect(!store.chatMode)

        await store.discoverAgents()
        await store.runQuickChat()

        #expect(recorder.params.isEmpty)
        #expect(store.state == .editing)
    }

    /// A locked Host stays put whatever the Host picker writes.
    @Test func aLockedHostIgnoresTheHostPicker() {
        let other = Host.fixture()
        let target = Host.fixture()
        let store = makeStore(
            hosts: [other, target], recorder: StartRecorder(),
            preset: Self.preset(hostID: target.id, locksHost: true))
        #expect(store.locksHost)
        #expect(store.lockedHost?.id == target.id)

        store.hostSelection.wrappedValue = other.id
        #expect(store.selectedHostID == target.id)
        store.hostSelection.wrappedValue = nil
        #expect(store.selectedHostID == target.id)
    }

    /// An unlocked preset Host is only a default, and a preset Host that is
    /// gone neither applies nor locks: the sheet falls back to Last Used.
    @Test func anUnlockedOrMissingPresetHostStaysTheUsersChoice() {
        let other = Host.fixture()
        let target = Host.fixture()
        let selections = makeSelections()
        selections.remember(hostID: other.id, kind: .claude)
        let unlocked = makeStore(
            hosts: [other, target], selections: selections, recorder: StartRecorder(),
            preset: Self.preset(hostID: target.id))
        #expect(unlocked.selectedHostID == target.id)
        #expect(!unlocked.locksHost)
        unlocked.hostSelection.wrappedValue = other.id
        #expect(unlocked.selectedHostID == other.id)

        let missing = makeStore(
            hosts: [other, target], selections: selections, recorder: StartRecorder(),
            preset: Self.preset(hostID: Host.fixture().id, locksHost: true))
        #expect(missing.selectedHostID == other.id)
        #expect(!missing.locksHost)
        #expect(missing.lockedHost == nil)
    }

    /// A preset offers every detected kind, never Default Shell, and keeps
    /// the remembered kind: one with no first-message flag gets the first
    /// message from its Composer.
    @Test func aPresetOffersEveryDetectedKind() async {
        let host = Host.fixture()
        let selections = makeSelections()
        selections.remember(hostID: host.id, kind: .amp)
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [.amp, .copilot, .opencode, .claude] },
            selections: selections,
            recorder: StartRecorder(),
            preset: Self.preset())
        await store.discoverAgents()

        #expect(store.availableAgentKinds == [.amp, .copilot, .opencode, .claude])
        #expect(store.selectedAgentKind == .amp)
        #expect(!store.offersShell)
        store.launchSelection.wrappedValue = .shell
        #expect(!store.selectedLaunchIsShell)
        store.launchSelection.wrappedValue = .agent(.copilot)
        #expect(store.selectedAgentKind == .copilot)
        #expect(store.canSubmit)
    }

    /// Default Shell as the last choice still opens a preset on an Agent.
    @Test func aPresetNeverPreselectsDefaultShell() async {
        let host = Host.fixture()
        let selections = makeSelections()
        selections.rememberShell(hostID: host.id)
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            selections: selections,
            recorder: StartRecorder(),
            preset: Self.preset())
        await store.discoverAgents()

        #expect(!store.selectedLaunchIsShell)
        #expect(store.selectedAgentKind == .claude)
        #expect(store.canSubmit)
    }

    /// A Host with no Agent offers none to a preset, which has no Default
    /// Shell either, so it can't start.
    @Test func aPresetOnAHostWithNoAgentCannotStart() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [] },
            recorder: recorder,
            preset: Self.preset())
        await store.discoverAgents()

        #expect(store.agentDiscoveryState == .loaded)
        #expect(store.availableAgentKinds.isEmpty)
        #expect(store.selectedAgentKind == nil)
        #expect(!store.canSubmit)
        await store.submit()
        #expect(recorder.params.isEmpty)
    }

    /// The Keychain Fix: Start launches on the locked Host with the
    /// suggested name, hands the Agent the fix prompt as the Launch Prompt
    /// File it reads and follows, is not Chat Mode (no Chat Prompt) though
    /// Chat Mode was last on, and leaves Last Used as it was.
    @Test func startingAPresetHandsItsAgentTheFirstMessageAndLeavesLastUsed() async throws {
        let other = Host.fixture()
        let target = Host.fixture()
        let recorder = StartRecorder()
        let promptHost = FakeLaunchPromptHost()
        let blocked = AIUsageProvider(
            id: "claude", providerID: "claude", displayName: "Claude", account: nil,
            windows: [], errorMessage: "No Claude session key found in browser cookies.")
        let prompt = CodexBarKeychainFix.agentPrompt(
            hostName: "Studio", problem: .keychainBlocked, providers: [blocked],
            codexBarPath: "/opt/homebrew/bin/codexbar")
        let lastChat = ChatDestination(
            hostID: other.id, workspaceID: "o1", workspaceLabel: "Elsewhere", cwd: "/work/o1")
        let selections = makeSelections()
        selections.remember(hostID: other.id, kind: .codex)
        selections.rememberChat(destination: lastChat, kind: .codex)
        selections.rememberChatMode(true)
        let recents = makeRecents()
        let store = StartAgentStore(
            hosts: [other, target],
            workspaces: { hostID in
                hostID == target.id
                    ? [ConsoleWorkspace(id: "w1", label: "Proj")]
                    : [ConsoleWorkspace(id: "o1", label: "Elsewhere")]
            },
            existingAgentNames: { _ in [] },
            discoverAgentKinds: { _ in [.claude] },
            remoteHome: { _ in "/home/you" },
            start: { params, destination, hostID, backend in
                try await recorder.record(params, destination, hostID, backend)
            },
            awaitAgentVisible: { _ in },
            recents: recents,
            selections: selections,
            chatOptions: { _ in ChatModeLaunchOptions(prompt: "Reply briefly.", quickThinking: false) },
            launchPromptHost: { _ in promptHost.host },
            preset: AgentLaunchPreset(
                title: "Fix AI Usage", hostID: target.id, locksHost: true,
                suggestedName: "fix-ai-usage", attachmentTitle: "Fix instructions",
                firstMessage: prompt))
        #expect(store.selectedHostID == target.id)
        #expect(!store.chatMode)

        await store.discoverAgents()
        await store.submit()

        #expect(recorder.hostIDs == [target.id])
        let request = try #require(recorder.params.first)
        #expect(request.kind == "claude")
        #expect(request.name == "fix-ai-usage")
        #expect(request.workspaceID == "w1")
        let firstMessage = try #require(
            await promptHost.stagedFiles.first(where: { $0.name == LaunchPromptStager.initialPromptFileName }))
        #expect(firstMessage.contents == prompt)
        #expect(
            Array(request.arguments.suffix(2))
                == ["--", "Read and follow \(FakeLaunchPromptHost.path(for: firstMessage))"],
            "claude takes its first message positionally, after end of options")
        #expect(!request.arguments.contains(prompt))
        #expect(await !promptHost.stagedFiles.contains { $0.name == LaunchPromptStager.chatPromptFileName })
        #expect(store.state == started(on: target))
        #expect(!store.launchedChat)
        #expect(selections.lastHostID == other.id)
        #expect(selections.lastAgentKind == .codex)
        #expect(selections.lastChatDestination == lastChat)
        #expect(selections.lastChatKind == .codex)
        #expect(selections.chatMode)
        #expect(recents.workspaceID(for: target.id) == nil)
    }

    /// The first message goes after every flag, as a pointer at the file
    /// holding it, in the form each kind starts its first message from; the
    /// user's own arguments stay ahead of it.
    @Test(arguments: [
        (SupportedAgentKind.codex, ["--", Self.fixPointer]),
        (.omp, [Self.fixPointer]),
        (.pi, [Self.fixPointer]),
        (.opencode, ["--prompt", Self.fixPointer]),
    ])
    func aPresetsFirstMessageFollowsTheUsersArguments(
        kind: SupportedAgentKind, promptTail: [String]
    ) async throws {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let promptHost = FakeLaunchPromptHost()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [kind] },
            recorder: recorder,
            preset: Self.preset(),
            promptHost: promptHost)
        await store.discoverAgents()
        #expect(store.selectedAgentKind == kind)
        store.arguments = "--model x"

        await store.submit()

        #expect(store.state == started(on: host))
        let request = try #require(recorder.params.first)
        #expect(request.kind == kind.rawValue)
        #expect(!request.arguments.contains { $0.contains(Self.fixPrompt) })
        // pi also pins its session, ahead of the user's arguments.
        let pin = kind == .pi ? Array(request.arguments.prefix(2)) : []
        #expect(pin.first.map { $0 == "--session-id" } ?? true)
        #expect(request.arguments == pin + ["--model", "x"] + promptTail)
        #expect(await promptHost.stagedFiles == [Self.fixFile])
    }

    /// A kind with no first-message flag (copilot -i hangs its hooks,
    /// copilot.md §6) starts without it on its line or a file for it, and
    /// its Composer queues it for the Agent the launch started.
    @Test(arguments: [SupportedAgentKind.copilot, .amp])
    func aPresetsFirstMessageGoesToTheComposerForAKindWithNoFlag(kind: SupportedAgentKind) async throws {
        let host = Host.fixture()
        let recorder = StartRecorder()
        recorder.agent = Agent(.fixture(paneID: "w1:pnew", kind: "unknown"))
        let promptHost = FakeLaunchPromptHost()
        let launchMessages = LaunchMessageRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [kind] },
            recorder: recorder,
            preset: Self.preset(),
            promptHost: promptHost,
            launchMessages: launchMessages)
        await store.discoverAgents()

        await store.submit()

        #expect(store.state == started(on: host))
        let request = try #require(recorder.params.first)
        #expect(!request.arguments.contains { $0.contains("Read and follow") || $0.contains(Self.fixPrompt) })
        #expect(await !promptHost.stagedFiles.contains { $0.name == LaunchPromptStager.initialPromptFileName })
        #expect(launchMessages.messages.count == 1)
        let queued = try #require(launchMessages.messages.first)
        #expect(queued.text == Self.fixPrompt)
        #expect(queued.agent == QueuedMessage.AgentIdentity(paneID: "w1:pnew", kind: kind.rawValue, session: nil))
        #expect(queued.hostID == host.id)
    }

    /// A kind that takes its first message on the launch line gets nothing
    /// queued; neither does a launch without a preset.
    @Test func aFirstMessageOnTheLaunchLineQueuesNothing() async throws {
        let host = Host.fixture()
        let launchMessages = LaunchMessageRecorder()
        let withFlag = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: StartRecorder(),
            preset: Self.preset(),
            launchMessages: launchMessages)
        await withFlag.discoverAgents()
        await withFlag.submit()
        #expect(withFlag.state == started(on: host))

        let plain = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            agentKinds: { _ in [.copilot] },
            recorder: StartRecorder(),
            launchMessages: launchMessages)
        await plain.discoverAgents()
        await plain.submit()
        #expect(plain.state == started(on: host))
        #expect(launchMessages.messages.isEmpty)
    }

    /// The first message travels in a file, so it keeps its lines: nothing
    /// on the launch line has to be one line any more.
    @Test func aPresetsFirstMessageReachesTheHostVerbatim() async throws {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let promptHost = FakeLaunchPromptHost()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder,
            preset: Self.preset(firstMessage: "Fix\n\tthis  now"),
            promptHost: promptHost)
        await store.discoverAgents()

        await store.submit()

        let request = try #require(recorder.params.first)
        #expect(request.kind == "claude")
        #expect(await promptHost.stagedFiles.map(\.contents) == ["Fix\n\tthis  now"])
        #expect(request.arguments.allSatisfy { !$0.contains("\n") && !$0.contains("\t") })
    }

    /// A first message the Host can't take fails the launch: the Agent never
    /// starts without it.
    @Test func aFailedFirstMessageWriteFailsTheLaunch() async throws {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Proj")] },
            recorder: recorder,
            preset: Self.preset(),
            promptHost: FakeLaunchPromptHost(failure: LaunchPromptStagingError.writeFailed))
        await store.discoverAgents()

        await store.submit()

        #expect(recorder.params.isEmpty)
        guard case .failed(let message) = store.state else {
            Issue.record("expected .failed, got \(String(describing: store.state))")
            return
        }
        #expect(message.contains(host.displayName))
    }

    // MARK: Hosts with no usable backend (WAY-338)

    /// The presence the Console last detected on a Host, which a test changes
    /// the way an install or Check Again does.
    @MainActor
    private final class PresenceBox {
        var presence: HostBackendPresence?
        init(_ presence: HostBackendPresence?) { self.presence = presence }
    }

    private static let neither = HostBackendPresence(herdr: false, tmuxVersion: nil)
    private static let herdrFound = HostBackendPresence(herdr: true, tmuxVersion: nil)

    @Test func startStaysOffUntilTheRecheckFindsABackend() async {
        let host = Host.fixture()
        let box = PresenceBox(Self.neither)
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Existing")] },
            recorder: StartRecorder(), backendPresence: { _ in box.presence })
        await store.discoverAgents()
        // Everything else the form needs is in place.
        #expect(store.agentDiscoveryState == .loaded)
        #expect(store.selectedAgentKind == .claude)

        #expect(store.backendGap == .noBackend)
        #expect(!store.canSubmit)

        box.presence = HostBackendPresence(herdr: false, tmuxVersion: "3.0")
        #expect(store.backendGap == .tmuxTooOld(found: "3.0"))
        #expect(!store.canSubmit)

        box.presence = Self.herdrFound
        #expect(store.backendGap == nil)
        #expect(store.canSubmit)
    }

    @Test func tmuxAtTheFloorIsNoGapAndAnUndetectedHostIsNone() async {
        let host = Host.fixture()
        let box = PresenceBox(HostBackendPresence(herdr: false, tmuxVersion: "3.2a"))
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Existing")] },
            recorder: StartRecorder(), backendPresence: { _ in box.presence })
        await store.discoverAgents()
        #expect(store.backendGap == nil)
        #expect(store.canSubmit)

        // Never detected: the form behaves as it did before this panel.
        box.presence = nil
        #expect(store.backendGap == nil)
    }

    @Test func aSubmitOnAHostWithNoBackendLaunchesNothing() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Existing")] },
            recorder: recorder, backendPresence: { _ in Self.neither })
        await store.discoverAgents()

        // Quick chat submits without the Start button.
        await store.submit()

        #expect(recorder.params.isEmpty)
        #expect(recorder.shellParams.isEmpty)
        #expect(store.state == .editing)
    }

    @Test func anOriginLaunchHasNoGapBecauseItsAgentProvesABackend() {
        let host = Host.fixture()
        let store = makeStore(
            hosts: [host],
            origin: StartAgentStore.LaunchOrigin(hostID: host.id, workspaceID: "w1", cwd: "/work"),
            recorder: StartRecorder(), backendPresence: { _ in Self.neither })

        #expect(store.backendGap == nil)
    }

    @Test func aFoundBackendWithNoWorkspaceAimsTheLaunchAtANewWorkspace() async {
        let host = Host.fixture()
        let box = PresenceBox(Self.neither)
        let store = makeStore(
            hosts: [host], recorder: StartRecorder(), backendPresence: { _ in box.presence })
        await store.discoverAgents()
        #expect(store.launchTarget == .existingWorkspace)
        #expect(!store.canSubmit)

        box.presence = Self.herdrFound
        await store.backendFound()

        #expect(store.launchTarget == .newWorkspace)
        #expect(store.foundBackend == .herdr)
        #expect(store.canSubmit)
    }

    @Test func findingOnlyHerdrCoreReportsHerdrCoreNotTmux() async {
        let host = Host.fixture()
        let presence = HostBackendPresence(herdr: false, tmuxVersion: nil,
            core: .init(version: "0.1.14", path: "/bin/herdr-core"))
        let store = makeStore(
            hosts: [host], backends: { _ in [.core] }, defaultBackend: { _ in .core },
            recorder: StartRecorder(), backendPresence: { _ in presence })
        await store.backendFound()
        #expect(store.foundBackend == .core)
        #expect(store.launchTarget == .newWorkspace)
        #expect(store.canSubmit)
    }

    @Test func findingOnlyZellijReportsZellijNotTmux() async {
        let host = Host.fixture()
        let presence = HostBackendPresence(herdr: false, tmuxVersion: nil,
            zellij: .init(version: "0.46.0", path: "/bin/zellij"))
        let store = makeStore(
            hosts: [host], backends: { _ in [.zellij] }, defaultBackend: { _ in .zellij },
            recorder: StartRecorder(), backendPresence: { _ in presence })
        await store.backendFound()
        #expect(store.foundBackend == .zellij)
        #expect(store.launchTarget == .newWorkspace)
        #expect(store.canSubmit)
    }

    @Test func aFoundBackendLeavesAWorkspaceTheUserPickedAlone() async {
        let host = Host.fixture()
        let box = PresenceBox(Self.neither)
        let store = makeStore(
            hosts: [host],
            workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "Existing")] },
            recorder: StartRecorder(), backendPresence: { _ in box.presence })
        await store.discoverAgents()
        box.presence = Self.herdrFound

        await store.backendFound()

        #expect(store.launchTarget == .existingWorkspace)
        #expect(store.selectedWorkspaceID == "w1")
        #expect(store.foundBackend == .herdr)
    }

    /// The Console restarts the Host's connection as it records the find, so
    /// the first detection can land on the connection that is going away.
    @Test func aFoundBackendDetectsAgentsAgainWhileTheConnectionRestarts() async {
        let host = Host.fixture()
        let box = PresenceBox(Self.neither)
        let calls = CallCounter()
        let store = makeStore(
            hosts: [host],
            agentKinds: { _ in
                // Fail twice, as the old connection and the restarting one.
                if calls.next() <= 2 {
                    throw TransportError.socketNotFound(path: "~/.config/herdr/herdr.sock")
                }
                return [.claude]
            },
            recorder: StartRecorder(), backendPresence: { _ in box.presence })
        box.presence = Self.herdrFound

        await store.backendFound()

        #expect(calls.count == 3)
        #expect(store.agentDiscoveryState == .loaded)
        #expect(store.selectedAgentKind == .claude)
        #expect(store.canSubmit)
    }

    @Test func aDetectionThatKeepsFailingIsLeftForTheUsersRetry() async {
        let host = Host.fixture()
        let calls = CallCounter()
        let store = makeStore(
            hosts: [host],
            agentKinds: { _ in
                _ = calls.next()
                throw TransportError.socketNotFound(path: "~/.config/herdr/herdr.sock")
            },
            recorder: StartRecorder(), backendPresence: { _ in Self.herdrFound })

        await store.backendFound()

        #expect(calls.count == 5)
        guard case .failed = store.agentDiscoveryState else {
            Issue.record("expected a failed detection, got \(store.agentDiscoveryState)")
            return
        }
        #expect(!store.canSubmit)
    }

    /// Counts the detections a store asked for; `agentKinds` closures are
    /// `@Sendable`-free here, so a plain main-actor box suffices.
    @MainActor
    private final class CallCounter {
        private(set) var count = 0
        func next() -> Int {
            count += 1
            return count
        }
    }

    @Test func theFoundNoteEndsWhenTheHostChanges() async {
        let first = Host.fixture()
        let second = Host.fixture()
        let box = PresenceBox(Self.neither)
        let store = makeStore(
            hosts: [first, second], recorder: StartRecorder(),
            backendPresence: { _ in box.presence })
        store.selectedHostID = first.id
        await store.discoverAgents()
        box.presence = Self.herdrFound
        await store.backendFound()
        #expect(store.foundBackend == .herdr)

        store.selectedHostID = second.id

        #expect(store.foundBackend == nil)
    }

    // MARK: herdr-core (ADR 0031)

    private static let coreWorkspace = ConsoleWorkspace(
        id: "core:/srv", label: "srv", backend: .core)

    @Test func runtimeChoiceIncludesAllBackendsAndPersistsPerHost() async {
        let host = Host.fixture()
        let other = Host.fixture()
        let workspace = ConsoleWorkspace(id: "herdr:one", label: "One", backend: .herdr)
        let recorder = StartRecorder()
        let recents = makeRecents()
        let store = makeStore(
            hosts: [host, other], workspaces: { _ in [workspace, Self.coreWorkspace] },
            recents: recents, backends: { _ in [.tmux, .core, .herdr] },
            defaultBackend: { _ in .herdr }, recorder: recorder)
        store.selectedHostID = host.id
        await store.discoverAgents()
        #expect(!store.offersBackendChoice)
        store.selectNewWorkspace()
        #expect(store.offersBackendChoice)
        #expect(store.hostBackends == [.herdr, .core, .tmux])
        #expect(store.hostBackends.map(\.displayName) == ["Herdr TUI", "Herdr Core", "tmux"])
        store.selectedLaunchIsShell = true
        store.newWorkspaceBackend = .core
        #expect(!store.selectedLaunchIsShell)
        #expect(store.formTargetBackend == .core)
        #expect(store.launchesIntoFolder)
        #expect(!store.offersShell)
        #expect(!store.offersWorktree)
        #expect(store.workspaces.map(\.id) == [workspace.id, Self.coreWorkspace.id])
        store.selectedHostID = other.id
        #expect(store.newWorkspaceBackend == .herdr)
        store.selectedHostID = host.id
        #expect(store.newWorkspaceBackend == .core)
        await store.discoverAgents()
        store.selectNewWorkspace()
        store.newWorkspaceDirectory = "/srv/new"
        await store.submit()
        #expect(recorder.backends == [.core])
        store.newWorkspaceBackend = .tmux
        #expect(recents.backend(for: host.id) == .tmux)
        let reopened = makeStore(
            hosts: [host], workspaces: { _ in [workspace, Self.coreWorkspace] },
            recents: recents, backends: { _ in [.herdr, .core, .tmux] },
            defaultBackend: { _ in .herdr }, recorder: StartRecorder())
        reopened.selectedHostID = host.id
        reopened.selectNewWorkspace()
        #expect(reopened.newWorkspaceBackend == .tmux)
        reopened.selectExistingWorkspace(workspace.id)
        #expect(!reopened.offersBackendChoice)
        #expect(reopened.formTargetBackend == .herdr)
        reopened.selectExistingWorkspace(Self.coreWorkspace.id)
        #expect(reopened.formTargetBackend == .core)
        // Moving the destination onto a core Workspace drops a stale
        // Default Shell pick (review P2): core takes no shell launch.
        reopened.selectExistingWorkspace(workspace.id)
        reopened.selectedLaunchIsShell = true
        reopened.selectExistingWorkspace(Self.coreWorkspace.id)
        #expect(!reopened.selectedLaunchIsShell)
    }

    /// A core-only Host asks for a kind and folder, without a worktree or shell.
    @Test func aCoreOnlyHostStartsAKindInAFolder() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host], workspaces: { _ in [Self.coreWorkspace] },
            backends: { _ in [.core] }, defaultBackend: { _ in .core },
            recorder: recorder)
        store.selectedHostID = host.id
        await store.discoverAgents()
        store.selectExistingWorkspace(Self.coreWorkspace.id)

        #expect(store.formTargetBackend == .core)
        #expect(store.launchesIntoFolder)
        #expect(store.canSubmit)
        #expect(!store.offersWorktree)
        #expect(!store.offersShell)
        #expect(store.offersNewWorkspace)
        #expect(!store.listsBothBackends)
        #expect(store.hostBackends == [.core])
        #expect(!store.offersBackendChoice)

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(recorder.params.map(\.workspaceID) == [Self.coreWorkspace.id])
        #expect(recorder.destinations == [.existingWorkspace])
    }

    /// A folder nobody is in yet: the launch carries the folder and no
    /// name, even when the Workspace name field held text from another
    /// backend's choice.
    @Test func aCoreFolderLaunchCarriesNoWorkspaceName() async {
        let host = Host.fixture()
        let recorder = StartRecorder()
        let store = makeStore(
            hosts: [host], workspaces: { _ in [] },
            backends: { _ in [.core] }, defaultBackend: { _ in .core }, recorder: recorder)
        store.selectedHostID = host.id
        await store.discoverAgents()
        #expect(store.launchesIntoFolder)
        store.selectNewWorkspace()
        store.newWorkspaceDirectory = "/srv/new"
        store.newWorkspaceLabel = "Leftover"

        await store.submit()

        #expect(store.state == started(on: host))
        #expect(
            recorder.destinations
                == [.newWorkspace(NewWorkspaceSpec(directory: "/srv/new", label: nil))])
    }

    /// A core Host that runs nothing yet reports no Workspace: the sheet
    /// still shows a kind and a folder only (home until chosen), with no
    /// worktree or Default Shell, and Start is on.
    @Test func anEmptyCoreHostStartsInAFolderWithNoOtherOptions() async {
        let host = Host.fixture()
        let store = makeStore(
            hosts: [host], workspaces: { _ in [] },
            backends: { _ in [.core] }, defaultBackend: { _ in .core },
            recorder: StartRecorder())
        store.selectedHostID = host.id
        await store.discoverAgents()

        #expect(store.launchTarget == .newWorkspace)
        #expect(store.launchesIntoFolder)
        #expect(store.hostBackends == [.core])
        #expect(!store.offersBackendChoice)
        #expect(!store.offersWorktree)
        #expect(!store.offersShell)
        #expect(store.canSubmit)
    }

    /// A core Host with tmux: the switch reads herdr-core | tmux, and only a
    /// launch that lands on core drops the worktree option and Default Shell.
    @Test func aCoreHostWithTmuxOffersEachBackendItsOwnOptions() async {
        let host = Host.fixture()
        let tmuxSession = ConsoleWorkspace(id: "tmux:$1", label: "main", backend: .tmux)
        let store = makeStore(
            hosts: [host], workspaces: { _ in [Self.coreWorkspace, tmuxSession] },
            backends: { _ in [.core, .tmux] }, defaultBackend: { _ in .core },
            recorder: StartRecorder())
        store.selectedHostID = host.id
        await store.discoverAgents()
        #expect(store.listsBothBackends)
        #expect(store.offersNewWorkspace)
        #expect(store.marksAsTmux(tmuxSession))
        #expect(!store.marksAsTmux(Self.coreWorkspace))

        store.selectNewWorkspace()
        #expect(store.offersBackendChoice)
        #expect(store.newWorkspaceBackend == .core)
        #expect(store.launchesIntoFolder)
        #expect(!store.offersShell)

        store.newWorkspaceBackend = .tmux
        #expect(!store.launchesIntoFolder)
        #expect(store.offersShell)

        store.selectExistingWorkspace(tmuxSession.id)
        #expect(store.offersWorktree)
        store.selectExistingWorkspace(Self.coreWorkspace.id)
        #expect(!store.offersWorktree)
        #expect(store.launchesIntoFolder)
    }

    @Test func herdrAndTmuxHostsKeepTheirOptions() async {
        let host = Host.fixture()
        let store = makeStore(
            hosts: [host], workspaces: { _ in [ConsoleWorkspace(id: "w1", label: "app")] },
            recorder: StartRecorder())
        store.selectedHostID = host.id
        await store.discoverAgents()
        store.selectExistingWorkspace("w1")

        #expect(!store.launchesIntoFolder)
        #expect(store.offersShell)
        #expect(store.offersWorktree)
        #expect(store.offersNewWorkspace)
    }

    /// A core launch's failures are worded for the user, with no
    /// "herdr-core rejected the command" in front.
    @Test func coreLaunchFailuresReadPlainly() {
        let missing = HerdrAPIError(
            code: "agent_start_failed", message: CoreLaunch.notInstalledMessage(kind: "claude"))
        #expect(
            StartAgentStore.message(for: missing, launchedKind: .claude, backend: .core)
                == "claude is not installed on this Host, or is not on its PATH")
        let folder = HerdrAPIError(
            code: "folder_not_found", message: "/nope is not a folder on this Host.")
        #expect(
            StartAgentStore.message(for: folder, launchedKind: .claude, backend: .core)
                == "/nope is not a folder on this Host.")
    }
}
