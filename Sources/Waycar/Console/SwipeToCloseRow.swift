import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import os

/// The Console row's swipe-to-close, drawn by the app rather than
/// `.swipeActions`: a system swipe action snaps its row shut before its
/// action runs, so the card would flash back to full width before a pending
/// close could hold it open.
///
/// Swiping left slides the card over a red trash disc (an indigo archive box
/// for a row that archives). Tapping the disc starts the undo window without
/// moving anything: the card stays where the swipe left it, the glyph turns
/// into an undo arrow, and the color drains clockwise to nothing, then the
/// row closes. Tapping the disc or the card undoes and slides the card home.
struct SwipeToCloseRow: ViewModifier {
    let pending: ConsoleStore.PendingTabClose?
    let agentName: String
    let closesWorkspace: Bool
    /// Whether a sent Close has already taken the row, which lingers only to
    /// lift away: it no longer swipes, selects, or offers Close.
    let isDeparting: Bool
    /// Whether the swipe is open with nothing pending; one row at a time.
    @Binding var isOpen: Bool
    let close: () -> Void
    let undo: () -> Void
    /// Off in Selection Mode: the row neither swipes nor offers Close, while
    /// a close already pending keeps its disc and undo.
    var isEnabled = true
    /// Off for a close started with others in Selection Mode, whose single
    /// announcement covers every row; a row's own countdown stays silent.
    var announcesCountdown = true
    /// The row archives its session rather than closing a tab (an OpenCode
    /// session, card 1530 1a): the disc says **Archive**, with an archive
    /// box on system indigo, as Mail's Archive (card 1611 1), since Archive
    /// is undone from Closed Sessions and red stays for what is gone.
    var archives = false

    /// How far the card slides to uncover the disc.
    static let revealWidth: CGFloat = 72
    static let discSize: CGFloat = 50
    /// The disc sits partly in the row's trailing inset, like the system
    /// swipe button it replaces.
    static let discCentreShift: CGFloat = 17

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// How far the live swipe has moved the card from where it rests.
    ///
    /// Driven by a UIKit pan that fails the moment a touch moves more
    /// vertically than horizontally, rather than a SwiftUI `DragGesture`: a
    /// drag gesture is a cell-level recognizer racing the List's scroll pan,
    /// and whenever it crossed its threshold first it kept the touch and the
    /// List never scrolled. A vertical drag starting on a card must always be
    /// a scroll, so the swipe never competes for one.
    @State private var dragTranslation: CGFloat = 0

    private var isHeldOpen: Bool { pending != nil || isOpen }

    private var offset: CGFloat {
        let resting: CGFloat = isHeldOpen ? -Self.revealWidth : 0
        return min(0, max(resting + dragTranslation, -Self.revealWidth * 1.5))
    }

    private var slide: Animation? {
        reduceMotion ? nil : .spring(duration: 0.35, bounce: 0)
    }

