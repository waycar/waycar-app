import SwiftUI
import UIKit

/// Where a row beside the slide-over's sidebar toggle sits: it starts
/// `leading` points from the leading edge, clear of the toggle, and centers
/// `centerY` points below the top safe area, on the toggle's own line. The
/// list's header row takes it, and so does the Agent's top row, which the
/// toggle floats over while the list is hidden.
struct ConsoleSidebarHeaderSlot: Equatable {
    let leading: CGFloat
    let centerY: CGFloat

    /// The top padding that centers a row `rowHeight` tall, already padded
    /// by `verticalPadding` above and below, on `centerY`. Never negative: a
    /// row too tall for the toggle's line starts at the top instead.
    func topPadding(rowHeight: CGFloat, verticalPadding: CGFloat) -> CGFloat {
        max(0, centerY - verticalPadding - rowHeight / 2)
    }
}

extension EnvironmentValues {
    /// Nil outside the iPad slide-over layout, where the header keeps its
    /// own insets.
    @Entry var consoleSidebarHeaderSlot: ConsoleSidebarHeaderSlot? = nil
    /// The same slot, handed to the Agent. Nil outside the iPad slide-over
    /// layout, where no toggle floats over the Agent.
    @Entry var consoleDetailHeaderSlot: ConsoleSidebarHeaderSlot? = nil
}

/// The slide-over's arithmetic, kept apart from the view so its boundaries
/// can be tested. `progress` runs from 0 (the Agent covers the list) to 1
/// (the list is out); values outside that range are clamped.
struct ConsoleSlideOverGeometry: Equatable {
    static let toggleSize: CGFloat = 44
    /// Where the system split view's own toggle sat.
    static let toggleLeadingInset: CGFloat = 9
    static let toggleTopInset: CGFloat = 8
    static let toggleToHeaderSpacing: CGFloat = 10
    static let cornerRadius: CGFloat = 26
    /// The slide distance over which the Agent's corners, hairline and edge
    /// shadow grow in. A full radius at the first point of travel would
    /// round the corners of a closed Agent sitting against the screen edge.
    static let edgeRampDistance: CGFloat = 80
    static let edgeShadowWidth: CGFloat = 48
    static let coveredSidebarScale: CGFloat = 0.94
    static let coveredSidebarDim: Double = 0.55

    let containerWidth: CGFloat
    let sidebarWidth: CGFloat

    /// The list takes its ideal width, but never more than half a narrow
    /// window (Stage Manager, Split View) down to its minimum, and never
    /// more than the window itself.
    init(containerWidth: CGFloat, column: ConsoleSplitPresentation.ColumnWidth) {
        let width = max(0, containerWidth)
        self.containerWidth = width
        sidebarWidth = min(width, min(column.ideal, max(column.minimum, width / 2)))
    }

    /// Past any window controls in the top-leading corner.
    static func toggleLeading(windowControlsWidth: CGFloat) -> CGFloat {
        toggleLeadingInset + windowControlsWidth
    }

    static func headerSlot(windowControlsWidth: CGFloat) -> ConsoleSidebarHeaderSlot {
        ConsoleSidebarHeaderSlot(
            leading: toggleLeading(windowControlsWidth: windowControlsWidth)
                + toggleSize + toggleToHeaderSpacing,
            centerY: toggleTopInset + toggleSize / 2)
    }

    static func clamped(_ progress: CGFloat) -> CGFloat {
        min(1, max(0, progress))
    }

    func detailOffset(progress: CGFloat) -> CGFloat {
        Self.clamped(progress) * sidebarWidth
    }

    /// The Agent keeps the full width while it moves, so a slide never
    /// reflows the terminal; only at rest beside the list does it narrow to
    /// the width the list leaves.
    func detailWidth(isNarrowed: Bool) -> CGFloat {
        isNarrowed ? containerWidth - sidebarWidth : containerWidth
    }

