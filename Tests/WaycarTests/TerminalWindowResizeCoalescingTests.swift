import Foundation
import GhosttyTerminal
import Testing
import UIKit

@testable import Waycar

/// Stage Manager live resize changes a window's size on consecutive frames.
/// Every grid the Host hears is a full TUI redraw, so a burst must reach the
/// Host as one PTY resize carrying the grid the window settled on.
@Suite("Terminal window resize coalescing")
struct TerminalWindowResizeCoalescingTests {
    @Test func theFirstLayoutOnlyEstablishesTheBaseline() {
        var tracker = TerminalWindowResizeTracker()

        let first = tracker.windowDidLayout(size: CGSize(width: 1024, height: 768))
        let repeated = tracker.windowDidLayout(size: CGSize(width: 1024, height: 768))
        #expect(!first)
        #expect(!repeated)
    }

    @Test func onlyAChangedWindowSizeCounts() {
        var tracker = TerminalWindowResizeTracker()
        _ = tracker.windowDidLayout(size: CGSize(width: 1024, height: 768))

        let narrower = tracker.windowDidLayout(size: CGSize(width: 900, height: 768))
        let smaller = tracker.windowDidLayout(size: CGSize(width: 880, height: 760))
        // A layout pass for any other reason — the keyboard, a split-view
        // column — leaves the window's size alone.
        let unchanged = tracker.windowDidLayout(size: CGSize(width: 880, height: 760))
        #expect(narrower)
        #expect(smaller)
        #expect(!unchanged)
    }

    /// The first software-keyboard raise on a 13-inch iPad shrinks the terminal
    /// from 1630 to 1100 points while its surface is still 3260 pixels tall:
    /// Ghostty derives a 3x layer scale and an idle terminal never renders
    /// the frame that corrects it. Every size change, the first raise
    /// included, must schedule the follow-up passes, and those passes (which
    /// keep the size) must not schedule more.
    @Test func everyTerminalSizeChangeSchedulesOneScaleSettle() {
        var settle = TerminalSurfaceScaleSettle()
        let keyboardDown = CGSize(width: 1032, height: 1630)
        let keyboardUp = CGSize(width: 1032, height: 1100)

        // `boundsDidLayout` is mutating, so each pass runs outside `#expect`.
        let unsized = settle.boundsDidLayout(size: .zero)
        let firstLayout = settle.boundsDidLayout(size: keyboardDown)
        let repeatedLayout = settle.boundsDidLayout(size: keyboardDown)
        let firstRaise = settle.boundsDidLayout(size: keyboardUp)
        var followUps: [Bool] = []
        for _ in TerminalSurfaceScaleSettle.followUpDelays {
            followUps.append(settle.boundsDidLayout(size: keyboardUp))
        }
        let dismissal = settle.boundsDidLayout(size: keyboardDown)
        let secondRaise = settle.boundsDidLayout(size: keyboardUp)

        #expect(!unsized)
        #expect(firstLayout)
        #expect(!repeatedLayout)
        #expect(firstRaise)
        #expect(followUps == Array(repeating: false, count: followUps.count))
        #expect(dismissal)
        #expect(secondRaise)
    }

    @Test func scaleSettleFollowUpsRunInOrderAfterTheChange() {
        let delays = TerminalSurfaceScaleSettle.followUpDelays
        #expect(!delays.isEmpty)
        #expect(delays.allSatisfy { $0 > 0 })
        #expect(delays == delays.sorted())
        #expect(Set(delays).count == delays.count)
    }

