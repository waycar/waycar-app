import SwiftUI
import UIKit

enum AgentComposerKeyboardPresentation: Equatable {
    case hidden
    case system
    case tools

    /// The tools dock follows the Keys dock's responder policy; see
    /// `TerminalKeyboardMode.controlsReleaseFirstResponder`.
    @MainActor static var toolsDockReleasesFocus: Bool {
        TerminalKeyboardMode.controlsReleaseFirstResponder
    }
}

extension TerminalKeyboardInset {
    /// Readies the inset for a Composer keyboard presentation: the tools dock
    /// freezes the last complete measurement, the system keyboard is expected
    /// before its first frame arrives.
    func prepare(for presentation: AgentComposerKeyboardPresentation) {
        switch presentation {
        case .tools:
            pauseHeightCapture()
        case .hidden:
            resumeHeightCapture()
        case .system:
            resumeHeightCapture()
            expectSoftwareKeyboard()
        }
    }
}

struct AgentComposerKeyboardLayout: Equatable {
    /// Used only when `lastPresentedHeight` is still zero. Any positive
    /// measurement is the tools footprint as-is, even when it is shorter
    /// than this value.
    static let minimumToolsHeight: CGFloat = 260

    let contentInset: CGFloat
    let availableToolsHeight: CGFloat

    /// `softwareKeyboardDismissed` releases the `.system` pin once the
    /// software keyboard really left while focus stayed (a hardware keyboard
    /// attached); see ``TerminalKeyboardInset/isSoftwareKeyboardDismissed``.
    init(
        currentHeight: CGFloat,
        lastPresentedHeight: CGFloat,
        presentation: AgentComposerKeyboardPresentation,
        softwareKeyboardDismissed: Bool = false
    ) {
        switch presentation {
        case .hidden:
            availableToolsHeight = lastPresentedHeight
            contentInset = currentHeight
        case .system:
            availableToolsHeight = lastPresentedHeight
            // The pin bridges transient dips (Tools→iOS pre-show, input-view
            // swaps), never a confirmed dismissal.
            contentInset =
                softwareKeyboardDismissed
                ? currentHeight : max(currentHeight, lastPresentedHeight)
        case .tools:
            // Only the unmeasured path may invent a height. A positive
            // measurement, including compact landscape footprints below
            // `minimumToolsHeight`, is the tools dock's exact size.
            let toolsHeight =
                lastPresentedHeight > 0
                ? lastPresentedHeight : Self.minimumToolsHeight
            availableToolsHeight = toolsHeight
            contentInset = toolsHeight
        }
    }
}

struct AgentComposerActions {
    /// Add Image / Add File have room in the Composer Tray.
    let canAdd: Bool
    let addImage: () -> Void
    let addFile: () -> Void
    let openTerminal: (() -> Void)?
    let isOpeningTerminal: Bool
    let startAgent: () -> Void
    let manageSnippets: () -> Void
    /// Opens the explicit Skill picker. Nil for agent kinds without a skills
    /// source catalog, which hides the More-menu entry entirely rather than
    /// offering a dead button.
    let showSkills: (() -> Void)?
    let showWorktreeDetails: (() -> Void)?
    let renameAgent: () -> Void
    let renameWorkspace: () -> Void
    /// Marks the Agent unread and leaves for the Console index. Nil when the
    /// Agent cannot be marked (not Idle, a shell, already marked), which hides
    /// the More-menu entry.
    let markUnread: (() -> Void)?
    let closeAgent: () -> Void
    /// Close Agent archives the session instead (an OpenCode session, card
    /// 1530 1a), so the menu says Archive.
    var archivesAgent = false
    /// Zellij cannot rename a session without invalidating its running hooks' address.
    var canRenameWorkspace = true
    /// Whole-session Attach has no inventory pane for these actions.
    var paneActionsAvailable = true
}

