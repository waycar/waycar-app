import Foundation
import UIKit

/// The terminal grid each layout last had, kept across launches, so an
/// attach can start the moment its detail is created instead of after the
/// terminal view's first layout (#105). A layout is a window's size
/// classes and size plus the terminal font size: what decides how many
/// cells fit. The window is always the terminal's own (`layout(of:)`), so
/// two windows side by side keep their own grids. The view's own size
/// report still wins — it rides the live session as a resize when it
/// differs. The app owns one (`WaycarAppModel`).
@MainActor
final class TerminalGridSizeMemory {
    struct Layout: Hashable, Codable, Sendable {
        let horizontalSizeClass: Int
        let verticalSizeClass: Int
        let width: Int
        let height: Int
        let fontSize: Float
    }

    struct GridSize: Equatable, Codable, Sendable {
        let cols: Int
        let rows: Int
    }

    private struct Entry: Codable {
        let layout: Layout
        let size: GridSize
    }

    static let defaultsKey = "terminal-grid-sizes"
    /// Enough for every orientation and split a device cycles through.
    static let capacity = 16

    private let defaults: UserDefaults
    /// Most recently recorded last.
    private var entries: [Entry]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// The grid `layout` last had; nil when it never reported one, or with
    /// no layout (no window yet).
    func size(for layout: Layout?) -> GridSize? {
        guard let layout else { return nil }
        return entries.last { $0.layout == layout }?.size
    }

    /// The grid reported last, in whichever window: for a start no window
    /// asked for yet (a speculative standby named by a notification).
    var lastRecordedSize: GridSize? {
        entries.last?.size
    }

    /// Keeps a view's size report for its window's layout.
    func record(cols: Int, rows: Int, for layout: Layout?) {
        guard cols > 0, rows > 0, let current = layout else { return }
        let size = GridSize(cols: cols, rows: rows)
        if entries.last?.layout == current, entries.last?.size == size { return }
        entries.removeAll { $0.layout == current }
        entries.append(Entry(layout: current, size: size))
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    /// `window`'s layout with the app-wide terminal font size.
    static func layout(of window: UIWindow) -> Layout {
        let traits = window.traitCollection
        return Layout(
            horizontalSizeClass: traits.horizontalSizeClass.rawValue,
            verticalSizeClass: traits.verticalSizeClass.rawValue,
            width: Int(window.bounds.width.rounded()),
            height: Int(window.bounds.height.rounded()),
            fontSize: TerminalZoomSettings().fontSize)
    }
}
