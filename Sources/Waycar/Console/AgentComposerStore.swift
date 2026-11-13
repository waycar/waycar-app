import Foundation
import Observation

/// The Composer Tray's hooks around one Attach's teardown: suspend before
/// that Attach's `ComposerStagingStore.leave()`, resume once its rejoin has
/// followed. Both are scoped to `staging`: a call naming any instance other
/// than the one the tray is bound to is ignored, so a departing Attach cannot
/// stall the tray its successor drives.
@MainActor
protocol ComposerTrayLifecycle: AnyObject {
    func suspendTrayForTeardown(of staging: ComposerStagingStore)
    func resumeTrayAfterRejoin(of staging: ComposerStagingStore)
}

/// ConsoleStore's side of an Agent Composer's Queued Messages (CONTEXT.md
/// **Queued Message**): where they persist, which Agent the row is now, and
/// how an attachment is prepared on the device and later uploaded.
@MainActor
struct ComposerOutbox {
    typealias Prepare =
        @Sendable (ComposerStagingStore.Source, _ directory: URL) async throws
        -> QueuedMessage.Attachment
    typealias Upload =
        @Sendable (QueuedMessage.Attachment, _ fileURL: URL) async throws -> String

    let hostID: Host.ID
    let store: QueuedMessageStore
    /// The Agent the Console lists on the pane now; nil when none is listed.
    let identity: @MainActor () -> QueuedMessage.AgentIdentity?
    /// Whether queued work may go out now: the app is in the foreground.
    let mayDrain: @MainActor () -> Bool
    let prepare: Prepare
    let upload: Upload
    /// Waits out one retry backoff; tests replace it.
    let sleep: @Sendable (Duration) async throws -> Void
    /// The number of queued and held messages, for the row badge.
    let countDidChange: @MainActor (Int) -> Void
}

/// Owns a detail's local draft, its Composer Tray, and delivery state. Draft
/// edits do not touch Transport. Send delivers the draft with the tray's
/// ready Host paths appended. An Agent's Send delivers through one
/// `agent.prompt` RPC, except when Agent Status is Blocked: then it inserts
/// into the live Attach PTY (the Chat view, with no Attach, into the pane)
/// without Enter. A shell row's Send is one atomic `pane.send_input`
/// type-and-submit. With an outbox, an Agent's Send that cannot leave the
/// device becomes a Queued Message, sent on its own once the Host can take
/// it (CONTEXT.md **Queued Message**); so does a launch's first message for
/// a kind that takes none on its launch line (`queueLaunchMessage`).
@MainActor
@Observable
final class AgentComposerStore: ComposerTrayLifecycle {
    struct Message: Identifiable, Equatable {
        let id: UUID
        /// The delivered bytes: the typed draft with the sent tray items'
        /// Host paths appended (`prompt(text:paths:)`). Delivery, retry, the
        /// Chat echo, and Message jump all read it. A Queued Message's grows
        /// as its attachments upload.
        fileprivate(set) var text: String
        /// What the user typed; Edit Draft restores it.
        let draftText: String
        /// The ready Composer Tray items Send took; Edit Draft restores them.
        /// Released once the message is delivered: only a failed or waiting
        /// message can go back to the draft, and the items hold thumbnails.
        fileprivate(set) var trayItems: [ComposerTray.Item]
        /// When Send created it, on this device's clock. A retry keeps it.
        let sentAt: Date
        fileprivate var agentWasWorkingAtSend: Bool
        fileprivate var statusRevisionAtSend: UInt64
        fileprivate var observedWorkingAfterSend: Bool
        /// Attach-inserted Blocked drafts are acked by the PTY write. They
        /// do not claim Working/Done from later status pushes.
        fileprivate var tracksAgentProgress: Bool
        fileprivate(set) var state: DeliveryState
        /// Its on-device record while it is queued, held, or going out from
        /// the queue; nil for a message that never waited.
        fileprivate(set) var queued: QueuedMessage? = nil
        /// When it went out from the queue delivered, so the Composer can
        /// show it as sent for a moment before its row leaves.
        fileprivate(set) var leftQueueAt: Date? = nil
        /// The Agent on the pane when the user sent it, read before any
        /// await: a message that ends up queued is for this Agent.
        fileprivate(set) var agentAtSend: QueuedMessage.AgentIdentity? = nil
        /// A launch's first message (`queueLaunchMessage`): until then, a
        /// pane that lists no identified Agent is that launch still coming
        /// up, so the queue waits for it instead of holding the message.
        fileprivate var launchWaitEnds: ContinuousClock.Instant? = nil
        /// A launch's first message whose attachments are not in a record
        /// yet: their prepared copies, still in the launch's directory, for
        /// Retry to keep them again and Edit Draft to put them in the tray.
        fileprivate var launchCopies: LaunchCopies? = nil

        /// Cancel and Edit Draft apply: it waits, and its record is complete.
        var isWaiting: Bool {
            guard queued != nil else { return false }
            switch state {
            case .queued, .held: return true
            case .sending, .delivered, .failed: return false
            }
        }

        var isFailed: Bool {
            if case .failed = state { return true }
            return false
        }

        var isHeld: Bool {
            if case .held = state { return true }
            return false
        }

        /// A row of the queue: queued, held, or going out from the queue.
        var isQueueRow: Bool {
            switch state {
            case .queued, .held: true
            case .sending: queued != nil
            case .delivered, .failed: false
            }
        }

        /// Not delivered and not on its way: failed, queued or held. It stays
        /// on screen until it goes out or the user withdraws it.
        var isUnsent: Bool {
            switch state {
            case .failed, .queued, .held: return true
            case .sending, .delivered: return false
            }
        }
    }

    /// A launch's prepared attachments and the directory holding them.
    struct LaunchCopies: Equatable {
        let attachments: [QueuedMessage.Attachment]
        let directory: URL?

