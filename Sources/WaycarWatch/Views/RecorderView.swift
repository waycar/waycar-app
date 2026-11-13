import SwiftUI

// MARK: - W4 Voice recorder

/// W4: Waycar's own recorder, no live text. ✕ cancels, the accent mic disc
/// pulses with the input level (W4a), and after speech a silence ring fills
/// over 3.5 s (W4b). Tapping the disc or a double tap stops and sends; the
/// recording goes to the iPhone, then the screen pops back to W2.
///
/// The recorder never opens for an Agent missing from the Watch State, while
/// the Agent's last message is still in flight (one per Agent), or when the
/// iPhone can't transcribe voice (W2 then offers system text input).
struct RecorderView: View {
    /// The Agent the recording goes to.
    let agentID: WatchAgentID
    /// The watch's model.
    let store: WatchStore
    /// The recorder.
    let recorder: WatchRecorder

    /// Why the recording was cancelled or never started, shown before
    /// popping; the microphone-permission reason stays until ✕.
    @State private var presentation = WatchRecorderPresentationMachine()
    private var cancelReason: String? { presentation.reason }
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long a cancellation reason stays on screen.
    private static let reasonDuration: Duration = .milliseconds(1500)
    /// Shown when a Reply route opens the recorder while the last message
    /// to this Agent still waits for its outcome.
    static let busyCopy = "Wait for the last message to finish."

