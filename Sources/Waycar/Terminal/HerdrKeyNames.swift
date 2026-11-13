/// How one toolbar key reaches a herdr pane through `pane.send_keys`.
enum HerdrKeyEncoding: Equatable, Sendable {
    /// A key-combo string herdr's `pane send-keys` parser accepts.
    case key(String)
    /// herdr's key parser has no name for it. Sending it needs another route
    /// (`pane.send_text` with the escape sequence, or `pane.send_input`).
    case notExpressible
}

extension AgentQuickKey {
    /// The toolbar-key → herdr key-name table. herdr accepts its own
    /// key-combo syntax, not tmux names (`BSpace`, `BTab`) and not `ctrl-c`
    /// (`ctrl+c`; the legacy alias is `C-c`). Spellings come from herdr's
    /// CLI reference and its `parse_key_combo` (v0.9.1).
    ///
    /// The switch has no `default`: a new `AgentQuickKey` case does not
    /// compile until it is mapped here.
    ///
    /// Modifier state (the one-shot Ctrl/Alt/Shift) is not part of this
    /// table: callers that need a chord prefix `ctrl+`, `alt+` or `shift+`.
    var herdrKey: HerdrKeyEncoding {
        switch self {
        case .escape: .key("esc")
        case .tab: .key("tab")
        case .shiftTab: .key("shift+tab")
        // The toolbar's Shift-Enter is Ctrl-J (LF) on every other route
        // (`TerminalKeyboard.keyPress`); herdr accepts `ctrl+j` and would
        // encode `shift+enter` differently.
        case .shiftEnter: .key("ctrl+j")
        case .left: .key("left")
        case .up: .key("up")
        case .down: .key("down")
        case .right: .key("right")
        case .enter: .key("enter")
        case .backspace: .key("backspace")
        // herdr's parser has no name for these six.
        case .home, .end, .insert, .forwardDelete, .pageUp, .pageDown:
            .notExpressible
        case .function(let key): .key("f\(key.rawValue)")
        case .character(let character): Self.herdrCharacterKey(character)
        }
    }

    private static let herdrPunctuationNames: [Character: String] = [
        " ": "space", "-": "minus", "+": "plus", "`": "backtick",
        ",": "comma", ".": "period", "/": "slash", "\\": "backslash",
        "'": "quote", "\"": "double_quote", ";": "semicolon",
        ":": "colon", "%": "percent", "&": "ampersand",
    ]

    /// herdr takes one Unicode scalar per key; a grapheme cluster of several
    /// scalars, or a control character, is text, not a key.
    private static func herdrCharacterKey(_ character: Character) -> HerdrKeyEncoding {
        if let name = herdrPunctuationNames[character] { return .key(name) }
        guard character.unicodeScalars.count == 1,
            let scalar = character.unicodeScalars.first,
            scalar.value >= 0x20, scalar.value != 0x7F
        else { return .notExpressible }
        return .key(String(character))
    }
}