    static func restsNarrowed(
        reveal: ConsoleSidebarReveal, isSidebarVisible: Bool, isMoving: Bool
    ) -> Bool {
        reveal == .beside && isSidebarVisible && !isMoving
    }

    /// 0 against the screen edge, 1 once the Agent has slid
    /// `edgeRampDistance` points: scales its corner radius, hairline and
    /// edge shadow.
    func edgeDepth(progress: CGFloat) -> CGFloat {
        min(1, detailOffset(progress: progress) / Self.edgeRampDistance)
    }

    func cornerRadius(progress: CGFloat) -> CGFloat {
        Self.cornerRadius * edgeDepth(progress: progress)
    }

    /// The list recedes as the Agent covers it.
    static func sidebarScale(progress: CGFloat) -> CGFloat {
        coveredSidebarScale + (1 - coveredSidebarScale) * clamped(progress)
    }

    static func sidebarDim(progress: CGFloat) -> Double {
        coveredSidebarDim * Double(1 - clamped(progress))
    }

    /// The edge shadow's darkest point. Dark mode keeps one strength; on a
    /// light list the same black reads as grime beside the open list, so it
    /// rests faint there and deepens only as the Agent covers the list.
    static func edgeShadowOpacity(progress: CGFloat, colorScheme: ColorScheme) -> Double {
        guard colorScheme == .light else { return 0.35 }
        return 0.12 + 0.13 * Double(1 - clamped(progress))
    }

    /// A drag moves the Agent from where it rested, one point per point.
    func dragProgress(fromOpen isOpen: Bool, translation: CGFloat) -> CGFloat {
        let base: CGFloat = isOpen ? 1 : 0
        guard sidebarWidth > 0 else { return base }
        return Self.clamped(base + translation / sidebarWidth)
    }

    /// `UIScrollView.DecelerationRate.normal`, per millisecond. Written out
    /// rather than read from UIKit so the geometry stays plain arithmetic.
    static let flingDeceleration: CGFloat = 0.998

    /// Where a drag let go at `velocity` points per second would coast to
    /// under a scroll view's normal deceleration (the projection from
    /// WWDC18's "Designing Fluid Interfaces"). SwiftUI's
    /// `predictedEndTranslation` looks only a quarter second ahead, which
    /// left a quick short flick short of halfway and sprang the Agent back.
    static func projectedTranslation(_ translation: CGFloat, velocity: CGFloat) -> CGFloat {
        translation + velocity / 1000 * flingDeceleration / (1 - flingDeceleration)
    }

    /// Where the fling would carry the Agent decides the side it settles
    /// on, not where the finger lifted; exactly halfway stays closed.
    func settlesOpen(fromOpen isOpen: Bool, translation: CGFloat, velocity: CGFloat) -> Bool {
        let projected = Self.projectedTranslation(translation, velocity: velocity)
        return dragProgress(fromOpen: isOpen, translation: projected) > 0.5
    }
}

