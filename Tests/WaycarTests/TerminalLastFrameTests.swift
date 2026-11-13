import Testing
import UIKit

@testable import Waycar

/// Which frame a reconnecting terminal keeps up, and how it sits in a
/// terminal whose size has changed (#21).
@MainActor
@Suite("Terminal last frame")
struct TerminalLastFrameTests {
    /// A replacement can itself be replaced before it paints (a second
    /// transport change mid-recovery). Its blank surface must not overwrite
    /// the frame the user last saw.
    @Test func aReplacementThatNeverPaintedKeepsTheOlderFrame() throws {
        let first = TerminalSurfaceID()
        let second = TerminalSurfaceID()
        let third = TerminalSurfaceID()
        let frame = TerminalLastFrame()
        #expect(!frame.hasFrame(for: first), "a cold surface has no frame")

        frame.surfaceDidPaint(first, view: nil)
        frame.surfaceWillRetire(first) { _ in Self.copy() }
        let copy = try #require(frame.snapshot?.view)
        #expect(frame.hasFrame(for: second))

        frame.surfaceWillRetire(second) { _ in Self.copy() }
        #expect(frame.snapshot?.view === copy)
        #expect(frame.hasFrame(for: third))

        frame.surfaceDidPaint(third, view: nil)
        #expect(frame.snapshot == nil, "a painted replacement stands on its own frame")
    }

    /// An ended attach, an unavailable Host or a takeover by another window
    /// leaves nothing to come back as the last frame later.
    @Test func aDiscardedFrameNeverReturns() {
        let painted = TerminalSurfaceID()
        let next = TerminalSurfaceID()
        let frame = TerminalLastFrame()
        frame.surfaceDidPaint(painted, view: nil)
        frame.surfaceWillRetire(painted) { _ in Self.copy() }
        frame.discard()
        #expect(!frame.hasFrame(for: next))

        frame.surfaceDidPaint(painted, view: nil)
        frame.discard()
        #expect(!frame.hasFrame(for: painted))
        frame.surfaceWillRetire(painted) { _ in Self.copy() }
        #expect(!frame.hasFrame(for: next), "a discarded surface leaves no copy on retirement")
    }

    /// An Agent's cached frame from an earlier visit stands in only while the
    /// screen has no frame of its own, and goes once the terminal paints.
    @Test func aCachedFrameStandsInOnlyWhileTheScreenHasNoneOfItsOwn() throws {
        let cold = TerminalSurfaceID()
        let frame = TerminalLastFrame()
        let cached = Self.copy()
        #expect(frame.offer(cached), "a cold entry takes the cached frame")
        #expect(frame.snapshot?.view === cached.view)
        #expect(frame.hasFrame(for: cold))
        #expect(!frame.offer(Self.copy()), "the frame already up stays")
        #expect(frame.snapshot?.view === cached.view)

        frame.surfaceDidPaint(cold, view: nil)
        #expect(frame.snapshot == nil, "the painted terminal stands on its own frame")
        #expect(!frame.offer(Self.copy()), "a painted screen never goes back to the cache")
        #expect(frame.snapshot == nil)

        let held = Self.copy()
        frame.surfaceWillRetire(cold) { _ in held }
        #expect(!frame.offer(Self.copy()), "this screen's own copy beats the cache")
        #expect(frame.snapshot?.view === held.view)
    }

    /// A shorter terminal (a reclaimed keyboard) keeps the copy at full size,
    /// pinned to the bottom so the prompt rows stay in view.
    @Test func aShorterTerminalClipsTheTopOfTheFrame() throws {
        let container = Self.container(size: CGSize(width: 402, height: 500))
        let view = try #require(container.subviews.first)
        #expect(container.clipsToBounds)
        #expect(view.frame == CGRect(x: 0, y: -374, width: 402, height: 874))
    }

    /// A narrower terminal (a rotation, a split) scales the copy uniformly.
    @Test func aNarrowerTerminalShrinksTheFrameUniformly() throws {
        let container = Self.container(size: CGSize(width: 201, height: 874))
        let view = try #require(container.subviews.first)
        #expect(view.frame == CGRect(x: 0, y: 437, width: 201, height: 437))
    }

    private static func copy() -> TerminalLastFrame.Snapshot {
        TerminalLastFrame.Snapshot(view: UIView(), size: CGSize(width: 402, height: 874))
    }

    private static func container(size: CGSize) -> TerminalLastFrameView.Container {
        let container = TerminalLastFrameView.Container(frame: CGRect(origin: .zero, size: size))
        container.show(copy())
        container.layoutIfNeeded()
        return container
    }
}
