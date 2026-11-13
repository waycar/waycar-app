import SwiftUI

/// What the toolbar's connection dot says about the terminal's attach.
///
/// A dropped attach used to cover the screen with a dimmed dialog, so the
/// scrollback could no longer be read. The terminal now stays as it was and
/// this passive dot carries the state; its popover holds the reason and the
/// way back.
enum TerminalConnectionIndicator: Equatable {
    /// The attach is up.
    case live
    /// The attach is coming up again, or (`isStalled`) is up but its Host
    /// has gone quiet. `message` is the Host's condition when it has one.
    case reconnecting(message: String?, isStalled: Bool)
    /// The attach ended; `canUseSSH` when it failed on mosh, which SSH can
    /// stand in for.
    case detached(message: String?, canUseSSH: Bool)
    /// The Host cannot be reached until the user acts: no terminal action
    /// helps, so the popover offers none.
    case hostUnavailable(title: String, message: String?)

    /// Nil where no dot belongs: the terminal lives in another window (its
    /// own dialog speaks), or the attach is stopped.
    ///
    /// `isStalled` counts only while the scene is active, as the
    /// Reconnecting pill does.
    init?(
        status: AttachTerminalStore.Status,
        presentation: TerminalStatusPresentation?,
        isStalled: Bool,
        isSceneActive: Bool,
        endedWithMoshFailure: Bool,
        liveInAnotherWindow: Bool
    ) {
        guard !liveInAnotherWindow else { return nil }
        if let presentation {
            switch presentation.kind {
            case .connecting:
                self = .reconnecting(message: presentation.message, isStalled: false)
            case .ended:
                self = .detached(message: presentation.message, canUseSSH: endedWithMoshFailure)
            case .hostUnavailable:
                self = .hostUnavailable(title: presentation.title, message: presentation.message)
            }
            return
        }
        guard status == .live else { return nil }
        self = isStalled && isSceneActive
            ? .reconnecting(message: nil, isStalled: true)
            : .live
    }

    var title: String {
        switch self {
        case .live: "Connected"
        case .reconnecting: "Reconnecting"
        case .detached: "Detached"
        case .hostUnavailable(let title, _): title
        }
    }

    var message: String? {
        switch self {
        case .live: nil
        case .reconnecting(let message, _), .detached(let message, _),
            .hostUnavailable(_, let message):
            message
        }
    }

    /// Whether keys that write to the attach's PTY can reach it. A stalled
    /// mosh session still takes them (mosh queues input until the Host
    /// answers); a terminal with no attach does not.
    var acceptsAttachKeys: Bool {
        switch self {
        case .live: true
        case .reconnecting(_, let isStalled): isStalled
        case .detached, .hostUnavailable: false
        }
    }
}

/// The dot in the Toolbar's fixed controls and the popover it opens. A dot
/// alone would be colour-only, so a detached or unavailable terminal draws a
/// different shape.
struct TerminalConnectionDot: View {
    let indicator: TerminalConnectionIndicator
    let reattach: () -> Void
    let useSSHInstead: () -> Void
    /// Opens the saved conversation; nil where none is kept.
    var readSaved: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingDetails = false
    @State private var isDimmed = false

    private var pulses: Bool {
        if case .reconnecting = indicator { !reduceMotion } else { false }
    }

    var body: some View {
        Button {
            isShowingDetails = true
        } label: {
            glyph
                .opacity(isDimmed ? 0.35 : 1)
                .frame(
                    minWidth: InputChromeLayout.minimumHitSide,
                    minHeight: InputChromeLayout.minimumHitSide)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Terminal connection: \(indicator.title)")
        .accessibilityHint("Double-tap for details")
        .accessibilityValue(indicator.message ?? "")
        .popover(isPresented: $isShowingDetails) { details }
        .onAppear { syncPulse() }
        .onChange(of: pulses) { _, _ in syncPulse() }
        .onChange(of: indicator) { old, new in
            // The terminal is not covered any more, so a detach is silent
            // unless it is announced.
            guard case .detached = new else { return }
            if case .detached = old { return }
            AccessibilityNotification.Announcement("Terminal detached").post()
        }
    }

    @ViewBuilder
    private var glyph: some View {
        switch indicator {
        case .live:
            Circle()
                .fill(Color(uiColor: AgentStatusPalette.greenInk))
                .frame(width: Self.dotSide, height: Self.dotSide)
        case .reconnecting:
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: Self.glyphSize, weight: .semibold))
                .foregroundStyle(Color(uiColor: AgentStatusPalette.yellowInk))
        case .detached:
            Image(systemName: "cable.connector.slash")
                .font(.system(size: Self.glyphSize, weight: .semibold))
                .foregroundStyle(Color(uiColor: AgentStatusPalette.redInk))
        case .hostUnavailable:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: Self.glyphSize, weight: .semibold))
                .foregroundStyle(Color(uiColor: AgentStatusPalette.mutedInk))
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(indicator.title)
                .font(.headline)
            if let message = indicator.message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if case .detached(_, let canUseSSH) = indicator {
                Button("Reattach") {
                    isShowingDetails = false
                    reattach()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
                if canUseSSH {
                    Button("Use SSH Instead") {
                        isShowingDetails = false
                        useSSHInstead()
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let readSaved {
                Button("Read saved conversation", systemImage: "text.bubble") {
                    isShowingDetails = false
                    readSaved()
                }
                .buttonStyle(.bordered)
                .padding(.top, 4)
                .accessibilityIdentifier("terminal.connection.readSaved")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 300, alignment: .leading)
        .padding()
        // A popover on iPhone too, not a sheet.
        .presentationCompactAdaptation(.popover)
    }

    /// Starts the pulse while reconnecting, otherwise settles at full
    /// opacity without animating, which also cancels the repeating one.
    private func syncPulse() {
        if pulses {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isDimmed = true
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { isDimmed = false }
        }
    }

    private static let dotSide: CGFloat = 10
    private static let glyphSize: CGFloat = 13
}
