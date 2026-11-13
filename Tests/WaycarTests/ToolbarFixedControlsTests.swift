import Foundation
import Testing

@testable import Waycar

@MainActor
@Suite("Toolbar fixed controls")
struct ToolbarFixedControlsTests {
    @Test func dictateToAgentShowsForAnAgentButNeverForAShell() {
        let dictation = DictationStore(
            engine: ScriptedDictationEngine(), locale: { Locale(identifier: "en_US") })
        let transport = ScriptedTransport()
        let agent = AgentComposerStore(target: "w1:p1") { params in
            try await transport.promptAgent(params)
        }
        let shell = AgentComposerStore(shellPaneID: "w1:p2") { _ in }

        #expect(AgentDirectInputPresentation.showsDictateToAgent(dictation: dictation, composer: agent))
        #expect(!AgentDirectInputPresentation.showsDictateToAgent(dictation: dictation, composer: shell))
        #expect(
            !AgentDirectInputPresentation.showsDictateToAgent(
                dictation: DictationStore(engine: nil), composer: agent))
    }

    @Test func terminalKeyboardHintMentionsClosingMessageAgentOnlyWhenItIsOpen() {
        let closed = AgentDirectInputPresentation.terminalKeyboardAccessibilityHint(
            isKeyboardUp: false, isMessageAgentOpen: false)
        let open = AgentDirectInputPresentation.terminalKeyboardAccessibilityHint(
            isKeyboardUp: false, isMessageAgentOpen: true)
        #expect(!closed.contains("Closes Message Agent"))
        #expect(open.contains("Closes Message Agent"))
    }

    @Test func aRecordingBlocksTheOtherMicUntilItEnds() async throws {
        let engine = ScriptedDictationEngine()
        let sender = DictationSender(
            dictation: DictationStore(engine: engine, locale: { Locale(identifier: "en_US") }))
        let other = DictationStore(engine: engine, locale: { Locale(identifier: "en_US") })

        sender.start()
        engine.emit(.listening)
        try await waitUntil { sender.dictation.phase == .listening }
        #expect(other.isBlockedByOtherSession)
        #expect(!sender.dictation.isBlockedByOtherSession)

        sender.cancel()
        try await waitUntil { sender.dictation.phase == .idle }
        #expect(!other.isBlockedByOtherSession)
    }
}
