import Foundation
import Testing

@testable import Waycar

@Suite("Chat Prompt launch text")
struct ChatModePromptTests {
    @Test(arguments: [nil, "", "   ", "\n\t \n"] as [String?])
    func blankUsesDefault(_ custom: String?) {
        #expect(ChatModePrompt.launchText(from: custom) == ChatModePrompt.defaultText)
    }

    @Test func whitespaceRunsCollapseToOneSpace() {
        let text = ChatModePrompt.launchText(from: "  Be brief.\n\n\tUse bullets.\r\nNo headings.  ")
        #expect(text == "Be brief. Use bullets. No headings.")
    }

    @Test func controlCharactersAreRemoved() {
        #expect(ChatModePrompt.launchText(from: "ring\u{0007}the bell") == "ringthe bell")
    }

    @Test func onlyControlCharactersFallBackToDefault() {
        #expect(ChatModePrompt.launchText(from: "\u{0007}\u{0000}") == ChatModePrompt.defaultText)
    }

    @Test func capsAtEightThousandCharacters() {
        let text = ChatModePrompt.launchText(from: String(repeating: "é", count: 9_000))
        #expect(text.count == 8_000)
        #expect(ChatModePrompt.launchText(from: String(repeating: "a", count: 8_000)).count == 8_000)
    }

    @Test func defaultIsSafeForHerdrArguments() {
        let text = ChatModePrompt.defaultText
        for forbidden in ["\n", "\t", "\"", "'", "!", "$", "`"] {
            #expect(!text.contains(forbidden), "default contains \(forbidden.debugDescription)")
        }
        #expect(ChatModePrompt.launchText(from: text) == text)
    }
}