        /// The copy of `attachment`, while it is still on the device.
        func fileURL(of attachment: QueuedMessage.Attachment) -> URL? {
            guard let directory, let name = attachment.localFileName else { return nil }
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    enum DeliveryState: Equatable {
        case sending
        case delivered(AgentProgress)
        case failed(String)
        /// Waiting on this device until its Host can take it (CONTEXT.md
        /// **Queued Message**).
        case queued
        /// Kept back from sending: the Agent it was queued for changed or
        /// left. Only the user sends, edits or deletes it.
        case held(String)
    }

    enum AgentProgress: Equatable {
        case acknowledged
        case agentBusy
        case working
        case done
    }

    /// How Send finished. `.deliveredViaAttach` is the view's cue to present
    /// the tools keyboard so the user can Enter or Esc themselves.
    /// `.queued` kept the message on the device until its Host can take it.
    enum SendResult: Equatable {
        case ignored
        case deliveredViaPrompt
        case deliveredViaAttach
        case deliveredViaPaneInput
        case failed
        case queued
    }

    /// Where Send delivers. `agent.prompt` refuses a plain shell, so a shell
    /// row types through `pane.send_input` instead. Agent-only behavior —
    /// status progress, the registration-window retry, the Blocked Attach
    /// insert — has no shell meaning and never runs for `.paneInput`.
    private enum Delivery {
        case agentPrompt(@Sendable (AgentPromptParams) async throws -> Agent)
        case paneInput(@Sendable (PaneSendInputParams) async throws -> Void)
    }

    private(set) var messages: [Message] = []
    private(set) var draft = ""
    /// UTF-16 caret/selection, matching the Composer text view.
    private(set) var draftSelection = NSRange(location: 0, length: 0)
    /// The draft's images and files. Lives as long as the draft.
    let tray = ComposerTray()

    private let target: String
    private var agentStatus: AgentStatus
    private var statusRevision: UInt64 = 0
    private let statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>?
    /// Pace and budget for waiting out a fresh Agent's launch on
    /// `agent_not_ready`; the defaults mirror the transport's
    /// shell-readiness wait (`startAgentAwaitingShell`). Tests inject
    /// smaller values so the wait itself stays under test.
    private let agentNotReadyRetryDelay: Duration
    private let agentNotReadyRetryBudget: Duration
    private let delivery: Delivery
    /// The Transport's sign-in and folder-trust screen check
    /// (`Transport.checkAgentInputScreen`), asked before a Blocked send
    /// types into the Attach: tmux and herdr read some of those screens
    /// as Blocked, and typed text would answer them. Nil skips it.
    private let checkInputScreen: (@Sendable (String) async throws -> Void)?
    @ObservationIgnored private var hasOpened = false
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// The detail screen's live Attach writer. Weak: Composer outlives any
    /// one Attach pipeline (reconnect replacement), and a dead writer must
    /// fail the Blocked path rather than retain a stale session.
    @ObservationIgnored private weak var attachInput: TerminalInputController?
    /// The Chat view's Blocked path: inserts text into the Agent's pane
    /// without Enter (`pane.send_input`), for a detail with no Attach open.
    /// A bound Attach input always wins.
    @ObservationIgnored private var blockedInsert: (@MainActor (String) async throws -> Void)?
    /// Queued Messages' persistence and Host hooks; nil never queues, so a
    /// send that cannot leave the device fails as before.
    @ObservationIgnored private let outbox: ComposerOutbox?
    /// Holds a pending launch, or its just-started pane until the older
    /// messages arrive. Send stays local and the queue never drains while held.
    var holdingForLaunch: QueuedMessage.AgentIdentity? {
        didSet {
            guard holdingForLaunch == nil, let staging = deferredStaging else { return }
            deferredStaging = nil
            tray.bind(staging)
        }
    }
    @ObservationIgnored private weak var deferredStaging: ComposerStagingStore?
    /// A pending launch has begun: no new Send may race its handover.
    private(set) var isLaunchStarting = false
    /// Whether the Agent's Host has verified rows on a live connection.
    /// ConsoleStore keeps it current; while it is false, Send may queue a
    /// tray whose items cannot upload yet.
    private(set) var isHostReachable = true
    private var drain = ComposerDrainMachine()
    @ObservationIgnored private var drainTasks: [UInt64: Task<Void, Never>] = [:]
    @ObservationIgnored private var retryTasks: [UInt64: Task<Void, Never>] = [:]
    /// Set once the composer's Host left the catalog or changed target:
    /// nothing of its queue goes out or touches the disk again.
    private var isQueueCancelled: Bool { drain.isCancelled }
    /// Review Prompt hooks, set by `ConsoleStore` on an Agent's Composer
    /// (never a shell's): a message the Host accepted, and a message's turn
    /// reaching Done. Neither touches quota or entitlement.
    @ObservationIgnored var onAgentMessageDelivered: (@MainActor () -> Void)?
    @ObservationIgnored var onAgentTurnDone: (@MainActor () -> Void)?

    init(
        target: String,
        initialStatus: AgentStatus = .idle,
        statusUpdates: AsyncStream<ConsoleStore.AgentStatusUpdate>? = nil,
        agentNotReadyRetryDelay: Duration = AgentComposerStore.defaultAgentNotReadyRetryDelay,
        agentNotReadyRetryBudget: Duration = AgentComposerStore.defaultAgentNotReadyRetryBudget,
        outbox: ComposerOutbox? = nil,
        holdingForLaunch: QueuedMessage.AgentIdentity? = nil,
        checkInputScreen: (@Sendable (String) async throws -> Void)? = nil,
        prompt: @escaping @Sendable (AgentPromptParams) async throws -> Agent
    ) {
        self.target = target
        agentStatus = initialStatus
        self.statusUpdates = statusUpdates
        self.agentNotReadyRetryDelay = agentNotReadyRetryDelay
        self.agentNotReadyRetryBudget = agentNotReadyRetryBudget
        self.outbox = outbox
        self.holdingForLaunch = holdingForLaunch
        isHostReachable = holdingForLaunch == nil
        self.checkInputScreen = checkInputScreen
        delivery = .agentPrompt(prompt)
    }

    /// A shell row's Composer. There is no Agent Status to follow and no
    /// Agent launch to wait out: Send is one `pane.send_input` carrying the
    /// draft and Enter, which the shell executes. The tray stages through
    /// the detail's Attach exactly as it does for an Agent, but a shell
    /// takes each completed path into the draft at the caret.
    init(
        shellPaneID: String,
        sendInput: @escaping @Sendable (PaneSendInputParams) async throws -> Void
    ) {
        target = shellPaneID
        agentStatus = .shellTerminal
        statusUpdates = nil
        agentNotReadyRetryDelay = Self.defaultAgentNotReadyRetryDelay
        agentNotReadyRetryBudget = Self.defaultAgentNotReadyRetryBudget
        delivery = .paneInput(sendInput)
        checkInputScreen = nil
        outbox = nil
        holdingForLaunch = nil
        tray.completedPathSink = { [weak self] path in self?.insertIntoDraft(path) }
    }

    /// Whether Send prompts an Agent (`agent.prompt`) rather than typing into
    /// a shell (`pane.send_input`). The Composer's copy and input traits
    /// follow it: an Agent takes natural language, a shell takes commands.
    var deliversToAgent: Bool {
        if case .agentPrompt = delivery { return true }
        return false
    }

    /// The shell-readiness wait in `WaycarSSHTransport.startAgentAwaitingShell`
    /// retries `agent.start`'s `agent_pane_busy`, which herdr returns while a
    /// fresh pane's shell rc is still running: 0.7.5 did, 0.8.0 did not open
    /// that window, and 0.9.1 does again. The later gate — `agent.start`
    /// answered while herdr's launch is still pending — surfaces on
    /// `agent.prompt`, so the composer carries its own budget here. herdr
    /// 0.9.1 promotes a pending launch only on a reconcile (`agent.get` or a
    /// status change) from 3 s after the start (#17). The Transport's
    /// post-start settle (`WaycarSSHTransport.scheduleLaunchSettle`) sends
    /// that `agent.get` for launches Waycar started; this budget is still
    /// load-bearing, since it carries a first Send made before the settle
    /// promotes the launch. An opencode input gate stretches it to the gate
    /// (`AgentInputNotReadyError`, `promptWaitingOutLaunch`).
    private static let defaultAgentNotReadyRetryDelay: Duration = .milliseconds(500)
    private static let defaultAgentNotReadyRetryBudget: Duration = .seconds(45)

    deinit {
        statusTask?.cancel()
        for task in drainTasks.values { task.cancel() }
        for task in retryTasks.values { task.cancel() }
    }

    /// Stops the queue for good: the composer's Host was removed or now
    /// points at another machine. A drain in flight writes nothing more.
    func cancelQueue() {
        sendDrain(.cancel)
    }

    /// Send needs typed text or a tray item to deliver, and no tray item
    /// still queued, staging, or failed. Images alone may be sent. With the
    /// Host offline, items that are waiting or failed for want of it do not
    /// hold Send: the message queues with them (`canQueueTray`).
    var canSend: Bool {
        guard !isQueueCancelled, !isLaunchStarting, !isWaitingOnTray else { return false }
        return draft.contains(where: { !$0.isWhitespace }) || tray.hasReadyItems
            || canQueueTray
    }

    var isWaitingOnTray: Bool {
        tray.blocksSend && !canQueueTray
    }

    /// Send would queue the tray as it is: the Host is offline, so its
    /// unready items wait in the Queued Message and upload on reconnect.
    var canQueueTray: Bool {
        outbox != nil && (holdingForLaunch != nil || !isHostReachable) && tray.canQueueUnreadyItems
    }

    /// VoiceOver hint for the Send button. A waiting tray disables Send.
    var sendAccessibilityHint: String {
        if isWaitingOnTray, let hint = tray.sendHint { return hint }
        if canQueueTray { return "Queues the message and sends it when the Host reconnects" }
        return deliversToAgent
            ? "Delivers the complete draft to the Agent"
            : "Runs the complete draft in the terminal"
    }

    /// The delivered text: `text` with the ready Host `paths` appended,
    /// space-separated. Paths alone end in a space, as an inserted path did.
    nonisolated static func prompt(text: String, paths: [String]) -> String {
        guard !paths.isEmpty else { return text }
        let joined = paths.joined(separator: " ")
        guard text.contains(where: { !$0.isWhitespace }) else { return joined + " " }
        return text + (text.last?.isWhitespace == true ? "" : " ") + joined
    }

    /// Inserts at the current caret, or replaces the current selection. This
    /// is the Snippet / Skill / shell staged-path insertion path: the draft
    /// changes and nothing is submitted.
    func insertIntoDraft(_ text: String) {
        let range = Self.clamped(draftSelection, to: draft)
        draft = (draft as NSString).replacingCharacters(in: range, with: text)
        draftSelection = NSRange(
            location: range.location + (text as NSString).length,
            length: 0)
    }

    func setDraftSelection(_ range: NSRange) {
        let clamped = Self.clamped(range, to: draft)
        guard draftSelection != clamped else { return }
        draftSelection = clamped
    }

    /// Typing and selection changes from the Composer and Chat Mode text
    /// views. This keeps the view's caret.
    func applyEditorDraft(_ text: String, selection: NSRange) {
        let clamped = Self.clamped(selection, to: text)
        guard draft != text || draftSelection != clamped else { return }
        draft = text
        draftSelection = clamped
    }

    /// Binds the presented Attach's staging to the Composer Tray, which
    /// drives it one item at a time. The detail view calls this whenever the
    /// Attach on screen changes, so the tray follows that Attach.
    func bindStaging(_ staging: ComposerStagingStore) {
        guard holdingForLaunch == nil else {
            deferredStaging = staging
            return
        }
        deferredStaging = nil
        tray.bind(staging)
    }

    /// Maps a drop or paste onto the draft and the Composer Tray. Text
    /// inserts at the caret; images and files join the tray in order, as
    /// many as it has room for, and the tray's `notice` names any it left
    /// out. Empty and unsupported items are skipped; nothing is submitted.
    func acceptDrop(_ items: [ComposerDropItem]) {
        var sources: [ComposerStagingStore.Source] = []
        for item in items {
            switch item {
            case .text(let text):
                guard !text.isEmpty else { continue }
                insertIntoDraft(text)
            case .image(let data, _):
                guard !data.isEmpty else { continue }
                sources.append(.photo(DataImageSelection(data: data)))
            case .file(let url):
                sources.append(.file(url))
            case .unsupported:
                continue
            }
        }
        let taken = tray.add(sources)
        sources.dropFirst(taken).forEach(ComposerTray.discardLocalCopy)
    }

    /// `staging`'s Attach is tearing down: the tray starts no new upload
    /// until that Attach rejoins. Ignored unless the tray is bound to it.
    func suspendTrayForTeardown(of staging: ComposerStagingStore) {
        if deferredStaging === staging { deferredStaging = nil }
        tray.suspendForTeardown(of: staging)
    }

    /// Called after `staging`'s serial leave has finished and its Attach
    /// rejoined. Ignored unless the tray is bound to it.
    func resumeTrayAfterRejoin(of staging: ComposerStagingStore) {
        tray.resumeAfterRejoin(of: staging)
    }

    /// Completes an inline Skill suggestion: swaps the typed trigger token at
    /// the end of the draft for the full invocation. A draft that no longer
    /// ends with the token — edited under a stale suggestion — is left alone
    /// rather than mangled.
    func replaceTrailingToken(_ token: String, with text: String) {
        guard !token.isEmpty, draft.hasSuffix(token) else { return }
        draft.removeLast(token.count)
        draft.append(text)
        draftSelection = NSRange(location: (draft as NSString).length, length: 0)
    }

    /// Starts consuming Console's existing per-Agent status fan-out. This
    /// does not open a Transport event stream or perform an RPC.
    func open() {
        guard !hasOpened else { return }
        hasOpened = true
        guard let statusUpdates else { return }
        statusTask = Task { [weak self] in
            for await update in statusUpdates {
                guard !Task.isCancelled, let self else { return }
                if let status = update.status {
                    self.agentStatusDidChange(status)
                }
            }
        }
    }

    /// The already-open Attach PTY writer owned by Agent detail. Blocked
    /// Send uses the same pipe as the tools keyboard.
    func bindAttachInput(_ input: TerminalInputController?) {
        attachInput = input
    }

    /// Binds the Blocked insert used when no Attach input is bound; nil
    /// unbinds it.
    func bindBlockedInsert(_ insert: (@MainActor (String) async throws -> Void)?) {
        blockedInsert = insert
    }

    /// Delivers the typed draft with the tray's ready Host paths appended,
    /// then clears both. With the Host offline and items that could not
    /// upload, the whole tray goes into a Queued Message instead, its
    /// unready items copied onto the device to upload on reconnect.
    @discardableResult
    func send() async -> SendResult {
        guard canSend else { return .ignored }
        let typed = draft
        if canQueueTray {
            let taken = tray.takeItemsForQueue()
            draft = ""
            draftSelection = NSRange(location: 0, length: 0)
            return await queueWithUnreadyItems(typed: typed, taken: taken)
        }
        let paths = tray.readyPaths
        let trayItems = tray.takeReadyItems()
        draft = ""
        draftSelection = NSRange(location: 0, length: 0)
        return await submit(
            Self.prompt(text: typed, paths: paths), draftText: typed, trayItems: trayItems)
    }

    /// Sends `text` as its own message, exactly as Send delivers a draft,
    /// while leaving the draft and the tray alone. The Direct Input
    /// microphone uses it: what was said goes to the Agent without them.
    @discardableResult
    func send(_ text: String) async -> SendResult {
        guard !isQueueCancelled, !isLaunchStarting,
            text.contains(where: { !$0.isWhitespace })
        else { return .ignored }
        return await submit(text, draftText: text, trayItems: [])
    }

    /// Queues a fresh launch's first message for a kind that takes none on
    /// its launch line (`LaunchPromptStager.firstMessageArguments`): a
    /// Queued Message for `agent`, the Agent that launch started. It goes
    /// out on its own like any other, once the Host can take it and the
    /// Agent takes input (`promptWaitingOutLaunch`), never while the Agent is
    /// Blocked and never typed into its Attach, and ahead of anything the
    /// user sends meanwhile. For `agentNotReadyRetryBudget` from now, a pane
    /// that lists no identified Agent yet is waited out instead of holding
    /// the message. The New Agent sheet's own first message comes here too,
    /// for any kind, with `attachments` prepared on the device and not yet
    /// uploaded: their copies are read from `directory` into the message's
    /// own, and upload before its prompt like any Queued Message's. One
    /// that cannot be kept on the device fails, `.failed`, and its Retry and
    /// Edit Draft read the attachments from `directory` again, so the
    /// caller leaves them there.
    @discardableResult
    func queueLaunchMessage(
        _ text: String, for agent: QueuedMessage.AgentIdentity,
        attachments: [QueuedMessage.Attachment] = [], from directory: URL? = nil,
        id: UUID = UUID(), createdAt: Date = Date()
    ) -> SendResult {
        guard outbox != nil, text.contains(where: { !$0.isWhitespace }) || !attachments.isEmpty
        else { return .ignored }
        if messages.contains(where: { $0.id == id && $0.queued != nil }) { return .queued }
        messages.removeAll { $0.id == id }
        let message = Message(
            id: id, text: text, draftText: text, trayItems: [], sentAt: createdAt,
            agentWasWorkingAtSend: false,
            statusRevisionAtSend: statusRevision,
            observedWorkingAfterSend: false,
            tracksAgentProgress: true,
            state: .sending,
            agentAtSend: agent,
            launchWaitEnds: ContinuousClock.now + agentNotReadyRetryBudget)
        messages.append(message)
        messages.sort { $0.sentAt < $1.sentAt }
        return enqueue(
            message.id, afterFailure: false, copying: attachments, from: directory)
    }

    /// Queued Messages go out in the order they were sent, so a new message
    /// waits behind any still queued instead of overtaking them.
    private func submit(
        _ text: String, draftText: String, trayItems: [ComposerTray.Item]
    ) async -> SendResult {
        let message = Message(
            id: UUID(), text: text, draftText: draftText, trayItems: trayItems,
            sentAt: Date(),
            agentWasWorkingAtSend: agentStatus == .working,
            statusRevisionAtSend: statusRevision,
            observedWorkingAfterSend: false,
            tracksAgentProgress: deliversToAgent,
            state: .sending,
            agentAtSend: identityAtSend())
        messages.append(message)
        if holdingForLaunch != nil || hasQueueAhead(of: message.id) {
            return enqueue(message.id, afterFailure: false)
        }
        return await deliver(message.id)
    }

    /// A failed message from the queue whose attachments did not all upload
    /// goes back to the queue; any other is resent in place, behind the
    /// queue when one is waiting.
    @discardableResult
    func retry(_ id: Message.ID) async -> SendResult {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return .ignored }
        guard case .failed = messages[index].state else { return .ignored }
        if var record = messages[index].queued {
            // A cancelled queue no longer drains; nothing goes back into it.
            guard !isQueueCancelled else { return .ignored }
            record.failureMessage = nil
            do {
                try outbox?.store.save(record)
            } catch {
                messages[index].state = .failed(Self.queueSaveFailedMessage)
                return .failed
            }
            messages[index].queued = record
            messages[index].state = .queued
            noteQueueChange()
            drainQueue()
            return .queued
        }
        if let copies = messages[index].launchCopies {
            // A launch's first message that could not be kept tries again.
            guard !isQueueCancelled else { return .ignored }
            return enqueue(
                id, afterFailure: false, copying: copies.attachments, from: copies.directory)
        }
        messages[index].agentWasWorkingAtSend = agentStatus == .working
        messages[index].statusRevisionAtSend = statusRevision
        messages[index].observedWorkingAfterSend = false
        messages[index].tracksAgentProgress = deliversToAgent
        messages[index].state = .sending
        messages[index].agentAtSend = identityAtSend()
        if holdingForLaunch != nil || hasQueueAhead(of: id) {
            return enqueue(id, afterFailure: false)
        }
        return await deliver(id)
    }

