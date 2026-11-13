import Testing

@testable import Waycar

@Suite("Toolbar key to herdr key name")
struct HerdrKeyNamesTests {
    /// Every `AgentQuickKey` shape with a fixed name, written from herdr's
    /// docs (CLI reference `<key>` syntax and `parse_key_combo`).
    private static let expected: [(AgentQuickKey, HerdrKeyEncoding)] = [
        (.escape, .key("esc")),
        (.tab, .key("tab")),
        (.shiftTab, .key("shift+tab")),
        (.shiftEnter, .key("ctrl+j")),
        (.left, .key("left")),
        (.up, .key("up")),
        (.down, .key("down")),
        (.right, .key("right")),
        (.enter, .key("enter")),
        (.backspace, .key("backspace")),
        (.home, .notExpressible),
        (.end, .notExpressible),
        (.insert, .notExpressible),
        (.forwardDelete, .notExpressible),
        (.pageUp, .notExpressible),
        (.pageDown, .notExpressible),
        (.function(.f1), .key("f1")),
        (.function(.f12), .key("f12")),
        (.character("a"), .key("a")),
        (.character("Z"), .key("Z")),
        (.character("7"), .key("7")),
        (.character("="), .key("=")),
        (.character(" "), .key("space")),
        (.character("-"), .key("minus")),
        (.character("+"), .key("plus")),
        (.character("`"), .key("backtick")),
        (.character("\\"), .key("backslash")),
        (.character("\""), .key("double_quote")),
        (.character("é"), .key("é")),
        (.character("\n"), .notExpressible),
        (.character("\u{7F}"), .notExpressible),
        (.character("e\u{301}\u{20DD}"), .notExpressible),
    ]

    @Test("each key maps to the spelling herdr documents", arguments: expected.indices)
    func tableMatchesDocs(index: Int) {
        let (key, encoding) = Self.expected[index]
        #expect(key.herdrKey == encoding)
    }

    @Test("every function key F1 through F12 is f<n>")
    func functionKeys() {
        for key in TerminalFunctionKey.allCases {
            #expect(AgentQuickKey.function(key).herdrKey == .key("f\(key.rawValue)"))
        }
        #expect(TerminalFunctionKey.allCases.count == 12)
    }

    /// One name per `AgentQuickKey` case. The switch has no `default`, so a
    /// new case stops this file compiling until it is named here and given an
    /// expectation in `expected`.
    private static func caseName(_ key: AgentQuickKey) -> String {
        switch key {
        case .escape: "escape"
        case .tab: "tab"
        case .shiftTab: "shiftTab"
        case .shiftEnter: "shiftEnter"
        case .left: "left"
        case .up: "up"
        case .down: "down"
        case .right: "right"
        case .enter: "enter"
        case .backspace: "backspace"
        case .home: "home"
        case .end: "end"
        case .insert: "insert"
        case .forwardDelete: "forwardDelete"
        case .function: "function"
        case .character: "character"
        case .pageUp: "pageUp"
        case .pageDown: "pageDown"
        }
    }

    @Test("every AgentQuickKey case has an expectation")
    func everyCaseCovered() {
        let all: Set<String> = [
            "escape", "tab", "shiftTab", "shiftEnter", "left", "up", "down", "right",
            "enter", "backspace", "home", "end", "insert", "forwardDelete",
            "function", "character", "pageUp", "pageDown",
        ]
        #expect(Set(Self.expected.map { Self.caseName($0.0) }) == all)
    }

    @Test("no key uses the rejected ctrl-x form or a tmux name")
    func noRejectedSpellings() {
        let tmuxNames: Set<String> = ["BSpace", "BTab", "Escape", "Enter", "Tab", "PPage", "NPage"]
        for (key, _) in Self.expected {
            guard case .key(let name) = key.herdrKey else { continue }
            #expect(!name.contains("-") || name == "-", "\(name) uses a dash chord")
            #expect(!name.lowercased().hasPrefix("ctrl-"))
            #expect(!tmuxNames.contains(name))
            #expect(!name.contains("++"))
        }
    }
}
