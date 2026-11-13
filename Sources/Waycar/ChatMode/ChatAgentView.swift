import SwiftUI
import UIKit

/// Chat Mode's presentation of an Agent: the transcript as bubbles, the
/// Composer's in-flight messages, a typing indicator, and a Blocked card,
/// with the input bar riding above the keyboard.
struct ChatAgentView: View {
    let agent: ConsoleAgent
    let transcript: ChatTranscriptStore
    let composer: AgentComposerStore
    let onShowTerminal: () -> Void
    /// Archive, for a Backend whose rows archive (`archivesOnClose`); nil
    /// elsewhere.
    let onArchive: (@MainActor () -> Void)?
    /// The local opening bubble from the Agent (`ChatGreeting`).
    let greeting: String
    /// Raises the keyboard once the view appears (a New Chat's arrival).
    let focusesInputOnAppear: Bool
    /// Fetches a message's media to a local file.
    let loadMedia: ChatMediaLoader
    /// Ultimate-only branches and sibling navigation.
    let ultimate: UltimateChatContext?
    /// Shared chat-only run control; no terminal keystrokes.
    let stopRun: (@MainActor () async -> Void)?
    /// A non-persistent partial launch notice; the chat itself succeeded.
    let launchNotice: String?
    /// Whether this chat is still the screen on show (the router's truth).
    /// The detail column can report a disappear for a chat that stays on
    /// screen, with no appear after it, so only a real departure stops the
    /// transcript.
    let isStillPresented: @MainActor () -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The Console's plugin update (#209); nil outside it (previews).
    @Environment(\.requestWaycarPluginUpdate) private var pluginUpdate
    @Environment(\.waycarPluginUpdateActivity) private var pluginUpdateActivity

    init(
        agent: ConsoleAgent,
        transcript: ChatTranscriptStore,
        composer: AgentComposerStore,
        greeting: String,
        focusesInputOnAppear: Bool = false,
        loadMedia: @escaping ChatMediaLoader,
        ultimate: UltimateChatContext? = nil,
        stopRun: (@MainActor () async -> Void)? = nil,
        launchNotice: String? = nil,
        isStillPresented: @escaping @MainActor () -> Bool = { false },
        onArchive: (@MainActor () -> Void)? = nil,
        onShowTerminal: @escaping () -> Void
    ) {
        self.onArchive = onArchive
        self.agent = agent
        self.transcript = transcript
        self.composer = composer
        self.greeting = greeting
        self.focusesInputOnAppear = focusesInputOnAppear
        self.loadMedia = loadMedia
        self.ultimate = ultimate
        self.stopRun = stopRun
        self.launchNotice = launchNotice
        self.isStillPresented = isStillPresented
        self.onShowTerminal = onShowTerminal
    }

