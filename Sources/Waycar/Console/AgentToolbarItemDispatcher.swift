import Foundation

/// Runs a Toolbar item through the owner that already does that job, so the
/// Toolbar never grows a delivery path of its own (ADR 0024):
///
/// - A plain Key goes where the tools keyboard's keys go: armed modifiers
///   apply, and Esc keeps its byte-exact fast path when nothing is armed. A
///   Combo sends exactly its chord and drops armed modifiers. Keys always
///   reach Attach, whether or not Message Agent is open.
/// - A sticky modifier chip arms the one-shot modifier for the next Key.
/// - Menu-backed actions run as their More-menu entry would; with Message
///   Agent closed, draft-owned ones open it first (ADR 0016).
/// - Tools Keyboard raises or swaps the terminal's tools keyboard.
/// - Text a Paste, Snippet or text Custom Key authors goes into the draft
///   while Message Agent is open and into Attach, without Enter, otherwise
///   (Paste through Attach's paste review). A text Custom Key with Enter goes
///   through Send's delivery owner as its own message, leaving the draft
///   alone. A Custom Key's key steps are sent in order like Combos.
/// - More is drawn by the Toolbar as a menu; tapping it never reaches here.
@MainActor
struct AgentToolbarItemDispatcher {
    /// The owners items are routed to, supplied by Agent detail.
    struct Routes {
        /// A plain Key: honors armed modifiers.
        let sendQuickKey: (AgentQuickKey) -> Void
        /// The exact chord; clears armed modifiers first.
        let sendChord: (AgentQuickKey, TerminalKeyModifiers) -> Void
        let toggleModifier: (TerminalKeyModifiers) -> Void
        /// Attach's paste review.
        let pasteIntoAttach: (String) -> Void
        /// Types text into Attach without Enter, as tools-keyboard Snippets do.
        let insertIntoAttach: (String) -> Void
        let insertIntoDraft: (String) -> Void
        /// Send's delivery owner for `text` as its own message; the draft is
        /// left alone. Blocked inserts without Enter; a pending launch is
        /// waited out.
        let submitText: (String) -> Void
        /// Opens Message Agent (keyboard down), then runs the action.
        let openMessageAgentThen: (@escaping () -> Void) -> Void
        /// The terminal's tools keyboard: raised, or swapped with the system
        /// keyboard when a keyboard is already up.
        let toggleToolsKeyboard: () -> Void
        let readPasteboard: () -> String?
    }

    /// Whether Message Agent (the Composer card) is open: authored text goes
    /// to its draft instead of Attach.
    let isMessageAgentOpen: Bool
    let actions: AgentComposerActions
    let snippets: [Snippet]
    let customKeys: [CustomKey]
    let routes: Routes

    func perform(_ content: AgentToolbarItem.Content) {
        guard actions.paneActionsAvailable || content.isTerminalOnlyControl else { return }
        switch content {
        case .key(let chord):
            if chord.isCombo {
                routes.sendChord(chord.key, chord.modifiers)
            } else {
                routes.sendQuickKey(chord.key)
            }
        case .modifier(let modifiers):
            routes.toggleModifier(modifiers)
        case .action(let action):
            perform(action)
        case .snippet(let id):
            guard let snippet = snippets.first(where: { $0.id == id }) else { return }
            insert(snippet.body)
        case .customKey(let id):
            guard let key = customKeys.first(where: { $0.id == id }) else { return }
            switch key.steps {
            case .keys(let chords):
                for chord in chords {
                    routes.sendChord(chord.key, chord.modifiers)
                }
            case .text(let text, let pressEnter):
                if pressEnter {
                    routes.submitText(text)
                } else {
                    insert(text)
                }
            }
        }
    }

    private func perform(_ action: AgentToolbarAction) {
        switch action {
        case .paste:
            guard let text = routes.readPasteboard(), !text.isEmpty else { return }
            if isMessageAgentOpen {
                routes.insertIntoDraft(text)
            } else {
                routes.pasteIntoAttach(text)
            }
        case .toolsKeyboard:
            routes.toggleToolsKeyboard()
        case .addImage, .addFile, .openTerminal, .newAgent, .skills, .snippets,
            .worktreeDetails, .renameAgent, .renameWorkspace:
            guard let item = action.menuItem,
                AgentActionMenuPolicy.isVisible(item, actions: actions),
                AgentActionMenuPolicy.isEnabled(.action(action), actions: actions)
            else { return }
            AgentActionMenuPolicy.dispatch(
                item,
                actions: actions,
                restoreComposerThen: isMessageAgentOpen ? nil : routes.openMessageAgentThen)
        case .moreMenu:
            break
        }
    }

    private func insert(_ text: String) {
        if isMessageAgentOpen {
            routes.insertIntoDraft(text)
        } else {
            routes.insertIntoAttach(text)
        }
    }
}

extension AgentToolbarAvailability {
    /// What the Toolbar can run for this Agent view. The hidden rules reuse
    /// the More menu's (`AgentActionMenuPolicy.isVisible`).
    init(
        actions: AgentComposerActions,
        snippets: [Snippet],
        customKeys: [CustomKey]
    ) {
        self.init(
            skillsAvailable: AgentActionMenuPolicy.isVisible(.skills, actions: actions),
            worktreeDetailsAvailable: AgentActionMenuPolicy.isVisible(
                .worktreeDetails, actions: actions),
            snippetIDs: Set(snippets.map(\.id)),
            customKeyIDs: Set(customKeys.map(\.id)),
            paneActionsAvailable: actions.paneActionsAvailable)
    }
}
