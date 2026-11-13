import CoreGraphics

/// Tells a window resize apart from every other layout pass a terminal sees.
///
/// Stage Manager live resize and rotation change the window's own size; the
/// keyboard, a split-view column, or the status bar change only the
/// terminal's frame inside it. Only the former arrives as a burst of grids
/// worth collapsing into one PTY resize (see
/// `WaycarTerminalView.deferGridReportsForWindowResize`).
struct TerminalWindowResizeTracker: Equatable, Sendable {
    private var lastWindowSize: CGSize?

    /// Records one layout pass in a window of `size`. True when the window
    /// changed size since the previous pass; the first pass only establishes
    /// the baseline, so a surface's initial grid is never held back.
    mutating func windowDidLayout(size: CGSize) -> Bool {
        defer { lastWindowSize = size }
        guard let lastWindowSize else { return false }
        return lastWindowSize != size
    }
}
