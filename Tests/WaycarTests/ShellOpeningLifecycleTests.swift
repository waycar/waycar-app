import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Waycar

/// Owner pins for Shell opening (ATTACH-21) through a hosted Agent detail:
/// New Terminal's creation and inventory wait across awaits, the identity it
/// remembers for a retry, its visibility check, and the shell keyboard
/// handoff token it owns. Taps go through the terminal screen's Toolbar
/// dispatcher, as a tap on Open Terminal would.
@MainActor
@Suite("Shell opening lifecycle", .serialized)
struct ShellOpeningLifecycleTests {
    private static let agentPane = "w1:p1"
    private static let shellPane = "w1:p-shell"

    @MainActor
    private final class Fixture {
        let host = Host.fixture()
        let transport: ScriptedTransport
        let console: ConsoleStore
        let handoff = TerminalKeyboardHandoff()
        let probe = AgentTerminalInteractionProbe()
        let registry = ConsoleCommandRegistry()
        var visible = true
        var switched: [ConsoleAgent.ID] = []
        /// The handoff's state at each switch, read before anything else runs.
        var armedModesAtSwitch: [TerminalKeyboardMode?] = []
        var window: UIWindow?
        var controller: UIViewController?
        var agent: ConsoleAgent?
        var attach: AgentAttachStore?

        var shellID: ConsoleAgent.ID { ConsoleAgent.ID(hostID: host.id, paneID: shellPane) }

        init() {
            let transport = ScriptedTransport(snapshot: ShellOpeningLifecycleTests.snapshot(withShell: false))
            self.transport = transport
            console = ConsoleStore { _, _, subscriptions in
                EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
            }
        }

        func mount() async throws {
            console.setHosts([host])
            await console.resume()
            try await waitUntil { console.agents.contains { $0.agent.paneID == agentPane } }
            let agent = try #require(console.agents.first { $0.agent.paneID == agentPane })
            self.agent = agent
            #expect(agent.shellTerminalCreationRequest != nil)
            let defaults = UserDefaults(suiteName: "shell-opening-\(UUID())") ?? .standard
            let composer = console.composerStore(for: agent)
            let transport = transport
            // An injected Attach: no retention swap rebuilds the terminal
            // screen (and its probe connection) under the test.
            let attach = AgentAttachStore(
                target: agent.attachTarget, transportGeneration: 1,
                recordsNetworkTelemetry: false, isOnStage: { true },
                runTerminal: { request, handler in
                    let session = try await transport.attachTerminal(request)
                    try await handler.runEndingSession(session)
                },
                stageImage: { _, _ in throw TransportError.cancelled },
                stageFile: { _, _ in throw TransportError.cancelled },
                composer: composer, closePane: {})
            self.attach = attach
            let detail = AgentDetailView(
                agent: agent, console: console,
                terminal: TerminalSettings(
                    themes: TerminalThemeSettings(defaults: defaults),
                    zoom: TerminalZoomSettings(defaults: defaults),
                    fonts: TerminalFontSettings(defaults: defaults),
                    snippets: SnippetStore(defaults: defaults),
                    toolbars: AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)),
                hosts: [host], activity: AppActivityCoordinator(), keyboardHandoff: handoff,
                keyboardInset: TerminalKeyboardInset(notificationCenter: NotificationCenter()),
                stage: AgentDetailStage(
                    isVisible: { [weak self] in self?.visible ?? false }, terminalAccess: { .holds }),
                onSwitch: { [weak self] id in
                    guard let self else { return }
                    self.switched.append(id)
                    self.armedModesAtSwitch.append(self.handoff.mode(for: id))
                },
                onClosed: {}, composerStore: composer, attachStore: attach,
                interactionProbe: probe)
                .environment(\.consoleCommandRegistry, registry)
            let controller = UIHostingController(rootView: detail)
            self.controller = controller
            window = try await makeTestWindow(
                frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller)
            try await waitUntil { probe.isConnected }
        }