    /// Removes a failed or waiting message and restores what it was made of:
    /// its typed text to the draft and its items to the Composer Tray, ready
    /// ones in front, ones that never uploaded from their copies on the
    /// device. If the user has already started another draft, both texts are
    /// kept in order. The caret shifts past the restored text, so with an
    /// empty draft it lands at the end of the restored message.
    func withdrawToDraft(_ id: Message.ID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let message = messages[index]
        guard message.isWaiting || message.isFailed else { return }
        messages.remove(at: index)
        tray.restore(message.trayItems)
        if let copies = message.launchCopies {
            tray.add(Self.unsentSources(of: copies.attachments, at: copies.fileURL), restoring: true)
        }
        if let record = message.queued, let outbox {
            tray.add(
                Self.unsentSources(of: record.attachments) {
                    outbox.store.fileURL(of: $0, in: record)
                }, restoring: true)
            outbox.store.remove(record)
            noteQueueChange()
        }
        let text = message.draftText
        guard !text.isEmpty else { return }
        let restored = draft.isEmpty ? text : "\(text)\n"
        draft = restored + draft
        draftSelection = NSRange(
            location: draftSelection.location + (restored as NSString).length,
            length: draftSelection.length)
    }

    func agentStatusDidChange(_ status: AgentStatus) {
        guard agentStatus != status else { return }
        let wasBlocked = agentStatus == .blocked
        agentStatus = status
        statusRevision &+= 1
        // A queue that stopped at the Agent's question goes on once it is answered.
        if wasBlocked { drainQueue(resettingBackoff: false) }
        for index in messages.indices {
            guard messages[index].tracksAgentProgress else { continue }
            if status == .working,
                messages[index].statusRevisionAtSend != statusRevision
            {
                messages[index].observedWorkingAfterSend = true
            }
            guard case .delivered(let progress) = messages[index].state else { continue }
            switch status {
            case .working
                where progress != .done && messages[index].observedWorkingAfterSend:
                messages[index].state = .delivered(.working)
            case .done
                where messages[index].observedWorkingAfterSend
                    || !messages[index].agentWasWorkingAtSend:
                messages[index].state = .delivered(.done)
            case .idle where messages[index].observedWorkingAfterSend:
                messages[index].state = .delivered(.done)
            default:
                break
            }
            if progress != .done, case .delivered(.done) = messages[index].state {
                onAgentTurnDone?()
            }
        }
    }

