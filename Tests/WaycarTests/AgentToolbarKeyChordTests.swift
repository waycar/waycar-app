import Foundation
import Testing

@testable import Waycar

@Suite("Agent toolbar key chord codec")
struct AgentToolbarKeyChordTests {
    /// Written out rather than derived from production code, so a key the
    /// codec forgets is a failing test and not a shorter loop.
    private static let nonCharacterKeys: [AgentQuickKey] = [
        .escape, .tab, .shiftTab, .shiftEnter, .left, .up, .down, .right, .enter, .backspace,
        .home, .end, .insert, .forwardDelete, .pageUp, .pageDown,
        .function(.f1), .function(.f12),
    ]
    private static let sampleCharacters: [Character] = ["a", "C", "-", "/", " ", "é", "~"]
    private static let modifierSubsets: [TerminalKeyModifiers] =
        (0..<8).map { TerminalKeyModifiers(rawValue: UInt8($0)) }

    private func decode(_ json: String) throws -> AgentToolbarKeyChord {
        try JSONDecoder().decode(AgentToolbarKeyChord.self, from: Data(json.utf8))
    }

    @Test func everyKeyAndModifierSubsetRoundTrips() throws {
        let keys = Self.nonCharacterKeys + Self.sampleCharacters.map { AgentQuickKey.character($0) }
        for key in keys {
            for modifiers in Self.modifierSubsets {
                let chord = AgentToolbarKeyChord(key, modifiers: modifiers)
                let data = try JSONEncoder().encode(chord)
                #expect(try JSONDecoder().decode(AgentToolbarKeyChord.self, from: data) == chord)
            }
        }
    }

    @Test func documentedShapesDecodeToTheirChords() throws {
        #expect(try decode(#"{"key":"tab","mods":["shift"]}"#)
            == AgentToolbarKeyChord(.tab, modifiers: .shift))
        #expect(try decode(#"{"key":"char","char":"c","mods":["control"]}"#)
            == AgentToolbarKeyChord(.character("c"), modifiers: .control))
        #expect(try decode(#"{"key":"f","n":12,"mods":["option"]}"#)
            == AgentToolbarKeyChord(.function(.f12), modifiers: .option))
        #expect(try decode(#"{"key":"char","char":"-","mods":["control","shift"]}"#)
            == AgentToolbarKeyChord(.character("-"), modifiers: [.control, .shift]))
        #expect(try decode(#"{"key":"escape"}"#) == AgentToolbarKeyChord(.escape))
    }

    /// Shift + Tab and the ⇧Tab key look alike but are different chords: a
    /// layout may hold both, and neither may decode as the other.
    @Test func shiftedTabStaysDistinctFromShiftTab() throws {
        let combo = AgentToolbarKeyChord(.tab, modifiers: .shift)
        let key = AgentToolbarKeyChord(.shiftTab)
        #expect(combo != key)
        #expect(try JSONEncoder().encode(combo) != JSONEncoder().encode(key))
        #expect(try decode(String(decoding: JSONEncoder().encode(combo), as: UTF8.self)) == combo)
        #expect(try decode(String(decoding: JSONEncoder().encode(key), as: UTF8.self)) == key)
        #expect(combo.isCombo && !key.isCombo)
    }

    @Test(arguments: [
        #"{"key":"hyper","mods":[]}"#,
        #"{"key":"tab","mods":["command"]}"#,
        #"{"key":"tab","mods":"shift"}"#,
        #"{"key":"char","mods":["control"]}"#,
        #"{"key":"char","char":"","mods":[]}"#,
        #"{"key":"char","char":"ab","mods":[]}"#,
        #"{"key":"char","char":"\u001b","mods":[]}"#,
        #"{"key":"char","char":"\n","mods":[]}"#,
        #"{"key":"char","char":"\t","mods":[]}"#,
        #"{"key":"f","n":0,"mods":[]}"#,
        #"{"key":"f","n":13,"mods":[]}"#,
        #"{"key":"f","mods":[]}"#,
        #"{"mods":["control"]}"#,
        #""tab""#,
        #"["tab"]"#,
    ])
    func junkIsRejected(json: String) {
        #expect(throws: (any Error).self) { try decode(json) }
    }

    @Test func onlyChordsThatEncodeCarriageReturnSubmit() {
        #expect(AgentToolbarKeyChord(.enter).submits)
        #expect(AgentToolbarKeyChord(.enter, modifiers: .option).submits)
        #expect(AgentToolbarKeyChord(.character("m"), modifiers: .control).submits)
        #expect(!AgentToolbarKeyChord(.enter, modifiers: .shift).submits)
        #expect(!AgentToolbarKeyChord(.shiftEnter).submits)
        #expect(!AgentToolbarKeyChord(.character("m")).submits)
        #expect(!AgentToolbarKeyChord(.character("c"), modifiers: .control).submits)
    }
}
