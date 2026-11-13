import SwiftUI

/// Chat Mode's input row: a growing message field on the Composer draft, the
/// Dictation mic, and Send, under the Composer Tray's added images and files.
/// Return sends with a hardware keyboard attached and breaks the line without
/// one. ChatAgentView pins it above the keyboard.
struct ChatInputBar: View {
    let composer: AgentComposerStore
    /// Focuses the field shortly after appearing, once the push settles.
    var focusOnAppear = false
    /// The empty field's prompt; Ultimate chats steer ("Steer or answer…").
    var placeholder = "Message"
    /// Non-nil while a run can be stopped: with the draft empty, Send
    /// becomes Stop. Typing brings Send back, so steering stays one tap.
    var stop: (() async -> Void)? = nil
    @State private var isStopping = false

    /// Owned per input bar, like the Composer's; the engine is app-wide.
    @State private var dictation = DictationStore()
    @State private var isFocused = false
    @Environment(\.scenePhase) private var scenePhase

    /// The mic and Send frames, and the one-line height of the field and the
    /// listening row, so the three sit centered on one line.
    private static let rowHeight: CGFloat = 44

    var body: some View {
        VStack(spacing: 6) {
            if showsDictation, let failure = dictation.failure {
                DictationFailureRow(
                    failure: failure,
                    dismiss: { dictation.dismissFailure() })
            }
            ComposerTrayView(tray: composer.tray)
            HStack(alignment: .bottom, spacing: 8) {
                if showsDictation, dictation.isActive {
                    listeningRow
                        .transition(.opacity)
                } else {
                    ChatMessageField(
                        text: composer.draft,
                        selectedRange: composer.draftSelection,
                        onEdit: { composer.applyEditorDraft($0, selection: $1) },
                        isFocused: $isFocused,
                        onReturn: {
                            guard canSend else { return }
                            Task { await sendDraft() }
                        },
                        onPasteAttachments: { composer.acceptDrop($0) })
                        .overlay(alignment: .topLeading) {
                            if composer.draft.isEmpty {
                                Text(placeholder)
                                    .foregroundStyle(Brand.Colors.text3)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        // The row aligns bottoms so the buttons stay by the last
                        // line as the field grows; a one-line field as tall as
                        // their 44pt frames keeps all three centered.
                        .frame(minHeight: Self.rowHeight)
                        .background(
                            Brand.Colors.surface3,
                            in: RoundedRectangle(cornerRadius: Brand.Radius.bubble, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Brand.Radius.bubble, style: .continuous)
                                .strokeBorder(Brand.Colors.line, lineWidth: 1))
                        .transition(.opacity)
                }

                if showsDictation {
                    DictationMicButton(
                        phase: dictation.phase,
                        idleTint: Brand.Colors.text2,
                        action: toggleDictation)
                    .disabled(dictation.isBlockedByOtherSession)
                }

                if let stop, !canSend {
                    Button {
                        guard !isStopping else { return }
                        isStopping = true
                        Task {
                            await stop()
                            isStopping = false
                        }
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Brand.Colors.danger.opacity(isStopping ? 0.5 : 1))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .frame(minWidth: Self.rowHeight, minHeight: Self.rowHeight)
                    .disabled(isStopping)
                    .accessibilityLabel("Stop")
                    .accessibilityHint("Stops the current run; queued messages stay")
                } else {
                    Button {
                        Task { await sendDraft() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(canSend ? Brand.Colors.violetSoft : Brand.Colors.text3)
                    }
                    .frame(minWidth: Self.rowHeight, minHeight: Self.rowHeight)
                    .disabled(!canSend)
                    .accessibilityLabel("Send")
                    .accessibilityHint(composer.sendAccessibilityHint)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: dictation.isActive)
            // Why Send is off, in sight: the Send hint carries it for VoiceOver.
            if composer.isWaitingOnTray {
                Text(composer.sendAccessibilityHint)
                    .font(.footnote)
                    .foregroundStyle(Brand.Colors.text2)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Brand.Colors.bg)
        // Keyed on the flag: the detail may decide it just after this appears.
        .task(id: focusOnAppear) {
            guard focusOnAppear else { return }
            // After the push transition, or the keyboard animates mid-push.
            try? await Task.sleep(for: .seconds(0.35))
            // Dictation took the field's place meanwhile: focusing a field
            // that is gone would raise the keyboard when it comes back.
            guard !Task.isCancelled, !dictation.isActive else { return }
            isFocused = true
        }
        .onDisappear {
            // Never leave the microphone live behind another screen.
            dictation.cancel()
        }
        .onChange(of: ObjectIdentifier(composer)) { _, _ in
            dictation.cancel()
            dictation.dismissFailure()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                dictation.stop()
            }
        }
    }

    /// Speech still in the microphone counts as a draft, as in the Composer.
    private var canSend: Bool {
        composer.canSend || (dictation.holdsSpeech && !composer.isWaitingOnTray)
    }

    private var showsDictation: Bool {
        dictation.isAvailable && composer.deliversToAgent
    }

    /// While listening the field collapses into the red waveform, the size of
    /// a one-line field; tapping it stops, as the mic does. Dictation puts
    /// the words in the draft, so the field returns holding them.
    private var listeningRow: some View {
        Button {
            dictation.stop()
        } label: {
            // A hidden line of the field's text sets the height, so the bar
            // keeps its size; the waveform fills that line.
            Text("Message")
                .hidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    if case .downloadingModel(let fraction) = dictation.phase {
                        Text("Downloading speech model… \(Int((fraction * 100).rounded()))%")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        DictationWaveform(dictation: dictation, tint: .red)
                            .accessibilityElement()
                            .accessibilityLabel("Listening")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                .background(
                    Brand.Colors.surface3,
                    in: RoundedRectangle(cornerRadius: Brand.Radius.bubble, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.Radius.bubble, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.4), lineWidth: 1))
                .contentShape(RoundedRectangle(cornerRadius: Brand.Radius.bubble, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Stops listening")
    }

    private func toggleDictation() {
        if dictation.isActive {
            dictation.stop()
        } else {
            dictation.start(into: composer)
        }
    }

    /// Send waits for Dictation's last words so the message leaves whole.
    private func sendDraft() async {
        await dictation.finish()
        await composer.send()
    }
}
