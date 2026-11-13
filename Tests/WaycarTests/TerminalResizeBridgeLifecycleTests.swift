import Foundation
import GhosttyTerminal
import Testing

@testable import Waycar

/// Owner pins for the resize callback bridge (ATTACH-15): what a callback
/// sees of the bridge while it runs, and what the bridge decides after a
/// callback re-entered it. Existing API only.
@MainActor
@Suite("Terminal resize bridge lifecycle")
struct TerminalResizeBridgeLifecycleTests {
    private static func makeBridge() -> TerminalSessionCallbackBridge {
        TerminalSessionCallbackBridge(
            onSizeChanged: nil, onViewportTextChanged: nil,
            onSend: nil, onScroll: nil, onPaste: nil)
    }

    private static func grid(_ columns: Int, _ rows: Int) -> TerminalGridSize {
        TerminalGridSize(columns: columns, rows: rows)
    }

    /// `onViewport` runs before the bridge decides whether the size is held:
    /// a freeze it begins holds that very report, which the thaw forwards.
    @Test func aFreezeBegunInsideOnViewportHoldsThatReportsSize() async throws {
        let bridge = Self.makeBridge()
        var sizes: [TerminalGridSize] = []
        var phases: [TerminalGridReportPhase] = []
        var forwarded: [TerminalGridSize?] = []
        var viewports = 0
        bridge.onSizeChanged = { sizes.append(Self.grid($0, $1)) }
        bridge.onViewport = { _ in
            viewports += 1
            if viewports == 1 { bridge.beginSizeReportDeferral() }
        }
        bridge.onGridReportPhaseChanged = { phase, grid in
            phases.append(phase)
            if phase == .live { forwarded.append(grid) }
        }
        defer {
            bridge.onSizeChanged = nil
            bridge.onViewport = nil
            bridge.onGridReportPhaseChanged = nil
        }

        bridge.resize(InMemoryTerminalViewport(columns: 80, rows: 24))
        try await waitUntil { viewports == 1 }
        #expect(sizes.isEmpty)
        #expect(bridge.gridReportPhase == .deferring)

        bridge.finishSizeReportDeferral()
        #expect(bridge.gridReportPhase == .live)
        #expect(sizes == [Self.grid(80, 24)])
        #expect(phases == [.deferring, .flushing, .live])
        #expect(forwarded == [Self.grid(80, 24)])
    }

    /// A thaw requested inside `onViewport` forwards the grid held before
    /// that report; the report itself is then delivered live, after it.
    @Test func aThawRequestedInsideOnViewportForwardsTheHeldGridFirst() async throws {
        let bridge = Self.makeBridge()
        var sizes: [TerminalGridSize] = []
        var viewports = 0
        bridge.onSizeChanged = { sizes.append(Self.grid($0, $1)) }
        bridge.onViewport = { _ in
            viewports += 1
            bridge.finishSizeReportDeferral()
        }
        defer {
            bridge.onSizeChanged = nil
            bridge.onViewport = nil
        }
        bridge.beginSizeReportDeferral()
        bridge.provideAuthoritativeDeferredSize(columns: 60, rows: 12)

        bridge.resize(InMemoryTerminalViewport(columns: 70, rows: 20))
        try await waitUntil { viewports == 1 }
        #expect(bridge.gridReportPhase == .live)
        #expect(sizes == [Self.grid(60, 12), Self.grid(70, 20)])
    }

    /// The thaw records its duplicate-suppression token after `onSizeChanged`
    /// returns, so a settled report made from inside that callback is
    /// delivered but its token is replaced by the thaw's own.
    @Test func theThawsSuppressionTokenOutlivesAReportMadeInsideItsCallback() async throws {
        let bridge = Self.makeBridge()
        var sizes: [TerminalGridSize] = []
        bridge.onSizeChanged = { columns, rows in
            sizes.append(Self.grid(columns, rows))
            if sizes.count == 1 { bridge.reportSettledSize(columns: 70, rows: 20) }
        }
        defer { bridge.onSizeChanged = nil }
        bridge.beginSizeReportDeferral()
        bridge.provideAuthoritativeDeferredSize(columns: 60, rows: 12)
        bridge.finishSizeReportDeferral()
        #expect(bridge.gridReportPhase == .live)
        #expect(sizes == [Self.grid(60, 12), Self.grid(70, 20)])

        // The engine's own copy of the thaw grid is consumed once; the
        // nested report's grid is not suppressed.
        bridge.resize(InMemoryTerminalViewport(columns: 60, rows: 12))
        bridge.resize(InMemoryTerminalViewport(columns: 70, rows: 20))
        try await waitUntil { sizes.count == 3 }
        #expect(sizes == [Self.grid(60, 12), Self.grid(70, 20), Self.grid(70, 20)])
    }

