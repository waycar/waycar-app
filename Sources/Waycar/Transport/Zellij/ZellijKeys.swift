import Foundation

/// Waycar toolbar/herdr spellings to KeyWithModifier's whitespace-separated vocabulary (0.46).
enum ZellijKeys {
    static func names(for keys: [String]) throws -> [String] { try keys.map(name(for:)) }

    static func name(for key: String) throws -> String {
        guard !key.isEmpty else { throw invalid(key) }
        if ["shiftenter", "shift+enter", "s-enter", "shift+return", "⇧enter"].contains(key.lowercased()) {
            return "Ctrl j"
        }
        if let direct = base(key) { return direct }
        var rest = key
        var modifiers = Set<String>()
        let prefixes: [(String, String)] = [
            ("ctrl+", "Ctrl"), ("control+", "Ctrl"), ("c-", "Ctrl"),
            ("alt+", "Alt"), ("meta+", "Alt"), ("option+", "Alt"), ("opt+", "Alt"), ("m-", "Alt"),
            ("shift+", "Shift"), ("s-", "Shift"), ("super+", "Super"), ("cmd+", "Super"),
        ]
        while let prefix = prefixes.first(where: { rest.lowercased().hasPrefix($0.0) }) {
            modifiers.insert(prefix.1)
            rest = String(rest.dropFirst(prefix.0.count))
        }
        guard !modifiers.isEmpty, var name = base(rest) else { throw invalid(key) }
        if modifiers == ["Shift"], name == "Enter" { return "Ctrl j" }
        if modifiers.contains("Ctrl"), name.count == 1 { name = name.lowercased() }
        return (["Ctrl", "Alt", "Shift", "Super"].filter(modifiers.contains) + [name]).joined(separator: " ")
    }

    private static func base(_ key: String) -> String? {
        if key == " " { return "Space" }
        if key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first,
            !CharacterSet.controlCharacters.contains(scalar),
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
        {
            return key
        }
        let normalized = key.lowercased().filter { $0 != "_" && $0 != " " }
        if let number = Int(normalized.dropFirst()), normalized == "f\(number)", (1...12).contains(number) {
            return "F\(number)"
        }
        return aliases[normalized]
    }

    private static let aliases: [String: String] = [
        "enter": "Enter", "return": "Enter", "cr": "Enter", "esc": "Esc", "escape": "Esc",
        "tab": "Tab", "shifttab": "Shift Tab", "btab": "Shift Tab", "backtab": "Shift Tab",
        "backspace": "Backspace", "bspace": "Backspace", "bs": "Backspace",
        "delete": "Delete", "del": "Delete", "dc": "Delete", "forwarddelete": "Delete",
        "insert": "Insert", "ins": "Insert", "ic": "Insert", "home": "Home", "end": "End",
        "pageup": "PageUp", "pgup": "PageUp", "ppage": "PageUp",
        "pagedown": "PageDown", "pgdn": "PageDown", "pgdown": "PageDown", "npage": "PageDown",
        "up": "Up", "down": "Down", "left": "Left", "right": "Right", "space": "Space",
        "minus": "-", "plus": "+", "comma": ",", "period": ".", "slash": "/", "backslash": "\\",
        "quote": "'", "doublequote": "\"", "semicolon": ";", "colon": ":", "backtick": "`",
        "percent": "%", "ampersand": "&",
    ]

    private static func invalid(_ key: String) -> HerdrAPIError {
        HerdrAPIError(code: "invalid_key", message: "unknown key name: \(key)")
    }
}
