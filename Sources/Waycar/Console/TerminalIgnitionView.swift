import SwiftUI
import os

/// Ignition (#96): the moment an Agent's terminal comes up. Cold (nothing
/// painted yet), a curtain in the theme's background with one faint dot
/// per terminal cell, a light band drifting across them, and the Agent's
/// identity. Warm (a kept frame, #21), the frame stays readable under a
/// light veil and a slow sweep. Either way the first paint lands as a
/// wavefront from the cursor that hands each cell to the live terminal.
/// Reduce Motion keeps the dots and the veil still, with no band or sweep,
/// and the reveal is a plain crossfade.
///
/// It owns the kept frame's rendering so the copy can outlive
/// `TerminalLastFrame` dropping it on that first paint, through the reveal.
struct TerminalIgnitionView: View {
    /// The status the terminal would present, nil when it presents none
    /// (live, stopped, or released to another window).
    let presentation: TerminalStatusPresentation?
    let isLive: Bool
    /// Whether a painted frame stands under the wait (#21).
    let isWarm: Bool
    let snapshot: TerminalLastFrame.Snapshot?
    let palette: TerminalThemePalette
    let identity: TerminalIgnitionIdentity
    let flavor: TerminalSessionFlavor
    let fontSize: CGFloat
    /// The terminal surface, read for its grid and cursor. The control, not
    /// the surface: the loader must never keep an outgoing surface alive (#242).
    let surface: TerminalKeyboardControl

    private static let log = Logger(subsystem: "com.otreva.waycar", category: "TerminalIgnition")
    /// The frame rate while waiting: the band and the sweep drift slowly.
    /// The reveal runs at the display's rate.
    private static let waitingFrameInterval: TimeInterval = 1.0 / 30

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// On iPad the open list covers the Agent; a covered loader holds still.
    @Environment(\.consoleDetailIsCovered) private var isCovered
    @State private var lifecycle = TerminalIgnitionLifecycle()
    /// Warm or cold, latched while waiting so a reveal keeps its look after
    /// the kept frame stops counting.
    @State private var warm = false
    /// The last Host condition seen while waiting, held through a reveal or
    /// a freeze so the slow line keeps its words while it fades.
    @State private var heldCondition: TerminalStatusPresentation?
    @State private var heldSnapshot: TerminalLastFrame.Snapshot?
    /// The loader's origin in window coordinates, to place the grid.
    @State private var globalOrigin: CGPoint = .zero
    @State private var revealOrigin: CGPoint?
    /// The approximate grid's cell, measured once per font size.
    @State private var fallbackCell: CGSize = .zero
    /// Under Reduce Motion, set once the fade-in is over: nothing moves
    /// until the reveal, so the frame clock drops to once a second.
    @State private var isStill = false
    @State private var hapticTrigger = 0
    @State private var hapticSpent = false

    private var signal: TerminalIgnitionSignal {
        TerminalIgnitionSignal(presentation: presentation, isLive: isLive)
    }

    private var isWaiting: Bool {
        if case .waiting = lifecycle.phase { true } else { false }
    }

    private var rendersScene: Bool {
        switch lifecycle.phase {
        case .waiting, .revealing: true
        // ponytail: a warm failure unmounts the loader instead of freezing
        // it, as the status dialog discards the kept frame anyway; ceiling:
        // the veil blinks out under the dialog; upgrade: freeze the veil
        // over the dialog's dim if that ever reads as a flash.
        case .frozen: !warm
        case .hidden, .done: false
        }
    }

    /// A Host condition that the wait is on, rather than the plain attach.
    /// Only while waiting: a failure's own dialog says it once frozen.
    private var condition: TerminalStatusPresentation? {
        guard isWaiting, let presentation, presentation != .connecting else { return nil }
        return presentation
    }

    /// The frame clock: once a second when nothing moves (still under
    /// Reduce Motion, or frozen under a failure, so a resize still redraws
    /// the grid), throttled while waiting, full rate for the reveal.
    private var frameInterval: TimeInterval? {
        if isStill || lifecycle.frozenAt != nil { return 1 }
        return isWaiting ? Self.waitingFrameInterval : nil
    }