/// The iPad Console (#15, ADR 0024): the Agent list lies under the Agent,
/// which slides right to reveal it and left to cover it. Landscape
/// (`.beside`) rests the Agent beside the open list; portrait (`.push`)
/// keeps its full width and pushes it partly off screen, where a tap on it
/// slides it back and focuses its terminal, and a leftward drag slides it
/// back. Either way, while the list is out a
/// swipe in from the screen's right edge slides the Agent back over it (#30).
///
/// One `progress` drives the slide and its depth: the Agent's offset,
/// rounded leading corners, hairline and edge shadow, and the list's scale
/// and dim. A drag writes it directly; everything else animates it.
///
/// The layout owns the motion; `isSidebarVisible` is the logical state and
/// `setSidebarVisible` records the user's choice. A change arriving from
/// outside (Show Agents, a portrait selection) slides like a toggle; one
/// that comes with a resize or rotation snaps, since that change carries
/// its own motion.
struct ConsoleSlideOverLayout<Sidebar: View, Detail: View>: View {
    let reveal: ConsoleSidebarReveal
    let sidebarColumn: ConsoleSplitPresentation.ColumnWidth
    let isSidebarVisible: Bool
    let setSidebarVisible: @MainActor (Bool) -> Void
    /// Built once by the caller rather than per layout update: a drag
    /// updates this view every frame, and neither the list nor the Agent
    /// screen should be rebuilt for it.
    private let sidebar: Sidebar
    private let detail: Detail

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var progress: CGFloat
    /// Up from the start of a slide or drag until it settles: the Agent
    /// keeps the full width meanwhile.
    @State private var isMoving = false
    /// Lets only the latest slide's completion end the move; a newer slide
    /// or a drag supersedes it.
    @State private var settleGeneration = 0
    /// Up only while the portrait catcher's drag is recognized. SwiftUI
    /// skips `onEnded` for a cancelled gesture but still resets this, so its
    /// fall settles a drag that would otherwise be left mid-slide.
    @GestureState private var isCatcherDragging = false
    @State private var catcherTranslation: CGFloat?
    /// Taps the portrait catcher took; the Agent focuses its terminal on each.
    @State private var detailFocusTaps = 0

    init(
        reveal: ConsoleSidebarReveal,
        sidebarColumn: ConsoleSplitPresentation.ColumnWidth,
        isSidebarVisible: Bool,
        setSidebarVisible: @escaping @MainActor (Bool) -> Void,
        @ViewBuilder sidebar: () -> Sidebar,
        @ViewBuilder detail: () -> Detail
    ) {
        self.reveal = reveal
        self.sidebarColumn = sidebarColumn
        self.isSidebarVisible = isSidebarVisible
        self.setSidebarVisible = setSidebarVisible
        self.sidebar = sidebar()
        self.detail = detail()
        _progress = State(initialValue: isSidebarVisible ? 1 : 0)
    }

    /// What the logical state is judged against: a visibility change that
    /// arrives with a new width or reveal is a rotation or resize.
    private struct Placement: Equatable {
        let isSidebarVisible: Bool
        let width: CGFloat
        let reveal: ConsoleSidebarReveal
    }

    var body: some View {
        GeometryReader { proxy in
            let geometry = ConsoleSlideOverGeometry(
                containerWidth: proxy.size.width, column: sidebarColumn)
            let controlsWidth = Self.windowControlsWidth(proxy)
            let slot = ConsoleSlideOverGeometry.headerSlot(windowControlsWidth: controlsWidth)
            ZStack(alignment: .topLeading) {
                // What the receding list uncovers at its edges.
                Color.black
                    .ignoresSafeArea()
                sidebarLayer(geometry, slot: slot)
                // Laid out in the whole window, not just drawn into it: an
                // `ignoresSafeArea()` on the Agent itself only moves its
                // content, and the clip and hairline after it would still
                // measure the safe area, cutting the terminal off under the
                // status bar and the home indicator. The Agent's navigation
                // container still takes its insets from the window. Keyboard
                // included: the terminal keeps its own keyboard inset.
                ZStack(alignment: .topLeading) {
                    edgeShadow(geometry)
                    detailLayer(geometry, slot: slot)
                }
                .ignoresSafeArea(edges: .vertical)
            }
            // On the container: the screen's right edge is the Agent's in
            // landscape and the catcher's in portrait.
            .gesture(ConsoleTrailingEdgeClose(drag: revealDrag(geometry)))
            // iPadOS has swipes of its own from that edge; while the list is
            // out the swipe is the Console's, and closed it goes back to them.
            .defersSystemGestures(on: isSidebarVisible ? .trailing : [])
            // The same spot whether the list is out or not, above both.
            .overlay(alignment: .topLeading) {
                sidebarToggle
                    .padding(
                        .leading,
                        ConsoleSlideOverGeometry.toggleLeading(windowControlsWidth: controlsWidth))
                    .padding(.top, ConsoleSlideOverGeometry.toggleTopInset)
            }
            .onChange(of: Placement(
                isSidebarVisible: isSidebarVisible, width: proxy.size.width, reveal: reveal)
            ) { old, new in
                placementChanged(from: old, to: new)
            }
            .onChange(of: isCatcherDragging) { _, dragging in
                guard !dragging, let translation = catcherTranslation else { return }
                catcherTranslation = nil
                settleDrag(fromOpen: true, translation: translation, velocity: 0, geometry: geometry)
            }
        }
    }

