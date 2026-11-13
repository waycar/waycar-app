import Foundation
import Testing

@testable import Waycar

@Suite("herdr-core key names", .timeLimit(.minutes(1)))
struct CoreKeysTests {
    /// Core's accepted names, written from `rpc-facts.md` §5 independently of
    /// `CoreKeys`: letters, digits, the literal punctuation, the named keys,
    /// and modifiers joined with `+`. `ctrl+i`, `ctrl+m` and `ctrl+[` are
    /// refused, as is `ctrl+shift+<letter>`.
    private static func coreAccepts(_ name: String) -> Bool {
        let parts = name.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let base = parts.last, !parts.contains(where: \.isEmpty) else { return false }
        let modifiers = parts.dropLast()
        let modifierWords: Set<String> = [
            "shift", "ctrl", "control", "alt", "meta", "opt", "super", "cmd",
        ]
        guard modifiers.allSatisfy(modifierWords.contains) else { return false }
        let named = Set<String>(
            [
                "backslash", "space", "enter", "return", "tab", "backspace", "esc", "escape",
                "delete", "del", "insert", "home", "end", "pageup", "pgup", "pagedown", "pgdn",
                "up", "down", "left", "right",
            ] + (1...12).map { "f\($0)" })
        let literals: Set<String> = ["`", "\\", "[", "]", ",", "=", "-", ".", "'", ";", "/"]
        let isLetter = base.count == 1 && base.first.map { $0.isASCII && $0.isLowercase && $0.isLetter } == true
        let isDigit = base.count == 1 && base.first.map { $0.isASCII && $0.isNumber } == true
        guard isLetter || isDigit || literals.contains(base) || named.contains(base) else {
            return false
        }
        if modifiers.contains("ctrl"), ["i", "m", "["].contains(base) { return false }
        if modifiers.contains("ctrl"), modifiers.contains("shift"), isLetter { return false }
        return true
    }

    @Test(arguments: [
        ("esc", "esc"), ("tab", "tab"), ("shift+tab", "shift+tab"), ("enter", "enter"),
        ("backspace", "backspace"), ("left", "left"), ("right", "right"), ("up", "up"),
        ("down", "down"), ("home", "home"), ("end", "end"), ("insert", "insert"),
        ("delete", "delete"), ("pageup", "pageup"), ("pagedown", "pagedown"),
        ("f1", "f1"), ("f12", "f12"), ("a", "a"), ("z", "z"), ("0", "0"), ("9", "9"),
        ("space", "space"), (" ", "space"), ("backslash", "backslash"), ("\\", "backslash"),
        ("ctrl+c", "ctrl+c"), ("alt+x", "alt+x"), ("ctrl+j", "ctrl+j"), ("ctrl+space", "ctrl+space"),
        ("alt+enter", "alt+enter"), ("ctrl+alt+delete", "ctrl+alt+delete"),
        ("minus", "-"), ("comma", ","), ("period", "."), ("slash", "/"), ("quote", "'"),
        ("semicolon", ";"), ("backtick", "`"),
        ("-", "-"), (",", ","), (".", "."), ("/", "/"), ("'", "'"), (";", ";"), ("`", "`"),
        ("[", "["), ("]", "]"), ("=", "="),
        ("ESC", "esc"), ("Enter", "enter"), ("Ctrl+C", "ctrl+c"), ("SHIFT+TAB", "shift+tab"),
        ("F5", "f5"), ("PageUp", "pageup"), ("forwardDelete", "delete"), ("escape", "esc"),
        ("return", "enter"), ("pgup", "pageup"), ("pgdn", "pagedown"),
        ("control+c", "ctrl+c"), ("meta+x", "alt+x"), ("option+x", "alt+x"),
        ("ctrl+minus", "ctrl+-"), ("alt+period", "alt+."),
    ])
    func acceptedKeysMapToCoresNames(key: String, name: String) throws {
        let mapped = try CoreKeys.name(for: key)
        #expect(mapped == name)
        #expect(Self.coreAccepts(mapped), "core would refuse \(mapped)")
    }

    @Test(arguments: [
        "plus", "double_quote", "colon", "percent", "ampersand",
        "+", "\"", ":", "%", "&", "!", "@", "#", "$", "^", "*", "(", ")", "_", "{", "}", "|",
        "<", ">", "?", "~", "A", "Z", "é", "👍",
        "ctrl+i", "ctrl+m", "ctrl+[", "ctrl+I", "ctrl+shift+a", "ctrl++", "alt+plus",
    ])
    func keysCoreCannotSendByNameAreUnsupported(key: String) {
        do {
            let name = try CoreKeys.name(for: key)
            Issue.record("\(key) became \(name)")
        } catch let error as HerdrAPIError {
            #expect(error.code == "unsupported")
            #expect(error.message.contains("herdr-core cannot send"))
            #expect(error.message.contains(key))
        } catch {
            Issue.record("\(key) threw \(error)")
        }
    }

