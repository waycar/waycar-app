import Testing

@testable import Waycar

struct HelpAgentPromptTests {
    private static func page(slug: String = "mosh") throws -> HelpPage {
        let markdown = """
            ---
            title: "Mosh"
            description: "Keep sessions alive on flaky networks."
            category: hosts
            ---

            Mosh keeps your session. See [Hosts](/help/hosts#add) and [CodexBar](https://github.com/steipete/CodexBar). See [Pricing](/pricing).
            """
        return try #require(HelpPage(slug: slug, markdown: markdown))
    }

    @Test func presetDescribesThePage() throws {
        let preset = HelpAgentPrompt.preset(for: try Self.page())
        #expect(preset.title == "Ask an Agent")
        #expect(preset.hostID == nil)
        #expect(!preset.locksHost)
        #expect(preset.suggestedName == "help-mosh")
        #expect(preset.attachmentTitle == "Help: Mosh")
    }

    @Test func firstMessageCarriesInstructionsAndPage() throws {
        let message = HelpAgentPrompt.preset(for: try Self.page()).firstMessage
        #expect(message.hasPrefix(
            "The user is reading Waycar's help page \"Mosh\" (https://waycar.dev/help/mosh)"))
        #expect(message.contains("ask before you change anything"))
        #expect(message.contains("---\n\n# Mosh\n\nKeep sessions alive on flaky networks.\n\nMosh keeps your session."))
    }

    @Test func siteLinksBecomeAbsoluteOthersStay() throws {
        let message = HelpAgentPrompt.preset(for: try Self.page()).firstMessage
        #expect(message.contains("[Hosts](https://waycar.dev/help/hosts#add)"))
        #expect(message.contains("[Pricing](https://waycar.dev/pricing)"))
        #expect(!message.contains("](/"))
        #expect(message.contains("[CodexBar](https://github.com/steipete/CodexBar)"))
    }

    @Test func longSlugNormalizesToAnAgentName() throws {
        let slug = "live-activities-not-updating-on-the-lock-screen"
        let name = try #require(HelpAgentPrompt.preset(for: try Self.page(slug: slug)).suggestedName)
        #expect(name.count <= 32)
        #expect(name.hasPrefix("help-live-activities"))
        #expect(AgentName.validationError(name) == nil)
    }

    /// The 32-character cut lands on a '-', which is dropped.
    @Test func aCutEndingOnAHyphenDropsIt() throws {
        let slug = "abcdefghijklmnopqrstuvwxyz-tail"
        #expect(AgentName.normalizingInput("help-\(slug)") == "help-abcdefghijklmnopqrstuvwxyz-")
        let name = try #require(HelpAgentPrompt.preset(for: try Self.page(slug: slug)).suggestedName)
        #expect(name == "help-abcdefghijklmnopqrstuvwxyz")
    }
}
