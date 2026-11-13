import SwiftUI

/// The default Agent detail surface. Ghostty renders the live Attach stream.
/// Composer owns authored delivery by default; Direct Input (ADR 0016) is an
/// explicit opt-in that types the Attach PTY with the system keyboard. A plain
/// shell row is shown here too, exactly like an Agent: it attaches through
/// `terminal attach` and its Composer types through `pane.send_input`.
/// A Chat Mode Agent shows the Chat view instead, and opens no Attach until
/// the user chooses Show Terminal; Show Chat releases it again.
struct AgentDetailView: View {
    let agent: ConsoleAgent
    private let console: ConsoleStore
    private let terminal: TerminalSettings
    private let hosts: [Host]
    private let activity: AppActivityCoordinator
    private let keyboardHandoff: TerminalKeyboardHandoff
    private let keyboardInset: TerminalKeyboardInset
    private let isOnStage: () -> Bool
    private let isVisible: () -> Bool
    private let onSwitch: (ConsoleAgent.ID) -> Void
    private let onClosed: () -> Void
    /// Leaves the screen after Mark as Unread; the Console owner returns to
    /// the index.
    private let onMarkedUnread: () -> Void
    /// Whether the Chat view is up, for the Console, which owns the
    /// window's status-bar scheme.
    private let onChatPresentationChange: (Bool) -> Void
    /// A thread's Show Terminal always attaches, even if the pane also has
    /// its own Chat Mode marker.
    private let isLinkedTerminal: Bool
    @State private var focus = AgentFocusCoordinator()
    @State private var hasAppeared = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var composer: AgentComposerStore
    /// nil while a Chat Mode Agent shows the Chat view: no PTY is opened
    /// until Show Terminal.
    @State private var attach: AgentAttachStore?
    /// A test-injected Attach, used whenever the terminal is presented.
    private let injectedAttach: AgentAttachStore?
    @State private var transcript: ChatTranscriptStore?
    /// The user chose Show Terminal for a Chat Mode Agent. Chat Mode
    /// learned late (markers refreshed after appear) never overrides it.
    @State private var choseTerminal = false
    /// A New Chat's arrival raises the Chat keyboard; decided once, on the
    /// Chat view's first appearance.
    @State private var focusesChatInput = false
    @State private var askedChatInputFocus = false
    @State private var retainedAgent: AgentTerminalCache.Entry?
    /// Outlives the terminal screen, which a new Attach store rebuilds: a
    /// return from a suspension keeps the frame the old store painted (#21).
    @State private var lastFrame = TerminalLastFrame()
    /// Set when the New Agent sheet opened this Agent: its terminal's
    /// Ignition echoes the launch (#96). Here rather than in the terminal
    /// screen, which the retention swap rebuilds right after appearing.
    /// Dropped once that terminal has been live and leaves it, so a
    /// Reattach, Take Over or Show Terminal is no launch.
    @State private var agentLaunch: AgentLaunchNote?
    /// Whether Message Agent is open. Outlives the terminal screen for the
    /// same reason: only a real navigation, which builds a new detail,
    /// closes it.
    @State private var inputMode = AgentInputModeState()
    @State private var retentionOwnerID: UUID
    private let permitsRetention: Bool
    @State private var isResolvingTerminal = false
    @State private var isChoosingTerminal = false
    @State private var terminalOpenFailure: String?
    @State private var createdTerminal: ShellTerminalIdentity?
    @State private var shellHandoffToken: UUID?
    /// Which window holds this Host's terminal channel; nil outside a scene
    /// root, where this detail always holds it.
    @Environment(\.agentSceneRouting) private var sceneRouting
    @Environment(\.sampleConnect) private var sampleConnect
    /// The open iPad list covers this Agent (portrait slide-over, ADR 0024).
    @Environment(\.consoleDetailIsCovered) private var isCovered
    /// An Agent switch's snapshot of the previous screen, which the arriving
    /// content dissolves once it is up.
    @Environment(\.detailCrossfade) private var detailCrossfade
    /// This scene's window: the terminal's remembered grid is its layout's.
    @Environment(\.sceneWindow) private var sceneWindow
    /// `isCovered` as keyboard commands read it. The command registry keeps
    /// the closure it was handed at registration, which a captured
    /// environment value would leave stale; state reads live.
    @State private var commandsAreCovered = false

