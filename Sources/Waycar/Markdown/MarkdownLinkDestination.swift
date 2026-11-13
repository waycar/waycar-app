import Foundation

/// Where a link inside a rendered Markdown document may go (#147). The
/// document is remote-chosen, so this is an allowlist: web links and Host
/// file paths (each confirmed by the user before opening), in-document
/// anchors, and nothing else.
enum MarkdownLinkDestination: Equatable, Sendable {
    /// An `http` or `https` link ``TerminalLinkPolicy`` lets through, or a
    /// `mailto:` with an address.
    case web(URL)
    /// A fragment-only link, slugged like heading anchors.
    case anchor(String)
    /// A Host path as the document wrote it — relative, absolute or
    /// `~`-relative — percent-decoded, query and fragment dropped. It is
    /// resolved against the document's directory like a path printed in a
    /// pane, by ``TerminalPathResolver``.
    case hostFile(String)

    /// Nil when the link must be refused: `file:`, `javascript:`, `data:`,
    /// any other scheme, a web link with no host, a `mailto:` with no
    /// address, a network-path (`//host/…`) reference, nothing to go to, or
    /// a path that decodes to a control or format character — a newline,
    /// NUL, bidi override or zero-width space would make the path read
    /// differently from the one confirmed.
    static func resolve(_ url: URL) -> MarkdownLinkDestination? {
        if let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                return TerminalLinkPolicy.url(for: url.absoluteString).map(MarkdownLinkDestination.web)
            case "mailto":
                let address = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    .map { decoded($0.percentEncodedPath) } ?? ""
                return address.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .web(url)
            default:
                return nil
            }
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.host == nil
        else { return nil }
        let path = decoded(components.percentEncodedPath)
        guard !path.isEmpty else {
            let anchor = MarkdownDocument.slug(decoded(components.percentEncodedFragment ?? ""))
            return anchor.isEmpty ? nil : .anchor(anchor)
        }
        guard !TerminalLinkTarget.containsControlCharacter(path),
            !TerminalLinkTarget.containsFormatCharacter(path)
        else { return nil }
        return .hostFile(path)
    }

    private static func decoded(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }
}
