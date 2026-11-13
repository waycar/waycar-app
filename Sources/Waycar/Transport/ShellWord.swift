import Foundation

/// One argument as herdr and tmux launch lines write it: bare when it holds
/// only `[A-Za-z0-9@%_+=:,./-]`, else POSIX single-quoted with each `'`
/// written `'\''`.
enum ShellWord {
    static func quoted(_ text: String) -> String {
        isBare(text) ? text : "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Non-empty and `[A-Za-z0-9@%_+=:,./-]` only.
    static func isBare(_ text: String) -> Bool {
        !text.isEmpty
            && text.unicodeScalars.allSatisfy { scalar in
                scalar.isASCII
                    && (CharacterSet.alphanumerics.contains(scalar) || "@%_+=:,./-".unicodeScalars.contains(scalar))
            }
    }
}
