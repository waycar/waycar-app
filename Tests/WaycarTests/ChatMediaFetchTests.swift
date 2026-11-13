import Foundation
import Testing

@testable import Waycar

/// What `ConsoleStore.chatMediaFile(for:agent:)` keeps on the device: only
/// content-addressed media come from the cache; a Host file a reply's text
/// names is read again on every load, since the file at a path can change.
@MainActor
@Suite("Chat media fetches", .timeLimit(.minutes(1)))
struct ChatMediaFetchTests {
    nonisolated private static let first = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1])
    nonisolated private static let second = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 2])

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-chat-media-fetch-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func makeCacheDirectory() -> (URL, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "hm-chat-media-fetch-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (directory, { try? FileManager.default.removeItem(at: directory) })
    }

    /// A store with a media cache, connected to one Host running one Agent.
    private func connectedStore(
        _ transport: ScriptedTransport, defaults: UserDefaults, cacheDirectory: URL
    ) async throws -> (ConsoleStore, ConsoleAgent) {
        let host = Host.fixture()
        let store = ConsoleStore(
            snapshotRetryDelay: .milliseconds(10),
            pins: PinnedAgentsStore(defaults: defaults),
            unread: UnreadAgentsStore(defaults: defaults),
            chatMode: ChatModeStore(defaults: defaults),
            chatMediaCache: ChatMediaCache(directory: cacheDirectory)
        ) { _, _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the snapshot should verify the rows") {
            store.agents.count == 1 && !store.hostsAwaitingSnapshot.contains(host.id)
        }
        return (store, try #require(store.agents.first))
    }

    @Test func aHostFileTheTextNamesIsReadAgainOnEveryLoad() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (directory, removeDirectory) = makeCacheDirectory()
        defer { removeDirectory() }
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.setPreviewFileResponder { _, _ in Self.first }
        let (store, agent) = try await connectedStore(transport, defaults: defaults, cacheDirectory: directory)
        defer { store.setHosts([]) }
        let shot = ChatMedia(id: "ref:/tmp/shot.png", kind: .image, mime: nil, source: .hostFile(path: "/tmp/shot.png"))

        let before = try await store.chatMediaFile(for: shot, agent: agent)
        #expect(try Data(contentsOf: before) == Self.first)
        // The Agent overwrites the file at the same path.
        await transport.setPreviewFileResponder { _, _ in Self.second }
        let after = try await store.chatMediaFile(for: shot, agent: agent)

        #expect(await transport.previewFileReads.map(\.path) == ["/tmp/shot.png", "/tmp/shot.png"])
        #expect(try Data(contentsOf: after) == Self.second, "the new bytes, never a stale copy")
        #expect(after == before, "one scratch file per path, overwritten")
        #expect(after.lastPathComponent == "shot.png", "Quick Look titles the copy with the Host file's name")
        #expect(
            !after.standardizedFileURL.path(percentEncoded: false)
                .hasPrefix(directory.standardizedFileURL.path(percentEncoded: false)),
            "a path's bytes never enter the device cache")
    }

    @Test func theCopysNameIsTheHostNameThatFitsTheFileSystem() {
        #expect(ConsoleStore.displayName(forRemotePath: "/tmp/ad-02.PNG", pathExtension: "png") == "ad-02.PNG")
        #expect(ConsoleStore.displayName(forRemotePath: "/tmp/notes.md", pathExtension: "txt") == "notes.md.txt")
        #expect(ConsoleStore.displayName(forRemotePath: "/tmp/..", pathExtension: "png") == "file.png")
        let long = String(repeating: "é", count: 126) + ".png"  // 256 bytes
        #expect(ConsoleStore.displayName(forRemotePath: "/tmp/" + long, pathExtension: "png") == "file.png")
    }

    @Test func aBlobComesFromTheCacheAfterItsFirstRead() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (directory, removeDirectory) = makeCacheDirectory()
        defer { removeDirectory() }
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.setPreviewFileResponder { _, _ in Self.first }
        let (store, agent) = try await connectedStore(transport, defaults: defaults, cacheDirectory: directory)
        defer { store.setHosts([]) }
        let blob = ChatMedia(
            id: "blob:sha256:ab", kind: .image, mime: "image/png",
            source: .hostFile(path: "/Users/x/.omp/agent/blobs/ab"))

        let url = try await store.chatMediaFile(for: blob, agent: agent)
        await transport.setPreviewFileResponder { _, _ in Self.second }
        let again = try await store.chatMediaFile(for: blob, agent: agent)

        #expect(await transport.previewFileReads.count == 1)
        #expect(again == url)
        #expect(try Data(contentsOf: again) == Self.first)
    }

    /// A `.file` cached before file attachments went through the preview
    /// allowlist kept its own extension, so a web page would still open as
    /// one; it is fetched again once and stored as text, then served from
    /// the cache like any blob.
    @Test func aWebPageFileCachedUnderItsOwnExtensionIsFetchedAgainAsText() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let (directory, removeDirectory) = makeCacheDirectory()
        defer { removeDirectory() }
        let page = Data("<html><body>hi</body></html>".utf8)
        _ = try ChatMediaCache(directory: directory).store(page, for: "blob|blob:sha256:ab", pathExtension: "html")
        let transport = ScriptedTransport(snapshot: .fixture(agents: [.fixture(paneID: "w1:p1")]))
        await transport.setPreviewFileResponder { _, _ in page }
        let (store, agent) = try await connectedStore(transport, defaults: defaults, cacheDirectory: directory)
        defer { store.setHosts([]) }
        let file = ChatMedia(
            id: "blob:sha256:ab", kind: .file, mime: "text/html",
            source: .hostFile(path: "/Users/x/.omp/agent/blobs/ab"))

        let url = try await store.chatMediaFile(for: file, agent: agent)
        #expect(url.pathExtension == "txt")
        #expect(await transport.previewFileReads.count == 1)

        let again = try await store.chatMediaFile(for: file, agent: agent)
        #expect(again == url)
        #expect(await transport.previewFileReads.count == 1, "the text copy is served from the cache")
    }
}
