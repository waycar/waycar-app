import SwiftUI

/// Shared Agent action-menu items for the Composer and the Toolbar. Ordering
/// and sectioning stay identical across both surfaces; with Message Agent
/// closed, the Toolbar only adds an open-Message-Agent hop for draft-owned
/// actions.
enum AgentActionMenuItem: Equatable, Hashable, Sendable, CaseIterable {
    case addImage
    case addFile
    case openTerminal
    case newAgent
    case skills
    case snippets
    case worktreeDetails
    case renameAgent
    case renameWorkspace
    case markUnread
    case closeAgent

    var title: String {
        switch self {
        case .addImage: "Add Image"
        case .addFile: "Add File"
        case .openTerminal: "Open Terminal"
        case .newAgent: "New Agent"
        case .skills: "Skills"
        case .snippets: "Snippets"
        case .worktreeDetails: "Worktree Details"
        case .renameAgent: "Rename Agent"
        case .renameWorkspace: "Rename Workspace"
        case .markUnread: "Mark as Unread"
        case .closeAgent: "Close Agent"
        }
    }

    var systemImage: String {
        switch self {
        case .addImage: "photo"
        case .addFile: "doc"
        case .openTerminal: "apple.terminal"
        case .newAgent: "plus"
        case .skills: "sparkles"
        case .snippets: "quote.bubble"
        case .worktreeDetails: "arrow.triangle.branch"
        case .renameAgent: "pencil"
        case .renameWorkspace: "pencil.line"
        case .markUnread: "envelope.badge"
        case .closeAgent: "trash"
        }
    }

    var role: ButtonRole? {
        switch self {
        case .closeAgent: .destructive
        default: nil
        }
    }

    /// Draft-owned: Skills, Snippets, and Add touch the Composer draft, so
    /// the Toolbar opens Message Agent before running them.
    var isDraftOwned: Bool {
        switch self {
        case .addImage, .addFile, .skills, .snippets:
            true
        case .openTerminal, .newAgent, .worktreeDetails, .renameAgent,
            .renameWorkspace, .markUnread, .closeAgent:
            false
        }
    }
}

enum AgentActionMenuSection: Equatable, Hashable, Sendable, CaseIterable {
    /// Attachments for the draft.
    case addAttachments
    /// Session tools — Skills before Snippets matches the Keys keyboard tab order.
    case sessionTools
    /// Rename / mark unread / close / worktree lifecycle.
    case agentLifecycle

    var items: [AgentActionMenuItem] {
        switch self {
        case .addAttachments:
            [.addImage, .addFile]
        case .sessionTools:
            [.openTerminal, .newAgent, .skills, .snippets]
        case .agentLifecycle:
            [.worktreeDetails, .renameAgent, .renameWorkspace, .markUnread, .closeAgent]
        }
    }
}

/// Availability and visibility rules shared by the Composer's Add/More and
/// the Toolbar's More menu.
enum AgentActionMenuPolicy {
    static let composerAddSections: [AgentActionMenuSection] = [.addAttachments]
    static let composerMoreSections: [AgentActionMenuSection] = [
        .sessionTools, .agentLifecycle,
    ]
    /// The Toolbar's More: everything, Add Image / Add File included.
    static let toolbarMoreSections: [AgentActionMenuSection] = [
        .addAttachments, .sessionTools, .agentLifecycle,
    ]

    /// Optional entries hide entirely when their action is absent: Mark as
    /// Unread is absent unless the Agent can be marked.
    static func isVisible(
        _ item: AgentActionMenuItem,
        actions: AgentComposerActions
    ) -> Bool {
        guard actions.paneActionsAvailable else { return false }
        return switch item {
        case .renameWorkspace:
            actions.canRenameWorkspace
        case .skills:
            actions.showSkills != nil
        case .worktreeDetails:
            actions.showWorktreeDetails != nil
        case .markUnread:
            actions.markUnread != nil
        default:
            true
        }
    }

    /// The item's title: Close Agent reads Archive for a session its server
    /// archives instead.
    static func title(_ item: AgentActionMenuItem, actions: AgentComposerActions) -> String {
        item == .closeAgent && actions.archivesAgent ? "Archive" : item.title
    }

    static func systemImage(_ item: AgentActionMenuItem, actions: AgentComposerActions) -> String {
        item == .closeAgent && actions.archivesAgent ? "archivebox" : item.systemImage
    }

