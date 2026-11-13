import Foundation
import Observation
import UIKit
import UniformTypeIdentifiers

typealias AttachmentStageProgressHandler = @Sendable (AttachmentStageProgress) async -> Void
typealias ImageStager =
    @Sendable (PreparedImage, AttachmentStageProgressReporter) async throws -> StagedImage
typealias FileStager =
    @Sendable (PreparedFile, AttachmentStageProgressReporter) async throws -> StagedFile

struct AttachmentStageProgressReporter: Sendable {
    private let handler: AttachmentStageProgressHandler

    init(_ handler: @escaping AttachmentStageProgressHandler) {
        self.handler = handler
    }

    func report(_ progress: AttachmentStageProgress) async {
        await handler(progress)
    }
}

@MainActor
protocol AttachmentClipboard {
    func copy(_ path: String) throws
}

@MainActor
struct SystemAttachmentClipboard: AttachmentClipboard {
    static let lifetime: TimeInterval = 24 * 60 * 60

    func copy(_ path: String) throws {
        UIPasteboard.general.setItems(
            [[UTType.plainText.identifier: path]],
            options: [
                .localOnly: true,
                .expirationDate: Date().addingTimeInterval(Self.lifetime),
            ])
    }
}

typealias AttachLinkOpener = @MainActor @Sendable (URL) async -> Bool

struct AttachLinkOpenFailure: Identifiable, Equatable {
    let link: AttachLink

    var id: String { link.id }
    var message: String {
        "The link to \(link.host) couldn't be opened. You can copy it instead."
    }
}

/// Owns the complete Agent Attach interaction: terminal lifetime, Composer
/// staging, reconnect replacement, close, and deterministic leave ordering.
/// The view only forwards UI events.
@MainActor
@Observable
final class AgentAttachStore {
    /// Attach presence and leave cleanup are related, but not interchangeable.
    /// A recovery may become invalid off stage before SwiftUI delivers the
    /// real leave callback. That transition requires a later full terminal
    /// replacement, while `leave()` still owns the interaction cleanup.
    private enum LifecycleState {
        case active
        case rejoinRequired
        case left
    }

    /// What the Attach resolves: an Agent's pane (`agent attach`), or a
    /// plain shell's terminal (`terminal attach`, which `agent attach`
    /// refuses for a pane with no Agent — ADR 0015).
    private let target: TerminalAttachTarget
    private let runTerminal: TerminalSessionRunner
    private let linkIndex: AttachLinkIndex
    private let mediaIndex: AttachMediaIndex
    /// Invalidates mosh for the store's Host, wired from the Console. The
    /// automatic fallback and the connection dot's "Use SSH Instead"
    /// both route through it.
    private let invalidateMosh: MoshInvalidation?
    /// Whether this screen is still the Console's current detail. The
    /// router's path is the ground truth SwiftUI's appear/disappear
    /// callbacks lack: they hand out spurious pairs amid navigation churn,
    /// on departing screens as well as staying ones.
    private let isOnStage: () -> Bool

    private(set) var terminal: AttachTerminalStore {
        willSet { terminalWillBeReplaced?(terminal) }
    }
    /// Told synchronously before a replacement pipeline takes over, while the
    /// outgoing terminal's surface is still on screen: the last moment its
    /// frame can be copied (#21).
    @ObservationIgnored var terminalWillBeReplaced: (@MainActor (_ outgoing: AttachTerminalStore) -> Void)?
    let input: TerminalInputController
    /// A tmux pane's copy-mode scroll path; nil on herdr. The Attach owns
    /// the one instance: the view, which SwiftUI rebuilds on every
    /// re-render, wires its scroll control to this one, and ``input``
    /// holds on it, so a scroll, the input it holds and the departure's
    /// leave all see the same position.
    let paneHistory: TmuxPaneHistory?
    let staging: ComposerStagingStore
    let close: ClosePaneStore
    /// Told about this Attach's staging teardown and rejoin. Binding the
    /// Composer Tray is the view's job: only the Attach actually on screen
    /// may drive it, and SwiftUI builds throwaway stores this one cannot
    /// tell apart from the real one.
    private let composer: any ComposerTrayLifecycle
    private(set) var attachLinkOpenFailure: AttachLinkOpenFailure?

