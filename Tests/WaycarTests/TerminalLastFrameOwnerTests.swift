import Observation
import Testing
import UIKit

@testable import Waycar

/// Characterization through the pre-machine owner's API (ATTACH-07).
@MainActor
struct TerminalLastFrameOwnerTests {
    @Test func aPaintedViewIsWeakAndANilRepeatDoesNotForgetIt() {
        let frame = TerminalLastFrame()
        let surface = TerminalSurfaceID()
        var view: UIView? = UIView()
        weak var weakView = view
        frame.surfaceDidPaint(surface, view: view)
        frame.surfaceDidPaint(surface, view: nil)
        #expect(frame.paintedTerminal(of: surface) === view)
        view = nil
        #expect(weakView == nil)
        #expect(frame.paintedTerminal(of: surface) == nil)
        #expect(frame.hasFrame(for: surface))
    }

    @Test func aRepeatedPaintDoesNotInvalidateObservedFrameOwnership() {
        let frame = TerminalLastFrame()
        let surface = TerminalSurfaceID()
        let view = UIView()
        frame.surfaceDidPaint(surface, view: view)
        let changes = LastFrameObservationChanges()
        withObservationTracking {
            _ = frame.paintedSurface
            _ = frame.snapshot
        } onChange: {
            MainActor.assumeIsolated { changes.invalidated = true }
        }
        frame.surfaceDidPaint(surface, view: view)
        frame.surfaceDidPaint(surface, view: nil)
        #expect(!changes.invalidated)
    }

    @Test func onlyThePaintedSurfaceIsCapturedAndAFailedCaptureLeavesNothing() {
        let frame = TerminalLastFrame()
        let surface = TerminalSurfaceID()
        let view = UIView()
        frame.surfaceDidPaint(surface, view: view)
        var captures = 0
        frame.surfaceWillRetire(TerminalSurfaceID()) { _ in
            captures += 1
            return nil
        }
        #expect(captures == 0)
        #expect(frame.paintedTerminal(of: surface) === view)
        frame.surfaceWillRetire(surface) { captured in
            captures += 1
            #expect(captured === view)
            return nil
        }
        #expect(captures == 1)
        #expect(frame.paintedSurface == nil)
        #expect(frame.snapshot == nil)
        #expect(!frame.hasFrame(for: surface))
    }
}

@MainActor
private final class LastFrameObservationChanges {
    var invalidated = false
}
