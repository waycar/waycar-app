import Foundation
import Observation
import SwiftUI
import Testing
import UIKit

@testable import Waycar

/// Owner pins for the Composer-to-terminal keyboard handoff (ATTACH-11),
/// through a hosted Agent screen: the update-time destination claim, its
/// refusal, the mode switch on acceptance, and the order in which the
/// shared inset's freeze is released. Existing API only.
@MainActor
@Suite("Composer to Direct Input handoff lifecycle", .serialized)
struct ComposerDirectHandoffLifecycleTests {
    /// Records, at every change of the inset's handoff, whether Message
    /// Agent was still open and whether the freeze was being released. The
    /// change is reported from `willSet` and re-armed there, so a release
    /// sees the screen's state at that instant. Begins and releases
    /// alternate in these tests, so each change flips `wasHolding`.
    @MainActor
    private final class HandoffReleases {
        struct Change: Equatable {
            let releasing: Bool
            let messageAgentOpen: Bool?
        }

        private(set) var changes: [Change] = []
        private let inset: TerminalKeyboardInset
        private let probe: AgentTerminalInteractionProbe

        init(_ inset: TerminalKeyboardInset, probe: AgentTerminalInteractionProbe) {
            self.inset = inset
            self.probe = probe
            track(wasHolding: inset.activeResponderHandoffID != nil)
        }

