import Foundation

/// Whether one opening of a help page shows the labelled **Ask an Agent**
/// button at its top, which teaches the toolbar's icon-only button. The
/// first ``limit`` help-page views on this device show it, then it is gone
/// for good.
///
/// The count is device-local in `UserDefaults` and not one of the
/// preferences iCloud Sync carries: each device teaches its own toolbar.
/// A page counts only once the action is available, so pages read before
/// there is a Host don't use the hint up. The decision is made once per
/// view and kept, so a page doesn't lose the button when pages opened on
/// top of it reach the limit, or when it comes back from one.
struct AskAgentHint {
    static let defaultsKey = "help.ask-agent-hint.page-views"
    static let limit = 10

    private let defaults: UserDefaults
    /// This view's decision; nil until the action is first available.
    private var decision: Bool?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether this view shows the button.
    var isVisible: Bool { decision == true }

    /// Help-page views counted so far on this device, capped at ``limit``.
    var recordedViews: Int { defaults.integer(forKey: Self.defaultsKey) }

    /// Called whenever the page appears or the action comes or goes. The
    /// first call with the action available decides this view and counts
    /// it; later calls keep that decision.
    mutating func pageAppeared(canAskAgent: Bool) {
        guard decision == nil, canAskAgent else { return }
        let views = recordedViews
        let shows = views < Self.limit
        decision = shows
        // Past the limit there is nothing left to count.
        if shows {
            defaults.set(views + 1, forKey: Self.defaultsKey)
        }
    }
}
