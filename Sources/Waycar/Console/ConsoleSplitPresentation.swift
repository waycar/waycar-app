import SwiftUI

/// Layout policy uses scene bounds. iPad at regular width slides the Agent
/// over the list (`ConsoleSlideOverLayout`); everything else, iPhone at
/// regular width (a Plus or Pro Max in landscape) included, keeps the split
/// view, whose style stays constant.
struct ConsoleSplitPresentation: Equatable {
    struct ColumnWidth: Equatable {
        let minimum: CGFloat
        let ideal: CGFloat
        let maximum: CGFloat?
    }

    let hasUsableSize: Bool
    let usesRegularColumns: Bool
    let usesSlideOver: Bool
    let isLandscape: Bool
    let defaultVisibility: NavigationSplitViewVisibility
    /// How the slide-over brings the list out; unused by the split view.
    let sidebarReveal: ConsoleSidebarReveal
    let sidebarWidth: ColumnWidth

    init(
        horizontalSizeClass: UserInterfaceSizeClass?, size: CGSize,
        safeAreaInsets: EdgeInsets = EdgeInsets(),
        idiom: UIUserInterfaceIdiom = .pad
    ) {
        let width = size.width + safeAreaInsets.leading + safeAreaInsets.trailing
        let height = size.height + safeAreaInsets.top + safeAreaInsets.bottom
        // Insets must not turn an initial zero-sized layout pass into a valid seed.
        hasUsableSize = size.width > 0 && size.height > 0
            && width.isFinite && height.isFinite
        usesRegularColumns = horizontalSizeClass == .regular
        // Not size-driven: a zero-sized pass must not swap the layout away.
        usesSlideOver = usesRegularColumns && idiom == .pad
        isLandscape = hasUsableSize && width > height
        guard hasUsableSize, horizontalSizeClass == .regular else {
            defaultVisibility = .automatic
            sidebarReveal = .push
            sidebarWidth = ColumnWidth(minimum: 320, ideal: 380, maximum: nil)
            return
        }
        if isLandscape {
            defaultVisibility = .all
            sidebarReveal = .beside
            sidebarWidth = ColumnWidth(minimum: 320, ideal: 380, maximum: 440)
        } else {
            defaultVisibility = .detailOnly
            sidebarReveal = .push
            sidebarWidth = ColumnWidth(minimum: 320, ideal: 380, maximum: 400)
        }
    }
}

/// Only user deviations from a layout default carry across policy changes.
struct ConsoleSplitVisibilityState {
    private(set) var visibility: NavigationSplitViewVisibility = .automatic
    private(set) var userVisibility: NavigationSplitViewVisibility?
    private(set) var reportedSidebarVisibility: Bool?
    private var appliedPresentation: ConsoleSplitPresentation?

    /// A concrete report wins; an applied concrete request is the fallback when
    /// SwiftUI does not echo programmatic visibility changes through the binding.
    var isSidebarVisible: Bool? {
        reportedSidebarVisibility ?? Self.sidebarVisibility(for: visibility)
    }

    var showsAgentsAction: Bool { isSidebarVisible != true }

    /// Whether the slide-over shows the list for `presentation`, which can be
    /// newer than the applied one: `update(from:)` runs in an `onChange`, a
    /// pass after the render that brought the new size. Answering with what
    /// that update will apply lets the layout see the visibility change in
    /// the same pass as the rotation's width and reveal, and snap with it
    /// rather than slide a pass later.
    func isSidebarVisible(applying presentation: ConsoleSplitPresentation) -> Bool {
        guard presentation.hasUsableSize, presentation != appliedPresentation else {
            // Before the first usable layout is applied, the default it will seed.
            return isSidebarVisible ?? (presentation.defaultVisibility == .all)
        }
        return Self.sidebarVisibility(for: userVisibility ?? presentation.defaultVisibility) == true
    }

    /// In portrait the open list covers the Agent it pushed aside, so
    /// opening an Agent (a tap, a shortcut, a deep link) is done with it.
    /// Landscape's list rests beside the Agent and stays.
    var agentOpenClosesList: Bool {
        guard let appliedPresentation else { return false }
        return appliedPresentation.usesSlideOver && appliedPresentation.sidebarReveal == .push
            && isSidebarVisible == true
    }

    /// Closing to portrait's default keeps no preference, so the list
    /// still follows rotation back to landscape.
    mutating func agentDidOpen() {
        guard agentOpenClosesList else { return }
        setSidebarVisible(false)
    }

    /// Search lives in the list, so Command-F with the slide-over's list
    /// hidden shows it first, as the toggle would, rather than focusing a
    /// field nobody can see. The split view on iPhone keeps its own column
    /// handling. True when the list was hidden and is now shown.
    @discardableResult
    mutating func revealForSearch() -> Bool {
        guard appliedPresentation?.usesSlideOver == true, isSidebarVisible != true else {
            return false
        }
        setSidebarVisible(true)
        return true
    }

    mutating func update(from presentation: ConsoleSplitPresentation) {
        guard presentation.hasUsableSize, presentation != appliedPresentation else { return }
        reportedSidebarVisibility = nil
        appliedPresentation = presentation
        visibility = userVisibility ?? presentation.defaultVisibility
    }

    mutating func systemDidChangeVisibility(
        _ newVisibility: NavigationSplitViewVisibility,
        presentation: ConsoleSplitPresentation
    ) {
        // A callback from a different layout must not pin the outgoing column state.
        guard presentation.hasUsableSize, presentation == appliedPresentation else { return }
        reportedSidebarVisibility = Self.sidebarVisibility(for: newVisibility)
        let changed = visibility != newVisibility
        visibility = newVisibility
        // Automatic is a policy, not a report that the sidebar is visible.
        // Compact stack navigation also must not become a regular-width preference.
        // A same-value acknowledgement in portrait must not erase a landscape hide.
        if changed, presentation.usesRegularColumns, reportedSidebarVisibility != nil {
            userVisibility = newVisibility == presentation.defaultVisibility ? nil : newVisibility
        }
    }

    /// The user's own choice: the sidebar toggle, its shortcut, a drag, Show
    /// Agents, or an opened Agent closing the portrait list. Like a system
    /// toggle, a choice equal to the layout's default is no preference, so
    /// defaults keep following rotation until the user departs from one.
    mutating func setSidebarVisible(_ isVisible: Bool) {
        let requested: NavigationSplitViewVisibility = isVisible ? .all : .detailOnly
        visibility = requested
        reportedSidebarVisibility = nil
        userVisibility = appliedPresentation?.defaultVisibility == requested ? nil : requested
    }

    private static func sidebarVisibility(for visibility: NavigationSplitViewVisibility) -> Bool? {
        switch visibility {
        case .all, .doubleColumn: true
        case .detailOnly: false
        default: nil
        }
    }
}