    private var transportGeneration: UInt64?
    /// How the most recent attach session was carried (mosh UDP or SSH PTY).
    /// The live terminal's transport flavor: every AttachTerminalStore
    /// records its own flavor when transportDidBecomeReady fires, so this
    /// reads the source of truth for the initial attach AND replacements —
    /// and for the host-level capsule's SSH→mosh upgrade.
    var lastSessionFlavor: TerminalSessionFlavor {
        terminal.lastSessionFlavor
    }
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleID: UInt64 = 0
    private var attachLinkOpenTask: Task<Void, Never>?
    private var attachLinkOpenID: UInt64 = 0
    private var lifecycleState = LifecycleState.active
    /// Owns recovery presentation for the latest scheduled replacement. Its
    /// predecessor may still be stopping, but an older queued transition cannot
    /// clear the token a newer transition installed. This is presentation
    /// state, not a transport claim: while it exists the screen must show
    /// recovery instead of the predecessor's stale `.live` state and its empty
    /// overlay.
    private var terminalRecoveryOwner: UUID?
    /// A possible-suspension activation observed by the selected screen is also
    /// a claim that this lifecycle is current. SwiftUI can still deliver a
    /// delayed disappear from the foreground mount after that claim, without a
    /// balancing appear. Only that recovery may survive such an on-stage leave;
    /// ordinary replacement and rejoin transitions keep their existing teardown
    /// semantics.
    private var activationRecoveryOwnsOnStageLifecycle = false
    /// Joins the independently scheduled readiness projection and terminal
    /// waiter for the exact foreground-recovery pipeline.
    private var activationRecovery = TerminalRecoveryGenerationLatch()
    #if DEBUG
    /// Created at the possible-suspension activation edge and retained until
    /// the replacement that actually publishes adopts it, or recovery is
    /// definitively abandoned off stage.
    private(set) var pendingForegroundRecoveryTrace: AttachRestorationTrace?
    #endif
    /// The grid sizes this device's layouts last had: a pipeline with one
    /// remembered starts at once instead of after the view's first layout
    /// (#105). nil keeps the wait.
    private let gridSizes: TerminalGridSizeMemory?
    /// The layout of the window presenting this terminal: what its
    /// remembered grid is keyed by (#105). Set by the presenting window
    /// (`AgentTerminalCache.acquire`); nil until one does.
    @ObservationIgnored
    var windowLayout: @MainActor () -> TerminalGridSizeMemory.Layout? = { nil }
    /// The viewport text last read, to read again when a transcript lands.
    @ObservationIgnored private var lastViewportText: String?
    /// The transcript being read for the indices, and which read it is.
    @ObservationIgnored private var transcriptReading: Task<Void, Never>?
    @ObservationIgnored private var transcriptReadingGeneration: UInt64 = 0
    /// The pipeline `startAtIntent()` started and no activation has looked
    /// at yet: it began after any absence it could be recovered from.
    private var unseenIntentPipeline: TerminalSurfaceID?
    /// The mosh pipeline a possible-suspension return is checking before
    /// replacing it (#105).
    private var moshContactCheck: Task<Void, Never>?
    private let recordsNetworkTelemetry: Bool

    init(
        target: TerminalAttachTarget,
        transportGeneration: UInt64?,
        recordsNetworkTelemetry: Bool,
        gridSizes: TerminalGridSizeMemory? = nil,
        isOnStage: @escaping () -> Bool,
        runTerminal: @escaping TerminalSessionRunner,
        stageImage: @escaping ImageStager,
        stageFile: @escaping FileStager,
        composer: any ComposerTrayLifecycle,
        paneHistory: TmuxPaneHistory? = nil,
        closePane: @escaping () async throws -> Void,
        invalidateMosh: MoshInvalidation? = nil,
        onUserInput: (@MainActor () -> Void)? = nil
    ) {
        let input = TerminalInputController(paneHistory: paneHistory)
        input.onUserInput = onUserInput
        self.target = target
        self.isOnStage = isOnStage
        self.runTerminal = runTerminal
        self.invalidateMosh = invalidateMosh
        self.transportGeneration = transportGeneration
        self.gridSizes = gridSizes
        self.recordsNetworkTelemetry = recordsNetworkTelemetry
        self.input = input
        self.paneHistory = paneHistory
        self.composer = composer
        let linkIndex = AttachLinkIndex()
        self.linkIndex = linkIndex
        let mediaIndex = AttachMediaIndex()
        self.mediaIndex = mediaIndex
        // The first pipeline reports readiness to the recovery latch like
        // every replacement, through a relay: `self` is not there yet.
        let relay = PipelineReadinessRelay()
        terminal = Self.makeTerminal(
            target: target, input: input,
            recordsNetworkTelemetry: recordsNetworkTelemetry,
            transportGeneration: transportGeneration,
            runTerminal: runTerminal, linkIndex: linkIndex, mediaIndex: mediaIndex,
            transportReady: { pipelineID, generation, _ in
                relay.store?.terminalTransportDidBecomeReady(
                    pipelineID: pipelineID, generation: generation)
            },
            runDidFinish: { pipelineID in
                relay.store?.activationRecovery.clear(boundTo: pipelineID)
            },
            onMoshFailure: invalidateMosh)
        staging = ComposerStagingStore(stageImage: stageImage, stageFile: stageFile)
        close = ClosePaneStore(close: closePane)
        relay.store = self
    }

    /// Opens the first pipeline right away on the grid size this layout
    /// last had (#105): the attach starts when the detail is created, and
    /// the view's first size report becomes a resize if it differs. No-op
    /// without a remembered size, or once the pipeline has started.
    func startAtIntent() {
        guard lifecycleState == .active, isOnStage(),
            let size = gridSizes?.size(for: windowLayout()),
            terminal.status == .waitingForSize
        else { return }
        terminal.start(assumingCols: size.cols, rows: size.rows)
        unseenIntentPipeline = terminal.surfaceID
    }

