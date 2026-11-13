import Foundation
import Testing

@testable import Waycar

@Suite("New Chat resolver")
struct NewChatResolverTests {
    private let host = UUID()

    private func destination(
        id: String? = nil, label: String? = nil, cwd: String? = nil, host: Host.ID? = nil
    ) -> ChatDestination {
        ChatDestination(hostID: host ?? self.host, workspaceID: id, workspaceLabel: label, cwd: cwd)
    }

    private func plan(
        _ destination: ChatDestination?, kind: SupportedAgentKind? = .claude,
        workspaces: [ConsoleWorkspace] = []
    ) -> NewChatPlan? {
        // Settings value: destination and kind fixed in Settings.
        NewChatResolver.plan(
            preferences: NewChatPreferences(destination: destination, kind: kind),
            knownHosts: [host], workspaces: workspaces)
    }

    @Test func noDestinationOrKindIsNil() {
        #expect(plan(nil) == nil)
        #expect(plan(destination(id: "w1"), kind: nil, workspaces: [.init(id: "w1", label: "a")]) == nil)
    }

    @Test func unknownHostIsNil() {
        let other = destination(id: "w1", cwd: "/src", host: UUID())
        #expect(plan(other, workspaces: [.init(id: "w1", label: "a")]) == nil)
    }

    @Test func liveIDBeatsLabel() {
        let result = plan(
            destination(id: "w1", label: "b", cwd: "/src"),
            workspaces: [.init(id: "w1", label: "a"), .init(id: "w2", label: "b")])
        #expect(result == NewChatPlan(hostID: host, target: .existingWorkspace(id: "w1"), kind: .claude))
    }

    @Test func uniqueLabelMatchesWhenIDIsGone() {
        let result = plan(
            destination(id: "gone", label: "b", cwd: "/src"),
            workspaces: [.init(id: "w1", label: "a"), .init(id: "w2", label: "b")])
        #expect(result?.target == .existingWorkspace(id: "w2"))
    }

    @Test func duplicateLabelFallsToCwd() {
        let workspaces: [ConsoleWorkspace] = [.init(id: "w1", label: "b"), .init(id: "w2", label: "b")]
        #expect(
            plan(destination(label: "b", cwd: "/src/b"), workspaces: workspaces)?.target
                == .newWorkspace(directory: "/src/b", label: "b"))
        #expect(plan(destination(label: "b"), workspaces: workspaces) == nil)
    }

    @Test func emptyLabelNeverMatches() {
        #expect(plan(destination(label: ""), workspaces: [.init(id: "w1", label: "")]) == nil)
    }

    @Test func absoluteCwdStartsANewWorkspace() {
        #expect(
            plan(destination(cwd: "/src/app"))
                == NewChatPlan(hostID: host, target: .newWorkspace(directory: "/src/app", label: nil), kind: .claude))
    }

    @Test(arguments: ["src/app", "~/app", ""])
    func relativeCwdIsNil(_ cwd: String) {
        #expect(plan(destination(cwd: cwd)) == nil)
    }

    @Test func lastUsedDestinationAppliesWhenSettingsIsLastUsed() {
        // Settings value: destination Last Used (nil).
        let preferences = NewChatPreferences(kind: .codex, lastDestination: destination(id: "w1"))
        #expect(
            NewChatResolver.plan(
                preferences: preferences, knownHosts: [host], workspaces: [.init(id: "w1", label: "a")])
                == NewChatPlan(hostID: host, target: .existingWorkspace(id: "w1"), kind: .codex))
    }

    @Test func settingsDestinationBeatsLastUsed() {
        let fixed = destination(id: "fixed")
        let preferences = NewChatPreferences(destination: fixed, lastDestination: destination(id: "last"))
        #expect(NewChatResolver.destination(preferences, knownHosts: [host]) == fixed)
    }

    /// Settings shows a removed Host as Last Used, so New Chat follows Last Used.
    @Test func removedSettingsHostFallsBackToLastUsed() {
        let last = destination(id: "w1")
        let preferences = NewChatPreferences(
            destination: destination(id: "w9", cwd: "/src/gone", host: UUID()), kind: .claude,
            lastDestination: last)
        #expect(NewChatResolver.destination(preferences, knownHosts: [host]) == last)
        #expect(
            NewChatResolver.plan(
                preferences: preferences, knownHosts: [host], workspaces: [.init(id: "w1", label: "a")])
                == NewChatPlan(hostID: host, target: .existingWorkspace(id: "w1"), kind: .claude))
    }

    @Test func noKnownHostResolvesNoDestination() {
        let preferences = NewChatPreferences(
            destination: destination(id: "w1", host: UUID()), lastDestination: destination(id: "w2", host: UUID()))
        #expect(NewChatResolver.destination(preferences, knownHosts: [host]) == nil)
    }

    /// A Settings destination naming only a Host (it had no workspaces yet).
    @Test func hostOnlyPlansIntoTheLastUsedWorkspaceOnThatHost() {
        let preferences = NewChatPreferences(
            destination: destination(), kind: .claude, lastDestination: destination(id: "w2", label: "b"))
        #expect(
            NewChatResolver.plan(
                preferences: preferences, knownHosts: [host],
                workspaces: [.init(id: "w1", label: "a"), .init(id: "w2", label: "b")])?.target
                == .existingWorkspace(id: "w2"))
    }

    @Test func hostOnlyRecreatesAGoneLastUsedWorkspace() {
        let preferences = NewChatPreferences(
            destination: destination(), kind: .claude,
            lastDestination: destination(id: "gone", label: "b", cwd: "/src/b"))
        #expect(
            NewChatResolver.plan(
                preferences: preferences, knownHosts: [host], workspaces: [.init(id: "w1", label: "a")])?.target
                == .newWorkspace(directory: "/src/b", label: "b"))
    }

    @Test func hostOnlyIgnoresLastUsedOnAnotherHost() {
        let other = UUID()
        let preferences = NewChatPreferences(
            destination: destination(), kind: .claude, lastDestination: destination(id: "w2", cwd: "/src", host: other))
        #expect(
            NewChatResolver.plan(
                preferences: preferences, knownHosts: [host, other],
                workspaces: [.init(id: "w1", label: "a"), .init(id: "w2", label: "b")])
                == NewChatPlan(hostID: host, target: .existingWorkspace(id: "w1"), kind: .claude))
    }

    @Test func hostOnlyFallsToTheFirstWorkspaceWhenLastUsedDoesNotResolve() {
        let preferences = NewChatPreferences(
            destination: destination(), kind: .claude, lastDestination: destination(id: "gone"))
        #expect(
            NewChatResolver.plan(
                preferences: preferences, knownHosts: [host],
                workspaces: [.init(id: "w1", label: "a"), .init(id: "w2", label: "b")])?.target
                == .existingWorkspace(id: "w1"))
    }

    @Test func hostOnlyWithNoWorkspacesIsNil() {
        #expect(plan(destination()) == nil)
        let preferences = NewChatPreferences(
            destination: destination(), kind: .claude, lastDestination: destination(id: "gone"))
        #expect(NewChatResolver.plan(preferences: preferences, knownHosts: [host], workspaces: []) == nil)
    }

    @Test func settingsKindBeatsLastUsed() {
        // Settings value: kind .omp.
        let preferences = NewChatPreferences(kind: .omp, lastChatKind: .pi, lastAgentKind: .codex)
        #expect(NewChatResolver.kind(preferences) == .omp)
    }

    @Test func lastChatKindBeatsLastAgentKind() {
        // Settings value: kind Last Used (nil).
        let preferences = NewChatPreferences(lastChatKind: .pi, lastAgentKind: .codex)
        #expect(NewChatResolver.kind(preferences) == .pi)
    }

    @Test func lastAgentKindAppliesWhenItSupportsChatMode() {
        // Settings value: kind Last Used (nil).
        #expect(NewChatResolver.kind(NewChatPreferences(lastAgentKind: .codex)) == .codex)
    }

    @Test func cursorLastAgentKindResolvesNothing() {
        // Settings value: kind Last Used (nil).
        #expect(!SupportedAgentKind.cursor.supportsChatMode)
        #expect(NewChatResolver.kind(NewChatPreferences(lastAgentKind: .cursor)) == nil)
    }
}

