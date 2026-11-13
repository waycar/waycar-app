import Foundation
import Testing

@testable import Waycar

@Suite("Input shortcut strip presentation")
struct InputShortcutStripPresentationTests {
    private static func key(_ key: AgentQuickKey, _ modifiers: TerminalKeyModifiers = []) -> AgentToolbarItem.Content {
        .key(AgentToolbarKeyChord(key, modifiers: modifiers))
    }

    private static let interrupt = key(.character("c"), .control)

    private func agent(
        skillsAvailable: Bool = true,
        customKeyIDs: Set<UUID> = []
    ) -> AgentToolbarAvailability {
        AgentToolbarAvailability(
            skillsAvailable: skillsAvailable,
            worktreeDetailsAvailable: true, snippetIDs: [], customKeyIDs: customKeyIDs)
    }

    private func strip(
        _ layout: AgentToolbarLayout,
        availability: AgentToolbarAvailability
    ) -> InputShortcutStripPresentation {
        InputShortcutStripPresentation(layout: availability.resolve(layout))
    }

    @Test func theDefaultLayoutDrawsEveryItemInOrderWithItsControl() {
        let presentation = strip(.default, availability: agent())

        #expect(presentation.items.map(\.item.content) == [
            Self.key(.escape), Self.key(.tab), Self.key(.shiftTab),
            Self.key(.up), Self.key(.down), Self.key(.left), Self.key(.right),
            Self.key(.backspace), Self.key(.shiftEnter), .action(.paste),
            Self.key(.enter), .action(.moreMenu), .action(.toolsKeyboard),
        ])
        #expect(presentation.items.map(\.control) == [
            .button, .button, .button, .button, .button, .button, .button,
            .repeatingBackspace, .button, .pasteControl,
            .button, .moreMenu, .toolsKeyboard,
        ])
    }

    @Test func aCustomLayoutKeepsItsOrderAndDropsWhatThisAgentCannotRun() {
        let compact = UUID()
        let gone = UUID()
        let layout = AgentToolbarLayout(items: [
            AgentToolbarItem(Self.interrupt),
            AgentToolbarItem(.customKey(gone)),
            AgentToolbarItem(Self.key(.escape)),
            AgentToolbarItem(.action(.skills)),
            AgentToolbarItem(.modifier(.control)),
            AgentToolbarItem(.customKey(compact)),
        ])

        let presentation = strip(
            layout, availability: agent(skillsAvailable: false, customKeyIDs: [compact]))

        // No More is added back: the Toolbar draws exactly the saved items.
        #expect(presentation.items.map(\.item.content) == [
            Self.interrupt, Self.key(.escape), .modifier(.control), .customKey(compact),
        ])
    }

    @Test func eachItemGetsTheControlThatDrivesIt() {
        let items: [AgentToolbarItem.Content] = [
            Self.key(.backspace),
            Self.key(.backspace, .option),
            .modifier([.control, .shift]),
            .action(.paste),
            .action(.moreMenu),
            .action(.toolsKeyboard),
            .action(.skills),
            .snippet(UUID()),
            .customKey(UUID()),
        ]
        let controls = items.map { InputShortcutStripItem(AgentToolbarItem($0)).control }

        #expect(controls == [
            // Only plain Backspace repeats; ⌥⌫ is a Combo sent once per tap.
            .repeatingBackspace,
            .button,
            .modifierChip([.control, .shift]),
            .pasteControl,
            .moreMenu,
            .toolsKeyboard,
            .button,
            .button,
            .button,
        ])
    }
}
