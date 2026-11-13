import Foundation
import Synchronization
import Testing

@testable import Waycar

/// Web chat media: which reply URLs become media at all, and what the
/// on-phone download (`ChatMediaWebDownload`) accepts, through a stub
/// protocol in the injected session configuration.
@Suite("Chat media on the web")
struct ChatMediaWebTests {
    // MARK: Download

    private static let cap = 16

    private func download(_ url: URL, maxBytes: Int = Self.cap) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubWebProtocol.self]
        return try await ChatMediaWebDownload.data(from: url, maxBytes: maxBytes, configuration: configuration)
    }

    /// A URL no other test routes, on a public-looking host.
    private func uniqueURL(host: String = "media.example.com", ext: String = "png") -> URL {
        URL(string: "https://\(host)/\(UUID().uuidString).\(ext)")!
    }

    @Test func anAnnouncedLengthOverTheCapIsTooLarge() async throws {
        let url = uniqueURL()
        StubWebProtocol.route(
            url, .respond(status: 200, headers: ["Content-Length": "\(Self.cap + 1)"], chunks: [Data(count: 4)]))
        await #expect(throws: ChatMediaError.tooLarge) { _ = try await download(url) }
    }

    @Test func anUnannouncedBodyOverTheCapIsTooLarge() async throws {
        let url = uniqueURL()
        let chunk = Data(repeating: 7, count: 8)
        StubWebProtocol.route(url, .respond(status: 200, headers: [:], chunks: [chunk, chunk, chunk]))
        await #expect(throws: ChatMediaError.tooLarge) { _ = try await download(url) }
    }

    @Test(arguments: [
        "http://media.example.com/a.png",
        "https://192.168.1.10/a.png",
        "https://localhost/a.png",
        "https://[fe80::1]/a.png",
    ])
    func aRedirectOffHTTPSOrToAPrivateHostIsUnavailable(target: String) async throws {
        let url = uniqueURL()
        let next = try #require(URL(string: target))
        StubWebProtocol.route(url, .redirect(to: next))
        StubWebProtocol.route(next, .respond(status: 200, headers: [:], chunks: [Data([1, 2, 3])]))
        await #expect(throws: ChatMediaError.unavailable) { _ = try await download(url) }
    }

    @Test func aNotFoundIsUnavailable() async throws {
        let url = uniqueURL()
        StubWebProtocol.route(url, .respond(status: 404, headers: [:], chunks: [Data("gone".utf8)]))
        await #expect(throws: ChatMediaError.unavailable) { _ = try await download(url) }
    }

    @Test func aBodyUnderTheCapArrivesExactly() async throws {
        let url = uniqueURL()
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
        StubWebProtocol.route(
            url,
            .respond(
                status: 200, headers: ["Content-Length": "\(bytes.count)"],
                chunks: [bytes.prefix(5), bytes.dropFirst(5)]))
        #expect(try await download(url) == bytes)
    }

    @Test func aPrivateInitialURLIsNeverRequested() async throws {
        let url = try #require(URL(string: "https://10.0.0.5/a.png"))
        await #expect(throws: ChatMediaError.unavailable) { _ = try await download(url) }
        #expect(!StubWebProtocol.wasRequested(url))
    }

    @Test func theDownloadSetsTheResourceTimeout() async throws {
        let url = uniqueURL()
        StubWebProtocol.route(url, .respond(status: 200, headers: [:], chunks: [Data([1])]))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubWebProtocol.self]
        _ = try await ChatMediaWebDownload.data(from: url, maxBytes: Self.cap, configuration: configuration)
        #expect(configuration.timeoutIntervalForResource == 120)
    }

    // MARK: References

    private func media(in text: String) -> [ChatMedia] {
        ChatMessageText.segments(of: text, rendersMedia: true).flatMap { segment -> [ChatMedia] in
            if case .media(let items, _) = segment { items } else { [] }
        }
    }

    private func prose(in text: String) -> String {
        ChatMessageText.segments(of: text, rendersMedia: true).compactMap { segment -> String? in
            if case .prose(let text) = segment { text } else { nil }
        }.joined(separator: "\n")
    }

    @Test(arguments: [
        "https://localhost/a.png",
        "https://cam.localhost/a.png",
        "https://printer.local/a.png",
        "https://intranet/a.png",
        "https://127.0.0.1/a.png",
        "https://127.1/a.png",
        "https://10.0.0.5/a.png",
        "https://192.168.1.10/a.png",
        "https://169.254.169.254/a.png",
        "https://[::1]/a.png",
        "https://[fd00::1]/a.png",
    ])
    func privateAndLiteralHostsMakeNoMediaAndStayText(source: String) {
        for text in [source, "![shot](\(source))", "See \(source) for it."] {
            #expect(media(in: text).isEmpty, "\(text)")
            #expect(prose(in: text).contains(source), "\(text)")
        }
    }

    @Test func aPublicHostIsMedia() {
        let found = media(in: "https://cdn.example.com/a.png")
        #expect(found.map(\.source) == [.web(URL(string: "https://cdn.example.com/a.png")!)])
        #expect(found.first?.loadsOnTap == true)
        #expect(found.first?.webHost == "cdn.example.com")
    }

    @Test func aMessageShowsAtMostTwelveItemsAndTheRestStayText() {
        let lines = (1...14).map { "https://cdn.example.com/\($0).png" }
        let text = lines.joined(separator: "\n")
        #expect(media(in: text).map(\.id) == lines.prefix(12).map { "ref:\($0)" })
        #expect(prose(in: text).contains(lines[12]))
        #expect(prose(in: text).contains(lines[13]))
    }

    @Test func theCapCountsTheWholeMessageAcrossCodeBlocks() {
        let before = (1...8).map { "https://cdn.example.com/a\($0).png" }
        let after = (1...8).map { "https://cdn.example.com/b\($0).png" }
        let text = (before + ["```", "code", "```"] + after).joined(separator: "\n")
        #expect(media(in: text).count == ChatMediaReferences.maximumPerMessage)
    }

    @Test func aRepeatedItemCountsOnce() {
        let lines = (1...12).map { "https://cdn.example.com/\($0).png" }
        let text = (lines + [lines[0]]).joined(separator: "\n")
        #expect(Set(media(in: text).map(\.id)).count == 12)
        #expect(!prose(in: text).contains(lines[0]), "an item already shown fits the cap")
    }
}

/// Serves scripted responses by absolute URL, for `ChatMediaWebDownload`'s
/// injected configuration. Tests route unique URLs, so they run in parallel.
final class StubWebProtocol: URLProtocol {
    enum Step: Sendable {
        case respond(status: Int, headers: [String: String], chunks: [Data])
        case redirect(to: URL)
    }

    private static let routes = Mutex<[String: Step]>([:])
    private static let requested = Mutex<Set<String>>([])

    static func route(_ url: URL, _ step: Step) {
        routes.withLock { $0[url.absoluteString] = step }
    }

    static func wasRequested(_ url: URL) -> Bool {
        requested.withLock { $0.contains(url.absoluteString) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.requested.withLock { _ = $0.insert(url.absoluteString) }
        guard let step = Self.routes.withLock({ $0[url.absoluteString] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        switch step {
        case .redirect(let target):
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        case .respond(let status, let headers, let chunks):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks {
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