/// Message Agent: the native, local-first Composer card above the Toolbar.
/// Drafting stays on device; for an Agent, Send emits one `agent.prompt`
/// request except when Agent Status is Blocked, in which case it inserts the
/// draft into Attach without Enter and presents the tools keyboard. For a
/// shell row, Send is one `pane.send_input` type-and-submit; copy and input
/// traits follow the store's delivery (`AgentComposerStore.deliversToAgent`).
/// A 💬 tap opens it with the text field focused; any other open leaves the keyboard down.
/// Added images and files ride the Composer Tray, a chip row above the text
/// field, until Send delivers their Host paths with the draft.
/// Its row is fixed: `+ …` on the left, the draft mic and Send on the right.
struct AgentComposerView: View {
    let store: AgentComposerStore
    /// The Agent this Composer drafts for; keys the window's Send command.
    let agentID: ConsoleAgent.ID
    /// Add puts images and files in the Composer Tray; More carries the row
    /// actions.
    let actions: AgentComposerActions
    /// The screen's one Skills store, shared with the tools keyboard and the
    /// explicit picker. Nil for kinds without a skills source catalog, which
    /// disables inline suggestions.
    let skills: SkillsPaneStore?
    @Binding var keyboardPresentation: AgentComposerKeyboardPresentation
    let prepareKeyboardPresentation: (AgentComposerKeyboardPresentation) -> Void
    /// One-shot: the opener asks for the text field to take focus; cleared once consumed.
    @Binding var focusRequested: Bool
    /// True while a sheet, alert, or picker covers the screen, or the Agent
    /// is Launch-locked: the microphone must not stay live behind UI the
    /// person is now looking at, and ⌘Return sends nothing.
    var isCovered: Bool = false
    /// A Queued Launch has no Host actions until its Agent starts.
    var showsMoreMenu: Bool = true
    /// Locks Send while a Queued Launch hands its messages to its Agent.
    var isSendDisabled: Bool = false
    /// Caps the Queued Messages' area, which scrolls inside the cap; nil
    /// lets it grow with its rows. The terminal sets it while the offline
    /// reader is open, so a card of queued rows cannot cover the reader.
    var queueMaxHeight: CGFloat? = nil
    /// Called with the Queued Messages' area height as shown (0 with no
    /// rows), for the cap to follow what the rest of the screen leaves.
    var queueHeightDidChange: ((CGFloat) -> Void)? = nil
    @State private var queueContentHeight: CGFloat = 0
    @State private var isInputFocused = false
    /// An explicit dismissal hides suggestions for the current trigger token;
    /// removing the token arms them again.
    @State private var isSuggestionsDismissed = false
    @State private var isDropTargeted = false
    /// Tap-to-talk into the draft with the system's on-device speech model.
    /// Owned per Composer; the engine underneath is app-wide.
    @State private var dictation = DictationStore()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Moves on once a just-sent queue row has lingered (`sentRowLinger`).
    @State private var sentRowClock = Date()

    private var toolsDockReleasesFocus: Bool {
        AgentComposerKeyboardPresentation.toolsDockReleasesFocus
    }