    static func role(_ item: AgentActionMenuItem, actions: AgentComposerActions) -> ButtonRole? {
        item == .closeAgent && actions.archivesAgent ? nil : item.role
    }

    static func isEnabled(
        _ item: AgentActionMenuItem,
        actions: AgentComposerActions
    ) -> Bool {
        switch item {
        case .addImage, .addFile:
            actions.canAdd
        case .renameWorkspace:
            actions.canRenameWorkspace
        case .openTerminal:
            actions.openTerminal != nil && !actions.isOpeningTerminal
        default:
            true
        }
    }

    /// Whether a toolbar item can run now. Only menu-backed actions can be
    /// unavailable; keys, Custom Keys, Snippets and other actions always run.
    static func isEnabled(
        _ content: AgentToolbarItem.Content,
        actions: AgentComposerActions
    ) -> Bool {
        guard case .action(let action) = content, let menuItem = action.menuItem else {
            return true
        }
        return isEnabled(menuItem, actions: actions)
    }

    /// Whether a Toolbar item is a Key press for the Attach's PTY, which
    /// does nothing while the terminal has no attach. Text items stay
    /// enabled: they can land in the draft, and Send never rides the attach.
    static func writesToAttach(_ content: AgentToolbarItem.Content) -> Bool {
        switch content {
        case .key, .modifier: true
        case .action, .snippet, .customKey: false
        }
    }

    static func perform(
        _ item: AgentActionMenuItem,
        actions: AgentComposerActions
    ) {
        switch item {
        case .addImage:
            actions.addImage()
        case .addFile:
            actions.addFile()
        case .openTerminal:
            actions.openTerminal?()
        case .newAgent:
            actions.startAgent()
        case .skills:
            actions.showSkills?()
        case .snippets:
            actions.manageSnippets()
        case .worktreeDetails:
            actions.showWorktreeDetails?()
        case .renameAgent:
            actions.renameAgent()
        case .renameWorkspace:
            actions.renameWorkspace()
        case .markUnread:
            actions.markUnread?()
        case .closeAgent:
            actions.closeAgent()
        }
    }

    /// Production dispatch for menu taps. With Message Agent closed, the
    /// Toolbar supplies `restoreComposerThen` so draft-owned actions open it
    /// first.
    static func dispatch(
        _ item: AgentActionMenuItem,
        actions: AgentComposerActions,
        restoreComposerThen: ((@escaping () -> Void) -> Void)? = nil
    ) {
        let action = { perform(item, actions: actions) }
        if item.isDraftOwned, let restoreComposerThen {
            restoreComposerThen(action)
        } else {
            action()
        }
    }
}

/// One menu body for the Composer's Add and More and the Toolbar's More.
struct AgentActionMenuContent: View {
    let actions: AgentComposerActions
    let sections: [AgentActionMenuSection]
    /// When set, draft-owned items open Message Agent before running.
    var restoreComposerThen: ((@escaping () -> Void) -> Void)? = nil

    var body: some View {
        ForEach(sections, id: \.self) { section in
            let visible = section.items.filter {
                AgentActionMenuPolicy.isVisible($0, actions: actions)
            }
            if !visible.isEmpty {
                Section {
                    ForEach(visible, id: \.self) { item in
                        button(for: item)
                    }
                }
            }
        }
        .tint(Brand.Colors.quietAction)
    }

    private func button(for item: AgentActionMenuItem) -> some View {
        Button(role: AgentActionMenuPolicy.role(item, actions: actions)) {
            AgentActionMenuPolicy.dispatch(
                item,
                actions: actions,
                restoreComposerThen: restoreComposerThen)
        } label: {
            Label {
                Text(AgentActionMenuPolicy.title(item, actions: actions))
                if let subtitle = disabledReason(for: item) {
                    Text(subtitle)
                }
            } icon: {
                Image(systemName: AgentActionMenuPolicy.systemImage(item, actions: actions))
            }
        }
        .disabled(!AgentActionMenuPolicy.isEnabled(item, actions: actions))
    }

    /// Menu subtitle saying why an item is unavailable; a full Composer Tray
    /// is the only reason worth spelling out.
    private func disabledReason(for item: AgentActionMenuItem) -> String? {
        switch item {
        case .addImage, .addFile:
            actions.canAdd ? nil : "\(ComposerTray.capacity) per message"
        default:
            nil
        }
    }
}
