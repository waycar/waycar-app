import Foundation
import Testing

@testable import Waycar

@Suite("Surface keyboard freeze machine")
struct SurfaceKeyboardFreezeMachineTests {
    typealias Machine = SurfaceKeyboardFreezeMachine
    private static let handoff = UUID()
    private static let begin: [Machine.Effect] = [
        .cancelGridReport, .beginBridgeFreeze, .cancelFallback, .armFallback(cycle: 1),
    ]
    private static let thaw: [Machine.Effect] = [
        .cancelFallback, .layoutNow, .provideAuthoritativeGrid, .scheduleGridReport,
    ]

    @Test func inheritingAndRequestingAHandoffBeginACycle() {
        var inherited = Machine()
        #expect(inherited.handle(.inherit) == Self.begin)
        #expect(inherited.state == .frozen(cycle: 1, endsOnFrameChange: true, reload: .notYet, handoff: nil))
        var requested = Machine()
        #expect(requested.handle(.requestHandoff(Self.handoff)) == Self.begin)
        #expect(requested.handoffID == Self.handoff)
        #expect(requested.isFrozen)
        #expect(requested.endsOnFrameChange)
    }

    @Test func aNewCycleKeepsOrReplacesTheOwningHandoff() {
        var machine = Machine().after([.requestHandoff(Self.handoff)])
        _ = machine.handle(.inherit)
        #expect(machine.state == .frozen(cycle: 2, endsOnFrameChange: true, reload: .notYet, handoff: Self.handoff))
        let replacement = UUID()
        _ = machine.handle(.requestHandoff(replacement))
        #expect(machine.state == .frozen(cycle: 3, endsOnFrameChange: true, reload: .notYet, handoff: replacement))
    }

    @Test func theFirstSettleQueuesOneReloadAndDuplicatesCoalesce() {
        var machine = Machine().after([.requestHandoff(Self.handoff)])
        #expect(machine.handle(.frameSettled) == [.scheduleReload(cycle: 1)])
        #expect(machine.handle(.frameSettled) == [])
        #expect(machine.handle(.queuedReloadFired(cycle: 1)) == [.reloadInputViews])
        #expect(machine.state == .frozen(cycle: 1, endsOnFrameChange: true, reload: .done, handoff: Self.handoff))
        #expect(machine.handle(.queuedReloadFired(cycle: 1)) == [])
    }

    @Test func theSettleAfterTheReloadThawsWithoutAnotherReload() {
        var machine = Machine().after([
            .requestHandoff(Self.handoff), .frameSettled, .queuedReloadFired(cycle: 1),
        ])
        #expect(machine.handle(.frameSettled) == Self.thaw + [.notifyHandoffEnded(Self.handoff, .settled)])
        #expect(machine.state == .live)
        #expect(machine.handle(.frameSettled) == [])
    }

    @Test func aQueuedReloadOfAnOlderCycleDoesNothing() {
        var machine = Machine().after([.requestHandoff(Self.handoff), .frameSettled, .requestHandoff(UUID())])
        #expect(machine.handle(.queuedReloadFired(cycle: 1)) == [])
        #expect(machine.handle(.frameSettled) == [.scheduleReload(cycle: 2)])
        var thawed = Machine().after([.inherit, .frameSettled, .finish(.settled)])
        #expect(thawed.handle(.queuedReloadFired(cycle: 1)) == [])
    }

    @Test func aThawWithoutTheQueuedReloadRebuildsFirst() {
        var machine = Machine().after([.requestHandoff(Self.handoff), .frameSettled])
        #expect(machine.handle(.fallbackElapsed(cycle: 1)) == [
            .cancelFallback, .reloadInputViews, .layoutNow, .provideAuthoritativeGrid,
            .scheduleGridReport, .notifyHandoffEnded(Self.handoff, .timedOut),
        ])
    }

    @Test func onlyTheCurrentCyclesLeashFires() {
        var machine = Machine().after([.inherit, .inherit])
        #expect(machine.handle(.fallbackElapsed(cycle: 1)) == [])
        #expect(machine.isFrozen)
        #expect(machine.handle(.fallbackElapsed(cycle: 2)).contains(.layoutNow))
        #expect(machine.handle(.fallbackElapsed(cycle: 2)) == [])
    }

    @Test func aThawReportsOnlyToAnOwningHandoff() {
        var inherited = Machine().after([.inherit])
        #expect(inherited.handle(.finish(.cancelled)) == [.cancelFallback, .reloadInputViews] + Self.thaw.dropFirst())
        var live = Machine()
        #expect(live.handle(.finish(.settled)) == [])
    }

    @Test func requestKeyboardEndsOnlyAFreezeNoHandoffOwns() {
        var owned = Machine().after([.requestHandoff(Self.handoff)])
        #expect(owned.handle(.requestKeyboard) == [])
        #expect(owned.isFrozen)
        var unowned = Machine().after([.inherit])
        #expect(unowned.handle(.requestKeyboard).contains(.layoutNow))
        #expect(!unowned.isFrozen)
        var live = Machine()
        #expect(live.handle(.requestKeyboard) == [])
    }

    @Test func aCancelThawsTheBridgeThenReportsToItsHandoff() {
        let cancel: [Machine.Effect] = [
            .cancelFallback, .cancelGridReport, .cancelBridgeFreeze, .reportPendingWindowResizeGrid,
        ]
        var owned = Machine().after([.requestHandoff(Self.handoff), .frameSettled])
        #expect(owned.handle(.cancel) == cancel + [.notifyHandoffEnded(Self.handoff, .cancelled)])
        #expect(owned.state == .live)
        #expect(owned.handle(.queuedReloadFired(cycle: 1)) == [])
        // A cancel with nothing frozen still thaws the bridge.
        var live = Machine()
        #expect(live.handle(.cancel) == cancel)
    }
}