    /// The queue rows, in a scroll view of at most `queueMaxHeight` when a cap
    /// is set, and as tall as their content otherwise (that area is then
    /// exactly what it was without the cap).
    @ViewBuilder
    private func queueArea<Rows: View>(@ViewBuilder _ rows: () -> Rows) -> some View {
        if let queueMaxHeight {
            ScrollView {
                rows()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                        queueContentHeight = $0
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: queueContentHeight > 0 ? min(queueContentHeight, queueMaxHeight) : queueMaxHeight)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                queueHeightDidChange?($0)
            }
        } else {
            rows()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    queueHeightDidChange?($0)
                }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let skills, let trigger = suggestionTrigger,
                isInputFocused, !isSuggestionsDismissed
            {
                AgentComposerSkillSuggestions(
                    skills: skills,
                    trigger: trigger,
                    onSelect: { skill in
                        store.replaceTrailingToken(
                            trigger.token, with: skill.insertionText)
                    },
                    onDismiss: { isSuggestionsDismissed = true })
            }
            ComposerTrayView(tray: store.tray)
            ZStack(alignment: .topLeading) {
                AgentComposerTextEditor(
                    text: store.draft,
                    selectedRange: store.draftSelection,
                    onEdit: { store.applyEditorDraft($0, selection: $1) },
                    isFocused: $isInputFocused,
                    accessibilityLabel: store.deliversToAgent
                        ? "Message the Agent" : "Command for the terminal",
                    // Matches the terminal Direct Input types into, so
                    // the responder handoff keeps one keyboard context:
                    // Agent input is natural language, a shell's commands.
                    textInputStyle: store.deliversToAgent ? .naturalLanguage : .terminal,
                    keyboardPresentation: keyboardPresentation,
                    onTapBehindToolsDock: { setKeyboardPresentation(.system) },
                    onPasteAttachments: { store.acceptDrop($0) })
                if store.draft.isEmpty {
                    Text(store.deliversToAgent ? "Message Agent" : "Command")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 36, alignment: .topLeading)
            .accessibilityElement(children: .contain)

            let waiting = waitingMessages
            Group {
                if !waiting.isEmpty {
                    queueArea {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(waiting.prefix(Self.listedWaitingLimit)) { message in
                            AgentComposerQueuedRow(
                                message: message,
                                canSendAnyway: store.canSendHeldAnyway,
                                cancel: { store.deleteQueued(message.id) },
                                edit: {
                                    store.withdrawToDraft(message.id)
                                    isInputFocused = true
                                },
                                sendAnyway: { store.sendAnyway(message.id) })
                            .transition(
                                QueuedMessageMotion.transition(
                                    reduceMotion: reduceMotion, anchor: .leading))
                        }
                        if waiting.count > Self.listedWaitingLimit {
                            Text("\(waiting.count - Self.listedWaitingLimit) more queued")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText(value: Double(waiting.count)))
                                .transition(.opacity)
                        }
                    }
                    }
                    .transition(
                        QueuedMessageMotion.transition(reduceMotion: reduceMotion, anchor: .leading))
                }
            }
            .onChange(of: waiting.isEmpty) { _, isEmpty in
                if isEmpty { queueHeightDidChange?(0) }
            }
            // A message that just went out from the queue stays as "Sent"
            // for a moment, its glyph morphed to a check, then lifts out.
            .task(id: newestLeftQueueAt) {
                guard newestLeftQueueAt != nil else { return }
                try? await Task.sleep(for: Self.sentRowLinger)
                sentRowClock = Date()
            }

            Group {
                if let failure = latestFailure {
                    AgentComposerFailureRow(
                        detail: failure.detail,
                        retry: {
                            Task { await deliverDraft { await store.retry(failure.id) } }
                        },
                        edit: {
                            store.withdrawToDraft(failure.id)
                            isInputFocused = true
                        })
                    .transition(
                        QueuedMessageMotion.transition(reduceMotion: reduceMotion, anchor: .leading))
                }
            }

            if showsDictation, let failure = dictation.failure {
                DictationFailureRow(
                    failure: failure,
                    dismiss: { dictation.dismissFailure() })
            }

            HStack(spacing: 8) {
                addMenu
                if showsMoreMenu { moreMenu }

                if dictation.isActive {
                    dictationIndicator
                } else {
                    Spacer(minLength: 0)
                    if store.isWaitingOnTray {
                        Text(store.sendAccessibilityHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    } else if store.canQueueTray {
                        Text("Sends when the Host reconnects")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityHidden(true)
                    }
                }

                if showsDictation {
                    DictationMicButton(
                        phase: dictation.phase,
                        idleTint: secondaryActionTint,
                        action: toggleDictation)
                    .disabled(dictation.isBlockedByOtherSession)
                }
                AgentComposerSendButton(
                    isEnabled: canSendDraft,
                    accessibilityHint: store.sendAccessibilityHint
                ) {
                    Task { await sendDraft() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.accentColor.opacity(dropHighlight.fillOpacity))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(composerCardStroke, lineWidth: dropHighlight.strokeWidth)
        }
        // Queue rows and failures change the card's height: animate at the
        // card so its material grows and shrinks with them, never behind.
        .animation(
            QueuedMessageMotion.arrival(reduceMotion: reduceMotion),
            value: waitingMessages.map(\.id))
        .animation(
            QueuedMessageMotion.state(reduceMotion: reduceMotion),
            value: waitingMessages.map(\.state))
        .animation(
            QueuedMessageMotion.arrival(reduceMotion: reduceMotion), value: latestFailure?.id)
        .composerDropDestination(
            isEnabled: true,
            isTargeted: $isDropTargeted,
            accept: { store.acceptDrop($0) }
        )
        .padding(.horizontal, 12)
        .modifier(ConsoleComposerCommandRegistration(
            agentID: agentID,
            isFocused: isInputFocused,
            isCovered: isCovered,
            hasDraft: { canSendDraft },
            send: { await sendDraft() }))
        .task(id: focusRequested) {
            guard focusRequested, !isCovered else { return }
            // Consumed at once: a cancelled task must not leave the request
            // armed for a later, keyboard-down open.
            focusRequested = false
            await Task.yield()
            isInputFocused = true
        }
        .onChange(of: isInputFocused) { _, isFocused in
            if isFocused {
                // A tap into the text while the iPad tools dock is up asks
                // for the system keyboard; on iPhone the dock keeps the caret.
                if keyboardPresentation != .tools || toolsDockReleasesFocus {
                    setKeyboardPresentation(.system)
                }
            } else if !(toolsDockReleasesFocus && keyboardPresentation == .tools) {
                setKeyboardPresentation(.hidden)
            }
        }
        .onDisappear {
            focusRequested = false
            // Never leave the microphone live behind another screen.
            dictation.cancel()
        }
        .onChange(of: ObjectIdentifier(store)) { _, _ in
            dictation.cancel()
            // A failure belongs to the previous Agent's Composer.
            dictation.dismissFailure()
        }
        .onChange(of: isCovered) { _, covered in
            if covered {
                dictation.stop()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                dictation.stop()
            }
        }
        .onChange(of: store.draft) { _, _ in
            guard let skills else { return }
            if suggestionTrigger == nil {
                isSuggestionsDismissed = false
            } else if !isSuggestionsDismissed {
                // Typing the prefix is the pane-selection moment: load once,
                // then reuse (the ConsoleStore caches underneath).
                Task { await skills.loadIfNeeded() }
            }
        }
    }

    /// The invocation token at the end of the draft, when this agent has
    /// skill sources at all. Prefixes ride the skills and their catalog, not
    /// the Composer.
    private var suggestionTrigger: SkillSuggestionTrigger? {
        guard let skills else { return nil }
        return SkillSuggestionTrigger.detect(
            draft: store.draft, prefixes: skills.triggerPrefixes)
    }

    private func setKeyboardPresentation(_ presentation: AgentComposerKeyboardPresentation) {
        guard presentation != keyboardPresentation else { return }
        prepareKeyboardPresentation(presentation)
        keyboardPresentation = presentation
    }

    /// Blocked delivery types into Attach without Enter; the tools keyboard
    /// is what submits or cancels.
    private func deliverDraft(
        _ deliver: () async -> AgentComposerStore.SendResult
    ) async {
        let result = await deliver()
        guard result == .deliveredViaAttach else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            setKeyboardPresentation(.tools)
            isInputFocused = !toolsDockReleasesFocus
        }
    }

    /// Send waits for Dictation's last words so the message leaves whole.
    private func sendDraft() async {
        await deliverDraft {
            await dictation.finish()
            return await store.send()
        }
    }

    /// Speech still in the microphone counts as a draft: Send stops
    /// Dictation first, so one tap does what Stop then Send did.
    private var canSendDraft: Bool {
        !isSendDisabled && (store.canSend || (dictation.holdsSpeech && !store.isWaitingOnTray))
    }

    /// Agents take natural language; a Shell's commands stay typed.
    private var showsDictation: Bool {
        dictation.isAvailable && store.deliversToAgent
    }

    private func toggleDictation() {
        if dictation.isActive {
            dictation.stop()
        } else {
            dictation.start(into: store)
        }
    }

    @ViewBuilder
    private var dictationIndicator: some View {
        if case .downloadingModel(let fraction) = dictation.phase {
            Text("Downloading speech model… \(Int((fraction * 100).rounded()))%")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Handed the store, not its level, so level changes redraw only
            // the waveform instead of the whole Composer.
            DictationWaveform(dictation: dictation, tint: Color(uiColor: .label))
                .frame(height: 28)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)
        }
    }

    private var addMenu: some View {
        Menu {
            AgentActionMenuContent(
                actions: actions,
                sections: AgentActionMenuPolicy.composerAddSections)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 18, height: 18)
                .accessibilityLabel("Add")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(secondaryActionTint)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityHint("Adds images or files to the draft")
    }

    private var moreMenu: some View {
        Menu {
            AgentActionMenuContent(
                actions: actions,
                sections: AgentActionMenuPolicy.composerMoreSections)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 18, height: 18)
                .accessibilityLabel("More")
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .tint(secondaryActionTint)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityHint("Opens Agent actions")
    }

    /// The newest message outside the queue, when it failed.
    private var latestFailure: (id: AgentComposerStore.Message.ID, detail: String)? {
        guard let message = store.messages.last(where: { !$0.isQueueRow }),
              case .failed(let detail) = message.state
        else { return nil }
        return (message.id, detail)
    }

    /// Queued Messages still on the device, oldest first, the one going out
    /// from the queue, and any that went out within `sentRowLinger`.
    private var waitingMessages: [AgentComposerStore.Message] {
        store.messages.filter { message in
            if message.isQueueRow { return true }
            guard case .delivered = message.state, let left = message.leftQueueAt else {
                return false
            }
            return left > sentRowClock.addingTimeInterval(-Self.sentRowLingerSeconds)
        }
        .sorted { $0.sentAt < $1.sentAt }
    }

    private var newestLeftQueueAt: Date? {
        store.messages.compactMap(\.leftQueueAt).max()
    }

    private static let sentRowLingerSeconds: TimeInterval = 1.4
    private static let sentRowLinger: Duration = .seconds(sentRowLingerSeconds)

    private static let listedWaitingLimit = 3

    private var secondaryActionTint: Color {
        Color(uiColor: .label).opacity(0.72)
    }

    private var dropHighlight: ComposerDropHighlight {
        ComposerDropHighlight(isTargeted: isDropTargeted)
    }

    private var composerCardStroke: Color {
        dropHighlight.usesAccentStroke
            ? Color.accentColor.opacity(0.72)
            : Color.secondary.opacity(0.16)
    }
}