    var terminalID: TerminalSurfaceID {
        terminal.surfaceID
    }

    /// What the screen should say about the terminal.
    ///
    /// A stopped terminal on a screen that has *not* left is one `rejoin()` is
    /// already replacing, so it reads as connecting: the alternative is a black
    /// surface with no overlay and nothing to say for itself. A screen that has
    /// left or is no longer the router's current detail keeps the real status —
    /// it is on its way off stage and must not flash a spinner on the way out.
    var terminalStatus: AttachTerminalStore.Status {
        guard lifecycleState == .active, isOnStage() else { return terminal.status }
        if terminalRecoveryOwner != nil {
            return .connecting
        }
        if terminal.status == .stopped {
            return .connecting
        }
        return terminal.status
    }

    var terminalFeed: TerminalByteFeed {
        terminal.feed
    }

    #if DEBUG
    func terminalDidBecomeVisible() {
        terminal.restorationTrace.emit(.agentDetailVisible, generation: terminal.transportGeneration)
    }

    func terminalSurfaceDidAttach() {
        terminal.restorationTrace.emit(.terminalSurfaceAttached, generation: terminal.transportGeneration)
    }
    #endif

    var attachLinks: [AttachLink] {
        linkIndex.links
    }

    /// Image and document paths this Attach's terminal printed, newest
    /// first, distinct, at most `AttachMediaIndex.maximumPathCount`, each
    /// exactly as printed: absolute, `~/…`, relative with a directory in it,
    /// or, for a Markdown or PDF document, a bare name; resolved against the
    /// Agent's directory only when fetched. An image counts how often the
    /// output stream printed it (`AttachMediaCandidate.sightings`); a
    /// document always counts one.
    var attachMediaCandidates: [AttachMediaCandidate] {
        mediaIndex.candidates
    }

    var pendingPaste: TerminalInputController.PasteReview? {
        input.pendingPaste
    }

    var canConfirmPaste: Bool {
        terminal.status == .live && input.canConfirmPaste
    }

    var pasteErrorMessage: String? {
        input.pasteErrorMessage
    }

    var closeFailureMessage: String? {
        guard case .failed(let message) = close.state else { return nil }
        return message
    }

    /// A size report from a screen that has left or moved off stage must not
    /// start anything: a departed view still lays out during its exit
    /// transition, before SwiftUI necessarily delivers `onDisappear`. An
    /// on-stage report is also what the next detail in this layout starts
    /// on (`startAtIntent()`).
    func viewDidResize(cols: Int, rows: Int) {
        guard lifecycleState == .active, isOnStage() else { return }
        gridSizes?.record(cols: cols, rows: rows, for: windowLayout())
        mediaIndex.gridColumns = cols
        terminal.viewDidResize(cols: cols, rows: rows)
    }

    /// A live mosh terminal whose Host has gone quiet (#105): the screen
    /// keeps its frame under the Reconnecting pill until the Host answers.
    var terminalIsStalled: Bool {
        guard lifecycleState == .active, isOnStage(), terminalRecoveryOwner == nil else {
            return false
        }
        return terminal.status == .live && terminal.isStalled
    }

    /// The terminal runs on mosh (#105): its session outlives the Host's
    /// SSH connection generation.
    var terminalRunsMosh: Bool {
        terminal.isRunningMosh
    }

    /// A live mosh session: what Background Grace expiry starts a standby
    /// for before it is torn down (#105).
    var terminalRunsLiveMosh: Bool {
        terminal.isRunningMosh && terminal.status == .live
    }

    /// The terminal's grid, once known.
    var terminalGridSize: (cols: Int, rows: Int)? {
        return terminal.gridSize
    }

    /// What settles a row break the screen alone cannot, for a tap as for
    /// the Attach Links list: the URLs the Agent's transcript and the
    /// stream hold whole.
    var knownLinkTargets: AttachKnownTargets {
        linkIndex.knownTargets
    }

    /// Ghostty's visible rows, one per line. The grid's column count lets
    /// both indices rejoin a URL or path a row break split.
    func viewportTextDidChange(_ text: String) {
        guard lifecycleState == .active else { return }
        lastViewportText = text
        let columns = terminalGridSize?.cols
        mediaIndex.gridColumns = columns
        linkIndex.receiveViewportText(text, columns: columns)
        mediaIndex.receiveViewportText(text, columns: columns)
    }

    /// Takes a read of the Agent's transcript (one the message-jump wiring
    /// already made): the URLs its turns hold whole settle the row breaks
    /// the screen alone cannot (a URL exactly as long as its row, cut or
    /// not), and the screen last read is read again with them. The turns
    /// are read off the main actor; a read that lands after the Attach
    /// left, or after a newer one, is dropped. A read that found no
    /// transcript changes nothing.
    func receiveTranscript(_ snapshot: ChatTranscriptSnapshot) {
        guard lifecycleState == .active, snapshot.header.status == .ok else { return }
        transcriptReading?.cancel()
        transcriptReadingGeneration &+= 1
        let generation = transcriptReadingGeneration
        transcriptReading = Task { [weak self] in
            let targets = await Task.detached(priority: .utility) {
                AttachKnownTargets.transcriptTargets(in: snapshot)
            }.value
            guard let self, !Task.isCancelled, self.lifecycleState == .active,
                  generation == self.transcriptReadingGeneration
            else { return }
            self.transcriptReading = nil
            self.linkIndex.receiveTranscriptTargets(
                targets, rereading: self.lastViewportText, columns: self.terminalGridSize?.cols)
        }
    }

