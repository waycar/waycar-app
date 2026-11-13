import Testing

@testable import Waycar

struct TerminalLastFrameMachineTests {
    @Test func onlyAnEmptyScreenAcceptsAnOfferedCopy() {
        var machine = TerminalLastFrameMachine()
        #expect(machine.handle(.offer) == [.storeSnapshot])
        #expect(machine.state == .cached)
        #expect(machine.handle(.offer).isEmpty)
        #expect(machine.hasFrame(for: TerminalSurfaceID()))
        let painted = TerminalLastFrameMachine().after([.paint(TerminalSurfaceID(), hasView: false)])
        #expect(painted.after([.offer]).state == painted.state)
    }

    @Test func aPaintReplacesTheCopyAndOwnsOnlyItsSurface() {
        let surface = TerminalSurfaceID()
        var machine = TerminalLastFrameMachine().after([.offer])
        #expect(machine.handle(.paint(surface, hasView: true)) == [.storePaintedView, .clearSnapshot])
        #expect(machine.state == .painted(surface))
        #expect(machine.hasFrame(for: surface))
        #expect(!machine.hasFrame(for: TerminalSurfaceID()))
        #expect(machine.handle(.paint(surface, hasView: true)) == [.storePaintedView])
        #expect(machine.handle(.paint(surface, hasView: false)).isEmpty)
        #expect(machine.state == .painted(surface))
    }

    @Test func aReplacementPaintReplacesEvenANilWeakView() {
        let first = TerminalSurfaceID()
        let second = TerminalSurfaceID()
        var machine = TerminalLastFrameMachine()
        #expect(machine.handle(.paint(first, hasView: false)) == [.storePaintedView])
        #expect(machine.handle(.paint(second, hasView: false)) == [.storePaintedView])
        #expect(machine.paintedSurface == second)
    }

    @Test func retirementKeepsOnlyASuccessfullyCapturedCopy() {
        let surface = TerminalSurfaceID()
        var machine = TerminalLastFrameMachine().after([.paint(surface, hasView: true)])
        #expect(machine.handle(.retired(hasSnapshot: true)) == [.storeSnapshot, .clearPaintedView])
        #expect(machine.state == .cached)
        #expect(machine.paintedSurface == nil)
        _ = machine.handle(.paint(surface, hasView: false))
        #expect(machine.handle(.retired(hasSnapshot: false)) == [.clearSnapshot, .clearPaintedView])
        #expect(machine.state == .empty)
        #expect(!machine.hasFrame(for: surface))
    }

    @Test func discardDropsEveryKindOfOwnership() {
        let setups: [[TerminalLastFrameMachine.Event]] = [
            [], [.offer], [.paint(TerminalSurfaceID(), hasView: true)],
        ]
        for events in setups {
            var machine = TerminalLastFrameMachine().after(events)
            #expect(machine.handle(.discard) == [.clearSnapshot, .clearPaintedView])
            #expect(machine.state == .empty)
        }
    }
}
