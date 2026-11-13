import Foundation
import GhosttyTerminal
import SwiftUI
import Testing
import UIKit

@testable import Waycar

/// Safety nets for the UIKit-bound rows deferred until their Mac conversion.
/// All tests use existing owner APIs; no new production seams.
@MainActor
@Suite("Terminal keyboard lifecycle owners")
struct TerminalKeyboardLifecycleOwnerTests {
    @Test func anOffstageAgentCannotSwitchInputOrRaiseItsKeyboard() async throws {
        let suite = "offstage-input-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let console = ConsoleStore(snapshotRetryDelay: .seconds(30)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { throw TransportError.cancelled },
                reconnectPolicy: .default, keepalive: .default)
        }
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            throw TransportError.cancelled
        }
        let owner = AgentAttachStore(
            target: .agentPane("w1:p1"), transportGeneration: 1,
            recordsNetworkTelemetry: false, isOnStage: { false },
            runTerminal: { _, _ in throw TransportError.cancelled },
            stageImage: { _, _ in throw TransportError.cancelled },
            stageFile: { _, _ in throw TransportError.cancelled },
            composer: composer, closePane: {})
        let settings = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults),
            toolbars: AgentToolbarLayoutStore(defaults: defaults, idiom: .phone))
        let agent = ConsoleAgent(
            hostID: UUID(), hostName: "fixture",
            agent: Agent(
                terminalID: "term_w1:p1", kind: "claude", title: "", status: .idle,
                workspaceID: "w", tabID: "w:t", paneID: "w1:p1", cwd: "/work",
                revision: 1, name: nil),
            workspaceLabel: nil, repositoryCheckout: nil)
        let probe = AgentTerminalInteractionProbe()
        let controller = UIHostingController(rootView: AgentTerminalView(
            agent: agent, console: console, terminal: settings, hosts: [],
            activity: AppActivityCoordinator(), keyboardHandoff: TerminalKeyboardHandoff(),
            keyboardInset: TerminalKeyboardInset(notificationCenter: NotificationCenter()),
            isOnStage: { false }, onSwitch: { _ in }, onClosed: {},
            composer: composer, attachStore: owner, interactionProbe: probe))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try await waitUntil { probe.isConnected }

        #expect(probe.isMessageAgentOpen == false)
        #expect(probe.isTerminalKeyboardUp == false)
        #expect(probe.tapMessageAgent())
        #expect(probe.tapTerminalKeyboard())
        #expect(probe.isMessageAgentOpen == false)
        #expect(probe.isTerminalKeyboardUp == false)
        await owner.leave().value
    }

    @Test func aReplacementInsetHandoffKeepsItsDismissalDebtAndIgnoresOldExits() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center, measure: { _ in 300 })
        inset.responderHandoffFallbackDelay = .seconds(60)
        inset.destinationResponderHandoffFallbackDelay = .seconds(60)
        inset.dismissalConfirmationDelay = .seconds(60)
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey:
                CGRect(x: 0, y: 400, width: 400, height: 300)])
        try await waitUntil { inset.height == 300 }
        let old = inset.beginResponderHandoff()
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        let replacement = inset.beginDestinationOwnedResponderHandoff()
        var staleMeasurements = 0

        inset.endResponderHandoff(old, currentHeight: { staleMeasurements += 1; return 0 })
        inset.cancelResponderHandoff(old, currentHeight: { staleMeasurements += 1; return 0 })
        #expect(staleMeasurements == 0)
        #expect(inset.activeResponderHandoffID == replacement)
        #expect(inset.height == 300)
        #expect(!inset.isConfirmingDismissal)

        inset.endResponderHandoff(replacement, currentHeight: { 0 })
        #expect(!inset.isHoldingHandoffHeight)
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 300)
        #expect(inset.isConfirmingDismissal)
    }

    @Test func cancellingASurfaceHandoffInvalidatesItsQueuedInputViewReload() async throws {
        let terminal = TerminalScreenView.makeConfiguredTerminal(
            notificationCenter: NotificationCenter())
        terminal.keyboardTransitionFallbackDelay = 60
        let host = UIViewController()
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 700),
            rootViewController: host)
        defer {
            terminal.removeFromSuperview()
            window.isHidden = true
        }
        terminal.frame = host.view.bounds
        host.view.addSubview(terminal)
        window.layoutIfNeeded()
        let id = UUID()
        var outcomes: [TerminalKeyboardHandoffOutcome] = []
        terminal.onKeyboardHandoffEnded = { ended, outcome in
            if ended == id { outcomes.append(outcome) }
        }
        try #require(terminal.requestKeyboardHandoff(id: id))
        terminal.keyboardFrameDidSettle()
        terminal.setLocalInputEnabled(false)
        let rebuilds = terminal.inputViewRebuildCount
        // FIFO barrier for the DispatchQueue reload scheduled above, not a
        // timing guess or a yield loop.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }

        #expect(terminal.inputViewRebuildCount == rebuilds)
        #expect(terminal.gridReportPhase == .live)
        #expect(outcomes == [.cancelled])
    }

    @Test func aPreFreezeQueuedResizeCannotReplaceTheAuthoritativeThawGrid() async throws {
        let bridge = TerminalSessionCallbackBridge(
            onSizeChanged: nil, onViewportTextChanged: nil,
            onSend: nil, onScroll: nil, onPaste: nil)
        var sizes: [TerminalGridSize] = []
        var viewports = 0
        var sizesAtLiveNotification: [Int] = []
        bridge.onSizeChanged = { columns, rows in
            #expect(bridge.gridReportPhase == .live)
            sizes.append(TerminalGridSize(columns: columns, rows: rows))
        }
        bridge.onViewport = { _ in viewports += 1 }
        bridge.onGridReportPhaseChanged = { phase, _ in
            if phase == .live { sizesAtLiveNotification.append(sizes.count) }
        }
        defer {
            bridge.onSizeChanged = nil
            bridge.onGridReportPhaseChanged = nil
        }
        bridge.resize(InMemoryTerminalViewport(columns: 80, rows: 24))
        bridge.beginSizeReportDeferral()
        bridge.provideAuthoritativeDeferredSize(columns: 60, rows: 12)
        bridge.finishSizeReportDeferral()
        #expect(bridge.gridReportPhase == .flushing)

        try await waitUntil { bridge.gridReportPhase == .live }
        #expect(viewports == 0)
        #expect(sizes == [TerminalGridSize(columns: 60, rows: 12)])
        #expect(sizesAtLiveNotification == [1])
    }
}
