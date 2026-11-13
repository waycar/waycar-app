import SwiftUI

// MARK: - W3 Agent detail, Blocked

/// W3: status line and title, then the Blocked prompt as the iPhone read it.
/// Buttons follow `BlockedPromptClassifier.carApproval(for:)` (§6.1): `.allow`
/// gets Allow and Deny, `.hold` Deny only, `.readOnly` nothing. No mic:
/// Waycar never types into a Blocked prompt.
struct BlockedDetailView: View {
    /// The Blocked Agent.
    let agentID: WatchAgentID
    /// The watch's model.
    let store: WatchStore

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// The scroll anchor below the answer.
    private static let bottomID = "bottom"

    /// The detail, re-rendered every minute so the age moves.
    var body: some View {
        let row = store.row(agentID)
        TimelineView(.everyMinute) { context in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: WatchLayout.blockSpacing) {
                        if let row {
                            header(row, now: context.date)
                        }
                        prompt
                        Color.clear
                            .frame(height: 1)
                            .id(Self.bottomID)
                    }
                }
                .onChange(of: store.answerState(agentID)) { _, state in
                    guard Self.isSettled(state) else { return }
                    withAnimation { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
        }
        .task(id: WatchLoadKey(status: row?.status, isReachable: store.isReachable)) {
            await store.loadBlocked(agentID)
        }
        .userActivity(WatchHandoff.activityType) { activity in
            WatchHandoff.configure(activity, for: agentID, title: row?.title)
        }
    }

    // MARK: Header

    /// Status line over the title (Headline, wrapped in full), then the
    /// frozen Agent Progress bar when the Agent had an estimate.
    private func header(_ row: WatchAgentRow, now: Date) -> some View {
        let hostName = store.state?.showsHostNames == true ? row.hostName : nil
        let progress = row.progressDisplay(at: now)
        return VStack(alignment: .leading, spacing: 2) {
            StatusLineView(
                status: row.status, since: row.statusSince, hostName: hostName, now: now,
                progress: progress)
            Text(row.title)
                .font(.headline)
                .foregroundStyle(WatchBrand.Colors.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(WatchFormat.spokenTitle(row.title))
            if let progress {
                WatchProgressBar(display: progress, status: row.status)
                    .padding(.top, 2)
            }
        }
        .alwaysOnDimmed(isLuminanceReduced)
    }

    // MARK: Prompt

    /// Reading, read-only, or the command with its answer area; a failure
    /// or a prompt that is no longer there offers Reload.
    @ViewBuilder
    private var prompt: some View {
        switch store.blocked(agentID) {
        case .idle, .loading:
            WatchActivityLine(text: "Reading prompt…")
        case .failed(let message):
            note(message, color: WatchBrand.Colors.danger)
            reloadButton("Reload")
        case .loaded(.none):
            if Self.isSettled(store.answerState(agentID)) {
                answerStamp
            } else {
                Text("No longer waiting for approval.")
                    .font(.body)
                    .foregroundStyle(WatchBrand.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .alwaysOnDimmed(isLuminanceReduced)
                reloadButton("Reload")
            }
        case .loaded(let prompt?):
            switch prompt.approval {
            case .readOnly:
                Text("Answer this one on iPhone.")
                    .font(.body)
                    .foregroundStyle(WatchBrand.Colors.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .alwaysOnDimmed(isLuminanceReduced)
            case .allow, .hold:
                command(prompt)
            }
        }
    }

    /// Kicker, command card, hold reason, then the answer area.
    @ViewBuilder
    private func command(_ prompt: WatchBlockedPrompt) -> some View {
        Text("WANTS TO RUN")
            .metaFont(monospaced: true, trackingEm: 0.08)
            .foregroundStyle(WatchBrand.Colors.text2)
            .alwaysOnDimmed(isLuminanceReduced)
        if let command = prompt.command {
            CommandCardView(command: command)
        }
        if prompt.approval == .hold, let reason = prompt.holdReason {
            note(reason, color: WatchBrand.Colors.text2)
        }
        answerArea(prompt)
    }

    // MARK: Answer

    /// The buttons, or what became of the answer.
    @ViewBuilder
    private func answerArea(_ prompt: WatchBlockedPrompt) -> some View {
        let state = store.answerState(agentID)
        switch state {
        case .idle, .sending, .failed:
            if case .failed(let message) = state {
                note(message, color: WatchBrand.Colors.danger)
            }
            buttons(prompt, isSending: state == .sending)
        case .done, .promptChanged:
            answerStamp
        }
    }

    /// Allow (accent fill, `.allow` only) over Deny (glass, danger text),
    /// full width, below the whole command.
    private func buttons(_ prompt: WatchBlockedPrompt, isSending: Bool) -> some View {
        let enabled = !isSending && WatchAvailability.canAct(on: agentID, in: store)
        return VStack(spacing: WatchLayout.blockSpacing) {
            if prompt.approval == .allow {
                allowButton
                    .disabled(!enabled)
                    .accessibilityHint("Sends Enter to the prompt")
            }
            Button {
                Task { await store.answer(.deny, agent: agentID) }
            } label: {
                Label("Deny", systemImage: "xmark")
                    .font(.headline)
                    .foregroundStyle(WatchBrand.Colors.danger)
                    .frame(maxWidth: .infinity, minHeight: WatchLayout.capsuleHeight)
            }
            .glassCapsuleButton()
            .disabled(!enabled)
            .accessibilityHint("Sends Esc to the prompt")
        }
    }

    /// Allow: an accent-filled capsule; in Always On the fill drops to glass.
    @ViewBuilder
    private var allowButton: some View {
        let button = Button {
            Task { await store.answer(.allow, agent: agentID) }
        } label: {
            Label("Allow", systemImage: "checkmark")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: WatchLayout.capsuleHeight)
        }
        if isLuminanceReduced {
            button
                .glassCapsuleButton()
                .foregroundStyle(WatchBrand.Colors.accent)
        } else {
            button
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(WatchBrand.Colors.accent)
        }
    }

    /// "Allowed ✓ 10:10", "Denied ✓ 10:10", or the "Prompt changed. Reload."
    /// button; nothing before an answer.
    @ViewBuilder
    private var answerStamp: some View {
        switch store.answerState(agentID) {
        case .done(let answer, let at):
            let word = answer == .allow ? "Allowed" : "Denied"
            Text("\(word) ✓ \(WatchFormat.clock(at))")
                .font(.headline)
                .foregroundStyle(WatchBrand.Colors.text)
                .frame(maxWidth: .infinity, minHeight: WatchLayout.capsuleHeight)
                .alwaysOnDimmed(isLuminanceReduced)
        case .promptChanged:
            reloadButton("Prompt changed. Reload.")
        case .idle, .sending, .failed:
            EmptyView()
        }
    }

    /// A full-width glass capsule that reads the prompt again.
    private func reloadButton(_ title: String) -> some View {
        Button {
            Task { await store.loadBlocked(agentID) }
        } label: {
            Text(title)
                .font(.headline)
                .foregroundStyle(WatchBrand.Colors.accent)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: WatchLayout.capsuleHeight)
        }
        .glassCapsuleButton()
    }

    /// Whether an answer state ends the exchange (scroll to the stamp).
    static func isSettled(_ state: WatchStore.AnswerState) -> Bool {
        switch state {
        case .done, .promptChanged: true
        case .idle, .sending, .failed: false
        }
    }

    /// A wrapping Footnote 2 line.
    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .metaFont()
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .alwaysOnDimmed(isLuminanceReduced)
    }
}