    func openAttachLink(_ link: AttachLink, using open: @escaping AttachLinkOpener) {
        guard lifecycleState == .active else { return }
        attachLinkOpenFailure = nil
        invalidateAttachLinkOpen()
        let openID = attachLinkOpenID
        attachLinkOpenTask = Task { @MainActor [weak self] in
            let accepted = await open(link.url)
            guard
                let self,
                !Task.isCancelled,
                self.lifecycleState == .active,
                self.attachLinkOpenID == openID
            else {
                return
            }
            self.attachLinkOpenTask = nil
            guard !accepted else { return }
            self.attachLinkOpenFailure = AttachLinkOpenFailure(link: link)
        }
    }

    func copyFailedAttachLink(using copy: (String) -> Void) {
        guard let failure = attachLinkOpenFailure else { return }
        copy(failure.link.target)
        attachLinkOpenFailure = nil
    }

    func dismissAttachLinkOpenFailure() {
        attachLinkOpenFailure = nil
    }

    func send(_ keystrokes: Data) {
        terminal.send(keystrokes)
    }

    func sendEscapeKey() {
        _ = input.sendEscapeKey()
    }

    func scroll(_ sequence: Data, rows: Int) {
        input.scroll(sequence, rows: rows)
    }

    func requestPaste(_ text: String, bracketedPaste: Bool) {
        _ = input.requestPaste(text, bracketedPaste: bracketedPaste)
    }

    func insertSnippet(_ text: String, bracketedPaste: Bool) {
        _ = input.insertSnippet(text, bracketedPaste: bracketedPaste)
    }

    func cancelPaste() {
        input.cancelPaste()
    }

    func confirmPaste() {
        guard canConfirmPaste else { return }
        _ = input.confirmPaste()
    }

    func clearPasteError() {
        input.clearPasteError()
    }

    /// A short foreground bounce keeps the current PTY and asks it to repaint.
    /// Once the app may have suspended, replace the complete terminal pipeline
    /// immediately: PTY Attach, input session ownership, byte feed and surface
    /// identity. The surrounding Attach interaction remains the same owner, so
    /// links, staging state and a reviewed Paste survive the recovery.
    ///
    /// Two pipelines are not replaced (#105). One `startAtIntent()` began
    /// for this return has nothing stale in it; the recovery latch just
    /// follows it onto the new connection. A mosh session still running is
    /// asked first: kept when its server answers within
    /// `moshContactWindow`, replaced — without waiting on a shutdown
    /// acknowledgement — when it does not.
    func didBecomeActive(afterPossibleSuspension: Bool = false) {
        guard lifecycleState == .active, isOnStage() else { return }
        let intentPipeline = unseenIntentPipeline
        unseenIntentPipeline = nil
        guard !afterPossibleSuspension else {
            #if DEBUG
            if !activationRecovery.isActive {
                beginPendingForegroundRecoveryTrace()
            }
            #endif
            if activationRecovery.isActive {
                activationRecoveryOwnsOnStageLifecycle = true
                return
            }
            if terminalRecoveryOwner != nil {
                activationRecoveryOwnsOnStageLifecycle = true
                activationRecovery.begin(
                    projectedGeneration: transportGeneration)
                return
            }
            if intentPipeline == terminal.surfaceID {
                followIntentPipeline()
                return
            }
            if terminal.isRunningMosh {
                checkMoshBeforeReplacing()
                return
            }
            recoverAfterPossibleSuspension()
            return
        }
        terminal.didBecomeActive()
    }

    /// How long a returning mosh session gets to hear from its server
    /// before it is replaced (#105).
    static let moshContactWindow: Duration = .milliseconds(1500)

    private func recoverAfterPossibleSuspension() {
        input.detachSessionForReplacement()
        activationRecovery.begin(
            projectedGeneration: transportGeneration)
        replaceTerminal(ownsOnStageLifecycle: true, abandoningPredecessor: true) {
            [weak self] in
            guard let self else { return false }
            return self.lifecycleState == .active && self.isOnStage()
        }
    }

    /// The started-at-intent pipeline serves this return as a replacement
    /// would: bound to the recovery latch, so the connection it lands on
    /// and the one the Console projects are reconciled the same way.
    private func followIntentPipeline() {
        activationRecovery.begin(projectedGeneration: transportGeneration)
        activationRecovery.bind(to: terminal.surfaceID)
        #if DEBUG
        if let trace = pendingForegroundRecoveryTrace {
            terminal.adoptRestorationTrace(trace)
            pendingForegroundRecoveryTrace = nil
        }
        #endif
        if let acquired = terminal.acquiredTransportGeneration,
            let decision = activationRecovery.recordAcquisition(acquired, by: terminal.surfaceID)
        {
            applyActivationRecovery(decision)
        }
    }

