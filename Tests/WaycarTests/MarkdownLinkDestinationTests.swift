import Foundation
import Testing

@testable import Waycar

/// Links inside a rendered Markdown preview (#147) come from a remote-chosen
/// file, so resolution is an allowlist: web links, in-document anchors and
/// Host file paths as written; everything else is refused.
@Suite("Markdown link destination")
struct MarkdownLinkDestinationTests {
    @Test func webSchemesOpenAsWebLinksWhateverTheirCase() throws {
        for link in ["https://example.com/a?b=1#c", "http://example.com", "mailto:me@example.com", "HTTPS://EXAMPLE.COM"] {
            let url = try #require(URL(string: link))
            #expect(resolve(link) == .web(url), "\(link)")
        }
    }

    @Test func everyOtherSchemeIsRefused() {
        for link in [
            "javascript:alert(1)", "JavaScript:alert(1)", "file:///etc/passwd", "data:text/html;base64,PGI+eDwvYj4=",
            "tel:+15555550100", "waycar://pair?code=1", "ssh://host/x", "ftp://example.com/f",
        ] {
            #expect(resolve(link) == nil, "\(link)")
        }
    }

    @Test func webLinksWithoutAHostAndMailWithoutAnAddressAreRefused() {
        for link in ["https:example.com", "http:///x", "https://", "mailto:", "mailto:?subject=hi", "mailto:%20"] {
            #expect(resolve(link) == nil, "\(link)")
        }
    }

    @Test func networkPathAndEmptyLinksAreRefused() {
        #expect(resolve("//evil.example.com/x.md") == nil)
        #expect(resolve("#") == nil)
        #expect(resolve("?only=query") == nil)
        #expect(resolve("#%F0%9F%8E%89") == nil)
    }

    @Test func fragmentOnlyLinksBecomeHeadingSlugs() {
        #expect(resolve("#install") == .anchor("install"))
        #expect(resolve("#Title%20Here") == .anchor("title-here"))
        #expect(resolve("#Getting-Started!") == .anchor("getting-started"))
        #expect(resolve("#title-1") == .anchor("title-1"))
    }

    @Test func pathsComeBackAsWrittenForTheResolverToJoin() {
        #expect(resolve("spec.md") == .hostFile("spec.md"))
        #expect(resolve("./api/v2.md") == .hostFile("./api/v2.md"))
        #expect(resolve("../README.md") == .hostFile("../README.md"))
        #expect(resolve("a/../../b/./c.md") == .hostFile("a/../../b/./c.md"))
        #expect(resolve("/etc/hosts") == .hostFile("/etc/hosts"))
        #expect(resolve("~/notes/todo.md") == .hostFile("~/notes/todo.md"))
    }

    @Test func pathsArePercentDecodedWithQueryAndFragmentDropped() {
        #expect(resolve("my%20notes/caf%C3%A9.md") == .hostFile("my notes/café.md"))
        #expect(resolve("spec.md?plain=1#usage") == .hostFile("spec.md"))
        #expect(resolve("../README.md#install") == .hostFile("../README.md"))
    }

    @Test func pathsDecodingToControlOrFormatCharactersAreRefused() {
        for link in [
            "a%0Ab.md", "a%00b.md", "a%1Bb.md", "%E2%80%AEdm.exe", "a%E2%80%8Bb.md", "a%E2%81%A6b.md",
        ] {
            #expect(resolve(link) == nil, "\(link)")
        }
    }

    /// The path as written is joined onto the document's directory by the
    /// same resolver a printed path goes through; `..` cannot climb past `/`.
    @Test func writtenPathsResolveAgainstTheDocumentDirectory() {
        let directory = "/Users/me/repo/docs"
        func resolved(_ link: String) -> String? {
            guard case .hostFile(let path)? = resolve(link) else { return nil }
            return TerminalPathResolver.resolve(path, workingDirectory: directory, homeDirectory: "/Users/me")
        }
        #expect(resolved("spec.md") == "/Users/me/repo/docs/spec.md")
        #expect(resolved("../README.md#install") == "/Users/me/repo/README.md")
        #expect(resolved("a/../../b/./c.md") == "/Users/me/repo/b/c.md")
        #expect(resolved("../../../../../../etc/hosts") == "/etc/hosts")
        #expect(resolved("~/notes/../plan.md") == "/Users/me/plan.md")
        #expect(TerminalPathResolver.resolve("../../x.md", workingDirectory: "/a", homeDirectory: nil) == "/x.md")
    }

    private func resolve(_ link: String) -> MarkdownLinkDestination? {
        guard let url = URL(string: link) else {
            Issue.record("unparseable test link \(link)")
            return nil
        }
        return MarkdownLinkDestination.resolve(url)
    }
}