    func body(content: Content) -> some View {
        content
            .selectionDisabled(isHeldOpen || isDeparting)
            // Combined, not nested: an outer `accessibilityHidden(false)`
            // must never be able to un-hide a pending or departing card.
            .accessibilityHidden(pending != nil || isDeparting)
            .overlay {
                if isHeldOpen {
                    // Tapping the card undoes a pending close or shuts the swipe.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if pending != nil { undo() } else { isOpen = false }
                        }
                        .accessibilityHidden(true)
                }
            }
            .offset(x: offset)
            .animation(slide, value: isHeldOpen)
            .overlay(alignment: .trailing) {
                disc
                    .opacity(min(1, -offset / Self.revealWidth))
                    .animation(slide, value: pending?.phase)
                    // The card can shut with no transaction (a tap on it, a
                    // scroll); fade the disc out alongside its slide.
                    .animation(slide, value: isHeldOpen)
                    // A departing row's disc is spent: its Close already went.
                    .accessibilityHidden(isDeparting)
            }
            .gesture(
                HorizontalSwipe(
                    isEnabled: pending == nil && !isDeparting && isEnabled,
                    onChanged: { dragTranslation = $0 },
                    onEnded: { predicted in
                        let resting: CGFloat = isOpen ? -Self.revealWidth : 0
                        withAnimation(slide) {
                            isOpen = resting + predicted < -Self.revealWidth / 2
                            dragTranslation = 0
                        }
                    },
                    // Cancelled (a pending close disabling it, say): slide home, don't jump.
                    onCancelled: { withAnimation(slide) { dragTranslation = 0 } }))
            .accessibilityActions {
                if pending == nil && !isDeparting && isEnabled {
                    Button(actionTitle, action: close)
                }
            }
            .onChange(of: pending?.deadline) { _, deadline in
                // A new deadline is a new countdown; announce it once.
                guard deadline != nil, pending?.phase == .counting, announcesCountdown else { return }
                let seconds = Int(ConsoleStore.tabCloseUndoSeconds)
                UIAccessibility.post(
                    notification: .announcement,
                    argument: "\(title) for \(agentName) in \(seconds) seconds. Undo to cancel.")
            }
    }

    /// The disc while the swipe is open; the same disc, turning into the
    /// draining undo, once Close is tapped.
    private var disc: some View {
        Button {
            if pending == nil { close() } else { undo() }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    switch pending?.phase {
                    case nil:
                        Circle().fill(discColor)
                        Image(systemName: discSymbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    case .counting:
                        if let pending {
                            DrainingUndoBadge(
                                deadline: pending.deadline, size: Self.discSize,
                                color: discColor, symbol: discSymbol)
                        }
                    case .closing:
                        ProgressView()
                    }
                }
                .frame(width: Self.discSize, height: Self.discSize)
                Text(pending == nil ? actionTitle : "Undo")
                    .font(.subheadline)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .contentTransition(.opacity)
                    .opacity(pending?.phase == .closing ? 0 : 1)
            }
        }
        .buttonStyle(.borderless)
        .disabled(pending?.phase == .closing)
        .frame(width: Self.revealWidth)
        .offset(x: Self.discCentreShift)
        .accessibilityLabel(
            pending == nil ? "\(actionTitle) \(agentName)" : "Undo \(title.lowercased()) for \(agentName)")
    }

    private var actionTitle: String { archives ? "Archive" : "Close" }

    private var discColor: Color { archives ? .indigo : .red }

    private var discSymbol: String { archives ? "archivebox" : "trash" }

    private var title: String {
        if archives { return "Archiving" }
        return closesWorkspace ? "Closing workspace" : "Closing tab"
    }
}

/// The row's swipe: a pan that only ever begins for horizontal movement,
/// reporting the card's horizontal translation.
private struct HorizontalSwipe: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var onChanged: (CGFloat) -> Void
    /// Called with the translation projected a little past the release, so
    /// a flick carries the card further than where the finger let go.
    var onEnded: (_ predicted: CGFloat) -> Void
    var onCancelled: () -> Void

    func makeUIGestureRecognizer(context: Context) -> HorizontalPanGestureRecognizer {
        HorizontalPanGestureRecognizer()
    }

    func updateUIGestureRecognizer(_ recognizer: HorizontalPanGestureRecognizer, context: Context) {
        // Disabling mid-swipe cancels it, which slides the card home.
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: HorizontalPanGestureRecognizer, context: Context
    ) {
        let x = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(x)
        case .ended:
            onEnded(x + recognizer.velocity(in: recognizer.view).x * 0.15)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }
}

/// A one-finger pan that fails whenever the touch has moved a few points
/// from where it went down and that movement is at least as vertical as it
/// is horizontal, well before the List's scroll pan would begin, so it never
/// takes a scroll. The direction is judged on every move until the pan
/// begins, not once: a drag that starts a little sideways and turns
/// vertical still fails and scrolls. A tap never moves far enough to begin
/// it, so taps reach the row's buttons untouched.
///
/// A swipe never outlasts its finger. UIKit resets the List's scroll pan
/// only together with every recognizer it shares a touch's failure
/// requirements with, and this pan is one of them: both wait on the List's
/// context-menu press. A swipe left running after its finger lifted, were
/// UIKit ever to skip its `touchesEnded`, would keep the scroll pan from
/// resetting, and every later drag on the List would do nothing while taps
/// still land. So from touch-down the pan checks its touch each frame and
/// gives up the moment that touch is gone or its view leaves the window.
private final class HorizontalPanGestureRecognizer: UIPanGestureRecognizer {
    /// Movement needed before the direction is judged; under the scroll
    /// pan's own threshold of about 10 points.
    private static let directionSlop: CGFloat = 5
    private static let log = Logger(subsystem: "com.otreva.waycar", category: "SwipeToClose")