/// The Composer's newest failed send, styled like a Queued Message row so a
/// failure arrives the same way: the error glyph, the reason, Retry and
/// Edit Draft, inside the error outline.
struct AgentComposerFailureRow: View {
    let detail: String
    let retry: () -> Void
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                QueuedMessageStatusIcon(state: .failed(detail))
                Text(detail)
                    .foregroundStyle(Brand.Colors.danger)
                    .lineLimit(2)
            }
            .font(.footnote)
            HStack(spacing: 8) {
                Button("Retry", action: retry)
                Button("Edit Draft", action: edit)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(QueuedMessageOutline(state: .failed(detail)))
    }
}

/// One Queued Message under the Composer draft (CONTEXT.md **Queued
/// Message**): what it says, "Queued" and its age, Cancel and Edit. A held
/// one says why it waits and offers Send Anyway while an Agent is on its
/// pane. One going out from the queue shows "Sending" and no actions. The
/// row keeps one layout across states: the glyph morphs, the dimmed text
/// brightens as it goes out, and the reason and actions fade in and out.
struct AgentComposerQueuedRow: View {
    let message: AgentComposerStore.Message
    let canSendAnyway: Bool
    let cancel: () -> Void
    let edit: () -> Void
    let sendAnyway: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                QueuedMessageStatusIcon(state: message.state)
                Text(verbatim: preview)
                    .font(.footnote)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(message.state == .queued ? 0.6 : 1)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(statusLine(at: context.date))
                        .accessibilityLabel(
                            statusLine(at: context.date, age: AgentSummaryLine.spokenAge)
                                .replacingOccurrences(of: " · ", with: ", "))
                        .font(.system(.caption, design: Brand.Fonts.monoDesign, weight: .medium))
                        .foregroundStyle(QueuedMessageStatusIcon.tint(for: message.state))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            if case .held(let reason) = message.state {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(QueuedMessageMotion.detailTransition(reduceMotion: reduceMotion))
            }
            if message.isWaiting {
                HStack(spacing: 8) {
                    if message.isHeld, canSendAnyway {
                        Button("Send Anyway", action: sendAnyway)
                    }
                    Button("Edit", action: edit)
                        .accessibilityHint("Moves the message back to the draft")
                    Button(message.isHeld ? "Delete" : "Cancel", role: .destructive, action: cancel)
                        .accessibilityHint("Deletes the message without sending it")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .transition(QueuedMessageMotion.detailTransition(reduceMotion: reduceMotion))
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(QueuedMessageOutline(state: message.state))
        .animation(QueuedMessageMotion.state(reduceMotion: reduceMotion), value: message.state)
        .accessibilityElement(children: .contain)
    }

    private var preview: String {
        let text = message.draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty else { return text }
        return message.trayItems.isEmpty && message.queued?.attachments.isEmpty != false
            ? "Message" : "Attachments"
    }

    private func statusLine(
        at now: Date, age format: (TimeInterval) -> String = AgentSummaryLine.shortAge
    ) -> String {
        let age = format(now.timeIntervalSince(message.sentAt))
        switch message.state {
        case .held: return "Held · \(age)"
        case .sending: return "Sending"
        case .delivered: return "Sent"
        case .failed: return "Not sent"
        case .queued: return "Queued · \(age)"
        }
    }
}

/// The inline suggestion menu above the Composer's text area: the Skills the
/// typed trigger token matches, or the load in progress behind them. Selecting
/// a row swaps the token for the full invocation in the draft — nothing is
/// sent. Renders nothing when a loaded catalogue has no match, so prose that
/// happens to contain a prefix is not nagged.
private struct AgentComposerSkillSuggestions: View {
    let skills: SkillsPaneStore
    let trigger: SkillSuggestionTrigger
    let onSelect: (AgentSkill) -> Void
    let onDismiss: () -> Void
    /// The suggestion list's measured content height. The scroll view is
    /// sized to it so one match does not reserve the full cap of empty
    /// space; the cap only bounds long lists.
    @State private var listHeight: CGFloat = Self.maximumListHeight