    /// Phase notifications are recorded as sent before their callback runs,
    /// so a freeze begun from the `.live` callback is reported nested.
    @Test func aFreezeBegunFromTheLiveCallbackIsReportedNested() async throws {
        let bridge = Self.makeBridge()
        var phases: [TerminalGridReportPhase] = []
        var forwarded: [TerminalGridSize?] = []
        var sizes: [TerminalGridSize] = []
        var viewports = 0
        bridge.onSizeChanged = { sizes.append(Self.grid($0, $1)) }
        bridge.onViewport = { _ in viewports += 1 }
        bridge.onGridReportPhaseChanged = { phase, grid in
            phases.append(phase)
            forwarded.append(grid)
            if phase == .live, phases.count == 3 { bridge.beginSizeReportDeferral() }
        }
        defer {
            bridge.onSizeChanged = nil
            bridge.onViewport = nil
            bridge.onGridReportPhaseChanged = nil
        }
        bridge.beginSizeReportDeferral()
        bridge.provideAuthoritativeDeferredSize(columns: 60, rows: 12)
        bridge.finishSizeReportDeferral()

        #expect(phases == [.deferring, .flushing, .live, .deferring])
        #expect(forwarded == [nil, nil, Self.grid(60, 12), nil])
        #expect(bridge.gridReportPhase == .deferring)
        // The nested freeze cleared the thaw's suppression token: the
        // engine's copy of the thaw grid is now held, not dropped.
        bridge.resize(InMemoryTerminalViewport(columns: 60, rows: 12))
        bridge.resize(InMemoryTerminalViewport(columns: 61, rows: 12))
        try await waitUntil { viewports == 2 }
        #expect(sizes == [Self.grid(60, 12)])
        bridge.finishSizeReportDeferral()
        #expect(phases.count == 6)
        #expect(sizes == [Self.grid(60, 12), Self.grid(61, 12)])
        #expect(forwarded.last == Self.grid(61, 12))
    }

    /// A report the surface no longer measures reaches neither callback,
    /// yet its arrival is what lets a flushing thaw complete.
    @Test func aStaleReportIsDroppedButStillCompletesTheThaw() async throws {
        let bridge = Self.makeBridge()
        var sizes: [TerminalGridSize] = []
        var viewports = 0
        var forwarded: [TerminalGridSize?] = []
        var currentnessChecks = 0
        bridge.isSizeReportCurrent = { _, _ in
            currentnessChecks += 1
            return false
        }
        bridge.onSizeChanged = { sizes.append(Self.grid($0, $1)) }
        bridge.onViewport = { _ in viewports += 1 }
        bridge.onGridReportPhaseChanged = { phase, grid in
            if phase == .live { forwarded.append(grid) }
        }
        defer {
            bridge.onSizeChanged = nil
            bridge.onViewport = nil
            bridge.onGridReportPhaseChanged = nil
            bridge.isSizeReportCurrent = nil
        }
        bridge.beginSizeReportDeferral()
        bridge.resize(InMemoryTerminalViewport(columns: 80, rows: 24))
        bridge.finishSizeReportDeferral()
        #expect(bridge.gridReportPhase == .flushing)

        try await waitUntil { bridge.gridReportPhase == .live }
        #expect(currentnessChecks == 1)
        #expect(viewports == 0)
        #expect(sizes.isEmpty)
        #expect(forwarded == [nil])
    }

    /// A cancelled freeze drops its held grid and every report already in
    /// flight; the next report is delivered live.
    @Test func cancellingDiscardsTheHeldGridAndInFlightReports() async throws {
        let bridge = Self.makeBridge()
        var sizes: [TerminalGridSize] = []
        var viewports: [UInt16] = []
        var phases: [TerminalGridReportPhase] = []
        bridge.onSizeChanged = { sizes.append(Self.grid($0, $1)) }
        bridge.onViewport = { viewports.append($0.columns) }
        bridge.onGridReportPhaseChanged = { phase, _ in phases.append(phase) }
        defer {
            bridge.onSizeChanged = nil
            bridge.onViewport = nil
            bridge.onGridReportPhaseChanged = nil
        }
        bridge.beginSizeReportDeferral()
        bridge.provideAuthoritativeDeferredSize(columns: 60, rows: 12)
        bridge.resize(InMemoryTerminalViewport(columns: 80, rows: 24))
        bridge.cancelSizeReportDeferral()
        #expect(bridge.gridReportPhase == .live)

        bridge.resize(InMemoryTerminalViewport(columns: 90, rows: 30))
        try await waitUntil { sizes.count == 1 }
        #expect(sizes == [Self.grid(90, 30)])
        #expect(viewports == [90])
        #expect(phases == [.deferring, .live])
    }

    /// A settled report while frozen becomes the grid the thaw forwards,
    /// and the engine's duplicate of it is consumed once afterwards.
    @Test func aSettledReportWhileFrozenIsTheThawGrid() async throws {
        let bridge = Self.makeBridge()
        var sizes: [TerminalGridSize] = []
        bridge.onSizeChanged = { sizes.append(Self.grid($0, $1)) }
        defer { bridge.onSizeChanged = nil }
        bridge.beginSizeReportDeferral()
        bridge.reportSettledSize(columns: 50, rows: 10)
        #expect(sizes.isEmpty)
        bridge.finishSizeReportDeferral()
        #expect(sizes == [Self.grid(50, 10)])

        bridge.resize(InMemoryTerminalViewport(columns: 50, rows: 10))
        bridge.resize(InMemoryTerminalViewport(columns: 50, rows: 10))
        try await waitUntil { sizes.count == 2 }
        #expect(sizes == [Self.grid(50, 10), Self.grid(50, 10)])
        // A thaw without a freeze, or an authoritative grid outside one,
        // changes nothing.
        bridge.finishSizeReportDeferral()
        bridge.provideAuthoritativeDeferredSize(columns: 1, rows: 1)
        #expect(bridge.gridReportPhase == .live)
        #expect(sizes.count == 2)
    }
}
