import Foundation
import Testing

@testable import Waycar

@Suite("tmux key names")
struct TmuxKeysTests {
    private func stroke(_ key: String) throws -> TmuxKeyStroke {
        try TmuxKeys.stroke(for: key)
    }

    @Test func theKeysTheAppSendsToday() throws {
        // Composer submit and Blocked Allow send `enter`; Blocked Cancel
        // sends `esc`.
        #expect(try stroke("enter") == .named("Enter"))
        #expect(try stroke("esc") == .named("Escape"))
    }

    @Test func herdrSpellingsAreCaseInsensitive() throws {
        #expect(try stroke("Enter") == .named("Enter"))
        #expect(try stroke("ESC") == .named("Escape"))
        #expect(try stroke("escape") == .named("Escape"))
        #expect(try stroke("ctrl+c") == .named("C-c"))
        #expect(try stroke("C-c") == .named("C-c"))
        #expect(try stroke("CTRL+C") == .named("C-c"))
    }

    @Test func toolbarKeys() throws {
        #expect(try stroke("tab") == .named("Tab"))
        #expect(try stroke("shiftTab") == .named("BTab"))
        #expect(try stroke("shift+tab") == .named("BTab"))
        #expect(try stroke("BTab") == .named("BTab"))
        #expect(try stroke("backspace") == .named("BSpace"))
        #expect(try stroke("BSpace") == .named("BSpace"))
        #expect(try stroke("forwardDelete") == .named("DC"))
        #expect(try stroke("delete") == .named("DC"))
        #expect(try stroke("insert") == .named("IC"))
        #expect(try stroke("up") == .named("Up"))
        #expect(try stroke("down") == .named("Down"))
        #expect(try stroke("left") == .named("Left"))
        #expect(try stroke("right") == .named("Right"))
        #expect(try stroke("home") == .named("Home"))
        #expect(try stroke("end") == .named("End"))
        #expect(try stroke("pageUp") == .named("PPage"))
        #expect(try stroke("page_down") == .named("NPage"))
        #expect(try stroke("PgDn") == .named("NPage"))
        #expect(try stroke("space") == .named("Space"))
    }

    @Test func functionKeys() throws {
        for number in 1...12 {
            #expect(try stroke("f\(number)") == .named("F\(number)"))
            #expect(try stroke("F\(number)") == .named("F\(number)"))
        }
        #expect(throws: HerdrAPIError.self) { try stroke("f13") }
    }

    @Test func shiftEnterIsALineFeedLikeTheToolbar() throws {
        #expect(try stroke("shiftEnter") == .bytes([0x0A]))
        #expect(try stroke("shift+enter") == .bytes([0x0A]))
        #expect(try stroke("S-Enter") == .bytes([0x0A]))
    }

    @Test func modifiedLetters() throws {
        #expect(try stroke("ctrl+r") == .named("C-r"))
        #expect(try stroke("C-r") == .named("C-r"))
        #expect(try stroke("alt+x") == .named("M-x"))
        #expect(try stroke("meta+x") == .named("M-x"))
        #expect(try stroke("option+b") == .named("M-b"))
        #expect(try stroke("M-x") == .named("M-x"))
        #expect(try stroke("M-X") == .named("M-X"))
        #expect(try stroke("alt+shift+f") == .named("M-F"))
        #expect(try stroke("ctrl+alt+d") == .named("C-M-d"))
        #expect(try stroke("shift+a") == .bytes([0x41]))
    }

    @Test func modifiedNamedKeys() throws {
        #expect(try stroke("ctrl+left") == .named("C-Left"))
        #expect(try stroke("alt+enter") == .named("M-Enter"))
        #expect(try stroke("S-Up") == .named("S-Up"))
        #expect(try stroke("ctrl+space") == .named("C-Space"))
        #expect(try stroke("alt+.") == .bytes([0x1B, 0x2E]))
    }

    @Test func singleCharactersAreTheirBytes() throws {
        #expect(try stroke("y") == .bytes([0x79]))
        #expect(try stroke(";") == .bytes([0x3B]))
        #expect(try stroke("é") == .bytes([0xC3, 0xA9]))
    }

    @Test func unknownNamesThrowInsteadOfBeingTyped() {
        for key in ["", "NotAKey", "ctrl-c", "ctrl+", "ctrl+[", "hyper+x", "enterr", "S-Enter2", "ctrl+é"] {
            #expect(throws: HerdrAPIError(code: "invalid_key", message: "unknown key name: \(key)"), "\(key)") {
                try stroke(key)
            }
        }
    }

    @Test func aBadKeyFailsTheWholeList() {
        #expect(throws: HerdrAPIError.self) {
            try TmuxKeys.strokes(for: ["enter", "bogus"])
        }
    }

    @Test func commandsSendNamesAndBytesInOrder() throws {
        #expect(try TmuxKeys.commands(target: "%3", keys: ["esc", "shift+enter", "C-c"]) == [
            "send-keys -t %3 Escape",
            "send-keys -t %3 -H 0a",
            "send-keys -t %3 C-c",
        ])
    }
}