@MainActor
@Suite("New Chat preferences")
struct NewChatPreferencesTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-new-chat-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func emptyDefaultsReadAsLastUsedWithNoHistory() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        #expect(NewChatPreferences.current(defaults: defaults) == NewChatPreferences())
    }

    @Test func currentReadsFixedAndLastUsedValues() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let fixed = ChatDestination(hostID: UUID(), workspaceID: "w1", workspaceLabel: "app", cwd: "/src/app")
        let last = ChatDestination(hostID: UUID(), workspaceID: nil, workspaceLabel: "web", cwd: nil)

        // Settings values: destination `fixed`, kind .omp.
        let settings = ChatModeSettings(defaults: defaults)
        settings.setNewChatDestination(fixed)
        settings.setNewChatKind(.omp)
        let recents = RecentSelectionsStore(defaults: defaults)
        recents.rememberChat(destination: last, kind: .pi)
        recents.remember(hostID: UUID(), kind: .gemini)

        #expect(
            NewChatPreferences.current(defaults: defaults)
                == NewChatPreferences(
                    destination: fixed, kind: .omp, lastDestination: last,
                    lastChatKind: .pi, lastAgentKind: .gemini))
    }

    @Test func rememberChatPersists() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let destination = ChatDestination(hostID: UUID(), workspaceID: "w2", workspaceLabel: "api", cwd: "/srv/api")
        RecentSelectionsStore(defaults: defaults).rememberChat(destination: destination, kind: .codex)

        let reopened = RecentSelectionsStore(defaults: defaults)
        #expect(reopened.lastChatDestination == destination)
        #expect(reopened.lastChatKind == .codex)
        #expect(reopened.chatMode == false)
    }

    @Test func unreadableDestinationReadsAsNil() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        defaults.set(Data("not json".utf8), forKey: "recent-chat-destination")
        defaults.set(Data("{}".utf8), forKey: ChatModeSettings.newChatDestinationKey)

        #expect(RecentSelectionsStore(defaults: defaults).lastChatDestination == nil)
        #expect(ChatModeSettings(defaults: defaults).newChatDestination == nil)
    }
}