    // MARK: Queued Messages

    /// First retry wait after a pre-delivery failure; it doubles per failure
    /// up to the scheduler's cap. A reconnect starts over at once.
    static func queueRetryDelay(afterFailures failures: Int) -> Duration {
        ComposerDrainMachine.retryDelay(afterFailures: failures)
    }

    /// Queued and held messages: the row badge's count.
    var waitingCount: Int {
        messages.count(where: { $0.state == .queued || $0.isHeld })
    }

    /// ConsoleStore's word on the Agent's Host. While it is unreachable,
    /// Send may queue a tray whose items cannot upload yet.
    func setHostReachable(_ reachable: Bool) {
        guard isHostReachable != reachable else { return }
        isHostReachable = reachable
    }

    /// Puts Queued Messages read from the device back into this Composer, in
    /// the order they were sent. Ones it already holds are left alone. One
    /// whose prompt was going out when the app ended may have been
    /// delivered, so it comes back failed, for a deliberate Retry.
    func restoreQueued(_ records: [QueuedMessage], awaitingLaunch: Bool = false) {
        if awaitingLaunch {
            let ids = Set(records.map(\.id))
            for index in messages.indices
            where ids.contains(messages[index].id) && messages[index].state == .queued {
                messages[index].agentAtSend = messages[index].queued?.agent
                messages[index].launchWaitEnds = ContinuousClock.now + agentNotReadyRetryBudget
            }
        }
        let known = Set(messages.map(\.id))
        let restored = records
            .filter { !known.contains($0.id) }
            .sorted { $0.createdAt < $1.createdAt }
        guard !restored.isEmpty else { return }
        for record in restored {
            let interrupted = record.promptStartedAt != nil
            if interrupted { outbox?.store.remove(record) }
            messages.append(
                Message(
                    id: record.id, text: record.prompt, draftText: record.draftText,
                    trayItems: Self.trayItems(for: record, keeping: []),
                    sentAt: record.createdAt,
                    agentWasWorkingAtSend: false,
                    statusRevisionAtSend: statusRevision,
                    observedWorkingAfterSend: false,
                    tracksAgentProgress: deliversToAgent,
                    state: interrupted
                        ? .failed(Self.interruptedMessage)
                        : record.failureMessage.map { .failed($0) } ?? .queued,
                    queued: interrupted ? nil : record,
                    agentAtSend: awaitingLaunch ? record.agent : nil,
                    launchWaitEnds: awaitingLaunch
                        ? ContinuousClock.now + agentNotReadyRetryBudget : nil))
        }
        messages.sort { $0.sentAt < $1.sentAt }
        noteQueueChange()
    }

    /// Sends the queued messages, oldest first and one at a time, without a
    /// tap. ConsoleStore calls it when the Agent's Host connects and when
    /// the app returns; `resettingBackoff` drops a pending retry wait and
    /// goes at once, and makes a drain already running go on rather than
    /// back off if its current attempt fails.
    func drainQueue(resettingBackoff: Bool = true) {
        guard holdingForLaunch == nil, outbox != nil else { return }
        sendDrain(.wake(resetBackoff: resettingBackoff, hasQueuedRecord: hasDrainableRecord))
    }

    func setLaunchStarting(_ starting: Bool) {
        isLaunchStarting = starting
    }

    /// Records already moved to the real pane no longer belong to the
    /// pending Composer. This drops only its local rows, never the records.
    func forgetHandedOverMessages(_ ids: Set<Message.ID>) {
        messages.removeAll { ids.contains($0.id) }
        noteQueueChange()
    }

    /// Handover preserves an unsent draft as a draft, including sources
    /// that failed preparation. Taking the tray transfers ownership of its
    /// local copies instead of removing (and deleting) them.
    func moveDraft(to composer: AgentComposerStore) {
        if !draft.isEmpty {
            let text = composer.draft.isEmpty ? draft : composer.draft + "\n" + draft
            composer.applyEditorDraft(
                text, selection: NSRange(location: (text as NSString).length, length: 0))
            applyEditorDraft("", selection: NSRange(location: 0, length: 0))
        }
        let taken = tray.takeItemsForQueue()
        composer.tray.restore(taken.compactMap {
            if case .ready(let item) = $0 { return item }
            return nil
        })
        composer.tray.add(taken.compactMap {
            if case .unready(_, let source) = $0 { return source }
            return nil
        }, restoring: true)
    }

    /// A replay must not strand a Send still copying its tray locally.
    /// The record becomes visible only after preparation completes; keep
    /// the pending Composer alive until then, or its drain is cancelled.
    func waitForQueuePreparation() async throws {
        while messages.contains(where: { $0.state == .queued && $0.queued == nil }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
    }

    /// Cancel: drops a waiting message and its copies on the device. Files
    /// it already uploaded stay on the Host (ADR 0005).
    func deleteQueued(_ id: Message.ID) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
            messages[index].isWaiting, let record = messages[index].queued
        else { return }
        messages.remove(at: index)
        outbox?.store.remove(record)
        noteQueueChange()
    }

    /// Whether Send Anyway has an Agent to send a held message to.
    var canSendHeldAnyway: Bool {
        outbox?.identity() != nil
    }

    /// Send Anyway: a held message is queued again for the Agent now on its
    /// pane, and goes out at once.
    func sendAnyway(_ id: Message.ID) {
        guard !isQueueCancelled, let outbox, let index = messages.firstIndex(where: { $0.id == id }),
            messages[index].isHeld, var record = messages[index].queued,
            let current = outbox.identity()
        else { return }
        record.agent = current
        try? outbox.store.save(record)
        messages[index].queued = record
        messages[index].state = .queued
        noteQueueChange()
        drainQueue()
    }

    private typealias DrainStep = ComposerDrainMachine.Outcome

    private var hasDrainableRecord: Bool {
        messages.contains { $0.state == .queued && $0.queued != nil }
    }