    init(
        agent: ConsoleAgent,
        console: ConsoleStore,
        terminal: TerminalSettings,
        hosts: [Host],
        activity: AppActivityCoordinator,
        keyboardHandoff: TerminalKeyboardHandoff,
        keyboardInset: TerminalKeyboardInset,
        stage: AgentDetailStage,
        onSwitch: @escaping (ConsoleAgent.ID) -> Void,
        onClosed: @escaping () -> Void,
        onMarkedUnread: @escaping () -> Void = {},
        onChatPresentationChange: @escaping (Bool) -> Void = { _ in },
        composerStore: AgentComposerStore? = nil,
        attachStore: AgentAttachStore? = nil,
        isLinkedTerminal: Bool = false
    ) {
        self.agent = agent
        self.console = console
        self.terminal = terminal
        self.hosts = hosts
        self.activity = activity
        self.keyboardHandoff = keyboardHandoff
        self.keyboardInset = keyboardInset
        let isOnStage = stage.isOnStage
        self.isOnStage = isOnStage
        self.isVisible = stage.isVisible
        self.onSwitch = onSwitch
        self.onClosed = onClosed
        self.onMarkedUnread = onMarkedUnread
        self.onChatPresentationChange = onChatPresentationChange
        self.isLinkedTerminal = isLinkedTerminal
        let composer = composerStore ?? console.composerStore(for: agent)
        _composer = State(initialValue: composer)
        let ownerID = UUID()
        _retentionOwnerID = State(initialValue: ownerID)
        permitsRetention = attachStore == nil
        _retainedAgent = State(initialValue: nil)
        injectedAttach = attachStore
        if !isLinkedTerminal && console.isChatMode(agent) {
            _attach = State(initialValue: nil)
            _transcript = State(initialValue: console.makeChatTranscriptStore(for: agent))
        } else {
            _attach = State(initialValue: attachStore ?? Self.makeAttach(
                agent: agent, console: console, composer: composer,
                retainsSessions: attachStore == nil, isOnStage: isOnStage))
            _transcript = State(initialValue: nil)
        }
    }

    /// The detail's own Attach until retention swaps in the cached one.
    private static func makeAttach(
        agent: ConsoleAgent, console: ConsoleStore, composer: AgentComposerStore,
        retainsSessions: Bool, isOnStage: @escaping () -> Bool
    ) -> AgentAttachStore {
        AgentAttachStore(
            target: agent.attachTarget,
            transportGeneration: console.connectionGeneration(for: agent),
            recordsNetworkTelemetry: agent.recordsNetworkTelemetry,
            isOnStage: { !retainsSessions && isOnStage() },
            runTerminal: console.terminalRunner(for: agent.hostID),
            stageImage: console.imageStager(for: agent.hostID),
            stageFile: console.fileStager(for: agent.hostID),
            composer: composer,
            paneHistory: console.makePaneHistory(for: agent)
        ) {
            try await console.closePane(agent.agent.paneID, on: agent.hostID)
        } invalidateMosh: { cause in
            console.invalidateMosh(for: agent.hostID, cause: cause)
        } onUserInput: { [weak console] in
            console?.noteUserInput(to: agent.id)
        }
    }

    /// Chat media fetches resolve relative paths against the Console's
    /// current row (its cwd), like the transcript reads.
    private var chatMediaLoader: ChatMediaLoader {
        let agent = agent
        let console = console
        return { [weak console] media in
            guard let console else { throw CancellationError() }
            let current = console.listedAgent(agent.id) ?? agent
            return try await console.chatMediaFile(for: media, agent: current)
        }
    }