    private static let bottomID = "chat-bottom"
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        // A leader chat on a wide screen keeps its branches in sight: a
        // left rail beside the transcript (the mockups' iPad layout).
        if let ultimate, horizontalSizeClass == .regular, !ultimate.children.isEmpty {
            HStack(spacing: 0) {
                UltimateBranchRail(context: ultimate)
                    .frame(width: 280)
                Divider().overlay(Brand.Colors.line)
                chat
            }
            .background(Brand.Colors.bg)
        } else {
            chat
        }
    }

    @ViewBuilder
    private var chat: some View {
        let pending = transcript.pendingMessages(composer.messages)
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: a lazy stack sizes rows it has not built from
                // estimates, so a long chat opened at its bottom could land
                // past the real content and show nothing until a touch made
                // it lay out again. A chat holds a few hundred messages at
                // most, and each row only re-renders when its message changes.
                VStack(alignment: .leading, spacing: 10) {
                    greetingBubble
                    if let launchNotice {
                        caption(launchNotice)
                    }
                    notice
                    ForEach(transcript.messages) { message in
                        ChatMessageRow(
                            message: message, agentName: agentName, loadMedia: loadMedia,
                            cardActions: cardActions)
                            .equatable()
                    }
                    // A send settles in with a spring carried by its own
                    // transition, so the rest of the transcript (a reply's
                    // echo landing in the same update) does not animate with
                    // it. A queued one that goes out keeps its bubble and only
                    // its caption changes (`ChatPendingBubble`).
                    ForEach(pending) { message in
                        pendingBubble(message)
                            .transition(
                                QueuedMessageMotion.transition(
                                    reduceMotion: reduceMotion, anchor: .bottomTrailing
                                )
                                .animation(QueuedMessageMotion.arrival(reduceMotion: reduceMotion)))
                    }
                    if transcript.showsTypingIndicator, ultimate == nil {
                        TypingIndicator(activity: transcript.activity)
                    }
                    if transcript.status == .blocked {
                        if transcript.usesStructuredRequests {
                            structuredRequests
                        } else {
                            blockedCard
                        }
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)
            // A short chat reads from the top; only the initial offset and
            // growth stay pinned to the bottom (the iPad's tall viewport
            // otherwise floats a few messages above a sea of empty space).
            .defaultScrollAnchor(.top, for: .alignment)
            .scrollDismissesKeyboard(.interactively)
            .background(Brand.Colors.bg)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if ultimate != nil, transcript.showsTypingIndicator {
                        ChatWorkingPill(activity: transcript.activity)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 2)
                    }
                    ChatInputBar(
                        composer: composer, focusOnAppear: focusesInputOnAppear,
                        placeholder: ultimate == nil ? "Message" : "Steer or answer…",
                        stop: stopAction)
                }
                .background(Brand.Colors.bg)
            }
            .onChange(of: transcript.messages) { _, _ in scrollToBottom(proxy) }
            .onChange(of: pending.map(\.id)) { _, _ in scrollToBottom(proxy) }
            .onChange(of: transcript.showsTypingIndicator) { _, _ in scrollToBottom(proxy) }
            .onChange(of: transcript.status) { _, _ in scrollToBottom(proxy) }
            .onChange(of: composer.draft) { _, _ in scrollToBottom(proxy, animated: false) }
            // A new send: follow it until its reply, even if herdr reports
            // no status change for the turn.
            .onChange(of: composer.messages.map(\.sentAt).max()) { old, new in
                guard let new, new > (old ?? .distantPast) else { return }
                transcript.followLocalSend()
            }
            .onReceive(
                NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)
            ) { _ in
                scrollToBottom(proxy)
            }
        }
        .toolbar {
            if let onArchive {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Archive", systemImage: "archivebox", action: onArchive)
                        .accessibilityLabel("Archive")
                }
            }
            if agent.canShowTerminal {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Show Terminal", systemImage: "terminal", action: onShowTerminal)
                        .accessibilityLabel("Show Terminal")
                }
            }
        }
        // Dark-only brand palette: the system's pieces (spinner, keyboard,
        // menus, navigation bar) must render dark too, whatever the
        // appearance. The status bar is the Console's to set
        // (`ConsoleView.terminalStatusBarColorScheme`), from the detail's
        // report that the Chat view is up.
        .environment(\.colorScheme, Brand.colorScheme)
        .toolbarColorScheme(Brand.colorScheme, for: .navigationBar)
        .toolbarBackground(Brand.Colors.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear { transcript.start() }
        // A plugin read as missing or outdated is never read again on its
        // own: once the Host's plugin meets the minimum (the update sheet,
        // or an update in a terminal seen on reconnect), the chat reads.
        .onChange(of: pluginUpdate?.status(agent.hostID)) { _, status in
            guard case .current = status else { return }
            transcript.recheckPlugin()
        }
        .onDisappear {
            guard !isStillPresented() else { return }
            transcript.stop()
        }
    }

    private var agentName: String { agent.agent.displayName }

    /// What the transcript's cards can do here: answer through the
    /// Composer's submit, and open sibling Ultimate chats.
    private var cardActions: ChatCardActions {
        var actions = ChatCardActions()
        let composer = composer
        let transcript = transcript
        actions.submitText = { text in
            let result = await composer.send(text)
            if result != .failed, result != .ignored { transcript.followLocalSend() }
            switch result {
            case .deliveredViaPrompt, .deliveredViaAttach, .deliveredViaPaneInput: return .sent
            case .queued: return .queued
            case .failed, .ignored: return .notSent
            }
        }
        if let ultimate {
            actions.openConversation = { ultimate.openConversation($0) }
        }
        return actions
    }

    /// Stop, offered to the input bar only while a chat run is busy:
    /// the bar shows it in Send's place while the draft is empty.
    private var stopAction: (() async -> Void)? {
        guard let stopRun, transcript.showsTypingIndicator else { return nil }
        return {
            await stopRun()
            await transcript.refresh()
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        } else {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }

    // MARK: Bubbles

    private var greetingBubble: some View {
        AgentBubble {
            ChatMessageText(text: greeting)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agentName): \(greeting)")
    }

    /// A Composer message the transcript does not hold yet: one bubble view
    /// across its states, so a change animates in place.
    private func pendingBubble(_ message: AgentComposerStore.Message) -> some View {
        ChatPendingBubble(
            message: message,
            canSendAnyway: composer.canSendHeldAnyway,
            retry: {
                // In place: a fresh send would leave this copy behind.
                Task {
                    let result = await composer.retry(message.id)
                    if result != .failed, result != .ignored { transcript.followLocalSend() }
                }
            },
            edit: { composer.withdrawToDraft(message.id) },
            cancel: { composer.deleteQueued(message.id) },
            sendAnyway: { composer.sendAnyway(message.id) })
    }

    // MARK: Notices

    @ViewBuilder
    private var notice: some View {
        switch transcript.availability {
        case .pluginMissing, .pluginOutdated:
            pluginNotice
        case .failed:
            caption("Can't refresh")
        case .loading, .waitingForConversation, .ready:
            EmptyView()
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Brand.Colors.text3)
            .frame(maxWidth: .infinity)
    }

    private var isUpdatingPlugin: Bool {
        pluginUpdateActivity?.runningHosts.contains(agent.hostID) == true
    }

    private var pluginNotice: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Update the Waycar plugin on \(agent.hostName) to see replies here.")
                .font(.subheadline)
                .foregroundStyle(Brand.Colors.text)
            // Outdated only: a missing plugin is installed from Host detail's
            // copy command, never in one tap.
            if transcript.availability == .pluginOutdated, let pluginUpdate {
                Button("Update Waycar on \(agent.hostName)…", systemImage: "arrow.down.circle") {
                    pluginUpdate(agent.hostID)
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.Colors.chatUser)
                .disabled(isUpdatingPlugin)
                .accessibilityHint(isUpdatingPlugin ? "An update is already running on this Host" : "")
            }
            HStack(spacing: 8) {
                Text(WaycarPluginRequirement.installCommand)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Brand.Colors.termText)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Button("Copy", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = WaycarPluginRequirement.installCommand
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Copy install command")
            }
            .padding(10)
            .background(
                Brand.Colors.ink,
                in: RoundedRectangle(cornerRadius: Brand.Radius.keycap, style: .continuous))
            if agent.canShowTerminal {
                Button("Show Terminal", systemImage: "terminal", action: onShowTerminal)
                    .buttonStyle(.bordered)
                    .tint(Brand.Colors.violetSoft)
            }
        }
        .padding(14)
        .background(
            Brand.Colors.chatAgent,
            in: RoundedRectangle(cornerRadius: Brand.Radius.bubble, style: .continuous))
    }

    // MARK: Blocked

    @ViewBuilder
    private var structuredRequests: some View {
        ForEach(transcript.requests) { request in
            if case .questions(let card) = request.kind {
                ChatQuestionCardView(
                    card: card, submit: nil,
                    submitAnswers: { answers in
                        Task { await transcript.answer(request, with: .answers(answers)) }
                    },
                    answersEnabled: transcript.canAnswerRequests)
            } else {
                AgentRequestCardView(
                    request: request, canAnswer: transcript.canAnswerRequests,
                    answer: { answer in
                        Task { await transcript.answer(request, with: answer) }
                    })
            }
        }
        if transcript.requestsUnreadable || transcript.requestAnswerFailed {
            HStack {
                Text(transcript.requestAnswerFailed ? "Couldn't send the answer" : "Couldn't read the prompt")
                Button("Retry") { transcript.retryBlockedScreen() }
                    .tint(Brand.Colors.violetSoft)
            }
            .font(.footnote)
            .foregroundStyle(Brand.Colors.text2)
        } else if transcript.requests.isEmpty {
            caption("Reading the prompt…")
        }
    }

    private var blockedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Needs your OK", systemImage: "hand.raised")
                .font(.headline)
                .foregroundStyle(Brand.Colors.blocked)
            Group {
                if let screen = transcript.blockedScreen {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(screen)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Brand.Colors.termText)
                            .fixedSize(horizontal: true, vertical: true)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                } else if transcript.blockedScreenUnreadable {
                    HStack(spacing: 8) {
                        Text("Couldn't read the prompt")
                            .font(.footnote)
                            .foregroundStyle(Brand.Colors.text2)
                        Spacer(minLength: 0)
                        Button("Retry") { transcript.retryBlockedScreen() }
                            .font(.footnote.weight(.semibold))
                            .tint(Brand.Colors.violetSoft)
                    }
                    .padding(10)
                } else {
                    Text("Reading the prompt…")
                        .font(.footnote)
                        .foregroundStyle(Brand.Colors.text3)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(
                Brand.Colors.ink,
                in: RoundedRectangle(cornerRadius: Brand.Radius.keycap, style: .continuous))
            // Enter and Esc answer only a prompt on display and still on
            // screen when tapped, never one the screen read missed.
            if let queued = transcript.queuedAnswerLabel {
                HStack(spacing: 8) {
                    Label(
                        "\(queued) queued. Sends when the Host is back.",
                        systemImage: "clock")
                        .font(.footnote)
                        .foregroundStyle(Brand.Colors.text2)
                    Spacer(minLength: 0)
                    Button("Withdraw") { transcript.withdrawQueuedAnswer() }
                        .buttonStyle(.bordered)
                        .tint(Brand.Colors.text2)
                    if agent.canShowTerminal {
                        Button("Show Terminal", systemImage: "terminal", action: onShowTerminal)
                            .buttonStyle(.bordered)
                            .tint(Brand.Colors.text2)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Button("Allow") { Task { await transcript.allow() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.Colors.chatUser)
                        .disabled(!transcript.canAnswerBlocked)
                    Button("Cancel") { Task { await transcript.cancel() } }
                        .buttonStyle(.bordered)
                        .tint(Brand.Colors.text2)
                        .disabled(!transcript.canAnswerBlocked)
                    Spacer(minLength: 0)
                    if agent.canShowTerminal {
                        Button("Show Terminal", systemImage: "terminal", action: onShowTerminal)
                            .buttonStyle(.bordered)
                            .tint(Brand.Colors.text2)
                    }
                }
            }
        }
        .padding(14)
        .background(
            Brand.Colors.chatAgent,
            in: RoundedRectangle(cornerRadius: Brand.Radius.bubble, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.bubble, style: .continuous)
                .strokeBorder(Brand.Colors.blocked.opacity(0.4), lineWidth: 1))
    }
}