        func teardown() async {
            controller?.dismiss(animated: false)
            await attach?.leave().value
            console.setHosts([])
            await console.agentTerminals.suspend()
            window?.isHidden = true
            window?.rootViewController = nil
        }

        @discardableResult
        func tapOpenTerminal() -> Bool {
            probe.performToolbarItem(.action(.openTerminal))
        }

        var failureIsPresented: Bool {
            guard let agent else { return false }
            return registry.isDetailPresenting(for: agent.id)
        }

        var presentedAlertMessage: String? {
            (controller?.presentedViewController as? UIAlertController)?.message
        }
    }

    static func snapshot(withShell: Bool) -> SessionSnapshot {
        func pane(_ id: String, tab: String, agent: String?) -> PaneInfo {
            PaneInfo(
                agentStatus: .idle, focused: false, paneID: id, revision: 1,
                tabID: tab, terminalID: agent == nil ? "term-shell" : "term_\(id)",
                workspaceID: "w1", agent: agent, cwd: "/work/w1",
                terminalTitleStripped: agent == nil ? "Shell" : "Task")
        }
        var panes = [pane(agentPane, tab: "w1:t1", agent: "claude")]
        var tabs = [TabInfo(
            agentStatus: .idle, focused: false, label: "Main", number: 1, paneCount: 1,
            tabID: "w1:t1", workspaceID: "w1")]
        if withShell {
            panes.append(pane(shellPane, tab: "w1:t-shell", agent: nil))
            tabs.append(TabInfo(
                agentStatus: .idle, focused: false, label: "Shell", number: 2, paneCount: 1,
                tabID: "w1:t-shell", workspaceID: "w1"))
        }
        return SessionSnapshot(
            agents: [.fixture(paneID: agentPane)], layouts: [], panes: panes,
            protocolVersion: 22, tabs: tabs,
            version: "0.9.3-fake",
            workspaces: [.fixture(workspaceID: "w1", label: "Work")])
    }

    /// New Terminal with the keyboard down: one creation, refused re-entry
    /// while it runs, the row awaited, then the shell opened with nothing
    /// armed for it.
    @Test func aNewTerminalOpensOnceItsRowArrives() async throws {
        let fixture = Fixture()
        let gate = ScriptedTransportCallGate()
        await fixture.transport.scriptShellTerminalCreation(snapshotAfter: Self.snapshot(withShell: true))
        await fixture.transport.gateNextShellTerminalCreation(using: gate)
        func run() async throws {
            try await fixture.mount()
            #expect(fixture.tapOpenTerminal())
            try await waitUntil { await fixture.transport.shellTerminalCreations.count == 1 }
            fixture.tapOpenTerminal()
            await gate.open()
            try await waitUntil { fixture.switched == [fixture.shellID] }
            #expect(await fixture.transport.shellTerminalCreations.count == 1)
            #expect(fixture.armedModesAtSwitch == [nil])
            #expect(!fixture.handoff.isArmed)
            #expect(!fixture.failureIsPresented)
        }
        do { try await run() } catch { await fixture.teardown(); throw error }
        await fixture.teardown()
    }

    /// A creation whose row has not reached the Console yet reports it, and
    /// the next Open Terminal refreshes the remembered terminal instead of
    /// creating another.
    @Test func aTerminalCreatedBeforeItsRowIsRetriedNotDuplicated() async throws {
        let fixture = Fixture()
        func run() async throws {
            try await fixture.mount()
            #expect(fixture.tapOpenTerminal())
            try await waitUntil { fixture.failureIsPresented }
            if let message = fixture.presentedAlertMessage {
                #expect(message.contains("hasn't refreshed yet"))
            }
            #expect(fixture.switched.isEmpty)
            #expect(await fixture.transport.shellTerminalCreations.count == 1)

            await fixture.transport.setSnapshot(Self.snapshot(withShell: true))
            #expect(fixture.tapOpenTerminal())
            try await waitUntil { fixture.switched == [fixture.shellID] }
            #expect(await fixture.transport.shellTerminalCreations.count == 1)
        }
        do { try await run() } catch { await fixture.teardown(); throw error }
        await fixture.teardown()
    }

    /// A raised keyboard is carried to the created shell in the mode it was
    /// armed in: the tools dock stays a tools dock.
    @Test func aRaisedKeyboardIsCarriedToTheCreatedShellInItsMode() async throws {
        let fixture = Fixture()
        await fixture.transport.scriptShellTerminalCreation(snapshotAfter: Self.snapshot(withShell: true))
        func run() async throws {
            try await fixture.mount()
            #expect(fixture.probe.performToolbarItem(.action(.toolsKeyboard)))
            try await waitUntil { fixture.probe.isTerminalKeyboardUp == true }
            #expect(fixture.tapOpenTerminal())
            try await waitUntil { fixture.switched == [fixture.shellID] }
            #expect(fixture.armedModesAtSwitch == [.controls])
        }
        do { try await run() } catch { await fixture.teardown(); throw error }
        await fixture.teardown()
    }

    /// A rejected creation says why, releases only the shell handoff this
    /// detail armed (a newer opening keeps its own), and leaves Open Terminal
    /// usable again.
    @Test func aRejectedCreationReleasesOnlyItsOwnShellHandoff() async throws {
        let fixture = Fixture()
        let gate = ScriptedTransportCallGate()
        await fixture.transport.scriptShellTerminalCreation(
            failure: TransportError.apiRejected(code: "gone", message: "Workspace is gone"))
        await fixture.transport.gateNextShellTerminalCreation(using: gate)
        func run() async throws {
            try await fixture.mount()
            #expect(fixture.probe.performToolbarItem(.action(.toolsKeyboard)))
            try await waitUntil { fixture.probe.isTerminalKeyboardUp == true }
            #expect(fixture.tapOpenTerminal())
            try await waitUntil { await fixture.transport.shellTerminalCreations.count == 1 }
            #expect(fixture.handoff.isArmed)
            // Another opening arms its own handoff while this one runs.
            let newer = fixture.handoff.armShellTerminal(mode: .text)
            await gate.open()
            try await waitUntil { fixture.failureIsPresented }
            if let message = fixture.presentedAlertMessage {
                #expect(message == "Herdr TUI couldn't create the terminal: Workspace is gone")
            }
            #expect(fixture.handoff.shellTerminalToken == newer)
            #expect(fixture.switched.isEmpty)

            fixture.handoff.cancelShellTerminal(ifOwnedBy: newer)
            await fixture.transport.scriptShellTerminalCreation(snapshotAfter: Self.snapshot(withShell: true))
            fixture.tapOpenTerminal()
            try await waitUntil { fixture.switched == [fixture.shellID] }
            #expect(await fixture.transport.shellTerminalCreations.count == 2)
        }
        do { try await run() } catch { await fixture.teardown(); throw error }
        await fixture.teardown()
    }

    /// A shell that arrives after the detail stopped being visible is not
    /// opened, and the handoff armed for it is released.
    @Test func aShellArrivingAfterTheDetailLeftIsNotOpened() async throws {
        let fixture = Fixture()
        let gate = ScriptedTransportCallGate()
        await fixture.transport.scriptShellTerminalCreation(snapshotAfter: Self.snapshot(withShell: true))
        await fixture.transport.gateNextShellTerminalCreation(using: gate)
        func run() async throws {
            try await fixture.mount()
            #expect(fixture.probe.performToolbarItem(.action(.toolsKeyboard)))
            try await waitUntil { fixture.probe.isTerminalKeyboardUp == true }
            #expect(fixture.tapOpenTerminal())
            try await waitUntil { await fixture.transport.shellTerminalCreations.count == 1 }
            #expect(fixture.handoff.isArmed)
            fixture.visible = false
            await gate.open()
            try await waitUntil { !fixture.handoff.isArmed }
            #expect(fixture.switched.isEmpty)
            #expect(!fixture.failureIsPresented)
        }
        do { try await run() } catch { await fixture.teardown(); throw error }
        await fixture.teardown()
    }
}