    var body: some View {
        Color.clear
            .overlay {
                if rendersScene {
                    TimelineView(
                        .animation(
                            minimumInterval: frameInterval,
                            paused: isCovered)
                    ) { context in
                        GeometryReader { proxy in
                            // A freeze draws its own moment. A paused
                            // timeline keeps the date it last delivered,
                            // which may sit inside the fade-in.
                            scene(
                                at: lifecycle.frozenAt ?? (isCovered ? Date() : context.date),
                                size: proxy.size)
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenLabel)
            .accessibilityValue(condition?.message ?? "")
            .accessibilityAddTraits(.updatesFrequently)
            .accessibilityIdentifier(
                isWaiting && warm && presentation == .connecting ? "terminal.reconnecting" : "")
            .accessibilityHidden(!isWaiting)
            .allowsHitTesting(false)
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: {
                globalOrigin = $0
            }
            .onChange(of: fontSize, initial: true) { _, fontSize in
                fallbackCell = TerminalIgnitionGrid.approximateCell(fontSize: fontSize)
            }
            .onChange(of: signal, initial: true) { _, signal in handle(signal) }
            .onChange(of: isWarm) { _, isWarm in
                if signal == .waiting { warm = isWarm }
            }
            // A new wait reads its condition here too: entering `.waiting`
            // always changes the presentation.
            .onChange(of: presentation, initial: true) { _, presentation in
                guard signal == .waiting else { return }
                heldCondition = presentation == .connecting ? nil : presentation
            }
            .onChange(of: snapshot.map { ObjectIdentifier($0.view) }, initial: true) {
                if let snapshot {
                    heldSnapshot = snapshot
                } else if signal != .live {
                    heldSnapshot = nil
                }
            }
            .onChange(of: lifecycle.phase) { _, phase in
                if phase == .done || phase == .hidden {
                    heldSnapshot = nil
                    revealOrigin = nil
                    heldCondition = nil
                }
            }
            .task(id: lifecycle.phase) { await follow(lifecycle.phase) }
            .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: hapticTrigger)
    }

    /// Only while waiting: the reveal and a freeze are not waits VoiceOver
    /// should hear about.
    private var spokenLabel: String {
        guard isWaiting, let presentation else { return "" }
        if let condition { return condition.title }
        return warm ? "Reconnecting" : presentation.title
    }

    private func handle(_ signal: TerminalIgnitionSignal) {
        let now = Date()
        lifecycle.revealDuration = reduceMotion ? 0.2 : 0.38
        switch signal {
        case .waiting:
            // A warm failure unmounted the loader (`rendersScene`), so its
            // reattach waits out the grace like any other.
            if warm, lifecycle.frozenAt != nil { lifecycle.reset() }
            // A new wait starts from the frame it has now, never from one a
            // previous reconnect left behind.
            if !isWaiting { heldSnapshot = snapshot }
            warm = isWarm
            lifecycle.connect(at: now)
        case .live:
            guard let since = lifecycle.paint(at: now) else { return }
            // ponytail: measured from when Ignition saw the wait, not from
            // the attach request; ceiling: misses whatever ran before the
            // loader mounted (a retention swap, a size wait); upgrade: stamp
            // the wait in `AgentAttachStore` if the numbers ever matter.
            let elapsed = Int(now.timeIntervalSince(since) * 1000)
            Self.log.info(
                "Attach first paint after \(elapsed) ms, \(warm ? "warm" : "cold", privacy: .public), \(flavor.rawValue, privacy: .public)"
            )
        case .failed:
            lifecycle.fail(at: now)
        case .idle:
            lifecycle.reset()
        }
    }

    /// Timed work for each phase: Reduce Motion's stop after the fade-in,
    /// and the reveal's start and end.
    private func follow(_ phase: TerminalIgnitionLifecycle.Phase) async {
        isStill = false
        switch phase {
        case .waiting(_, let visibleAt):
            guard reduceMotion else { return }
            let faded = visibleAt.addingTimeInterval(TerminalIgnitionLifecycle.fadeIn)
            try? await Task.sleep(for: .seconds(max(0, faded.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            isStill = true
        case .revealing(let start, _, _):
            try? await Task.sleep(for: .seconds(max(0, start.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            // Read once the surface has drawn, so the cursor is where the
            // first frame put it.
            revealOrigin = surface.terminal?.ignitionCursor.map {
                CGPoint(x: $0.x - globalOrigin.x, y: $0.y - globalOrigin.y)
            }
            if identity.isLaunch, !warm, !hapticSpent {
                hapticSpent = true
                hapticTrigger += 1
            }
            try? await Task.sleep(for: .seconds(lifecycle.revealDuration + 0.02))
            lifecycle.tick(at: Date())
        case .hidden, .done, .frozen:
            return
        }
    }

    // MARK: Scene

    @ViewBuilder
    private func scene(at now: Date, size: CGSize) -> some View {
        let fade = lifecycle.opacity(at: now)
        let progress = lifecycle.revealProgress(at: now)
        // Reduce Motion: no wavefront, the reveal is a plain crossfade from
        // wherever the fade-in had got to.
        let wave = reduceMotion ? nil : progress.map { wavefront(progress: $0, in: size) }
        let crossfade = reduceMotion ? 1 - (progress ?? 0) : 1
        if warm {
            warmScene(at: now, fade: fade, wave: wave)
                .opacity(crossfade)
        } else if fade > 0 {
            coldScene(at: now, size: size, wave: wave, textFade: 1 - min(1, (progress ?? 0) * 2.5))
                .opacity(fade * crossfade)
        }
    }

    /// The reveal's circle: from the cursor to the farthest corner.
    private func wavefront(progress: Double, in size: CGSize) -> IgnitionWave {
        // ponytail: bottom-leading guess where the cursor is unknown (it
        // still sits in the first cell); ceiling: a reveal that starts a
        // little off the prompt; upgrade: wait for the surface's first
        // cursor report.
        let origin = revealOrigin ?? CGPoint(x: size.width * 0.15, y: size.height * 0.85)
        let farthest = [
            CGPoint.zero, CGPoint(x: size.width, y: 0),
            CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height),
        ].map { hypot($0.x - origin.x, $0.y - origin.y) }.max() ?? 0
        return IgnitionWave(origin: origin, radius: farthest * progress, fade: 1 - progress)
    }

    private func coldScene(
        at now: Date, size: CGSize, wave: IgnitionWave?, textFade: Double
    ) -> some View {
        let grid = surface.terminal?.ignitionGrid.map { measured -> TerminalIgnitionGrid in
            var local = measured
            local.origin = CGPoint(
                x: measured.origin.x - globalOrigin.x, y: measured.origin.y - globalOrigin.y)
            return local
        } ?? .approximate(in: size, cell: fallbackCell)
        let band = IgnitionBand(
            grid: grid, palette: palette, time: now.timeIntervalSinceReferenceDate, wave: wave)
        return ZStack {
            IgnitionBaseField(grid: grid, palette: palette)
                .equatable()
                .mask {
                    if let wave {
                        Canvas { context, size in
                            context.fill(
                                wave.unrevealed(in: CGRect(origin: .zero, size: size), grid: grid),
                                with: .color(.black), style: FillStyle(eoFill: true))
                        }
                    } else {
                        Color.black
                    }
                }
            Canvas { context, size in
                if !reduceMotion { band.draw(in: &context, size: size) }
                wave?.drawGlint(in: &context, color: palette.cyan)
            }
            identityBlock(maxWidth: size.width - 32)
                .position(x: size.width / 2, y: size.height * 0.42)
                .opacity(textFade)
        }
    }

    private func warmScene(at now: Date, fade: Double, wave: IgnitionWave?) -> some View {
        let time = now.timeIntervalSinceReferenceDate
        return ZStack {
            if let heldSnapshot {
                TerminalLastFrameView(snapshot: heldSnapshot)
            }
            ZStack {
                palette.background.opacity(0.28)
                if !reduceMotion {
                    Canvas { context, size in
                        IgnitionBand.drawSweep(in: &context, size: size, time: time, palette: palette)
                    }
                }
                GeometryReader { proxy in
                    slowLine(carded: true)
                        .frame(maxWidth: max(proxy.size.width - 48, 0))
                        .position(x: proxy.size.width / 2, y: proxy.size.height * 0.42)
                }
            }
            .opacity(fade)
        }
        .mask {
            Canvas { context, size in
                var visible = Path(CGRect(origin: .zero, size: size))
                if let wave { visible.addEllipse(in: wave.rect) }
                context.fill(visible, with: .color(.black), style: FillStyle(eoFill: true))
            }
        }
        .overlay {
            if let wave {
                Canvas { context, _ in wave.drawGlint(in: &context, color: palette.cyan) }
            }
        }
    }

    private func identityBlock(maxWidth: CGFloat) -> some View {
        VStack(spacing: 6) {
            Text(identity.title)
                .font(Brand.Fonts.title)
                .tracking(Brand.Tracking.title)
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if !identity.caption.isEmpty {
                caption(identity.caption)
            }
            if let step = identity.launchStep {
                caption(step)
            }
            slowLine(carded: false)
                .padding(.top, 10)
        }
        .padding(.horizontal, 44)
        .padding(.vertical, 36)
        // A soft clearing in the dot field, so the copy reads on its own.
        .background {
            EllipticalGradient(
                stops: [
                    .init(color: palette.background, location: 0),
                    .init(color: palette.background, location: 0.5),
                    .init(color: palette.background.opacity(0), location: 1),
                ],
                center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
        }
        .frame(maxWidth: max(maxWidth, 0))
    }

    /// An identity line: one line, truncated in the middle so both ends of
    /// a host or path stay readable.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Brand.Fonts.caption)
            .foregroundStyle(palette.foreground.opacity(0.7))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    /// What the wait is on, once it is long enough to say: a Host condition
    /// in its own words, else the plain attach and how long it has taken.
    /// Its own once-a-second clock, so it ticks while the scene holds still.
    /// `carded` sets it on its own card (over a kept frame), which shows
    /// and hides with the text.
    private func slowLine(carded: Bool) -> some View {
        TimelineView(.periodic(from: lifecycle.waitStart ?? .now, by: 1)) { context in
            let waited = lifecycle.waited(at: context.date) ?? 0
            // A reveal keeps the count it ended on while the line fades out.
            let shows =
                lifecycle.waitStart != nil && waited >= TerminalIgnitionLifecycle.slowLineDelay
            let card = RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous)
            VStack(spacing: 2) {
                if let condition = heldCondition {
                    slowText(condition.title, opacity: 1)
                    if let message = condition.message {
                        slowText(message, opacity: 0.7)
                    }
                } else {
                    // One line, so a new digit never re-wraps it.
                    slowText(
                        "\(warm ? "Reconnecting" : "Connecting") to \(identity.hostName) · \(Int(waited))s",
                        opacity: 0.7
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, carded ? 14 : 0)
            .padding(.vertical, carded ? 8 : 0)
            .background(palette.background.opacity(carded ? 0.85 : 0), in: card)
            .overlay { card.strokeBorder(palette.foreground.opacity(carded ? 0.12 : 0)) }
            .opacity(shows ? 1 : 0)
            .animation(.easeOut(duration: 0.4), value: shows)
        }
    }

    /// A slow-line line, wrapped in full rather than cut: a Host condition's
    /// message is the one thing that says what to do.
    private func slowText(_ text: String, opacity: Double) -> some View {
        Text(text)
            .font(Brand.Fonts.caption)
            .foregroundStyle(palette.foreground.opacity(opacity))
            .fixedSize(horizontal: false, vertical: true)
    }
}