// MARK: - Pieces

/// One transcript message. A user's is a violet bubble; an Agent reply is
/// the media its turn showed, directly above the text, and a reply with
/// media and no text is the media alone. Equatable on the message, so an
/// unchanged row is not laid out again when anything else in the chat
/// changes (its Markdown is parsed in `body`).
struct ChatMessageRow: View, Equatable {
    let message: ChatTranscriptMessage
    let agentName: String
    let loadMedia: ChatMediaLoader
    /// Rich-card taps (Hybrid Chat); inert cards without them. Excluded
    /// from `==`: the closures are behaviourally stable per chat.
    var cardActions = ChatCardActions()

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && lhs.agentName == rhs.agentName
    }

    var body: some View {
        if let card = message.card {
            ChatTranscriptCardView(card: card, actions: cardActions)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            bubble
        }
    }

    @ViewBuilder
    private var bubble: some View {
        switch message.role {
        case .user:
            UserBubble(text: message.text)
        case .assistant:
            let isBlank = message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            VStack(alignment: .leading, spacing: 6) {
                if !message.media.isEmpty {
                    // Attached by the turn itself: a failed item keeps its
                    // tile to retry, unlike media read from the text.
                    ChatMediaView(media: message.media, load: loadMedia)
                }
                if !isBlank || message.media.isEmpty {
                    AgentBubble {
                        if isBlank {
                            Text("No reply")
                                .font(.footnote)
                                .foregroundStyle(Brand.Colors.text3)
                        } else {
                            ChatMessageText(text: message.text, loadMedia: loadMedia)
                        }
                    }
                    // Media in the text keeps its own tiles for VoiceOver.
                    .accessibilityElement(children: Self.referencesMedia(message.text) ? .contain : .combine)
                    .accessibilityLabel("\(agentName): \(isBlank ? "No reply" : message.text)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func referencesMedia(_ text: String) -> Bool {
        ChatMessageText.segments(of: text, rendersMedia: true).contains {
            if case .media = $0 { true } else { false }
        }
    }
}

/// A Composer message waiting in the Chat view (CONTEXT.md **Queued
/// Message**), one view across its states so nothing jumps: the bubble
/// stays put and dims while it has not left the phone, wearing a dashed
/// outline; the caption's glyph morphs (queued clock, sending arrow, sent
/// check, held or failed warning) and the reason and actions fade in and
/// out under it.
struct ChatPendingBubble: View {
    let message: AgentComposerStore.Message
    let canSendAnyway: Bool
    let retry: () -> Void
    let edit: () -> Void
    let cancel: () -> Void
    let sendAnyway: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            UserBubble(text: message.text, outline: outline)
                // An ordinary send has no caption: VoiceOver still learns
                // it has not arrived yet.
                .accessibilityHint(message.state == .sending && !showsCaption ? "Sending" : "")
                .opacity(bubbleOpacity)
            if showsCaption {
                caption
                    .transition(QueuedMessageMotion.detailTransition(reduceMotion: reduceMotion))
            }
            if case .held(let reason) = message.state {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Brand.Colors.text3)
                    .multilineTextAlignment(.trailing)
                    .transition(QueuedMessageMotion.detailTransition(reduceMotion: reduceMotion))
            }
            if message.isFailed || message.isWaiting {
                actions
                    .transition(QueuedMessageMotion.detailTransition(reduceMotion: reduceMotion))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .animation(QueuedMessageMotion.state(reduceMotion: reduceMotion), value: message.state)
    }

    /// Queue states always caption; a message that went out from the queue
    /// keeps its caption as "Sent" so the bubble does not shrink under it.
    private var showsCaption: Bool {
        switch message.state {
        case .failed: true
        case .delivered: message.leftQueueAt != nil
        case .queued, .held, .sending: message.isQueueRow
        }
    }

    private var caption: some View {
        HStack(spacing: 4) {
            QueuedMessageStatusIcon(state: message.state)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(statusLine(at: context.date))
                    .accessibilityLabel(
                        statusLine(at: context.date, age: AgentSummaryLine.spokenAge)
                            .replacingOccurrences(of: " · ", with: ", "))
                    .contentTransition(.opacity)
            }
            .foregroundStyle(captionTint)
        }
        .font(.caption)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if message.isFailed {
                Button("Retry", action: retry)
                    .tint(Brand.Colors.violetSoft)
            }
            if message.isHeld, canSendAnyway {
                Button("Send Anyway", action: sendAnyway)
                    .tint(Brand.Colors.violetSoft)
            }
            Button("Edit Draft", action: edit)
                .tint(Brand.Colors.violetSoft)
            if message.isWaiting {
                Button(message.isHeld ? "Delete" : "Cancel", role: .destructive, action: cancel)
                    .tint(Brand.Colors.danger)
            }
        }
        .font(.caption.weight(.semibold))
    }

    private var bubbleOpacity: Double {
        switch message.state {
        case .queued, .held: 0.55
        case .sending: 0.7
        case .delivered: 0.8
        case .failed: 1
        }
    }

    private var outline: AgentComposerStore.DeliveryState? {
        switch message.state {
        case .queued, .held: message.state
        case .sending, .delivered, .failed: nil
        }
    }

    private var captionTint: Color {
        switch message.state {
        case .held: Brand.Colors.warn
        case .failed: Brand.Colors.danger
        case .queued, .sending, .delivered: Brand.Colors.text3
        }
    }

    private func statusLine(
        at now: Date, age format: (TimeInterval) -> String = AgentSummaryLine.shortAge
    ) -> String {
        let age = format(now.timeIntervalSince(message.sentAt))
        switch message.state {
        case .queued: return "Queued · \(age)"
        case .held: return "Held · \(age)"
        case .sending: return "Sending"
        case .delivered: return "Sent"
        case .failed: return "Not delivered"
        }
    }
}

