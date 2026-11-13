import SwiftUI

/// Motion shared by every Queued Message surface (CONTEXT.md **Queued
/// Message**): the Composer's rows, the Chat view's bubbles and the Console
/// row badge. DESIGN.md defines no motion tokens, so these follow the app's
/// own conventions (`.snappy` for state, a light spring for arrival), and
/// Reduce Motion swaps every move, scale and pulse for a crossfade.
enum QueuedMessageMotion {
    /// A message settling in: a light spring, or a plain fade.
    static func arrival(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.42, bounce: 0.22)
    }

    /// Queued, sending, delivered, held, failed: one state to the next.
    static func state(reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.28)
    }

    /// How a row or bubble enters and leaves: it rises in slightly scaled
    /// down from its trailing (bubble) or leading (row) edge, and lifts out.
    static func transition(reduceMotion: Bool, anchor: UnitPoint) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.92, anchor: anchor))
                .combined(with: .offset(y: 8)),
            removal: .opacity.combined(with: .scale(scale: 0.96, anchor: anchor)))
    }

    /// Captions and action rows that come and go inside a stable bubble.
    static func detailTransition(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}

/// A Queued Message's state glyph. One view across the states, so a change
/// morphs the symbol in place (`.replace`) instead of swapping views; a
/// queued clock pulses gently while it waits, and is still under Reduce
/// Motion, where every change is a crossfade.
struct QueuedMessageStatusIcon: View {
    let state: AgentComposerStore.DeliveryState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: Self.symbol(for: state))
            .contentTransition(
                reduceMotion ? .opacity : .symbolEffect(.replace.downUp.byLayer))
            .symbolEffect(
                .pulse.byLayer, options: .repeating,
                isActive: !reduceMotion && state == .queued)
            .foregroundStyle(Self.tint(for: state))
            .animation(QueuedMessageMotion.state(reduceMotion: reduceMotion), value: state)
            .accessibilityHidden(true)
    }

    static func symbol(for state: AgentComposerStore.DeliveryState) -> String {
        switch state {
        case .queued: "clock"
        case .sending: "arrow.up.circle"
        case .delivered: "checkmark.circle"
        case .held: "exclamationmark.triangle"
        case .failed: "exclamationmark.circle"
        }
    }

    /// Held waits on the user and failed is an error; queued, sending and
    /// delivered are ordinary progress.
    static func tint(for state: AgentComposerStore.DeliveryState) -> Color {
        switch state {
        case .held: Brand.Colors.warn
        case .failed: Brand.Colors.danger
        case .queued, .sending, .delivered: Color.secondary
        }
    }
}

/// The outline a waiting message wears: a dashed hairline while it is
/// queued (it has not left the phone), solid once it is going out, and the
/// warning or error tint when it is held or failed. nil draws none.
struct QueuedMessageOutline: ViewModifier {
    let state: AgentComposerStore.DeliveryState?
    var cornerRadius: CGFloat = Brand.Radius.controlLg

    func body(content: Content) -> some View {
        content.overlay {
            if let state {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Self.stroke(for: state),
                        style: StrokeStyle(lineWidth: 1, dash: state == .queued ? [4, 3] : []))
                    .transition(.opacity)
            }
        }
    }

    private static func stroke(for state: AgentComposerStore.DeliveryState) -> Color {
        switch state {
        case .held: Brand.Colors.warn.opacity(0.7)
        case .failed: Brand.Colors.danger.opacity(0.7)
        case .queued, .sending, .delivered: Color.secondary.opacity(0.45)
        }
    }
}
