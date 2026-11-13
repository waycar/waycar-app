import Foundation
import Testing

@testable import Waycar

/// The harness lab conformance suite (#172): the app's own launch builders,
/// Transports, Closed Session resume and chat transcript reader driving the
/// real harnesses in `scripts/harness-lab`, on both backends, against the
/// lab's mock model server. One parameterized case per kind × backend.
///
/// Runs only through `make test-harness-lab` (`scripts/harness-lab/run-e2e.sh`),
/// which puts `WAYCAR_HARNESS_LAB_CONFIG` into the Simulator; everywhere else
/// the suite is disabled. Every case starts and ends with the lab reset
/// (`scripts/harness-lab/e2e-reset.sh`), which closes only what carries
/// `HarnessLabEnvironment.labelPrefix`.
///
/// Each case, for a kind the lab can sign in:
/// 1. launch: Chat Mode where the build offers it (model, Quick thinking,
///    Chat Prompt, first message from the kind's case in
///    `plugin/test-vectors/harness-launch-v1.json`), built by
///    `LaunchPromptStager.launchCommand` and started in a new Workspace,
///    or, for a kind with no first-message flag, sent from an Agent
///    Composer's queue (`HarnessLabLaunchComposer`), exactly once; the mock
///    log shows the first message with the vector's model, effort and Chat
///    Prompt marker;
/// 2. a plain turn: idle → working → done, its prompt in the mock log;
/// 3. a tool turn: blocked → approve → working → done where the lab can
///    make the kind ask (`HarnessLabProfile`), the tool result in the mock
///    log, and a relay push for blocked and for done (the plugin's
///    push-worthiness decision, observed at a mock relay);
/// 4. the chat transcript through the app's reader: the turns for a Chat
///    Mode kind, `unsupported` for any other;
/// 5. close, then resume through `ClosedSessionResumer`: the resumed
///    session's next request carries the earlier turns.
/// For cursor, kiro and devin (account-only) the case checks the sign-in
/// screen instead: recognized, and a prompt refused without typing.
@Suite(
    "Harness lab e2e",
    .enabled(
        if: HarnessLabEnvironment.current != nil,
        "requires the harness lab: make test-harness-lab"),
    .serialized)
struct HarnessLabE2ETests {
    /// A KINDS or BACKENDS entry the matrix cannot hold (`antigravity` for
    /// `agy`, a typo) would otherwise run fewer cases, or none, and pass.
    @Test("the configured kinds and backends all name a lab case")
    func configurationNamesOnlyLabCases() throws {
        let environment = try #require(HarnessLabEnvironment.current)
        #expect(
            environment.unknownEntries.isEmpty,
            "not lab kinds or backends: \(environment.unknownEntries); kinds are \(HarnessLabProfile.labKinds.map(\.rawValue))")
        #expect(!HarnessLabCase.matrix.isEmpty, "the configuration selects no lab case")
    }

    @Test(
        "a lab harness launches, works, asks, keeps a transcript, resumes and notifies",
        .timeLimit(.minutes(12)),
        arguments: HarnessLabCase.matrix)
    func harness(_ labCase: HarnessLabCase) async throws {
        let environment = try #require(HarnessLabEnvironment.current)
        let started = ContinuousClock.now
        defer { print("harness lab case \(labCase.testDescription): finished in \(ContinuousClock.now - started)") }
        let host = try await HarnessLabHost.open(environment)
        let outcome: Result<Void, any Error>
        do {
            try await host.reset()
            let transport = try await environment.connect(labCase.backend)
            let run = try await HarnessLabRun(
                labCase: labCase, environment: environment, host: host, transport: transport)
            do {
                try await run.execute()
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            await run.cleanUp()
            try? await transport.close()
        } catch {
            outcome = .failure(error)
        }
        _ = try? await host.reset()
        await host.close()
        try outcome.get()
    }
}

/// One kind on one backend.
struct HarnessLabCase: Sendable, CustomTestStringConvertible, CustomStringConvertible {
    let kind: SupportedAgentKind
    let backend: HostBackend

    var testDescription: String { "\(kind.rawValue) on \(backend.rawValue)" }
    var description: String { testDescription }

    /// The configured kinds × backends; every lab kind on both when the lab
    /// is not configured (the suite is disabled then).
    static var matrix: [HarnessLabCase] {
        let environment = HarnessLabEnvironment.current
        let kinds = environment?.kinds ?? HarnessLabProfile.labKinds
        let backends = environment?.backends ?? [.herdr, .tmux]
        return kinds.flatMap { kind in backends.map { HarnessLabCase(kind: kind, backend: $0) } }
    }
}