    /// The Hybrid chat extras for an Ultimate conversation: the leader's
    /// branches (live, from the listed row), sibling navigation through the
    /// Console's selection; nil on every other backend.
    private var ultimateChatContext: UltimateChatContext? {
        guard agent.backend == .ultimate else { return nil }
        let console = console
        let agent = agent
        let current = console.listedAgent(agent.id) ?? agent
        let onSwitch = onSwitch
        return UltimateChatContext(
            name: current.agent.displayName,
            busy: current.agent.status == .working,
            children: current.isUltimateLeader ? current.ultimateChildren : [],
            openConversation: { conversationId in
                onSwitch(ConsoleAgent.ID(
                    hostID: agent.hostID,
                    paneID: UltimateChatContext.paneID(
                        sibling: conversationId, of: agent.agent.paneID)))
            })
    }

    /// Whether this Agent was launched in Chat Mode. Follows the marker
    /// cache, so a refresh after appear can still turn it on.
    private var isChatAgent: Bool {
        !isLinkedTerminal && console.isChatMode(agent)
    }

    /// Deterministic per chat, so recomputing it is harmless
    /// (`ChatGreeting.seed`).
    private var chatGreeting: String {
        let marker = console.chatMode.marker(for: agent.id)
        return ChatGreeting.text(
            seed: ChatGreeting.seed(
                agentID: agent.id, terminalID: agent.agent.terminalID,
                launchedAt: marker?.launchedAt),
            startedAt: marker?.launchedAt)
    }

    private var showsChat: Bool {
        isChatAgent && !choseTerminal
    }

    /// The chat's Archive, for a Backend whose rows archive
    /// (`archivesOnClose`): the swipe's Close, with its undo countdown on
    /// the Console row, then back to the Console. nil elsewhere.
    static func chatArchiveAction(
        for agent: ConsoleAgent, console: ConsoleStore, onClosed: @escaping () -> Void
    ) -> (@MainActor () -> Void)? {
        guard agent.backend.archivesOnClose else { return nil }
        return { [weak console] in
            guard let console else { return }
            console.scheduleTabClose(console.listedAgent(agent.id) ?? agent)
            onClosed()
        }
    }

    /// Show Terminal: builds and starts the Attach exactly as a non-chat
    /// detail's init and first appear would. The transcript stops here, not
    /// only on the Chat view's disappear, which the detail column does not
    /// always report.
    private func presentTerminal() {
        composer.bindBlockedInsert(nil)
        transcript?.stop()
        guard agent.backend.hasTerminal, attach == nil else { return }
        attach = injectedAttach ?? Self.makeAttach(
            agent: agent, console: console, composer: composer,
            retainsSessions: permitsRetention, isOnStage: isOnStage)
        applyTerminalAccess()
    }

    /// Show Chat: releases the Attach so no PTY stays open behind the Chat
    /// view. A retained entry goes back to the cache, which evicts it when
    /// idle; its PTY is left now either way. The transcript and Composer
    /// start here as well as on the Chat view's appear, which the detail
    /// column does not always deliver (`start` is idempotent).
    private func presentChat() {
        if transcript == nil {
            transcript = console.makeChatTranscriptStore(for: agent)
        }
        transcript?.start()
        bindChatComposer()
        guard let attach else { return }
        composer.bindAttachInput(nil)
        if let retainedAgent {
            console.agentTerminals.release(retainedAgent, ownerID: retentionOwnerID)
            self.retainedAgent = nil
        }
        attach.leaveForTerminalHandoff()
        self.attach = nil
    }

    /// The Chat view has no Attach: a Blocked send inserts through the pane.
    private func bindChatComposer() {
        composer.open()
        composer.bindAttachInput(nil)
        let agent = agent
        let console = console
        composer.bindBlockedInsert { [weak console] text in
            guard let console else { throw CancellationError() }
            try await console.insertText(text, into: agent)
        }
    }

    /// herdr rows share their Host's one writable channel; tmux rows always
    /// attach (`HostBackend.terminalAccess`).
    private var terminalAccess: HostTerminalAccess {
        agent.backend.terminalAccess(sceneRouting?.terminalAccess(for: agent.hostID) ?? .holds)
    }