    /// The recorder screen: the stack centred when it fits, else scrolled,
    /// so a long title that wraps never rides under the toolbar or pushes
    /// the hint off the bottom.
    var body: some View {
        let title = store.row(agentID)?.title ?? ""
        ViewThatFits(in: .vertical) {
            recorderStack(title: title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView {
                recorderStack(title: title)
                    .frame(maxWidth: .infinity)
            }
        }
        .alwaysOnDimmed(isLuminanceReduced)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    recorder.cancel()
                    perform(.cancel)
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(WatchBrand.Colors.text)
                }
                .glassCircleButton()
                .accessibilityLabel("Cancel")
            }
        }
        .task { await begin() }
        .onChange(of: recorder.phase) { _, phase in
            handle(phase)
        }
        .onDisappear {
            // Also abandons a start still waiting on microphone permission;
            // a no-op once the recording finished.
            recorder.cancel()
            perform(.disappear)
        }
    }

    /// "To" the Agent's title (wrapped in full), the disc, then the hint.
    private func recorderStack(title: String) -> some View {
        VStack(spacing: WatchLayout.blockSpacing) {
            Text("To \(title)")
                .font(.footnote)
                .foregroundStyle(WatchBrand.Colors.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("To \(WatchFormat.spokenTitle(title))")
            Spacer(minLength: 0)
            stopButton
            Spacer(minLength: 0)
            Text(hint)
                .metaFont()
                .foregroundStyle(cancelReason == nil ? WatchBrand.Colors.text2 : WatchBrand.Colors.danger)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Disc

    /// The mic disc; a tap or double tap stops and sends.
    private var stopButton: some View {
        Button {
            recorder.stop()
        } label: {
            disc
        }
        .buttonStyle(.plain)
        .handGestureShortcut(.primaryAction)
        .disabled(!isRecording)
        .accessibilityLabel("Send")
    }

    /// Level rings (listening) or the silence ring (paused) around the disc.
    private var disc: some View {
        let diameter = WatchLayout.recorderDisc
        let level = isLuminanceReduced || reduceMotion ? 0 : min(max(recorder.level, 0), 1)
        return ZStack {
            switch recorder.phase {
            case .listening:
                if !isLuminanceReduced {
                    Circle()
                        .fill(WatchBrand.Colors.accent.opacity(0.18))
                        .frame(width: diameter + 8 + 28 * level, height: diameter + 8 + 28 * level)
                    Circle()
                        .stroke(WatchBrand.Colors.accent.opacity(0.35), lineWidth: 2)
                        .frame(width: diameter + 4 + 16 * level, height: diameter + 4 + 16 * level)
                }
            case .paused(let progress):
                Circle()
                    .stroke(WatchBrand.Colors.text2.opacity(0.25), lineWidth: 4)
                    .frame(width: diameter + 14, height: diameter + 14)
                Circle()
                    .trim(from: 0, to: min(max(progress, 0), 1))
                    .stroke(WatchBrand.Colors.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: diameter + 14, height: diameter + 14)
            case .idle, .requestingPermission, .finished, .cancelled:
                EmptyView()
            }
            if isLuminanceReduced {
                Circle()
                    .strokeBorder(WatchBrand.Colors.accent, lineWidth: 2)
                    .frame(width: diameter, height: diameter)
            } else {
                Circle()
                    .fill(WatchBrand.Colors.accent)
                    .frame(width: diameter, height: diameter)
            }
            Image(systemName: "mic.fill")
                .font(.system(size: diameter * 0.4, weight: .semibold))
                .foregroundStyle(isLuminanceReduced ? WatchBrand.Colors.accent : WatchBrand.Colors.text)
        }
        .frame(width: diameter + 40, height: diameter + 40)
        .animation(.easeOut(duration: 0.1), value: level)
        .contentShape(Circle())
    }

    // MARK: State

    /// The line under the disc.
    private var hint: String {
        if let cancelReason { return cancelReason }
        if case .paused = recorder.phase { return "Sends when the ring fills" }
        return "Tap or double-tap to send"
    }

    /// Whether the microphone is open.
    private var isRecording: Bool {
        switch recorder.phase {
        case .listening, .paused: true
        case .idle, .requestingPermission, .finished, .cancelled: false
        }
    }

    /// Starts recording unless the Agent is gone, the iPhone can't
    /// transcribe voice, or the Agent's last message is still in flight.
    private func begin() async {
        let availability: WatchRecorderPresentationMachine.Availability
        if store.state == nil { availability = .unknown }
        else if store.row(agentID) == nil { availability = .missing }
        else if !store.phoneTranscribesVoice { availability = .unsupported }
        else if store.outgoing(for: agentID)?.isInFlight == true { availability = .busy }
        else { availability = .ready }
        for effect in presentation.handle(.begin(availability, busyReason: Self.busyCopy)) {
            if case .start = effect { await recorder.start() }
            else { perform(effect) }
        }
    }

    /// Sends a finished recording and pops; pops after a cancellation,
    /// showing and announcing its reason first.
    private func handle(_ phase: WatchRecorder.Phase) {
        switch phase {
        case .listening: perform(.listening)
        case .paused, .idle, .requestingPermission: break
        case .finished(let url, let duration): perform(.finished(url, duration: duration))
        case .cancelled(let reason): perform(.cancelled(reason, stays: reason == WatchRecorder.permissionCopy))
        }
    }

    /// Consume the presentation transition before announcing or navigating.
    private func perform(_ event: WatchRecorderPresentationMachine.Event) {
        for effect in presentation.handle(event) { perform(effect) }
    }

    private func perform(_ effect: WatchRecorderPresentationMachine.Effect) {
        switch effect {
        case .start: break // Only begin emits start, and awaits it in the view task.
        case .announce(let reason): AccessibilityNotification.Announcement(reason).post()
        case .send(let url, let duration): store.sendVoice(recordingAt: url, duration: duration, to: agentID)
        case .dismiss(let detail):
            if detail { returnToDetail() } else { popRecorder() }
        case .armReason(let token):
            Task {
                try? await Task.sleep(for: Self.reasonDuration)
                guard !Task.isCancelled else { return }
                perform(.reasonElapsed(token))
            }
        }
    }

    /// Pops only the recorder, for an Agent no longer in the Watch State.
    private func popRecorder() {
        guard store.route.last == .recorder(agentID) else { return }
        store.route.removeLast()
    }

    /// Pops the recorder and makes sure W2 for this Agent is underneath, so
    /// the sent state (W5a, W5) shows even after a notification opened W4
    /// directly.
    private func returnToDetail() {
        guard store.route.last == .recorder(agentID) else { return }
        store.route.removeLast()
        if store.route.last != .agent(agentID) {
            store.route.append(.agent(agentID))
        }
    }
}
