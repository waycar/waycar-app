import Foundation

/// Client-side mirror of the server's agent-name rule, shared by the
/// new-agent form (#12) and the rename sheet (#98) so the copy and the rule
/// cannot drift. The server enforces `^[a-z][a-z0-9_-]{0,31}$` and rejects
/// violations with `invalid_agent_name` (verified live against herdr 0.7.5);
/// validating here explains the rule before a round trip.
enum AgentName {
    /// Nil when `name` is an acceptable agent name; otherwise a user-facing
    /// message stating the rule. Empty is invalid here like on the server;
    /// callers intercept emptiness first when it carries meaning ("generate
    /// a default" on the start form, "clear back to the detected kind" on
    /// the rename sheet).
    static func validationError(_ name: String) -> String? {
        let message =
            "Agent names are 1–32 characters: lowercase letters, digits, "
            + "- or _, starting with a lowercase letter."
        guard !name.isEmpty, name.count <= 32 else { return message }
        for (offset, character) in name.enumerated() {
            guard character.unicodeScalars.count == 1,
                let scalar = character.unicodeScalars.first
            else { return message }
            switch scalar.value {
            case 0x61...0x7A:  // a-z
                continue
            case 0x30...0x39, 0x2D, 0x5F:  // 0-9, '-', '_'
                if offset == 0 { return message }
            default:
                return message
            }
        }
        return nil
    }

    /// Rewrites typed input toward the rule so the field never holds a
    /// character the server would reject for a reason the user could not
    /// see coming: uppercase is lowered, accents are folded, and spaces,
    /// punctuation and symbols become a single `-`. Other scripts are
    /// dropped, a leading `-` is dropped, and the result stops at 32
    /// characters. A leading digit or `_` is kept, so validation still
    /// explains that rule instead of silently eating the keystroke.
    ///
    /// A space becomes `-` the moment it is typed, so the field always shows
    /// what will be sent; a trailing `-` is dropped at submit instead.
    static func normalizingInput(_ input: String) -> String {
        let folded = input.folding(options: .diacriticInsensitive, locale: nil).lowercased()
        var result = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars {
            switch scalar.value {
            case 0x61...0x7A, 0x30...0x39, 0x5F:  // a-z, 0-9, '_'
                result.append(scalar)
            case _ where separators.contains(scalar):
                guard let last = result.last, last != "-" else { continue }
                result.append("-")
            default:
                continue
            }
        }
        return String(String(result).prefix(maxLength))
    }

    private static let maxLength = 32

    private static let separators = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)
}