    private func runDrain(_ token: UInt64) async {
        guard holdingForLaunch == nil, let outbox else {
            sendDrain(.ended(token, clearFailures: false))
            return
        }
        while holdingForLaunch == nil, !drainStopped, outbox.mayDrain() {
            sendDrain(.iterationStarted(token))
            guard let next = messages.filter({ $0.state == .queued })
                .min(by: { $0.sentAt < $1.sentAt })
            else {
                sendDrain(.ended(token, clearFailures: true))
                return
            }
            // Still copying its attachments: it drains once they are saved.
            guard next.queued != nil else {
                sendDrain(.ended(token, clearFailures: false))
                return
            }
            let outcome = await drainOne(next.id, outbox: outbox)
            let effects = drain.handle(.attemptFinished(token, outcome, launchDelay: agentNotReadyRetryDelay))
            performDrain(effects)
            guard effects.contains(.continueDrain(token)) else { return }
        }
        sendDrain(.ended(token, clearFailures: false))
    }

    private func sendDrain(_ event: ComposerDrainMachine.Event) {
        performDrain(drain.handle(event))
    }

    private func performDrain(_ effects: [ComposerDrainMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .start(let token):
                drainTasks[token] = Task { [weak self] in await self?.runDrain(token) }
            case .finish(let token): drainTasks[token] = nil
            case .cancelDrain(let token):
                drainTasks.removeValue(forKey: token)?.cancel()
            case .cancelRetry(let token):
                retryTasks.removeValue(forKey: token)?.cancel()
            case .continueDrain: break
            case .armRetry(let token, let delay):
                guard let outbox else { continue }
                retryTasks[token] = Task { [weak self] in
                    do { try await outbox.sleep(delay) } catch { return }
                    guard !Task.isCancelled, let self else { return }
                    self.sendDrain(.timerElapsed(token,
                        mayWake: self.holdingForLaunch == nil,
                        hasQueuedRecord: self.hasDrainableRecord))
                }
            }
        }
    }

    /// One queued message: the Agent must still be the one it was queued for,
    /// its attachments upload first, then one `agent.prompt` (waiting out a
    /// fresh launch as Send does). A failure that left nothing on the Host
    /// puts it back in the queue; one after the prompt was written may have
    /// delivered it, so it fails for a deliberate Retry.
    private func drainOne(_ id: Message.ID, outbox: ComposerOutbox) async -> DrainStep {
        guard let index = messages.firstIndex(where: { $0.id == id }),
            var record = messages[index].queued,
            case .agentPrompt(let prompt) = delivery
        else { return .settled }
        if drainStopped { return .settled }
        // herdr would refuse it, and typing into a question is the user's call.
        guard agentStatus != .blocked else { return .waitsForAgent }
        let current = outbox.identity()
        if Self.awaitsLaunch(messages[index], current: current) { return .waitsForLaunch }
        guard let current else {
            messages[index].state = .held(Self.agentGoneMessage)
            return .settled
        }
        guard record.agent.matches(current) else {
            messages[index].state = .held(Self.agentChangedMessage)
            return .settled
        }
        messages[index].agentWasWorkingAtSend = agentStatus == .working
        messages[index].statusRevisionAtSend = statusRevision
        messages[index].observedWorkingAfterSend = false
        messages[index].tracksAgentProgress = deliversToAgent
        messages[index].state = .sending
        noteQueueChange()
        for position in record.attachments.indices
        where record.attachments[position].hostPath == nil {
            let attachment = record.attachments[position]
            guard let fileURL = outbox.store.fileURL(of: attachment, in: record) else {
                return failQueued(id, record: record, message: Self.attachmentMissingMessage)
            }
            do {
                let path = try await outbox.upload(attachment, fileURL)
                if drainStopped { return .settled }
                record.attachments[position].hostPath = path
                record.attachments[position].localFileName = nil
                // The record names the Host path before the copy goes, so a
                // kill in between never loses an upload that landed.
                if (try? outbox.store.save(record)) != nil {
                    try? FileManager.default.removeItem(at: fileURL)
                }
                updateQueued(id, record: record)
            } catch {
                if drainStopped { return .settled }
                guard Self.uploadMayRetry(error) else {
                    return failQueued(id, record: record, message: Self.uploadFailedMessage)
                }
                requeue(id, record: record)
                return .notSent
            }
        }
        guard outbox.mayDrain() else {
            requeue(id, record: record)
            return .notSent
        }
        // The uploads took time: the Agent must still be the one it was
        // queued for right before the prompt goes.
        guard let latest = outbox.identity(), record.agent.matches(latest) else {
            let reason = outbox.identity() == nil ? Self.agentGoneMessage : Self.agentChangedMessage
            return holdQueued(id, record: record, message: reason)
        }
        let text = record.prompt
        // From here a kill may leave the prompt delivered: a relaunch fails
        // the message for a deliberate Retry instead of sending it again. A
        // marker that did not reach the disk stops the send.
        record.promptStartedAt = Date()
        do {
            try outbox.store.save(record)
        } catch {
            record.promptStartedAt = nil
            return failQueued(id, record: record, message: Self.queueSaveFailedMessage)
        }
        updateQueued(id, record: record)
        let input = attachInput
        let generation = input?.liveGeneration
        let queuedFor = record.agent
        do {
            _ = try await promptWaitingOutLaunch(
                AgentPromptParams(target: target, text: text), prompt: prompt,
                stillAddressed: { [outbox] in
                    outbox.identity().map(queuedFor.matches) ?? false
                })
        } catch {
            if drainStopped { return .settled }
            // A launch still coming up: herdr 0.9.1 answers a fresh pane
            // `agent_not_found` for a moment, and its row may not name the
            // Agent yet.
            if let waiting = messages.first(where: { $0.id == id }), Self.isInLaunchWindow(waiting),
                Self.errorCode(error) == "agent_not_found"
                    || (error is QueuedAgentChangedError
                        && Self.awaitsLaunch(waiting, current: outbox.identity()))
            {
                requeue(id, record: record)
                return .waitsForLaunch
            }
            if error is QueuedAgentChangedError {
                return holdQueued(id, record: record, message: Self.agentChangedMessage)
            }
            // herdr knows no Agent on the pane: nothing was written, and
            // whatever starts there next is not the one it was queued for.
            if Self.errorCode(error) == "agent_not_found" {
                return holdQueued(id, record: record, message: Self.agentGoneMessage)
            }
            if error is RequestNotSentError || error is AgentInputNotReadyError {
                requeue(id, record: record)
                return .notSent
            }
            if Self.isAgentBlocked(error) {
                requeue(id, record: record)
                return .waitsForAgent
            }
            return failQueued(id, record: record, message: Self.message(for: error))
        }
        outbox.store.remove(record)
        // The prompt landed, so the record goes; a stopped drain writes
        // nothing more to the view.
        if drainStopped { return .settled }
        if let deliveredIndex = messages.firstIndex(where: { $0.id == id }) {
            messages[deliveredIndex].queued = nil
            messages[deliveredIndex].leftQueueAt = Date()
            markDelivered(
                deliveredIndex,
                progress: progressAfterAcknowledgment(for: messages[deliveredIndex]))
        }
        if let input, let generation {
            input.recordSubmitted(text, generation: generation)
        }
        noteQueueChange()
        return .settled
    }

    /// A Send whose prompt never left the device, or one that must wait
    /// behind the queue: its record goes to disk and it waits its turn.
    /// After a failure the Host is likely away, so the next try waits out a
    /// backoff; otherwise the queue drains as usual. A launch's prepared
    /// `attachments` are copied from `directory` into the record's own first.
    private func enqueue(
        _ id: Message.ID, afterFailure: Bool,
        copying attachments: [QueuedMessage.Attachment] = [], from directory: URL? = nil
    ) -> SendResult {
        guard let outbox, let index = messages.firstIndex(where: { $0.id == id }) else {
            return .ignored
        }
        let message = messages[index]
        // Held, not sent, if no row listed an Agent when the user sent it.
        var record = QueuedMessage(
            id: message.id, hostID: outbox.hostID,
            agent: message.agentAtSend
                ?? QueuedMessage.AgentIdentity(paneID: target, kind: nil, session: nil),
            draftText: message.draftText,
            attachments: message.trayItems.compactMap(Self.uploadedAttachment),
            createdAt: message.sentAt)
        if !attachments.isEmpty {
            // Until the record is saved: a message that fails keeps them.
            messages[index].launchCopies = LaunchCopies(
                attachments: attachments, directory: directory)
            do {
                try Self.copy(attachments, from: directory, into: &record, store: outbox.store)
            } catch {
                outbox.store.remove(record)
                return fail(id, message: Self.queueSaveFailedMessage)
            }
        }
        // A queue that is not on the disk would not outlive the app: the
        // message fails for a deliberate Retry instead of claiming Queued.
        guard !isQueueCancelled, (try? outbox.store.save(record)) != nil else {
            if !attachments.isEmpty { outbox.store.remove(record) }
            return fail(id, message: Self.queueSaveFailedMessage)
        }
        messages[index].queued = record
        messages[index].launchCopies = nil
        messages[index].state = .queued
        noteQueueChange()
        if afterFailure {
            sendDrain(.unsent)
        } else {
            drainQueue(resettingBackoff: false)
        }
        return .queued
    }

