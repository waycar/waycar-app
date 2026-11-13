import Foundation
import GhosttyTerminal
import Testing
import UIKit

@testable import Waycar

/// Owner pins for the surface keyboard freeze (ATTACH-14): the queued
/// input-view reload a handoff's first owned frame schedules, its cycle
/// token, and what the handoff-ended callback sees of the surface.
/// Existing API only.
@MainActor
@Suite("Terminal surface freeze lifecycle")
struct TerminalSurfaceFreezeLifecycleTests {
    private struct Mounted {
        let terminal: WaycarTerminalView
        let window: UIWindow
        let host: UIViewController
    }

    private static func mount() async throws -> Mounted {
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: NotificationCenter())
        terminal.keyboardTransitionFallbackDelay = 60
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        terminal.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        host.view.addSubview(terminal)
        window.layoutIfNeeded()
        return Mounted(terminal: terminal, window: window, host: host)
    }

    private static func unmount(_ mounted: Mounted) {
        mounted.terminal.onKeyboardHandoffEnded = nil
        mounted.terminal.removeFromSuperview()
        mounted.window.isHidden = true
    }

    /// FIFO barrier for a `DispatchQueue.main.async` the surface scheduled.
    private static func mainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private struct Ended: Equatable {
        let id: UUID
        let outcome: TerminalKeyboardHandoffOutcome
        let phase: TerminalGridReportPhase
        let rebuilds: Int
    }

    private static func recordEndings(of terminal: WaycarTerminalView) -> () -> [Ended] {
        var endings: [Ended] = []
        terminal.onKeyboardHandoffEnded = { [weak terminal] id, outcome in
            guard let terminal else { return }
            endings.append(Ended(
                id: id, outcome: outcome, phase: terminal.gridReportPhase,
                rebuilds: terminal.inputViewRebuildCount))
        }
        return { endings }
    }

    /// Duplicate first frames before the queued reload runs schedule one
    /// rebuild; the settle after it ends the handoff without another.
    @Test func duplicateFirstFramesQueueOneReloadAndTheSettleAddsNone() async throws {
        let mounted = try await Self.mount()
        defer { Self.unmount(mounted) }
        let terminal = mounted.terminal
        let endings = Self.recordEndings(of: terminal)
        let id = UUID()
        try #require(terminal.requestKeyboardHandoff(id: id))
        #expect(terminal.gridReportPhase == .deferring)
        let rebuilds = terminal.inputViewRebuildCount

        terminal.keyboardFrameDidSettle()
        terminal.keyboardFrameDidSettle()
        #expect(terminal.inputViewRebuildCount == rebuilds)
        await Self.mainQueueTurn()
        #expect(terminal.inputViewRebuildCount == rebuilds + 1)
        #expect(endings().isEmpty)

        terminal.keyboardFrameDidSettle()
        #expect(endings() == [Ended(
            id: id, outcome: .settled, phase: .deferring, rebuilds: rebuilds + 1)])
        try await waitUntil { terminal.gridReportPhase == .live }
        #expect(terminal.inputViewRebuildCount == rebuilds + 1)
        // A settle with no freeze in force does nothing.
        terminal.keyboardFrameDidSettle()
        await Self.mainQueueTurn()
        #expect(terminal.inputViewRebuildCount == rebuilds + 1)
        #expect(endings().count == 1)
    }

    /// A freeze that ends without the queued rebuild having run rebuilds
    /// inside the thaw, before the owner hears the outcome; the grid report
    /// is still scheduled when it does.
    @Test func aTimedOutHandoffRebuildsBeforeReportingItsOutcome() async throws {
        let mounted = try await Self.mount()
        defer { Self.unmount(mounted) }
        let terminal = mounted.terminal
        terminal.keyboardTransitionFallbackDelay = 0.02
        let endings = Self.recordEndings(of: terminal)
        let id = UUID()
        try #require(terminal.requestKeyboardHandoff(id: id))
        let rebuilds = terminal.inputViewRebuildCount

        try await waitUntil { !endings().isEmpty }
        #expect(endings() == [Ended(
            id: id, outcome: .timedOut, phase: .deferring, rebuilds: rebuilds + 1)])
        try await waitUntil { terminal.gridReportPhase == .live }
    }

    /// The queued reload belongs to the cycle that scheduled it: a newer
    /// freeze begun before it runs makes it a no-op, and the replaced
    /// handoff hears no outcome.
    @Test func aNewerFreezeInvalidatesTheQueuedReloadOfTheOldCycle() async throws {
        let mounted = try await Self.mount()
        defer { Self.unmount(mounted) }
        let terminal = mounted.terminal
        let endings = Self.recordEndings(of: terminal)
        let first = UUID()
        let second = UUID()
        try #require(terminal.requestKeyboardHandoff(id: first))
        terminal.keyboardFrameDidSettle()
        try #require(terminal.requestKeyboardHandoff(id: second))
        let rebuilds = terminal.inputViewRebuildCount
        await Self.mainQueueTurn()
        #expect(terminal.inputViewRebuildCount == rebuilds)
        #expect(terminal.gridReportPhase == .deferring)

        // The new cycle schedules its own reload, then settles.
        terminal.keyboardFrameDidSettle()
        await Self.mainQueueTurn()
        #expect(terminal.inputViewRebuildCount == rebuilds + 1)
        terminal.keyboardFrameDidSettle()
        #expect(endings().map(\.id) == [second])
        #expect(endings().map(\.outcome) == [.settled])
    }

    /// A cancelled freeze thaws before its owner hears `.cancelled`, never
    /// rebuilds the input views, and drops a reload it had queued.
    @Test func aCancelledHandoffThawsBeforeReportingAndDropsItsReload() async throws {
        let mounted = try await Self.mount()
        defer { Self.unmount(mounted) }
        let terminal = mounted.terminal
        let endings = Self.recordEndings(of: terminal)
        let id = UUID()
        try #require(terminal.requestKeyboardHandoff(id: id))
        terminal.keyboardFrameDidSettle()
        let rebuilds = terminal.inputViewRebuildCount
        terminal.setLocalInputEnabled(false)
        #expect(endings() == [Ended(
            id: id, outcome: .cancelled, phase: .live, rebuilds: rebuilds)])
        await Self.mainQueueTurn()
        #expect(terminal.inputViewRebuildCount == rebuilds)
        // A second cancel has no handoff left to report.
        terminal.setLocalInputEnabled(true)
        terminal.setLocalInputEnabled(false)
        #expect(endings().count == 1)
    }

    /// `requestKeyboard()` ends a freeze that no handoff owns (an inherited
    /// keyboard), thawing it; one an accepted handoff owns stands.
    @Test func requestKeyboardEndsOnlyAnUnownedFreeze() async throws {
        let mounted = try await Self.mount()
        defer { Self.unmount(mounted) }
        let terminal = mounted.terminal
        let endings = Self.recordEndings(of: terminal)
        terminal.removeFromSuperview()
        terminal.raisesKeyboardWhenReady = true
        mounted.host.view.addSubview(terminal)
        try #require(terminal.isFirstResponder)
        #expect(terminal.gridReportPhase == .deferring)
        let rebuilds = terminal.inputViewRebuildCount

        terminal.requestKeyboard()
        // An inherited keyboard's thaw rebuilds the input views; no handoff
        // owned it, so no outcome is reported.
        #expect(terminal.inputViewRebuildCount == rebuilds + 1)
        #expect(endings().isEmpty)
        try await waitUntil { terminal.gridReportPhase == .live }

        let id = UUID()
        try #require(terminal.requestKeyboardHandoff(id: id))
        terminal.requestKeyboard()
        #expect(terminal.gridReportPhase == .deferring)
        #expect(endings().isEmpty)
    }
}
