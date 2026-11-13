import Foundation

/// Zellij's session-scoped terminal address and the app's synthetic topology ids.
/// Control characters and leading '-' are not app targets: ls cannot frame the former,
/// and attach's positional session argument cannot represent the latter.
struct ZellijPaneID: Sendable, Hashable, CustomStringConvertible {
    let session: String
    let pane: Int

    init?(session: String, pane: Int) {
        guard Self.isSessionName(session), pane >= 0, UInt32(exactly: pane) != nil else { return nil }
        self.session = session
        self.pane = pane
    }

    init?(_ text: String) {
        guard text.hasPrefix("zellij:"), let slash = text.lastIndex(of: "/") else { return nil }
        let session = String(text[text.index(text.startIndex, offsetBy: 7)..<slash])
        let terminal = text[text.index(after: slash)...]
        guard terminal.hasPrefix("terminal_") else { return nil }
        let digits = terminal.dropFirst(9)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
            let pane = Int(digits), String(pane) == digits
        else { return nil }
        self.init(session: session, pane: pane)
    }

    static func isSessionName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.contains("/")
            && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    var rawPane: String { "terminal_\(pane)" }
    var description: String { "zellij:\(session)/\(rawPane)" }
    var workspaceID: String { Self.workspace(session: session) }
    static func workspace(session: String) -> String { "zellij:\(session)" }
    static func tab(session: String, id: Int) -> String { "zellij:\(session)/tab_\(id)" }
    func terminalID(generation: UInt64) -> String { description + "@\(generation)" }
    var fileName: String {
        Data(description.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "") + ".json"
    }
}