/// Right-aligned and violet. The leading spacer keeps it to roughly 80% of
/// a phone's width while short messages hug their text. A waiting message
/// wears `QueuedMessageOutline`.
private struct UserBubble: View {
    let text: String
    var outline: AgentComposerStore.DeliveryState?

    var body: some View {
        HStack {
            Spacer(minLength: 64)
            ChatMessageText(text: text, foreground: Brand.Colors.chatUserText)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    Brand.Colors.chatUser,
                    in: RoundedRectangle(cornerRadius: Brand.Radius.bubble, style: .continuous))
                .modifier(QueuedMessageOutline(state: outline, cornerRadius: Brand.Radius.bubble))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("You: \(text)")
    }
}

/// Left-aligned, raised surface.
private struct AgentBubble<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Brand.Colors.chatAgent,
                in: RoundedRectangle(cornerRadius: Brand.Radius.bubble, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Three pulsing dots in an Agent bubble, with the open turn's activity.
private struct TypingIndicator: View {
    let activity: String?
    @State private var phase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Brand.Colors.text2)
                        .frame(width: 7, height: 7)
                        .opacity(phase ? 1 : 0.3)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever()
                                .delay(Double(index) * 0.2),
                            value: phase)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                Brand.Colors.chatAgent,
                in: RoundedRectangle(cornerRadius: Brand.Radius.bubble, style: .continuous))
            if let activity, !activity.isEmpty {
                Text(activity)
                    .font(.caption)
                    .foregroundStyle(Brand.Colors.text3)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { phase = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(activity.map { "Working: \($0)" } ?? "Working")
    }
}