    /// The touch this sequence follows, and where it went down. Weak: a
    /// touch is not to be kept past its sequence, and a released one reads
    /// as gone.
    private weak var touch: UITouch?
    private var start: CGPoint = .zero
    /// Ticks while the pan has a touch, checking it still has its finger.
    private var watchdog: CADisplayLink?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        maximumNumberOfTouches = 1
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        // A new sequence always takes its own start: one the system dropped
        // without a reset must not leave its origin behind.
        if !hasLiveTouch, let first = touches.first {
            touch = first
            start = first.location(in: nil)
            startWatchdog()
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // Only the followed finger is judged against where it went down.
        if state == .possible, let touch, touches.contains(touch) {
            let location = touch.location(in: nil)
            let dx = abs(location.x - start.x)
            let dy = abs(location.y - start.y)
            if max(dx, dy) >= Self.directionSlop, dy >= dx {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        stopWatchdog()
        touch = nil
    }

    private var hasLiveTouch: Bool {
        guard let phase = touch?.phase else { return false }
        return phase != .ended && phase != .cancelled
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(watchTouch))
        link.add(to: .main, forMode: .common)
        watchdog = link
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    @objc private func watchTouch() {
        let prior = state
        guard prior == .possible || prior == .began || prior == .changed else {
            stopWatchdog()
            return
        }
        let inWindow = view?.window != nil
        guard !hasLiveTouch || !inWindow else { return }
        stopWatchdog()
        Self.log.notice(
            "Swipe let go of a lost touch: state \(prior.rawValue), touch phase \(self.touch?.phase.rawValue ?? -1), has view \(self.view != nil), in window \(inWindow)"
        )
        // Failed if it never began; cancelled once it did, so the card
        // slides home rather than opening on a swipe nobody finished.
        state = prior == .possible ? .failed : .cancelled
    }
}

/// Picks up where the swipe's disc left off: its glyph fades into an undo
/// arrow, then the color drains clockwise to empty at `deadline`, leaving
/// nothing behind. The glyph is white over the color and colored over the
/// drained part, so it stays legible on any background.
private struct DrainingUndoBadge: View {
    let deadline: Date
    let size: CGFloat
    let color: Color
    /// The disc's own glyph, shown before it turns into the undo arrow.
    let symbol: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsUndo = false

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : nil)) { context in
            let fraction = max(0, deadline.timeIntervalSince(context.date))
                / ConsoleStore.tabCloseUndoSeconds
            ZStack {
                glyph.foregroundStyle(color)
                PieSlice(fraction: fraction)
                    .fill(color)
                glyph.foregroundStyle(.white)
                    .mask(PieSlice(fraction: fraction).frame(width: size, height: size))
            }
            .frame(width: size, height: size)
        }
        .task {
            // Let the glyph register as the same disc before it turns.
            guard !reduceMotion else {
                showsUndo = true
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            withAnimation(.snappy) { showsUndo = true }
        }
    }

    private var glyph: some View {
        Image(systemName: showsUndo ? "arrow.uturn.backward" : symbol)
            .font(.system(size: 20, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size, height: size)
    }
}

/// A clockwise-from-12-o'clock pie covering `fraction` of the circle.
private struct PieSlice: Shape {
    var fraction: Double

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0 else { return Path() }
        guard clamped < 1 else { return Path(ellipseIn: rect) }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(
            center: center, radius: min(rect.width, rect.height) / 2,
            // The empty wedge sweeps clockwise from 12 o'clock.
            startAngle: .degrees(-90 + 360 * (1 - clamped)),
            endAngle: .degrees(270),
            clockwise: false)
        path.closeSubpath()
        return path
    }
}
