import Foundation
import GameController
import SwiftUI
import Testing
import UIKit

@testable import Waycar

@MainActor
@Suite("Agent Direct Input", .serialized)
struct AgentDirectInputTests {
    @Test func productionLayoutSeamTracksSoftwareKeyboardOnly() {
        let hardwareOnly = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: false,
            expectsSystemKeyboard: false,
            currentHeight: 0,
            lastPresentedHeight: 336)
        #expect(hardwareOnly.keyboardPresentation == .hidden)
        #expect(hardwareOnly.layout.contentInset == 0)

        let softwareUp = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: false,
            expectsSystemKeyboard: false,
            currentHeight: 336,
            lastPresentedHeight: 336)
        #expect(softwareUp.keyboardPresentation == .system)
        #expect(softwareUp.layout.contentInset == 336)

        let tools = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: true,
            expectsSystemKeyboard: false,
            currentHeight: 0,
            lastPresentedHeight: 336)
        #expect(tools.keyboardPresentation == .tools)
        #expect(tools.layout.contentInset == 336)
    }

    @Test func toolsToSystemPreShowKeepsStableInset() {
        // Shared TerminalAttachTests contract: `.system` with currentHeight 0
        // still reserves lastPresentedHeight during the Tools→iOS swap.
        let midSwap = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: false,
            expectsSystemKeyboard: true,
            currentHeight: 0,
            lastPresentedHeight: 336)
        #expect(midSwap.keyboardPresentation == .system)
        #expect(midSwap.layout.contentInset == 336)
        #expect(midSwap.layout.availableToolsHeight == 336)

        let withoutHold = AgentDirectInputPresentation.resolve(
            usesToolsKeyboard: false,
            expectsSystemKeyboard: false,
            currentHeight: 0,
            lastPresentedHeight: 336)
        #expect(withoutHold.keyboardPresentation == .hidden)
        #expect(withoutHold.layout.contentInset == 0)
    }

    @Test func accessibilityTraversalFallsBackToIndexedContainerWhenElementsAreEmpty() {
        let root = IndexedAccessibilityContainerView(indexedLabel: "Indexed control")

        #expect(Self.firstAccessible(labeled: "Indexed control", in: root) != nil)
    }

    @Test func accessibilityTraversalIncludesIndexedElementsWhenArrayIsIncomplete() {
        let root = IndexedAccessibilityContainerView(
            indexedLabel: "Indexed control",
            arrayLabel: "Array control")

        #expect(Self.firstAccessible(labeled: "Indexed control", in: root) != nil)
        #expect(Self.firstAccessible(labeled: "Array control", in: root) != nil)
    }

    @Test func accessibilityTraversalDeduplicatesElementsAcrossContainerSources() {
        let root = IndexedAccessibilityContainerView(
            indexedLabel: "Shared control",
            includesIndexedElementInArray: true)

        #expect(Self.accessibleCount(labeled: "Shared control", in: root) == 1)
    }

    @Test func sharedActionMenuContractIsExhaustive() {
        #expect(
            AgentActionMenuPolicy.composerAddSections == [.addAttachments])
        #expect(
            AgentActionMenuPolicy.composerMoreSections
                == [.sessionTools, .agentLifecycle])
        #expect(
            AgentActionMenuPolicy.toolbarMoreSections
                == [.addAttachments, .sessionTools, .agentLifecycle])
        #expect(
            AgentActionMenuSection.addAttachments.items
                == [.addImage, .addFile])
        #expect(
            AgentActionMenuSection.sessionTools.items
                == [.openTerminal, .newAgent, .skills, .snippets])
        #expect(
            AgentActionMenuSection.agentLifecycle.items
                == [
                    .worktreeDetails, .renameAgent, .renameWorkspace, .markUnread,
                    .closeAgent,
                ])
        #expect(
            AgentActionMenuItem.allCases
                == AgentActionMenuSection.allCases.flatMap(\.items))

        let metadata: [(AgentActionMenuItem, String, String, Bool, Bool)] = [
            (.addImage, "Add Image", "photo", false, true),
            (.addFile, "Add File", "doc", false, true),
            (.openTerminal, "Open Terminal", "apple.terminal", false, false),
            (.newAgent, "New Agent", "plus", false, false),
            (.skills, "Skills", "sparkles", false, true),
            (.snippets, "Snippets", "quote.bubble", false, true),
            (.worktreeDetails, "Worktree Details", "arrow.triangle.branch", false, false),
            (.renameAgent, "Rename Agent", "pencil", false, false),
            (.renameWorkspace, "Rename Workspace", "pencil.line", false, false),
            (.markUnread, "Mark as Unread", "envelope.badge", false, false),
            (.closeAgent, "Close Agent", "trash", true, false),
        ]
        for (item, title, systemImage, isDestructive, isDraftOwned) in metadata {
            #expect(item.title == title)
            #expect(item.systemImage == systemImage)
            #expect((item.role == .destructive) == isDestructive)
            #expect(item.isDraftOwned == isDraftOwned)
        }
    }

    @Test func sharedActionMenuAvailabilityAndDispatchCoverAllGates() {
        enum Event: Equatable {
            case addImage, addFile, openTerminal, startAgent, skills, snippets
            case worktree, renameAgent, renameWorkspace, markUnread, closeAgent
        }
        var events: [Event] = []
        let gated = AgentComposerActions(
            canAdd: false,
            addImage: { events.append(.addImage) },
            addFile: { events.append(.addFile) },
            openTerminal: nil,
            isOpeningTerminal: false,
            startAgent: { events.append(.startAgent) },
            manageSnippets: { events.append(.snippets) },
            showSkills: nil,
            showWorktreeDetails: nil,
            renameAgent: { events.append(.renameAgent) },
            renameWorkspace: { events.append(.renameWorkspace) },
            markUnread: nil,
            closeAgent: { events.append(.closeAgent) })
        let busy = AgentComposerActions(
            canAdd: true,
            addImage: { events.append(.addImage) },
            addFile: { events.append(.addFile) },
            openTerminal: { events.append(.openTerminal) },
            isOpeningTerminal: true,
            startAgent: { events.append(.startAgent) },
            manageSnippets: { events.append(.snippets) },
            showSkills: { events.append(.skills) },
            showWorktreeDetails: { events.append(.worktree) },
            renameAgent: { events.append(.renameAgent) },
            renameWorkspace: { events.append(.renameWorkspace) },
            markUnread: { events.append(.markUnread) },
            closeAgent: { events.append(.closeAgent) })
        let ready = AgentComposerActions(
            canAdd: true,
            addImage: { events.append(.addImage) },
            addFile: { events.append(.addFile) },
            openTerminal: { events.append(.openTerminal) },
            isOpeningTerminal: false,
            startAgent: { events.append(.startAgent) },
            manageSnippets: { events.append(.snippets) },
            showSkills: { events.append(.skills) },
            showWorktreeDetails: { events.append(.worktree) },
            renameAgent: { events.append(.renameAgent) },
            renameWorkspace: { events.append(.renameWorkspace) },
            markUnread: { events.append(.markUnread) },
            closeAgent: { events.append(.closeAgent) })

        let availability: [(AgentActionMenuItem, AgentComposerActions, Bool, Bool)] = [
            (.addImage, gated, true, false),
            (.addFile, gated, true, false),
            (.openTerminal, gated, true, false),
            (.openTerminal, busy, true, false),
            (.openTerminal, ready, true, true),
            (.newAgent, ready, true, true),
            (.skills, gated, false, true),
            (.skills, ready, true, true),
            (.snippets, ready, true, true),
            (.worktreeDetails, gated, false, true),
            (.worktreeDetails, ready, true, true),
            (.renameAgent, ready, true, true),
            (.renameWorkspace, ready, true, true),
            (.markUnread, gated, false, true),
            (.markUnread, ready, true, true),
            (.closeAgent, ready, true, true),
        ]
        for (item, actions, visible, enabled) in availability {
            #expect(AgentActionMenuPolicy.isVisible(item, actions: actions) == visible)
            #expect(AgentActionMenuPolicy.isEnabled(item, actions: actions) == enabled)
        }

        for item in AgentActionMenuItem.allCases {
            AgentActionMenuPolicy.perform(item, actions: ready)
        }
        #expect(
            events == [
                .addImage, .addFile, .openTerminal, .startAgent, .skills, .snippets,
                .worktree, .renameAgent, .renameWorkspace, .markUnread, .closeAgent,
            ])
    }

    @Test func directInputRestoreComposerThenRunsBeforeDraftOwnedActions() {
        enum Step: Equatable {
            case restore
            case action(AgentActionMenuItem)
        }
        var steps: [Step] = []
        let actions = AgentComposerActions(
            canAdd: true,
            addImage: { steps.append(.action(.addImage)) },
            addFile: { steps.append(.action(.addFile)) },
            openTerminal: { steps.append(.action(.openTerminal)) },
            isOpeningTerminal: false,
            startAgent: { steps.append(.action(.newAgent)) },
            manageSnippets: { steps.append(.action(.snippets)) },
            showSkills: { steps.append(.action(.skills)) },
            showWorktreeDetails: { steps.append(.action(.worktreeDetails)) },
            renameAgent: { steps.append(.action(.renameAgent)) },
            renameWorkspace: { steps.append(.action(.renameWorkspace)) },
            markUnread: { steps.append(.action(.markUnread)) },
            closeAgent: { steps.append(.action(.closeAgent)) })
        let restoreComposerThen: (@escaping () -> Void) -> Void = { action in
            steps.append(.restore)
            action()
        }

        for item in AgentActionMenuItem.allCases {
            AgentActionMenuPolicy.dispatch(
                item,
                actions: actions,
                restoreComposerThen: restoreComposerThen)
        }

        #expect(
            steps == [
                .restore, .action(.addImage),
                .restore, .action(.addFile),
                .action(.openTerminal),
                .action(.newAgent),
                .restore, .action(.skills),
                .restore, .action(.snippets),
                .action(.worktreeDetails),
                .action(.renameAgent),
                .action(.renameWorkspace),
                .action(.markUnread),
                .action(.closeAgent),
            ])

        steps.removeAll()
        for item in AgentActionMenuItem.allCases where item.isDraftOwned {
            AgentActionMenuPolicy.dispatch(item, actions: actions)
        }
        #expect(
            steps == [
                .action(.addImage), .action(.addFile),
                .action(.skills), .action(.snippets),
            ])
    }

    @Test func keyboardClaimPolicyUnifiesReplacementAndAgentSwitchGates() {
        #expect(
            !AgentDirectInputPresentation.shouldClaimKeyboard(
                wantsKeyboard: false,
                isKeyboardUp: false,
                usesToolsKeyboard: false,
                softwareKeyboardHeight: 0))
        #expect(
            AgentDirectInputPresentation.shouldClaimKeyboard(
                wantsKeyboard: true,
                isKeyboardUp: false,
                usesToolsKeyboard: false,
                softwareKeyboardHeight: 0))
        #expect(
            AgentDirectInputPresentation.shouldClaimKeyboard(
                wantsKeyboard: false,
                isKeyboardUp: true,
                usesToolsKeyboard: false,
                softwareKeyboardHeight: 0))
        #expect(
            AgentDirectInputPresentation.shouldClaimKeyboard(
                wantsKeyboard: false,
                isKeyboardUp: false,
                usesToolsKeyboard: true,
                softwareKeyboardHeight: 0))
        #expect(
            AgentDirectInputPresentation.shouldClaimKeyboard(
                wantsKeyboard: false,
                isKeyboardUp: false,
                usesToolsKeyboard: false,
                softwareKeyboardHeight: 336))
    }

    @Test func openMessageAgentStillRejectsLocalGhosttyInput() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        composer.replaceDraft(with: "keep me")
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let interactions = AgentTerminalInteractionProbe()

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                interactionProbe: interactions))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
                && interactions.isConnected
        })
        #expect(interactions.isMessageAgentOpen == false)

        try #require(try await Self.activateControl(
            labeled: "Message Agent",
            in: controller.view,
            probe: { interactions.tapMessageAgent() }))
        try #require(await Self.eventually { interactions.isMessageAgentOpen == true })
        controller.view.layoutIfNeeded()

        let terminal = try #require(Self.terminals(in: controller.view).first)
        try #require(await Self.eventually { !terminal.isLocalInputEnabled })
        terminal.requestKeyboard()
        await Task.yield()
        #expect(!terminal.isFirstResponder)
        #expect(
            await transport.attachInputs.allSatisfy {
                if case .keystrokes = $0 { false } else { true }
            })
        #expect(composer.draft == "keep me")
        #expect(await transport.agentPromptParams.isEmpty)

        await owner.leave().value
    }

    @Test func terminalKeyboardTakesMessageAgentsVisibleKeyboardWithoutReloading() async throws {
        let center = NotificationCenter.default
        let inset = TerminalKeyboardInset(notificationCenter: center)
        let keyboardTransitions = KeyboardTransitionProbe(
            notificationCenter: center,
            insetHeight: { inset.height })
        defer { keyboardTransitions.stop() }
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        composer.replaceDraft(with: "do not send")
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let interactions = AgentTerminalInteractionProbe()

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                keyboardInset: inset,
                interactionProbe: interactions))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        // An iPad's keyboard rises from the bottom of its taller screen,
        // below a phone-sized window at the top, and covers none of it. On
        // the bottom edge the window is covered as a phone's is.
        if UIDevice.current.userInterfaceIdiom == .pad, let screen = window.windowScene?.screen {
            window.frame.origin.y = screen.bounds.height - window.frame.height
        }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
                && interactions.isConnected
        })

        try #require(try await Self.activateControl(
            labeled: "Message Agent",
            in: controller.view,
            probe: { interactions.tapMessageAgent() }))
        try #require(await Self.eventually {
            controller.view.layoutIfNeeded()
            return interactions.isMessageAgentOpen == true
                && Self.composerInput(in: controller.view) != nil
        })
        let terminal = try #require(Self.terminals(in: controller.view).first)
        try #require(await Self.eventually { !terminal.isLocalInputEnabled })
        let composerInput = try #require(Self.composerInput(in: controller.view))
        // One keyboard context across the handoff: Agent input is natural
        // language in both the draft and the terminal.
        #expect(composerInput.autocorrectionType == terminal.autocorrectionType)
        #expect(composerInput.autocapitalizationType == terminal.autocapitalizationType)
        composerInput.becomeFirstResponder()
        try #require(await Self.eventually { composerInput.isFirstResponder })
        try #require(await Self.eventually { composerInput.inputView == nil })
        try #require(await Self.eventually {
            inset.height > 0
                && (keyboardTransitions.willShowCount > 0
                    || keyboardTransitions.willChangeFrameCount > 0)
        })
        let keyboardHeight = inset.height
        #expect(window.isKeyWindow)
        #expect(composerInput.window === window)
        keyboardTransitions.setChromeSample {
            Self.keyboardChromeSample(in: controller.view, window: window, inset: inset)
        }
        keyboardTransitions.reset()
        try #require(await Self.eventually { keyboardTransitions.hasStableTail() })
        keyboardTransitions.reset()

        try #require(try await Self.activateControl(
            labeled: "Terminal Keyboard",
            in: controller.view,
            probe: { interactions.tapTerminalKeyboard() }))
        // The measured keyboard stays in place while SwiftUI updates the
        // existing terminal and transfers first responder to it.
        #expect(inset.height == keyboardHeight)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            interactions.isMessageAgentOpen == false
                && interactions.isTerminalKeyboardUp == true
                && terminal.isLocalInputEnabled
                && terminal.isFirstResponder
                && interactions.inputChromeMountCount == 1
                && !inset.isHoldingHandoffHeight
                && keyboardTransitions.observedHandoffWindow()
                && keyboardTransitions.hasStableTail()
        })
        keyboardTransitions.stopSampling()
        #expect(!composerInput.isFirstResponder)
        #expect(terminal.window === window)
        #expect(inset.height == keyboardHeight)
        #expect(
            keyboardTransitions.observedInsetHeights.allSatisfy { $0 == keyboardHeight },
            "Message Agent→Terminal Keyboard exposed transient insets: \(keyboardTransitions.observedInsetHeights)")
        Self.expectStableKeyboardChrome(
            keyboardTransitions.chromeSamples,
            keyboardHeight: keyboardHeight,
            direction: "Message Agent→Terminal Keyboard")
        #expect(composer.draft == "do not send")
        #expect(await transport.agentPromptParams.isEmpty)
        #expect(
            await transport.attachInputs.allSatisfy {
                if case .keystrokes = $0 { false } else { true }
            })

        await owner.leave().value
    }

    @Test(arguments: [false, true])
    func toolsSnippetsInsertIntoAttachWithoutSubmitting(bracketed: Bool) async throws {
        guard #available(iOS 27, *) else { return }
        let suiteName = "tools-insertion-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let snippets = SnippetStore(defaults: defaults)
        let snippet = try Snippet.make(title: "Insert test phrase", body: "first\nsecond")
        try snippets.add(snippet)
        let settings = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults), snippets: snippets,
            toolbars: AgentToolbarLayoutStore(defaults: defaults, idiom: .phone))
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 336 }
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        composer.replaceDraft(with: "keep this local: ")
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let interactions = AgentTerminalInteractionProbe()
        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner, composer: composer,
                keyboardInset: inset, interactionProbe: interactions,
                terminalSettings: settings))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        let terminal = try #require(Self.terminals(in: controller.view).first)
        terminal.receive(Data((bracketed ? "\u{1B}[?2004h" : "\u{1B}[?2004l").utf8))
        #expect(terminal.usesBracketedPaste == bracketed)
        terminal.requestKeyboard()
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey:
                CGRect(x: 0, y: 500, width: 402, height: 370)])
        try #require(await Self.eventually { inset.height == 336 })
        try #require(try await Self.activateControl(
            labeled: "Tools Keyboard", in: controller.view, probe: { false }))
        for label in ["Skills", "Snippets", "Terminal Appearance"] {
            try #require(try await Self.waitForAccessible(labeled: label, in: controller.view) != nil)
        }
        try #require(try await Self.activateControl(
            labeled: "Snippets", in: controller.view, probe: { false }))
        try #require(try await Self.activateControl(
            labeled: snippet.displayTitle, in: controller.view, probe: { false }))
        let expected = Data((bracketed ? "\u{1B}[200~first\nsecond\u{1B}[201~" : snippet.body).utf8)
        try #require(await Self.eventually {
            await transport.attachInputs.contains(.keystrokes(expected))
        })
        let bytes = await transport.attachInputs.reduce(into: Data()) { output, input in
            if case .keystrokes(let data) = input { output.append(data) }
        }
        #expect(bytes == expected)
        #expect(composer.draft == "keep this local: ")
        #expect(interactions.isMessageAgentOpen == false)
        #expect(inset.lastPresentedHeight == 336)
        #expect(owner.pendingPaste == nil)
        #expect(await transport.agentPromptParams.isEmpty)
        await owner.leave().value
    }

    @Test func agentViewOpensIdleWithoutRaisingKeyboard() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 336 }
        center.post(
            name: UIResponder.keyboardWillShowNotification,
            object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                    x: 0, y: 500, width: 402, height: 370)
            ])
        try await waitUntil("the keyboard inset should reach its presented height") { inset.height == 336 }
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 336)

        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let interactions = AgentTerminalInteractionProbe()

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                keyboardInset: inset,
                interactionProbe: interactions))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
                && interactions.isConnected
                && interactions.inputChromeMountCount == 1
        })

        #expect(interactions.isMessageAgentOpen == false)
        #expect(interactions.isTerminalKeyboardUp == false)
        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(terminal.isLocalInputEnabled)
        #expect(!terminal.isFirstResponder)
        if #available(iOS 27, *) {
            try #require(
                try await Self.waitForAccessible(
                    labeled: "Escape",
                    in: controller.view) != nil)
        }

        await owner.leave().value
    }

    @Test func coldDirectEntryResumesPausedHeightCapture() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 336 }
        center.post(
            name: UIResponder.keyboardWillShowNotification,
            object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                    x: 0, y: 500, width: 402, height: 370)
            ])
        try await waitUntil("the keyboard inset should reach its presented height") { inset.height == 336 }
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 336)
        inset.pauseHeightCapture()

        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let interactions = AgentTerminalInteractionProbe()

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                keyboardInset: inset,
                interactionProbe: interactions))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
                && interactions.isConnected
                && interactions.inputChromeMountCount == 1
        })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(terminal.isLocalInputEnabled)
        #expect(!terminal.isFirstResponder)
        if #available(iOS 27, *) {
            try #require(
                try await Self.waitForAccessible(
                    labeled: "Escape",
                    in: controller.view) != nil)
        }

        terminal.requestKeyboard()
        try #require(await Self.eventually { terminal.isFirstResponder })
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey:
                    CGRect(x: 0, y: 500, width: 402, height: 370)
            ])
        #expect(try await Self.eventually { inset.height == 336 })
        await owner.leave().value
    }

    @Test func returningFromListDoesNotRestoreKeyboard() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let probe = AgentTerminalInteractionProbe()
        var onStage = true
        let detail = UIHostingController(rootView: Self.makeDetailView(
            attachStore: owner, composer: composer,
            interactionProbe: probe, isOnStage: { onStage }))
        let navigation = UINavigationController(rootViewController: UIViewController())
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: navigation)
        defer { window.isHidden = true }
        navigation.pushViewController(detail, animated: false)
        try #require(await Self.eventually { probe.isConnected })
        let terminal = try #require(Self.terminals(in: detail.view).first)
        #expect(probe.tapTerminalKeyboard())
        try #require(await Self.eventually { terminal.isFirstResponder })
        onStage = false
        navigation.popViewController(animated: false)
        try #require(await Self.eventually { !probe.isConnected })
        // Wait for the production leave cleanup, rather than assuming a
        // Task.yield orders it before the next navigation transaction.
        try #require(await Self.eventually { !terminal.canBecomeFirstResponder })
        // Keep the hosting controller alive: a cached destination must clear
        // intent on a real leave, even when SwiftUI retains its @State.
        onStage = true
        navigation.pushViewController(detail, animated: false)
        try #require(await Self.eventually { probe.isConnected })
        let returned = try #require(Self.terminals(in: detail.view).first)
        #expect(!returned.isFirstResponder)
        await owner.leave().value
    }

    /// New Agent and Open Terminal arm the handoff with the tools dock when it
    /// is up; the next Agent view must come up on the dock, keep the last
    /// presented height, and resume system-inset capture when swapped back.
    @Test func toolsKeyboardSurvivesAgentHandoffAndResumesSystemInset() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 336 }
        let handoff = TerminalKeyboardHandoff()
        let firstAgent = Self.makeAgent(status: .idle)
        let secondAgent = Self.makeAgent(status: .idle)
        var selectedID = firstAgent.id
        let firstComposer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let secondComposer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let firstOwner = try await Self.makeLiveAttach(
            transport: ScriptedTransport(), composer: firstComposer)
        let secondOwner = try await Self.makeLiveAttach(
            transport: ScriptedTransport(), composer: secondComposer)
        let firstProbe = AgentTerminalInteractionProbe()
        let secondProbe = AgentTerminalInteractionProbe()
        let controller = UIHostingController(rootView: AnyView(Self.makeDetailView(
            agent: firstAgent, attachStore: firstOwner, composer: firstComposer,
            keyboardHandoff: handoff, keyboardInset: inset,
            interactionProbe: firstProbe, isOnStage: { selectedID == firstAgent.id })
            .id(firstAgent.id)))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        try #require(await Self.eventually { firstProbe.isConnected })
        let firstTerminal = try #require(Self.terminals(in: controller.view).first)
        #expect(firstProbe.tapTerminalKeyboard())
        try #require(await Self.eventually { firstTerminal.isFirstResponder })
        let frame: [AnyHashable: Any] = [
            UIResponder.keyboardFrameEndUserInfoKey:
                CGRect(x: 0, y: 500, width: 402, height: 370)
        ]
        center.post(name: UIResponder.keyboardWillShowNotification, object: nil, userInfo: frame)
        try #require(await Self.eventually { inset.height == 336 })
        try #require(await Self.eventually {
            firstProbe.performToolbarItem(.action(.toolsKeyboard))
        })
        #expect(firstTerminal.keyboardMode == .controls)
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        // The New Agent sheet and Open Terminal arm the handoff this way.
        handoff.arm(for: secondAgent.id, mode: .controls)
        selectedID = secondAgent.id
        controller.rootView = AnyView(Self.makeDetailView(
            agent: secondAgent, attachStore: secondOwner, composer: secondComposer,
            keyboardHandoff: handoff, keyboardInset: inset,
            interactionProbe: secondProbe, isOnStage: { selectedID == secondAgent.id })
            .id(secondAgent.id))
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually { secondProbe.isConnected })
        let secondTerminal = try #require(Self.terminals(in: controller.view).first)
        // iPad Tools releases input; iPhone Tools keeps its keyboard responder.
        let retainsResponder = !TerminalKeyboardMode.controlsReleaseFirstResponder
        try #require(await Self.eventually {
            secondTerminal.keyboardMode == .controls
                && secondTerminal.isFirstResponder == retainsResponder
        })
        #expect(!handoff.consume(secondAgent.id))
        #expect(inset.lastPresentedHeight == 336)
        try #require(await Self.eventually {
            secondProbe.performToolbarItem(.action(.toolsKeyboard))
        })
        #expect(secondTerminal.keyboardMode == .text)
        center.post(name: UIResponder.keyboardWillShowNotification, object: nil, userInfo: frame)
        #expect(try await Self.eventually { inset.height == 336 })
        await firstOwner.leave().value
        await secondOwner.leave().value
    }

    @Test func hardwareKeyboardReconnectDoesNotReplaceTheToolsDock() async throws {
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let owner = try await Self.makeLiveAttach(
            transport: ScriptedTransport(), composer: composer)
        let interactions = AgentTerminalInteractionProbe()
        let controller = UIHostingController(rootView: Self.makeDetailView(
            attachStore: owner, composer: composer, interactionProbe: interactions))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        try #require(await Self.eventually { interactions.isConnected })
        let terminal = try #require(Self.terminals(in: controller.view).first)
        terminal.isHardwareKeyboardConnected = { false }
        terminal.requestKeyboard()
        try #require(await Self.eventually { terminal.isFirstResponder })
        // Tools comes after the screen has seen the keyboard rise, as a
        // user's next tap does; a layout pass delivers the rise. Seen only
        // once the dock is up, on iPad it reads as a tap on the terminal,
        // which swaps the dock out for the system keyboard.
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        try #require(interactions.performToolbarItem(.action(.toolsKeyboard)))
        try #require(await Self.eventually { terminal.keyboardMode == .controls })
        try #require(await Self.eventually { !terminal.isHardwareKeyboardAutoFocus })

        // iPad Tools releases input; iPhone Tools keeps its keyboard responder.
        let retainsResponder = !TerminalKeyboardMode.controlsReleaseFirstResponder
        try #require(await Self.eventually { terminal.isFirstResponder == retainsResponder })
        terminal.isHardwareKeyboardConnected = { true }
        NotificationCenter.default.post(name: .GCKeyboardDidConnect, object: nil)
        #expect(terminal.isFirstResponder == retainsResponder)
        #expect(terminal.keyboardMode == .controls)

        // Repeated re-arming after the mounted update must not change the chosen input.
        terminal.setNeedsLayout()
        terminal.layoutIfNeeded()
        terminal.rearmHardwareKeyboardFocus()
        #expect(terminal.isFirstResponder == retainsResponder)
        #expect(terminal.keyboardMode == .controls)

        // The explicit toolbar action can still return to the system keyboard.
        try #require(interactions.performToolbarItem(.action(.toolsKeyboard)))
        try #require(await Self.eventually {
            terminal.keyboardMode == .text && terminal.isFirstResponder
        })
        await owner.leave().value
    }

    @Test func ghosttyReturnSendsPtyCRWithoutComposerPrompt() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        composer.replaceDraft(with: "waiting draft")
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(terminal.isLocalInputEnabled)
        terminal.requestKeyboard()
        try #require(await Self.eventually { terminal.isFirstResponder })

        // Soft-keyboard Return enters through UIKeyInput.insertText("\n"),
        // not sendQuickKey. Production maps that to PTY CR.
        (terminal as UIKeyInput).insertText("\n")
        try #require(await Self.eventually {
            await transport.attachInputs.contains(
                TerminalAttachInput.keystrokes(Data([0x0D])))
        })
        #expect(composer.draft == "waiting draft")
        #expect(await transport.agentPromptParams.isEmpty)

        await owner.leave().value
    }

    @Test func toolbarPersistsAndSendsBytesAcrossKeyboardVisibility() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 336 }
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let interactions = AgentTerminalInteractionProbe()

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                keyboardInset: inset,
                interactionProbe: interactions))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
                && interactions.isConnected
                && interactions.inputChromeMountCount == 1
        })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        terminal.requestKeyboard()
        try #require(await Self.eventually { terminal.isFirstResponder })

        if #available(iOS 27, *) {
            #expect(Self.firstAccessible(labeled: "Escape", in: controller.view) != nil)
        }
        controller.view.layoutIfNeeded()
        let heightBeforeKeyboard = terminal.frame.height

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                    x: 0, y: 500, width: 402, height: 370)
            ])
        try #require(await Self.eventually { inset.height == 336 })
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        let heightWithKeyboard = try #require(Self.terminals(in: controller.view).first)
            .frame.height

        let defaultKeys: [AgentToolbarKeyChord] =
            AgentToolbarLayout.default.items.compactMap { item in
                guard case .key(let chord) = item.content else { return nil }
                return chord
            }
        try #require(!defaultKeys.isEmpty)
        for chord in defaultKeys {
            try #require(Self.shortcutBytes[chord] != nil, "no expected bytes for \(chord.glyphs)")
            try #require(try await Self.activateControl(
                labeled: Self.accessibilityLabel(of: chord),
                in: controller.view,
                probe: { interactions.performToolbarItem(.key(chord)) }))
        }

        if #available(iOS 27, *) {
            // One bar: the keys share a row with the fixed controls at its
            // trailing edge, Message Agent before Terminal Keyboard.
            let escapeFrame = try #require(
                Self.firstAccessibleFrame(labeled: "Escape", in: controller.view))
            let messageAgentFrame = try #require(
                Self.firstAccessibleFrame(labeled: "Message Agent", in: controller.view))
            let terminalKeyboardFrame = try #require(
                Self.firstAccessibleFrame(labeled: "Terminal Keyboard", in: controller.view))
            let enterFrame = try #require(
                Self.firstAccessibleFrame(labeled: "Send, Enter", in: controller.view))
            let moreFrame = try #require(
                Self.firstAccessibleFrame(labeled: "More", in: controller.view))
            #expect(abs(escapeFrame.midY - terminalKeyboardFrame.midY) <= 1)
            #expect(abs(messageAgentFrame.midY - terminalKeyboardFrame.midY) <= 1)
            #expect(messageAgentFrame.maxX <= terminalKeyboardFrame.minX + 1)
            #expect(moreFrame.minX >= enterFrame.maxX)
            #expect(Self.accessibleCount(labeled: "Terminal Keyboard", in: controller.view) == 1)
            #expect(Self.accessibleCount(labeled: "Message Agent", in: controller.view) == 1)
        }

        try #require(await Self.eventually {
            let inputs = await transport.attachInputs
            return defaultKeys.allSatisfy { chord in
                Self.shortcutBytes[chord].map { inputs.contains(.keystrokes($0)) } ?? false
            }
        })
        #expect(await transport.agentPromptParams.isEmpty)

        // Rendered production inset: AgentTerminalKeyboardInsetModifier must
        // shrink the hosted terminal by the software-keyboard height.
        #expect(heightBeforeKeyboard - heightWithKeyboard >= 336)

        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        #expect(interactions.inputChromeMountCount == 1)
        if #available(iOS 27, *) {
            #expect(Self.firstAccessible(labeled: "Escape", in: controller.view) != nil)
            #expect(Self.accessibleCount(labeled: "Terminal Keyboard", in: controller.view) == 1)
        }
        let heightAfterHide = try #require(Self.terminals(in: controller.view).first)
            .frame.height
        #expect(abs(heightAfterHide - heightBeforeKeyboard) < 1)

        await owner.leave().value
    }

    /// iPhone's Back and the iPad slide-over's sidebar toggle float at the
    /// Agent's top-leading corner; the terminal's first row starts below
    /// them, never under them.
    @Test(arguments: [false, true])
    func topLeadingControlNeverCoversTheTerminal(inSlideOver: Bool) async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let slot = ConsoleSlideOverGeometry.headerSlot(windowControlsWidth: 0)
        // A scene root hands the Agent its window, safe area already known.
        // Without one the screen reads its own window at mount, before a
        // fresh test window has safe-area insets, and pads nothing for the
        // status bar until something else re-renders it.
        let sceneWindow = WindowReference()
        let controller = UIHostingController(
            rootView: Self.makeDetailView(attachStore: owner, composer: composer)
                .environment(\.horizontalSizeClass, inSlideOver ? .regular : .compact)
                .environment(\.verticalSizeClass, .regular)
                .environment(\.consoleDetailHeaderSlot, inSlideOver ? slot : nil)
                .environment(\.sceneWindow, sceneWindow))
        let window = try await makeTestWindow(
            frame: inSlideOver
                ? CGRect(x: 0, y: 0, width: 1024, height: 1366)
                : CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        sceneWindow.attach(window)
        func terminalFrame() -> CGRect? {
            controller.view.layoutIfNeeded()
            return Self.terminals(in: controller.view).first
                .map { $0.convert($0.bounds, to: controller.view) }
        }
        // Both controls sit this far below the status bar: the layout pads
        // its toggle from the safe area, and Back rides the same line.
        let controlBottom = window.safeAreaInsets.top
            + ConsoleSlideOverGeometry.toggleTopInset + ConsoleSlideOverGeometry.toggleSize
        try #require(window.safeAreaInsets.top > 0)
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live && terminalFrame() != nil
        })
        // The attach re-renders the screen with the status-bar padding on
        // the next pass.
        #expect(try await Self.eventually { (terminalFrame()?.minY ?? 0) >= controlBottom })
        let settled = try #require(terminalFrame())
        #expect(settled.height > 0)

        if !inSlideOver, #available(iOS 27, *) {
            try #require(try await Self.waitForAccessible(labeled: "Back", in: controller.view) != nil)
            let back = try #require(Self.firstAccessibleFrame(labeled: "Back", in: controller.view))
            let terminalTop = try #require(terminalFrame()).minY
            #expect(back.minY >= window.safeAreaInsets.top)
            #expect(back.maxY <= terminalTop)
        }

        await owner.leave().value
    }

    /// Portrait iPad: while the open list covers the Agent no key may reach
    /// its hidden terminal, so the terminal's keyboard goes down, and it
    /// stays down when the list closes some other way. The tap on the
    /// Agent's visible strip, which closes the list, raises it again.
    @Test func theCoveringListTakesTheKeyboardAndTheCatcherTapGivesItBack() async throws {
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let owner = try await Self.makeLiveAttach(transport: ScriptedTransport(), composer: composer)
        let slideOver = SlideOverEnvironment()
        let controller = UIHostingController(rootView: SlideOverEnvironmentHost(
            environment: slideOver,
            content: Self.makeDetailView(attachStore: owner, composer: composer)))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        try #require(await Self.eventually { !Self.terminals(in: controller.view).isEmpty })
        let terminal = try #require(Self.terminals(in: controller.view).first)

        slideOver.focusTaps += 1
        #expect(try await Self.eventually { terminal.isFirstResponder })

        slideOver.isCovered = true
        #expect(try await Self.eventually { !terminal.isFirstResponder })

        slideOver.isCovered = false
        try await Task.sleep(for: .milliseconds(200))
        #expect(!terminal.isFirstResponder)

        slideOver.focusTaps += 1
        #expect(try await Self.eventually { terminal.isFirstResponder })

        await owner.leave().value
    }

    /// Switching with the keyboard up hands it to the next Agent's terminal,
    /// and the handoff is spent so it cannot raise a later surface.
    @Test func aKeyboardHandedToAnAgentReachesItsTerminal() async throws {
        let agent = Self.makeAgent(status: .idle)
        let handoff = TerminalKeyboardHandoff()
        handoff.arm(for: agent.id)
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let transport = ScriptedTransport()
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let controller = UIHostingController(rootView: Self.makeDetailView(
            agent: agent, attachStore: owner, composer: composer, keyboardHandoff: handoff))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        try #require(await Self.eventually { !Self.terminals(in: controller.view).isEmpty })
        let terminal = try #require(Self.terminals(in: controller.view).first)

        #expect(try await Self.eventually { terminal.isFirstResponder })
        #expect(!handoff.isArmed)

        await owner.leave().value
    }

    @Test func customToolbarLayoutSendsItsCombosAndDropsRemovedKeys() async throws {
        let suiteName = "custom-shortcuts-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let toolbars = AgentToolbarLayoutStore(defaults: defaults, idiom: .phone)
        let interrupt = AgentToolbarKeyChord(.character("c"), modifiers: .control)
        // No ⇧Tab and no More: the Toolbar shows exactly what was saved.
        let saved = AgentToolbarLayout(items: [
            AgentToolbarItem(.key(AgentToolbarKeyChord(.escape))),
            AgentToolbarItem(.key(interrupt)),
            AgentToolbarItem(.key(AgentToolbarKeyChord(.tab))),
            AgentToolbarItem(.key(AgentToolbarKeyChord(.enter))),
        ])
        try toolbars.setLayout(saved)
        let settings = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults),
            toolbars: toolbars)
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let interactions = AgentTerminalInteractionProbe()
        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner, composer: composer,
                interactionProbe: interactions, terminalSettings: settings))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
                && interactions.isConnected
                && interactions.inputChromeMountCount == 1
        })

        let toolbar = try #require(interactions.toolbarLayout)
        #expect(toolbar.hasSameContents(as: saved))
        let interruptLabel = Self.accessibilityLabel(of: interrupt)
        if #available(iOS 27, *) {
            #expect(try await Self.waitForAccessible(labeled: interruptLabel, in: controller.view) != nil)
            #expect(try await Self.activateControl(
                labeled: Self.accessibilityLabel(of: AgentToolbarKeyChord(.shiftTab)),
                in: controller.view,
                probe: { false }) == false)
            #expect(Self.firstAccessible(labeled: "More", in: controller.view) == nil)
        }
        try #require(try await Self.activateControl(
            labeled: interruptLabel,
            in: controller.view,
            probe: { interactions.performToolbarItem(.key(interrupt)) }))
        try #require(await Self.eventually {
            await transport.attachInputs.contains(.keystrokes(Data([0x03])))
        })
        #expect(await transport.agentPromptParams.isEmpty)

        await owner.leave().value
    }

    @Test func toolsToSystemSwapKeepsToolbarThroughCoalesce() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 336 }
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let interactions = AgentTerminalInteractionProbe()

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                keyboardInset: inset,
                interactionProbe: interactions))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
                && interactions.isConnected
                && interactions.inputChromeMountCount == 1
        })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        terminal.requestKeyboard()
        try #require(await Self.eventually { terminal.isFirstResponder })
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                    x: 0, y: 500, width: 402, height: 370)
            ])
        try #require(await Self.eventually { inset.height == 336 })
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        let heightWithSoftwareKeyboard = try #require(
            Self.terminals(in: controller.view).first).frame.height
        #expect(interactions.inputChromeMountCount == 1)

        try #require(try await Self.activateControl(
            labeled: "Tools Keyboard",
            in: controller.view,
            probe: { interactions.performToolbarItem(.action(.toolsKeyboard)) }))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        // Tools replaces the software keyboard without hiding the Toolbar.
        #expect(interactions.inputChromeMountCount == 1)

        // UIKit tears the software keyboard down while Tools stays first
        // responder — the production hold must keep `.system` once we leave Tools.
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 336)

        try #require(try await Self.activateControl(
            labeled: "Tools Keyboard",
            in: controller.view,
            probe: { interactions.performToolbarItem(.action(.toolsKeyboard)) }))
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()

        // Pre-show `.system` hold: the Toolbar stays above the keyboard's
        // footprint even while measured height is still zero. Two-sided bound:
        // wiring the modifier to the raw zero height expands the terminal by
        // ~lastPresentedHeight and still satisfies a one-sided upper bound.
        #expect(interactions.inputChromeMountCount == 1)
        let midSwapTerminal = try #require(Self.terminals(in: controller.view).first)
        #expect(midSwapTerminal.isFirstResponder)
        #expect(abs(heightWithSoftwareKeyboard - midSwapTerminal.frame.height) <= 1)

        // Software keyboard actually appears — hold must release without a
        // transient `.hidden` dip (row and inset stay).
        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                    x: 0, y: 500, width: 402, height: 370)
            ])
        try #require(await Self.eventually { inset.height == 336 })
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        #expect(interactions.inputChromeMountCount == 1)
        let afterShow = try #require(Self.terminals(in: controller.view).first)
        #expect(afterShow.isFirstResponder)
        #expect(abs(afterShow.frame.height - heightWithSoftwareKeyboard) < 1)

        // Hardware keyboard hides the software keyboard while Ghostty remains
        // first responder. Released hold must not keep a stale inset; the
        // Toolbar stays, as it does in every state.
        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        let afterHardwareHide = try #require(Self.terminals(in: controller.view).first)
        #expect(afterHardwareHide.isFirstResponder)
        #expect(interactions.inputChromeMountCount == 1)
        #expect(afterHardwareHide.frame.height - heightWithSoftwareKeyboard >= 336)

        await owner.leave().value
    }

    @Test func hardwareFirstResponderDoesNotReserveSoftwareKeyboardGap() async throws {
        let center = NotificationCenter()
        let inset = TerminalKeyboardInset(notificationCenter: center) { _ in 336 }
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let interactions = AgentTerminalInteractionProbe()

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                keyboardInset: inset,
                interactionProbe: interactions))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
                && interactions.isConnected
                && interactions.inputChromeMountCount == 1
        })

        center.post(
            name: UIResponder.keyboardWillShowNotification, object: nil,
            userInfo: [
                UIResponder.keyboardFrameEndUserInfoKey: CGRect(
                    x: 0, y: 500, width: 402, height: 370)
            ])
        try #require(await Self.eventually { inset.height == 336 })
        #expect(inset.lastPresentedHeight == 336)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        let heightWithSoftwareKeyboard = try #require(
            Self.terminals(in: controller.view).first).frame.height

        center.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        #expect(inset.height == 0)
        #expect(inset.lastPresentedHeight == 336)

        let terminal = try #require(Self.terminals(in: controller.view).first)
        terminal.requestKeyboard()
        try #require(await Self.eventually { terminal.isFirstResponder })
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()

        let hardwareTerminal = try #require(Self.terminals(in: controller.view).first)
        #expect(hardwareTerminal.isFirstResponder)
        if #available(iOS 27, *) {
            #expect(Self.firstAccessible(labeled: "Escape", in: controller.view) != nil)
        }
        // No software keyboard: production inset must not reserve lastPresentedHeight.
        #expect(hardwareTerminal.frame.height - heightWithSoftwareKeyboard >= 336)

        await owner.leave().value
    }

    @Test func directPasteRoutesThroughAttachReview() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(terminal.isLocalInputEnabled)
        terminal.requestPaste("git status\ngit diff")
        let pending = try #require(owner.pendingPaste)
        #expect(pending.preview == "git status\ngit diff")
        #expect(pending.lineCount == 2)
        #expect(pending.characterCount == "git status\ngit diff".count)
        #expect(
            await transport.attachInputs.allSatisfy {
                if case .keystrokes = $0 { false } else { true }
            })

        owner.confirmPaste()
        try #require(await Self.eventually {
            await transport.attachInputs.contains {
                if case .keystrokes(let data) = $0 {
                    return String(data: data, encoding: .utf8)?.contains("git status") == true
                }
                return false
            }
        })
        #expect(owner.pendingPaste == nil)

        await owner.leave().value
    }

    /// From Extra Large text up the system draws nothing in the Paste key's
    /// slot, leaving a blank gap, so its control stops growing at Large and
    /// follows a text size change while it is on screen.
    @Test func pasteKeyTextSizeStopsAtLarge() throws {
        let controller = UIViewController()
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        let pasteKey = KeyCapPasteView(paste: { _ in })
        pasteKey.frame = CGRect(x: 0, y: 0, width: 41, height: InputChromeLayout.pasteControlSide)
        controller.view.addSubview(pasteKey)
        let control = try #require(pasteKey.subviews.first as? UIPasteControl)

        let cases: [(user: UIContentSizeCategory, drawn: UIContentSizeCategory)] = [
            (.small, .small),
            (.large, .large),
            (.extraLarge, .large),
            (.accessibilityExtraExtraExtraLarge, .large),
            (.medium, .medium),
        ]
        for (user, drawn) in cases {
            controller.view.traitOverrides.preferredContentSizeCategory = user
            controller.view.layoutIfNeeded()
            #expect(control.traitCollection.preferredContentSizeCategory == drawn, "at \(user.rawValue)")
        }
    }

    /// A control the system never sized (its SecureControlService died) is
    /// covered by the fallback key once it has stayed blank on screen past
    /// the timeout; a sized control, or one gone before then, is left alone.
    @Test func pasteKeyFallsBackWhenTheControlStaysUnsized() async throws {
        let controller = UIViewController()
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        func makeKey(size: CGSize, timeout: Duration) throws
            -> (KeyCapPasteView, UIPasteControl, UIButton)
        {
            let pasteKey = KeyCapPasteView(
                paste: { _ in }, contentSize: { _ in size }, contentTimeout: timeout)
            let control = try #require(pasteKey.subviews.first as? UIPasteControl)
            let fallback = try #require(pasteKey.subviews.last as? UIButton)
            #expect(fallback.isHidden)
            #expect(!control.accessibilityElementsHidden)
            return (pasteKey, control, fallback)
        }

        let (blank, blankControl, blankFallback) = try makeKey(
            size: .zero, timeout: .milliseconds(10))
        controller.view.addSubview(blank)
        let check = try #require(blank.contentCheck)
        await check.value
        #expect(!blankFallback.isHidden)
        #expect(blankControl.accessibilityElementsHidden)

        let (drawn, drawnControl, drawnFallback) = try makeKey(
            size: CGSize(width: 30, height: 30), timeout: .milliseconds(10))
        controller.view.addSubview(drawn)
        #expect(drawn.contentCheck == nil)
        #expect(drawnFallback.isHidden)
        #expect(!drawnControl.accessibilityElementsHidden)

        let (gone, goneControl, goneFallback) = try makeKey(size: .zero, timeout: .seconds(60))
        controller.view.addSubview(gone)
        let pending = try #require(gone.contentCheck)
        gone.removeFromSuperview()
        await pending.value
        #expect(goneFallback.isHidden)
        #expect(!goneControl.accessibilityElementsHidden)
    }

    @Test func blockedStatusKeepsMessageAgentClosed() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1", initialStatus: .blocked) { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let interactions = AgentTerminalInteractionProbe()

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                agent: Self.makeAgent(status: .blocked),
                attachStore: owner,
                composer: composer,
                interactionProbe: interactions))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
                && interactions.isConnected
        })

        #expect(interactions.isMessageAgentOpen == false)
        let terminal = try #require(Self.terminals(in: controller.view).first)
        #expect(terminal.isLocalInputEnabled)
        terminal.sendQuickKey(AgentQuickKey.enter)
        try #require(await Self.eventually {
            await transport.attachInputs.contains(
                TerminalAttachInput.keystrokes(Data([0x0D])))
        })
        #expect(await transport.agentPromptParams.isEmpty)

        await owner.leave().value
    }

    @Test func terminalReplacementWhileTerminalKeyboardUpClaimsIntent() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        composer.replaceDraft(with: "keep")
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let interactions = AgentTerminalInteractionProbe()

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer,
                interactionProbe: interactions))
        // A scene-less hierarchy isolates Attach feed replacement from UIKit's
        // active software-keyboard reload while retaining responder semantics.
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
                && interactions.isConnected
        })

        try #require(try await Self.activateControl(
            labeled: "Terminal Keyboard",
            in: controller.view,
            probe: { interactions.tapTerminalKeyboard() }))
        let first = try #require(Self.terminals(in: controller.view).first)
        try #require(await Self.eventually { first.isFirstResponder })
        let firstID = owner.terminalID
        let firstFeed = owner.terminalFeed

        owner.transportGenerationDidChange(2)
        try #require(await Self.eventually {
            owner.terminalID != firstID
        })
        // Replacement pipeline is a fresh Attach waiting for its first size.
        owner.viewDidResize(cols: 80, rows: 24)
        try #require(await Self.eventually {
            await transport.attachRequests.count == 2
        })
        #expect(await transport.emitAttachOutput(Data("replaced".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })
        // Hosted SwiftUI may reuse the UIView address; prove the rendered
        // terminal is attached to the replacement feed, not the predecessor.
        #expect(owner.terminalFeed !== firstFeed)
        let replacement = try #require(await Self.eventuallyTerminal(
            boundTo: owner.terminalFeed, in: controller.view))
        #expect(!firstFeed.isAttached(to: replacement))
        #expect(replacement.isLocalInputEnabled)
        try #require(await Self.eventually { replacement.isFirstResponder })
        #expect(composer.draft == "keep")

        await owner.leave().value
    }

    @Test func dismissAfterReplacementDoesNotRaiseOnSecondReplacement() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)
        let handoff = TerminalKeyboardHandoff()
        let agent = Self.makeAgent(status: .idle)
        let interactions = AgentTerminalInteractionProbe()

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                agent: agent,
                attachStore: owner,
                composer: composer,
                keyboardHandoff: handoff,
                interactionProbe: interactions))
        // A scene-less hierarchy isolates Attach feed replacement from UIKit's
        // active software-keyboard reload while retaining responder semantics.
        let window = Self.makeLocalTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
                && interactions.isConnected
        })

        try #require(try await Self.activateControl(
            labeled: "Terminal Keyboard",
            in: controller.view,
            probe: { interactions.tapTerminalKeyboard() }))
        let first = try #require(Self.terminals(in: controller.view).first)
        try #require(await Self.eventually { first.isFirstResponder })
        let firstID = owner.terminalID
        let firstFeed = owner.terminalFeed

        // Replacement while keyboard up — intent reclaim, not a leftover handoff.
        owner.transportGenerationDidChange(2)
        try #require(await Self.eventually { owner.terminalID != firstID })
        owner.viewDidResize(cols: 80, rows: 24)
        try #require(await Self.eventually {
            await transport.attachRequests.count == 2
        })
        #expect(await transport.emitAttachOutput(Data("first-replace".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })
        // Bind to the replacement feed before reading first-responder or
        // chrome — `.first` can still be a predecessor briefly.
        #expect(owner.terminalFeed !== firstFeed)
        let afterFirst = try #require(await Self.eventuallyTerminal(
            boundTo: owner.terminalFeed, in: controller.view))
        #expect(!firstFeed.isAttached(to: afterFirst))
        try #require(await Self.eventually { afterFirst.isFirstResponder })

        // Terminal Keyboard's dismiss clears the raised intent. A leftover
        // TerminalKeyboardHandoff arm after the first replacement must not
        // resurrect the keyboard on the next pipeline rebuild.
        try #require(await Self.eventually {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
            return interactions.inputChromeMountCount == 1
        })
        try #require(try await Self.activateControl(
            labeled: "Terminal Keyboard",
            in: controller.view,
            probe: { interactions.tapTerminalKeyboard() }))
        try #require(await Self.eventually { !afterFirst.isFirstResponder })
        #expect(!handoff.consume(agent.id))

        let secondID = owner.terminalID
        let secondFeed = owner.terminalFeed
        owner.transportGenerationDidChange(3)
        try #require(await Self.eventually { owner.terminalID != secondID })
        owner.viewDidResize(cols: 80, rows: 24)
        try #require(await Self.eventually {
            await transport.attachRequests.count == 3
        })
        #expect(await transport.emitAttachOutput(Data("second-replace".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        #expect(owner.terminalFeed !== secondFeed)
        let afterSecond = try #require(await Self.eventuallyTerminal(
            boundTo: owner.terminalFeed, in: controller.view))
        #expect(!secondFeed.isAttached(to: afterSecond))
        #expect(afterSecond.isLocalInputEnabled)
        #expect(!afterSecond.isFirstResponder)
        #expect(!handoff.consume(agent.id))

        await owner.leave().value
    }

    @Test func terminalReplacementWhileTerminalKeyboardDownStaysDown() async throws {
        let transport = ScriptedTransport()
        let composer = AgentComposerStore(target: "w1:p1") { _ in
            Agent(.fixture(paneID: "w1:p1"))
        }
        let owner = try await Self.makeLiveAttach(transport: transport, composer: composer)

        let controller = UIHostingController(
            rootView: Self.makeDetailView(
                attachStore: owner,
                composer: composer))
        let window = try await makeTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874),
            rootViewController: controller)
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        let first = try #require(Self.terminals(in: controller.view).first)
        #expect(!first.isFirstResponder)
        let firstID = owner.terminalID

        owner.transportGenerationDidChange(2)
        try #require(await Self.eventually { owner.terminalID != firstID })
        owner.viewDidResize(cols: 80, rows: 24)
        try #require(await Self.eventually {
            await transport.attachRequests.count == 2
        })
        #expect(await transport.emitAttachOutput(Data("still-down".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })

        let replacement = try #require(Self.terminals(in: controller.view).first)
        #expect(replacement.isLocalInputEnabled)
        #expect(!replacement.isFirstResponder)

        await owner.leave().value
    }

    @Test func toolsContextExposesInsertTabsWhenSkillsAreSupported() throws {
        let suiteName = "direct-tabs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults),
            toolbars: AgentToolbarLayoutStore(defaults: defaults, idiom: .phone))
        let skills = TerminalSkillsContext(
            store: SkillsPaneStore(commandPrefixes: ["/"]) { _ in [] })
        let context = TerminalKeysContext(
            settings: settings, skills: skills, manageSnippets: {})
        #expect(context.tabs == [.controls, .skills, .snippets, .appearance])
        let withoutSkills = TerminalKeysContext(settings: settings, manageSnippets: {})
        #expect(withoutSkills.tabs == [.controls, .snippets, .appearance])
    }

    /// What each plain Toolbar key sends to Attach.
    private static let shortcutBytes: [AgentToolbarKeyChord: Data] = [
        AgentToolbarKeyChord(.escape): Data([0x1B]),
        AgentToolbarKeyChord(.tab): Data([0x09]),
        AgentToolbarKeyChord(.shiftTab): Data("\u{1B}[Z".utf8),
        AgentToolbarKeyChord(.up): Data("\u{1B}[A".utf8),
        AgentToolbarKeyChord(.down): Data("\u{1B}[B".utf8),
        AgentToolbarKeyChord(.left): Data("\u{1B}[D".utf8),
        AgentToolbarKeyChord(.right): Data("\u{1B}[C".utf8),
        AgentToolbarKeyChord(.backspace): Data([0x7F]),
        AgentToolbarKeyChord(.shiftEnter): Data([0x0A]),
        AgentToolbarKeyChord(.enter): Data([0x0D]),
    ]

    /// The label the bar's cap speaks for `chord`.
    private static func accessibilityLabel(of chord: AgentToolbarKeyChord) -> String {
        AgentToolbarItemPresentation(.key(chord), customKeys: [], snippets: [])?
            .accessibilityLabel ?? chord.accessibilityLabel
    }

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
        // Fresh stores start `.active` with `.waitingForSize`. `rejoin()` is a
        // no-op until leave/rejoinRequired, so open the channel the same way
        // production does: the first positive size report.
        owner.viewDidResize(cols: 80, rows: 24)
        try #require(await Self.eventually {
            await transport.attachRequests.count == 1
        })
        #expect(await transport.emitAttachOutput(Data("live".utf8)))
        try #require(await Self.eventually {
            owner.terminalStatus == AttachTerminalStore.Status.live
        })
        return owner
    }

    private static func makeDetailView(
        agent: ConsoleAgent? = nil,
        attachStore: AgentAttachStore,
        composer: AgentComposerStore,
        keyboardHandoff: TerminalKeyboardHandoff = TerminalKeyboardHandoff(),
        keyboardInset: TerminalKeyboardInset = TerminalKeyboardInset(),
        interactionProbe: AgentTerminalInteractionProbe? = nil,
        terminalSettings: TerminalSettings? = nil,
        isOnStage: @escaping () -> Bool = { true },
        console: ConsoleStore? = nil
    ) -> some View {
        let defaults = UserDefaults(suiteName: "direct-detail-\(UUID())") ?? .standard
        let console = console ?? makeConsole()
        let terminal = terminalSettings ?? TerminalSettings(
            themes: TerminalThemeSettings(defaults: defaults),
            zoom: TerminalZoomSettings(defaults: defaults),
            fonts: TerminalFontSettings(defaults: defaults),
            snippets: SnippetStore(defaults: defaults),
            toolbars: AgentToolbarLayoutStore(defaults: defaults, idiom: .phone))
        return AgentTerminalView(
            agent: agent ?? makeAgent(status: .idle),
            console: console,
            terminal: terminal,
            hosts: [],
            activity: AppActivityCoordinator(),
            keyboardHandoff: keyboardHandoff,
            keyboardInset: keyboardInset,
            isOnStage: isOnStage,
            onSwitch: { _ in },
            onClosed: {},
            composer: composer,
            attachStore: attachStore,
            interactionProbe: interactionProbe)
    }

    private static func makeConsole() -> ConsoleStore {
        ConsoleStore(snapshotRetryDelay: .seconds(30)) { _, _, subscriptions in
            EventsSession(
                subscriptions: subscriptions,
                connect: { throw TransportError.sshUnreachable(detail: "fixture") },
                reconnectPolicy: .default,
                keepalive: .default)
        }
    }

    private static func makeAgent(status: AgentStatus) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(),
            hostName: "devbox",
            agent: Agent(
                terminalID: "term_w1:p1", kind: "claude", title: "",
                status: status, workspaceID: "w", tabID: "w:t", paneID: "w1:p1",
                cwd: "/work", revision: 1, name: nil),
            workspaceLabel: nil,
            repositoryCheckout: nil)
    }

    private static func terminals(in root: UIView) -> [WaycarTerminalView] {
        var found: [WaycarTerminalView] = []
        func walk(_ view: UIView) {
            if let terminal = view as? WaycarTerminalView {
                found.append(terminal)
            }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
    }

    private static func firstView(
        in root: UIView, matching: (UIView) -> Bool
    ) -> UIView? {
        if matching(root) { return root }
        for subview in root.subviews {
            if let match = firstView(in: subview, matching: matching) {
                return match
            }
        }
        return nil
    }

    /// Message Agent's draft; present only while Message Agent is open.
    private static func composerInput(in root: UIView) -> UITextView? {
        firstView(in: root) {
            $0 is UITextView && $0.accessibilityLabel == "Message the Agent"
        } as? UITextView
    }

    private struct KeyboardChromeSample {
        let insetHeight: CGFloat
        let toolbarBottom: CGFloat?
    }

    @MainActor
    private final class KeyboardTransitionProbe: NSObject {
        // Hosted app tests cannot inspect the out-of-process keyboard surface:
        // its layout guide remains empty even while Simulator renders it. This
        // probe therefore samples the app-owned chrome on every display frame;
        // Simulator acceptance separately verifies the keyboard surface itself.
        private let notificationCenter: NotificationCenter
        private var token: NSObjectProtocol?
        private var showToken: NSObjectProtocol?
        private var changeFrameToken: NSObjectProtocol?
        private var displayLink: CADisplayLink?
        private var samplingStartedAt: CFTimeInterval?
        private let insetHeight: @MainActor () -> CGFloat
        private var chromeSample: (@MainActor () -> KeyboardChromeSample)?
        private(set) var willShowCount = 0
        private(set) var willHideCount = 0
        private(set) var willChangeFrameCount = 0
        private(set) var observedInsetHeights: [CGFloat] = []
        private(set) var chromeSamples: [KeyboardChromeSample] = []

        init(
            notificationCenter: NotificationCenter,
            insetHeight: @escaping @MainActor () -> CGFloat
        ) {
            self.notificationCenter = notificationCenter
            self.insetHeight = insetHeight
            super.init()
            showToken = notificationCenter.addObserver(
                forName: UIResponder.keyboardWillShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.willShowCount += 1
                    self?.recordInsetHeight()
                }
            }
            token = notificationCenter.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.willHideCount += 1
                    self?.recordInsetHeight()
                }
            }
            changeFrameToken = notificationCenter.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.willChangeFrameCount += 1
                    self?.recordInsetHeight()
                }
            }
        }

        func reset() {
            stopSampling()
            willShowCount = 0
            willHideCount = 0
            willChangeFrameCount = 0
            observedInsetHeights = []
            chromeSamples = []
            captureChromeSample()
            let displayLink = CADisplayLink(target: self, selector: #selector(sampleDisplayFrame))
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
            samplingStartedAt = CACurrentMediaTime()
        }

        func setChromeSample(_ sample: @escaping @MainActor () -> KeyboardChromeSample) {
            chromeSample = sample
        }

        func captureChromeSample() {
            if let chromeSample {
                chromeSamples.append(chromeSample())
            }
        }

        @objc private func sampleDisplayFrame() {
            captureChromeSample()
        }

        func hasStableTail(frameCount: Int = 4) -> Bool {
            guard chromeSamples.count >= frameCount,
                  let baseline = chromeSamples.last,
                  baseline.toolbarBottom != nil
            else { return false }
            return chromeSamples.suffix(frameCount).allSatisfy { sample in
                abs(sample.insetHeight - baseline.insetHeight) <= 1
                    && Self.close(sample.toolbarBottom, baseline.toolbarBottom)
            }
        }

        func observedHandoffWindow(_ duration: TimeInterval = 0.65) -> Bool {
            guard let samplingStartedAt else { return false }
            return CACurrentMediaTime() - samplingStartedAt >= duration
        }

        private static func close(_ lhs: CGFloat?, _ rhs: CGFloat?) -> Bool {
            guard let lhs, let rhs else { return lhs == nil && rhs == nil }
            return abs(lhs - rhs) <= 1
        }

        func stopSampling() {
            displayLink?.invalidate()
            displayLink = nil
            samplingStartedAt = nil
        }

        private func recordInsetHeight() {
            observedInsetHeights.append(insetHeight())
            captureChromeSample()
        }

        func stop() {
            stopSampling()
            if let showToken {
                notificationCenter.removeObserver(showToken)
            }
            if let token {
                notificationCenter.removeObserver(token)
            }
            if let changeFrameToken {
                notificationCenter.removeObserver(changeFrameToken)
            }
            showToken = nil
            self.token = nil
            changeFrameToken = nil
        }
    }

    @MainActor
    private static func keyboardChromeSample(
        in root: UIView,
        window: UIWindow,
        inset: TerminalKeyboardInset
    ) -> KeyboardChromeSample {
        // The default Toolbar's Paste key is its one UIKit-backed view, so its
        // presentation frame tracks the bar's on-screen position.
        let pasteKey = toolbarPasteKeys(in: root)
            .filter { $0.window === window }
            .max { effectivePresentationOpacity(of: $0) < effectivePresentationOpacity(of: $1) }
        let bottom = pasteKey.flatMap { pasteKey -> CGFloat? in
            guard pasteKey.window === window, let superview = pasteKey.superview else { return nil }
            let frame = pasteKey.layer.presentation()?.frame ?? pasteKey.frame
            return superview.convert(frame, to: window).maxY
        }
        return KeyboardChromeSample(
            insetHeight: inset.height,
            toolbarBottom: bottom)
    }

    private static func toolbarPasteKeys(in root: UIView) -> [KeyCapPasteView] {
        var result: [KeyCapPasteView] = []
        if let pasteKey = root as? KeyCapPasteView {
            result.append(pasteKey)
        }
        for subview in root.subviews {
            result.append(contentsOf: toolbarPasteKeys(in: subview))
        }
        return result
    }

    private static func effectivePresentationOpacity(of view: UIView) -> Float {
        var opacity: Float = 1
        var current: UIView? = view
        while let node = current {
            if node.isHidden { return 0 }
            opacity *= node.layer.presentation()?.opacity ?? node.layer.opacity
            current = node.superview
        }
        return opacity
    }

    private static func expectStableKeyboardChrome(
        _ samples: [KeyboardChromeSample],
        keyboardHeight: CGFloat,
        direction: String
    ) {
        #expect(!samples.isEmpty, "\(direction) produced no display-frame samples")
        #expect(
            samples.allSatisfy { abs($0.insetHeight - keyboardHeight) <= 1 },
            "\(direction) moved the keyboard inset during a UIKit transition")
        let bottoms = samples.compactMap(\.toolbarBottom)
        #expect(
            bottoms.count == samples.count,
            "\(direction) removed the Toolbar during a UIKit transition")
        guard let baseline = bottoms.first else { return }
        #expect(
            bottoms.allSatisfy { abs($0 - baseline) <= 1 },
            "\(direction) moved the Toolbar during a UIKit transition: \(bottoms)")
    }

    /// Waits for the hosted terminal attached to the owner's current feed —
    /// the binding seam when UIView object identity may be reused and Ghostty
    /// viewport text is not a reliable harness signal.
    private static func eventuallyTerminal(
        boundTo feed: TerminalByteFeed,
        in root: UIView,
        timeout: Duration = .waitCeiling
    ) async throws -> WaycarTerminalView? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            root.setNeedsLayout()
            root.layoutIfNeeded()
            if let terminal = terminals(in: root).first(where: { feed.isAttached(to: $0) }) {
                return terminal
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        root.setNeedsLayout()
        root.layoutIfNeeded()
        return terminals(in: root).first(where: { feed.isAttached(to: $0) })
    }

    private static func firstAccessible(labeled label: String, in root: UIView) -> NSObject? {
        firstAccessible(in: root) { $0.accessibilityLabel == label }
    }

    private static func activateControl(
        labeled label: String,
        in root: UIView,
        probe: () -> Bool
    ) async throws -> Bool {
        guard #available(iOS 27, *) else { return probe() }
        guard let element = try await waitForAccessible(labeled: label, in: root) else {
            return false
        }
        if let backspace = element as? TerminalRepeatingBackspaceButton {
            return backspace.accessibilityActivate()
        }
        if let control = element as? UIControl {
            control.sendActions(for: .touchUpInside)
            return true
        }
        return element.accessibilityActivate()
    }

    private static func waitForAccessible(
        labeled label: String,
        in root: UIView
    ) async throws -> NSObject? {
        let deadline = ContinuousClock.now + .waitCeiling
        while ContinuousClock.now < deadline {
            root.layoutIfNeeded()
            if let element = firstAccessible(labeled: label, in: root) {
                return element
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private static func firstAccessibleFrame(labeled label: String, in root: UIView) -> CGRect? {
        // Reuse visitAccessible so frame probes share the same container walk as
        // label lookups. Skip zero-size matches and keep searching — same rule
        // TerminalAttachTests uses for hosted SwiftUI chrome.
        var match: CGRect?
        visitAccessible(in: root) { node in
            guard match == nil, node.accessibilityLabel == label else { return }
            if let view = node as? UIView {
                guard view.bounds.width > 0, view.bounds.height > 0 else { return }
                match = view.convert(view.bounds, to: root)
            } else {
                let frame = node.accessibilityFrame
                guard frame.width > 0, frame.height > 0 else { return }
                match = root.convert(frame, from: nil)
            }
        }
        return match
    }

    private static func accessibleCount(labeled label: String, in root: UIView) -> Int {
        var count = 0
        visitAccessible(in: root) { node in
            if node.accessibilityLabel == label {
                count += 1
            }
        }
        return count
    }

    private static func firstAccessible(
        in root: UIView, matching: (NSObject) -> Bool
    ) -> NSObject? {
        var match: NSObject?
        visitAccessible(in: root) { node in
            guard match == nil, matching(node) else { return }
            match = node
        }
        return match
    }

    private static func visitAccessible(
        in root: UIView, body: (NSObject) -> Void
    ) {
        var visited = Set<ObjectIdentifier>()

        func visit(_ node: NSObject) {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return }
            body(node)
            if let elements = node.accessibilityElements {
                for element in elements {
                    if let object = element as? NSObject {
                        visit(object)
                    }
                }
            }
            // SwiftUI containers can expose an empty or incomplete array while
            // their indexed accessibility API still owns the live controls.
            let count = node.accessibilityElementCount()
            if count > 0, count != NSNotFound {
                for index in 0..<count {
                    if let object = node.accessibilityElement(at: index) as? NSObject {
                        visit(object)
                    }
                }
            }
            if let view = node as? UIView {
                for subview in view.subviews {
                    visit(subview)
                }
            }
        }
        visit(root)
    }

    private static func makeLocalTestWindow(
        frame: CGRect,
        rootViewController: UIViewController
    ) -> UIWindow {
        let window = UIWindow(frame: frame)
        window.rootViewController = rootViewController
        window.makeKeyAndVisible()
        return window
    }

    private static func eventually(
        timeout: Duration = .waitCeiling,
        _ condition: @escaping () async -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private final class IndexedAccessibilityContainerView: UIView {
    private let indexedLabel: String
    private let arrayLabel: String?
    private let includesIndexedElementInArray: Bool
    private lazy var indexedElement: UIAccessibilityElement = {
        let element = UIAccessibilityElement(accessibilityContainer: self)
        element.accessibilityLabel = indexedLabel
        return element
    }()
    private lazy var arrayElement: UIAccessibilityElement = {
        let element = UIAccessibilityElement(accessibilityContainer: self)
        element.accessibilityLabel = arrayLabel
        return element
    }()

    init(
        indexedLabel: String,
        arrayLabel: String? = nil,
        includesIndexedElementInArray: Bool = false
    ) {
        self.indexedLabel = indexedLabel
        self.arrayLabel = arrayLabel
        self.includesIndexedElementInArray = includesIndexedElementInArray
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var accessibilityElements: [Any]? {
        get {
            if includesIndexedElementInArray {
                return [indexedElement]
            }
            return arrayLabel == nil ? [] : [arrayElement]
        }
        set { }
    }

    override func accessibilityElementCount() -> Int { 1 }

    override func accessibilityElement(at index: Int) -> Any? {
        index == 0 ? indexedElement : nil
    }
}

/// What the iPad slide-over hands its Agent, settable mid-test.
@MainActor
@Observable
private final class SlideOverEnvironment {
    var isCovered = false
    var focusTaps = 0
}

private struct SlideOverEnvironmentHost<Content: View>: View {
    let environment: SlideOverEnvironment
    let content: Content

    var body: some View {
        content
            .environment(\.consoleDetailIsCovered, environment.isCovered)
            .environment(\.consoleDetailFocusTaps, environment.focusTaps)
    }
}