    private func checkMoshBeforeReplacing() {
        let pipeline = terminal
        moshContactCheck?.cancel()
        moshContactCheck = Task { [weak self] in
            let heard = await pipeline.awaitServerContact(within: Self.moshContactWindow)
            guard !Task.isCancelled, let self, self.terminal === pipeline,
                self.lifecycleState == .active, self.isOnStage()
            else { return }
            self.moshContactCheck = nil
            if heard, pipeline.isRunningMosh {
                #if DEBUG
                self.abortPendingForegroundRecoveryTrace()
                #endif
                pipeline.didBecomeActive()
                return
            }
            // A session that failed meanwhile and is already reattaching
            // on its own (a lost link) needs no second replacement.
            guard self.terminalRecoveryOwner == nil, !self.activationRecovery.isActive,
                pipeline.isRunningMosh || pipeline.status != .connecting
            else { return }
            self.recoverAfterPossibleSuspension()
        }
    }

    /// A new Transport requires a new terminal pipeline. The replacement is
    /// serialized behind any earlier transition and starts only after the
    /// old terminal has finished. Staging deliberately survives: the
    /// stager resolves the live Transport per call, so a retryable or
    /// completed upload stays actionable across the reconnect. Two runs are
    /// not left behind by it (#105): a mosh session, whose UDP flow never
    /// rode the replaced SSH connection, and a run that holds no connection
    /// yet, which gets the newest one.
    func transportGenerationDidChange(_ generation: UInt64?) {
        guard let generation, lifecycleState == .active else { return }
        if let decision = activationRecovery.recordProjection(generation) {
            advanceTransportGeneration(to: generation)
            applyActivationRecovery(decision)
            return
        }
        if terminal.transportGeneration == generation {
            transportGeneration = generation
            return
        }
        guard generation != transportGeneration else { return }
        transportGeneration = generation
        guard !terminal.isRunningMosh, !terminal.isAwaitingTransport else { return }
        replaceTerminal(abandoningPredecessor: true) { [weak self] in
            guard let self else { return false }
            return self.lifecycleState == .active && self.transportGeneration == generation
        }
    }

    private func terminalTransportDidBecomeReady(
        pipelineID: TerminalSurfaceID,
        generation: UInt64
    ) {
        guard
            let decision = activationRecovery.recordAcquisition(
                generation, by: pipelineID)
        else { return }
        applyActivationRecovery(decision)
    }

    private func applyActivationRecovery(
        _ decision: TerminalRecoveryGenerationLatch.Decision
    ) {
        switch decision {
        case .pending:
            return
        case .acknowledge(let generation), .retain(let generation):
            advanceTransportGeneration(to: generation)
        case .replace(let generation):
            advanceTransportGeneration(to: generation)
            guard !terminal.isRunningMosh else { return }
            replaceTerminal(abandoningPredecessor: true) { [weak self] in
                guard let self else { return false }
                return self.lifecycleState == .active
                    && self.transportGeneration == generation
            }
        }
    }

    private func advanceTransportGeneration(to generation: UInt64) {
        guard transportGeneration.map({ generation > $0 }) ?? true else { return }
        transportGeneration = generation
    }

    /// Tears the terminal pipeline down and builds a fresh one, serialized
    /// behind any earlier transition. `isStillWanted` is re-asked when the
    /// queued operation starts and after teardown: the route can change both
    /// while this waits for an earlier transition and while `stop()` awaits.
    ///
    /// The new pipeline carries a new `TerminalSurfaceID`, which is what makes
    /// SwiftUI build a new terminal view rather than reuse the one on screen.
    private func replaceTerminal(
        ownsOnStageLifecycle: Bool = false,
        abandoningPredecessor: Bool = false,
        while isStillWanted: @escaping @MainActor () -> Bool
    ) {
        guard isStillWanted() else { return }
        // Synchronous on purpose. `previous.stop()` can wait on the SSH channel
        // teardown, and the user must see recovery throughout that wait rather
        // than the predecessor's `.live` status and an EmptyView overlay.
        let recoveryOwner = UUID()
        terminalRecoveryOwner = recoveryOwner
        activationRecoveryOwnsOnStageLifecycle =
            activationRecoveryOwnsOnStageLifecycle || ownsOnStageLifecycle
        enqueueLifecycleTransition { [weak self] in
            guard let self else { return }
            guard isStillWanted() else {
                if !self.isOnStage() {
                    self.abortTerminalRecoveryOffStage(ownedBy: recoveryOwner)
                } else {
                    self.finishTerminalRecovery(ownedBy: recoveryOwner)
                }
                return
            }
            let previous = self.terminal
            await previous.stop(preservingPendingPaste: true, abandoning: abandoningPredecessor)
            guard isStillWanted() else {
                if !self.isOnStage() {
                    self.abortTerminalRecoveryOffStage(ownedBy: recoveryOwner)
                } else {
                    self.finishTerminalRecovery(ownedBy: recoveryOwner)
                }
                return
            }
            #if DEBUG
            if !self.isOnStage(), self.pendingForegroundRecoveryTrace != nil {
                self.abortTerminalRecoveryOffStage(ownedBy: recoveryOwner)
                return
            }
            #endif
            guard self.terminalRecoveryOwner == recoveryOwner else { return }
            let replacement = Self.makeTerminal(
                target: self.target,
                input: self.input,
                recordsNetworkTelemetry: self.recordsNetworkTelemetry,
                transportGeneration: self.transportGeneration,
                runTerminal: self.runTerminal,
                linkIndex: self.linkIndex,
                mediaIndex: self.mediaIndex,
                transportReady: { [weak self] pipelineID, generation, _ in
                    self?.terminalTransportDidBecomeReady(
                        pipelineID: pipelineID, generation: generation)
                },
                runDidFinish: { [weak self] pipelineID in
                    self?.activationRecovery.clear(boundTo: pipelineID)
                },
                onMoshFailure: self.invalidateMosh)
            #if DEBUG
            self.publishReplacement(replacement)
            #else
            self.terminal = replacement
            #endif
            self.activationRecovery.bind(to: replacement.surfaceID)
            self.finishTerminalRecovery(ownedBy: recoveryOwner)
            if let size = self.gridSizes?.size(for: self.windowLayout()) {
                replacement.start(assumingCols: size.cols, rows: size.rows)
            }
        }
    }

