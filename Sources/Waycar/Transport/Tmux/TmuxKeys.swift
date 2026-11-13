import Foundation

/// One key as tmux receives it: a key name for `send-keys`, or raw bytes for
/// `send-keys -H`.
enum TmuxKeyStroke: Sendable, Equatable {
    case named(String)
    case bytes([UInt8])
}

/// Maps the key names Waycar sends to herdr (`agent.send_keys`,
/// `pane.send_input`) onto tmux keys.
///
/// The app sends `enter` (Composer submit, Blocked Allow) and `esc`
/// (Blocked Cancel); herdr also takes `ctrl+c`/`C-c` style chords,
/// case-insensitively. The table covers those spellings plus the Agent
/// Toolbar's key names (`shiftTab`, `forwardDelete`, `pageUp`, …), so the
/// same strings work for either backend. Every name is checked here because
/// tmux types an unknown key name literally instead of failing (T20).
enum TmuxKeys {
    /// The tmux stroke for one herdr key name. Throws
    /// `HerdrAPIError(code: "invalid_key")`, herdr's own code, for a name
    /// with no mapping.
    static func stroke(for key: String) throws -> TmuxKeyStroke {
        guard let stroke = parse(key) else {
            throw HerdrAPIError(code: "invalid_key", message: "unknown key name: \(key)")
        }
        return stroke
    }

    /// ``stroke(for:)`` for each key, in order; throws before mapping
    /// anything partially.
    static func strokes(for keys: [String]) throws -> [TmuxKeyStroke] {
        try keys.map(stroke(for:))
    }

    /// One `send-keys` command per stroke, in order: names through
    /// ``TmuxCommand/sendKeys(target:keys:)``, bytes through
    /// ``TmuxCommand/sendKeysHex(target:bytes:)``.
    static func commands(target: String, keys: [String]) throws -> [String] {
        try strokes(for: keys).map { stroke in
            switch stroke {
            case .named(let name):
                TmuxCommand.sendKeys(target: target, keys: [name])
            case .bytes(let bytes):
                TmuxCommand.sendKeysHex(target: target, bytes: bytes)
            }
        }
    }

    // MARK: Parsing

    private struct Modifiers: OptionSet {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1)
        static let meta = Modifiers(rawValue: 2)
        static let shift = Modifiers(rawValue: 4)
    }

    /// Unmodified names, lowercased and with `_` and spaces removed, to tmux
    /// key names. `-` is kept: `C-r` must never read as `cr`.
    private static let namedKeys: [String: String] = [
        "enter": "Enter", "return": "Enter", "cr": "Enter",
        "esc": "Escape", "escape": "Escape",
        "tab": "Tab",
        "btab": "BTab", "backtab": "BTab", "shifttab": "BTab",
        "backspace": "BSpace", "bspace": "BSpace", "bs": "BSpace",
        "delete": "DC", "del": "DC", "dc": "DC", "forwarddelete": "DC",
        "insert": "IC", "ins": "IC", "ic": "IC",
        "up": "Up", "down": "Down", "left": "Left", "right": "Right",
        "home": "Home", "end": "End",
        "pageup": "PPage", "pgup": "PPage", "ppage": "PPage",
        "pagedown": "NPage", "pgdn": "NPage", "pgdown": "NPage", "npage": "NPage",
        "space": "Space",
        "f1": "F1", "f2": "F2", "f3": "F3", "f4": "F4", "f5": "F5", "f6": "F6",
        "f7": "F7", "f8": "F8", "f9": "F9", "f10": "F10", "f11": "F11", "f12": "F12",
    ]

    private static func parse(_ key: String) -> TmuxKeyStroke? {
        guard !key.isEmpty else { return nil }
        // A single character is itself, whatever it is (`y`, `;`, `?`).
        if key.count == 1 {
            return .bytes(Array(key.utf8))
        }
        let lowered = key.lowercased()
        // Shift-Enter is a newline without submitting: LF, as the Agent
        // Toolbar's `shiftEnter` sends it.
        if ["shiftenter", "shift+enter", "s-enter", "shift+return"].contains(lowered) {
            return .bytes([0x0A])
        }
        if let name = namedKeys[normalized(lowered)] {
            return .named(name)
        }
        guard let (modifiers, base) = splitModifiers(key), !modifiers.isEmpty else { return nil }
        return chord(modifiers: modifiers, base: base)
    }

    /// `ctrl+c`, `C-c`, `alt+x`, `meta+x`, `M-x`, `option+x`, `shift+up`,
    /// `S-Up`, combined in any order. herdr's `ctrl-c` spelling is not
    /// accepted there either.
    private static func splitModifiers(_ key: String) -> (Modifiers, String)? {
        var modifiers: Modifiers = []
        var rest = Substring(key)
        while true {
            let lowered = rest.lowercased()
            if let length = matchedPrefix(of: lowered, in: ["ctrl+", "control+", "c-"]) {
                modifiers.insert(.control)
                rest = rest.dropFirst(length)
            } else if let length = matchedPrefix(
                of: lowered, in: ["alt+", "meta+", "option+", "opt+", "m-"])
            {
                modifiers.insert(.meta)
                rest = rest.dropFirst(length)
            } else if let length = matchedPrefix(of: lowered, in: ["shift+", "s-"]) {
                modifiers.insert(.shift)
                rest = rest.dropFirst(length)
            } else {
                break
            }
        }
        guard !rest.isEmpty else { return nil }
        return (modifiers, String(rest))
    }

    private static func matchedPrefix(of lowered: String, in prefixes: [String]) -> Int? {
        prefixes.first { lowered.hasPrefix($0) }?.count
    }

    private static func chord(modifiers: Modifiers, base: String) -> TmuxKeyStroke? {
        if base.count == 1, let character = base.first {
            return characterChord(modifiers: modifiers, character: character)
        }
        let lowered = base.lowercased()
        guard let name = namedKeys[normalized(lowered)] else { return nil }
        if modifiers == .shift, name == "Tab" { return .named("BTab") }
        if modifiers == .shift, name == "Enter" { return .bytes([0x0A]) }
        return .named(prefix(modifiers) + name)
    }

    /// Letters take every modifier: `C-c` (Control folds case), `M-x` and
    /// `M-X` as written, shift as the capital. Other ASCII printables take
    /// Meta only, as ESC then the character.
    private static func characterChord(modifiers: Modifiers, character: Character) -> TmuxKeyStroke? {
        guard character.isASCII, let ascii = character.asciiValue, ascii >= 0x20, ascii < 0x7F
        else { return nil }
        if character.isLetter {
            var letter = String(character)
            var remaining = modifiers
            if remaining.contains(.shift) {
                remaining.remove(.shift)
                letter = letter.uppercased()
            } else if remaining.contains(.control) {
                letter = letter.lowercased()
            }
            guard !remaining.isEmpty else { return .bytes(Array(letter.utf8)) }
            return .named(prefix(remaining) + letter)
        }
        guard modifiers == .meta else { return nil }
        return .bytes([0x1B, ascii])
    }

    private static func prefix(_ modifiers: Modifiers) -> String {
        (modifiers.contains(.control) ? "C-" : "")
            + (modifiers.contains(.meta) ? "M-" : "")
            + (modifiers.contains(.shift) ? "S-" : "")
    }

    private static func normalized(_ lowered: String) -> String {
        lowered.filter { $0 != "_" && $0 != " " }
    }
}