    /// Adds a launch's prepared attachments to `record`, copying each one's
    /// local file from `directory` into the record's own directory.
    private static func copy(
        _ attachments: [QueuedMessage.Attachment], from directory: URL?,
        into record: inout QueuedMessage, store: QueuedMessageStore
    ) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        let folder = try store.preparedDirectory(for: record)
        for attachment in attachments {
            if let name = attachment.localFileName {
                let destination = folder.appending(path: name, directoryHint: .notDirectory)
                // A process may have ended after copying, before saving the
                // deterministic first-message record. Reuse that same copy.
                if !FileManager.default.fileExists(atPath: destination.path) {
                    let temporary = folder.appending(path: ".copy-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try FileManager.default.copyItem(
                        at: directory.appending(path: name, directoryHint: .notDirectory),
                        to: temporary)
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
            }
            record.attachments.append(attachment)
        }
    }

    /// Send with the Host offline and items that could not upload: the
    /// message waits in the queue while its unready items are prepared into
    /// its directory on the device, exactly as staging would prepare them.
    /// One that cannot be prepared puts the whole send back in the draft.
    private func queueWithUnreadyItems(
        typed: String, taken: [ComposerTray.QueuedTake]
    ) async -> SendResult {
        guard let outbox else { return .ignored }
        let readyItems = taken.compactMap { take -> ComposerTray.Item? in
            if case .ready(let item) = take { return item }
            return nil
        }
        var record = QueuedMessage(
            id: UUID(), hostID: outbox.hostID,
            agent: identityAtSend()
                ?? QueuedMessage.AgentIdentity(paneID: target, kind: nil, session: nil),
            draftText: typed, attachments: [], createdAt: Date())
        // No record yet: nothing drains, cancels or edits it while it is copied.
        messages.append(
            Message(
                id: record.id, text: typed, draftText: typed, trayItems: readyItems,
                sentAt: record.createdAt,
                agentWasWorkingAtSend: false,
                statusRevisionAtSend: statusRevision,
                observedWorkingAfterSend: false,
                tracksAgentProgress: deliversToAgent,
                state: .queued))
        noteQueueChange()
        do {
            let directory = try outbox.store.preparedDirectory(for: record)
            for take in taken {
                switch take {
                case .ready(let item):
                    if let attachment = Self.uploadedAttachment(item) {
                        record.attachments.append(attachment)
                    }
                case .unready(_, let source):
                    record.attachments.append(try await outbox.prepare(source, directory))
                }
            }
            guard !isQueueCancelled else { throw CancellationError() }
            try outbox.store.save(record)
        } catch {
            outbox.store.remove(record)
            messages.removeAll { $0.id == record.id }
            noteQueueChange()
            tray.restore(readyItems)
            tray.add(taken.compactMap { take in
                if case .unready(_, let source) = take { return source }
                return nil
            }, restoring: true)
            let restored = draft.isEmpty ? typed : "\(typed)\n"
            if !typed.isEmpty {
                draft = restored + draft
                draftSelection = NSRange(
                    location: draftSelection.location + (restored as NSString).length,
                    length: draftSelection.length)
            }
            return .failed
        }
        for case .unready(_, let source) in taken {
            ComposerTray.discardLocalCopy(source)
        }
        updateQueued(record.id, record: record)
        drainQueue(resettingBackoff: false)
        return .queued
    }

    /// The Agent a message sent now is for: the one the Console lists on
    /// the pane, or, while a launch's first message still waits for the
    /// pane to list it, the Agent that launch started.
    private func identityAtSend() -> QueuedMessage.AgentIdentity? {
        if let holdingForLaunch { return holdingForLaunch }
        let current = outbox?.identity()
        let launch = messages.last { $0.isQueueRow && Self.awaitsLaunch($0, current: current) }
        return launch?.agentAtSend ?? current
    }

    /// Whether `message` is a launch's first message within its launch
    /// window (`queueLaunchMessage`).
    private static func isInLaunchWindow(_ message: Message) -> Bool {
        message.launchWaitEnds.map { ContinuousClock.now < $0 } ?? false
    }

    /// Whether `message` is a launch's first message whose pane lists no
    /// identified Agent yet (`current`): no row, herdr's pending launch
    /// (`Agent.unidentifiedKind`), or the shell before the Agent starts.
    private static func awaitsLaunch(
        _ message: Message, current: QueuedMessage.AgentIdentity?
    ) -> Bool {
        guard isInLaunchWindow(message) else { return false }
        guard let kind = current?.kind else { return true }
        return kind == Agent.unidentifiedKind || kind == Agent.shellKind
    }

    /// Something still queued (or going out from the queue) was sent
    /// before `id`. Held messages wait for the user, so they hold nothing up.
    private func hasQueueAhead(of id: Message.ID) -> Bool {
        guard outbox != nil else { return false }
        return messages.contains { message in
            message.id != id && message.isQueueRow && !message.isHeld
        }
    }

