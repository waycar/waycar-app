import Foundation

/// Waycar's key names (the toolbar and `HerdrKeyNames` spellings) to the
/// names herdr-core's `terminal.keys` accepts (design §7; research
/// `rpc-facts.md` §5).
///
/// core takes letters, digits, the literal punctuation `` ` \ [ ] , = - . ' ; / ``,
/// `space enter tab backspace esc delete insert home end pageup pagedown`,
/// the arrows and `f1`-`f12`, with `shift ctrl alt super` joined by `+`. It
/// validates all names or sends none, and cannot type `+ " : % &`, shifted
/// symbols or capitals by name. Every name is checked here, so a key core
/// would refuse never reaches the Host, and one it would silently change
/// (`A` typed as `a`) is refused as well.
enum CoreKeys {
    /// Code of the error for a key core cannot send by name. The UI's
    /// `unsupported` branch is the one herdr's own missing-feature errors use.
    static let unsupportedCode = "unsupported"
    /// Code of the error for a name that is no key at all, as `TmuxKeys`.
    static let invalidKeyCode = "invalid_key"

    /// The `terminal.keys` names for `keys`, in order. Throws before
    /// returning anything partially: `HerdrAPIError(code: "unsupported")` for
    /// a key core cannot send by name, `invalid_key` for an unknown name.
    static func names(for keys: [String]) throws -> [String] {
        try keys.map(name(for:))
    }

    static func name(for key: String) throws -> String {
        guard !key.isEmpty else { throw invalid(key) }
        if key.unicodeScalars.count == 1 { return try character(key, original: key) }
        let parts = key.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 { return try namedKey(key.lowercased(), original: key) }
        // An empty part is a `+` base (`ctrl++`) or a dangling one (`ctrl+`).
        guard parts.allSatisfy({ !$0.isEmpty }) else {
            throw key.hasSuffix("++") ? unsupported(key) : invalid(key)
        }
        guard let modifierNames = modifiers(Array(parts.dropLast())),
            let base = parts.last
        else { throw invalid(key) }
        let name = try chordBase(base, modifiers: modifierNames, original: key)
        return (modifierNames + [name]).joined(separator: "+")
    }

    // MARK: Vocabulary

    /// Names core takes as they are.
    private static let sameNames: Set<String> = [
        "esc", "tab", "enter", "backspace", "left", "right", "up", "down", "home", "end",
        "insert", "delete", "pageup", "pagedown", "space", "backslash",
        "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12",
    ]

    /// Other spellings of those, lowercased: core's own aliases and the
    /// toolbar's `forwardDelete`.
    private static let aliases: [String: String] = [
        "escape": "esc", "return": "enter", "del": "delete", "forwarddelete": "delete",
        "pgup": "pageup", "pgdn": "pagedown", "pgdown": "pagedown",
    ]

    /// herdr TUI's names for the punctuation core spells literally.
    private static let punctuationNames: [String: String] = [
        "minus": "-", "comma": ",", "period": ".", "slash": "/", "quote": "'",
        "semicolon": ";", "backtick": "`",
    ]

    /// herdr TUI names for what core cannot type by name.
    private static let unsupportedNames: Set<String> = [
        "plus", "double_quote", "colon", "percent", "ampersand",
    ]

    /// The literal single characters core takes.
    private static let literalPunctuation: Set<Character> = [
        "`", "[", "]", ",", "=", "-", ".", "'", ";", "/",
    ]

    /// Modifier spellings to core's canonical word. core also knows `meta`,
    /// `opt`, `cmd` and `control`; the canonical one is used so the output
    /// is one stable vocabulary.
    private static let modifierWords: [String: String] = [
        "ctrl": "ctrl", "control": "ctrl", "alt": "alt", "meta": "alt", "opt": "alt",
        "option": "alt", "shift": "shift", "super": "super", "cmd": "super",
    ]

    private static func modifiers(_ parts: [String]) -> [String]? {
        guard !parts.isEmpty else { return nil }
        var result: [String] = []
        for part in parts {
            guard let word = modifierWords[part.lowercased()] else { return nil }
            if !result.contains(word) { result.append(word) }
        }
        return result
    }

    // MARK: Keys

    /// A one-scalar key: a letter, digit or literal punctuation as itself,
    /// the space bar as `space`.
    private static func character(_ key: String, original: String) throws -> String {
        guard let character = key.first, character.isASCII else { throw unsupported(original) }
        if character == " " { return "space" }
        if character == "\\" { return "backslash" }
        if character.isLowercase && character.isLetter { return key }
        if character.isNumber { return key }
        if literalPunctuation.contains(character) { return key }
        // Capitals, shifted symbols, `+ " : % &`, control characters.
        throw unsupported(original)
    }

    /// A multi-character name without modifiers.
    private static func namedKey(_ lowered: String, original: String) throws -> String {
        if sameNames.contains(lowered) { return lowered }
        if let alias = aliases[lowered] { return alias }
        if let literal = punctuationNames[lowered] { return literal }
        if unsupportedNames.contains(lowered) { throw unsupported(original) }
        throw invalid(original)
    }

    /// The base of a chord. `ctrl+i` and `ctrl+m` are Tab and Enter (core
    /// takes them as `tab`, `enter`), `ctrl+[` is Escape: core refuses all
    /// three, and so does `ctrl+shift+<letter>`.
    private static func chordBase(
        _ base: String, modifiers: [String], original: String
    ) throws -> String {
        if base.unicodeScalars.count == 1 {
            guard let character = base.first, character.isASCII else { throw unsupported(original) }
            let lowered = Character(character.lowercased())
            if modifiers.contains("ctrl") {
                if lowered == "i" || lowered == "m" || lowered == "[" { throw unsupported(original) }
                if modifiers.contains("shift") && lowered.isLetter { throw unsupported(original) }
            }
            if character == " " { return "space" }
            if character == "\\" { return "backslash" }
            if lowered.isLetter || lowered.isNumber || literalPunctuation.contains(lowered) {
                return String(lowered)
            }
            throw unsupported(original)
        }
        let lowered = base.lowercased()
        if sameNames.contains(lowered) { return lowered }
        if let alias = aliases[lowered] { return alias }
        if let literal = punctuationNames[lowered] {
            return try chordBase(literal, modifiers: modifiers, original: original)
        }
        if unsupportedNames.contains(lowered) { throw unsupported(original) }
        throw invalid(original)
    }

    private static func invalid(_ key: String) -> HerdrAPIError {
        HerdrAPIError(code: invalidKeyCode, message: "unknown key name: \(key)")
    }

    private static func unsupported(_ key: String) -> HerdrAPIError {
        HerdrAPIError(
            code: unsupportedCode,
            message: "herdr-core cannot send the key \"\(key)\" by name.")
    }
}
