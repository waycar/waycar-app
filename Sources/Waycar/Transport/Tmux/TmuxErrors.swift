import Foundation

/// tmux error text to the errors the UI already branches on (design §4.3).
///
/// Command failures become `HerdrAPIError`s with herdr's codes where the
/// meaning matches: the Console, Close, Rename and Closed Sessions flows
/// test `pane_not_found` and `workspace_not_found`, and herdr's
/// `tab_not_found` is the window case. Anything else is `tmux_error` with
/// tmux's own text. Text that means the server or its connection is gone is
/// a `TransportError` instead, so EventsSession's reconnect path sees it.
enum TmuxErrors {
    /// The code for an error herdr has no counterpart for.
    static let genericCode = "tmux_error"

    /// tmux's `can't find …` text (3.2–3.7: `can't find pane: %9`) to herdr
    /// codes. Matched case-sensitively, anywhere in the text.
    private static func notFoundCode(_ message: String) -> String? {
        if message.contains("can't find pane") { return "pane_not_found" }
        if message.contains("can't find window") { return "tab_not_found" }
        if message.contains("can't find session") { return "workspace_not_found" }
        return nil
    }

    /// Text that says no server answers, or that it went away mid-command.
    /// tmux prints `no server running on <socket>`, `error connecting to
    /// <socket> (No such file or directory)`, `server exited unexpectedly`
    /// and `lost server`.
    private static let connectionTexts = [
        "no server running",
        "error connecting to",
        "server exited unexpectedly",
        "lost server",
    ]

    /// The `HerdrAPIError` for a failed command's error text.
    static func apiError(_ text: String) -> HerdrAPIError {
        let message = trimmed(text)
        let code = notFoundCode(message) ?? genericCode
        return HerdrAPIError(code: code, message: message)
    }

    /// The `HerdrAPIError` for an `%error` reply: its lines joined.
    static func apiError(reply: TmuxReply) -> HerdrAPIError {
        apiError(reply.lines.joined(separator: "\n"))
    }

    /// Shells' spellings of a missing `tmux`: bash, dash, zsh, fish.
    private static let missingBinaryTexts = [
        "tmux: command not found",
        "tmux: not found",
        "command not found: tmux",
        "Unknown command: tmux",
    ]

    /// The connection-level `TransportError` the text describes, or nil
    /// when it is an ordinary command failure. A shell's report of a
    /// missing `tmux` binary is `TransportError.tmuxNotInstalled`.
    static func transportError(_ text: String) -> TransportError? {
        let message = trimmed(text)
        if missingBinaryTexts.contains(where: { message.contains($0) }) {
            return .tmuxNotInstalled
        }
        guard connectionTexts.contains(where: { message.contains($0) }) else { return nil }
        return .channelFailed(detail: "tmux: \(message)")
    }

    /// The error a caller throws for tmux's text: the connection-level
    /// `TransportError` when there is one, the `HerdrAPIError` otherwise.
    static func error(_ text: String) -> any Error {
        if let transport = transportError(text) { return transport }
        return apiError(text)
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
