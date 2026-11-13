import Foundation

/// Where a link inside a bundled help page goes. The pages are first-party,
/// written for waycar.dev, so their links are site-relative: other help
/// pages open in the app, everything else on the web.
enum HelpLinkDestination: Equatable, Sendable {
    /// `/help/<slug>`, optionally with `#anchor`: another help page. The
    /// anchor is slugged like ``MarkdownBlock`` heading anchors.
    case page(slug: String, anchor: String?)
    /// `#anchor`: a heading on the same page.
    case anchor(String)
    /// `https`/`http` and `mailto:` links as written; other site paths
    /// (`/pricing`, `/privacy`, `/support`, `/help`) made absolute on
    /// ``HelpWeb/base``.
    case external(URL)

    /// Nil for anything else: other schemes (`file:`, `javascript:`, …), a
    /// web link without a host, a `mailto:` without an address, relative or
    /// network-path (`//host`) references, and empty links.
    static func resolve(_ url: URL) -> HelpLinkDestination? {
        if let scheme = url.scheme?.lowercased() {
            switch scheme {
            case "http", "https":
                guard let host = url.host(), !host.isEmpty else { return nil }
                return .external(url)
            case "mailto":
                let address = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
                return address.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .external(url)
            default:
                return nil
            }
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.host == nil
        else { return nil }
        let fragment = MarkdownDocument.slug(components.fragment ?? "")
        let anchor = fragment.isEmpty ? nil : fragment
        let path = components.path

        guard !path.isEmpty else { return anchor.map(HelpLinkDestination.anchor) }
        // Site paths only: relative references have no page to resolve
        // against, and `//host/…` never reaches here (it parses a host).
        guard path.hasPrefix("/") else { return nil }

        if path.hasPrefix("/help/") {
            var slug = String(path.dropFirst("/help/".count))
            if slug.hasSuffix("/") { slug.removeLast() }
            // The page's Markdown twin is the same page.
            if slug.hasSuffix(".md") { slug.removeLast(3) }
            if HelpWeb.isSlug(slug) { return .page(slug: slug, anchor: anchor) }
        }

        var site = URLComponents()
        site.scheme = HelpWeb.base.scheme
        site.host = HelpWeb.base.host()
        site.percentEncodedPath = components.percentEncodedPath
        site.percentEncodedQuery = components.percentEncodedQuery
        site.percentEncodedFragment = components.percentEncodedFragment
        return site.url.map(HelpLinkDestination.external)
    }
}