    /// The choke point itself: N grid reports inside one freeze leave as one
    /// resize, the last one.
    @MainActor
    @Test func aBurstOfGridReportsForwardsOnlyTheFinalGrid() async throws {
        var reportedGrids: [TerminalGridSize] = []
        let bridge = TerminalSessionCallbackBridge(
            onSizeChanged: { columns, rows in
                reportedGrids.append(TerminalGridSize(columns: columns, rows: rows))
            },
            onViewportTextChanged: nil,
            onSend: nil,
            onScroll: nil,
            onPaste: nil)
        let phases = TerminalGridReportPhaseRecorder(observing: bridge)

        bridge.beginSizeReportDeferral()
        for step in 0..<12 {
            bridge.resize(
                InMemoryTerminalViewport(columns: UInt16(120 - step), rows: UInt16(40 - step)))
        }
        bridge.finishSizeReportDeferral()

        let forwarded = try await phases.thawedGrid()
        #expect(forwarded == TerminalGridSize(columns: 109, rows: 29))
        #expect(reportedGrids == [TerminalGridSize(columns: 109, rows: 29)])
    }

    /// The trigger, on a real surface: resizing the window several times in
    /// a row holds every grid report, then thaws once with the grid the
    /// surface settled on.
    @MainActor
    @Test func aLiveWindowResizeReportsOnlyTheSettledGrid() async throws {
        var reportedGrids: [TerminalGridSize] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSizeChanged: { columns, rows in
                reportedGrids.append(TerminalGridSize(columns: columns, rows: rows))
            },
            notificationCenter: NotificationCenter())
        terminal.frame = CGRect(x: 0, y: 0, width: 834, height: 1100)
        let controller = UIViewController()
        controller.view = terminal
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }
        try await waitForGhosttyContentLayer(in: terminal)
        terminal.layoutIfNeeded()
        // Let the first layout's own reports land before the burst starts.
        try await Task.sleep(for: .milliseconds(300))
        reportedGrids.removeAll()

        // A layout pass that leaves the window's size alone is not a resize.
        terminal.setNeedsLayout()
        terminal.layoutIfNeeded()
        #expect(terminal.gridReportPhase == .live)

        let phases = TerminalGridReportPhaseRecorder(observing: terminal)
        for step in 1...6 {
            window.frame = CGRect(
                x: 0, y: 0,
                width: 834 - CGFloat(step) * 40,
                height: 1100 - CGFloat(step) * 80)
            window.layoutIfNeeded()
            #expect(terminal.gridReportPhase == .deferring)
        }
        #expect(reportedGrids.isEmpty, "a grid reached the Host mid-resize: \(reportedGrids)")

        let forwarded = try await phases.thawedGrid()
        // Anything still in Ghostty's pipeline gets the chance to leak out.
        try await Task.sleep(for: .milliseconds(300))
        #expect(forwarded == terminal.measuredGrid)
        #expect(
            reportedGrids.count <= 1,
            "the burst reached the Host as \(reportedGrids)")
        if let forwarded {
            #expect(reportedGrids.allSatisfy { $0 == forwarded })
        }
    }

    /// A cancelled freeze throws away the grid it held. The Host has to hear
    /// that grid anyway, and exactly once.
    @MainActor
    @Test func aSettledSizeReportsOnceAndConsumesTheEngineDuplicate() async {
        var reportedGrids: [TerminalGridSize] = []
        let bridge = TerminalSessionCallbackBridge(
            onSizeChanged: { columns, rows in
                reportedGrids.append(TerminalGridSize(columns: columns, rows: rows))
            },
            onViewportTextChanged: nil,
            onSend: nil,
            onScroll: nil,
            onPaste: nil)

        bridge.reportSettledSize(columns: 90, rows: 30)
        #expect(reportedGrids == [TerminalGridSize(columns: 90, rows: 30)])

        // Ghostty's own callback for the same grid, still in its pipeline.
        await withCheckedContinuation { continuation in
            bridge.onViewport = { _ in continuation.resume() }
            bridge.resize(InMemoryTerminalViewport(columns: 90, rows: 30))
        }
        bridge.onViewport = nil

        #expect(reportedGrids == [TerminalGridSize(columns: 90, rows: 30)])
    }

    @MainActor
    @Test func aSettledSizeDuringAFreezeWaitsForTheThaw() async throws {
        var reportedGrids: [TerminalGridSize] = []
        let bridge = TerminalSessionCallbackBridge(
            onSizeChanged: { columns, rows in
                reportedGrids.append(TerminalGridSize(columns: columns, rows: rows))
            },
            onViewportTextChanged: nil,
            onSend: nil,
            onScroll: nil,
            onPaste: nil)
        let phases = TerminalGridReportPhaseRecorder(observing: bridge)

        bridge.beginSizeReportDeferral()
        bridge.reportSettledSize(columns: 90, rows: 30)
        #expect(reportedGrids.isEmpty)
        bridge.finishSizeReportDeferral()

        let forwarded = try await phases.thawedGrid()
        #expect(forwarded == TerminalGridSize(columns: 90, rows: 30))
        #expect(reportedGrids == [TerminalGridSize(columns: 90, rows: 30)])
    }

    /// Disabling local input cancels the grid freeze. When that lands inside
    /// a window resize's settle, the grid the window settled on must still
    /// reach the Host: Ghostty will not report an unchanged grid again.
    @MainActor
    @Test func cancellingAWindowResizeFreezeStillReportsTheSettledGrid() async throws {
        var reportedGrids: [TerminalGridSize] = []
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            onSizeChanged: { columns, rows in
                reportedGrids.append(TerminalGridSize(columns: columns, rows: rows))
            },
            notificationCenter: NotificationCenter())
        terminal.frame = CGRect(x: 0, y: 0, width: 834, height: 1100)
        let controller = UIViewController()
        controller.view = terminal
        let window = try await makeTestWindow(
            frame: terminal.bounds,
            rootViewController: controller)
        defer { window.isHidden = true }
        try await waitForGhosttyContentLayer(in: terminal)
        terminal.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        reportedGrids.removeAll()

        window.frame = CGRect(x: 0, y: 0, width: 700, height: 900)
        window.layoutIfNeeded()
        try #require(terminal.gridReportPhase == .deferring)
        // Stands in for Ghostty's measurement of the resized surface, so the
        // settled grid does not depend on the engine's schedule.
        terminal.terminalDidResize(
            TerminalGridMetrics(
                columns: 71, rows: 33,
                widthPixels: 2_100, heightPixels: 2_640,
                cellWidthPixels: 30, cellHeightPixels: 49))

        terminal.setLocalInputEnabled(false)

        let settled = TerminalGridSize(columns: 71, rows: 33)
        #expect(terminal.gridReportPhase == .live)
        #expect(reportedGrids.first == settled)
        // The cancelled settle must not report it a second time.
        try await Task.sleep(for: .milliseconds(300))
        #expect(
            reportedGrids.filter { $0 == settled }.count == 1,
            "the settled grid reached the Host as \(reportedGrids)")
    }

    /// Keyboard notifications are process-wide. Only the window that owns
    /// the keyboard measures it; another window of the app leaves its
    /// terminal's inset alone (#157).
    @Test func onlyTheKeyWindowOwnsTheKeyboard() {
        #expect(
            TerminalKeyboardInset.windowOwnsKeyboard(
                isKeyWindow: true, isSceneKeyWindow: true, activationState: .foregroundActive))
        #expect(
            !TerminalKeyboardInset.windowOwnsKeyboard(
                isKeyWindow: false, isSceneKeyWindow: true, activationState: .foregroundActive))
        #expect(
            !TerminalKeyboardInset.windowOwnsKeyboard(
                isKeyWindow: false, isSceneKeyWindow: false, activationState: .foregroundActive))
    }

    /// UIKit restores the keyboard while a scene is still foregrounding, and
    /// no window is key yet; the scene's own key window stands in there.
    @Test func aForegroundingSceneMeasuresThroughItsOwnKeyWindow() {
        #expect(
            TerminalKeyboardInset.windowOwnsKeyboard(
                isKeyWindow: false, isSceneKeyWindow: true, activationState: .foregroundInactive))
        #expect(
            !TerminalKeyboardInset.windowOwnsKeyboard(
                isKeyWindow: false, isSceneKeyWindow: false, activationState: .foregroundInactive))
        #expect(
            !TerminalKeyboardInset.windowOwnsKeyboard(
                isKeyWindow: true, isSceneKeyWindow: true, activationState: .background))
    }
}