    /// iPadOS 26 windows draw their controls in the top-leading corner; the
    /// toggle and the header row beside it step right past them when they
    /// reach down to the toggle's line. Zero full screen.
    private static func windowControlsWidth(_ proxy: GeometryProxy) -> CGFloat {
        guard #available(iOS 26.0, *) else { return 0 }
        let corner = proxy.containerCornerInsets.topLeading
        return corner.height > ConsoleSlideOverGeometry.toggleTopInset ? corner.width : 0
    }

    private func sidebarLayer(
        _ geometry: ConsoleSlideOverGeometry, slot: ConsoleSidebarHeaderSlot
    ) -> some View {
        let isCovered = !isSidebarVisible && !isMoving
        return sidebar
            // The list and its bottom bar own the column's whole bottom
            // edge. Any region the system reserves there — the mini keyboard
            // bar a hardware keyboard leaves while the terminal types, the
            // software keyboard, the home indicator — otherwise shrank this
            // subtree and lifted the bar off the screen edge with it (#79);
            // the bar is pinned to the column's edge and nothing moves it.
            .ignoresSafeArea(.all, edges: .bottom)
            .environment(\.consoleSidebarHeaderSlot, slot)
            .environment(\.consoleListIsCovered, isCovered)
            .frame(width: geometry.sidebarWidth)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.black
                    .opacity(ConsoleSlideOverGeometry.sidebarDim(progress: progress))
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .scaleEffect(
                ConsoleSlideOverGeometry.sidebarScale(progress: progress),
                anchor: UnitPoint(x: 0.25, y: 0.5))
            .allowsHitTesting(!isCovered)
            .accessibilityHidden(isCovered)
    }