    private func applyTerminalAccess() {
        // The Chat view holds no Attach, so it has no channel to hand over.
        guard let current = attach else { return }
        switch terminalAccess {
        case .holds:
            prepareRetainedAgent()
            attach?.rejoin()
        case .liveInAnotherWindow:
            if let retainedAgent {
                console.agentTerminals.release(retainedAgent, ownerID: retentionOwnerID)
                self.retainedAgent = nil
                attach = makePrivateAttach()
            } else {
                current.leaveForTerminalHandoff()
            }
        }
    }

    private func prepareRetainedAgent() {
        guard permitsRetention, isOnStage(), let current = attach else { return }
        if let retainedAgent, retainedAgent.isRetained {
            console.agentTerminals.activate(retainedAgent, ownerID: retentionOwnerID, isPresented: { isOnStage() })
            return
        }
        if retainedAgent == nil { current.leaveForTerminalHandoff() }
        let entry = console.agentTerminals.acquire(
            agent: agent, console: console, composer: composer, ownerID: retentionOwnerID,
            windowLayout: { [weak sceneWindow] in
                sceneWindow?.window.map(TerminalGridSizeMemory.layout(of:))
            },
            isPresented: { isOnStage() })
        retainedAgent = entry
        // The screen showing the old store is about to be rebuilt around the
        // new one; keep what it painted.
        lastFrame.surfaceWillRetire(current.terminalID)
        attach = entry.attach
    }

    private func makePrivateAttach() -> AgentAttachStore {
        let console = console
        let hostID = agent.hostID
        let paneID = agent.agent.paneID
        return AgentAttachStore(
            target: agent.attachTarget,
            transportGeneration: console.connectionGeneration(for: agent),
            recordsNetworkTelemetry: agent.recordsNetworkTelemetry,
            isOnStage: isOnStage,
            runTerminal: console.terminalRunner(for: agent.hostID),
            stageImage: console.imageStager(for: agent.hostID),
            stageFile: console.fileStager(for: agent.hostID),
            composer: composer,
            paneHistory: console.makePaneHistory(for: agent),
            closePane: { [weak console] in
                guard let console else { throw CancellationError() }
                try await console.closePane(paneID, on: hostID)
            },
            invalidateMosh: { [weak console] cause in
                guard let console else { return }
                console.invalidateMosh(for: hostID, cause: cause)
            },
            onUserInput: { [weak console] in
                console?.noteUserInput(
                    to: ConsoleAgent.ID(hostID: hostID, paneID: paneID))
            })
    }

    private var focusViewingState: AgentFocusCoordinator.ViewingState {
        let current = console.listedAgent(agent.id)
        return .init(
            agentID: agent.id,
            terminalID: current?.agent.terminalID ?? agent.agent.terminalID,
            transportGeneration: console.connectionGeneration(for: agent),
            status: current?.agent.status,
            isHostReady: console.hostStatuses[agent.hostID] == .connected
                && !console.hostsAwaitingSnapshot.contains(agent.hostID),
            isSceneActive: scenePhase == .active,
            isOnStage: hasAppeared && isOnStage())
    }

    private func updateFocus() {
        let state = focusViewingState
        focus.update(state) { id in
            // A queued task can begin after selection moved, before SwiftUI
            // has delivered the next onChange callback.
            guard focusViewingState == state else { throw CancellationError() }
            try await console.focusAgent(id.paneID, on: id.hostID)
        }
    }

