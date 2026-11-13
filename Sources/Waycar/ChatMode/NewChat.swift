import Foundation

/// Where a New Chat starts (`CONTEXT.md` "New Chat"): a Host and, within it,
/// a workspace by id and label, with the directory to recreate it from when
/// neither is live any more.
struct ChatDestination: Codable, Equatable, Sendable {
    let hostID: Host.ID
    let workspaceID: String?
    let workspaceLabel: String?
    /// An absolute path, or nil.
    let cwd: String?

    /// Decodes `data`; anything unreadable reads as nil.
    static func decoded(from data: Data?) -> ChatDestination? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(ChatDestination.self, from: data)
    }

    var encoded: Data? { try? JSONEncoder().encode(self) }
}

/// The New Chat quick action's inputs: Settings › Chat Mode's New Chat
/// defaults and this device's Last Used values.
struct NewChatPreferences: Equatable, Sendable {
    /// Fixed in Settings; nil means Last Used.
    var destination: ChatDestination?
    /// Fixed in Settings; nil means Last Used.
    var kind: SupportedAgentKind?
    /// `RecentSelectionsStore.lastChatDestination`.
    var lastDestination: ChatDestination?
    /// `RecentSelectionsStore.lastChatKind`.
    var lastChatKind: SupportedAgentKind?
    /// `RecentSelectionsStore.lastAgentKind`: the last New Agent kind.
    var lastAgentKind: SupportedAgentKind?

    /// Reads the Settings keys (ChatModeSettings) and the per-device recents
    /// (RecentSelectionsStore) from `defaults`.
    static func current(defaults: UserDefaults = .standard) -> NewChatPreferences {
        let recents = RecentSelectionsStore(defaults: defaults)
        return NewChatPreferences(
            destination: ChatModeSettings.storedNewChatDestination(in: defaults),
            kind: ChatModeSettings.storedNewChatKind(in: defaults),
            lastDestination: recents.lastChatDestination,
            lastChatKind: recents.lastChatKind,
            lastAgentKind: recents.lastAgentKind)
    }
}

/// A resolved New Chat: what to launch, and where.
struct NewChatPlan: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case existingWorkspace(id: String)
        case newWorkspace(directory: String, label: String?)
    }

    let hostID: Host.ID
    let target: Target
    let kind: SupportedAgentKind
}

enum NewChatResolver {
    /// The first of the Settings destination and the Last Used one whose Host
    /// is in `knownHosts`, the enabled Hosts. A Settings destination whose
    /// Host was removed or disabled therefore reads as Last Used, which is
    /// what Settings shows.
    static func destination(_ p: NewChatPreferences, knownHosts: Set<Host.ID>) -> ChatDestination? {
        [p.destination, p.lastDestination]
            .lazy
            .compactMap { $0 }
            .first { knownHosts.contains($0.hostID) }
    }

    /// p.kind ?? p.lastChatKind ?? (p.lastAgentKind if it supportsChatMode);
    /// only kinds with supportsChatMode.
    static func kind(_ p: NewChatPreferences) -> SupportedAgentKind? {
        [p.kind, p.lastChatKind, p.lastAgentKind]
            .lazy
            .compactMap { $0 }
            .first(where: \.supportsChatMode)
    }

    /// `workspaces` is the LIVE list for the destination's Host; callers must
    /// call only once that list is current.
    static func plan(
        preferences: NewChatPreferences, knownHosts: Set<Host.ID>,
        workspaces: [ConsoleWorkspace]
    ) -> NewChatPlan? {
        guard let destination = destination(preferences, knownHosts: knownHosts),
            let kind = kind(preferences)
        else { return nil }
        let target: NewChatPlan.Target?
        if destination.workspaceID == nil, destination.workspaceLabel == nil, destination.cwd == nil {
            // Only a Host: its Last Used workspace when that resolves, else
            // its first live workspace.
            let lastUsed = preferences.lastDestination.flatMap { last in
                last.hostID == destination.hostID ? workspaceTarget(last, in: workspaces) : nil
            }
            target = lastUsed ?? workspaces.first.map { NewChatPlan.Target.existingWorkspace(id: $0.id) }
        } else {
            target = workspaceTarget(destination, in: workspaces)
        }
        return target.map { NewChatPlan(hostID: destination.hostID, target: $0, kind: kind) }
    }

    /// The live workspace `destination` names, by id and then by a unique
    /// label, else a new workspace in its absolute `cwd`; nil when none applies.
    private static func workspaceTarget(
        _ destination: ChatDestination, in workspaces: [ConsoleWorkspace]
    ) -> NewChatPlan.Target? {
        if let id = destination.workspaceID, workspaces.contains(where: { $0.id == id }) {
            return .existingWorkspace(id: id)
        }
        if let label = destination.workspaceLabel, !label.isEmpty {
            let matches = workspaces.filter { $0.label == label }
            if matches.count == 1, let match = matches.first {
                return .existingWorkspace(id: match.id)
            }
        }
        if let cwd = destination.cwd, cwd.hasPrefix("/") {
            return .newWorkspace(directory: cwd, label: destination.workspaceLabel)
        }
        return nil
    }
}