    private static let maximumListHeight: CGFloat = 176

    var body: some View {
        switch skills.phase {
        case .idle, .loading:
            header {
                ProgressView()
                    .controlSize(.small)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                header {
                    Button("Retry") { Task { await skills.refresh() } }
                        .font(.caption)
                }
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        case .loaded:
            let matches = trigger.matches(in: skills.skills)
            if !matches.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    header { EmptyView() }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(matches) { skill in
                                row(for: skill)
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            listHeight = height
                        }
                    }
                    .frame(height: min(listHeight, Self.maximumListHeight))
                    .scrollBounceBehavior(.basedOnSize)
                    Divider()
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Skill Suggestions")
            }
        }
    }

    private func header(@ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 8) {
            Text("Skills")
                .font(.caption.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            trailing()
            Spacer(minLength: 0)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss Skill Suggestions")
        }
    }

    private func row(for skill: AgentSkill) -> some View {
        Button {
            onSelect(skill)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(skill.command)
                    .font(.subheadline.weight(.medium))
                    .fontDesign(.monospaced)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let description = skill.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(skill.name)
        .accessibilityHint("Inserts \(skill.command) without sending it")
    }
}

struct AgentComposerSendButton: View {
    let isEnabled: Bool
    var accessibilityHint: String = "Delivers the complete draft to the Agent"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(AgentComposerSendButtonStyle())
        .disabled(!isEnabled)
        .accessibilityLabel("Send")
        .accessibilityHint(accessibilityHint)
    }
}