    private func finishTerminalRecovery(ownedBy owner: UUID) {
        guard terminalRecoveryOwner == owner else { return }
        terminalRecoveryOwner = nil
        activationRecoveryOwnsOnStageLifecycle = false
    }

    #if DEBUG
    private func beginPendingForegroundRecoveryTrace() {
        guard pendingForegroundRecoveryTrace == nil else { return }
        let trace = AttachRestorationTrace()
        trace.emit(.foregroundRecoveryStarted, generation: transportGeneration)
        pendingForegroundRecoveryTrace = trace
    }

    private func publishReplacement(_ replacement: AttachTerminalStore) {
        if let trace = pendingForegroundRecoveryTrace {
            replacement.adoptRestorationTrace(trace)
            pendingForegroundRecoveryTrace = nil
        }
        terminal = replacement
    }

    private func abortPendingForegroundRecoveryTrace() {
        guard let trace = pendingForegroundRecoveryTrace else { return }
        trace.emit(.foregroundRecoveryAborted, generation: transportGeneration)
        pendingForegroundRecoveryTrace = nil
    }
    #endif

    func retryTerminal() {
        terminal.retry()
    }

    /// Whether the terminal has shown content this screen life: an ended
    /// attach then leaves it to read, and a cold failure has nothing.
    var terminalHasBeenLive: Bool {
        return terminal.hasBeenLive
    }

    /// Whether the current ended session failed on the mosh path: the
    /// connection dot's popover shows "Use SSH Instead" only then.
    var terminalEndedWithMoshFailure: Bool {
        if case .ended = terminalStatus, terminal.endedWithMoshFailure {
            return true
        }
        return false
    }

    /// The overlay's "Use SSH Instead": invalidates mosh for the Host, then
    /// reattaches — SSH takes over.
    func useSSHInstead() {
        terminal.retryOverSSH()
    }

    /// The host-level mosh capsule's tap: upgrades this screen's SSH session
    /// to mosh by restarting the terminal pipeline — the runner re-selects
    /// mosh now that the Host's probe proved it. An SSH attach still
    /// connecting restarts too; `connectingOnly` restarts only that one,
    /// for a probe landing while a cold-restored attach opens (#105). No-op
    /// for a session already on mosh or not running.
    func upgradeToMoshIfNeeded(connectingOnly: Bool = false) {
        // A shell's `terminal attach` always rides SSH (`MoshTransportChoice`);
        // restarting it would only reconnect over SSH again.
        guard case .agentPane = target,
            (terminal.runningFlavor ?? terminal.lastSessionFlavor) == .ssh,
            terminal.canUpgradeToMosh,
            !connectingOnly || terminal.status == .connecting
        else { return }
        terminal.upgradeToMosh()
    }

    func closeAgent() async -> Bool {
        await close.closePane()
        guard close.state == .closed else { return false }
        await leave().value
        return true
    }