    private func updateQueued(_ id: Message.ID, record: QueuedMessage) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].queued = record
        messages[index].text = record.prompt
        messages[index].trayItems = Self.trayItems(for: record, keeping: messages[index].trayItems)
    }

    /// Back in the queue: nothing of the prompt reached the Host.
    private func requeue(_ id: Message.ID, record: QueuedMessage) {
        var record = record
        if record.promptStartedAt != nil {
            record.promptStartedAt = nil
            try? outbox?.store.save(record)
        }
        updateQueued(id, record: record)
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].state = .queued
        noteQueueChange()
    }

    /// Held for the user: the Agent it was for is gone or changed. Nothing
    /// of the prompt reached the Host, so its record loses the marker.
    private func holdQueued(
        _ id: Message.ID, record: QueuedMessage, message: String
    ) -> DrainStep {
        var record = record
        if record.promptStartedAt != nil {
            record.promptStartedAt = nil
            try? outbox?.store.save(record)
        }
        updateQueued(id, record: record)
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].state = .held(message)
        }
        noteQueueChange()
        return .settled
    }

    /// The drain's Host was removed or re-targeted, or its task cancelled:
    /// it writes nothing more.
    private var drainStopped: Bool {
        isQueueCancelled || Task.isCancelled
    }

    /// Fails a message from the queue. Its record stays on the device while
    /// an attachment has not uploaded, so Retry and Edit Draft still have
    /// the copy; otherwise everything is on the Host and the record goes.
    private func failQueued(
        _ id: Message.ID, record: QueuedMessage, message: String
    ) -> DrainStep {
        var record = record
        let keepsRecord = !record.isUploaded
        if keepsRecord {
            record.failureMessage = message
            try? outbox?.store.save(record)
        } else {
            outbox?.store.remove(record)
        }
        if let index = messages.firstIndex(where: { $0.id == id }) {
            updateQueued(id, record: record)
            if !keepsRecord { messages[index].queued = nil }
            messages[index].state = .failed(message)
        }
        noteQueueChange()
        return .settled
    }

    private func noteQueueChange() {
        outbox?.countDidChange(waitingCount)
    }

    /// A ready tray item as an attachment already on the Host. Its id is
    /// the item's, so Edit Draft brings the same chip back.
    private static func uploadedAttachment(_ item: ComposerTray.Item) -> QueuedMessage.Attachment? {
        guard let path = item.status.readyPath else { return nil }
        let kind: QueuedMessage.Attachment.Kind
        let fileName: String?
        switch item.kind {
        case .image:
            kind = .image
            fileName = nil
        case .file(let name):
            kind = .file
            fileName = name
        }
        return QueuedMessage.Attachment(
            id: item.id, kind: kind, fileName: fileName, localFileName: nil,
            fileExtension: "", pixelWidth: nil, pixelHeight: nil, byteCount: 0, hostPath: path)
    }

    /// The record's uploaded attachments as ready tray items, reusing
    /// `existing` chips (and their thumbnails) by id.
    private static func trayItems(
        for record: QueuedMessage, keeping existing: [ComposerTray.Item]
    ) -> [ComposerTray.Item] {
        record.attachments.compactMap { attachment in
            guard let path = attachment.hostPath else { return nil }
            if let item = existing.first(where: { $0.id == attachment.id }) { return item }
            let kind: ComposerTray.Item.Kind
            switch attachment.kind {
            case .image: kind = .image
            case .file: kind = .file(name: attachment.fileName ?? "file")
            }
            return ComposerTray.Item(
                id: attachment.id, kind: kind, thumbnail: nil, status: .ready(path: path))
        }
    }

    /// Edit Draft's sources for attachments that never uploaded, read from
    /// their copies (`fileURL`) before the record and its directory go. A
    /// file keeps its picked name through a temporary copy.
    private static func unsentSources(
        of attachments: [QueuedMessage.Attachment],
        at fileURL: (QueuedMessage.Attachment) -> URL?
    ) -> [ComposerStagingStore.Source] {
        attachments.compactMap { attachment in
            guard attachment.hostPath == nil, let url = fileURL(attachment) else { return nil }
            switch attachment.kind {
            case .image:
                guard let data = try? Data(contentsOf: url) else { return nil }
                return .photo(DataImageSelection(data: data))
            case .file:
                let name = attachment.fileName ?? url.lastPathComponent
                guard let copy = try? ComposerTray.makeLocalCopy(named: name, write: {
                    try FileManager.default.copyItem(at: url, to: $0)
                }) else { return nil }
                return .file(copy)
            }
        }
    }

    /// An upload that may succeed later stays queued: a transient transport
    /// failure (`TransportError.isRetryable`, less a Host's rejection), a
    /// cancellation, or a staging failure staging itself would retry. A
    /// Host's answer, such as a bad path or a missing SFTP, will not clear up
    /// on its own.
    private static func uploadMayRetry(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError: true
        case let staging as AttachmentStagingError: staging.isRetryable
        case TransportError.apiRejected: false
        case let transport as TransportError: transport.isRetryable
        default: EventsSession.isTransportLinkFailure(error)
        }
    }

    private func deliver(_ id: Message.ID) async -> SendResult {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return .ignored }
        let text = messages[index].text
        switch delivery {
        case .paneInput(let sendInput):
            return await deliverThroughPaneInput(id, text: text, sendInput: sendInput)
        case .agentPrompt(let prompt):
            return await deliverThroughPrompt(id, text: text, prompt: prompt)
        }
    }

    /// Types the draft and Enter into the shell in one request, so a partial
    /// failure cannot leave text typed but unsubmitted. Matches the Attach
    /// insert's scalar policy: a draft cannot smuggle terminal controls.
    private func deliverThroughPaneInput(
        _ id: Message.ID,
        text: String,
        sendInput: @Sendable (PaneSendInputParams) async throws -> Void
    ) async -> SendResult {
        guard TerminalTextSafety.containsOnlySafeScalars(text) else {
            return fail(id, message: Self.unsafeTextMessage)
        }
        let input = attachInput
        let generation = input?.liveGeneration
        do {
            try await sendInput(PaneSendInputParams(paneID: target, keys: ["enter"], text: text))
        } catch {
            return fail(id, message: Self.message(for: error))
        }
        guard let deliveredIndex = messages.firstIndex(where: { $0.id == id }) else {
            return .ignored
        }
        markDelivered(deliveredIndex, progress: .acknowledged)
        // Message jump indexes what Send submitted, for a shell as for an Agent.
        if let input, let generation {
            input.recordSubmitted(text, generation: generation)
        }
        return .deliveredViaPaneInput
    }

    private func deliverThroughPrompt(
        _ id: Message.ID,
        text: String,
        prompt: @Sendable (AgentPromptParams) async throws -> Agent
    ) async -> SendResult {
        if agentStatus == .blocked {
            // A sign-in screen or folder-trust dialog the backend reads as
            // Blocked is refused as `agent.prompt` refuses it. Any other
            // failure of the check leaves the send to the Attach.
            do {
                try await checkInputScreen?(target)
            } catch let error as AgentSignInRequiredError {
                return fail(id, message: error.message)
            } catch let error as AgentFolderTrustRequiredError {
                return fail(id, message: error.message)
            } catch {}
            return await deliverThroughAttach(id, text: text)
        }
        let input = attachInput
        let generation = input?.liveGeneration
        do {
            _ = try await promptWaitingOutLaunch(
                AgentPromptParams(target: target, text: text), prompt: prompt)
            guard let acknowledgedIndex = messages.firstIndex(where: { $0.id == id }) else {
                return .ignored
            }
            markDelivered(
                acknowledgedIndex,
                progress: progressAfterAcknowledgment(for: messages[acknowledgedIndex]))
            if let input, let generation {
                input.recordSubmitted(text, generation: generation)
            }
            return .deliveredViaPrompt
        } catch {
            // Nothing reached the Host: the message waits in the queue and
            // goes out on its own once the Host can take it.
            if outbox != nil, error is RequestNotSentError {
                return enqueue(id, afterFailure: true)
            }
            if Self.isAgentBlocked(error) {
                return await deliverThroughAttach(id, text: text)
            }
            // The Transport still holds prompts to this launch because the
            // agent's TUI drops typed input (`AgentInputNotReadyError`):
            // typing the draft into the Attach would lose it the same way.
            if let notReady = error as? AgentInputNotReadyError {
                return fail(id, message: notReady.message)
            }
            // A launch herdr 0.9.1 left pending refuses the prompt API until
            // something reconciles it (#17). The Transport's post-start settle
            // cures launches Waycar started; this is the backstop. With the
            // Attach live, type the message into the PTY without submitting
            // it: the user sees the screen and presses Enter from the tools
            // keyboard. That Enter starts a turn for any agent kind, a status
            // change that reconciles the launch; past herdr's 30 s deadline it
            // clears the flag together with the Agent's name. No automatic
            // Enter: `agent_not_ready` only means herdr's launch is pending,
            // and the PTY may show claude's folder-trust dialog (reported
            // `blocked`, possibly after a stale status), where Enter would
            // accept it.
            // Only `agent_not_ready` qualifies: it means herdr still sees an
            // agent launching in the pane. `agent_not_found` means herdr
            // knows no agent there, so the PTY may be a plain shell. A draft
            // with a line break is refused too: until the agent's input is
            // on screen, an LF may be taken as Enter.
            if Self.isAgentStillLaunching(error), !TerminalTextSafety.isMultiline(text),
                attachInput != nil
            {
                // Status updates keep arriving during the retry budget. A
                // claude launch in an untrusted folder stops on its trust
                // dialog, which herdr reports as `blocked`. Typing there could
                // pick one of the dialog's choices, so leave the dialog to the
                // user and keep the draft for a later send.
                if agentStatus == .blocked {
                    return fail(id, message: Self.launchQuestionMessage)
                }
                return await deliverThroughAttach(id, text: text)
            }
            return fail(id, message: Self.message(for: error))
        }
    }

    /// Delivers one `agent.prompt` request, waiting out a fresh launch's
    /// registration rejections first. herdr 0.8.0+ answers `agent.start`
    /// while the pane's agent is still booting (`launch_pending`), so the
    /// first prompt of a just-started Agent can beat the agent's registration
    /// on the Host and be refused with "agent wX:pY is not an active named
    /// agent" (`agent_not_ready`) — the pane id is correct, and re-entering
    /// the session later finds it active because only time was missing.
    /// 0.9.1 also returns `agent_not_found` ("agent target wX:pY not found")
    /// during that same window on a fresh pane, so both codes are waited
    /// out. A launch herdr 0.9.1 left pending is promoted only by a reconcile
    /// (`agent.get` or a status change, #17); the Transport's post-start
    /// settle sends that `agent.get` for launches Waycar started. A target
    /// that never comes up still fails at the budget's end with herdr's
    /// refusal. An Agent whose live status turns Blocked meanwhile (claude's
    /// folder-trust dialog) gets no further attempt: the refusal surfaces at
    /// once and the caller leaves the dialog to the user.
    ///
    /// `AgentInputNotReadyError` is waited out the same way, with the budget
    /// stretched to its gate: the Transport holds an opencode launch's
    /// prompts until its input box is on screen or until `opensAt` (60 s
    /// after the start by default, past this budget), and lets the first
    /// prompt after that through. Running to `opensAt` plus two retry
    /// delays leaves room for that last attempt, the read in front of it
    /// included. A send the gate never held keeps exactly the plain budget.
    ///
    /// A queued drain passes `stillAddressed`: it never waits out
    /// `agent_not_found` (an absent Agent is not the one it was queued for),
    /// and it stops with `QueuedAgentChangedError` when the pane's Agent is
    /// no longer that one after a retry delay.
    private func promptWaitingOutLaunch(
        _ params: AgentPromptParams,
        prompt: @Sendable (AgentPromptParams) async throws -> Agent,
        stillAddressed: (@MainActor () -> Bool)? = nil
    ) async throws -> Agent {
        var admission = ComposerPromptAdmissionMachine(
            retryDelay: agentNotReadyRetryDelay, queued: stillAddressed != nil)
        var effects = admission.handle(.begin(now: ContinuousClock.now, budget: agentNotReadyRetryBudget))
        while case .attempt(let token) = effects.first {
            do {
                let agent = try await prompt(params)
                _ = admission.handle(.response(token, .accepted, now: ContinuousClock.now, blocked: agentStatus == .blocked))
                return agent
            } catch {
                if error is CancellationError {
                    _ = admission.handle(.cancelled(token))
                    throw error
                }
                let response: ComposerPromptAdmissionMachine.Response
                if let hold = error as? AgentInputNotReadyError {
                    response = .inputHold(opensAt: hold.opensAt)
                } else if Self.isAgentNotReady(error) {
                    response = .registration(stillLaunching: Self.isAgentStillLaunching(error))
                } else {
                    response = .refusal
                }
                let waiting = admission.handle(.response(token, response, now: ContinuousClock.now, blocked: agentStatus == .blocked))
                guard case .wait(let timer, let delay) = waiting.first else { throw error }
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    _ = admission.handle(.cancelled(timer))
                    throw error
                }
                // The original checks are ordered: Blocked first, then the
                // identity check (which is not called after a Blocked wake).
                let blocked = agentStatus == .blocked
                effects = admission.handle(.retryElapsed(timer, blocked: blocked,
                    stillAddressed: blocked ? true : stillAddressed?() ?? true))
                if admission.state == .refused(.agentChanged) { throw QueuedAgentChangedError() }
                guard !effects.isEmpty else { throw error }
            }
        }
        throw CancellationError()
    }

    /// Types the draft into the live Attach PTY without submitting it.
    /// Matches tools-keyboard writes: UTF-8 bytes, no bracketed paste. Line
    /// breaks are content for the agent TUIs this path targets, so CRLF and
    /// lone CR are normalized to LF first: a CR would submit. Those bytes
    /// already cross `TerminalInputController`'s writer, which indexes them;
    /// do not also `record(submitted:)` here. With no Attach bound, the
    /// Chat view's Blocked insert carries the same text instead.
    private func deliverThroughAttach(_ id: Message.ID, text: String) async -> SendResult {
        guard TerminalTextSafety.containsOnlySafeScalars(text) else {
            return fail(id, message: Self.unsafeTextMessage)
        }
        let normalized = TerminalTextSafety.normalizingNewlines(text)
        if let attachInput {
            guard attachInput.insertComposerDraft(normalized) else {
                return fail(id, message: attachFailureMessage)
            }
        } else if let blockedInsert {
            do {
                try await blockedInsert(normalized)
            } catch {
                return fail(id, message: Self.message(for: error))
            }
        } else {
            return fail(id, message: attachFailureMessage)
        }
        guard let deliveredIndex = messages.firstIndex(where: { $0.id == id }) else {
            return .ignored
        }
        messages[deliveredIndex].tracksAgentProgress = false
        markDelivered(deliveredIndex, progress: .acknowledged)
        return .deliveredViaAttach
    }

    /// A delivered message can no longer go back to the draft, so it lets
    /// go of its tray items and their thumbnails.
    private func markDelivered(_ index: Int, progress: AgentProgress) {
        messages[index].state = .delivered(progress)
        messages[index].trayItems = []
        guard deliversToAgent else { return }
        // A launch's first message is already counted with its launch.
        if messages[index].launchWaitEnds == nil { onAgentMessageDelivered?() }
        if progress == .done { onAgentTurnDone?() }
    }

    @discardableResult
    private func fail(_ id: Message.ID, message: String) -> SendResult {
        guard let failedIndex = messages.firstIndex(where: { $0.id == id }) else {
            return .ignored
        }
        messages[failedIndex].state = .failed(message)
        return .failed
    }

    /// Both registration-window codes: `agent_not_ready` ("is not an active
    /// named agent") and `agent_not_found` ("agent target ... not found",
    /// transiently returned for a freshly created pane before its agent
    /// registers). A genuinely absent target still surfaces at the budget's
    /// end rather than on the first attempt.
    private static func isAgentNotReady(_ error: any Error) -> Bool {
        let code = errorCode(error)
        return code == "agent_not_ready" || code == "agent_not_found"
    }

    /// Exactly `agent_not_ready`: herdr still sees an agent launching in the
    /// pane, so the PTY belongs to that agent rather than a fallback shell.
    private static func isAgentStillLaunching(_ error: any Error) -> Bool {
        errorCode(error) == "agent_not_ready"
    }

    private static func errorCode(_ error: any Error) -> String? {
        if let apiError = error as? HerdrAPIError {
            return apiError.code
        }
        if let transportError = error as? TransportError,
            case .apiRejected(let code, _) = transportError
        {
            return code
        }
        return nil
    }

    private static func isAgentBlocked(_ error: any Error) -> Bool {
        if let apiError = error as? HerdrAPIError {
            return apiError.code == "agent_blocked"
        }
        if let transportError = error as? TransportError,
            case .apiRejected(let code, _) = transportError
        {
            return code == "agent_blocked"
        }
        return false
    }

    private func progressAfterAcknowledgment(for message: Message) -> AgentProgress {
        if message.observedWorkingAfterSend {
            switch agentStatus {
            case .working:
                return .working
            case .done, .idle:
                return .done
            default:
                break
            }
        } else if !message.agentWasWorkingAtSend,
            message.statusRevisionAtSend != statusRevision,
            agentStatus == .done
        {
            // The status stream keeps only the newest event. A fast
            // working-to-done pair can therefore arrive as Done alone.
            return .done
        }
        return message.agentWasWorkingAtSend ? .agentBusy : .acknowledged
    }

    /// Why typing into the Attach found no way in. A message for an Agent
    /// waiting on a question is never queued (it would go out as a new prompt
    /// after the question was answered some other way), so with the Host out
    /// of reach it fails with that said, and Retry or Edit Draft wait for
    /// the connection.
    private var attachFailureMessage: String {
        isHostReachable ? Self.missingAttachMessage : Self.offlineAttachMessage
    }

    /// The refusal while the Host is out of reach (`attachFailureMessage`).
    static let offlineAttachMessage =
        "The Host is not connected, so this can't be typed into the Agent. Reconnect, then retry, or edit the draft."

    private static let missingAttachMessage =
        "The message could not be sent. Check the connection and retry."
    private static let unsafeTextMessage =
        "The message contains unsafe terminal control characters."
    private static let launchQuestionMessage =
        "The Agent is asking a question. Answer it in the terminal, then send again."
    static let agentChangedMessage =
        "A different Agent now runs here. Send it anyway, edit it, or delete it."
    static let agentGoneMessage =
        "The Agent this was for is no longer listed. Edit it or delete it."
    private static let attachmentMissingMessage =
        "An attachment's copy on this device is gone. Edit the draft to add it again."
    private static let uploadFailedMessage =
        "An attachment could not be uploaded. Retry, or edit the draft."
    private static let queueSaveFailedMessage =
        "This message could not be kept on the device. Retry, or edit the draft."
    private static let interruptedMessage =
        "Waycar closed while this was sending, so it may have arrived. Retry, or edit the draft."

    private static func clamped(_ range: NSRange, to text: String) -> NSRange {
        let length = (text as NSString).length
        guard range.location != NSNotFound else {
            return NSRange(location: length, length: 0)
        }
        let location = min(max(range.location, 0), length)
        let remaining = length - location
        let clampedLength = min(max(range.length, 0), remaining)
        return NSRange(location: location, length: clampedLength)
    }

    static func message(for error: any Error) -> String {
        switch RequestNotSentError.unwrapped(error) {
        case TransportError.sshUnreachable:
            "The Host is not connected. Check the connection and retry."
        case TransportError.timedOut:
            "The Host did not answer. Check the connection and retry."
        case let error as HerdrAPIError:
            "herdr rejected the message: \(error.message)"
        case let error as TransportError:
            error.presentation.message
        case let error as AgentInputNotReadyError:
            error.message
        case let error as AgentSignInRequiredError:
            error.message
        case let error as AgentFolderTrustRequiredError:
            error.message
        default:
            missingAttachMessage
        }
    }
}

/// The pane's Agent changed while a queued prompt waited out a launch.
private struct QueuedAgentChangedError: Error {}
