import PhotosUI
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Stable in-process seam for exercising Agent-detail behavior without relying
/// on hosted SwiftUI accessibility. iOS 26 does not materialize those elements
/// without an assistive client; button wiring remains UI-test coverage.
@MainActor
final class AgentTerminalInteractionProbe {
    private var tapMessageAgentAction: (() -> Void)?
    private var tapTerminalKeyboardAction: (() -> Void)?
    private var tapDictateToAgentAction: (() -> Void)?
    private var sendQuickKeyHandler: ((AgentQuickKey) -> Void)?
    private var performToolbarItemAction: ((AgentToolbarItem.Content) -> Void)?
    private var jumpOlderAction: (() -> Void)?
    private var jumpNewerAction: (() -> Void)?
    private var readInputMode: (() -> AgentInputMode)?
    private var readTerminalKeyboardUp: (() -> Bool)?
    private(set) var inputChromeMountCount = 0
    /// The Toolbar layout as last handed to the input chrome.
    private(set) var toolbarLayout: AgentToolbarLayout?

    var isConnected: Bool { tapMessageAgentAction != nil }

    /// Whether Message Agent (the Composer card) is open; nil while
    /// disconnected.
    var isMessageAgentOpen: Bool? {
        readInputMode.map { $0() == .composer }
    }

    /// Whether ⌨ is lit: the terminal keyboard (system or tools) is up.
    var isTerminalKeyboardUp: Bool? {
        readTerminalKeyboardUp?()
    }

    /// 💬, as a tap on the Toolbar would.
    @discardableResult
    func tapMessageAgent() -> Bool {
        guard let tapMessageAgentAction else { return false }
        tapMessageAgentAction()
        return true
    }

    /// ⌨, as a tap on the Toolbar would.
    @discardableResult
    func tapTerminalKeyboard() -> Bool {
        guard let tapTerminalKeyboardAction else { return false }
        tapTerminalKeyboardAction()
        return true
    }

    /// 🎤, as a tap on the Toolbar would.
    @discardableResult
    func tapDictateToAgent() -> Bool {
        guard let tapDictateToAgentAction else { return false }
        tapDictateToAgentAction()
        return true
    }

    @discardableResult
    func sendQuickKey(_ key: AgentQuickKey) -> Bool {
        guard let sendQuickKeyHandler else { return false }
        sendQuickKeyHandler(key)
        return true
    }

    /// Runs a Toolbar item through Agent detail's dispatcher, as a tap on
    /// the Toolbar would (a ⌃C Combo, a Custom Key, a sticky modifier chip,
    /// Paste).
    @discardableResult
    func performToolbarItem(_ content: AgentToolbarItem.Content) -> Bool {
        guard let performToolbarItemAction else { return false }
        performToolbarItemAction(content)
        return true
    }

    @discardableResult
    func jumpOlderMessage() -> Bool {
        guard let jumpOlderAction else { return false }
        jumpOlderAction()
        return true
    }

    @discardableResult
    func jumpNewerMessage() -> Bool {
        guard let jumpNewerAction else { return false }
        jumpNewerAction()
        return true
    }

    /// Viewport frames delivered to the jump controller through Agent detail's
    /// production `onViewportTextChanged` seam.
    private(set) var messageJumpViewportFrames: [String] = []

    /// Latest frame retained by ``AgentMessageJumpWiring`` after a viewport
    /// delivery — proves the production path reached the wiring, not only a
    /// probe tap beside it.
    private var messageJumpLastViewportFrame: (() -> String?)?

    var lastMessageJumpViewportFrame: String? {
        messageJumpLastViewportFrame?()
    }

    fileprivate func connect(
        tapMessageAgent: @escaping () -> Void,
        tapTerminalKeyboard: @escaping () -> Void,
        tapDictateToAgent: @escaping () -> Void,
        performToolbarItem: @escaping (AgentToolbarItem.Content) -> Void,
        inputMode: @escaping () -> AgentInputMode,
        terminalKeyboardUp: @escaping () -> Bool
    ) {
        tapMessageAgentAction = tapMessageAgent
        tapTerminalKeyboardAction = tapTerminalKeyboard
        tapDictateToAgentAction = tapDictateToAgent
        performToolbarItemAction = performToolbarItem
        readInputMode = inputMode
        readTerminalKeyboardUp = terminalKeyboardUp
    }

    fileprivate func connectMessageJump(
        jumpOlder: @escaping () -> Void,
        jumpNewer: @escaping () -> Void,
        lastViewportFrame: @escaping () -> String?
    ) {
        jumpOlderAction = jumpOlder
        jumpNewerAction = jumpNewer
        messageJumpLastViewportFrame = lastViewportFrame
    }

    fileprivate func messageJumpDidReceiveViewportText(_ text: String) {
        messageJumpViewportFrames.append(text)
    }

    fileprivate func inputChromeDidAppear(
        toolbarLayout: AgentToolbarLayout,
        sendQuickKey: @escaping (AgentQuickKey) -> Void
    ) {
        inputChromeMountCount += 1
        self.toolbarLayout = toolbarLayout
        sendQuickKeyHandler = sendQuickKey
    }

    fileprivate func disconnect() {
        tapMessageAgentAction = nil
        tapTerminalKeyboardAction = nil
        tapDictateToAgentAction = nil
        sendQuickKeyHandler = nil
        performToolbarItemAction = nil
        readInputMode = nil
        readTerminalKeyboardUp = nil
        jumpOlderAction = nil
        jumpNewerAction = nil
        messageJumpLastViewportFrame = nil
        messageJumpViewportFrames = []
        inputChromeMountCount = 0
    }

    fileprivate func inputChromeDidDisappear() {
        inputChromeMountCount = max(0, inputChromeMountCount - 1)
        guard inputChromeMountCount == 0 else { return }
        sendQuickKeyHandler = nil
    }

    fileprivate func updateToolbarLayout(_ layout: AgentToolbarLayout) {
        guard inputChromeMountCount > 0 else { return }
        toolbarLayout = layout
    }
}

@MainActor
private final class WeakAgentTerminalInteractionProbe {
    weak var value: AgentTerminalInteractionProbe?

    init(_ value: AgentTerminalInteractionProbe) {
        self.value = value
    }
}

/// The live Ghostty surface used by Agent detail, above the Toolbar: one bar
/// in every state, with Message Agent (💬), Terminal Keyboard (⌨) and Dictate
/// to Agent (🎤) fixed at its trailing edge. Message Agent opens the Composer
/// card (ADR 0013), focusing its text field when 💬 opens it, and keeps the terminal display-only
/// for typing; ⌨ enables Ghostty local input so the system keyboard types the
/// live Attach PTY (Direct Input, ADR 0016). The two never coexist.
struct AgentTerminalView: View {
    let agent: ConsoleAgent
    private let console: ConsoleStore
    private let terminal: TerminalSettings
    /// Passed through to the new-agent sheet, which keeps its Host picker for
    /// the Console's own entry point even though this screen pre-selects one.
    private let hosts: [Host]
    private let activity: AppActivityCoordinator
    /// Keeps the keyboard up across the terminal rebuild an Agent switch
    /// forces; owned by the Console so it survives that rebuild.
    private let keyboardHandoff: TerminalKeyboardHandoff
    /// False for the placeholder Agent detail builds before its retained
    /// terminal is prepared: that instance is torn down a moment later, and
    /// spending the one-shot handoff there would leave the real screen
    /// without it. See `AgentDetailView.prepareRetainedAgent`.
    private let inheritsKeyboardHandoff: Bool
    /// How much of the bottom edge the keyboard covers. Console-owned for the
    /// same reason as the handoff: a switch that inherits a raised keyboard
    /// must lay the terminal out at the right height on its first frame.
    private let keyboardInset: TerminalKeyboardInset
    /// Router truth used to distinguish a real navigation from SwiftUI's
    /// same-screen disappear/appear churn.
    private let isOnStage: () -> Bool
    /// Whether this screen's presentations gate the window's keyboard
    /// commands; defaults to `isOnStage`.
    private let isCommandOnStage: () -> Bool
    /// Opens the Agent the new-agent sheet started. The owner moves the
    /// selection, exactly as a tap in the Agent list would.
    private let onSwitch: (ConsoleAgent.ID) -> Void
    /// Where toolbar Paste reads from; tests inject a fake.
    private let clipboard: TerminalClipboard
    /// Leaves the screen after a confirmed close. A callback rather than
    /// `dismiss`: as the root of the Console's detail this view has nothing
    /// to dismiss — the owner clears the sidebar selection instead, which
    /// also pops the collapsed stack on iPhone.
    private let onClosed: () -> Void
    /// Leaves the screen after Mark as Unread, for the same reason as
    /// `onClosed`: the owner returns to the Console index.
    private let onMarkedUnread: () -> Void
    private let canOpenTerminal: Bool
    /// False for a whole-session Attach that has no addressable inventory pane.
    private let paneActionsAvailable: Bool
    private let isOpeningTerminal: Bool
    private let openTerminal: () -> Void
    private let composer: AgentComposerStore
    private let interactionProbe: WeakAgentTerminalInteractionProbe?
    private let retainedSurface: TerminalSurfaceRetention?
    /// Called with whether the next screen takes the keyboard over, so the
    /// retained surface knows not to dismiss it on the way out.
    private let onRetainDeparture: ((_ keepingKeyboard: Bool) -> Void)?
    /// Set when the New Agent sheet opened this Agent (#96).
    private let launch: AgentLaunchNote?
    /// Follows the Agent's own session file for the usage strip (#325).
    @State private var sessionUsage = AgentSessionUsageStore()
    @State private var attach: AgentAttachStore
    /// Quick Look, or the Markdown sheet, for a file path tapped in the
    /// terminal or picked from the strip's list.
    @State private var filePreview: TerminalFilePreviewStore
    /// Whether the Markdown sheet shows the raw text rather than the
    /// rendered document: one choice for the whole device, read again each
    /// time a sheet opens, so another window's flip carries over.
    @State private var markdownShowsRaw = RecentSelectionsStore().markdownPreviewShowsRaw
    /// The status row's strip of files the terminal printed paths to
    /// (`attach.attachMediaCandidates`): images as thumbnails, Markdown and
    /// PDFs as glyphs. Owned here, not by the strip, so a status-row redraw
    /// never fetches again. Every pane gets it, a Shell's too: this screen
    /// always has its `ConsoleAgent`, whose cwd resolves relative paths.
    @State private var mediaStrip = TerminalMediaStripModel()
    /// Whether the strip's list of files and links is up.
    @State private var isShowingFilesAndLinks = false
    /// The link a list row picked, opened once the list has gone, so its
    /// Couldn't Open Link recovery, presented from here, never meets the
    /// closing list. A file row instead previews over the list, which stays
    /// up (`TerminalFilePreviewPresenters`). The last tap wins.
    @State private var pendingListLink: AttachLink?
    /// Whether the list, while up, started a file preview, which its closing
    /// then stops. A load a terminal tap started before the list opened
    /// carries on.
    @State private var listStartedPreview = false
    /// A tapped link whose target the screen does not show, awaiting the
    /// user's go-ahead, with the destination its confirmation spells out.
    @State private var pendingLink: PendingLinkConfirmation?
    /// Works out a confirmation's destination: a `~` path needs the Host's
    /// home first. A later tap's confirmation replaces it.
    @State private var linkConfirmation: Task<Void, Never>?

    /// Nil for agent kinds without a skills source catalog; the Keys
    /// keyboard hides the Skills tab in that case.
    @State private var skills: SkillsPaneStore?
    @State private var keyboardControl = TerminalKeyboardControl()
    @State private var messageJump: AgentMessageJumpWiring
    /// Whether Message Agent is open. Every Agent view opens on the Toolbar
    /// alone; the Agent detail passes its own, which outlives the rebuild a
    /// new Attach store forces.
    @State private var inputMode: AgentInputModeState
    /// Dictate to Agent's recorder. Owned here, not by the chrome, so the
    /// view's own state decides nothing about it: opening or closing Message
    /// Agent never interrupts a recording.
    @State private var dictationSender: DictationSender
    @State private var composerKeyboardPresentation: AgentComposerKeyboardPresentation = .hidden
    /// One-shot: 💬 asks the freshly opened Composer to focus its text field.
    @State private var composerFocusRequested = false
    /// Message Agent's visible system keyboard moving to the terminal (⌨
    /// while typing in Message Agent): Composer stays mounted until the
    /// terminal confirms first-responder ownership, and the inset is released
    /// once its keyboard frame settles. See ``DirectKeyboardHandoffMachine``.
    @State private var keyboardHandoffToDirect = DirectKeyboardHandoffMachine()
    /// Direct Input's tools dock, separate from Composer focus presentation.
    @State private var usesDirectToolsKeyboard = false
    /// Holds `.system` presentation across the Tools→iOS coalesce window so
    /// the terminal does not expand then shrink while UIKit re-shows the
    /// software keyboard. Cleared once `keyboardInset.height` becomes positive
    /// (or on resign / mode change). Never set for bare first-responder /
    /// hardware.
    @State private var expectsDirectSystemKeyboard = false
    /// Survives same-screen terminal replacement so a raised Direct Input
    /// keyboard is reclaimed without raising one that was down.
    @State private var directKeyboardIntent = DirectInputKeyboardIntent()
    /// The last frame this screen's terminal painted, held while a
    /// replacement pipeline connects (#21). The Agent detail passes its own,
    /// which outlives this screen.
    @State private var lastFrame: TerminalLastFrame
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var isSelectingPhoto = false
    @State private var isSelectingFile = false
    /// The conversation this device kept for the Agent, offered to read while
    /// the terminal is not live (`OfflineReading`).
    @State private var savedTranscript: SavedTranscript?
    /// How long the terminal has been plainly connecting on a device with a
    /// network; the Read offer waits `OfflineReading.slowConnectDelay` so a
    /// normal (even slow) open shows none.
    @State private var reconnectingFor: Duration = .zero
    /// The offline reader covers the terminal, above the input chrome.
    @State private var isReadingOfflineCopy = false
    /// What the screen measures for the offline reader (the input chrome's
    /// top edge, the terminal's region, the queued rows' height). Its own
    /// observable box so that this view's body does not re-run for it.
    @State private var readerGeometry = OfflineReaderGeometry()
    @State private var isConfirmingClose = false
    @State private var isStartingAgent = false
    @State private var isManagingSnippets = false
    @State private var isShowingSkillsPicker = false
    @State private var isRenamingAgent = false
    /// The skill whose full document is on screen; set from the Skills
    /// pane's long-press menu.
    @State private var viewingSkill: AgentSkill?
    @State private var isRenamingWorkspace = false
    @State private var isShowingWorktree = false
    @State private var worktreeStore: WorktreeDetailStore?
    @State private var closeErrorMessage: String?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The window's leading safe-area gutter, where landscape Back floats.
    @State private var leadingSafeAreaInset: CGFloat = 0
    /// The bottom safe area the Toolbar rests on: the Agent Footer's band.
    /// Nil until geometry first reports, when the window's inset stands in.
    @State private var measuredBottomSafeAreaInset: CGFloat?
    /// Where this screen's top edge sits in its window: 0 everywhere but
    /// under the Sample's label, which already keeps it below the clock.
    @State private var topInWindow: CGFloat = 0
    /// The Agent Footer's Branch field, followed only while it is configured.
    @State private var gitBranch = AgentGitBranchStore()
    /// Where the iPad slide-over's sidebar toggle floats over this Agent.
    @Environment(\.consoleDetailHeaderSlot) private var sidebarToggleSlot
    /// Bumped by a tap that slid the portrait iPad list off this Agent.
    @Environment(\.consoleDetailFocusTaps) private var detailFocusTaps
    /// The open portrait iPad list covers this Agent.
    @Environment(\.consoleDetailIsCovered) private var isDetailCovered
    /// The scene root's window, known before this screen first renders.
    @Environment(\.sceneWindow) private var sceneWindow
    @Environment(\.detailCrossfade) private var detailCrossfade
    /// Each Agent's latest frame across screens and launches; nil when not
    /// injected (tests, previews).
    @Environment(\.agentLastFrames) private var lastFrames
    /// This view's own window, for hosts without a scene root.
    @State private var mountedWindow = WindowReference()
    /// Nil outside a scene root, where this screen always holds its Host's
    /// terminal channel.
    @Environment(\.agentSceneRouting) private var sceneRouting
    @Environment(\.sampleConnect) private var sampleConnect