    /// The Attach screen came back after `leave()` or an off-stage recovery
    /// abort.
    ///
    /// `leave()` rides `onDisappear`, which SwiftUI also fires for removals the
    /// user never made — and the state that comes back is the one that left. A
    /// torn-down store cannot serve it: its terminal is stopped for good, which
    /// draws as a black surface with no overlay, no error and no way back. A
    /// fresh terminal pipeline is exactly what an Agent switch would have
    /// built, so build one.
    ///
    /// Only the screen the Console still has on stage may rejoin. SwiftUI
    /// hands spurious appears to *departing* screens too (an Agent switch, a
    /// notification deep link), and a departed screen's view keeps laying out
    /// through the transition — a resurrected pipeline would attach unseen
    /// and hold the Host's only terminal channel, leaving the screen the user
    /// is actually looking at queued behind it on "Connecting…" forever.
    ///
    /// A retained Attach comes back still `.active`: its PTY never left, only
    /// its interactions did (`leaveInteractionsForRetention()`). That rejoin
    /// only resumes the Composer Tray, after the retention teardown.
    func rejoin() {
        guard lifecycleState != .active else {
            resumeTrayAfterRetention()
            return
        }
        guard isOnStage() else { return }
        activationRecovery.clear()
        let requiresFullReplacement = lifecycleState == .rejoinRequired
        lifecycleState = .active
        // A rejoin is the latest terminal transition even when it is queued
        // behind an in-flight recovery and the teardown leave enqueued after
        // it. Take presentation ownership synchronously so the recovery task
        // cannot expose its intermediate pipeline before this one lands.
        let recoveryOwner = UUID()
        terminalRecoveryOwner = recoveryOwner
        enqueueLifecycleTransition { [weak self] in
            guard let self else { return }
            guard self.lifecycleState == .active else {
                self.finishTerminalRecovery(ownedBy: recoveryOwner)
                return
            }
            guard self.isOnStage() else {
                self.abortTerminalRecoveryOffStage(ownedBy: recoveryOwner)
                return
            }
            // After the queued leave has finished. Resuming earlier would let
            // the Composer Tray start an upload while staging is still tearing down.
            self.composer.resumeTrayAfterRejoin(of: self.staging)
            if requiresFullReplacement, self.terminal.status != .stopped {
                await self.terminal.stop(preservingPendingPaste: true)
                guard self.terminalRecoveryOwner == recoveryOwner else { return }
                guard self.lifecycleState == .active else {
                    self.finishTerminalRecovery(ownedBy: recoveryOwner)
                    return
                }
                guard self.isOnStage() else {
                    self.abortTerminalRecoveryOffStage(ownedBy: recoveryOwner)
                    return
                }
            }
            guard self.terminal.status == .stopped else {
                #if DEBUG
                self.abortPendingForegroundRecoveryTrace()
                #endif
                self.finishTerminalRecovery(ownedBy: recoveryOwner)
                return
            }
            guard self.terminalRecoveryOwner == recoveryOwner else { return }
            let replacement = Self.makeTerminal(
                target: self.target,
                input: self.input,
                recordsNetworkTelemetry: self.recordsNetworkTelemetry,
                transportGeneration: self.transportGeneration,
                runTerminal: self.runTerminal,
                linkIndex: self.linkIndex,
                mediaIndex: self.mediaIndex,
                transportReady: { [weak self] pipelineID, generation, _ in
                    self?.terminalTransportDidBecomeReady(
                        pipelineID: pipelineID, generation: generation)
                },
                runDidFinish: { [weak self] pipelineID in
                    self?.activationRecovery.clear(boundTo: pipelineID)
                },
                onMoshFailure: self.invalidateMosh)
            #if DEBUG
            self.publishReplacement(replacement)
            #else
            self.terminal = replacement
            #endif
            self.activationRecovery.bind(to: replacement.surfaceID)
            self.finishTerminalRecovery(ownedBy: recoveryOwner)
        }
    }

    /// Queued behind any pending transition, so it lands after the retention
    /// teardown that suspended the tray. The tray ignores it unless this
    /// Attach's staging is the one bound, which is also why it needs no route
    /// check: a screen that is not showing this Attach has bound another.
    private func resumeTrayAfterRetention() {
        enqueueLifecycleTransition { [weak self] in
            guard let self, self.lifecycleState == .active else { return }
            self.composer.resumeTrayAfterRejoin(of: self.staging)
        }
    }

    /// A terminal transition that became invalid off stage never completed,
    /// whether it aborted before or after stopping its predecessor. Record
    /// that outcome so a later on-stage appearance can try again even if
    /// SwiftUI has not delivered the departing screen's delayed
    /// `onDisappear` yet. Only the transition that still owns recovery may
    /// change this state; a stale operation must not turn a newer on-stage
    /// transition back into a leave.
    private func abortTerminalRecoveryOffStage(ownedBy owner: UUID) {
        guard terminalRecoveryOwner == owner, lifecycleState == .active,
            !isOnStage()
        else { return }
        lifecycleState = .rejoinRequired
        #if DEBUG
        abortPendingForegroundRecoveryTrace()
        #endif
        activationRecovery.clear()
        finishTerminalRecovery(ownedBy: owner)
    }

    /// Cancels view-owned interaction while a retained PTY continues receiving
    /// output. Returning to this terminal keeps its feed and emulator intact;
    /// its `rejoin()` resumes the Composer Tray this suspends.
    @discardableResult
    func leaveInteractionsForRetention() -> Task<Void, Never> {
        invalidateAttachLinkOpen()
        attachLinkOpenFailure = nil
        input.cancelPaste()
        leavePaneHistory()
        return enqueueLifecycleTransition { [self] in
            composer.suspendTrayForTeardown(of: staging)
            await staging.leave()
        }
    }

