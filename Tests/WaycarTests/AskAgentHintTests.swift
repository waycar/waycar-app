import Foundation
import Testing

@testable import Waycar

/// The labelled Ask an Agent button at the top of a help page shows on the
/// first ten help-page views on this device, then never again.
@Suite("Ask an Agent hint")
struct AskAgentHintTests {
    private func makeDefaults() throws -> (UserDefaults, () -> Void) {
        let suiteName = "ask-agent-hint-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    /// Opens one help page with the action available and reports whether
    /// it shows the button.
    private func openPage(_ defaults: UserDefaults, canAskAgent: Bool = true) -> AskAgentHint {
        var hint = AskAgentHint(defaults: defaults)
        hint.pageAppeared(canAskAgent: canAskAgent)
        return hint
    }

    @Test func theFirstTenPageViewsShowTheButtonAndLaterOnesDont() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let shown = (1...14).map { _ in openPage(defaults).isVisible }

        #expect(AskAgentHint.limit == 10)
        #expect(shown == Array(repeating: true, count: 10) + Array(repeating: false, count: 4))
        #expect(AskAgentHint(defaults: defaults).recordedViews == AskAgentHint.limit)
    }

    @Test func pagesReadWithoutTheActionDontUseUpTheHint() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        for _ in 1...20 {
            #expect(!openPage(defaults, canAskAgent: false).isVisible)
        }
        #expect(AskAgentHint(defaults: defaults).recordedViews == 0)

        let shown = (1...AskAgentHint.limit).map { _ in openPage(defaults).isVisible }
        #expect(shown.allSatisfy { $0 })
    }

    @Test func aViewCountsOnceWhenTheActionArrivesNotOnEachReappear() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        var page = AskAgentHint(defaults: defaults)
        page.pageAppeared(canAskAgent: false)
        #expect(!page.isVisible)
        page.pageAppeared(canAskAgent: true)
        #expect(page.isVisible)
        // Back from a page pushed on top, or the action going and coming.
        page.pageAppeared(canAskAgent: true)
        page.pageAppeared(canAskAgent: false)
        page.pageAppeared(canAskAgent: true)

        #expect(page.isVisible)
        #expect(AskAgentHint(defaults: defaults).recordedViews == 1)
    }

    @Test func aViewKeepsItsDecisionWhenLaterPagesReachTheLimit() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        for _ in 1..<AskAgentHint.limit { _ = openPage(defaults) }
        var tenth = openPage(defaults)
        #expect(tenth.isVisible)

        var eleventh = openPage(defaults)
        #expect(!eleventh.isVisible)

        // Back on the tenth page after the eleventh: still shown.
        tenth.pageAppeared(canAskAgent: true)
        #expect(tenth.isVisible)
        eleventh.pageAppeared(canAskAgent: true)
        #expect(!eleventh.isVisible)
        #expect(AskAgentHint(defaults: defaults).recordedViews == AskAgentHint.limit)
    }

    @Test func eachDefaultsSuiteKeepsItsOwnCount() throws {
        let (used, cleanupUsed) = try makeDefaults()
        defer { cleanupUsed() }
        let (fresh, cleanupFresh) = try makeDefaults()
        defer { cleanupFresh() }

        for _ in 1...AskAgentHint.limit { _ = openPage(used) }

        #expect(!openPage(used).isVisible)
        #expect(openPage(fresh).isVisible)
        #expect(AskAgentHint(defaults: fresh).recordedViews == 1)
    }
}