    private var isDirectInput: Bool { inputMode.isDirect }

    /// The status bar height of the window this terminal is in, less what
    /// lies above this screen's top edge. Another window's inset is wrong
    /// under Stage Manager, where windows sit at different distances from
    /// the status bar.
    private var statusBarInset: CGFloat {
        let windowTop = (sceneWindow?.window ?? mountedWindow.window)?.safeAreaInsets.top ?? 0
        return max(0, windowTop - max(0, topInWindow))
    }

    private var bottomSafeAreaInset: CGFloat {
        measuredBottomSafeAreaInset
            ?? (sceneWindow?.window ?? mountedWindow.window)?.safeAreaInsets.bottom ?? 0
    }

    init(
        agent: ConsoleAgent,
        console: ConsoleStore,
        terminal: TerminalSettings,
        hosts: [Host],
        activity: AppActivityCoordinator,
        keyboardHandoff: TerminalKeyboardHandoff,
        keyboardInset: TerminalKeyboardInset,
        isOnStage: @escaping () -> Bool,
        isCommandOnStage: (() -> Bool)? = nil,
        onSwitch: @escaping (ConsoleAgent.ID) -> Void,
        onClosed: @escaping () -> Void,
        onMarkedUnread: @escaping () -> Void = {},
        canOpenTerminal: Bool = false,
        isOpeningTerminal: Bool = false,
        openTerminal: @escaping () -> Void = {},
        composer: AgentComposerStore,
        attachStore: AgentAttachStore? = nil,
        retainedSurface: TerminalSurfaceRetention? = nil,
        onRetainDeparture: ((_ keepingKeyboard: Bool) -> Void)? = nil,
        lastFrame: TerminalLastFrame? = nil,
        launch: AgentLaunchNote? = nil,
        inputMode: AgentInputModeState? = nil,
        inheritsKeyboardHandoff: Bool = true,
        interactionProbe: AgentTerminalInteractionProbe? = nil,
        clipboard: TerminalClipboard = .system,
        dictationSender: DictationSender? = nil,
        paneActionsAvailable: Bool = true
    ) {
        self.agent = agent
        self.console = console
        self.terminal = terminal
        _dictationSender = State(initialValue: dictationSender ?? DictationSender())
        self.hosts = hosts
        self.activity = activity
        self.keyboardHandoff = keyboardHandoff
        self.inheritsKeyboardHandoff = inheritsKeyboardHandoff
        self.keyboardInset = keyboardInset
        // Every Agent view opens on the Toolbar alone, so only an inherited
        // tools keyboard starts it on the tools dock.
        _usesDirectToolsKeyboard = State(
            initialValue: paneActionsAvailable && keyboardHandoff.mode(for: agent.id) == .controls)
        self.isOnStage = isOnStage
        self.isCommandOnStage = isCommandOnStage ?? isOnStage
        self.onSwitch = onSwitch
        self.onClosed = onClosed
        self.onMarkedUnread = onMarkedUnread
        self.canOpenTerminal = canOpenTerminal
        self.paneActionsAvailable = paneActionsAvailable
        self.isOpeningTerminal = isOpeningTerminal
        self.openTerminal = openTerminal
        self.composer = composer
        self.interactionProbe = interactionProbe.map(WeakAgentTerminalInteractionProbe.init)
        self.retainedSurface = retainedSurface
        self.onRetainDeparture = onRetainDeparture
        self.clipboard = clipboard
        _lastFrame = State(initialValue: lastFrame ?? TerminalLastFrame())
        self.launch = launch
        _inputMode = State(initialValue: inputMode ?? AgentInputModeState())
        let attach = attachStore ?? AgentAttachStore(
            target: agent.attachTarget,
            transportGeneration: console.connectionGeneration(for: agent),
            recordsNetworkTelemetry: agent.recordsNetworkTelemetry,
            isOnStage: isOnStage,
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
        _attach = State(initialValue: attach)
        _skills = State(initialValue: Self.makeSkillsStore(for: agent, console: console))
        let hostID = agent.hostID
        _filePreview = State(
            initialValue: TerminalFilePreviewStore(
                read: console.previewFileReader(for: hostID),
                resolveHome: { [console] in try await console.remoteHomeDirectory(on: hostID) }))
        let messageJump = AgentMessageJumpWiring(
            profile: .forAgentKind(agent.agent.kind)
        ) { [weak console] in
            guard let console else { throw CancellationError() }
            return try await console.readChatTranscriptSaving(for: agent)
        }
        // The one transcript read also settles the Files & Links row breaks
        // the screen alone cannot.
        messageJump.onTranscript = { [weak attach] snapshot in
            attach?.receiveTranscript(snapshot)
        }
        // The Attach's own pane history (tmux only): this init runs again
        // on every parent re-render, so it must not make one of its own.
        messageJump.scrollControl.paneHistory = attach.paneHistory
        _messageJump = State(initialValue: messageJump)
    }

    /// The Skills pane's store, or nil when this agent's kind has no skills
    /// source catalog. Captures launch-time context on purpose: the project
    /// root is the worktree checkout or launch cwd, never the live cwd.
    private static func makeSkillsStore(
        for agent: ConsoleAgent, console: ConsoleStore
    ) -> SkillsPaneStore? {
        guard let kind = SupportedAgentKind(rawValue: agent.agent.kind) else { return nil }
        let sources = SkillSourceCatalog.sources(for: kind)
        guard !sources.isEmpty else { return nil }
        let projectRoot = agent.skillsProjectRoot
        return SkillsPaneStore(
            commandPrefixes: sources.map(\.commandPrefix)
        ) { [console] forceRefresh in
            try await console.fetchSkills(
                kind: kind,
                projectRoot: projectRoot,
                on: agent.hostID,
                forceRefresh: forceRefresh)
        }
    }

    /// Follows the Agent's session file for the usage strip (#325).
    ///
    /// The interval is deliberately unhurried: the figures are a running total
    /// a reader glances at, not a live meter, and every refresh costs a round
    /// trip. An Agent with no session file on the Host clears the strip and
    /// stops, so nothing polls for a figure that cannot arrive.
    private func followSessionUsage() async {
        guard let path = agent.sessionFilePath else {
            sessionUsage.clear()
            return
        }
        let read = console.sessionFileReader(for: agent.hostID)
        let resolveContextWindow = console.modelContextWindowResolver(for: agent.hostID)
        while !Task.isCancelled {
            await sessionUsage.refresh(
                path: path, read: read, resolveContextWindow: resolveContextWindow)
            do {
                try await Task.sleep(for: .seconds(Self.sessionUsageInterval))
            } catch {
                return
            }
        }
    }

    private static let sessionUsageInterval: Double = 5

    private var terminalScreen: TerminalScreenView {
        var screen = TerminalScreenView(feed: attach.terminalFeed)
        screen.retention = retainedSurface
        // A tap reads a URL a row break split as the Attach Links list does,
        // with what the stream and the Agent's transcript hold whole.
        screen.knownLinkTargets = { [weak attach = attach] in
            attach?.knownLinkTargets ?? AttachKnownTargets()
        }
        #if DEBUG
        screen.onSurfaceAttached = {
            attach.terminalSurfaceDidAttach()
        }
        #endif
        screen.onSizeChanged = { cols, rows in
            attach.viewDidResize(cols: cols, rows: rows)
        }
        screen.onViewportTextChanged = { text in
            attach.viewportTextDidChange(text)
            messageJump.deliverViewportText(text)
            interactionProbe?.value?.messageJumpDidReceiveViewportText(text)
        }
        screen.onSend = { keystrokes in attach.send(keystrokes) }
        screen.onScroll = { sequence, rows in
            attach.scroll(sequence, rows: rows)
        }
        screen.onPaste = { text, bracketed in
            attach.requestPaste(text, bracketedPaste: bracketed)
        }
        screen.keyboardControl = keyboardControl
        screen.scrollControl = messageJump.scrollControl
        // Agent input is natural-language authored text in both Composer and
        // Direct Input. Matching traits lets UIKit retain one Apple keyboard
        // context across the responder transfer; a shell row keeps the
        // command-oriented defaults, matching its Composer.
        screen.textInputStyle = agent.isShell ? .terminal : .naturalLanguage
        screen.initialKeyboardMode = usesDirectToolsKeyboard ? .controls : .text
        // Keep the destination terminal enabled until Composer-to-Direct has
        // fully settled. The reverse handoff must disable this outgoing
        // terminal as soon as Composer accepts first responder.
        let composerToDirectHandoffID = keyboardHandoffToDirect.requestID
        screen.isLocalInputEnabled = isDirectInput || composerToDirectHandoffID != nil
        // Plain keys and arrows reach the terminal with the keyboard down
        // (#80), unless the tools dock deliberately owns input without a
        // responder. A reconnect must not replace that dock with iOS input.
        screen.hardwareKeyboardAutoFocus = !usesDirectToolsKeyboard
        screen.claimsKeyboard = {
            [
                keyboardHandoff,
                inheritsKeyboardHandoff,
                agent,
                inputMode,
                directKeyboardIntent,
                composerToDirectHandoffID,
                keyboardInset,
                usesDirectToolsKeyboard,
            ] in
            if composerToDirectHandoffID != nil {
                return directKeyboardIntent.wantsKeyboard
            }
            guard inputMode.isDirect else { return false }
            // The shared inset can still be paused by the outgoing Agent.
            // Adopt this surface's mode before UIKit sends its first frame.
            if usesDirectToolsKeyboard {
                keyboardInset.pauseHeightCapture()
            } else {
                keyboardInset.resumeHeightCapture()
            }
            // A placeholder build leaves the one-shot for the real screen.
            guard inheritsKeyboardHandoff else { return directKeyboardIntent.wantsKeyboard }
            // An iPad tools dock stands without a responder; the token is
            // still consumed so it cannot raise a later surface.
            if usesDirectToolsKeyboard, TerminalKeyboardMode.controlsReleaseFirstResponder {
                _ = keyboardHandoff.consume(agent.id)
                return false
            }
            if keyboardHandoff.consume(agent.id) {
                directKeyboardIntent.setWantsKeyboard(true)
                return true
            }
            // Same-screen pipeline replacement: reclaim only while Direct
            // Input still owns raised intent. Cold persisted Direct stays down.
            return directKeyboardIntent.wantsKeyboard
        }
        screen.keyboardHandoffID = composerToDirectHandoffID
        screen.isKeyboardHandoffCurrent = { id in
            isOnStage()
                && keyboardInset.activeResponderHandoffID == id
                && keyboardHandoffToDirect.requestID == id
        }
        screen.onKeyboardHandoffResult = { id, succeeded in
            sendKeyboardHandoff(.destinationAnswered(id, accepted: succeeded))
        }
        screen.onKeyboardHandoffEnded = { id, outcome in
            switch outcome {
            case .settled, .timedOut:
                sendKeyboardHandoff(.destinationSettled(id))
            case .cancelled:
                sendKeyboardHandoff(.cancel(id))
            }
        }
        screen.theme = terminal.themes.theme
        screen.fontSize = terminal.zoom.fontSize
        screen.fontFamily = terminal.fonts.familyName
        screen.onFontSizeChanged = { fontSize in terminal.zoom.setFontSize(fontSize) }
        // A relative path resolves against the pane's directory: a shell's
        // follows its `cd`, an Agent's is where it runs.
        let workingDirectory = linkWorkingDirectory
        screen.onPreviewFile = { file in
            filePreview.preview(file, workingDirectory: workingDirectory)
        }
        screen.onConfirmLink = { target in confirmLink(target) }
        screen.onRefusedFileLink = { host in filePreview.refuse(.onAnotherMachine(host: host)) }
        return screen
    }

    var body: some View {
        GeometryReader { proxy in
            lifecycleSurface
                .frame(
                    width: proxy.size.width,
                    height: proxy.size.height,
                    alignment: .top)
        }
        // Keyboard avoidance is owned by `TerminalKeyboardInset`. The fixed
        // geometry reader must ignore UIKit's keyboard safe area itself;
        // otherwise replacing the system keyboard changes the proposal that
        // reaches Ghostty even when our explicit inset is unchanged.
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // Keyed on the path, not the Agent: herdr hands a pane a new session
        // file when the Agent starts a fresh session, and the loop must follow
        // it instead of re-reading a file nothing writes to any more.
        .task(id: agent.sessionFilePath) { await followSessionUsage() }
        // Keyed on everything that decides whether and where to read: a
        // footer without Branch, or a backgrounded app, polls nothing.
        .task(id: footerBranchDirectory) {
            await gitBranch.follow(
                cwd: footerBranchDirectory, read: console.gitBranchReader(for: agent.hostID))
        }
        .modifier(ConsoleTerminalCommandRegistration(
            agentID: agent.id,
            isFocused: keyboardControl.isFirstResponder,
            isPresenting: isPresentingOverDetail,
            isOnStage: { @MainActor in paneActionsAvailable && isCommandOnStage() },
            toggleInputMode: { tapMessageAgent() },
            sendReturn: { sendAgentQuickKey(.enter) },
            resuppressKeyboardFocus: {
                keyboardControl.resuppressSceneKeyboardFocus()
            }))
        .task { composer.open() }
        #if DEBUG && targetEnvironment(simulator)
        // `--demo-dictation`: the Checkout Agent opens listening, for the
        // `dictation` screenshot and the waycar.dev hero. Polls until its 🎤
        // is on stage, however slow the cold launch, then starts Dictate to
        // Agent. `DemoScreenshotMode.didStartDictation` holds that to once
        // per launch, so a re-created terminal never starts it again.
        .task {
            guard DemoScreenshotMode.isDictationEnabled,
                agent.id == DemoScreenshotFixture.checkoutAgentID
            else { return }
            while !Task.isCancelled {
                guard (try? await Task.sleep(for: .milliseconds(500))) != nil,
                    !DemoScreenshotMode.didStartDictation
                else { return }
                guard isOnStage(), AgentDirectInputPresentation.showsDictateToAgent(
                    dictation: dictationSender.dictation, composer: composer)
                else { continue }
                if dictationSender.dictation.phase == .idle {
                    toggleDictation()
                    DemoScreenshotMode.didStartDictation = true
                }
                return
            }
        }
        #endif
    }

    private var presentedSurface: some View {
        terminalSurface
        .photosPicker(
            isPresented: $isSelectingPhoto,
            selection: $selectedPhotos,
            maxSelectionCount: max(1, composer.tray.remainingCapacity),
            selectionBehavior: .ordered,
            matching: .images,
            preferredItemEncoding: .current)
        .fileImporter(
            isPresented: $isSelectingFile,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            composer.tray.add(urls.map { .file($0) })
        }
        .sheet(isPresented: $isStartingAgent) {
            // StartAgentView brings its own NavigationStack.
            StartAgentView(
                hosts: hosts,
                console: console,
                origin: StartAgentStore.LaunchOrigin(
                    hostID: agent.hostID,
                    workspaceID: agent.agent.workspaceID,
                    cwd: agent.agent.cwd),
                onStarted: { switchToAgent($0) })
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(
                    horizontalSizeClass: horizontalSizeClass)))
            // The Console can't close this sheet to present Ask an Agent's,
            // so its Help offers no Ask an Agent.
            .environment(\.askAgent, nil)
        }
        // Presenting this takes the keyboard down and dismissing brings it
        // back; see `allowsKeyboardActivation` in WaycarTerminalView.
        .sheet(isPresented: $isManagingSnippets) {
            SnippetsManagementView(store: terminal.snippets)
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(
                    horizontalSizeClass: horizontalSizeClass)))
        }
        // Same keyboard choreography as the Snippets sheet above. The picker
        // shares the tools keyboard's SkillsPaneStore, so both surfaces load
        // and fail together.
        .sheet(isPresented: $isShowingSkillsPicker) {
            if let skills {
                SkillsPickerView(
                    store: skills,
                    onInsert: { composer.insertIntoDraft($0.insertionText) },
                    readSkill: { [console, agent] skill in
                        try await console.readSkillFile(path: skill.path, on: agent.hostID)
                    })
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: ConsoleSheetPresentation(
                        horizontalSizeClass: horizontalSizeClass)))
            }
        }
        // Same keyboard choreography as the Snippets sheet above.
        .sheet(item: $viewingSkill) { skill in
            SkillContentSheet(skill: skill) { [console, agent] in
                try await console.readSkillFile(path: skill.path, on: agent.hostID)
            }
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(
                    horizontalSizeClass: horizontalSizeClass)))
        }
        .sheet(isPresented: $isRenamingAgent) {
            RenameSheetView(
                title: agent.isShell ? "Rename Shell" : "Rename Agent",
                store: renameStore)
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(
                    horizontalSizeClass: horizontalSizeClass)))
        }
        .sheet(isPresented: $isRenamingWorkspace) {
            RenameSheetView(
                title: "Rename Workspace",
                store: RenameStore.workspace(
                    currentLabel: agent.workspaceLabel ?? ""
                ) { [console, agent] label in
                    try await console.renameWorkspace(
                        agent.agent.workspaceID, label: label, on: agent.hostID)
                })
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(
                    horizontalSizeClass: horizontalSizeClass)))
        }
        .sheet(isPresented: $isShowingWorktree) {
            if let worktreeStore {
                WorktreeDetailView(store: worktreeStore) { _ in
                    isShowingWorktree = false
                }
                .modifier(ConsoleSheetPresentationModifier(
                    presentation: ConsoleSheetPresentation(
                        horizontalSizeClass: horizontalSizeClass)))
            }
        }
        .sheet(
            isPresented: Binding(
                get: { attach.pendingPaste != nil },
                set: { if !$0 { attach.cancelPaste() } })
        ) {
            pasteReviewSheet
        }
        .sheet(isPresented: $isShowingFilesAndLinks, onDismiss: { openPendingListLink() }) {
            TerminalFilesAndLinksSheet(
                files: mediaStrip.files, links: attach.attachLinks, preview: filePreview,
                workingDirectory: linkWorkingDirectory,
                openFile: { file in
                    // Read like a tapped terminal path, against the folder
                    // its thumbnail came from.
                    listStartedPreview = true
                    filePreview.preview(TerminalFileReference(path: file.path), workingDirectory: linkWorkingDirectory)
                },
                openLink: { link in
                    pendingListLink = link
                    isShowingFilesAndLinks = false
                },
                copyLink: { link in UIPasteboard.general.string = link.target })
            // A file picked here previews over the list, so closing the
            // preview lands back on it, scrolled and sized as it was. Active
            // only while the list is showing, so exactly one copy is active
            // at any moment, even while the list animates away.
            .modifier(filePreviewPresenters(isActive: isShowingFilesAndLinks))
            .modifier(ConsoleSheetPresentationModifier(
                presentation: ConsoleSheetPresentation(
                    horizontalSizeClass: horizontalSizeClass)))
        }
        // The list closing stops a preview still loading from it, as soon as
        // it starts to go: a late result would otherwise present here while
        // the list animates away, and a presentation requested then is
        // dropped. A preview already on screen is not loading, so stays.
        .onChange(of: isShowingFilesAndLinks) { _, isShowing in
            guard !isShowing else { return }
            if listStartedPreview { filePreview.cancel() }
            listStartedPreview = false
        }
        // A path tapped in the terminal previews from here; while the list
        // is up, the list presents instead. Exactly one copy is active.
        .modifier(filePreviewPresenters(isActive: !isShowingFilesAndLinks))
        .onChange(of: filePreview.markdownPreview?.id) { _, opened in
            if opened != nil { markdownShowsRaw = RecentSelectionsStore().markdownPreviewShowsRaw }
        }
    }

    /// The file preview's presenters over `filePreview`, with the
    /// device-wide raw choice and this terminal's size class.
    private func filePreviewPresenters(isActive: Bool) -> TerminalFilePreviewPresenters {
        TerminalFilePreviewPresenters(
            store: filePreview,
            isActive: isActive,
            horizontalSizeClass: horizontalSizeClass,
            markdownShowsRaw: Binding(
                get: { markdownShowsRaw },
                set: {
                    markdownShowsRaw = $0
                    RecentSelectionsStore().rememberMarkdownPreviewShowsRaw($0)
                }))
    }

    /// Opens the link a list row picked, once the list has gone.
    private func openPendingListLink() {
        guard let link = pendingListLink else { return }
        pendingListLink = nil
        openAttachLink(link)
    }

    private var alertSurface: some View {
        presentedSurface
        // Close Agent runs at once when Closed Sessions can resume the
        // conversation, so a mistaken close is undone from there (#185).
        // Anything it can't bring back (a Shell, an unknown kind, an Agent
        // with no resumable session) still asks first. An alert, not a
        // confirmationDialog: iOS 26 draws the dialog as a popover anchored
        // to the view it is attached to, here the whole terminal (the menu
        // item that asked is gone once tapped), so its arrow pointed at
        // nothing the user touched. The quiet tint keeps Cancel gray.
        .quietCancelAlert(
            "Close \(Self.displayTitle(for: agent))?", isPresented: $isConfirmingClose
        ) {
            Button(agent.isShell ? "Close Shell" : "Close Agent", role: .destructive) {
                Task { await performClose() }
            }
            Button("Cancel", role: .cancel) {}
                .tint(Brand.Colors.quietAction)
        } message: {
            Text(
                agent.isShell
                    ? "This closes the shell on the Host. Shells aren't kept in Closed "
                        + "Sessions, so this can't be undone."
                    : "This closes the pane on the Host. Closed Sessions can't resume "
                        + "this agent's conversation, so this can't be undone.")
        }
        .quietCancelAlert(
            agent.backend.archivesOnClose ? "Couldn't Archive" : "Couldn't Close Agent",
            isPresented: Binding(
                get: { closeErrorMessage != nil },
                set: { if !$0 { closeErrorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
                .tint(Brand.Colors.quietAction)
        } message: {
            Text(closeErrorMessage ?? "")
        }
        .quietCancelAlert(
            "Paste Blocked",
            isPresented: Binding(
                get: { attach.pasteErrorMessage != nil },
                set: { if !$0 { attach.clearPasteError() } })
        ) {
            Button("OK", role: .cancel) {
                attach.clearPasteError()
            }
            .tint(Brand.Colors.quietAction)
        } message: {
            Text(attach.pasteErrorMessage ?? "")
        }
        .linkConfirmationAlert($pendingLink) { openConfirmedLink($0) }
        .alert(
            "Couldn't Open Link",
            isPresented: Binding(
                get: { attach.attachLinkOpenFailure != nil },
                set: { if !$0 { attach.dismissAttachLinkOpenFailure() } })
        ) {
            Button("Copy Link") {
                attach.copyFailedAttachLink {
                    UIPasteboard.general.string = $0
                }
            }
            Button("Cancel", role: .cancel) {
                attach.dismissAttachLinkOpenFailure()
            }
            .tint(Brand.Colors.quietAction)
        } message: {
            Text(
                attach.attachLinkOpenFailure?.message
                    ?? "This link couldn't be opened.")
        }
    }

    private var lifecycleSurface: some View {
        alertSurface
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            let picked = items
            selectedPhotos = []
            composer.tray.add(picked.map { .photo(PhotosPickerImageSelection(item: $0)) })
        }
        // Follows the grace period, not the raw scene phase: a staging operation
        // is exactly the work worth finishing while the app is briefly out of
        // sight, and it is cancelled only once the app really suspends.
        .onChange(of: activity.phase) { _, phase in
            guard phase == .suspended else { return }
            attach.staging.didEnterBackground()
        }
        // A cold launch restores from the frame kept on the way out.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { recordLastFrame() }
        }
        // Heard whether or not Message Agent's card shows the failed chip.
        .onChange(of: failedTrayItemCount) { previous, current in
            guard current > previous else { return }
            AccessibilityNotification.Announcement("Upload failed").post()
        }
        // Not the phase: a background→foreground round trip the grace period
        // absorbs never leaves `.active`, so the return that has to prove the
        // attach channel is exactly the one an `onChange` on the phase cannot
        // see (#141).
        // `initial` lets a replacement screen claim an activation that landed
        // after its predecessor disappeared but before this observer existed.
        .onChange(of: activity.activationCount, initial: true) { _, _ in
            handleActivation()
        }
        .onChange(of: console.connectionGeneration(for: agent)) { _, generation in
            armDirectKeyboardClaimIfNeeded()
            attach.transportGenerationDidChange(generation)
        }
        // Paired with the leave below: SwiftUI hands out onDisappear for
        // removals the user never made, and the state that comes back is the
        // one that left. Rejoining is what makes that survivable — and both
        // calls must stay synchronous, because the spurious pair can land in
        // one transaction and rejoin() can only undo a leave it can see.
        .onAppear {
            // The build before retention swaps `attach` in is a placeholder;
            // the dissolve waits for the one with the surface.
            if inheritsKeyboardHandoff { detailCrossfade?.contentDidAppear() }
            interactionProbe?.value?.connect(
                tapMessageAgent: { tapMessageAgent() },
                tapTerminalKeyboard: { tapTerminalKeyboard() },
                tapDictateToAgent: { toggleDictation() },
                performToolbarItem: { content in toolbarDispatcher().perform(content) },
                inputMode: { [inputMode] in inputMode.mode },
                terminalKeyboardUp: { terminalKeyboardIsUp })
            interactionProbe?.value?.connectMessageJump(
                jumpOlder: { jumpToOlderMessage() },
                jumpNewer: { jumpToNewerMessageOrLive() },
                lastViewportFrame: { messageJump.lastViewportFrame })
            composer.bindAttachInput(attach.input)
            // The tray follows the Attach this screen shows. Attach stores
            // never bind themselves: SwiftUI builds throwaway ones, and a
            // retained one may come back on a rebuilt screen. Only an
            // on-stage screen binds, so a spurious appear on a departing
            // or placeholder screen cannot re-point the tray at an Attach
            // that already left. Stage can settle a turn after the appear
            // (the same lag the disappear below waits out), so check again
            // then.
            if isOnStage() {
                composer.bindStaging(attach.staging)
            } else {
                let staging = attach.staging
                Task { @MainActor in
                    await Task.yield()
                    guard isOnStage() else { return }
                    composer.bindStaging(staging)
                }
            }
            // Arm before rejoin so a full pipeline replacement can claim the
            // keyboard while Direct Input still owns raised intent.
            if isOnStage() {
                prepareComposerKeyboardPresentation(
                    isDirectInput
                        ? (usesDirectToolsKeyboard ? .tools : .hidden)
                        : composerKeyboardPresentation)
                armDirectKeyboardClaimIfNeeded()
            }
            let frame = lastFrame
            let frames = lastFrames
            attach.terminalWillBeReplaced = { [weak frame, weak frames, agent, hosts] outgoing in
                frames?.record(
                    frame?.paintedTerminal(of: outgoing.surfaceID), for: agent, hosts: hosts)
                frame?.surfaceWillRetire(outgoing.surfaceID)
            }
            // Entering with no frame of its own: the Agent's cached one
            // stands in until the terminal paints.
            lastFrames?.offer(to: lastFrame, for: agent.id, hosts: hosts)
            attach.rejoin()
            messageJump.refreshTranscript()
            messageJump.scrollControl.paneHistory?.refresh()
        }
        .onDisappear {
            // Before the departure below can take the surface down.
            recordLastFrame()
            // Only a real departure closes the preview. A spurious disappear
            // on a screen that stays would otherwise cancel a read in flight,
            // or pull Quick Look and its local copy out from under the user.
            // The screen's presentations, not its Attach, decide: a detail
            // whose Host channel is held elsewhere still shows its sheets.
            Task { @MainActor in
                await Task.yield()
                guard !isCommandOnStage() else { return }
                filePreview.close()
            }
            interactionProbe?.value?.disconnect()
            messageJump.resetSession()
            if let onRetainDeparture {
                let keepingKeyboard = keyboardHandoff.isArmed
                if !isOnStage() {
                    onRetainDeparture(keepingKeyboard)
                } else {
                    Task { @MainActor in
                        await Task.yield()
                        guard !isOnStage() else { return }
                        onRetainDeparture(keepingKeyboard)
                    }
                }
            } else {
                attach.leave()
            }
            Task { @MainActor in
                await Task.yield()
                guard !isOnStage() else { return }
                directKeyboardIntent.setWantsKeyboard(false)
                keyboardControl.dismissKeyboard()
                usesDirectToolsKeyboard = false
                expectsDirectSystemKeyboard = false
                keyboardHandoff.cancel(for: agent.id)
                cancelKeyboardHandoffs()
            }
        }
        .onChange(of: agent.agent.status) { _, status in
            // A new turn may have pushed the conversation past the screen;
            // re-offer Up if an earlier walk had found nothing above.
            if status == .working {
                messageJump.noteConversationGrew()
            }
            // A turn began or ended: the transcript has a user turn to add.
            messageJump.refreshTranscript()
            // The Agent exited to its shell, or another application took
            // the pane: its history may have come or gone.
            messageJump.scrollControl.paneHistory?.refresh()
        }
        // The Agent moved to another session (`/sessions`, `/clear`), which
        // need not move its status: the transcript read so far is another
        // conversation's.
        .onChange(of: agent.agent.agentSession) { _, _ in
            messageJump.refreshTranscript()
        }
        // A live attach has painted its own frame, including one already
        // live when this screen mounts (a retained Agent shown again) (#21).
        .onChange(of: attach.terminalStatus, initial: true) { _, _ in
            registerPaintedSurface()
        }
        // The surface can mount after the status observer first runs.
        .onChange(of: keyboardControl.terminal.map(ObjectIdentifier.init)) { _, _ in
            registerPaintedSurface()
        }
        .onChange(of: discardsLastFrame, initial: true) { _, discards in
            if discards { lastFrame.discard() }
        }
        .onChange(of: endsLastFrame, initial: true) { _, ends in
            if ends { lastFrames?.discard(agent.id) }
        }
        .onChange(of: showsReconnectingIndicator, initial: true) { _, shows in
            if shows { AccessibilityNotification.Announcement("Reconnecting").post() }
        }
        .onChange(of: attach.terminalID) { _, _ in
            messageJump.resetSession()
            messageJump.refreshTranscript()
            cancelKeyboardHandoffs()
            guard isDirectInput else { return }
            expectsDirectSystemKeyboard = false
            keyboardControl.setKeyboardMode(usesDirectToolsKeyboard ? .controls : .text)
            prepareComposerKeyboardPresentation(usesDirectToolsKeyboard ? .tools : .hidden)
            // Do not re-arm TerminalKeyboardHandoff here: claimsKeyboard already
            // consumed any pre-armed token or reclaimed via same-screen intent.
            // Arming again leaves a stale one-shot that can raise a dismissed
            // keyboard on a later replacement.
        }
        #if DEBUG
        // A fresh terminal ID means a new Attach pipeline, including a
        // foreground recovery. Mark its visible detail edge separately from
        // outer SwiftUI appearance, which does not run for that replacement.
        .onChange(of: attach.terminalID, initial: true) { _, _ in
            attach.terminalDidBecomeVisible()
        }
        #endif
        .onChange(of: keyboardControl.isFirstResponder) { _, isUp in
            guard isDirectInput else { return }
            if isUp {
                // A tap on the terminal surface raises the keyboard directly
                // (see `WaycarTerminalView.tapAction`), bypassing every arm
                // site above. Record the raised intent so a same-screen
                // pipeline replacement reclaims first responder when its
                // attach goes live instead of coming up cold. A hardware
                // keyboard's claim takes first responder with the software
                // keyboard down: that is not a wish for the keyboard, so it
                // records nothing.
                if keyboardInset.height > 0 || usesDirectToolsKeyboard {
                    directKeyboardIntent.setWantsKeyboard(true)
                }
                // On iPad the tools dock stands without a responder, so a tap
                // on the terminal asks for the system keyboard.
                guard usesDirectToolsKeyboard, toolsDockReleasesFocus else { return }
                showDirectSystemKeyboard()
                return
            }
            // Tools→iOS keeps first responder across the coalesce window; a
            // real dismiss resigns and must drop the pre-show `.system` hold.
            expectsDirectSystemKeyboard = false
        }
        .onChange(of: detailFocusTaps) {
            // The tap that slid the portrait list off this Agent means what
            // a tap on the terminal means: type into it. Message Agent keeps
            // the keyboard its own, as it does for a terminal tap.
            guard isOnStage(), isDirectInput, !keyboardControl.isFirstResponder else { return }
            directKeyboardIntent.setWantsKeyboard(true)
            keyboardControl.requestKeyboard()
        }
        .onChange(of: isDetailCovered) { _, blocked in
            // Covered by the portrait list, the Agent takes no keys, so the
            // terminal drops its keyboard, and the wish for it, until it is
            // asked for again. AgentDetailView's responder-chain resign
            // alone left it up: on iOS 27 that action was handled while the
            // terminal, first responder of the key window, never
            // received it. When it does arrive first, the intent must still
            // go, or a pipeline replacement would claim the keyboard back.
            guard blocked else {
                // Uncovered with a hardware keyboard attached, plain keys
                // and arrows must reach the terminal again; the cover's
                // dismissal cleared the claim the surface held. The tools
                // dock stands without a responder by design, so it keeps it.
                guard !usesDirectToolsKeyboard else { return }
                keyboardControl.terminal?.rearmHardwareKeyboardFocus()
                return
            }
            expectsDirectSystemKeyboard = false
            directKeyboardIntent.setWantsKeyboard(false)
            keyboardControl.dismissKeyboard()
        }
        .onChange(of: keyboardInset.height) { _, height in
            // Release the Tools→iOS pre-show hold only after the software
            // keyboard has actually appeared. Clearing while height is still
            // zero would dip through `.hidden`; clearing once height is
            // positive keeps `.system` via the live measurement. A later
            // hardware-keyboard hide can then drop to zero inset cleanly.
            guard isDirectInput, expectsDirectSystemKeyboard, height > 0 else { return }
            expectsDirectSystemKeyboard = false
        }
    }

    private var terminalKeysContext: TerminalKeysContext {
        TerminalKeysContext(
            settings: terminal,
            skills: skills.map { store in
                TerminalSkillsContext(store: store) { skill in
                    viewingSkill = skill
                }
            }
        ) {
            isManagingSnippets = true
        }
    }

    /// Read inside the view body so it follows `ConsoleStore`'s observation:
    /// a fresh measurement — at connect, at the foreground re-proof, or at
    /// the open Hosts sheet's `sampleLatency()` every 2 s — re-renders this
    /// row and nothing else. A keepalive ping does not: it
    /// only proves liveness (see `KeepalivePolicy.interval`), so this row
    /// holds its last-proven number through an idle stretch rather than
    /// refreshing on every tick. No request of its own — the Host's
    /// connection measured this already.
    private var hostTelemetry: HostTelemetryPresentation? {
        HostTelemetryPresentation(
            status: console.hostStatuses[agent.hostID],
            latency: console.hostLatencies[agent.hostID])
    }

    private var directInputPresentation: AgentDirectInputPresentation {
        AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: usesDirectToolsKeyboard,
            expectsSystemKeyboard: expectsDirectSystemKeyboard,
            currentHeight: keyboardInset.height,
            lastPresentedHeight: keyboardInset.lastPresentedHeight)
    }

    private var activeKeyboardPresentation: AgentComposerKeyboardPresentation {
        if isDirectInput {
            return directInputPresentation.keyboardPresentation
        }
        return composerKeyboardPresentation
    }

    private var composerKeyboardLayout: AgentComposerKeyboardLayout {
        if isDirectInput {
            // Single seam: never rebuild layout beside the resolved presentation.
            return directInputPresentation.layout
        }
        return AgentComposerKeyboardLayout(
            currentHeight: keyboardInset.height,
            lastPresentedHeight: keyboardInset.lastPresentedHeight,
            presentation: composerKeyboardPresentation,
            softwareKeyboardDismissed: keyboardInset.isSoftwareKeyboardDismissed)
    }

    /// Rename names what the row shows. An Agent's name is `agent.rename`'s;
    /// a shell has no Agent to rename (`agent.rename` refuses it), so its
    /// name is its tab label, renamed through `tab.rename`.
    private var renameStore: RenameStore {
        if agent.isShell {
            return RenameStore.tab(
                currentLabel: agent.agent.name ?? ""
            ) { [console, agent] label in
                try await console.renameTab(of: agent, label: label)
            }
        }
        return RenameStore(
            subject: .agent(detectedKind: agent.agent.kind),
            currentValue: agent.agent.name ?? ""
        ) { [console, agent] name in
            try await console.renameAgent(agent.agent.paneID, name: name, on: agent.hostID)
        }
    }

    /// Rises when an upload fails, which VoiceOver announces.
    private var failedTrayItemCount: Int {
        composer.tray.items.filter(\.status.isFailed).count
    }

    private var composerActions: AgentComposerActions {
        AgentComposerActions(
            canAdd: composer.tray.canAdd,
            addImage: { isSelectingPhoto = true },
            addFile: { isSelectingFile = true },
            openTerminal: canOpenTerminal
                ? {
                    armShellTerminalKeyboardHandoffIfKeyboardIsUp()
                    openTerminal()
                } : nil,
            isOpeningTerminal: isOpeningTerminal,
            startAgent: {
                if let sampleConnect { sampleConnect() }
                else { isStartingAgent = true }
            },
            manageSnippets: { isManagingSnippets = true },
            showSkills: skills != nil ? { isShowingSkillsPicker = true } : nil,
            showWorktreeDetails: agent.isLinkedWorktree
                ? {
                    if let checkout = agent.repositoryCheckout {
                        worktreeStore = makeWorktreeStore(checkout: checkout)
                        isShowingWorktree = true
                    }
                } : nil,
            renameAgent: { isRenamingAgent = true },
            renameWorkspace: { isRenamingWorkspace = true },
            markUnread: console.unread.canMarkUnread(agent)
                ? { performMarkUnread() } : nil,
            closeAgent: {
                if agent.backend.archivesOnClose || ClosedSession.resumesConversation(of: agent) {
                    Task { await performClose() }
                } else {
                    isConfirmingClose = true
                }
            },
            archivesAgent: agent.backend.archivesOnClose,
            canRenameWorkspace: agent.backend != .zellij,
            paneActionsAvailable: paneActionsAvailable)
    }

    private func makeWorktreeStore(checkout: RepositoryCheckout) -> WorktreeDetailStore {
        let hostID = agent.hostID
        let workspaceID = agent.agent.workspaceID
        let request = WorktreeRemovalRequest(
            identity: WorktreeIdentity(
                hostID: hostID, workspaceID: workspaceID, checkout: checkout))
        return WorktreeDetailStore(
            request: request,
            workspaceLabel: agent.workspaceLabel ?? checkout.repoName,
            checkout: checkout,
            list: { [console] workspaceID in
                try await console.listWorktrees(
                    forWorkspaceID: workspaceID, on: hostID)
            },
            remove: { [console] request in
                try await console.removeWorktree(request, on: hostID)
            },
            hasWorkingAgent: { [console] in
                console.agents.contains {
                    $0.hostID == hostID
                        && $0.agent.workspaceID == workspaceID
                        && $0.agent.status == .working
                }
            })
    }

    private var terminalSurface: some View {
        terminalScreen
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                readerGeometry.terminalRegion = $0
            }
            .id(attach.terminalID)
            // A reconnecting terminal is not live content, whether it is
            // the outgoing surface or its blank replacement.
            .accessibilityHidden(showsLastFrame || showsOfflineReader)
            .overlay { ignitionOverlay }
        // Above alternateScreenBottomRegion; only the buttons take hits —
        // see MessageJumpChromeContainer.
        .overlay {
            if paneActionsAvailable { messageJumpChrome }
        }
        // Docked on the trailing edge near the bottom, under the message tab's
        // lowest dock; only the tab itself takes hits.
        .overlay {
            if paneActionsAvailable { scrollJumpChrome }
        }
        .overlay { statusOverlay }
        .modifier(
            OfflineReadingPresentation(
                saved: savedTranscript,
                connection: terminalConnectionIndicator,
                hasNetwork: console.hasNetwork,
                offersReader: offersOfflineReader,
                isReading: $isReadingOfflineCopy,
                agentName: Self.displayTitle(for: agent),
                composer: composer,
                palette: themePalette,
                loadMedia: terminalMediaLoader,
                open: openOfflineReader,
                geometry: readerGeometry,
                keyboardIsUp: keyboardInset.height > 0))
        .task(id: savedTranscriptLoadID) {
            savedTranscript = console.savedTranscript(for: agent)
        }
        .task(
            id: OfflineReading.isSlowConnectCandidate(
                terminalConnectionIndicator, hasNetwork: console.hasNetwork)
        ) {
            reconnectingFor = .zero
            guard
                OfflineReading.isSlowConnectCandidate(
                    terminalConnectionIndicator, hasNetwork: console.hasNetwork)
            else { return }
            do { try await Task.sleep(for: OfflineReading.slowConnectDelay) } catch { return }
            reconnectingFor = OfflineReading.slowConnectDelay
        }
        // While the list is up it shows its own, over its rows; this one
        // would show twice beside it at the list's half height.
        .overlay(alignment: .top) {
            if !isShowingFilesAndLinks, case .loading(let name) = filePreview.phase {
                TerminalFilePreviewLoadingBadge(name: name) { filePreview.cancel() }
                    .padding(.top, 8)
            }
        }
        // Keep the edge gesture below the input chrome and tools dock so
        // its transparent hit region cannot intercept their leading keys.
        .overlay(alignment: .leading) {
            // Steps aside only where a selection handle takes touches: a
            // start handle at the left edge sits under this strip, and
            // dragging it right would read as a back swipe, or on iPad as
            // opening the list. Everywhere else along the edge the swipe
            // still works while text is selected. A plain tap on it goes on
            // to the terminal, so a path drawn in the first columns still
            // opens — unless a dimmed status dialog covers the terminal.
            AgentEdgeBackGesture(
                keyboardControl: keyboardControl,
                onTap: forwardEdgeTap(at:)
            ) { dismiss() }
        }
        // Below the keyboard's own inset, so the Toolbar rides above the
        // keyboard while it is up and rests on the screen's edge once it is
        // down. The same bar in every state; the Agent view has nothing
        // below it.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inputChrome
        }
        // Not SwiftUI's keyboard avoidance: it retracts in two stages and the
        // terminal would resize twice per dismissal. See TerminalKeyboardInset.
        .modifier(
            AgentTerminalKeyboardInsetModifier(
                height: composerKeyboardLayout.contentInset))
        // This dock is always present at the system keyboard's last complete
        // height. In iOS mode it is transparent behind the system keyboard;
        // in Tools mode it is already in place when UIKit removes its native
        // candidate row, so no intermediate gap is ever exposed.
        // Anchored to the frame's bottom edge, the edge the inset above is
        // padded from, not the bottom safe area: on iPad the Agent is laid
        // out through the home indicator, and a safe-area-aligned dock rode
        // up under the Toolbar by that inset.
        .overlay(alignment: .bottom) {
            if paneActionsAvailable {
                AgentToolsKeyboard(
                    insertText: insertToolsText,
                    context: terminalKeysContext,
                    keyboardControl: keyboardControl,
                    inputMode: inputMode.mode,
                    height: composerKeyboardLayout.availableToolsHeight,
                    quickKeysEnabled: true,
                    sendQuickKey: sendAgentQuickKey)
                .opacity(activeKeyboardPresentation == .tools ? 1 : 0)
                .disabled(activeKeyboardPresentation != .tools)
                .allowsHitTesting(activeKeyboardPresentation == .tools)
                .accessibilityHidden(activeKeyboardPresentation != .tools)
                .ignoresSafeArea(.container, edges: .bottom)
            }
        }
        // The Agent Footer, in the band under the Toolbar capsule. An overlay,
        // never part of the bottom inset: the terminal and its PTY keep their
        // size whatever the footer shows. Anchored to the frame's bottom edge
        // like the dock above, so the band also reaches through the home
        // indicator on iPad. Hidden, not removed, under any keyboard, so
        // nothing reflows as one rises.
        .overlay(alignment: .bottom) {
            // A progress estimate goes stale on a clock, not on a change, so
            // the footer redraws as often as the card's progress rail.
            TimelineView(.periodic(from: .now, by: 15)) { timeline in
                AgentFooterBand(
                    layout: terminal.footer.layout,
                    context: footerContext(at: timeline.date),
                    maximumLines: footerMaximumLines,
                    height: AgentFooterBand.height(bottomSafeAreaInset: bottomSafeAreaInset))
            }
            .opacity(footerIsCovered ? 0 : 1)
            .accessibilityHidden(footerIsCovered)
            .allowsHitTesting(false)
            .environment(\.colorScheme, terminal.themes.selection(for: colorScheme)
                .chromeColorScheme(for: colorScheme))
            .ignoresSafeArea(.container, edges: .bottom)
        }
        // Above the status-bar padding, so the strip lands just below the
        // clock and the terminal keeps the offset it already had (#325).
        // With a control floating at the top-leading corner the strip is
        // that control's row, so the terminal starts below it.
        .safeAreaInset(edge: .top, spacing: 0) {
            let moved = movedUsage
            ZStack(alignment: .leading) {
                AgentUsageStrip(
                    model: moved.contains(.model) ? nil : sessionUsage.usage.model,
                    contextText: moved.contains(.context) ? nil : sessionUsage.contextText,
                    costText: moved.contains(.cost) ? nil : sessionUsage.usage.costText,
                    rateText: moved.contains(.rate) || !sessionUsage.showsTokenRate
                        ? nil : sessionUsage.usage.rateText,
                    isReserved: agent.sessionFilePath != nil
                        && !AgentFooterBand.takesAllUsage(
                            layout: terminal.footer.layout,
                            maximumLines: footerMaximumLines),
                    palette: themePalette,
                    controlSlot: topControlSlot)
                if showsBackButton && !isCompactHeight {
                    backButton
                        .padding(.leading, Self.backButtonInset)
                }
            }
        }
        // Landscape iPhone: no 60 pt control row over a short terminal. Back
        // floats in a leading column instead — the safe-area gutter where
        // the phone has one, topped up so the column is always wide enough
        // for the button — so it never covers a terminal column either.
        .safeAreaInset(edge: .leading, spacing: 0) {
            if showsBackButton && isCompactHeight {
                Color.clear
                    .frame(width: compactBackColumnTopUp)
                    .overlay(alignment: .topTrailing) {
                        backButton
                            .padding(.top, Self.backButtonInset)
                            .padding(.trailing, Self.backButtonInset)
                    }
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.safeAreaInsets.leading
        } action: { inset in
            leadingSafeAreaInset = inset
        }
        // Keyboard safe area is ignored above, so this is the home indicator
        // alone, never a keyboard's height.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.safeAreaInsets.bottom
        } action: { inset in
            measuredBottomSafeAreaInset = inset
        }
        // The navigation bar remains present only as the owner of the status
        // bar appearance. Its content stays hidden, while this inset keeps
        // terminal output below the system clock.
        .padding(.top, statusBarInset)
        .background {
            // Keyboard geometry and the status bar inset follow this view's
            // own window, not whichever window of the app is key.
            WindowReader { window in
                keyboardInset.attach(to: window)
                mountedWindow.attach(window)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .background(
            terminal.themes.selection(for: colorScheme)
                .surfaceBackground(for: colorScheme))
        .ignoresSafeArea(.container, edges: .top)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.frame(in: .global).minY
        } action: { top in
            topInWindow = top
        }
        .toolbarColorScheme(
            terminal.themes.selection(for: colorScheme)
                .chromeColorScheme(for: colorScheme),
            for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        // The system back button is hidden, so VoiceOver's two-finger scrub
        // has nothing to press; this keeps a way back when Settings › Hide
        // Back Button removes ours.
        .accessibilityAction(.escape) { dismiss() }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        // `toolbarColorScheme` takes effect only while the bar background is
        // visible. A clear visible background keeps the bar visually absent
        // and the terminal unobscured while still applying status-bar contrast.
        .toolbarBackground(Color.clear, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar(.visible, for: .navigationBar)
    }

    private func prepareComposerKeyboardPresentation(
        _ presentation: AgentComposerKeyboardPresentation
    ) {
        keyboardInset.prepare(for: presentation)
    }

    /// Status, Message Agent's card when open, and the Toolbar: one chrome
    /// in every state, so the bar never rebuilds as the inputs change.
    private var inputChrome: some View {
        let actions = composerActions
        let toolbarLayout = terminal.toolbars.resolvedLayout(
            availability: toolbarAvailability(actions: actions))
        let readSaved = savedReadingAction
        return AgentInputChrome(
            context: AgentInputChromeContext(
                presentation: .init(
                    status: agent.agent.status,
                    hostTelemetry: hostTelemetry,
                    chromeColorScheme: terminal.themes.selection(for: colorScheme)
                        .chromeColorScheme(for: colorScheme),
                    isMessageAgentOpen: !isDirectInput,
                    isTerminalKeyboardUp: terminalKeyboardIsUp,
                    isToolsKeyboardPresented: isDirectInput && usesDirectToolsKeyboard,
                    isCovered: isPresentingOverDetail,
                    toolbarLayout: toolbarLayout,
                    toolbarItemSpacing: CGFloat(terminal.toolbars.itemSpacing),
                    armedModifiers: keyboardControl.pendingModifiers,
                    messageAgentTrayBadge: MessageAgentTrayBadge(
                        items: composer.tray.items, isMessageAgentOpen: !isDirectInput),
                    progressAgent: agent,
                    connection: terminalConnectionIndicator,
                    paneActionsAvailable: paneActionsAvailable),
                interactions: .init(
                    actions: actions,
                    tapMessageAgent: tapMessageAgent,
                    tapTerminalKeyboard: tapTerminalKeyboard,
                    sendQuickKey: sendAgentQuickKey,
                    paste: pasteFromToolbar,
                    showComposerForDictation: showComposerForDictation,
                    openMessageAgentThen: openMessageAgentThen,
                    dictation: dictationSender,
                    toggleDictation: toggleDictation,
                    composer: composer,
                    itemPresentation: toolbarItemPresentation(),
                    performToolbarItem: { item in
                        toolbarDispatcher().perform(item.content)
                    },
                    reattach: { attach.retryTerminal() },
                    useSSHInstead: { attach.useSSHInstead() },
                    readSaved: readSaved)),
            mediaStrip: TerminalMediaStrip(model: mediaStrip, links: attach.attachLinks) { isShowingFilesAndLinks = true }
        ) {
            if !isDirectInput {
                composerCard(actions: actions)
            }
        }
        .terminalMediaFetching(attach.attachMediaCandidates, into: mediaStrip, using: terminalMediaLoader)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
            readerGeometry.chromeTop = $0
        }
        .onAppear {
            interactionProbe?.value?.inputChromeDidAppear(
                toolbarLayout: toolbarLayout,
                sendQuickKey: { key in sendAgentQuickKey(key) })
        }
        .onDisappear { interactionProbe?.value?.inputChromeDidDisappear() }
        .onChange(of: toolbarLayout) { _, layout in
            interactionProbe?.value?.updateToolbarLayout(layout)
        }
    }

    /// The strip's fetches resolve relative paths against the Console's
    /// current row (its cwd), like Chat Mode's media (`AgentDetailView`).
    private var terminalMediaLoader: ChatMediaLoader {
        let agent = agent
        let console = console
        return { [weak console] media in
            guard let console else { throw CancellationError() }
            let current = console.agents.first { $0.id == agent.id } ?? agent
            return try await console.chatMediaFile(for: media, agent: current)
        }
    }

    /// Message Agent: the Composer card; 💬 opens it focused, other opens keep the keyboard down.
    private func composerCard(actions: AgentComposerActions) -> some View {
        AgentComposerView(
            store: composer,
            agentID: agent.id,
            actions: actions,
            skills: skills,
            keyboardPresentation: $composerKeyboardPresentation,
            prepareKeyboardPresentation: prepareComposerKeyboardPresentation,
            focusRequested: $composerFocusRequested,
            isCovered: isPresentingOverDetail,
            queueMaxHeight: offlineReaderQueueCap,
            queueHeightDidChange: { readerGeometry.queuedAreaHeight = $0 })
    }

    /// Any sheet, alert, or picker presented over this detail.
    private var isPresentingOverDetail: Bool {
        isSelectingPhoto || isSelectingFile || isConfirmingClose
            || isStartingAgent || isManagingSnippets || isShowingSkillsPicker
            || isRenamingAgent || viewingSkill != nil || isRenamingWorkspace
            || isShowingWorktree || closeErrorMessage != nil
            || attach.pendingPaste != nil || attach.pasteErrorMessage != nil
            || attach.attachLinkOpenFailure != nil
            || filePreview.previewURL != nil || filePreview.markdownPreview != nil
            || filePreview.failureMessage != nil
            || isShowingFilesAndLinks || pendingLink != nil
    }

    /// Where a relative path the pane printed resolves: the folder the
    /// strip's thumbnails resolve against too (`mediaWorkingDirectory`), so a
    /// tapped path, a list row, and its thumbnail all name the same file.
    private var linkWorkingDirectory: String? {
        console.mediaWorkingDirectory(for: agent)
    }

    /// Asks before opening `target`, naming where it leads: a file's Host
    /// path as a Preview would read it, which for a `~` path takes the
    /// Host's home first.
    private func confirmLink(_ target: TerminalLinkTarget) {
        linkConfirmation?.cancel()
        let workingDirectory = linkWorkingDirectory
        linkConfirmation = Task {
            let destination = await filePreview.confirmationDetail(
                for: target, workingDirectory: workingDirectory)
            guard !Task.isCancelled else { return }
            pendingLink = PendingLinkConfirmation(target: target, destination: destination)
        }
    }

    private func openConfirmedLink(_ target: TerminalLinkTarget) {
        switch target {
        case .web(let url): openURL(url)
        case .file(let file): filePreview.preview(file, workingDirectory: nil)
        }
    }

    /// ⌨ is lit: the terminal holds first responder or its tools dock is up.
    /// Never while Message Agent is open, whose keyboard is the Composer's.
    private var terminalKeyboardIsUp: Bool {
        isDirectInput
            && (keyboardControl.isKeyboardUp || usesDirectToolsKeyboard || keyboardInset.height > 0)
    }

    /// Tools author into the active input surface without adding Enter or
    /// restoring the hidden Composer. Reuse Snippet validation and paste framing.
    private func insertToolsText(_ text: String) {
        if isDirectInput {
            insertIntoAttach(text)
        } else {
            composer.insertIntoDraft(text)
        }
    }

    /// Types `text` into Attach without Enter, framed as a paste when the
    /// remote asked for bracketed paste.
    private func insertIntoAttach(_ text: String) {
        guard let terminal = keyboardControl.terminal else { return }
        keyboardControl.noteReliableInputBegan()
        attach.insertSnippet(text, bracketedPaste: terminal.usesBracketedPaste)
    }

    // MARK: Toolbars

    /// What the Toolbar can run here.
    private func toolbarAvailability(actions: AgentComposerActions) -> AgentToolbarAvailability {
        AgentToolbarAvailability(
            actions: actions,
            snippets: terminal.snippets.snippets,
            customKeys: terminal.toolbars.customKeys)
    }

    /// Cap strings for the bars. A Snippet or Custom Key that no longer
    /// exists yields nil and is hidden.
    private func toolbarItemPresentation() -> (AgentToolbarItem) -> AgentToolbarItemPresentation? {
        let customKeys = terminal.toolbars.customKeys
        let snippets = terminal.snippets.snippets
        return { item in
            AgentToolbarItemPresentation(item.content, customKeys: customKeys, snippets: snippets)
        }
    }

    /// Built at tap time, so a tap sees the current catalog, actions and
    /// whether Message Agent is open.
    private func toolbarDispatcher() -> AgentToolbarItemDispatcher {
        AgentToolbarItemDispatcher(
            isMessageAgentOpen: !isDirectInput,
            actions: composerActions,
            snippets: terminal.snippets.snippets,
            customKeys: terminal.toolbars.customKeys,
            routes: .init(
                sendQuickKey: { key in sendAgentQuickKey(key) },
                sendChord: { key, modifiers in keyboardControl.sendChord(key, modifiers: modifiers) },
                toggleModifier: { modifiers in keyboardControl.toggleModifier(modifiers) },
                pasteIntoAttach: { text in keyboardControl.paste(text) },
                insertIntoAttach: { text in insertIntoAttach(text) },
                insertIntoDraft: { text in composer.insertIntoDraft(text) },
                submitText: { text in submitToolbarText(text) },
                openMessageAgentThen: openMessageAgentThen,
                toggleToolsKeyboard: { toggleToolsKeyboard() },
                readPasteboard: clipboard.string))
    }

    /// The Paste item's system control hands its text here: the draft while
    /// Message Agent is open, Attach's paste review otherwise.
    private func pasteFromToolbar(_ text: String) {
        if isDirectInput {
            keyboardControl.paste(text)
        } else {
            composer.insertIntoDraft(text)
        }
    }

    /// A Custom Key's text + Enter through Send's delivery owner, leaving
    /// the draft alone. With Message Agent closed, the outcome is surfaced as
    /// a Dictation send's is: a Blocked insert brings up the tools keyboard
    /// to submit or cancel it; a failure opens Message Agent, where Retry
    /// lives. Both do nothing once the screen has moved on.
    private func submitToolbarText(_ text: String) {
        Task {
            switch await composer.send(text) {
            case .failed, .queued:
                showComposerForDictation()
            case .deliveredViaAttach:
                showDirectToolsKeyboard()
            case .ignored, .deliveredViaPrompt, .deliveredViaPaneInput:
                break
            }
        }
    }

    /// Esc is a known key, not a raw `0x1B` that might start CSI/SS3.
    /// With no modifiers armed this stays on the attach fast path
    /// byte-for-byte; armed ⌃/⌥ (#270) routes through the control so the
    /// next key's bytes carry the xterm modifier and consume the one-shot.
    private func sendAgentQuickKey(_ key: AgentQuickKey) {
        if key == .escape, keyboardControl.pendingModifiers.isEmpty {
            keyboardControl.noteReliableInputBegan()
            attach.sendEscapeKey()
            return
        }
        keyboardControl.sendQuickKey(key)
    }

    /// Whether a responder handoff is still moving the keyboard; a second
    /// switch would strand it between the two inputs.
    private var isKeyboardHandoffInFlight: Bool {
        keyboardHandoffToDirect.isInFlight
    }

    /// 💬: opens Message Agent and focuses its text field (the terminal
    /// keyboard, if up, is dismissed), or closes it.
    private func tapMessageAgent() {
        guard paneActionsAvailable else { return }
        guard isOnStage(), !isKeyboardHandoffInFlight else { return }
        if isDirectInput {
            applyInputMode(.composer)
            composerFocusRequested = true
        } else {
            applyInputMode(.direct, raisesKeyboard: false)
        }
    }

    /// ⌨: raises or dismisses the terminal keyboard. With Message Agent open
    /// it closes Message Agent and raises the terminal keyboard instead.
    private func tapTerminalKeyboard() {
        guard isOnStage() else { return }
        // The keyboard belongs to the terminal under the reader.
        isReadingOfflineCopy = false
        if isDirectInput {
            toggleDirectKeyboard()
        } else {
            closeMessageAgentRaisingTerminalKeyboard()
        }
    }

    /// A system keyboard the Composer holds moves to the terminal without
    /// dropping (a responder handoff); otherwise the terminal asks for its
    /// own once Message Agent has closed.
    private func closeMessageAgentRaisingTerminalKeyboard() {
        guard !isDirectInput, !isKeyboardHandoffInFlight else { return }
        guard composerKeyboardPresentation == .system else {
            applyInputMode(.direct)
            return
        }
        directKeyboardIntent.setWantsKeyboard(true)
        keyboardControl.setKeyboardMode(.text)
        let id = keyboardInset.beginDestinationOwnedResponderHandoff(
            currentHeight: currentWindowKeyboardHeight
        ) { expiredID in
            sendKeyboardHandoff(.cancel(expiredID))
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            sendKeyboardHandoff(.begin(id))
        }
    }

    /// `.direct` closes Message Agent and, unless `raisesKeyboard` is false,
    /// asks for the terminal keyboard. `.composer` opens Message Agent with
    /// the keyboard down; 💬 then asks the text field for focus separately.
    private func applyInputMode(
        _ mode: AgentInputMode,
        preservingKeyboardHandoff: Bool = false,
        raisesKeyboard: Bool = true
    ) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            switch mode {
            case .direct:
                composerFocusRequested = false
                if !preservingKeyboardHandoff {
                    prepareComposerKeyboardPresentation(.hidden)
                    sendKeyboardHandoff(.requestCleared)
                }
                composerKeyboardPresentation = .hidden
                usesDirectToolsKeyboard = false
                expectsDirectSystemKeyboard = false
                keyboardControl.setKeyboardMode(.text)
                inputMode.select(.direct)
            case .composer:
                usesDirectToolsKeyboard = false
                expectsDirectSystemKeyboard = false
                directKeyboardIntent.setWantsKeyboard(false)
                keyboardControl.setKeyboardMode(.text)
                keyboardControl.dismissKeyboard()
                prepareComposerKeyboardPresentation(.hidden)
                composerKeyboardPresentation = .hidden
                inputMode.select(.composer)
            }
        }
        switch mode {
        case .direct:
            guard raisesKeyboard else {
                UIAccessibility.post(notification: .announcement, argument: "Message Agent closed.")
                return
            }
            UIAccessibility.post(
                notification: .announcement,
                argument: "Keyboard. Typing into the Agent.")
            if !keyboardControl.isFirstResponder {
                Task { @MainActor in
                    // The terminal accepts input only after SwiftUI re-renders
                    // it as Direct Input; a single yield can ask too early.
                    for _ in 0..<20 {
                        await Task.yield()
                        guard isOnStage(), isDirectInput, !keyboardControl.isFirstResponder
                        else { return }
                        if keyboardControl.terminal?.isLocalInputEnabled == true { break }
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                    guard isOnStage(), isDirectInput else { return }
                    directKeyboardIntent.setWantsKeyboard(true)
                    keyboardControl.requestKeyboard()
                }
            }
        case .composer:
            UIAccessibility.post(notification: .announcement, argument: "Message Agent.")
        }
    }

    /// Feeds the handoff machine and performs its effects in order.
    private func sendKeyboardHandoff(_ event: DirectKeyboardHandoffMachine.Event) {
        for effect in keyboardHandoffToDirect.handle(event) {
            switch effect {
            case .enterDirectInput:
                applyInputMode(.direct, preservingKeyboardHandoff: true)
            case .dropKeyboardIntent:
                directKeyboardIntent.setWantsKeyboard(false)
            case .endInsetHandoff(let id):
                keyboardInset.endResponderHandoff(
                    id, currentHeight: currentWindowKeyboardHeight)
            case .cancelInsetHandoff(let id):
                keyboardInset.cancelResponderHandoff(
                    id, currentHeight: currentWindowKeyboardHeight)
            }
        }
    }

    private func currentWindowKeyboardHeight() -> CGFloat? {
        guard let window = keyboardControl.terminal?.window else { return nil }
        return TerminalKeyboardInset.layoutGuideHeight(in: window)
    }

    private func cancelKeyboardHandoffs() {
        sendKeyboardHandoff(.cancelCurrent)
    }

    /// Draft-owned actions (Skills, Snippets, Add) run with Message Agent
    /// open, so it opens first with no focus request: the sheet or picker
    /// that follows must not see a keyboard rise under it.
    private func openMessageAgentThen(_ action: @escaping () -> Void) {
        guard paneActionsAvailable else { return }
        if isDirectInput {
            guard isOnStage(), !isKeyboardHandoffInFlight else { return }
            applyInputMode(.composer)
        }
        Task { @MainActor in
            await Task.yield()
            action()
        }
    }

    /// The Tools Keyboard item: the terminal's tools dock, swapped with the
    /// system keyboard when one is already up. With Message Agent open it
    /// closes Message Agent first, as ⌨ does.
    private func toggleToolsKeyboard() {
        guard isOnStage() else { return }
        guard isDirectInput else {
            guard !isKeyboardHandoffInFlight else { return }
            applyInputMode(.direct, raisesKeyboard: false)
            // The terminal takes input once it re-renders as Direct Input.
            Task { @MainActor in
                await Task.yield()
                guard isOnStage(), isDirectInput else { return }
                switchDirectKeyboard()
            }
            return
        }
        switchDirectKeyboard()
    }

    private func toggleDirectKeyboard() {
        guard isOnStage() else { return }
        if usesDirectToolsKeyboard {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                usesDirectToolsKeyboard = false
                expectsDirectSystemKeyboard = false
                keyboardInset.resumeHeightCapture()
                keyboardControl.setKeyboardMode(.text)
            }
            directKeyboardIntent.setWantsKeyboard(false)
            keyboardControl.dismissKeyboard()
        } else if keyboardControl.isKeyboardUp {
            expectsDirectSystemKeyboard = false
            directKeyboardIntent.setWantsKeyboard(false)
            keyboardControl.dismissKeyboard()
        } else {
            directKeyboardIntent.setWantsKeyboard(true)
            keyboardControl.requestKeyboard()
        }
    }

    /// See `TerminalKeyboardMode.controlsReleaseFirstResponder`.
    private var toolsDockReleasesFocus: Bool {
        TerminalKeyboardMode.controlsReleaseFirstResponder
    }

    private func switchDirectKeyboard() {
        guard isOnStage() else { return }
        guard !usesDirectToolsKeyboard else {
            showDirectSystemKeyboard()
            return
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            expectsDirectSystemKeyboard = false
            keyboardInset.pauseHeightCapture()
            usesDirectToolsKeyboard = true
            keyboardControl.setKeyboardMode(.controls)
        }
        if toolsDockReleasesFocus {
            directKeyboardIntent.setWantsKeyboard(false)
            keyboardControl.dismissKeyboard()
        } else {
            directKeyboardIntent.setWantsKeyboard(true)
            keyboardControl.requestKeyboard()
        }
    }

    /// Blocked delivery types into Attach without Enter; the tools keyboard
    /// is what submits or cancels. A Dictation send can land up to 45 s
    /// later, so it does nothing once this screen left the stage or Direct
    /// Input.
    private func showDirectToolsKeyboard() {
        guard isOnStage(), isDirectInput, !usesDirectToolsKeyboard else { return }
        switchDirectKeyboard()
    }

    /// A Dictation or Custom Key outcome to review (failed send, Blocked
    /// Agent, or an interruption): Message Agent opens on it, keyboard down.
    /// Ignored once this screen left the stage.
    private func showComposerForDictation() {
        guard paneActionsAvailable else { return }
        guard isOnStage(), isDirectInput, !isKeyboardHandoffInFlight else { return }
        applyInputMode(.composer)
    }

    /// 🎤. Stop sends what was said straight to the Agent; neither Message
    /// Agent nor the keyboard changes, unless Send failed, where Message
    /// Agent opens on its failure row with Retry and Edit Draft. A Blocked
    /// Agent would take the words as keys into its dialog, so there they go
    /// into the draft for review instead.
    private func toggleDictation() {
        guard paneActionsAvailable else { return }
        let sender = dictationSender
        switch sender.dictation.phase {
        case .idle:
            sender.start()
        case .listening:
            if agent.agent.status == .blocked {
                Task {
                    if await sender.stopAndKeep(in: composer) {
                        showComposerForDictation()
                    }
                }
                return
            }
            Task {
                switch await sender.stopAndSend(through: composer) {
                case .failed, .queued:
                    showComposerForDictation()
                case .deliveredViaAttach:
                    showDirectToolsKeyboard()
                case .ignored, .deliveredViaPrompt, .deliveredViaPaneInput:
                    break
                }
            }
        case .starting, .downloadingModel:
            // The spinner cancels a startup that is taking too long.
            sender.cancel()
        case .finishing:
            break
        }
    }

    /// Tools → iOS keyboard. Holds `.system` through UIKit's coalesce window
    /// so content inset stays at lastPresentedHeight instead of dipping to
    /// zero. On iPad the dock released first responder, so the keyboard is
    /// requested again unless the tap that raised it already did.
    private func showDirectSystemKeyboard() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            expectsDirectSystemKeyboard = true
            keyboardInset.resumeHeightCapture()
            usesDirectToolsKeyboard = false
            keyboardControl.setKeyboardMode(.text)
        }
        directKeyboardIntent.setWantsKeyboard(true)
        if toolsDockReleasesFocus, !keyboardControl.isFirstResponder {
            keyboardControl.requestKeyboard()
        }
    }

    private func armDirectKeyboardClaimIfNeeded() {
        guard isDirectInput else { return }
        guard AgentDirectInputPresentation.shouldClaimKeyboard(
            wantsKeyboard: directKeyboardIntent.wantsKeyboard,
            isKeyboardUp: keyboardControl.isKeyboardUp,
            usesToolsKeyboard: usesDirectToolsKeyboard,
            softwareKeyboardHeight: keyboardInset.height)
        else { return }
        // Same-screen replacements read this intent directly. Arming another
        // one-shot here would survive consumption and reopen a later visit.
        directKeyboardIntent.setWantsKeyboard(true)
    }

    private func handleActivation() {
        let afterPossibleSuspension = activity.lastAbsenceMayHaveSuspended
        if afterPossibleSuspension {
            armDirectKeyboardClaimIfNeeded()
        }
        attach.didBecomeActive(afterPossibleSuspension: afterPossibleSuspension)
    }

    private func openAttachLink(_ link: AttachLink) {
        let openURL = openURL
        attach.openAttachLink(link) { url in
            guard !Task.isCancelled else { return false }
            let (results, continuation) = AsyncStream<Bool>.makeStream(
                bufferingPolicy: .bufferingNewest(1))
            openURL(url) { accepted in
                continuation.yield(accepted)
                continuation.finish()
            }
            return await withTaskCancellationHandler {
                for await accepted in results {
                    return accepted
                }
                return false
            } onCancel: {
                continuation.finish()
            }
        }
    }

    /// Opens the Agent the new-agent sheet started. The keyboard is armed
    /// first: the selection change rebuilds this screen from scratch, and the
    /// new terminal claims the handoff as it comes up.
    private func switchToAgent(_ id: ConsoleAgent.ID) {
        guard id != agent.id else { return }
        armAgentKeyboardHandoffIfKeyboardIsUp(for: id)
        onSwitch(id)
    }

    /// Whether leaving this screen should bring the keyboard up on the next
    /// one: a move made with the keyboard down must not raise one on the
    /// other side. Direct Input may keep first responder with a hardware
    /// keyboard and a zero inset.
    private var keyboardIsUpForHandoff: Bool {
        isDirectInput
            ? AgentDirectInputPresentation.shouldClaimKeyboard(
                wantsKeyboard: directKeyboardIntent.wantsKeyboard,
                isKeyboardUp: keyboardControl.isKeyboardUp,
                usesToolsKeyboard: usesDirectToolsKeyboard,
                softwareKeyboardHeight: keyboardInset.height)
            : keyboardInset.height > 0
    }

    /// The keyboard a destination inherits: Direct Input's tools dock stays a
    /// tools dock, everything else hands over the text keyboard.
    private var keyboardHandoffMode: TerminalKeyboardMode {
        isDirectInput && usesDirectToolsKeyboard ? .controls : .text
    }

    private func armAgentKeyboardHandoffIfKeyboardIsUp(for id: ConsoleAgent.ID) {
        guard id != agent.id, keyboardIsUpForHandoff else { return }
        keyboardHandoff.arm(for: id, mode: keyboardHandoffMode)
    }

    /// A shell opened from here before its row is known — Open Terminal's
    /// chooser or a terminal still being created — comes up with the
    /// keyboard in the state this screen leaves it: up stays up, down stays
    /// down. Agent detail re-arms it for the row once the row is resolved.
    private func armShellTerminalKeyboardHandoffIfKeyboardIsUp() {
        if keyboardIsUpForHandoff {
            keyboardHandoff.armShellTerminal(mode: keyboardHandoffMode)
        } else {
            keyboardHandoff.cancelShellTerminal(ifOwnedBy: keyboardHandoff.shellTerminalToken)
        }
    }

    /// Marks this Agent unread and returns to the Console index, where it
    /// lists as Done. Does nothing when the mark is refused (the Agent
    /// started working since the menu opened), so a tap never leaves the
    /// screen without having marked it.
    private func performMarkUnread() {
        guard console.markUnread(agent) else { return }
        AccessibilityNotification.Announcement(
            "Marked \(Self.displayTitle(for: agent)) as unread").post()
        onMarkedUnread()
    }

    private func performClose() async {
        if await attach.closeAgent() {
            let verb = agent.backend.archivesOnClose ? "Archived" : "Closed"
            AccessibilityNotification.Announcement("\(verb) \(Self.displayTitle(for: agent))").post()
            onClosed()
        } else {
            closeErrorMessage = attach.closeFailureMessage
        }
    }

    /// The dialog wears the terminal's theme, not the system's.
    private var themePalette: TerminalThemePalette {
        terminal.themes.selection(for: colorScheme).palette(for: colorScheme)
    }

    private var messageJumpAvailability: MessageJumpControlAvailability {
        MessageJumpControlAvailability.evaluate(
            isAlternateScreen: messageJump.scrollControl.isAlternateScreen,
            canScrollRemoteContent: messageJump.scrollControl.canScrollRemoteContent,
            reach: messageJump.reach,
            runningJump: messageJump.runningJump)
    }

    private var scrollJumpAvailability: ScrollJumpAvailability {
        messageJump.scrollJumpAvailability
    }

    /// iPhone (and any compact width, where the split view collapses) has no
    /// sidebar to switch Agents from: this is the visible way back to the
    /// Console, beside the back swipe. Settings › Terminal Appearance › Hide Back Button removes it
    /// and leaves the back swipe.
    private var showsBackButton: Bool {
        horizontalSizeClass == .compact && !terminal.backButton.isHidden
    }

    /// The control floating at the Agent's top-leading corner, if any: the
    /// iPad slide-over's sidebar toggle, or Back. The top row reserves its
    /// height so no terminal row starts under it.
    private var topControlSlot: ConsoleSidebarHeaderSlot? {
        if let sidebarToggleSlot { return sidebarToggleSlot }
        return showsBackButton && !isCompactHeight ? Self.backButtonSlot : nil
    }

    /// Landscape iPhone: too short to give Back its own row.
    private var isCompactHeight: Bool { verticalSizeClass == .compact }

    // MARK: Agent Footer

    private func footerContext(at now: Date) -> AgentFooterContext {
        AgentFooterContext(
            agent: agent,
            branch: gitBranch.branch,
            model: sessionUsage.usage.model,
            contextText: sessionUsage.contextText,
            costText: sessionUsage.usage.costText,
            rateText: sessionUsage.showsTokenRate ? sessionUsage.usage.rateText : nil,
            transport: attach.terminal.runningFlavor,
            progress: agent.progressDisplay(at: now))
    }

    /// Landscape iPhone's one line, and what the band fits.
    private var footerMaximumLines: Int {
        AgentFooterBand.lineCap(
            isCompactHeight: isCompactHeight,
            height: AgentFooterBand.height(bottomSafeAreaInset: bottomSafeAreaInset))
    }

    /// The usage figures the footer shows, which the top strip leaves out.
    /// Independent of the keyboard: a figure does not jump back up while the
    /// footer is covered.
    private var movedUsage: Set<AgentFooterField> {
        AgentFooterRenderer.displayedUsageFields(
            layout: terminal.footer.layout, context: footerContext(at: .now),
            maximumLines: footerMaximumLines)
    }

    /// A system keyboard (terminal or Composer) or the Tools keyboard sits
    /// over the band. Message Agent open with its keyboard down is not.
    private var footerIsCovered: Bool {
        activeKeyboardPresentation == .tools || composerKeyboardLayout.contentInset > 0
    }

    /// Where to read the footer's branch; nil pauses polling and keeps the
    /// branch. An unknown (empty) cwd passes through so the branch clears.
    private var footerBranchDirectory: String? {
        let layout = terminal.footer.layout
        let cap = footerMaximumLines
        guard scenePhase != .background, cap > 0, layout.isEnabled,
              layout.shownLines(maximumLines: cap).joined().contains(.branch) else { return nil }
        return agent.agent.cwd
    }

    /// The width Back needs beside the terminal in compact height: the
    /// button with `backButtonInset` either side.
    static let compactBackColumnWidth =
        backButtonInset * 2 + MessageJumpControlView.buttonSize

    /// What the leading safe-area gutter lacks of that column. Notched
    /// phones' landscape gutter nearly covers it; home-button phones have
    /// none, and the terminal gives up the whole column.
    private var compactBackColumnTopUp: CGFloat {
        Self.compactBackColumnTopUp(gutter: leadingSafeAreaInset)
    }

    static func compactBackColumnTopUp(gutter: CGFloat) -> CGFloat {
        max(0, compactBackColumnWidth - gutter)
    }

    private static let backButtonInset = ConsoleSlideOverGeometry.toggleTopInset

    /// Back sits where the iPad sidebar toggle does, so the Agent's top row
    /// is one height on every device.
    private static let backButtonSlot = ConsoleSidebarHeaderSlot(
        leading: backButtonInset + MessageJumpControlView.buttonSize
            + ConsoleSlideOverGeometry.toggleToHeaderSpacing,
        centerY: backButtonInset + MessageJumpControlView.buttonSize / 2)

    /// Back to the Console, as the back swipe does: a floating circle in the
    /// terminal's theme, like the other controls over its output, centered
    /// on the top row's line.
    private var backButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 16, weight: .semibold))
                .opacity(TerminalFloatingButtonStyle.iconOpacity)
        }
        .buttonStyle(TerminalBackButtonStyle(palette: themePalette))
        .foregroundStyle(themePalette.foreground)
        .hoverEffect(.highlight)
        .accessibilityLabel("Back")
        .accessibilityHint("Returns to the Agent list")
    }

    @ViewBuilder
    private var messageJumpChrome: some View {
        MessageJumpChromeOverlay(
            availability: messageJumpAvailability,
            runningDirection: messageJump.runningDirection,
            palette: themePalette,
            edgeFraction: terminal.edgeDock.fraction(for: .messageJump),
            onOlder: { jumpToOlderMessage() },
            onNewer: { jumpToNewerMessageOrLive() },
            onDock: { terminal.edgeDock.setFraction($0, for: .messageJump) })
        // Hit-test only while enabled. The in-flight spinner must not eat
        // terminal drags. Placement and pass-through live in
        // MessageJumpChromeContainer.
        .allowsHitTesting(messageJumpAvailability.isEnabled)
    }

    private func jumpToOlderMessage() {
        let availability = messageJumpAvailability
        guard availability.isEnabled, availability.showsOlder else { return }
        messageJump.runJump(.older) { session in
            // Entry generation/cancellation already checked inside runJump
            // before this body is entered.
            _ = await self.messageJump.jumpOlder(in: session)
        }
    }

    /// Walks toward live one user message at a time. When no newer message
    /// remains, finishes the trip with ``returnToLive()`` so the same button
    /// covers both "next message" and "back to live" (issue #268). The follow-up
    /// is abandoned if the Attach session was replaced while `jump` was awaited.
    private func jumpToNewerMessageOrLive() {
        let availability = messageJumpAvailability
        guard availability.isEnabled, availability.showsNewer else { return }
        messageJump.runJump(.newer) { session in
            _ = await self.messageJump.jumpNewerOrLive(in: session)
        }
    }

    /// The scroll-jump tab (issue #58), hidden where it cannot fit clear of
    /// the message-jump tab.
    private var scrollJumpChrome: some View {
        let availability = scrollJumpAvailability
        let messageJumpTabVisible = messageJumpAvailability.isVisible
        return GeometryReader { proxy in
            if let bottomPadding = ScrollJumpPlacement.bottomPadding(
                terminalHeight: proxy.size.height,
                messageJumpTabVisible: messageJumpTabVisible)
            {
                ScrollJumpButton(availability: availability, palette: themePalette) {
                    jumpToScrollEnd()
                }
                .padding(.bottom, bottomPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        // Hidden means no hit: a press that just sent the terminal on its way
        // must not leave an invisible target eating the next drag.
        .allowsHitTesting(availability.isVisible)
        .animation(.snappy(duration: 0.22), value: availability)
    }

    /// The rest of the way to the oldest history or to live, whichever way
    /// the user was scrolling. Shares the message jumps' controller and
    /// session guard through ``AgentMessageJumpWiring/runJump(_:kind:_:)``.
    private func jumpToScrollEnd() {
        let availability = scrollJumpAvailability
        guard let direction = availability.direction else { return }
        messageJump.runJump(direction, kind: .scroll) { session in
            _ = await self.messageJump.jumpToScrollEnd(direction, in: session)
        }
    }

    /// Never on a tmux row: it attaches its own client (ADR 0026).
    private var liveInAnotherWindow: LiveInAnotherWindowPresentation? {
        LiveInAnotherWindowPresentation(
            access: agent.backend.terminalAccess(
                sceneRouting?.terminalAccess(for: agent.hostID) ?? .holds))
    }

    private var terminalStatusPresentation: TerminalStatusPresentation? {
        TerminalStatusPresentation(
            status: attach.terminalStatus,
            hostCondition: MissingAgentPresentation.attachHostCondition(
                agentID: agent.id, console: console, hosts: hosts))
    }

    /// The Toolbar's connection dot: the state of the attach that the
    /// terminal itself no longer covers with a dialog.
    private var terminalConnectionIndicator: TerminalConnectionIndicator? {
        TerminalConnectionIndicator(
            status: attach.terminalStatus,
            presentation: terminalStatusPresentation,
            isStalled: attach.terminalIsStalled,
            isSceneActive: scenePhase == .active,
            endedWithMoshFailure: attach.terminalEndedWithMoshFailure,
            liveInAnotherWindow: liveInAnotherWindow != nil)
    }

    /// Whether a status dialog dims the terminal: its backdrop takes every
    /// tap over it.
    private var statusDialogDimsTerminal: Bool {
        liveInAnotherWindow != nil || showsOfflineReader
            || terminalStatusPresentation?.dimsBackground == true
    }

    /// The reader is up over the terminal, and the copy it shows still exists.
    private var showsOfflineReader: Bool {
        isReadingOfflineCopy && savedTranscript != nil
    }

    /// While the reader is open, the most the Composer's queued rows may
    /// take so the reader keeps room to read; nil when it is closed.
    private var offlineReaderQueueCap: CGFloat? {
        guard showsOfflineReader, let chromeTop = readerGeometry.chromeTop else { return nil }
        // The window's height above the keyboard: neither the chrome's growth
        // nor the reader's own frame moves it.
        let region = readerGeometry.terminalRegion
        let window = sceneWindow?.window ?? mountedWindow.window
        let availableHeight = (window?.bounds.height ?? region.maxY) - keyboardInset.height
        return OfflineReading.queueAreaCap(
            containerMinY: region.minY, availableHeight: availableHeight,
            chromeTop: chromeTop, queueAreaHeight: readerGeometry.queuedAreaHeight)
    }

    /// Whether the Read pill and the connection popover's Read saved
    /// conversation are offered (`OfflineReading.offersReader`).
    private var offersOfflineReader: Bool {
        guard paneActionsAvailable else { return false }
        return OfflineReading.offersReader(
            connection: terminalConnectionIndicator, saved: savedTranscript,
            hasNetwork: console.hasNetwork, reconnectingFor: reconnectingFor)
    }

    /// The connection dot's Read saved conversation: nil unless offered.
    private var savedReadingAction: (() -> Void)? {
        guard offersOfflineReader else { return nil }
        return { openOfflineReader() }
    }

    /// Changes when the Agent's kept transcript does, or when whose copy it
    /// is does (another terminal takes the pane, its chat marker's launch
    /// moves, or it reports another session): the copy is then a different one.
    private var savedTranscriptLoadID: String {
        let key = console.chatTranscriptKey(for: agent)
        let identity = console.currentTranscriptIdentity(for: agent) ?? "-"
        return "\(console.savedTranscriptRevisions[agent.id] ?? 0)/\(key.terminalID)/\(key.launchedAt)/\(identity)"
    }

    /// Read: shows the saved conversation over the terminal, with the
    /// Composer card open under it so a reply can be written, and queued
    /// when the Host is out of reach, as from any other state of this screen.
    private func openOfflineReader() {
        guard savedTranscript != nil else { return }
        if isDirectInput {
            guard isOnStage(), !isKeyboardHandoffInFlight else { return }
            applyInputMode(.composer)
        }
        isReadingOfflineCopy = true
    }

    /// A tap the back-swipe strip caught, at `point` in the terminal's own
    /// coordinates (the strip lies along its leading edge, full height):
    /// handed on to the terminal unless a dimmed status dialog covers it,
    /// which takes every other tap there.
    private func forwardEdgeTap(at point: CGPoint) {
        guard !statusDialogDimsTerminal else { return }
        keyboardControl.forwardTap(at: point)
    }

    /// Whether a reconnecting terminal keeps its last painted frame up: the
    /// outgoing surface itself until its replacement mounts, then a copy of
    /// it until the replacement paints (#21). A cold open has no frame to
    /// keep.
    private var showsLastFrame: Bool {
        liveInAnotherWindow == nil
            && terminalStatusPresentation?.kind == .connecting
            && lastFrame.hasFrame(for: attach.terminalID)
    }

    /// A plain reattach over a kept frame: VoiceOver hears "Reconnecting"
    /// as it starts, which is also what Ignition's label says while it lasts.
    /// A live mosh terminal whose Host went quiet while the app is in front
    /// shows the Reconnecting pill over its live frame until the Host answers
    /// again (#105).
    private var showsReconnectingIndicator: Bool {
        (showsLastFrame && terminalStatusPresentation == .connecting)
            || (liveInAnotherWindow == nil && scenePhase == .active && attach.terminalIsStalled)
    }

    /// States after which the held frame no longer stands for anything the
    /// terminal will show again: an ended attach, an unavailable Host, or
    /// the terminal taken over by another window.
    private var discardsLastFrame: Bool {
        if liveInAnotherWindow != nil { return true }
        switch terminalStatusPresentation?.kind {
        case .ended, .hostUnavailable: return true
        case .connecting, nil: return false
        }
    }

    /// An ended attach: the Agent's saved frame goes too. A paused or failed
    /// Host and a terminal live in another window are transient, so the
    /// saved frame stays for the next return (`retainAgents`/`retainHosts`
    /// drop frames of gone panes and re-targeted Hosts).
    private var endsLastFrame: Bool {
        terminalStatusPresentation?.kind == .ended
    }

    /// Records the surface drawing a live pipeline as the one whose frame a
    /// later replacement keeps.
    private func registerPaintedSurface() {
        guard attach.terminalStatus == .live else { return }
        let surface = keyboardControl.terminal.flatMap {
            attach.terminalFeed.isAttached(to: $0) ? $0 : nil
        }
        lastFrame.surfaceDidPaint(attach.terminalID, view: surface)
    }

    /// Keeps the frame this screen's live terminal shows as the Agent's
    /// latest, for its next entry. A discarded frame stays gone: nothing has
    /// painted since.
    private func recordLastFrame() {
        lastFrames?.record(lastFrame.paintedTerminal(of: attach.terminalID), for: agent, hosts: hosts)
    }

    /// Ignition (#96): the loader while the terminal connects, the kept
    /// frame (#21) under it, and the reveal once the terminal paints.
    private var ignitionOverlay: some View {
        TerminalIgnitionView(
            presentation: liveInAnotherWindow == nil ? terminalStatusPresentation : nil,
            isLive: attach.terminalStatus == .live,
            isWarm: showsLastFrame,
            snapshot: lastFrame.snapshot,
            palette: themePalette,
            identity: TerminalIgnitionIdentity(agent: agent, launch: launch),
            flavor: attach.lastSessionFlavor,
            fontSize: CGFloat(terminal.zoom.fontSize),
            surface: keyboardControl)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let away = liveInAnotherWindow {
            // Ahead of the terminal status: this window released its Attach
            // on purpose, so its stopped terminal says nothing useful.
            TerminalStatusDialog(
                glyph: .symbol(away.systemImage),
                title: away.title,
                message: away.message,
                palette: themePalette
            ) {
                Button(LiveInAnotherWindowPresentation.takeOverTitle) {
                    sceneRouting?.takeOverTerminal(for: agent.hostID)
                }
                .buttonStyle(.borderedProminent)
            }
        } else if let presentation = terminalStatusPresentation {
            switch presentation.kind {
            case .connecting:
                // Ignition speaks for a connecting terminal, Host
                // conditions included (`ignitionOverlay`).
                EmptyView()
            case .ended:
                // With content to read the terminal stays as it is and the
                // Toolbar's connection dot says it detached and offers
                // Reattach. A cold failure has nothing to read, so it keeps a
                // dialog, which never dims (`dimsBackground` is off for ended).
                if !attach.terminalHasBeenLive {
                    TerminalStatusDialog(
                        glyph: .symbol("cable.connector.slash"),
                        title: presentation.title,
                        message: presentation.message,
                        palette: themePalette,
                        dimsBackground: presentation.dimsBackground
                    ) {
                        VStack(spacing: 8) {
                            Button("Reattach") { attach.retryTerminal() }
                                .buttonStyle(.borderedProminent)
                            if attach.terminalEndedWithMoshFailure {
                                Button("Use SSH Instead") { attach.useSSHInstead() }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            case .hostUnavailable(let systemImage):
                TerminalStatusDialog(
                    glyph: .symbol(systemImage),
                    title: presentation.title,
                    message: presentation.message,
                    palette: themePalette,
                    dimsBackground: presentation.dimsBackground)
            }
        } else if showsReconnectingIndicator {
            TerminalReconnectingIndicator(palette: themePalette)
        } else {
            // .live needs nothing, and .stopped only reaches the view while the
            // screen is on its way off stage (see `AgentAttachStore.terminalStatus`).
            EmptyView()
        }
    }

    @ViewBuilder
    private var pasteReviewSheet: some View {
        if let review = attach.pendingPaste {
            NavigationStack {
                VStack(alignment: .leading, spacing: 12) {
                    Text(
                        "\(review.lineCount) lines, \(review.characterCount) characters")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ScrollView {
                        Text(review.preview)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .background(.quaternary, in: .rect(cornerRadius: 10))
                }
                .padding()
                .navigationTitle("Review Paste")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", role: .cancel) { attach.cancelPaste() }
                            .tint(Brand.Colors.quietAction)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Paste") { attach.confirmPaste() }
                            .disabled(!attach.canConfirmPaste)
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .modifier(SampleContextModifier())
        }
    }

    static func displayTitle(for agent: ConsoleAgent) -> String {
        agent.agent.title.isEmpty ? agent.agent.displayName : agent.agent.title
    }
}

/// Preserve edge-swipe navigation after the title bar is removed. The strip
/// covers the terminal's first columns, so a tap that does not move is handed
/// to `onTap` rather than swallowed, in the strip's own coordinates: laid
/// along the terminal's leading edge at its full height, those are the
/// terminal's too, wherever the Console layout puts it.
///
/// On iPhone a swipe from the screen's leading edge goes back to the Console
/// list. Inside the iPad slide-over layout, which sets
/// `consoleSidebarRevealDrag`, the list lies under the Agent instead, so the
/// strip never goes back: it hands a horizontal drag to the layout, and the
/// Agent follows the finger. With the list hidden only a drag from the
/// screen's edge opens it; with the list out the strip sits at the Agent's
/// leading edge beside it, where a leftward drag closes it.
private struct AgentEdgeBackGesture: View {
    /// Its selection handles' touch areas, in the terminal's coordinates
    /// (the strip's too), are cut out of the strip so a handle there stays
    /// grabbable. Read here, not by the Agent view, so a moving handle
    /// redraws only the strip.
    let keyboardControl: TerminalKeyboardControl
    let onTap: @MainActor (CGPoint) -> Void
    let dismiss: @MainActor () -> Void

    @Environment(\.consoleSidebarRevealDrag) private var revealDrag
    /// What the current iPad drag turned out to be, decided on its first
    /// change. Nil between drags, and for the whole of an iPhone swipe.
    @State private var revealPhase: RevealPhase?
    /// Up only while a drag is recognized. SwiftUI skips `onEnded` for a
    /// cancelled gesture but still resets this, so its fall ends a drag the
    /// layout would otherwise be left holding mid-slide.
    @GestureState private var isDragging = false

    private enum RevealPhase {
        /// Handed to the value the drag began with: the layout rebuilds its
        /// value as the slide moves, and a drag must end where it began.
        case forwarding(ConsoleSidebarRevealDrag, lastTranslation: CGFloat)
        /// Vertical, or not from the screen's edge while the list is hidden:
        /// left alone for its whole length.
        case ignored
    }

    var body: some View {
        Color.clear
            .frame(width: 24)
            .frame(maxHeight: .infinity)
            .contentShape(EdgeStripShape(holes: keyboardControl.touchSelectionHandleAreas))
            .gesture(
                // `.global` is the window's space wherever the Console layout
                // puts the terminal: the swipe starts only from the window's
                // leading edge.
                DragGesture(minimumDistance: 12, coordinateSpace: .global)
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { dragChanged($0) }
                    .onEnded { dragEnded($0) })
            .onTapGesture { onTap($0) }
            .onChange(of: isDragging) { _, dragging in
                if !dragging { dragCancelled() }
            }
            // The strip can leave mid-drag — the Agent's pane exits or another
            // Agent takes its place — and the gesture then never reports its
            // end, which would strand the slide between rest positions.
            .onDisappear { dragCancelled() }
            .accessibilityHidden(true)
    }

    private func dragChanged(_ value: DragGesture.Value) {
        let translation = value.translation.width
        switch revealPhase {
        case .forwarding(let drag, _):
            revealPhase = .forwarding(drag, lastTranslation: translation)
            drag.changed(translation)
        case .ignored:
            break
        case nil:
            // iPhone's swipe back decides only when the finger lifts.
            guard let revealDrag else { return }
            guard abs(translation) > abs(value.translation.height),
                  revealDrag.isSidebarVisible || value.startLocation.x <= 24
            else {
                revealPhase = .ignored
                return
            }
            revealPhase = .forwarding(revealDrag, lastTranslation: translation)
            revealDrag.changed(translation)
        }
    }

    private func dragEnded(_ value: DragGesture.Value) {
        let phase = revealPhase
        revealPhase = nil
        switch phase {
        case .forwarding(let drag, _):
            drag.ended(value.translation.width, value.velocity.width)
        case .ignored:
            break
        case nil:
            // Inside the slide-over layout the list is under the Agent, so
            // there is nothing to go back to.
            guard revealDrag == nil else { return }
            let horizontal = value.translation.width
            guard value.startLocation.x <= 24,
                  horizontal >= 72,
                  abs(value.translation.height) <= horizontal * 0.75
            else { return }
            dismiss()
        }
    }

    /// Runs after `onEnded` too, which has already cleared the phase, and
    /// again on disappearance, so no drag is ended twice.
    private func dragCancelled() {
        let phase = revealPhase
        revealPhase = nil
        guard case .forwarding(let drag, let lastTranslation) = phase else { return }
        drag.ended(lastTranslation, 0)
    }
}

/// The back-swipe strip's touch area: its whole rectangle minus `holes`.
struct EdgeStripShape: Shape {
    let holes: [CGRect]

    func path(in rect: CGRect) -> Path {
        holes.reduce(Path(rect)) { $0.subtracting(Path($1)) }
    }
}

private struct AgentTerminalKeyboardInsetModifier: ViewModifier {
    let height: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.bottom, height)
    }
}

/// The file preview's presenters, all bound to one `TerminalFilePreviewStore`:
/// Quick Look, the rendered Markdown sheet (#147), and the Couldn't Preview
/// File alert. Applied twice: at the terminal, active while the Files &
/// Links list is down, and on that list, active while it is up, so a file
/// picked there previews over it and closing the preview lands back on it.
/// Exactly one copy is active at any moment: two presenters bound to one
/// store value would race to show it, and one under a sheet cannot show at all.
private struct TerminalFilePreviewPresenters: ViewModifier {
    let store: TerminalFilePreviewStore
    let isActive: Bool
    /// The terminal's own size class, even on the list: inside the list's
    /// form sheet on iPad the environment reads compact, which would cost
    /// the Markdown sheet its tall form.
    let horizontalSizeClass: UserInterfaceSizeClass?
    /// Whether the Markdown sheet shows the raw text.
    let markdownShowsRaw: Binding<Bool>

    func body(content: Content) -> some View {
        // Read here, not only inside the bindings, so this body is what
        // observes the store, wherever it is applied.
        let previewURL = isActive ? store.previewURL : nil
        let markdownPreview = isActive ? store.markdownPreview : nil
        let failureMessage = isActive ? store.failureMessage : nil
        return content
            .quickLookPreview(
                Binding(
                    get: { previewURL },
                    set: { if $0 == nil, isActive { store.previewDidClose() } }))
            .sheet(
                item: Binding(
                    get: { markdownPreview },
                    set: { if $0 == nil, isActive { store.markdownPreviewDidClose() } })
            ) { preview in
                markdownPreviewSheet(preview)
            }
            .quietCancelAlert(
                "Couldn't Preview File",
                isPresented: Binding(
                    get: { failureMessage != nil },
                    set: { if !$0, isActive { store.dismissFailure() } })
            ) {
                Button("OK", role: .cancel) {
                    store.dismissFailure()
                }
                .tint(Brand.Colors.quietAction)
            } message: {
                Text(failureMessage ?? "")
            }
    }

    /// A tapped Markdown file, rendered (#147). Its links ask through the
    /// sheet's own confirmation, then read through `store`, which removes
    /// their copies when the sheet closes.
    private func markdownPreviewSheet(_ preview: MarkdownFilePreview) -> some View {
        MarkdownFilePreviewSheet(
            preview: preview,
            showsRaw: markdownShowsRaw,
            loadLinkedFile: { [store] file, workingDirectory in
                try await store.linkedPreview(file, workingDirectory: workingDirectory)
            },
            confirmationDetail: { [store] target, workingDirectory in
                await store.confirmationDetail(for: target, workingDirectory: workingDirectory)
            },
            failureMessage: TerminalFilePreviewStore.failureMessage(for:))
        .modifier(ConsoleSheetPresentationModifier(
            presentation: ConsoleSheetPresentation(horizontalSizeClass: horizontalSizeClass),
            isTall: true))
    }
}
