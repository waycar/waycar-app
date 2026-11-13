import Foundation
import Testing

@testable import Waycar

/// Ignition's timeline (#96): a fast attach never shows the loader, a slow
/// one reveals and then gets out of the way, and a failure freezes it.
@Suite("Terminal Ignition lifecycle")
struct TerminalIgnitionTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private let settle = TerminalIgnitionLifecycle.paintSettle

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    @Test func aPaintInsideTheGraceNeverShows() {
        var lifecycle = TerminalIgnitionLifecycle()
        lifecycle.connect(at: start)
        #expect(!lifecycle.isVisible(at: at(0.1)))

        #expect(lifecycle.paint(at: at(0.2)) == start)
        #expect(lifecycle.phase == .done)
        #expect(!lifecycle.isVisible(at: at(0.3)))
        #expect(lifecycle.revealProgress(at: at(0.3)) == nil)
    }

    @Test func aPaintAfterTheGraceRevealsThenFinishes() {
        var lifecycle = TerminalIgnitionLifecycle(revealDuration: 0.38)
        lifecycle.connect(at: start)
        #expect(lifecycle.isVisible(at: at(0.3)))

        #expect(lifecycle.paint(at: at(1)) == start)
        let revealStart = at(1).addingTimeInterval(settle)
        #expect(lifecycle.phase == .revealing(start: revealStart, from: 1, waited: 1))
        #expect(lifecycle.waited(at: at(1.2)) == 1)
        #expect(lifecycle.revealProgress(at: at(1 + settle / 2)) == 0)
        lifecycle.tick(at: at(1.2))
        #expect(lifecycle.phase == .revealing(start: revealStart, from: 1, waited: 1))
        lifecycle.tick(at: at(1.4 + settle))
        #expect(lifecycle.phase == .done)
        #expect(!lifecycle.isVisible(at: at(1.5 + settle)))
    }

    @Test func aPaintDuringTheFadeInNeverBrightensTheLoader() {
        var lifecycle = TerminalIgnitionLifecycle(revealDuration: 0.38)
        lifecycle.connect(at: start)
        let paintedAt = at(TerminalIgnitionLifecycle.grace + 0.1)
        let reached = lifecycle.opacity(at: paintedAt)
        #expect(reached > 0 && reached < 1)

        lifecycle.paint(at: paintedAt)
        for step in 0...20 {
            let now = paintedAt.addingTimeInterval(Double(step) * 0.03)
            #expect(lifecycle.opacity(at: now) <= reached)
        }
    }

    @Test func anEndWhileShowingFreezes() {
        var lifecycle = TerminalIgnitionLifecycle()
        lifecycle.connect(at: start)

        lifecycle.fail(at: at(2))
        #expect(lifecycle.phase == .frozen(since: start, at: at(2), from: 1))
        #expect(lifecycle.isVisible(at: at(5)))
        #expect(lifecycle.waited(at: at(5)) == 2)
    }

    @Test func aPaintOverAFreezeEndsTheLoader() {
        var lifecycle = TerminalIgnitionLifecycle()
        lifecycle.connect(at: start)
        lifecycle.fail(at: at(2))

        #expect(lifecycle.paint(at: at(3)) == nil)
        #expect(lifecycle.phase == .done)
        #expect(!lifecycle.isVisible(at: at(3)))
    }

    @Test func aReattachAfterAFreezeStaysUpWithoutTheGrace() {
        var lifecycle = TerminalIgnitionLifecycle()
        lifecycle.connect(at: start)
        lifecycle.fail(at: at(2))

        lifecycle.connect(at: at(3))
        #expect(lifecycle.waitStart == at(3))
        #expect(lifecycle.isVisible(at: at(3)))
        #expect(lifecycle.opacity(at: at(3)) == 1)
        #expect(lifecycle.isVisible(at: at(3 + TerminalIgnitionLifecycle.grace / 2)))
    }

    @Test func anEndInsideTheGraceNeverShows() {
        var lifecycle = TerminalIgnitionLifecycle()
        lifecycle.connect(at: start)

        lifecycle.fail(at: at(0.1))
        #expect(lifecycle.phase == .done)
        #expect(!lifecycle.isVisible(at: at(1)))
    }

    @Test func anEndDuringTheRevealFinishesIt() {
        var lifecycle = TerminalIgnitionLifecycle()
        lifecycle.connect(at: start)
        lifecycle.paint(at: at(1))

        lifecycle.fail(at: at(1.2))
        #expect(lifecycle.phase == .done)
        #expect(!lifecycle.isVisible(at: at(1.2)))
    }
}