@MainActor
@Suite("Chat Mode settings")
struct ChatModeSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-chat-mode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func customPromptPersistsAcrossInstances() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let settings = ChatModeSettings(defaults: defaults)
        #expect(settings.isDefault)
        settings.setPrompt("Reply in one sentence.")

        let reloaded = ChatModeSettings(defaults: defaults)
        #expect(reloaded.customPrompt == "Reply in one sentence.")
        #expect(reloaded.promptText == "Reply in one sentence.")
        #expect(!reloaded.isDefault)
    }

    @Test(arguments: ["", "  \n\t"])
    func blankPromptRestoresDefault(_ blank: String) throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = ChatModeSettings(defaults: defaults)
        settings.setPrompt("Custom")

        settings.setPrompt(blank)

        #expect(settings.isDefault)
        #expect(settings.promptText == ChatModePrompt.defaultText)
        #expect(defaults.object(forKey: ChatModeSettings.promptKey) == nil)
    }

    @Test func promptEqualToDefaultStoresNothing() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = ChatModeSettings(defaults: defaults)
        settings.setPrompt("Custom")

        settings.setPrompt(ChatModePrompt.defaultText)

        #expect(settings.isDefault)
        #expect(defaults.object(forKey: ChatModeSettings.promptKey) == nil)
    }

    @Test func resetClearsTheOverride() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = ChatModeSettings(defaults: defaults)
        settings.setPrompt("Custom")

        settings.resetToDefault()

        #expect(settings.isDefault)
        #expect(ChatModeSettings(defaults: defaults).isDefault)
        #expect(ChatModeSettings.effectivePrompt(defaults: defaults) == ChatModePrompt.defaultText)
    }

    @Test func reloadPicksUpASyncedChange() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = ChatModeSettings(defaults: defaults)

        defaults.set("From another device", forKey: ChatModeSettings.promptKey)
        settings.reload()

        #expect(settings.customPrompt == "From another device")
    }

    @Test func effectivePromptIsTheNormalizedCustomText() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = ChatModeSettings(defaults: defaults)
        settings.setPrompt("Be brief.\n\nNo tables.\u{0007}")

        #expect(ChatModeSettings.effectivePrompt(defaults: defaults) == "Be brief. No tables.")
        #expect(settings.promptText == "Be brief.\n\nNo tables.\u{0007}")
    }

    @Test func modelIsNormalizedAndPersists() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = ChatModeSettings(defaults: defaults)
        #expect(settings.model(for: .claude) == nil)

        settings.setModel(" claude-opus-4\n", for: .claude)

        #expect(settings.model(for: .claude) == "claude-opus-4")
        #expect(settings.model(for: .codex) == nil, "each harness keeps its own model")
        #expect(ChatModeSettings(defaults: defaults).model(for: .claude) == "claude-opus-4")
    }

    @Test(arguments: ["", "  \n\t"])
    func blankModelRemovesTheKey(_ blank: String) throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = ChatModeSettings(defaults: defaults)
        settings.setModel("gpt-5", for: .codex)

        settings.setModel(blank, for: .codex)

        #expect(settings.model(for: .codex) == nil)
        #expect(defaults.object(forKey: ChatModeSettings.modelKey(for: .codex)) == nil)
    }

    @Test func quickThinkingDefaultsOnAndOffPersists() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = ChatModeSettings(defaults: defaults)
        #expect(settings.quickThinking)

        settings.setQuickThinking(false)
        #expect(!settings.quickThinking)
        #expect(!ChatModeSettings(defaults: defaults).quickThinking)

        settings.setQuickThinking(true)
        #expect(defaults.object(forKey: ChatModeSettings.quickThinkingKey) == nil)
        #expect(ChatModeSettings(defaults: defaults).quickThinking)
    }

    @Test func reloadPicksUpSyncedModelsAndQuickThinking() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = ChatModeSettings(defaults: defaults)

        defaults.set("sonnet", forKey: ChatModeSettings.modelKey(for: .omp))
        defaults.set(false, forKey: ChatModeSettings.quickThinkingKey)
        settings.reload()

        #expect(settings.model(for: .omp) == "sonnet")
        #expect(!settings.quickThinking)
    }

    @Test func launchOptionsReadPromptModelAndQuickThinking() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        #expect(
            ChatModeSettings.launchOptions(for: .codex, defaults: defaults)
                == ChatModeLaunchOptions(prompt: ChatModePrompt.defaultText, model: nil, quickThinking: true))

        let settings = ChatModeSettings(defaults: defaults)
        settings.setPrompt("Be brief.\nNo tables.")
        settings.setModel("gpt-5", for: .codex)
        settings.setQuickThinking(false)

        #expect(
            ChatModeSettings.launchOptions(for: .codex, defaults: defaults)
                == ChatModeLaunchOptions(prompt: "Be brief. No tables.", model: "gpt-5", quickThinking: false))
        #expect(
            ChatModeSettings.launchOptions(for: .claude, defaults: defaults)
                == ChatModeLaunchOptions(prompt: "Be brief. No tables.", model: nil, quickThinking: false))
    }

    @Test func newChatDefaultsPersistAndClear() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = ChatModeSettings(defaults: defaults)
        #expect(settings.newChatDestination == nil)
        #expect(settings.newChatKind == nil)

        let destination = ChatDestination(hostID: UUID(), workspaceID: "w1", workspaceLabel: "app", cwd: "/src/app")
        settings.setNewChatDestination(destination)
        settings.setNewChatKind(.codex)
        let reopened = ChatModeSettings(defaults: defaults)
        #expect(reopened.newChatDestination == destination)
        #expect(reopened.newChatKind == .codex)

        reopened.setNewChatDestination(nil)
        reopened.setNewChatKind(nil)
        #expect(defaults.object(forKey: ChatModeSettings.newChatDestinationKey) == nil)
        #expect(defaults.object(forKey: ChatModeSettings.newChatKindKey) == nil)
    }

    @Test func reloadPicksUpSyncedNewChatDefaults() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = ChatModeSettings(defaults: defaults)
        let destination = ChatDestination(hostID: UUID(), workspaceID: nil, workspaceLabel: "web", cwd: nil)

        defaults.set(try JSONEncoder().encode(destination), forKey: ChatModeSettings.newChatDestinationKey)
        defaults.set("pi", forKey: ChatModeSettings.newChatKindKey)
        settings.reload()
        #expect(settings.newChatDestination == destination)
        #expect(settings.newChatKind == .pi)

        defaults.removeObject(forKey: ChatModeSettings.newChatDestinationKey)
        defaults.removeObject(forKey: ChatModeSettings.newChatKindKey)
        settings.reload()
        #expect(settings.newChatDestination == nil)
        #expect(settings.newChatKind == nil)
    }

    /// Every key a setting writes syncs, so no setting quietly stays on one device.
    @Test func everyWrittenKeyIsSynced() throws {
        let suiteName = "hm-chat-mode-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ChatModeSettings(defaults: defaults)

        settings.setPrompt("Reply in one sentence.")
        for kind in SupportedAgentKind.allCases where kind.supportsChatMode {
            settings.setModel("model-\(kind.rawValue)", for: kind)
        }
        settings.setQuickThinking(false)
        settings.setNewChatDestination(
            ChatDestination(hostID: UUID(), workspaceID: "w1", workspaceLabel: "app", cwd: "/src/app"))
        settings.setNewChatKind(.codex)

        let written = Set(try #require(defaults.persistentDomain(forName: suiteName)).keys)
        #expect(written == Set(ChatModeSettings.syncedKeys))
    }
}