        private func track(wasHolding: Bool) {
            withObservationTracking {
                _ = inset.activeResponderHandoffID
            } onChange: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.changes.append(Change(
                        releasing: wasHolding, messageAgentOpen: self.probe.isMessageAgentOpen))
                    self.track(wasHolding: !wasHolding)
                }
            }
        }
    }

    @Test func aRefusedDestinationKeepsMessageAgentAndTheNextTapHandsOver() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        composer.replaceDraft(with: "keep me")
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let probe = AgentTerminalInteractionProbe()
        let inset = TerminalKeyboardInset(notificationCenter: NotificationCenter())
        inset.destinationResponderHandoffFallbackDelay = .seconds(60)
        // The draft's focus readies the inset for the system keyboard, which
        // starts a confirmation this keeps pending: the signal that the
        // Composer presents `.system`, the handoff's precondition.
        inset.dismissalConfirmationDelay = .seconds(60)
        var onStage = true
        let releases = HandoffReleases(inset, probe: probe)
        let controller = UIHostingController(rootView: Self.makeView(
            attachStore: owner, composer: composer, keyboardInset: inset,
            probe: probe, isOnStage: { onStage }))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try await waitUntil { probe.isConnected }
        try #require(probe.isConnected)

        // 💬 opens Message Agent and focuses its draft: the system keyboard.
        #expect(probe.tapMessageAgent())
        let input = try #require(try await Self.composerInputFirstResponder(in: controller))
        try await waitUntil { inset.isConfirmingDismissal }
        let terminal = try #require(Self.terminals(in: controller.view).first)
        try await waitUntil { !terminal.isLocalInputEnabled }
        try #require(!terminal.isLocalInputEnabled)

        // ⌨ begins the handoff; the screen leaves the stage before the
        // update-time claim reaches the terminal, which refuses it.
        #expect(probe.tapTerminalKeyboard())
        let refused = try #require(inset.activeResponderHandoffID)
        onStage = false
        try await waitUntil { inset.activeResponderHandoffID == nil }
        controller.view.layoutIfNeeded()
        #expect(releases.changes == [
            .init(releasing: false, messageAgentOpen: true),
            .init(releasing: true, messageAgentOpen: true),
        ])
        #expect(probe.isMessageAgentOpen == true)
        #expect(!terminal.isFirstResponder)
        try await waitUntil { !terminal.isLocalInputEnabled }
        #expect(input.isFirstResponder)

        // Nothing is left in flight: the next ⌨ hands the keyboard over.
        onStage = true
        #expect(probe.tapTerminalKeyboard())
        let accepted = try #require(inset.activeResponderHandoffID)
        #expect(accepted != refused)
        // A second ⌨ or 💬 while it moves is ignored.
        #expect(probe.tapTerminalKeyboard())
        #expect(probe.tapMessageAgent())
        #expect(inset.activeResponderHandoffID == accepted)
        try await waitUntil {
            controller.view.layoutIfNeeded()
            return inset.activeResponderHandoffID == nil
                && probe.isMessageAgentOpen == false
                && terminal.isFirstResponder
                && terminal.isLocalInputEnabled
        }
        // The mode switched to Direct Input before the freeze was released.
        #expect(releases.changes.count == 4)
        #expect(releases.changes.last == .init(releasing: true, messageAgentOpen: false))
        #expect(composer.draft == "keep me")
        #expect(await transport.agentPromptParams.isEmpty)

        // The handoff is spent: 💬 opens Message Agent again.
        #expect(probe.tapMessageAgent())
        try await waitUntil { probe.isMessageAgentOpen == true }
        await owner.leave().value
    }

    // MARK: Fixtures

    private static func makeLiveAttach(
        transport: ScriptedTransport,
        composer: AgentComposerStore
    ) async throws -> AgentAttachStore {
        let owner = AgentAttachStore(
            target: .agentPane("w1:p1"),
            transportGeneration: 1,
            recordsNetworkTelemetry: true,
            isOnStage: { true },
            runTerminal: { request, handler in
                let session = try await transport.attachTerminal(request)
                try await handler.runEndingSession(session)
            },
            stageImage: { _, _ in throw TransportError.cancelled },
            stageFile: { _, _ in throw TransportError.cancelled },
            composer: composer,
            closePane: {})
        owner.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { await transport.attachRequests.count == 1 }
        #expect(await transport.emitAttachOutput(Data("live".utf8)))
        try await waitUntil { owner.terminalStatus == AttachTerminalStore.Status.live }
        return owner
    }

    private static func makeView(
        attachStore: AgentAttachStore,
        composer: AgentComposerStore,
        keyboardInset: TerminalKeyboardInset,
        probe: AgentTerminalInteractionProbe,
        isOnStage: @escaping () -> Bool
    ) -> some View {
        let defaults = UserDefaults(suiteName: "composer-direct-\(UUID())") ?? .standard
        let console = ConsoleStore(snapshotRetryDelay: .seconds(30)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { throw TransportError.sshUnreachable(detail: "fixture") },
                reconnectPolicy: .default,
                keepalive: .default)
        }
        let terminal = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults),
            toolbars: AgentToolbarLayoutStore(defaults: defaults, idiom: .phone))
        let agent = ConsoleAgent(
            hostID: UUID(),
            hostName: "devbox",
            agent: Agent(
                terminalID: "term_w1:p1", kind: "claude", title: "",
                status: .idle, workspaceID: "w", tabID: "w:t", paneID: "w1:p1",
                cwd: "/work", revision: 1, name: nil),
            workspaceLabel: nil,
            repositoryCheckout: nil)
        return AgentTerminalView(
            agent: agent,
            console: console,
            terminal: terminal,
            hosts: [],
            activity: AppActivityCoordinator(),
            keyboardHandoff: TerminalKeyboardHandoff(),
            keyboardInset: keyboardInset,
            isOnStage: isOnStage,
            onSwitch: { _ in },
            onClosed: {},
            composer: composer,
            attachStore: attachStore,
            interactionProbe: probe)
    }

    private static func composerInputFirstResponder(
        in controller: UIViewController
    ) async throws -> UITextView? {
        var input: UITextView?
        try await waitUntil {
            controller.view.layoutIfNeeded()
            input = firstView(in: controller.view) {
                $0 is UITextView && $0.accessibilityLabel == "Message the Agent"
            } as? UITextView
            return input != nil
        }
        guard let input else { return nil }
        // The focus request usually lands on its own; asking again is what
        // a tap into the draft would do.
        if !input.isFirstResponder { input.becomeFirstResponder() }
        try await waitUntil { input.isFirstResponder }
        return input.isFirstResponder ? input : nil
    }

    private static func terminals(in root: UIView) -> [WaycarTerminalView] {
        var found: [WaycarTerminalView] = []
        func walk(_ view: UIView) {
            if let terminal = view as? WaycarTerminalView { found.append(terminal) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private static func firstView(in root: UIView, matching: (UIView) -> Bool) -> UIView? {
        if matching(root) { return root }
        for subview in root.subviews {
            if let match = firstView(in: subview, matching: matching) { return match }
        }
        return nil
    }
}
