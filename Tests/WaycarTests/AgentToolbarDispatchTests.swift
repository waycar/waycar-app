import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Waycar

/// Toolbar items dispatched through Agent detail, as a tap on a bar would:
/// bytes reach Attach, text reaches the draft or Send's delivery owner. The
/// fixed 💬 ⌨ 🎤 controls keep Message Agent and the terminal keyboard
/// exclusive, and Dictate to Agent changes neither.
@MainActor
@Suite("Agent toolbar dispatch", .serialized)
struct AgentToolbarDispatchTests {
    // MARK: - Routing

    @Test(arguments: [false, true])
    func keysCombosAndKeyStepCustomKeysAlwaysReachAttach(isMessageAgentOpen: Bool) {
        let log = RouteLog()
        let steps = CustomKey(label: "end", steps: .keys([
            AgentToolbarKeyChord(.character("e"), modifiers: .control),
            AgentToolbarKeyChord(.escape),
        ]))
        let dispatcher = Self.dispatcher(
            isMessageAgentOpen: isMessageAgentOpen, log: log, customKeys: [steps])

        dispatcher.perform(.key(AgentToolbarKeyChord(.escape)))
        dispatcher.perform(.key(AgentToolbarKeyChord(.character("c"), modifiers: .control)))
        dispatcher.perform(.customKey(steps.id))

        // A plain Key honors armed modifiers; Combos and every key step send
        // their exact chord.
        #expect(log.calls == [
            .quickKey(.escape),
            .chord(.character("c"), .control),
            .chord(.character("e"), .control),
            .chord(.escape, []),
        ])
    }

    @Test(arguments: [false, true])
    func modifierChipsArmInBothStates(isMessageAgentOpen: Bool) {
        let log = RouteLog()
        let dispatcher = Self.dispatcher(isMessageAgentOpen: isMessageAgentOpen, log: log)

        dispatcher.perform(.modifier([.control, .shift]))

        #expect(log.calls == [.modifier([.control, .shift])])
    }

    @Test(arguments: [false, true])
    func authoredTextGoesToTheDraftOnlyWhileMessageAgentIsOpen(isMessageAgentOpen: Bool) throws {
        let log = RouteLog()
        log.pasteboard = "git status"
        let snippet = try Snippet.make(title: "deploy", body: "make deploy")
        let review = CustomKey(label: "review", steps: .text("/review", pressEnter: false))
        let dispatcher = Self.dispatcher(
            isMessageAgentOpen: isMessageAgentOpen, log: log,
            snippets: [snippet], customKeys: [review])

        dispatcher.perform(.action(.paste))
        dispatcher.perform(.snippet(snippet.id))
        dispatcher.perform(.customKey(review.id))

        if isMessageAgentOpen {
            #expect(log.calls == [
                .insertIntoDraft("git status"),
                .insertIntoDraft("make deploy"),
                .insertIntoDraft("/review"),
            ])
        } else {
            // Paste goes through Attach's paste review; the rest types
            // without Enter.
            #expect(log.calls == [
                .pasteIntoAttach("git status"),
                .insertIntoAttach("make deploy"),
                .insertIntoAttach("/review"),
            ])
        }
    }

    @Test(arguments: [false, true])
    func anEmptyClipboardPastesNothing(isMessageAgentOpen: Bool) {
        let log = RouteLog()
        let dispatcher = Self.dispatcher(isMessageAgentOpen: isMessageAgentOpen, log: log)

        dispatcher.perform(.action(.paste))
        log.pasteboard = ""
        dispatcher.perform(.action(.paste))

        #expect(log.calls.isEmpty)
    }

    @Test(arguments: [false, true])
    func textCustomKeyWithEnterIsSubmittedInBothStates(isMessageAgentOpen: Bool) {
        let log = RouteLog()
        let compact = CustomKey(label: "compact", steps: .text("/compact", pressEnter: true))
        let dispatcher = Self.dispatcher(
            isMessageAgentOpen: isMessageAgentOpen, log: log, customKeys: [compact])

        dispatcher.perform(.customKey(compact.id))

        #expect(log.calls == [.submitText("/compact")])
    }

    @Test(arguments: [false, true])
    func toolsKeyboardTogglesTheToolsKeyboard(isMessageAgentOpen: Bool) {
        let log = RouteLog()
        let dispatcher = Self.dispatcher(isMessageAgentOpen: isMessageAgentOpen, log: log)

        dispatcher.perform(.action(.toolsKeyboard))

        #expect(log.calls == [.toggleToolsKeyboard])
    }

    @Test(arguments: [false, true])
    func draftOwnedActionsOpenMessageAgentFirstOnlyWhileItIsClosed(isMessageAgentOpen: Bool) {
        let log = RouteLog()
        let dispatcher = Self.dispatcher(isMessageAgentOpen: isMessageAgentOpen, log: log)

        dispatcher.perform(.action(.skills))
        dispatcher.perform(.action(.snippets))
        // Not draft-owned: runs where it is, never opening Message Agent.
        dispatcher.perform(.action(.renameAgent))

        if isMessageAgentOpen {
            #expect(log.calls == [.menu(.skills), .menu(.snippets), .menu(.renameAgent)])
        } else {
            #expect(log.calls == [
                .openMessageAgent, .menu(.skills),
                .openMessageAgent, .menu(.snippets),
                .menu(.renameAgent),
            ])
        }
    }

    @Test(arguments: [false, true])
    func unavailableMenuActionsDoNothing(isMessageAgentOpen: Bool) {
        let log = RouteLog()
        let dispatcher = Self.dispatcher(
            isMessageAgentOpen: isMessageAgentOpen, log: log,
            canAdd: false, skillsAvailable: false)

        // Add Image waits for `canAdd`; Open Terminal has no opener; Skills
        // is hidden for this kind.
        dispatcher.perform(.action(.addImage))
        dispatcher.perform(.action(.openTerminal))
        dispatcher.perform(.action(.skills))

        #expect(log.calls.isEmpty)
    }

    @Test(arguments: [false, true])
    func itemsWhoseSnippetOrCustomKeyIsGoneDoNothing(isMessageAgentOpen: Bool) {
        let log = RouteLog()
        log.pasteboard = "unused"
        let dispatcher = Self.dispatcher(isMessageAgentOpen: isMessageAgentOpen, log: log)

        dispatcher.perform(.snippet(UUID()))
        dispatcher.perform(.customKey(UUID()))

        #expect(log.calls.isEmpty)
    }

    // MARK: - Through Agent detail

    @Test func comboSendsItsExactChordWhileAModifierIsArmed() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }

        // ⌥ armed, then ⌃C: the Combo sends 03, not ⌃⌥C, and disarms ⌥.
        #expect(fixture.probe.performToolbarItem(.modifier(.option)))
        fixture.probe.performToolbarItem(.key(AgentToolbarKeyChord(.character("c"), modifiers: .control)))
        // Ghostty delivers encoded keys on a later main-actor turn while Esc's
        // fast path writes at once: let ⌃C land before tapping Esc.
        try #require(await Self.eventually { await fixture.keystrokes() == Data([0x03]) })
        // Nothing armed any more: Esc keeps its single byte.
        fixture.probe.performToolbarItem(.key(AgentToolbarKeyChord(.escape)))
        // The chip arms the next plain Key.
        fixture.probe.performToolbarItem(.modifier(.option))
        fixture.probe.performToolbarItem(.key(AgentToolbarKeyChord(.function(.f12))))

        let expected = Data([0x03, 0x1B]) + Data("\u{1B}[24;3~".utf8)
        try #require(await Self.eventually { await fixture.keystrokes() == expected })
        #expect(await fixture.transport.agentPromptParams.isEmpty)
        await fixture.leave()
    }

    @Test func keyStepCustomKeySendsEachChordInOrderAndDropsArmedModifiers() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        let key = try fixture.addCustomKey(steps: .keys([
            AgentToolbarKeyChord(.character("e"), modifiers: .control),
            AgentToolbarKeyChord(.character("u"), modifiers: .control),
        ]))

        #expect(fixture.probe.performToolbarItem(.modifier(.option)))
        fixture.probe.performToolbarItem(.customKey(key.id))

        // Exactly ⌃E then ⌃U: armed ⌥ is dropped, not merged into either step.
        try #require(await Self.eventually { await fixture.keystrokes() == Data([0x05, 0x15]) })
        #expect(await fixture.transport.agentPromptParams.isEmpty)
        await fixture.leave()
    }

    @Test func customKeyTextAndEnterSendsOnePromptAndKeepsTheDraft() async throws {
        let fixture = try await Fixture(messageAgentOpen: true)
        defer { fixture.close() }
        let key = try fixture.addCustomKey(text: "/compact", pressEnter: true)

        fixture.probe.performToolbarItem(.customKey(key.id))

        try #require(await Self.eventually {
            await fixture.transport.agentPromptParams.count == 1
        })
        #expect(await fixture.transport.agentPromptParams.map(\.text) == ["/compact"])
        #expect(fixture.composer.draft == Fixture.draft)
        #expect(await fixture.keystrokes().isEmpty)
        await fixture.leave()
    }

    @Test func blockedCustomKeyTextInsertsWithoutEnter() async throws {
        let fixture = try await Fixture(status: .blocked, messageAgentOpen: true)
        defer { fixture.close() }
        let key = try fixture.addCustomKey(text: "/compact", pressEnter: true)

        fixture.probe.performToolbarItem(.customKey(key.id))

        try #require(await Self.eventually {
            await fixture.keystrokes() == Data("/compact".utf8)
        })
        #expect(await fixture.transport.agentPromptParams.isEmpty)
        #expect(fixture.composer.draft == Fixture.draft)
        await fixture.leave()
    }

    @Test func pendingLaunchCustomKeyTextSendsOnePromptOnceTheLaunchClears() async throws {
        // The prompt is refused twice and must go out on the third try, so the
        // retry budget has to outlast two slow retries: 40 ms ran out when the
        // 5 ms retries ran late, and the key text was typed instead (WAY-505).
        let fixture = try await Fixture(messageAgentOpen: true, retryBudget: .seconds(2))
        defer { fixture.close() }
        await fixture.transport.setAgentPromptFailures([Fixture.notReady, Fixture.notReady])
        let key = try fixture.addCustomKey(text: "/compact", pressEnter: true)

        fixture.probe.performToolbarItem(.customKey(key.id))

        try #require(await Self.eventually {
            await fixture.transport.agentPromptParams.count == 3
        })
        #expect(await fixture.transport.agentPromptParams.last?.text == "/compact")
        let typed = await fixture.keystrokes()
        #expect(typed.range(of: Data("/compact".utf8)) == nil)
        #expect(!typed.contains(0x0D))
        #expect(fixture.composer.draft == Fixture.draft)
        await fixture.leave()
    }

    @Test func exhaustedLaunchWaitTypesCustomKeyTextWithoutEnter() async throws {
        let fixture = try await Fixture(messageAgentOpen: true)
        defer { fixture.close() }
        await fixture.transport.setAgentPromptFailure(Fixture.notReady)
        let key = try fixture.addCustomKey(text: "/compact", pressEnter: true)

        fixture.probe.performToolbarItem(.customKey(key.id))

        let text = Data("/compact".utf8)
        try #require(await Self.eventually {
            await fixture.keystrokes().suffix(text.count) == text
        })
        #expect(!(await fixture.keystrokes()).contains(0x0D))
        #expect(fixture.composer.draft == Fixture.draft)
        await fixture.leave()
    }

    @Test(arguments: [false, true])
    func customKeyTextOnlyGoesToTheActiveInput(messageAgentOpen: Bool) async throws {
        let fixture = try await Fixture(messageAgentOpen: messageAgentOpen)
        defer { fixture.close() }
        let key = try fixture.addCustomKey(text: "/review", pressEnter: false)

        fixture.probe.performToolbarItem(.customKey(key.id))

        if messageAgentOpen {
            try #require(await Self.eventually { fixture.composer.draft == Fixture.draft + "/review" })
            #expect(await fixture.keystrokes().isEmpty)
        } else {
            try #require(await Self.eventually {
                await fixture.keystrokes() == Data("/review".utf8)
            })
            #expect(fixture.composer.draft == Fixture.draft)
        }
        #expect(await fixture.transport.agentPromptParams.isEmpty)
        await fixture.leave()
    }

    @Test(arguments: [false, true])
    func pasteReachesTheActiveInputsOwner(messageAgentOpen: Bool) async throws {
        let text = "git status\ngit diff"
        let fixture = try await Fixture(clipboard: text, messageAgentOpen: messageAgentOpen)
        defer { fixture.close() }

        fixture.probe.performToolbarItem(.action(.paste))

        if messageAgentOpen {
            #expect(fixture.composer.draft == Fixture.draft + text)
            #expect(fixture.owner.pendingPaste == nil)
        } else {
            // With Message Agent closed it goes through Attach's paste review.
            #expect(fixture.owner.pendingPaste?.preview == text)
            #expect(fixture.composer.draft == Fixture.draft)
        }
        #expect(await fixture.keystrokes().isEmpty)
        await fixture.leave()
    }

    // MARK: - Message Agent and the terminal keyboard

    @Test func anAgentViewOpensIdle() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }

        #expect(fixture.probe.isMessageAgentOpen == false)
        #expect(fixture.probe.isTerminalKeyboardUp == false)
        #expect(fixture.terminal()?.isFirstResponder == false)
        await fixture.leave()
    }

    @Test func messageAgentOpensFocusedAndClosesWithTheKeyboardDown() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }

        #expect(fixture.probe.tapMessageAgent())
        try #require(
            await Self.eventually {
                fixture.probe.isMessageAgentOpen == true && fixture.draftInput() != nil
            }, Comment(rawValue: fixture.messageAgentOpenFailure()))
        // Opens ready to type: the draft takes focus, the terminal does not.
        try #require(await Self.eventually { fixture.draftInput()?.isFirstResponder == true })
        #expect(fixture.terminal()?.isFirstResponder == false)

        #expect(fixture.probe.tapMessageAgent())
        try #require(await Self.eventually { fixture.probe.isMessageAgentOpen == false })
        // Closing with 💬 does not raise the terminal keyboard, not even on a
        // later turn.
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.probe.isTerminalKeyboardUp == false)
        #expect(fixture.terminal()?.isFirstResponder == false)
        await fixture.leave()
    }

    @Test func openingMessageAgentHandsTheKeyboardToTheDraft() async throws {
        let fixture = try await Fixture()
        defer { fixture.close() }
        #expect(fixture.probe.tapTerminalKeyboard())
        try #require(await Self.eventually {
            fixture.probe.isTerminalKeyboardUp == true
                && fixture.terminal()?.isFirstResponder == true
        })

        #expect(fixture.probe.tapMessageAgent())

        try #require(
            await Self.eventually {
                fixture.probe.isMessageAgentOpen == true
                    && fixture.terminal()?.isFirstResponder == false
                    && fixture.draftInput()?.isFirstResponder == true
            }, Comment(rawValue: fixture.messageAgentOpenFailure()))
        await fixture.leave()
    }

    @Test func terminalKeyboardFromAKeyboardDownMessageAgentFocusesTheTerminal() async throws {
        let fixture = try await Fixture(messageAgentOpen: true)
        defer { fixture.close() }
        let draft = try #require(fixture.draftInput())
        draft.resignFirstResponder()
        try #require(await Self.eventually { draft.isFirstResponder == false })

        #expect(fixture.probe.tapTerminalKeyboard())

        try #require(await Self.eventually {
            fixture.probe.isMessageAgentOpen == false
                && fixture.terminal()?.isFirstResponder == true
        })
        await fixture.leave()
    }

    @Test func terminalKeyboardClosesMessageAgentAndRaisesTheTerminalKeyboard() async throws {
        let fixture = try await Fixture(messageAgentOpen: true)
        defer { fixture.close() }
        #expect(fixture.probe.isTerminalKeyboardUp == false)

        #expect(fixture.probe.tapTerminalKeyboard())

        try #require(await Self.eventually {
            fixture.probe.isMessageAgentOpen == false
                && fixture.probe.isTerminalKeyboardUp == true
                && fixture.terminal()?.isFirstResponder == true
        })
        #expect(fixture.composer.draft == Fixture.draft)
        await fixture.leave()
    }

    // MARK: - Dictate to Agent

    enum DictationSurface: Sendable, CaseIterable {
        case messageAgent
        case terminalKeyboard
    }

    @Test(arguments: DictationSurface.allCases)
    func dictationSendsWithoutChangingMessageAgentOrTheKeyboard(surface: DictationSurface) async throws {
        let engine = ScriptedDictationEngine()
        let sender = DictationSender(
            dictation: DictationStore(engine: engine, locale: { Locale(identifier: "en_US") }))
        let fixture = try await Fixture(messageAgentOpen: surface == .messageAgent, dictation: sender)
        defer { fixture.close() }
        if surface == .terminalKeyboard {
            #expect(fixture.probe.tapTerminalKeyboard())
            try #require(await Self.eventually {
                fixture.probe.isTerminalKeyboardUp == true
                    && fixture.terminal()?.isFirstResponder == true
            })
        } else {
            try #require(await Self.eventually { fixture.draftInput() != nil })
            let draft = try #require(fixture.draftInput())
            #expect(draft.becomeFirstResponder())
            try #require(await Self.eventually { draft.isFirstResponder })
        }
        let unchanged: () -> Bool = {
            switch surface {
            case .messageAgent:
                fixture.probe.isMessageAgentOpen == true
                    && fixture.draftInput()?.isFirstResponder == true
            case .terminalKeyboard:
                fixture.probe.isMessageAgentOpen == false
                    && fixture.probe.isTerminalKeyboardUp == true
                    && fixture.terminal()?.isFirstResponder == true
            }
        }

        #expect(fixture.probe.tapDictateToAgent())
        #expect(sender.dictation.phase != .idle)
        engine.emit(.listening)
        engine.emit(.transcript("Fix the bug", isFinal: true))
        // A trailing level proves every earlier event was applied.
        engine.emit(.level(0.5))
        try #require(await Self.eventually {
            sender.dictation.phase == .listening && sender.dictation.level == 0.5
        })
        #expect(unchanged())

        #expect(fixture.probe.tapDictateToAgent())

        try #require(await Self.eventually {
            await fixture.transport.agentPromptParams.map(\.text) == ["Fix the bug"]
                && sender.dictation.phase == .idle
        })
        // Let any follow-up of the send land before looking again.
        try await Task.sleep(for: .milliseconds(100))
        #expect(unchanged())
        #expect(fixture.composer.draft == Fixture.draft)
        #expect(await fixture.keystrokes().isEmpty)
        await fixture.leave()
    }

    @Test func wholeSessionHidesPaneMenusAndDispatchesOnlyTerminalControls() {
        let log = RouteLog()
        log.pasteboard = "direct terminal paste"
        let dispatcher = Self.dispatcher(
            isMessageAgentOpen: false, log: log, paneActionsAvailable: false)
        for item in AgentActionMenuItem.allCases {
            #expect(!AgentActionMenuPolicy.isVisible(item, actions: dispatcher.actions))
        }
        for action in AgentToolbarAction.allCases { dispatcher.perform(.action(action)) }
        dispatcher.perform(.key(.init(.enter)))
        #expect(log.calls == [.pasteIntoAttach("direct terminal paste"), .quickKey(.enter)])
    }

    // MARK: - Dispatcher fixture

    /// Every route the dispatcher took, in order.
    @MainActor
    private final class RouteLog {
        enum Call: Equatable {
            case quickKey(AgentQuickKey)
            case chord(AgentQuickKey, TerminalKeyModifiers)
            case modifier(TerminalKeyModifiers)
            case pasteIntoAttach(String)
            case insertIntoAttach(String)
            case insertIntoDraft(String)
            case submitText(String)
            case openMessageAgent
            case toggleToolsKeyboard
            case menu(AgentActionMenuItem)
        }

        var calls: [Call] = []
        var pasteboard: String?
    }

    private static func dispatcher(
        isMessageAgentOpen: Bool,
        log: RouteLog,
        canAdd: Bool = true,
        skillsAvailable: Bool = true,
        snippets: [Snippet] = [],
        customKeys: [CustomKey] = [],
        paneActionsAvailable: Bool = true
    ) -> AgentToolbarItemDispatcher {
        AgentToolbarItemDispatcher(
            isMessageAgentOpen: isMessageAgentOpen,
            actions: AgentComposerActions(
                canAdd: canAdd,
                addImage: { log.calls.append(.menu(.addImage)) },
                addFile: { log.calls.append(.menu(.addFile)) },
                openTerminal: nil,
                isOpeningTerminal: false,
                startAgent: { log.calls.append(.menu(.newAgent)) },
                manageSnippets: { log.calls.append(.menu(.snippets)) },
                showSkills: skillsAvailable ? { log.calls.append(.menu(.skills)) } : nil,
                showWorktreeDetails: nil,
                renameAgent: { log.calls.append(.menu(.renameAgent)) },
                renameWorkspace: { log.calls.append(.menu(.renameWorkspace)) },
                markUnread: { log.calls.append(.menu(.markUnread)) },
                closeAgent: { log.calls.append(.menu(.closeAgent)) },
                paneActionsAvailable: paneActionsAvailable),
            snippets: snippets,
            customKeys: customKeys,
            routes: .init(
                sendQuickKey: { log.calls.append(.quickKey($0)) },
                sendChord: { log.calls.append(.chord($0, $1)) },
                toggleModifier: { log.calls.append(.modifier($0)) },
                pasteIntoAttach: { log.calls.append(.pasteIntoAttach($0)) },
                insertIntoAttach: { log.calls.append(.insertIntoAttach($0)) },
                insertIntoDraft: { log.calls.append(.insertIntoDraft($0)) },
                submitText: { log.calls.append(.submitText($0)) },
                openMessageAgentThen: { action in
                    log.calls.append(.openMessageAgent)
                    action()
                },
                toggleToolsKeyboard: { log.calls.append(.toggleToolsKeyboard) },
                readPasteboard: { log.pasteboard }))
    }

    // MARK: - Agent detail fixture

    /// A hosted Agent detail on a live Attach, with its own toolbar catalog.
    @MainActor
    private final class Fixture {
        static let draft = "keep this local: "
        static let notReady = HerdrAPIError(
            code: "agent_not_ready",
            message: "agent w1:p1 is not an active named agent")

        let transport: ScriptedTransport
        let composer: AgentComposerStore
        let owner: AgentAttachStore
        let toolbars: AgentToolbarLayoutStore
        let probe: AgentTerminalInteractionProbe
        private let controller: UIViewController
        private let window: UIWindow
        private let suiteName: String

        /// Mounts idle, as every Agent view opens; `messageAgentOpen` then
        /// taps 💬.
        init(
            status: AgentStatus = .idle,
            clipboard: String? = nil,
            messageAgentOpen: Bool = false,
            dictation: DictationSender? = nil,
            retryBudget: Duration = .milliseconds(40)
        ) async throws {
            let suiteName = "toolbar-dispatch-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suiteName))
            let transport = ScriptedTransport()
            let toolbars = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
            let probe = AgentTerminalInteractionProbe()
            let composer = AgentComposerStore(
                target: "w1:p1",
                initialStatus: status,
                agentNotReadyRetryDelay: .milliseconds(5),
                agentNotReadyRetryBudget: retryBudget
            ) { params in
                try await transport.promptAgent(params)
            }
            composer.replaceDraft(with: Self.draft)
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
            // The first positive size report opens the channel, as in production.
            owner.viewDidResize(cols: 80, rows: 24)
            try #require(await AgentToolbarDispatchTests.eventually {
                await transport.attachRequests.count == 1
            })
            #expect(await transport.emitAttachOutput(Data("live".utf8)))

            let settings = TerminalSettings(
                themes: TerminalThemeSettings(defaults: defaults),
                zoom: TerminalZoomSettings(defaults: defaults),
                fonts: TerminalFontSettings(defaults: defaults),
                snippets: SnippetStore(defaults: defaults),
                toolbars: toolbars)
            let console = ConsoleStore(snapshotRetryDelay: .seconds(30)) { _, _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "fixture") },
                    reconnectPolicy: .default,
                    keepalive: .default)
            }
            let agent = ConsoleAgent(
                hostID: UUID(),
                hostName: "devbox",
                agent: Agent(
                    terminalID: "term_w1:p1", kind: "claude", title: "",
                    status: status, workspaceID: "w", tabID: "w:t", paneID: "w1:p1",
                    cwd: "/work", revision: 1, name: nil),
                workspaceLabel: nil,
                repositoryCheckout: nil)
            let controller = UIHostingController(
                rootView: AgentTerminalView(
                    agent: agent,
                    console: console,
                    terminal: settings,
                    hosts: [],
                    activity: AppActivityCoordinator(),
                    keyboardHandoff: TerminalKeyboardHandoff(),
                    keyboardInset: TerminalKeyboardInset(),
                    isOnStage: { true },
                    onSwitch: { _ in },
                    onClosed: {},
                    composer: composer,
                    attachStore: owner,
                    interactionProbe: probe,
                    clipboard: TerminalClipboard(
                        string: { clipboard },
                        hasStrings: { clipboard != nil }),
                    dictationSender: dictation))
            let window = try await makeTestWindow(
                frame: CGRect(x: 0, y: 0, width: 402, height: 874),
                rootViewController: controller)
            self.suiteName = suiteName
            self.transport = transport
            self.toolbars = toolbars
            self.probe = probe
            self.composer = composer
            self.owner = owner
            self.controller = controller
            self.window = window

            controller.view.layoutIfNeeded()
            try #require(await AgentToolbarDispatchTests.eventually {
                owner.terminalStatus == AttachTerminalStore.Status.live && probe.isConnected
            })
            // Plain text, not a bracketed paste: the expected bytes are the text.
            let terminal = try #require(self.terminal())
            terminal.receive(Data("\u{1B}[?2004l".utf8))
            try #require(await AgentToolbarDispatchTests.eventually { !terminal.usesBracketedPaste })

            // A tap that lands while SwiftUI is still working through the
            // window's first updates can lose its redraw: the mode reads as
            // open, the view tree never gains the draft, and the wait times
            // out (WAY-505: 13 CI failures at this site, then
            // `messageAgentOpensFocusedAndClosesWithTheKeyboardDown` on main
            // after it was fixed here alone). Every test taps a fresh window,
            // so every Fixture lets those updates run first.
            try await DisplayTickMonitor.shared.waitForTicks(20)

            if messageAgentOpen {
                #expect(probe.tapMessageAgent())
                try #require(
                    await AgentToolbarDispatchTests.eventually {
                        probe.isMessageAgentOpen == true
                            && self.draftInput()?.isFirstResponder == true
                    }, Comment(rawValue: messageAgentOpenFailure()))
            }
        }

        /// What a Message Agent open wait that ran out of time can say: the
        /// mode, the draft's focus, and the window and machine state.
        func messageAgentOpenFailure() -> String {
            """
            Message Agent should open with its draft focused: \
            open \(String(describing: probe.isMessageAgentOpen)), \
            draft \(UIWaitDiagnostics.focus(of: draftInput())), \
            chrome mounts \(probe.inputChromeMountCount), \
            \(UIWaitDiagnostics.hierarchy(of: controller.view)), \
            \(UIWaitDiagnostics.window(window)); \(UIWaitDiagnostics.machine())
            """
        }

        func addCustomKey(text: String, pressEnter: Bool) throws -> CustomKey {
            try addCustomKey(steps: .text(text, pressEnter: pressEnter))
        }

        func addCustomKey(steps: CustomKey.Steps) throws -> CustomKey {
            let key = CustomKey(label: "key", steps: steps)
            try toolbars.upsertCustomKey(key, addToBar: true)
            return key
        }

        /// The mounted terminal, looked up fresh.
        func terminal() -> WaycarTerminalView? {
            Self.firstView(in: controller.view) { $0 is WaycarTerminalView } as? WaycarTerminalView
        }

        /// Message Agent's draft editor, while it is open.
        func draftInput() -> UITextView? {
            Self.firstView(in: controller.view) {
                $0 is UITextView && $0.accessibilityLabel == "Message the Agent"
            } as? UITextView
        }

        /// Every byte typed into Attach, in order.
        func keystrokes() async -> Data {
            await transport.attachInputs.reduce(into: Data()) { output, input in
                if case .keystrokes(let data) = input { output.append(data) }
            }
        }

        func leave() async {
            await owner.leave().value
        }

        func close() {
            window.isHidden = true
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }

        private static func firstView(in root: UIView, where matches: (UIView) -> Bool) -> UIView? {
            if matches(root) { return root }
            for subview in root.subviews {
                if let match = firstView(in: subview, where: matches) { return match }
            }
            return nil
        }
    }

    fileprivate static func eventually(
        timeout: Duration = .waitCeiling,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws -> Bool {
        let start = ContinuousClock.now
        let deadline = start + timeout
        while ContinuousClock.now < deadline {
            if await condition() {
                UIWaitDiagnostics.noteSlowWait(
                    "AgentToolbarDispatchTests.swift:\(line)", took: ContinuousClock.now - start,
                    budget: timeout)
                return true
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}