    /// Drawn as a gradient beside the Agent rather than a `.shadow()` on
    /// it: a shadow renders the terminal offscreen on every frame of the
    /// slide to find its outline.
    private func edgeShadow(_ geometry: ConsoleSlideOverGeometry) -> some View {
        LinearGradient(
            colors: [
                .clear,
                .black.opacity(ConsoleSlideOverGeometry.edgeShadowOpacity(
                    progress: progress, colorScheme: colorScheme)),
            ],
            startPoint: .leading, endPoint: .trailing)
            .frame(width: ConsoleSlideOverGeometry.edgeShadowWidth)
            .frame(maxHeight: .infinity)
            .opacity(geometry.edgeDepth(progress: progress))
            .offset(
                x: geometry.detailOffset(progress: progress)
                    - ConsoleSlideOverGeometry.edgeShadowWidth)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func detailLayer(
        _ geometry: ConsoleSlideOverGeometry, slot: ConsoleSidebarHeaderSlot
    ) -> some View {
        let radius = geometry.cornerRadius(progress: progress)
        // Portrait's list covers most of the Agent it pushed aside.
        let isCovered = reveal == .push && isSidebarVisible
        // A navigation container, as the split view's detail column was:
        // the Agent screen styles the navigation bar for status-bar contrast.
        return NavigationStack { detail }
            .environment(\.consoleSidebarRevealDrag, revealDrag(geometry))
            .environment(\.consoleDetailHeaderSlot, slot)
            .environment(\.consoleDetailIsCovered, isCovered)
            .environment(\.consoleDetailFocusTaps, detailFocusTaps)
            .frame(width: geometry.detailWidth(isNarrowed: ConsoleSlideOverGeometry.restsNarrowed(
                reveal: reveal, isSidebarVisible: isSidebarVisible, isMoving: isMoving)))
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Color(uiColor: .separator)
                    .frame(width: 1)
                    .opacity(geometry.edgeDepth(progress: progress))
                    .allowsHitTesting(false)
            }
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: radius, bottomLeadingRadius: radius, style: .continuous))
            .accessibilityHidden(isCovered)
            .overlay {
                if isCovered {
                    catcher(geometry)
                }
            }
            .offset(x: geometry.detailOffset(progress: progress))
    }

    /// Over the visible part of a pushed-aside Agent: a tap closes the list
    /// and focuses the Agent's terminal, and a leftward drag closes it under
    /// the finger. A pan from the
    /// screen's right edge starts here too; the drag is named so
    /// `ConsoleTrailingEdgeClose` can make it wait, and only one of them
    /// moves the Agent.
    private func catcher(_ geometry: ConsoleSlideOverGeometry) -> some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture {
                request(false)
                detailFocusTaps &+= 1
            }
            .gesture(
                DragGesture(minimumDistance: 10, coordinateSpace: .global)
                    .updating($isCatcherDragging) { _, dragging, _ in dragging = true }
                    .onChanged { value in
                        catcherTranslation = value.translation.width
                        follow(fromOpen: true, translation: value.translation.width, geometry: geometry)
                    }
                    .onEnded { value in
                        catcherTranslation = nil
                        settleDrag(
                            fromOpen: true, translation: value.translation.width,
                            velocity: value.velocity.width, geometry: geometry)
                    },
                name: ConsoleTrailingEdgeClose.catcherDragName)
            .accessibilityHidden(true)
    }

    private var sidebarToggle: some View {
        Button { request(!isSidebarVisible) } label: {
            Image(systemName: "sidebar.left")
                .font(.body.weight(.medium))
                .imageScale(.large)
                .foregroundStyle(.primary)
                .frame(
                    width: ConsoleSlideOverGeometry.toggleSize,
                    height: ConsoleSlideOverGeometry.toggleSize)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .modifier(ConsoleSidebarToggleSurface())
        .hoverEffect(.highlight)
        .accessibilityLabel(isSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        // On the button rather than in `ConsoleCommandShortcut`: the system
        // sidebar toggle's chord, which that table keeps Control out of.
        .keyboardShortcut("s", modifiers: [.command, .control])
    }

    /// Handed to the Agent terminal's leading-edge strip and to the
    /// right-edge pan. A drag starts from the logical state it began in, and
    /// each keeps this value for the whole drag.
    private func revealDrag(_ geometry: ConsoleSlideOverGeometry) -> ConsoleSidebarRevealDrag {
        let isOpen = isSidebarVisible
        return ConsoleSidebarRevealDrag(
            isSidebarVisible: isOpen,
            changed: { translation in
                follow(fromOpen: isOpen, translation: translation, geometry: geometry)
            },
            ended: { translation, velocity in
                settleDrag(
                    fromOpen: isOpen, translation: translation, velocity: velocity,
                    geometry: geometry)
            })
    }

    private func follow(
        fromOpen isOpen: Bool, translation: CGFloat, geometry: ConsoleSlideOverGeometry
    ) {
        let dragged = geometry.dragProgress(fromOpen: isOpen, translation: translation)
        // A drag pinned at the side the Agent rests on moves nothing; taking
        // it as a move would still widen a narrowed Agent, and the terminal
        // would reflow twice for no motion.
        guard isMoving || dragged != progress else { return }
        // The finger takes over from any slide still settling.
        settleGeneration &+= 1
        isMoving = true
        progress = dragged
    }

    private func settleDrag(
        fromOpen isOpen: Bool, translation: CGFloat, velocity: CGFloat,
        geometry: ConsoleSlideOverGeometry
    ) {
        request(geometry.settlesOpen(fromOpen: isOpen, translation: translation, velocity: velocity))
    }

    /// The toggle, its shortcut and drags: slide there, and keep the choice.
    /// Forwarded even when it matches: a drag's `isOpen` is the state it
    /// began in, and a toggle, shortcut or rotation during it may have
    /// changed the logical state since.
    private func request(_ open: Bool) {
        settle(open: open, animated: true)
        setSidebarVisible(open)
    }

    private func placementChanged(from old: Placement, to new: Placement) {
        // Already heading there when the change is our own request.
        guard old.isSidebarVisible != new.isSidebarVisible,
              progress != (new.isSidebarVisible ? 1 : 0)
        else { return }
        settle(
            open: new.isSidebarVisible,
            animated: old.width == new.width && old.reveal == new.reveal)
    }

    /// Opening slides at full width and narrows the Agent once it arrives;
    /// closing widens it first, the extra width running past the screen's
    /// trailing edge, then slides. One terminal reflow either way, and none
    /// mid-slide.
    private func settle(open: Bool, animated: Bool) {
        let target: CGFloat = open ? 1 : 0
        settleGeneration &+= 1
        guard animated, !reduceMotion, progress != target else {
            progress = target
            isMoving = false
            return
        }
        let generation = settleGeneration
        isMoving = true
        withAnimation(.snappy, completionCriteria: .logicallyComplete) {
            progress = target
        } completion: {
            guard generation == settleGeneration else { return }
            isMoving = false
        }
    }
}

/// The swipe in from the screen's right edge that slides the Agent back
/// over the open list (#30), under the finger like the other drags. A
/// screen-edge recognizer rather than a SwiftUI drag: it only ever claims a
/// touch that starts at the edge, so the terminal under it keeps its taps,
/// selection and scrolling everywhere else.
private struct ConsoleTrailingEdgeClose: UIGestureRecognizerRepresentable {
    /// The portrait catcher's drag, as UIKit names its recognizer.
    static let catcherDragName = "ConsoleCatcherDrag"

    let drag: ConsoleSidebarRevealDrag

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIScreenEdgePanGestureRecognizer {
        let recognizer = UIScreenEdgePanGestureRecognizer()
        recognizer.edges = .right
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(
        _ recognizer: UIScreenEdgePanGestureRecognizer, context: Context
    ) {
        // Closed, there is nothing to close. Disabling mid-swipe cancels it,
        // which settles the Agent rather than leaving it mid-slide.
        recognizer.isEnabled = drag.isSidebarVisible
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UIScreenEdgePanGestureRecognizer, context: Context
    ) {
        let coordinator = context.coordinator
        let translation = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began:
            coordinator.drag = drag
            drag.changed(translation)
        case .changed:
            coordinator.drag?.changed(translation)
        case .ended:
            coordinator.drag?.ended(translation, recognizer.velocity(in: recognizer.view).x)
            coordinator.drag = nil
        case .cancelled:
            // No fling to go by: settle from where the Agent was left.
            coordinator.drag?.ended(translation, 0)
            coordinator.drag = nil
        default:
            break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        /// The value the swipe began with: the layout rebuilds its value as
        /// the slide moves, and a swipe must end where it began.
        var drag: ConsoleSidebarRevealDrag?

        /// Only what would race the swipe for the same finger waits for it
        /// to fail: portrait's catcher drag, which lies under the edge and
        /// would move and settle the Agent a second time, and plain pans such
        /// as the terminal's scroll. Presses, taps and buttons do not wait:
        /// the terminal's selection handle and the message-jump and
        /// scroll-jump tabs all sit on this edge in landscape and must answer
        /// the moment they are touched. A handle's zero-delay press
        /// recognizes first and so keeps its drag from ever becoming this
        /// swipe.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer.name == ConsoleTrailingEdgeClose.catcherDragName
                || otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}

/// Liquid Glass where the system has it, the material it replaced before.
private struct ConsoleSidebarToggleSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(.regularMaterial, in: .circle)
        }
    }
}
