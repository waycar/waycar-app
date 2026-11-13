import Foundation
import Observation
import SwiftUI
import Testing
import UIKit

@testable import Waycar

@Suite("Zellij closed sessions", .serialized)
struct ZellijClosedSessionTests {
    @Test func exitedRowsAreHostKeptAndAgesOnlyRefreshWhenAsked() async throws {
        let listing = "work [Created 2h 5m ago] (EXITED - attach to resurrect)\nlive [Created 1m ago]\n"
        let rows = ZellijClosedSession.listing(listing)
        #expect(rows == [ZellijClosedSession(name: "work", age: "2h 5m ago")])
        let rig = try await ZellijTransportTests.open { _, _ in FakeHostSSHServices.result(stdout: listing) }
        rig.channel.feed("\u{1E}B\nwork [Created] (EXITED - attach to resurrect)\n\u{1E}P\n\u{1E}H\n\u{1E}E\n")
        try await waitUntil { try await rig.transport.closedZellijSessions(refreshAge: false).count == 1 }
        #expect(await rig.session.execs.isEmpty)
        #expect(try await rig.transport.closedZellijSessions(refreshAge: true) == rows)
        #expect(try await rig.transport.closedZellijSessions(refreshAge: false) == rows)
        try await rig.transport.deleteZellijSession("work")
        #expect(await rig.session.execs.last?.command == "/opt/zellij delete-session -- work")
        #expect(await rig.session.execs.allSatisfy { !$0.command.contains("attach ") })
        try await rig.transport.close()
    }

    @Test @MainActor func resumeTargetAndDeleteConfirmationAreDistinctFromAnAgent() throws {
        let session = ZellijClosedSession(name: "saved 'work'", age: "1h ago")
        let row = ClosedZellijSession(hostID: UUID(), hostName: "Host", session: session)
        #expect(row.terminalRow.isShell)
        #expect(row.terminalRow.backend == .zellij)
        #expect(ZellijClosedSession.name(for: row.terminalRow.attachTarget) == session.name)
        #expect(row.deleteTitle == "Delete Zellij session “saved 'work'”?")
        #expect(ClosedZellijSession.deleteMessage == "Its saved layout is removed from the Host.")
        let commands = try ZellijCommand(zellij: "/bin/zellij")
        let resume = commands.resumeSession(name: session.name)
        #expect(resume.contains("attach"))
        #expect(!resume.contains("--default-mode") && !resume.contains("-b"))
        #expect(ZellijClosedSession.name(for: .agentPane("zellij:saved/terminal_0")) == nil)
    }