private struct AgentComposerSendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(
                Color(uiColor: isEnabled ? .systemBackground : .secondaryLabel))
            .frame(width: 32, height: 32)
            .background(
                isEnabled
                    ? Color(uiColor: .label)
                    : Color(uiColor: .label).opacity(0.12),
                in: Circle())
            .frame(width: 44, height: 44)
            .opacity(configuration.isPressed && isEnabled ? 0.72 : 1)
            .contentShape(.circle)
    }
}

private struct AgentComposerTextEditor: UIViewRepresentable {
    let text: String
    let selectedRange: NSRange
    let onEdit: (String, NSRange) -> Void
    @Binding var isFocused: Bool
    let accessibilityLabel: String
    let textInputStyle: TerminalTextInputStyle
    let keyboardPresentation: AgentComposerKeyboardPresentation
    /// iPhone's tools dock keeps the caret, so a tap into the text never
    /// changes focus; this asks for the system keyboard instead.
    let onTapBehindToolsDock: () -> Void
    /// A paste holding images or files; see `ComposerPasteTextView`.
    let onPasteAttachments: @MainActor ([ComposerDropItem]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEdit: onEdit, isFocused: $isFocused)
    }

    func makeUIView(context: Context) -> AgentComposerUITextView {
        let textView = AgentComposerUITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        // Correction traits are pinned in AgentComposerUITextView's
        // initializers, identical to the terminal's — matching traits
        // keep one keyboard context across the Direct Input responder
        // transfer (de36399). The style-dependent ones follow the target's
        // terminal the same way `WaycarTerminalView` applies them: a shell
        // command is never capitalized and gets no assistant bar groups.
        if textInputStyle == .terminal {
            textView.autocapitalizationType = .none
            textView.inputAssistantItem.leadingBarButtonGroups = []
            textView.inputAssistantItem.trailingBarButtonGroups = []
        }
        textView.accessibilityLabel = accessibilityLabel
        let tap = UITapGestureRecognizer(
            target: textView, action: #selector(AgentComposerUITextView.handleTap))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        textView.addGestureRecognizer(tap)
        return textView
    }

    func updateUIView(_ textView: AgentComposerUITextView, context: Context) {
        context.coordinator.onEdit = onEdit
        if textView.text != text {
            textView.text = text
        }
        if textView.selectedRange != selectedRange {
            textView.selectedRange = selectedRange
        }
        textView.updateKeyboard(presentation: keyboardPresentation)
        textView.onTapBehindToolsDock = onTapBehindToolsDock
        textView.onPasteAttachments = onPasteAttachments
        let shouldFocus = isFocused
        let coordinator = context.coordinator
        coordinator.wantsFocus = shouldFocus
        guard shouldFocus != textView.isFirstResponder else { return }
        DispatchQueue.main.async { [weak textView] in
            guard let textView else { return }
            if shouldFocus {
                guard !textView.isFirstResponder else { return }
                textView.becomeFirstResponder()
            } else {
                // UIKit can flush a pending update from inside
                // `becomeFirstResponder`, after the view is first responder
                // but before `textViewDidBeginEditing` records it. That
                // update's stale `false` must not undo the focus it raced.
                guard !coordinator.wantsFocus else { return }
                _ = textView.resignFirstResponder()
            }
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: AgentComposerUITextView,
        context _: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = uiView.font?.lineHeight ?? 20
        let maximumHeight = lineHeight * 5
            + uiView.textContainerInset.top
            + uiView.textContainerInset.bottom
        let height = min(max(36, measured.height), maximumHeight)
        uiView.isScrollEnabled = measured.height > maximumHeight
        return CGSize(width: width, height: height)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var onEdit: (String, NSRange) -> Void
        /// The latest focus intent, from either SwiftUI or UIKit, so a
        /// deferred focus change can recheck it before acting.
        var wantsFocus = false
        private var isFocused: Binding<Bool>

        init(onEdit: @escaping (String, NSRange) -> Void, isFocused: Binding<Bool>) {
            self.onEdit = onEdit
            self.isFocused = isFocused
        }

        func textViewDidChange(_ textView: UITextView) {
            onEdit(textView.text, textView.selectedRange)
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            onEdit(textView.text, textView.selectedRange)
        }

        func textViewDidBeginEditing(_: UITextView) {
            wantsFocus = true
            isFocused.wrappedValue = true
        }

        func textViewDidEndEditing(_: UITextView) {
            wantsFocus = false
            isFocused.wrappedValue = false
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

/// Keeps the Composer first-responder while switching between the system
/// keyboard and an app-owned tools dock. Tools mode suppresses UIKit's soft
/// keyboard with a zero-height input view; the dock already occupies the
/// measured keyboard footprint behind it, so removing the candidate row never
/// exposes an intermediate gap.
final class AgentComposerUITextView: ComposerPasteTextView {
    static var toolsDockReleasesFocus: Bool {
        AgentComposerKeyboardPresentation.toolsDockReleasesFocus
    }

    private lazy var suppressedSoftKeyboard = TerminalSuppressedSoftKeyboardView()
    private var keyboardPresentation: AgentComposerKeyboardPresentation = .hidden
    /// A tap into the text while it keeps focus behind the iPhone tools
    /// dock. Focus does not change, so the view reports the tap itself.
    var onTapBehindToolsDock: (() -> Void)?

    @objc fileprivate func handleTap() {
        guard isFirstResponder, keyboardPresentation == .tools else { return }
        onTapBehindToolsDock?()
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        applyTerminalMatchedInputTraits()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        applyTerminalMatchedInputTraits()
    }

    /// No-correction traits, identical to the terminal's — the parity
    /// keeps one keyboard context across the Direct Input responder
    /// transfer (de36399).
    private func applyTerminalMatchedInputTraits() {
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        inlinePredictionType = .no
    }

    func updateKeyboard(presentation: AgentComposerKeyboardPresentation) {
        guard presentation != keyboardPresentation else { return }
        keyboardPresentation = presentation
        let previousInputView = inputView
        switch presentation {
        case .hidden, .tools:
            inputView = suppressedSoftKeyboard
        case .system:
            inputView = nil
        }
        guard isFirstResponder, inputView !== previousInputView else { return }
        // On iPad the tools dock resigns instead (see `toolsDockReleasesFocus`);
        // reloading here would flash the suppressed keyboard's toolbar first.
        if presentation == .tools, Self.toolsDockReleasesFocus { return }
        UIView.performWithoutAnimation {
            reloadInputViews()
        }
    }
}

struct AgentToolsKeyboard: View {
    /// The screen routes authored text according to the active input mode.
    let insertText: (String) -> Void
    let context: TerminalKeysContext
    let keyboardControl: TerminalKeyboardControl
    let inputMode: AgentInputMode
    let height: CGFloat
    let quickKeysEnabled: Bool
    let sendQuickKey: (AgentQuickKey) -> Void
    @State private var selectedTab: TerminalKeysTab = .controls

    private var tabs: [TerminalKeysTab] {
        context.tabs
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .controls:
                    if inputMode == .direct {
                        TerminalFullKeyboard(
                            isEnabled: quickKeysEnabled,
                            keyboardControl: keyboardControl,
                            send: sendQuickKey)
                    } else {
                        AgentControlKeyboard(
                            isEnabled: quickKeysEnabled,
                            keyboardControl: keyboardControl,
                            send: sendQuickKey)
                    }
                case .skills:
                    if let skills = context.skills {
                        SkillsKeyboardPane(
                            store: skills.store,
                            onInsert: { skill in
                                insertText(skill.insertionText)
                                selectedTab = .controls
                            },
                            onViewContent: skills.viewContent)
                    }
                case .snippets:
                    SnippetsKeyboardPane(
                        store: context.settings.snippets,
                        onSend: { snippet in
                            insertText(snippet.body)
                            selectedTab = .controls
                        },
                        onManage: context.manageSnippets)
                case .appearance:
                    TerminalAppearancePane(
                        themes: context.settings.themes,
                        zoom: context.settings.zoom,
                        fonts: context.settings.fonts)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack(spacing: 4) {
                ForEach(tabs) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Image(systemName: tab.systemImageName)
                            .font(.body)
                            .foregroundStyle(selectedTab == tab ? Color.accentColor : .secondary)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(
                                selectedTab == tab ? Color(uiColor: .secondarySystemFill) : .clear,
                                in: .rect(cornerRadius: 8))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.accessibilityLabel)
                    .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
        }
        .frame(height: height)
        .clipped()
        .background(Color(uiColor: .systemBackground).ignoresSafeArea(edges: .bottom))
        .onChange(of: selectedTab) { _, tab in
            guard tab == .skills, let skills = context.skills else { return }
            Task { await skills.store.loadIfNeeded() }
        }
    }
}
