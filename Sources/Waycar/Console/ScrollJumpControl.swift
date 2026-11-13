import SwiftUI
import UIKit

/// Which control started the jump in flight. The message-jump tab and the
/// scroll-jump button share one ``TerminalMessageJumpController`` — one walk
/// at a time over one remote viewport. The tab must know whether the walk
/// running is its own: it shows progress for its own and steps aside for the
/// button's. The button hides for either. `refs #58`.
enum AttachJumpKind: Equatable, Sendable {
    /// The edge tab: to the neighbouring user message, or back to live.
    case message
    /// The scroll-jump button: all the way to the oldest history, or to live.
    case scroll
}

/// The jump in flight: which control started it, and which way it walks.
struct AttachRunningJump: Equatable, Sendable {
    let kind: AttachJumpKind
    let direction: TerminalMessageJumpController.Direction
}

/// One run of touch scrolling in one direction, and whether it has gone far
/// enough to offer the scroll-jump button for that end of the history.
///
/// Nothing reports where the remote viewport sits, so the button cannot be
/// shown by position the way a chat app shows its jump-to-latest. It follows
/// intent instead: a run long enough to be a trip through the history, not a
/// nudge to re-read a few lines. Pure; the wiring owns the clock and the
/// timer. `refs #58`.
struct ScrollJumpRun: Equatable, Sendable {
    /// Rows one run scrolls before the button appears: past a nudge to
    /// re-read a few lines, short of one flick.
    static let rowsBeforeOffer = 12
    /// How long the button stays after the last scroll, so the thumb that
    /// was scrolling has time to reach it.
    static let linger: Duration = .seconds(3)

    private(set) var direction: TerminalMessageJumpController.Direction?
    private(set) var rows = 0
    private(set) var lastScroll: ContinuousClock.Instant?

    /// The end the button offers, or nil while the run is too short.
    var offeredDirection: TerminalMessageJumpController.Direction? {
        rows >= Self.rowsBeforeOffer ? direction : nil
    }

    /// When the run lapses; nil when there is none.
    var expiry: ContinuousClock.Instant? {
        lastScroll.map { $0 + Self.linger }
    }

    func isExpired(at instant: ContinuousClock.Instant) -> Bool {
        guard let expiry else { return true }
        return instant >= expiry
    }

    /// A touch scroll of `rows` rows. Turning around, or scrolling again
    /// after the run lapsed, starts a new run.
    mutating func note(
        _ direction: TerminalMessageJumpController.Direction,
        rows: Int,
        at instant: ContinuousClock.Instant
    ) {
        if direction != self.direction || isExpired(at: instant) {
            self = ScrollJumpRun()
            self.direction = direction
        }
        // Saturates: past the threshold the count no longer matters.
        self.rows = min(self.rows + max(rows, 0), Self.rowsBeforeOffer)
        lastScroll = instant
    }
}

/// Visibility of the scroll-jump button, as a pure function of its inputs.
/// `refs #58`.
struct ScrollJumpAvailability: Equatable, Sendable {
    /// The end the button jumps to; nil when it is hidden.
    var direction: TerminalMessageJumpController.Direction?

    var isVisible: Bool { direction != nil }

    static let hidden = Self(direction: nil)

    /// Shown only where a scroll step reaches the remote application's own
    /// history, only for an end the viewport is not already known to sit at,
    /// and never while a jump runs. A press hides the button at once: the
    /// terminal moving is all the progress there is to show, and a spinner
    /// would outlast the trip (the walk proves the end by watching the frame
    /// settle).
    ///
    /// Mouse reporting alone decides whether a step reaches that history, as
    /// it does for a drag (`applyScroll` sends wheel reports whenever it is
    /// on). The alternate screen is no test: an Agent attaches over mosh once
    /// the Host's mosh probe has passed, and the phone never sees the Agent's
    /// `?1049h` there while its mouse modes still arrive, so a scrollable
    /// Agent shows up on the primary screen (verified against mosh-server
    /// 1.4.0).
    static func evaluate(
        canScrollRemoteContent: Bool,
        reach: MessageJumpReach,
        offeredDirection: TerminalMessageJumpController.Direction?,
        runningJump: AttachRunningJump?
    ) -> Self {
        guard canScrollRemoteContent, runningJump == nil, let offeredDirection else {
            return .hidden
        }
        let hasSomewhereToGo =
            switch offeredDirection {
            case .older: reach.canJumpOlder
            case .newer: reach.canJumpNewer
            }
        return hasSomewhereToGo ? Self(direction: offeredDirection) : .hidden
    }
}