    @Test @MainActor func wholeSessionUsesOnlyPTYInputAndNeverSendsToASyntheticPane() async throws {
        let transport = ScriptedTransport()
        let session = Self.terminal(transport: transport, isPresented: { true })
        session.attach.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(Data("saved layout".utf8)))
        try await waitUntil { session.attach.terminalStatus == .live }
        let input = Data("terminal keyboard\r".utf8)
        session.attach.send(input)
        try await waitUntil { await transport.attachInputs.contains(.keystrokes(input)) }
        // Even an accidental Send cannot address the reserved zellij-session: identity.
        #expect(await session.composer.send("not a pane") == .failed)
        #expect(await transport.paneInputParams.isEmpty)
        #expect(await transport.agentPromptParams.isEmpty)
        #expect(await transport.attachRequests.first?.target == .terminal("zellij-session:saved"))
        let availability = AgentToolbarAvailability(
            skillsAvailable: true, worktreeDetailsAvailable: true,
            snippetIDs: [], customKeyIDs: [], paneActionsAvailable: false)
        for action in AgentToolbarAction.allCases {
            #expect(availability.isVisible(.action(action)) == (action == .paste))
        }
        #expect(availability.isVisible(.key(.init(.enter))))
        #expect(availability.isVisible(.modifier(.control)))
        await session.attach.leave().value
    }

    @Test @MainActor func wholeSessionDetailKeepsComposerAndPaneControlsHidden() async throws {
        let transport = ScriptedTransport()
        let session = Self.terminal(transport: transport, isPresented: { true })
        let row = ClosedZellijSession(hostID: UUID(), hostName: "Host",
            session: ZellijClosedSession(name: "saved", age: nil))
        let suiteName = "zellij-session-detail-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let console = ConsoleStore { _, _, subscriptions in
            EventsSession(subscriptions: subscriptions,
                connect: { throw TransportError.cancelled }, reconnectPolicy: .default, keepalive: .default)
        }
        let terminal = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults), zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults), snippets: SnippetStore(defaults: defaults),
            toolbars: AgentToolbarLayoutStore(defaults: defaults, idiom: .phone))
        let probe = AgentTerminalInteractionProbe()
        let controller = UIHostingController(rootView: NavigationStack {
            AgentTerminalView(
                agent: row.terminalRow, console: console, terminal: terminal, hosts: [],
                activity: AppActivityCoordinator(), keyboardHandoff: TerminalKeyboardHandoff(),
                keyboardInset: TerminalKeyboardInset(), isOnStage: { true }, onSwitch: { _ in },
                onClosed: {}, composer: session.composer, attachStore: session.attach,
                interactionProbe: probe, paneActionsAvailable: false)
        })
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844), rootViewController: controller)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil { probe.isConnected && probe.toolbarLayout != nil }
        try await waitUntil { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(Data("saved layout".utf8)))
        try await waitUntil { session.attach.terminalStatus == .live }
        #expect(probe.tapMessageAgent())
        #expect(probe.isMessageAgentOpen == false)
        let layout = try #require(probe.toolbarLayout)
        #expect(layout.items.allSatisfy { $0.content.isTerminalOnlyControl })
        #expect(!layout.items.isEmpty)
        #expect(await transport.paneInputParams.isEmpty)
        await session.attach.leave().value
    }

    @Test @MainActor func dismissalDuringForegroundRecoveryDoesNotReattachOffscreen() async throws {
        var presented = true
        let transport = ScriptedTransport()
        let endGate = ScriptedTransportCallGate()
        await transport.gateNextAttachEnd(on: endGate)
        let session = Self.terminal(transport: transport, isPresented: { presented })
        let owner = session.attach
        owner.viewDidResize(cols: 80, rows: 24)
        try await waitUntil { await transport.hasLiveAttachSession }
        #expect(await transport.emitAttachOutput(Data("saved layout".utf8)))
        try await waitUntil { owner.terminalStatus == .live }
        owner.didBecomeActive(afterPossibleSuspension: true)
        try await waitUntil { await endGate.entryCount == 1 }
        #expect(owner.terminalStatus == .connecting)
        presented = false
        let teardown = owner.leave()
        await endGate.open()
        await teardown.value
        #expect(owner.terminalStatus == .stopped)
        #expect(await transport.hasLiveAttachSession == false)
        #expect(await transport.attachRequests.count == 1)
        owner.rejoin()
        owner.didBecomeActive(afterPossibleSuspension: true)
        #expect(owner.terminalStatus == .stopped)
        #expect(await transport.attachRequests.count == 1)
    }

    @MainActor private static func terminal(
        transport: ScriptedTransport, isPresented: @escaping () -> Bool
    ) -> ClosedZellijSessionTerminal {
        ClosedZellijSessionTerminal(
            row: ClosedZellijSession(hostID: UUID(), hostName: "Host",
                session: ZellijClosedSession(name: "saved", age: nil)),
            transportGeneration: 1, isPresented: isPresented,
            runTerminal: { request, handler in
                let session = try await transport.attachTerminal(request)
                try await handler.runEndingSession(session)
            })
    }

    @MainActor @Observable final class ConfirmationBox {
        var pending: ClosedZellijSession?
        var deleted: [String] = []
    }

    @Test @MainActor func deleteRequiresConfirmationAndCancelDoesNothing() async throws {
        let row = ClosedZellijSession(hostID: UUID(), hostName: "Host",
            session: ZellijClosedSession(name: "Saved workspace", age: "2h ago"))
        let box = ConfirmationBox()
        let confirmation = ZellijSessionDeleteConfirmation(pending: Binding(
            get: { box.pending }, set: { box.pending = $0 })) { box.deleted.append($0.id) }
        let controller = UIHostingController(rootView:
            ClosedZellijSessionCardView(row: row).padding().modifier(confirmation))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844), rootViewController: controller)
        defer { window.isHidden = true; window.rootViewController = nil }
        try await waitUntil { controller.view.window != nil }
        controller.view.layoutIfNeeded()
        let card = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(card, named: "zellij-closed-session-card", as: .png)
        box.pending = row
        try await waitUntil {
            guard let alert = controller.presentedViewController else { return false }
            return alert.view.window != nil && !alert.isBeingPresented
        }
        #expect(box.deleted.isEmpty)
        _ = try #require(controller.presentedViewController)
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        Attachment.record(image, named: "zellij-delete-confirmation", as: .png)
        // Drive the same callbacks the native alert's Buttons use. UIKit's alert action
        // representation does not implement accessibilityActivate in the unit-test host.
        confirmation.cancel()
        try await waitUntil { controller.presentedViewController == nil }
        #expect(box.pending == nil && box.deleted.isEmpty)
        box.pending = row
        try await waitUntil {
            guard let alert = controller.presentedViewController else { return false }
            return alert.view.window != nil && !alert.isBeingPresented
        }
        confirmation.confirm(row)
        try await waitUntil { box.deleted == [row.id] }
    }

    @Test func deletionRechecksThatTheSessionIsStillExited() async throws {
        let rig = try await ZellijTransportTests.open { _, _ in
            FakeHostSSHServices.result(stdout: "work [Created 1h ago]\n")
        }
        await #expect(throws: HerdrAPIError.self) { try await rig.transport.deleteZellijSession("work") }
        #expect(await rig.session.execs.allSatisfy { !$0.command.contains("delete-session") })
        try await rig.transport.close()
    }
}
