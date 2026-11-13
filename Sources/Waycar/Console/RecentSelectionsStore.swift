import Foundation

/// The Host and the "Agent" picker selection the user last launched (#12),
/// whether their last New Worktree launch started from the latest main, and
/// whether the Markdown File Preview last showed its raw text (#147).
///
/// The new-agent sheet pre-selects these, so opening it again needs no
/// re-picking. Unlike `RecentWorkspaceStore`, these are global rather than
/// per-Host: a Host ID is only valid against the current Host list, which
/// the sheet already filters against, and kind availability is per-Host by
/// nature.
struct RecentSelectionsStore {
    private static let hostKey = "recent-agent-host"
    private static let kindKey = "recent-agent-kind"
    private static let shellSelectionKey = "recent-agent-selection-shell"
    private static let latestMainKey = "recent-worktree-starts-from-latest-main"
    private static let chatModeKey = "recent-agent-chat-mode"
    private static let chatDestinationKey = "recent-chat-destination"
    private static let chatKindKey = "recent-chat-kind"
    private static let markdownPreviewShowsRawKey = "recent-markdown-preview-shows-raw"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var lastHostID: Host.ID? {
        guard let uuidString = defaults.string(forKey: Self.hostKey) else { return nil }
        return UUID(uuidString: uuidString)
    }

    var lastAgentKind: SupportedAgentKind? {
        defaults.string(forKey: Self.kindKey).flatMap(SupportedAgentKind.init(rawValue:))
    }

    /// The launch selection the user last dispatched: the remembered kind
    /// above preselects only when the shell was not the most recent choice.
    var lastSelectionWasShell: Bool {
        defaults.bool(forKey: Self.shellSelectionKey)
    }

    /// Whether a New Worktree launch starts from origin's latest default
    /// branch. On until a launch with it turned off says otherwise.
    var startsFromLatestMain: Bool {
        defaults.object(forKey: Self.latestMainKey) as? Bool ?? true
    }

    /// Whether the last Chat-Mode-capable Agent launched in Chat Mode. Off
    /// until a launch with it turned on says otherwise.
    var chatMode: Bool {
        defaults.bool(forKey: Self.chatModeKey)
    }

    /// Where the last Chat Mode Agent started: New Chat's Last Used.
    var lastChatDestination: ChatDestination? {
        ChatDestination.decoded(from: defaults.data(forKey: Self.chatDestinationKey))
    }

    /// The kind of the last Chat Mode Agent: New Chat's Last Used.
    var lastChatKind: SupportedAgentKind? {
        defaults.string(forKey: Self.chatKindKey).flatMap(SupportedAgentKind.init(rawValue:))
    }

    /// Whether a Markdown File Preview opens on its raw text rather than the
    /// rendered document. Rendered until a flip to raw says otherwise.
    var markdownPreviewShowsRaw: Bool {
        defaults.bool(forKey: Self.markdownPreviewShowsRawKey)
    }

    func remember(hostID: Host.ID, kind: SupportedAgentKind) {
        defaults.set(hostID.uuidString, forKey: Self.hostKey)
        defaults.set(kind.rawValue, forKey: Self.kindKey)
        defaults.set(false, forKey: Self.shellSelectionKey)
    }

    func rememberShell(hostID: Host.ID) {
        defaults.set(hostID.uuidString, forKey: Self.hostKey)
        defaults.set(true, forKey: Self.shellSelectionKey)
    }

    func rememberStartsFromLatestMain(_ startsFromLatestMain: Bool) {
        defaults.set(startsFromLatestMain, forKey: Self.latestMainKey)
    }

    func rememberChatMode(_ chatMode: Bool) {
        defaults.set(chatMode, forKey: Self.chatModeKey)
    }

    func rememberChat(destination: ChatDestination, kind: SupportedAgentKind) {
        if let data = destination.encoded {
            defaults.set(data, forKey: Self.chatDestinationKey)
        }
        defaults.set(kind.rawValue, forKey: Self.chatKindKey)
    }

    func rememberMarkdownPreviewShowsRaw(_ showsRaw: Bool) {
        defaults.set(showsRaw, forKey: Self.markdownPreviewShowsRawKey)
    }
}
