import SwiftUI

/// How the iPad Agent list comes out from under the Agent (ADR 0024).
enum ConsoleSidebarReveal: Equatable, Sendable {
    /// Landscape: at rest the Agent sits beside the list, narrowed to the
    /// width the list leaves.
    case beside
    /// Portrait: the Agent keeps its full width and slides partly off
    /// screen; a tap or a leftward drag on it slides it back.
    case push
}

/// The Agent terminal's leading-edge strip (`AgentEdgeBackGesture`) drives
/// the iPad slide through this, as does the layout's own swipe from the
/// screen's right edge. Set only inside the slide-over layout; nil on
/// iPhone, where the strip keeps its swipe back.
@MainActor
struct ConsoleSidebarRevealDrag {
    /// The list is out: the Agent sits to its right.
    let isSidebarVisible: Bool
    /// The drag moved: horizontal points since it began, positive rightward.
    let changed: @MainActor (_ translation: CGFloat) -> Void
    /// The drag ended: its horizontal translation and velocity in points
    /// per second; the layout projects the fling from them. A cancelled
    /// drag ends with its last translation and no velocity.
    let ended: @MainActor (_ translation: CGFloat, _ velocity: CGFloat) -> Void
}

extension EnvironmentValues {
    /// Nil outside the iPad slide-over layout.
    @Entry var consoleSidebarRevealDrag: ConsoleSidebarRevealDrag? = nil
    /// True while the Agent covers the iPad Agent list at rest: the list
    /// stays mounted under it, so its per-frame animations should pause.
    @Entry var consoleListIsCovered = false
    /// True while the open iPad list covers the Agent it pushed aside
    /// (portrait): the Agent stays mounted under it, so its keyboard input
    /// and commands must stop until it is back.
    @Entry var consoleDetailIsCovered = false
    /// Counts taps on the visible part of an Agent the open iPad list pushed
    /// aside (portrait). Each closes the list and, as a tap on the terminal
    /// would, focuses the Agent's terminal. Landscape's list rests beside
    /// the Agent, which takes its own taps, so nothing counts there.
    @Entry var consoleDetailFocusTaps = 0
}
