import Testing

@testable import Waycar

@Suite("Zellij keys")
struct ZellijKeysTests {
    static let toolbar: [(String, String)] = [
        ("enter", "Enter"), ("esc", "Esc"), ("tab", "Tab"), ("shiftTab", "Shift Tab"),
        ("shiftEnter", "Ctrl j"), ("⇧Enter", "Ctrl j"), ("backspace", "Backspace"),
        ("forwardDelete", "Delete"), ("insert", "Insert"), ("home", "Home"), ("end", "End"),
        ("pageUp", "PageUp"), ("pageDown", "PageDown"), ("up", "Up"), ("down", "Down"),
        ("left", "Left"), ("right", "Right"), ("ctrl+c", "Ctrl c"), ("C-C", "Ctrl c"),
        ("alt+b", "Alt b"), ("ctrl+alt+c", "Ctrl Alt c"), ("M-x", "Alt x"),
        ("space", "Space"), ("plus", "+"), ("double_quote", "\""), ("colon", ":"),
        ("percent", "%"), ("ampersand", "&"), ("backslash", "\\"),
    ]
    @Test(arguments: toolbar)
    func toolbarNames(_ entry: (String, String)) throws {
        #expect(try ZellijKeys.name(for: entry.0) == entry.1)
    }
    @Test(arguments: Array(1...12))
    func functionKeys(_ number: Int) throws {
        #expect(try ZellijKeys.name(for: "f\(number)") == "F\(number)")
    }
    @Test(arguments: ["+", "\"", ":", "%", "&", "A", "é", "-", "?", "'"])
    func literalCharacters(_ text: String) throws { #expect(try ZellijKeys.name(for: text) == text) }
    @Test func invalidNameUsesHerdrError() {
        #expect(throws: HerdrAPIError(code: "invalid_key", message: "unknown key name: potato")) {
            try ZellijKeys.name(for: "potato")
        }
    }
}