    /// Drops a Composer or Direct Input keyboard that was up when the iPad
    /// list covered the Agent, so no keystroke reaches the hidden terminal.
    /// This responder-chain action can miss the terminal, so
    /// `AgentTerminalView` also resigns its own surface then.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    var body: some View {
        ZStack {
            if showsChat, let transcript {
                ChatAgentView(
                    agent: agent, transcript: transcript, composer: composer,
                    greeting: chatGreeting,
                    focusesInputOnAppear: focusesChatInput,
                    loadMedia: chatMediaLoader,
                    ultimate: ultimateChatContext,
                    stopRun: agent.backend.hasTerminal ? nil : {
                        // Keep Stop if the run did not stop, like Allow/Cancel.
                        try? await console.abortAgentRun(agent.agent.paneID, on: agent.hostID)
                    },
                    launchNotice: console.serverLaunchNotices[agent.id],
                    isStillPresented: { isVisible() && showsChat },
                    onArchive: Self.chatArchiveAction(for: agent, console: console, onClosed: onClosed),
                    onShowTerminal: { choseTerminal = true })
                .onAppear {
                    if !askedChatInputFocus {
                        askedChatInputFocus = true
                        focusesChatInput = console.consumeChatInputFocus(agent.id)
                    }
                    bindChatComposer()
                    detailCrossfade?.contentDidAppear()
                    // The Chat view raises no terminal keyboard, so a
                    // handoff armed for this Agent must not outlive it.
                    keyboardHandoff.cancel(for: agent.id)
                }
                .onDisappear {
                    // A spurious disappear (the chat stays on screen,
                    // with no appear after it) keeps the Composer bound.
                    guard !(isVisible() && showsChat) else { return }
                    console.dismissServerLaunchNotice(for: agent.id)
                    composer.bindBlockedInsert(nil)
                    // Show Terminal → Show Chat must not raise it again.
                    focusesChatInput = false
                }
                // A turn can end while the app is away or the Host is
                // offline, on the status the chat last saw.
                .onChange(of: activity.activationCount) {
                    Task { await transcript.refresh() }
                }
                .onChange(of: console.connectionGeneration(for: agent)) {
                    Task { await transcript.refresh() }
                }
            } else if choseTerminal, let pane = console.linkedTerminalAgent(for: agent) {
                // A separate detail owns the pane's Composer, Attach, retention
                // and backend actions; the thread keeps its native Chat state.
                AnyView(AgentDetailView(
                    agent: pane, console: console, terminal: terminal, hosts: hosts,
                    activity: activity, keyboardHandoff: keyboardHandoff,
                    keyboardInset: keyboardInset,
                    stage: AgentDetailStage(isVisible: isVisible, terminalAccess: {
                        pane.backend.terminalAccess(sceneRouting?.terminalAccess(for: pane.hostID) ?? .holds)
                    }).linkedTerminal(pane,
                        isPresented: { [choseTerminal = $choseTerminal] in choseTerminal.wrappedValue },
                        current: { console.linkedTerminalAgent(for: agent) }),
                    onSwitch: onSwitch, onClosed: { choseTerminal = false },
                    onMarkedUnread: onMarkedUnread, isLinkedTerminal: true))
                    .id(AgentDetailIdentity(pane))
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Show Chat", systemImage: "bubble.left.and.bubble.right") {
                                choseTerminal = false
                            }
                        }
                    }
            } else if let attach, isChatAgent {
                terminalView(attach)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Show Chat", systemImage: "bubble.left.and.bubble.right") {
                                choseTerminal = false
                            }
                        }
                    }
            } else if let attach {
                terminalView(attach)
            }
        }
        .onChange(of: agent.linkedTerminal) { _, link in
            if agent.backend.isServerChat, link == nil { choseTerminal = false }
        }
        .onChange(of: showsChat) { _, chat in
            if chat { presentChat() } else { presentTerminal() }
        }
        .onChange(of: showsChat, initial: true) { _, chat in
            onChatPresentationChange(chat)
        }
        .onChange(of: isCovered, initial: true) { _, covered in
            commandsAreCovered = covered
            if covered { dismissKeyboard() }
        }
        .onAppear {
            hasAppeared = true
            // Taken either way so it cannot outlive this visit; a Chat
            // view is no terminal launch, and its later Show Terminal is not.
            let launch = console.consumeAgentLaunch(agent.id)
            if !showsChat, let launch { agentLaunch = launch }
            prepareRetainedAgent()
            updateFocus()
        }
        .onChange(of: attach?.terminalStatus == .live) { wasLive, isLive in
            if wasLive, !isLive { agentLaunch = nil }
        }
        .onChange(of: focusViewingState) {
            updateFocus()
        }
        .onDisappear {
            hasAppeared = false
            focus.leave()
            if isLinkedTerminal {
                Task { @MainActor in
                    await Task.yield()
                    guard !isOnStage() else { return }
                    if let retainedAgent {
                        console.agentTerminals.release(retainedAgent, ownerID: retentionOwnerID)
                    }
                    // Show Chat must release the PTY now, not after the
                    // retained terminal's idle timeout pins the pane size.
                    attach?.leaveForTerminalHandoff()
                }
            }
        }
        .onChange(of: console.connectionGeneration(for: agent)) {
            prepareRetainedAgent()
        }
        .onChange(of: activity.activationCount) { prepareRetainedAgent() }
        // An alert, not a confirmationDialog: iOS 26 draws the dialog as a
        // popover anchored to the view it is attached to, here the whole
        // detail, far from the More menu or Toolbar button that asked, so its
        // arrow pointed into the terminal.
        .alert("Open Terminal", isPresented: $isChoosingTerminal) {
            ForEach(workspaceShells) { shell in
                Button(shellChoiceTitle(shell)) { openShell(shell.id, handoffToken: shellHandoffToken) }
            }
            if agent.shellTerminalCreationRequest != nil {
                Button("New Terminal") { createWorkspaceTerminal() }
            }
            Button("Cancel", role: .cancel) {
                keyboardHandoff.cancelShellTerminal(ifOwnedBy: shellHandoffToken)
            }
                .tint(Brand.Colors.quietAction)
        }
        .quietCancelAlert("Couldn't Open Terminal", isPresented: Binding(
            get: { terminalOpenFailure != nil }, set: { if !$0 { terminalOpenFailure = nil } })
        ) {
            Button("OK", role: .cancel) { terminalOpenFailure = nil }
                .tint(Brand.Colors.quietAction)
        } message: {
            Text(terminalOpenFailure ?? "")
        }
        // The same-Host handoff between windows rides the Attach store's own
        // leave and rejoin: the window that loses the channel releases its
        // Attach, and the one that gains it rejoins behind that release
        // through the Host's terminal serialization.
        .onChange(of: terminalAccess, initial: true) {
            applyTerminalAccess()
        }
        .modifier(ConsoleDetailPresentationRegistration(
            agentID: agent.id,
            isPresenting: terminalOpenFailure != nil || isChoosingTerminal))
    }

    private func terminalView(_ attach: AgentAttachStore) -> some View {
        AgentTerminalView(
            agent: agent,
            console: console,
            terminal: terminal,
            hosts: hosts,
            activity: activity,
            keyboardHandoff: keyboardHandoff,
            keyboardInset: keyboardInset,
            isOnStage: isOnStage,
            // A detail that lost its Host channel to another window is still
            // on screen, and its sheets still cover commands. One the iPad
            // list covers keeps its Attach but takes no commands.
            isCommandOnStage: { [isVisible, commandsAreCovered = $commandsAreCovered] in
                isVisible() && !commandsAreCovered.wrappedValue
            },
            onSwitch: onSwitch,
            onClosed: onClosed,
            onMarkedUnread: onMarkedUnread,
            canOpenTerminal: (!workspaceShells.isEmpty || agent.shellTerminalCreationRequest != nil)
                && terminalAccess == .holds,
            isOpeningTerminal: isResolvingTerminal,
            openTerminal: { openWorkspaceTerminal() },
            composer: composer,
            attachStore: attach,
            retainedSurface: retainedAgent?.surfaceRetention,
            onRetainDeparture: retainedAgent.map { entry in
                { keepingKeyboard in
                    console.agentTerminals.release(
                        entry, ownerID: retentionOwnerID, keepingKeyboard: keepingKeyboard)
                }
            },
            lastFrame: lastFrame,
            launch: agentLaunch,
            inputMode: inputMode,
            // Retention swaps `attach` on appear and rebuilds this view; the
            // build before that swap is a placeholder and must not spend the
            // keyboard handoff meant for the real one.
            inheritsKeyboardHandoff: !permitsRetention || retainedAgent != nil)
        .id(ObjectIdentifier(attach))
    }

    /// The Workspace's other shell rows: what Open Terminal offers.
    private var workspaceShells: [ConsoleAgent] {
        console.agents.filter {
            $0.isShell && $0.id != agent.id && $0.hostID == agent.hostID
                && $0.agent.workspaceID == agent.agent.workspaceID
        }
    }

    private func shellChoiceTitle(_ shell: ConsoleAgent) -> String {
        let title = shell.agent.title.isEmpty ? shell.agent.displayName : shell.agent.title
        guard let tab = shell.tabLabel, !tab.isEmpty, tab != title else { return title }
        return "\(title) · \(tab)"
    }

    /// Opens a shell row's own detail. A keyboard raised when Open Terminal
    /// or New Terminal was tapped — armed before the destination was known —
    /// carries over to it like any Agent switch, in the mode it was armed in.
    private func openShell(_ id: ConsoleAgent.ID, handoffToken: UUID?) {
        if let mode = keyboardHandoff.consumeShellTerminal(ifOwnedBy: handoffToken) {
            keyboardHandoff.arm(for: id, mode: mode)
        }
        onSwitch(id)
    }

    private func openWorkspaceTerminal() {
        shellHandoffToken = keyboardHandoff.shellTerminalToken
        if createdTerminal != nil { createWorkspaceTerminal(); return }
        switch workspaceShells.count {
        case 0: createWorkspaceTerminal()
        case 1: openShell(workspaceShells[0].id, handoffToken: shellHandoffToken)
        default: isChoosingTerminal = true
        }
    }

    /// Open Terminal routes back to the tab this detail already created,
    /// so a creation that has not reached the Console yet is retried rather
    /// than duplicated.
    private func createWorkspaceTerminal() {
        let handoffToken = shellHandoffToken
        if let sampleConnect {
            keyboardHandoff.cancelShellTerminal(ifOwnedBy: handoffToken)
            sampleConnect()
            return
        }
        guard !isResolvingTerminal, let request = agent.shellTerminalCreationRequest else {
            keyboardHandoff.cancelShellTerminal(ifOwnedBy: handoffToken)
            return
        }
        isResolvingTerminal = true
        Task { @MainActor in
            defer { isResolvingTerminal = false }
            do {
                let created: ShellTerminalIdentity
                if let createdTerminal {
                    created = createdTerminal
                    await console.refreshTerminalInventory(on: agent.hostID)
                } else {
                    // The new tab joins this row's Workspace, so it runs
                    // on the row's backend.
                    created = try await console.createShellTerminal(
                        request, on: agent.hostID, backend: agent.backend)
                    createdTerminal = created
                }
                let id = ConsoleAgent.ID(hostID: agent.hostID, paneID: created.paneID)
                await console.waitForAgent(id)
                guard console.agents.contains(where: { $0.id == id }) else {
                    keyboardHandoff.cancelShellTerminal(ifOwnedBy: handoffToken)
                    terminalOpenFailure = "The terminal was created, but its Workspace hasn't refreshed yet. Try Open Terminal again to refresh it."
                    return
                }
                if isVisible() {
                    openShell(id, handoffToken: handoffToken)
                } else {
                    keyboardHandoff.cancelShellTerminal(ifOwnedBy: handoffToken)
                }
            } catch {
                keyboardHandoff.cancelShellTerminal(ifOwnedBy: handoffToken)
                terminalOpenFailure = Self.terminalCreationFailureMessage(
                    for: error, backend: agent.backend)
            }
        }
    }

    /// A definitive rejection by the row's backend created nothing; anything
    /// else may have created a tab the reply never confirmed, so the user
    /// checks the Host instead of blindly retrying into a duplicate.
    static func terminalCreationFailureMessage(
        for error: any Error, backend: HostBackend = .herdr
    ) -> String {
        switch error {
        case let api as HerdrAPIError:
            "\(backend.displayName) couldn't create the terminal: \(api.message)"
        case TransportError.apiRejected(_, let message):
            "\(backend.displayName) couldn't create the terminal: \(message)"
        default:
            "The request did not finish clearly. A new tab may already exist on the Host. Check the Host before trying again."
        }
    }
}
