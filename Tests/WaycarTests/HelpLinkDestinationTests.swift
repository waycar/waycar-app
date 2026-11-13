import Foundation
import Testing

@testable import Waycar

/// Links inside a bundled help page are written for waycar.dev: other help
/// pages open in the app, site paths and web links open on the web, and
/// anything else is refused.
@Suite("Help link destination")
struct HelpLinkDestinationTests {
    @Test func helpPathsOpenThePageInTheApp() {
        #expect(resolve("/help/pairing") == .page(slug: "pairing", anchor: nil))
        #expect(resolve("/help/add-host-manually/") == .page(slug: "add-host-manually", anchor: nil))
        #expect(resolve("/help/pairing.md") == .page(slug: "pairing", anchor: nil))
    }

    @Test func helpPathsKeepTheirAnchorSluggedLikeHeadings() {
        #expect(resolve("/help/pairing#scan-the-code") == .page(slug: "pairing", anchor: "scan-the-code"))
        #expect(resolve("/help/pairing#Scan%20the%20Code") == .page(slug: "pairing", anchor: "scan-the-code"))
        #expect(resolve("/help/pairing#") == .page(slug: "pairing", anchor: nil))
    }

    @Test func fragmentsScrollTheSamePage() {
        #expect(resolve("#what-does-each-status-mean") == .anchor("what-does-each-status-mean"))
        #expect(resolve("#What%20Next") == .anchor("what-next"))
        #expect(resolve("#") == nil)
    }

    @Test func otherSitePathsOpenOnWaycarDev() {
        #expect(external("/pricing") == "https://waycar.dev/pricing")
        #expect(external("/privacy") == "https://waycar.dev/privacy")
        #expect(external("/support#email") == "https://waycar.dev/support#email")
        #expect(external("/help") == "https://waycar.dev/help")
        // Not a page slug: the site decides.
        #expect(external("/help/search.json") == "https://waycar.dev/help/search.json")
    }

    @Test func webAndMailLinksOpenAsWritten() throws {
        for link in ["https://herdr.dev/docs#install", "http://example.com", "HTTPS://EXAMPLE.COM", "mailto:support@waycar.dev"] {
            let url = try #require(URL(string: link))
            #expect(HelpLinkDestination.resolve(url) == .external(url), "\(link)")
        }
    }

    @Test func unsupportedLinksAreRefused() {
        // One row per refusal branch: unknown scheme, http(s) without a host,
        // empty and blank mailto, network-path reference, relative path.
        for link in [
            "javascript:alert(1)", "https://", "mailto:", "mailto:%20", "//evil.example/help/pairing", "pairing",
        ] {
            #expect(resolve(link) == nil, "\(link)")
        }
    }

    @Test func pageURLsLiveUnderWaycarDevHelp() {
        #expect(HelpWeb.pageURL("pairing")?.absoluteString == "https://waycar.dev/help/pairing")
        #expect(HelpWeb.pageURL("add-host-manually")?.absoluteString == "https://waycar.dev/help/add-host-manually")
        for slug in ["", "Pairing", "two words", "../etc", "a--b", "-a", "a-", "café"] {
            #expect(HelpWeb.pageURL(slug) == nil, "\(slug)")
        }
    }

    private func resolve(_ link: String) -> HelpLinkDestination? {
        URL(string: link).flatMap(HelpLinkDestination.resolve)
    }

    private func external(_ link: String) -> String? {
        guard case .external(let url) = resolve(link) else { return nil }
        return url.absoluteString
    }
}