/// The state of one case while it runs.
actor HarnessLabRun {
    /// Shared by every record this suite creates; never a real Host's.
    private static let hostID = UUID(uuidString: "00000000-0000-4000-8000-0000000172E2")!

    let labCase: HarnessLabCase
    let environment: HarnessLabEnvironment
    let host: HarnessLabHost
    let transport: any Transport
    let profile: HarnessLabProfile
    /// Every prompt's tokens start with it, so the shared mock log can be
    /// read for this case alone; the mock echoes `WAYCAR_*` tokens back.
    let token: String
    let nonce: String
    /// Host clock at the case's start, less a margin.
    let since: Int64
    let workspaceLabel: String
    let launchPromptHost: LaunchPromptHost

    private var kind: SupportedAgentKind { labCase.kind }
    private var backend: HostBackend { labCase.backend }
    /// The approval this case turns on; none where the backend cannot
    /// report it (`HarnessLabProfile.approval(on:environment:)`).
    private var approval: HarnessLabProfile.Approval? { profile.approval(on: backend, environment: environment) }

    private var observer: HarnessLabObserver?
    private var chatOptions: ChatModeLaunchOptions?
    private var marker: ChatModeMarker?
    private var wire: HarnessLaunchVectors.Wire?
    private var paneIDs: [String] = []
    /// The first message's Composer for a kind with no first-message flag.
    private var launchComposer: HarnessLabLaunchComposer?
    /// Text only the first message carries, where Waycar sends it from the
    /// queue: a later turn's request must carry it exactly once.
    private var queuedFirstMessage: String?
    private var notifications: ArmedNotifications?
    /// Host ms of the last relay push asserted, so a later one is new.
    private var lastPush: Int64 = 0
    /// One delivery POSTs once per registered device within milliseconds,
    /// and a Host may hold other devices' entries (fakes an interrupted run
    /// left behind); a pane's next delivery comes at least the plugin's 5 s
    /// hold later. So a push this long after the last one is a new delivery.
    private static let pushGap: Int64 = 1000

    private struct ArmedNotifications {
        let deviceToken: String
        let originalConfig: Data?
        let relayPath: String
    }

    init(
        labCase: HarnessLabCase, environment: HarnessLabEnvironment, host: HarnessLabHost,
        transport: any Transport
    ) async throws {
        self.labCase = labCase
        self.environment = environment
        self.host = host
        self.transport = transport
        profile = HarnessLabProfile.profile(for: labCase.kind)
        let nonce = String(UUID().uuidString.prefix(6))
        self.nonce = nonce
        token = "WAYCAR_E2E_\(labCase.kind.rawValue.uppercased())_\(labCase.backend.rawValue.uppercased())_\(nonce)"
        since = try await host.nowMilliseconds() - 2000
        workspaceLabel = "\(HarnessLabEnvironment.labelPrefix)\(labCase.kind.rawValue)-\(labCase.backend.rawValue)"
        let homePath = environment.homePath
        launchPromptHost = LaunchPromptHost(
            capabilities: { await transport.launchPromptCapabilities() },
            stage: { try await transport.stageLaunchPromptFiles($0) },
            homeDirectory: { homePath })
    }

    // MARK: Phases

    func execute() async throws {
        if profile.signIn {
            try await signIn()
            return
        }
        try await launch()
        try await plainTurn()
        await armNotifications()
        try await toolTurn()
        try await transcript()
        try await closeAndResume()
    }

    func cleanUp() async {
        await observer?.stop()
        if let notifications {
            if let data = try? await transport.readNotificationRegistration(),
                let file = try? NotificationRegistrationFile.decode(data),
                let cleaned = try? file.removing(token: notifications.deviceToken).encoded()
            {
                try? await transport.replaceNotificationRegistration(cleaned)
            }
            let original = notifications.originalConfig ?? (try? NotificationConfigFile().encoded())
            if let original { try? await transport.replaceNotificationConfig(original) }
        }
        for paneID in paneIDs { try? await transport.deleteChatModeMarker(paneID: paneID) }
        await launchComposer?.stop()
    }

    /// The New Agent sheet's launch (`StartAgentStore.submit`), in a new
    /// Workspace at the lab's trusted checkout, then its first turn.
    private func launch() async throws {
        let vector = Self.vector(for: kind, on: backend)
        if vector == nil {
            Issue.record("harness-launch-v1.json has no launch case for \(kind.rawValue)")
        }
        wire = vector?.wire
        if kind.supportsChatMode {
            if let options = vector?.chatOptions {
                chatOptions = options
            } else {
                // No vector: the suite's own marker stands in for one.
                let marker = "\(token)_CHATMARK"
                chatOptions = ChatModeLaunchOptions(
                    prompt: ChatModePrompt.launchText(from: "Answer briefly. \(marker)"))
                wire = HarnessLaunchVectors.Wire(
                    model: nil, effort: nil, systemContains: marker, firstUserContains: nil)
            }
        }
        let userArguments = (vector?.input.userArguments ?? []) + (approval?.arguments ?? [])
        let initialPrompt = vector?.input.firstMessage ?? "\(token)_FIRST hello"
        // `StartAgentStore.submit`: every fresh launch of a kind that can be
        // pinned is, Chat Mode or not, and its marker records the pin.
        let sessionPin = ChatModeLaunch.sessionPin(kind: kind, userArguments: userArguments)
        let command = try await LaunchPromptStager.launchCommand(
            kind: kind, chatOptions: chatOptions, sessionPin: sessionPin,
            userArguments: userArguments, initialPrompt: initialPrompt, host: launchPromptHost,
            hostName: "the harness lab", backend: backend)
        let launchedAt = Date()
        let agent = try await start(command: command, extraEnvironment: approval?.environment ?? [:])
        if chatOptions != nil || sessionPin != nil {
            let marker = ChatModeMarker(
                paneID: agent.paneID, terminalID: agent.terminalID, kind: kind.rawValue,
                cwd: agent.cwd.isEmpty ? environment.workDirectory : agent.cwd,
                session: sessionPin.map { .init(kind: "id", value: $0.uuidString.lowercased()) },
                prompt: chatOptions?.prompt, chatMode: chatOptions != nil, launchedAt: launchedAt)
            // The Host copy `ConsoleStore.recordChatModeLaunch` writes.
            try await transport.writeChatModeMarker(marker)
            self.marker = marker
        }
        // A kind with no first-message flag gets it from its Composer's
        // queue once it takes input, as `StartAgentStore.submit` hands it to
        // `ConsoleStore.queueLaunchMessage` (copilot: copilot.md §6).
        if LaunchPromptStager.firstMessageArguments(kind: kind, pointer: "") == nil {
            launchComposer = await HarnessLabLaunchComposer.queue(
                initialPrompt,
                for: QueuedMessage.AgentIdentity(paneID: agent.paneID, kind: kind.rawValue, session: nil),
                hostID: Self.hostID, transport: transport)
            queuedFirstMessage = wire?.firstUserContains ?? initialPrompt
        }
        await answerStartupDialog(paneID: agent.paneID)

        let firstContains = wire?.firstUserContains
        let first = await mockRequest(timeout: profile.launchBudget) { request in
            request.isAgentTurn && (firstContains.map { request.lastUser?.contains($0) == true } ?? true)
        }
        if first == nil { await recordUnreached("the first message") }
        if let first { checkWire(first, turn: "the first message") }
        if let launchComposer {
            let state = await launchComposer.settledState(timeout: .waitCeiling)
            #expect(
                state == .delivered,
                "\(labCase): the queued first message ended \(String(describing: state))")
        }
        let observer = try requireObserver()
        if profile.reportsTurns(on: backend, environment: environment),
            try await !unreportedTextTurn("the first turn", since: 0, reply: first?.replyText)
        {
            let finished = await observer.wait(since: 0, timeout: .seconds(60)) {
                $0.contains(.working) && $0.last == .done
            }
            let statuses = await observer.statuses(since: 0)
            #expect(finished, "\(labCase): the first turn did not go working → done: \(statuses)")
        }
        let kindsSeen = await observer.kindsSeen
        #expect(
            kindsSeen.contains(kind.rawValue),
            "\(labCase): the pane was never listed as \(kind.rawValue): \(kindsSeen)")
    }

    private func plainTurn() async throws {
        let marker = "\(token)_P1"
        let mark = try await requireObserver().mark()
        try await prompt("hello \(marker)")
        let request = await mockRequest(timeout: .seconds(60)) {
            $0.isAgentTurn && $0.lastUser?.contains(marker) == true
        }
        if request == nil { await recordUnreached("the plain prompt") }
        if let request, let queuedFirstMessage {
            let copies = (request.messages ?? []).filter {
                $0.role == "user" && $0.text?.contains(queuedFirstMessage) == true
            }
            #expect(
                copies.count == 1,
                "\(labCase): the queued first message reached the model \(copies.count) times")
        }
        if let request, let system = wire?.systemContains {
            #expect(
                request.system?.contains(system) == true,
                "\(labCase): the Chat Prompt marker is missing from a later turn")
        }
        if try await !unreportedTextTurn("the plain turn", since: mark, reply: request?.replyText) {
            try await expectTurn(since: mark, what: "the plain turn")
        }
    }

    private func toolTurn() async throws {
        let marker = "\(token)_T1"
        let observer = try requireObserver()
        let mark = await observer.mark()
        try await prompt("run \(approval?.token ?? "WAYCAR_TOOL") now \(marker)")
        if let approval {
            let blocked = await observer.wait(since: mark, timeout: .seconds(60)) {
                $0.contains(.blocked)
            }
            if !blocked {
                let statuses = await observer.statuses(since: mark)
                let shown = await screen()
                let evidence = approval.verifiedLive ? "dialog seen live" : "dialog unverified live"
                Issue.record(
                    "\(labCase): the approval never showed as blocked (\(evidence)): \(statuses); screen:\n\(shown)")
            }
            if blocked {
                let blockedAt = try await host.nowMilliseconds()
                await expectPush(after: blockedAt, for: "blocked")
                let held = await observer.current == .blocked
                #expect(held, "\(labCase): blocked did not hold while the push went out")
            }
            try await answer(approval.approve)
            let approved = await observer.wait(since: mark, timeout: .seconds(60)) { statuses in
                guard let blockedIndex = statuses.lastIndex(of: .blocked) else { return false }
                return statuses[blockedIndex...].contains(.working) && statuses.last == .done
            }
            let afterApproval = await observer.statuses(since: mark)
            #expect(
                approved || !blocked,
                "\(labCase): after approval the turn did not go working → done: \(afterApproval)")
        } else {
            if let reason = profile.noApprovalReason(on: backend, environment: environment) {
                print("\(labCase): no blocked state in the lab: \(reason)")
            }
            try await expectTurn(since: mark, what: "the tool turn")
            let statuses = await observer.statuses(since: mark)
            #expect(
                !statuses.contains(.blocked),
                "\(labCase): blocked without an approval the lab asked for: \(statuses)")
        }
        // Observed within a poll of the change; the push follows the
        // plugin's 5 s debounce, and never precedes the blocked one.
        let turnEnded = try await host.nowMilliseconds() - 3000
        // The tool result's request has no trailing user text (the mock's
        // `lastUser` is empty for it), so it is matched by its transcript.
        let afterTool = await mockRequest(timeout: .seconds(60)) {
            $0.reply == "after-tool" && $0.transcriptText.contains(marker)
        }
        if afterTool == nil { await recordUnreached("the tool's result") }
        let ended = await observer.current == .done
        if profile.reportsTurns(on: backend, environment: environment), ended {
            await expectPush(after: max(turnEnded, lastPush + Self.pushGap), for: "done")
        }
    }

    /// The Chat view's read (`ConsoleStore.readChatTranscript(for:after:)`).
    private func transcript() async throws {
        let observer = try requireObserver()
        let ofKind = await observer.latestOfKind
        let anyKind = await observer.latest
        guard let listed = ofKind ?? anyKind else {
            Issue.record("\(labCase): no listed Agent to read a transcript for")
            return
        }
        let marker = self.marker
        let session: ChatModeMarker.Session? =
            if let live = listed.agentSession, !live.value.isEmpty {
                ChatModeMarker.Session(kind: live.kind.rawValue, value: live.value)
            } else {
                marker?.session
            }
        let request = ChatTranscriptRequest(
            paneID: listed.paneID, kind: listed.kind, sessionKind: session?.kind,
            sessionValue: session?.value,
            cwd: listed.cwd.isEmpty ? marker?.cwd : listed.cwd,
            launchedAt: marker?.launchedAt, status: listed.status, after: nil)
        let transport = self.transport
        guard kind.supportsChatMode else {
            let snapshot = try await transport.readChatTranscript(request)
            #expect(
                snapshot.header.status == .unsupported,
                "\(labCase): a kind without Chat Mode read as \(snapshot.header.status)")
            return
        }
        if profile.transcriptNeedsSession, session == nil {
            // herdr reports `agent_session` only through an integration
            // (herdr-backend.md), and this kind pins none at launch.
            let snapshot = try await transport.readChatTranscript(request)
            print("\(labCase): no session to find the transcript by; the read is \(snapshot.header.status)")
            #expect(
                snapshot.header.status == .notFound,
                "\(labCase): a session-less read of a session-only reader returned \(snapshot.header.status)")
            return
        }
        let plain = "\(token)_P1"
        // Waits for the whole conversation, the tool turn closed: a backend
        // that reports no turns for the kind (omp on herdr) gave no done to
        // wait for before this read.
        @Sendable func complete(_ snapshot: ChatTranscriptSnapshot) -> Bool {
            snapshot.header.status == .ok && !snapshot.header.turnOpen
                && snapshot.messages.contains { $0.role == .assistant && $0.text.contains(plain) }
                && snapshot.messages.contains { $0.role == .assistant && $0.text.contains("waycar-tool-done") }
        }
        let finished = await harnessLabPoll(timeout: .seconds(30), interval: .seconds(1)) {
            let snapshot = try await transport.readChatTranscript(request)
            return complete(snapshot) ? snapshot : nil
        }
        let snapshot = if let finished { finished } else { try await transport.readChatTranscript(request) }
        guard snapshot.header.status == .ok else {
            Issue.record("\(labCase): the transcript read \(snapshot.header): \(snapshot.messages.map(\.text))")
            return
        }
        #expect(snapshot.messages.contains { $0.role == .user && $0.text.contains(plain) })
        #expect(
            snapshot.messages.contains { $0.role == .assistant && $0.text.contains(plain) },
            "\(labCase): the plain turn's reply is missing from the transcript")
        #expect(
            snapshot.messages.contains { $0.role == .assistant && $0.text.contains("waycar-tool-done") },
            "\(labCase): the tool turn's reply is missing from the transcript")
        #expect(!snapshot.header.turnOpen, "\(labCase): a finished turn read as open: \(snapshot.header)")
    }

    /// Close the Agent, record it as the Console does, and resume it.
    private func closeAndResume() async throws {
        let observer = try requireObserver()
        guard let row = await observer.latestOfKind else {
            Issue.record("\(labCase): never listed as \(kind.rawValue), so nothing to close")
            return
        }
        let session = await observer.lastSession
        let expectsSession = profile.reportsSession(on: backend, environment: environment)
        if expectsSession {
            #expect(session != nil, "\(labCase): no session was ever reported")
        }
        try await transport.closePane(PaneTarget(paneID: row.paneID), closesWorktreeGroup: false)
        let gone = await observer.waitUntilGone(timeout: .seconds(30))
        #expect(gone, "\(labCase): the closed pane stayed listed")
        let consoleRow = ConsoleAgent(
            hostID: Self.hostID, hostName: "harness lab", agent: row,
            workspaceLabel: workspaceLabel, repositoryCheckout: nil, backend: backend)
        // `ConsoleStore.agentsDidClose`: the launch's pin stands in for a
        // session the backend never reported.
        let capture = ClosedAgentCapture(row: consoleRow, session: session, lastSeenRunningAt: Date())
            .withLaunchSession(from: marker)
        let closed = try #require(
            ClosedSession(
                closing: capture.row, session: capture.session, lastSeenRunningAt: Date(), closedAt: Date(),
                chatMode: chatOptions != nil),
            "\(labCase): the closed Agent made no Closed Session")
        #expect(closed.kind == kind)
        if marker?.session != nil {
            #expect(closed.session != nil, "\(labCase): the launch pinned a session the Closed Session lost")
        }
        if closed.session == nil {
            // With no session the resume is the kind's own session-less form.
            // A continue-the-latest form reopens this case's session (cases
            // run one at a time in the one working directory), and the
            // resumed request's earlier turns below prove it. An empty form or
            // an interactive picker gives nothing to drive.
            if let reason = profile.sessionlessResumeUncheckable(closed.resumeArguments) {
                print("\(labCase): no session reported or pinned, and \(reason); a resume would run \(closed.resumeArguments)")
                return
            }
        } else {
            #expect(!closed.resumeArguments.isEmpty, "\(labCase): a session but no resume form")
            guard !closed.resumeArguments.isEmpty else { return }
        }

        let outcome = await Self.resume(
            closed, transport: transport, chatOptions: chatOptions, host: launchPromptHost)
        guard case .started(let id) = outcome else {
            Issue.record("\(labCase): the resume failed: \(outcome)")
            return
        }
        paneIDs.append(id.paneID)
        await observer.follow(id.paneID)
        await answerStartupDialog(paneID: id.paneID)
        if backend == .herdr {
            // herdr classifies a launched Agent about 3.6 s after its start
            // and reports `unknown` until then (herdr-backend.md, finding 1);
            // the mock's 1.5 s turn sent at once would end unseen. The
            // Console shows the Agent as starting until herdr settles.
            let settled = await observer.wait(since: 0, timeout: profile.launchBudget) {
                $0.contains { $0 != .unknown }
            }
            #expect(settled, "\(labCase): herdr never classified the resumed Agent")
        }
        let marker = "\(token)_R1"
        let mark = await observer.mark()
        try await prompt("after resume \(marker)")
        let request = await mockRequest(timeout: profile.launchBudget) {
            $0.isAgentTurn && $0.lastUser?.contains(marker) == true
        }
        if request == nil { await recordUnreached("the resumed Agent's prompt") }
        if let request {
            #expect(
                request.transcriptText.contains("\(token)_P1"),
                "\(labCase): the resumed session did not carry its earlier turns")
            if let system = wire?.systemContains {
                #expect(
                    request.system?.contains(system) == true,
                    "\(labCase): the Chat Prompt did not survive the resume")
            }
        }
        if try await !unreportedTextTurn("the resumed turn", since: mark, reply: request?.replyText) {
            try await expectTurn(since: mark, what: "the resumed turn")
        }
    }

    /// Account-only kinds: the sign-in screen is recognized and refuses a
    /// prompt without typing it (Enter would start the browser login).
    private func signIn() async throws {
        let command = try await LaunchPromptStager.launchCommand(
            kind: kind, chatOptions: nil, sessionPin: nil, userArguments: [],
            initialPrompt: nil, host: launchPromptHost, hostName: "the harness lab",
            backend: backend)
        let agent = try await start(command: command, extraEnvironment: [:])
        let transport = self.transport
        let kind = self.kind
        let paneID = agent.paneID
        let shown = await harnessLabPoll(timeout: .seconds(45), interval: .seconds(1)) {
            let text = try await transport.readPane(PaneReadParams(paneID: paneID, source: .visible)).text
            return AgentScreen.signInRequired(kind: kind.rawValue, screen: text) ? text : nil
        }
        if shown == nil {
            let visible = await screen()
            Issue.record("\(labCase): the sign-in screen was not recognized:\n\(visible)")
        }
        do {
            _ = try await transport.promptAgent(
                AgentPromptParams(target: paneID, text: "hello \(token)_SIGNIN"))
            Issue.record("\(labCase): a prompt went through to the sign-in screen")
        } catch {
            #expect(
                RequestNotSentError.unwrapped(error) is AgentSignInRequiredError,
                "\(labCase): the prompt failed with \(error), not AgentSignInRequiredError")
        }
        try await Task.sleep(for: .seconds(2))
        let after = (try? await transport.readPane(PaneReadParams(paneID: paneID, source: .visible)).text) ?? ""
        #expect(
            AgentScreen.signInRequired(kind: kind.rawValue, screen: after),
            "\(labCase): the sign-in screen changed after the refused prompt:\n\(after)")
        let statuses = try await requireObserver().statuses(since: 0)
        #expect(
            !statuses.contains(.working) && !statuses.contains(.blocked),
            "\(labCase): a sign-in screen reported \(statuses)")
    }

    // MARK: Steps

    private func start(command: AgentLaunchCommand, extraEnvironment: [String: String]) async throws -> Agent {
        if backend == .herdr { try await focusElsewhere() }
        let request = AgentLaunchRequest(
            kind: kind.rawValue, name: "e2e-\(kind.rawValue)-\(nonce.lowercased())",
            arguments: command.arguments,
            environment: command.environment.merging(extraEnvironment) { launch, _ in launch })
        let agent = try await transport.startAgentInNewWorkspace(
            request,
            workspace: NewWorkspaceSpec(directory: environment.workDirectory, label: workspaceLabel))
        paneIDs.append(agent.paneID)
        let observer = HarnessLabObserver(transport: transport, kind: kind, paneID: agent.paneID)
        await observer.start()
        self.observer = observer
        return agent
    }

    /// herdr reports a finished turn as `done` only while its pane is unseen;
    /// the focused pane of the focused Workspace reads `idle` instead (`herdr
    /// --skill`: "idle and done both mean the agent is ready for input … the
    /// server's seen state"; verified on the lab's 0.9.3: same claude turn,
    /// focused pane → idle, unfocused → done). The lab reset leaves no
    /// Workspace, so the case's own one, created with `focus: false`, would
    /// still be the only and therefore focused one. A focused placeholder
    /// Workspace stands in for whatever the user looks at meanwhile; the
    /// reset closes it with the rest.
    private func focusElsewhere() async throws {
        try await host.shell(
            "herdr workspace create --label \(HarnessLabEnvironment.labelPrefix)focus --cwd \"$HOME\" --focus >/dev/null")
    }

    /// `ClosedSessionResumer.resume`, its closures bound to the Transport the
    /// way `init(console:)` binds them to the Console.
    @MainActor
    private static func resume(
        _ session: ClosedSession, transport: any Transport, chatOptions: ChatModeLaunchOptions?,
        host: LaunchPromptHost
    ) async -> ClosedSessionResumer.Outcome {
        let resumer = ClosedSessionResumer(
            workspaces: { _ in [] },
            existingAgentNames: { _ in [] },
            start: { request, destination, _, _ in
                print("\(request.kind) resume launches: \(request.arguments)")
                switch destination {
                case .existingWorkspace:
                    return try await transport.startAgent(request)
                case .newWorkspace(let workspace):
                    return try await transport.startAgentInNewWorkspace(request, workspace: workspace)
                case .newWorktree:
                    throw HarnessLabError.unexpectedOutput(
                        command: "resume", output: "a resume never makes a worktree")
                }
            },
            awaitAgentVisible: { _ in },
            beginPendingResume: { _, _, _ in },
            recordChatMode: { marker, _ in try? await transport.writeChatModeMarker(marker) },
            chatOptions: { chatOptions ?? ChatModeSettings.launchOptions(for: $0) },
            launchPromptHost: { _ in host },
            hostName: { _ in "the harness lab" })
        return await resumer.resume(session)
    }

    /// The Composer's send: retried while the Transport holds it back for a
    /// TUI that does not take input yet, as `AgentComposerStore` retries.
    private func prompt(_ text: String) async throws {
        let paneID = try await requireObserver().paneID
        let deadline = ContinuousClock.now + profile.launchBudget
        while true {
            do {
                _ = try await transport.promptAgent(AgentPromptParams(target: paneID, text: text))
                return
            } catch {
                let cause = RequestNotSentError.unwrapped(error)
                let retryable =
                    cause is AgentInputNotReadyError
                    || (cause as? HerdrAPIError).map { ["agent_not_ready", "agent_pane_busy"].contains($0.code) }
                        == true
                guard retryable, ContinuousClock.now < deadline else { throw error }
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func answer(_ approve: HarnessLabProfile.Approve) async throws {
        let paneID = try await requireObserver().paneID
        switch approve {
        case .keys(let keys):
            try await transport.sendAgentKeys(AgentSendKeysParams(keys: keys, target: paneID))
        }
    }

    /// A first-run dialog the lab still shows for this kind; answered once.
    private func answerStartupDialog(paneID: String) async {
        guard let dialog = profile.startupDialog else { return }
        let transport = self.transport
        let shown = await harnessLabPoll(timeout: .seconds(15), interval: .seconds(1)) {
            let text = try await transport.readPane(PaneReadParams(paneID: paneID, source: .visible)).text
            return text.contains(dialog.marker) ? true : nil
        }
        guard shown == true else { return }
        print("\(labCase): answering the lab's startup dialog (\(dialog.marker))")
        try? await transport.sendAgentKeys(AgentSendKeysParams(keys: dialog.keys, target: paneID))
    }

    private func expectTurn(since mark: Int, what: String) async throws {
        let observer = try requireObserver()
        guard profile.reportsTurns(on: backend, environment: environment) else {
            print("\(labCase): \(what): this backend reports no turns for \(kind.rawValue) here")
            return
        }
        let finished = await observer.wait(since: mark, timeout: .seconds(60)) {
            guard let working = $0.firstIndex(of: .working) else { return false }
            return $0[working...].last == .done
        }
        let statuses = await observer.statuses(since: mark)
        #expect(finished, "\(labCase): \(what) did not go working → done: \(statuses)")
    }

    /// A turn the model answers in text alone, where the backend reports
    /// turns for this kind but not such a turn
    /// (`HarnessLabProfile.unreportedTextTurnReason`): says why, waits for
    /// the mock's `reply` on screen in place of done, so the next prompt
    /// never lands mid-turn, and prints the statuses seen since `mark`.
    /// False where the backend reports the turn, or no turns at all
    /// (`expectTurn` says so).
    private func unreportedTextTurn(_ what: String, since mark: Int, reply: String?) async throws -> Bool {
        guard profile.reportsTurns(on: backend, environment: environment),
            let reason = profile.unreportedTextTurnReason(on: backend)
        else { return false }
        print(
            "\(labCase): \(what) is text only, which \(backend.rawValue) does not report for \(kind.rawValue): \(reason)")
        // No request, no reply to wait for: already recorded as unreached.
        guard let reply else { return true }
        let observer = try requireObserver()
        let paneID = await observer.paneID
        let transport = self.transport
        let shown = await harnessLabPoll(timeout: .seconds(60), interval: .seconds(1)) {
            let text = try await transport.readPane(PaneReadParams(paneID: paneID, source: .visible)).text
            return text.contains(reply) ? true : nil
        }
        if shown == nil {
            let current = await screen()
            Issue.record("\(labCase): \(what): the reply \"\(reply)\" never showed; screen:\n\(current)")
        }
        let statuses = await observer.statuses(since: mark)
        print("\(labCase): \(what): statuses seen until the reply showed: \(statuses)")
        return true
    }

    /// The vector's wire facts on one request; nil facts are not asserted.
    private func checkWire(_ request: MockRequest, turn: String) {
        guard let wire else { return }
        if let model = wire.model {
            #expect(request.model == model, "\(labCase): \(turn) went out on model \(String(describing: request.model))")
        }
        if let effort = wire.effort {
            #expect(request.effort == effort, "\(labCase): \(turn) went out with effort \(String(describing: request.effort))")
        }
        if let system = wire.systemContains {
            #expect(
                request.system?.contains(system) == true,
                "\(labCase): \(turn)'s system prompt lacks the Chat Prompt marker")
        }
    }

    // MARK: Notifications

    /// Registers a fake device and points the Host's relay at the mock, as
    /// Notification Registration writes them (`NotificationRegistrationFile`,
    /// `NotificationConfigFile`), so the plugin's push decision becomes a
    /// POST the mock logs. The envelope is sealed for the fake key; only the
    /// POST's timing is asserted.
    private func armNotifications() async {
        let relayPath = "/\(HarnessLabEnvironment.labelPrefix)relay/\(nonce)"
        do {
            let originalConfig = try await transport.readNotificationConfig()
            let config = try NotificationConfigFile.decode(originalConfig)
                .settingRelayURL(environment.mockURL + relayPath)
            try await transport.replaceNotificationConfig(try config.encoded())
            var bytes = [UInt8](repeating: 0, count: 64)
            for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
            let token = APNSDeviceToken(tokenData: Data(bytes.prefix(32)), environment: .sandbox)
            let entry = NotificationDeviceEntry(
                token: token, key: Data(bytes.suffix(32)), notify: NotificationTriggerPreferences())
            let registration = try NotificationRegistrationFile.decode(
                try await transport.readNotificationRegistration())
            try await transport.replaceNotificationRegistration(try registration.upserting(entry).encoded())
            notifications = ArmedNotifications(
                deviceToken: token.hex, originalConfig: originalConfig, relayPath: relayPath + "/push")
        } catch {
            Issue.record("\(labCase): could not register the mock relay: \(error)")
        }
    }

    /// A push the plugin decided to send after `after` (Host ms): its relay
    /// debounce is 5 s, so this waits up to 30 s.
    private func expectPush(after: Int64, for status: String) async {
        guard let relayPath = notifications?.relayPath else { return }
        let push = await mockRequest(timeout: .seconds(30)) {
            $0.path == relayPath && $0.ts >= after
        }
        #expect(push != nil, "\(labCase): no relay push for \(status)")
        if let push { lastPush = push.ts }
    }

    // MARK: Reading

    private func requireObserver() throws -> HarnessLabObserver {
        guard let observer else { throw HarnessLabError.timedOut("a started Agent") }
        return observer
    }

    private func mockRequest(
        timeout: Duration, _ match: @escaping @Sendable (MockRequest) -> Bool
    ) async -> MockRequest? {
        let host = self.host
        let since = self.since
        return await harnessLabPoll(timeout: timeout, interval: .seconds(1)) {
            try await host.mockRequests(since: since).first(where: match)
        }
    }

    private func screen() async -> String {
        guard let paneID = try? await requireObserver().paneID else { return "" }
        return (try? await transport.readPane(PaneReadParams(paneID: paneID, source: .visible)).text) ?? ""
    }

    /// A request the mock never saw, with the pane's screen as evidence.
    private func recordUnreached(_ what: String) async {
        let statuses = await observer?.statuses(since: 0) ?? []
        let shown = await screen()
        Issue.record("\(labCase): \(what) never reached the model; statuses \(statuses); screen:\n\(shown)")
    }

    /// The kind's launch case, never a resume case: a Chat Mode one for a
    /// Chat Mode kind, preferring one with live wire facts, then one with a
    /// first message, then one for this backend.
    private static func vector(
        for kind: SupportedAgentKind, on backend: HostBackend
    ) -> HarnessLaunchVectors.Case? {
        let cases = HarnessLaunchVectors.shared.cases.filter {
            $0.kind == kind && !$0.isResume && (!kind.supportsChatMode || $0.chatOptions != nil)
        }
        func score(_ vector: HarnessLaunchVectors.Case) -> Int {
            (vector.wire != nil ? 4 : 0) + (vector.input.firstMessage != nil ? 2 : 0)
                + (vector.backend == backend ? 1 : 0)
        }
        // The first of the best, in file order.
        return cases.reduce(HarnessLaunchVectors.Case?.none) { best, vector in
            guard let best else { return vector }
            return score(vector) > score(best) ? vector : best
        }
    }
}

/// `ConsoleStore.queueLaunchMessage` against the lab's Transport: a launch's
/// first message in a real Agent Composer's queue, its outbox on a scratch
/// Queued Message store, the pane's row and status read from `listAgents()`
/// the way the Console's resync reads them.
@MainActor
final class HarnessLabLaunchComposer {
    /// How the queued message ended: on its way, or settled.
    enum Outcome: Equatable {
        case waiting
        case delivered
        case failed(String)
        case held(String)
    }

    /// The Console's last listing of the pane.
    @MainActor
    private final class Row {
        var identity: QueuedMessage.AgentIdentity?
    }

    private let composer: AgentComposerStore
    private let directory: URL
    private var following: Task<Void, Never>?

    private init(composer: AgentComposerStore, directory: URL) {
        self.composer = composer
        self.directory = directory
    }

    static func queue(
        _ text: String, for agent: QueuedMessage.AgentIdentity, hostID: Host.ID,
        transport: any Transport
    ) -> HarnessLabLaunchComposer {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "harness-lab-queue-\(UUID().uuidString)", directoryHint: .isDirectory)
        let row = Row()
        let outbox = ComposerOutbox(
            hostID: hostID, store: QueuedMessageStore(directory: directory),
            identity: { row.identity },
            mayDrain: { true },
            prepare: { _, _ in throw AttachmentStagingError.invalidPreparedSource },
            upload: { _, _ in throw AttachmentStagingError.invalidPreparedSource },
            sleep: { try await Task.sleep(for: $0) },
            countDidChange: { _ in })
        let composer = AgentComposerStore(target: agent.paneID, outbox: outbox) { params in
            try await transport.promptAgent(params)
        }
        let launch = HarnessLabLaunchComposer(composer: composer, directory: directory)
        let paneID = agent.paneID
        launch.following = Task { @MainActor [weak composer] in
            while !Task.isCancelled {
                if let listed = try? await transport.listAgents().first(where: { $0.paneID == paneID }) {
                    row.identity = QueuedMessage.AgentIdentity(listed)
                    composer?.agentStatusDidChange(listed.status)
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        composer.queueLaunchMessage(text, for: agent)
        return launch
    }

    /// The queued message's outcome once it settles, or `.waiting` at the
    /// timeout.
    func settledState(timeout: Duration) async -> Outcome {
        let deadline = ContinuousClock.now + timeout
        while true {
            let outcome = self.outcome
            if outcome != .waiting || ContinuousClock.now >= deadline { return outcome }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    func stop() {
        following?.cancel()
        following = nil
        composer.cancelQueue()
        try? FileManager.default.removeItem(at: directory)
    }

    private var outcome: Outcome {
        switch composer.messages.first?.state {
        case .delivered: .delivered
        case .failed(let reason): .failed(reason)
        case .held(let reason): .held(reason)
        case .queued, .sending, nil: .waiting
        }
    }
}