    /// Leaves the screen: records the departure and enqueues the teardown,
    /// then returns the teardown for callers that must wait for it.
    ///
    /// Recording is synchronous on purpose. SwiftUI can hand out a spurious
    /// disappear/appear pair back-to-back in one transaction, and `rejoin()`
    /// can only undo a departure that is already visible when it runs — a
    /// leave deferred behind a Task hop runs *after* the rejoin has already
    /// no-opped, and strands a visible screen on a permanently stopped
    /// terminal: black, no overlay, no way back.
    @discardableResult
    func leave() -> Task<Void, Never> {
        leave(preservingOnStageActivationRecovery: true)
    }

    /// A deliberate local destination handoff is not SwiftUI navigation churn.
    /// It must tear down even while a foreground recovery owns the on-stage
    /// lifecycle, because the shell cannot take the Host terminal lease until
    /// this Attach has explicitly released it.
    @discardableResult
    func leaveForTerminalHandoff() -> Task<Void, Never> {
        leave(preservingOnStageActivationRecovery: false)
    }

    private func leave(
        preservingOnStageActivationRecovery: Bool
    ) -> Task<Void, Never> {
        guard lifecycleState != .left else {
            return lifecycleTask ?? Task {}
        }
        if preservingOnStageActivationRecovery,
            lifecycleState == .active,
            activationRecoveryOwnsOnStageLifecycle,
            terminalRecoveryOwner != nil,
            isOnStage()
        {
            return lifecycleTask ?? Task {}
        }
        #if DEBUG
        abortPendingForegroundRecoveryTrace()
        #endif
        lifecycleState = .left
        terminalRecoveryOwner = nil
        activationRecoveryOwnsOnStageLifecycle = false
        activationRecovery.clear()
        moshContactCheck?.cancel()
        moshContactCheck = nil
        unseenIntentPipeline = nil
        invalidateAttachLinkOpen()
        attachLinkOpenFailure = nil
        linkIndex.clear()
        mediaIndex.clear()
        lastViewportText = nil
        transcriptReading?.cancel()
        transcriptReading = nil
        input.cancelPaste()
        leavePaneHistory()
        // Strongly captured on purpose: the owner is `@State` on a view
        // SwiftUI discards right after `onDisappear`, so this task is often
        // the store's last holder. A weak capture silently skips the
        // teardown once the store deallocates — the live session then holds
        // the Host's terminal channel forever and every later attach queues
        // behind it on "Connecting…". The retain is temporary and
        // self-breaking: the task releases the store when the teardown ends.
        return enqueueLifecycleTransition { [self] in
            composer.suspendTrayForTeardown(of: staging)
            await staging.leave()
            await terminal.stop()
            linkIndex.clear()
            mediaIndex.clear()
        }
    }

    /// Copy mode is pane state the desk's tmux clients share: an Attach
    /// that leaves, or steps away into retention, takes the pane's view back
    /// to live output rather than leave it frozen where the phone scrolled.
    /// Copy mode a desk client entered stays (``TmuxPaneHistory/depart()``).
    private func leavePaneHistory() {
        guard let paneHistory else { return }
        Task { await paneHistory.depart() }
    }

    @discardableResult
    private func enqueueLifecycleTransition(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let previous = lifecycleTask
        lifecycleID &+= 1
        let id = lifecycleID
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        lifecycleTask = task
        Task { @MainActor [weak self] in
            await task.value
            guard self?.lifecycleID == id else { return }
            self?.lifecycleTask = nil
        }
        return task
    }

    private func invalidateAttachLinkOpen() {
        attachLinkOpenID &+= 1
        attachLinkOpenTask?.cancel()
        attachLinkOpenTask = nil
    }

    private static func makeTerminal(
        target: TerminalAttachTarget,
        input: TerminalInputController,
        recordsNetworkTelemetry: Bool,
        transportGeneration: UInt64?,
        runTerminal: @escaping TerminalSessionRunner,
        linkIndex: AttachLinkIndex,
        mediaIndex: AttachMediaIndex,
        transportReady: @escaping @MainActor @Sendable (TerminalSurfaceID, UInt64, TerminalSessionFlavor) -> Void = {
            _, _, _ in
        },
        runDidFinish: @escaping @MainActor @Sendable (TerminalSurfaceID) -> Void = { _ in },
        onMoshFailure: MoshInvalidation? = nil
    ) -> AttachTerminalStore {
        AttachTerminalStore(
            target: target,
            takeover: true,
            recordsNetworkTelemetry: recordsNetworkTelemetry,
            input: input,
            transportGeneration: transportGeneration,
            observeOutput: { data in
                linkIndex.receive(data)
                mediaIndex.receive(data)
            },
            finishOutput: {
                linkIndex.finishOutput()
                mediaIndex.finishOutput()
            },
            transportReady: transportReady,
            runDidFinish: runDidFinish,
            onMoshFailure: onMoshFailure,
            runTerminal: runTerminal)
    }
}

/// Lets the first pipeline, built before its store exists, report to it.
@MainActor
private final class PipelineReadinessRelay {
    weak var store: AgentAttachStore?
}