/// Where the scroll-jump tab sits: docked flush on the terminal's trailing
/// edge, a tenth of the terminal up from its bottom, where the thumb that
/// was scrolling finishes. That is inside the alternate-screen keyboard band
/// on purpose: the tab takes only its own square, and stays only
/// ``ScrollJumpRun/linger`` after the last scroll. While the message-jump
/// tab shows, it stays under that tab's
/// lowest dock (the tab never docks inside the band), sliding lower on a
/// short terminal and hiding when there is no room; over mosh that tab
/// never shows, so only the terminal's height limits it. Pure so
/// short-terminal placement is testable without a device.
/// `refs #58`, `refs #94`.
@MainActor
enum ScrollJumpPlacement {
    // ponytail: clamps on the message tab's availability, not its placement, so
    // on a terminal too short to place that tab (under ~119 pt; landscape with
    // the keyboard up, SSH not mosh) the scroll tab steps
    // aside too; upgrade: have MessageJumpChromeContainer report its placed frame.
    /// How far up the terminal the tab's bottom edge sits.
    static let bottomFraction: CGFloat = 0.1
    /// Space between the tab and the message-jump tab above it.
    static let gap: CGFloat = 8

    /// Bottom padding for the tab inside a terminal of `terminalHeight`, or nil
    /// when it fits nowhere it may sit. Callers hide the tab rather than overlap.
    static func bottomPadding(
        terminalHeight: CGFloat,
        messageJumpTabVisible: Bool = false
    ) -> CGFloat? {
        let tab = MessageJumpControlView.buttonSize
        // The highest the tab's bottom may sit: the whole tab inside the
        // terminal, and while the message-jump tab shows, under the lowest
        // point that tab docks at wherever the user left it.
        let highest = messageJumpTabVisible
            ? MessageJumpPlacement.bottomInset(terminalHeight: terminalHeight) - gap - tab
            : terminalHeight - tab
        let padding = min(terminalHeight * bottomFraction, highest)
        guard padding >= 0 else { return nil }
        return padding
    }
}

/// The edge tab a long touch scroll reveals, docked on the terminal's
/// trailing edge like the message-jump tab. One press takes the Agent's
/// terminal the rest of the way: to the beginning of its history when the
/// user was scrolling back, to live output when they were scrolling forward.
/// Drawn in the terminal's own colours. `refs #58`.
struct ScrollJumpButton: View {
    let availability: ScrollJumpAvailability
    var palette: TerminalThemePalette = .system
    let action: () -> Void

    var body: some View {
        if let direction = availability.direction {
            Button {
                // The button leaves with the press; a light tap says it landed.
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                action()
            } label: {
                Image(systemName: direction == .older ? "arrow.up.to.line" : "arrow.down.to.line")
                    .font(.system(size: 15, weight: .semibold))
                    .opacity(TerminalFloatingButtonStyle.iconOpacity)
            }
            .buttonStyle(TerminalEdgeTabButtonStyle(highlight: palette.foreground))
            .hoverEffect(.highlight)
            .background(alignment: .trailing) {
                TerminalEdgeTabBackground(palette: palette)
                    .frame(width: TerminalEdgeTabBackground.width)
            }
            .foregroundStyle(palette.foreground)
            .accessibilityLabel(direction == .older ? "Scroll to beginning" : "Scroll to end")
            .accessibilityHint(
                direction == .older
                    ? "Scrolls the Agent back to the start of its history"
                    : "Scrolls the Agent forward to live output")
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        }
    }
}