    @Test(arguments: ["", "C-c", "ctrl-c", "ctrl+", "hello", "f13", "f0", "hyper+x", "tab+tab", "shiftEnter"])
    func unknownNamesAreInvalidKeys(key: String) {
        do {
            let name = try CoreKeys.name(for: key)
            Issue.record("\(key) became \(name)")
        } catch let error as HerdrAPIError {
            #expect(error.code == "invalid_key")
        } catch {
            Issue.record("\(key) threw \(error)")
        }
    }

    @Test func aBadKeyAnywhereSendsNothing() throws {
        #expect(try CoreKeys.names(for: ["down", "enter"]) == ["down", "enter"])
        #expect(try CoreKeys.names(for: []).isEmpty)
        #expect(throws: HerdrAPIError.self) { try CoreKeys.names(for: ["a", "+", "b"]) }
        #expect(throws: HerdrAPIError.self) { try CoreKeys.names(for: ["a", "nope"]) }
    }

    // MARK: Toolbar

    /// What the toolbar sends for the keys herdr's own parser has no name
    /// for: `AgentQuickKey.herdrKey` reports them as `.notExpressible`.
    private static let namesForKeysHerdrCannotExpress: [String: String] = [
        "home": "home", "end": "end", "insert": "insert", "forwardDelete": "delete",
        "pageUp": "pageup", "pageDown": "pagedown",
    ]

    private static var toolbarKeys: [(label: String, key: AgentQuickKey)] {
        var keys: [(String, AgentQuickKey)] = [
            ("escape", .escape), ("tab", .tab), ("shiftTab", .shiftTab), ("shiftEnter", .shiftEnter),
            ("left", .left), ("up", .up), ("down", .down), ("right", .right),
            ("enter", .enter), ("backspace", .backspace), ("home", .home), ("end", .end),
            ("insert", .insert), ("forwardDelete", .forwardDelete), ("pageUp", .pageUp),
            ("pageDown", .pageDown),
        ]
        keys += TerminalFunctionKey.allCases.map { ("f\($0.rawValue)", AgentQuickKey.function($0)) }
        // Every printable ASCII character the character keys can carry.
        for value in 0x20...0x7E {
            if let scalar = Unicode.Scalar(value) {
                keys.append((String(scalar), .character(Character(scalar))))
            }
        }
        return keys
    }

    /// Characters core cannot type by name: capitals, and the shifted
    /// symbols, `+ " : % &` among them.
    private static let unsupportedCharacters: Set<Character> = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ+\":%&!@#$^*()_{}|<>?~")

    @Test func everyToolbarKeyIsAcceptedByCoreOrRejectedOnPurpose() throws {
        var accepted = 0
        for (label, quickKey) in Self.toolbarKeys {
            let herdrName: String
            switch quickKey.herdrKey {
            case .key(let name):
                herdrName = name
            case .notExpressible:
                herdrName = try #require(
                    Self.namesForKeysHerdrCannotExpress[label], "no core name for \(label)")
            }
            do {
                let name = try CoreKeys.name(for: herdrName)
                accepted += 1
                #expect(Self.coreAccepts(name), "\(label) became \(name), which core refuses")
                if case .character(let character) = quickKey {
                    #expect(
                        !Self.unsupportedCharacters.contains(character),
                        "\(label) must not be sendable by name")
                }
            } catch let error as HerdrAPIError {
                #expect(error.code == "unsupported", "\(label): \(error)")
                guard case .character(let character) = quickKey else {
                    Issue.record("\(label) is a named toolbar key and must be sendable")
                    continue
                }
                #expect(Self.unsupportedCharacters.contains(character), "\(label) should be sendable")
            }
        }
        // 16 named keys and F1-F12 plus lowercase letters, digits, and the
        // punctuation and space core takes: nothing was skipped silently.
        #expect(accepted == 28 + 26 + 10 + 11 + 1)
    }

    @Test func shiftEnterStaysCtrlJ() throws {
        #expect(AgentQuickKey.shiftEnter.herdrKey == .key("ctrl+j"))
        #expect(try CoreKeys.name(for: "ctrl+j") == "ctrl+j")
    }
}
