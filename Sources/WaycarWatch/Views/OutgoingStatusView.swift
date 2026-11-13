import SwiftUI

// MARK: - You-bubble

/// The right-aligned You-bubble (W5a, W5): the sent text once the phone
/// reports it, the typed text while it travels, or a waveform and the
/// recording's length until the iPhone has transcribed it.
struct OutgoingBubbleView: View {
    /// The message.
    let outgoing: WatchOutgoing

    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// The bubble, capped at 86% of the screen width.
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        content
            .font(.caption)
            .foregroundStyle(isLuminanceReduced ? WatchBrand.Colors.text : WatchBrand.Colors.chatUserText)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                if isLuminanceReduced {
                    shape.strokeBorder(WatchBrand.Colors.chatUser, lineWidth: 1)
                } else {
                    shape.fill(WatchBrand.Colors.chatUser)
                }
            }
            .privacySensitive()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, WatchLayout.bubbleLeadingInset)
    }

    /// The words, or the voice placeholder.
    @ViewBuilder
    private var content: some View {
        if let text = Self.displayedText(of: outgoing) {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } else if case .voice(let duration) = outgoing.content {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .accessibilityHidden(true)
                Text(WatchFormat.duration(duration))
                    .monospacedDigit()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Voice message, \(WatchFormat.duration(duration))")
        }
    }

    /// What the bubble says: the phone's sent text wins; a voice message
    /// has no words before that.
    static func displayedText(of outgoing: WatchOutgoing) -> String? {
        if case .sent(let text, _) = outgoing.phase {
            return text
        }
        switch outgoing.content {
        case .text(let text): return text
        case .voice: return nil
        }
    }
}

// MARK: - Delivery status

/// The line under the You-bubble, one per `WatchOutgoing.Phase`.
struct OutgoingStatusView: View {
    /// The message.
    let outgoing: WatchOutgoing
    /// Whether the iPhone and Host can take a retry right now.
    let canAct: Bool
    /// Try again, with the same message id.
    let onRetry: () -> Void

    /// The phase's copy.
    var body: some View {
        switch outgoing.phase {
        case .sending, .delivering:
            WatchActivityLine(text: "Sending…", isMeta: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .transcribing:
            WatchActivityLine(text: "Transcribing on iPhone…", isMeta: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .sent(_, let at):
            VStack(alignment: .leading, spacing: WatchLayout.blockSpacing) {
                Text("Sent ✓ \(WatchFormat.clock(at))")
                    .metaFont()
                    .foregroundStyle(WatchBrand.Colors.text2)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                WatchActivityLine(text: "Waiting for reply", isMeta: true)
            }
        case .notSent(let reason):
            VStack(alignment: .leading, spacing: WatchLayout.blockSpacing) {
                note("Not sent — \(reason)", color: WatchBrand.Colors.danger)
                Button(action: onRetry) {
                    Text("Try again")
                        .font(.headline)
                        .foregroundStyle(WatchBrand.Colors.accent)
                        .frame(maxWidth: .infinity, minHeight: WatchLayout.capsuleHeight)
                }
                .glassCapsuleButton()
                .disabled(!(canAct && outgoing.canRetry))
            }
        case .unknown:
            note("Couldn't confirm it was delivered", color: WatchBrand.Colors.text2)
        case .keptAsDraft(let reason):
            note(Self.keptCopy(reason), color: WatchBrand.Colors.text2)
        case .noWords:
            note("Couldn't make out any words. Nothing sent.", color: WatchBrand.Colors.text2)
        }
    }

    /// W5 "Kept as draft on iPhone" line, naming what to do first.
    static func keptCopy(_ reason: WatchKeptReason) -> String {
        switch reason {
        case .blocked: "Kept as draft on iPhone — answer the prompt first"
        case .signInRequired: "Kept as draft on iPhone — sign in on the Host first"
        case .folderTrustRequired: "Kept as draft on iPhone — trust the folder on the Host first"
        }
    }

    /// A wrapping Footnote 2 line.
    private func note(_ text: String, color: Color) -> some View {
        Text(text)
            .metaFont()
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
