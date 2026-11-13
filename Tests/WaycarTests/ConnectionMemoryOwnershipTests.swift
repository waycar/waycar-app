import Foundation
import Testing

@testable import Waycar

@Suite("Connection memory ownership")
struct ConnectionMemoryOwnershipTests {
    @Test func factsMergeAndSurviveReloadWithoutChangingTheEnvelope() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        let cache = ConsoleInventoryCache(directory: directory)
        let memory = cache.connectionMemory(for: host)
        memory.rememberHomeDirectory("/home/dev")
        memory.rememberProtocolVersion(22)
        memory.rememberLoginPATH("/usr/bin")
        cache.flush()

        let reloaded = ConsoleInventoryCache(directory: directory).connectionMemory(for: host)
        #expect(reloaded.homeDirectory == "/home/dev")
        #expect(reloaded.protocolVersion == 22)
        #expect(reloaded.loginPATH == "/usr/bin")
        let bytes = try Data(contentsOf: cache.connectionFileURL(for: host.id))
        let envelope = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(envelope.keys) == ["version", "hostID", "target", "facts"])
        #expect(envelope["version"] as? Int == 1)
    }

    /// B-21: a memory retained by the old connection may finish after the
    /// replacement has remembered its home, protocol and login PATH.
    @Test func lateOldTargetWritesCannotReplaceNewFacts() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        var other = host
        other.address = "other"
        let cache = ConsoleInventoryCache(directory: directory)
        let old = cache.connectionMemory(for: host)
        old.rememberHomeDirectory("/old")
        let current = cache.connectionMemory(for: other)
        current.rememberHomeDirectory("/new")
        current.rememberProtocolVersion(23)
        current.rememberLoginPATH("/new/bin")
        old.rememberHomeDirectory("/late")
        old.rememberProtocolVersion(1)
        old.rememberLoginPATH("/late/bin")
        #expect(current.homeDirectory == "/new")
        #expect(current.protocolVersion == 23)
        #expect(current.loginPATH == "/new/bin")
        #expect(old.homeDirectory == nil)
        cache.flush()
        let reloaded = ConsoleInventoryCache(directory: directory).connectionMemory(for: other)
        #expect(reloaded.homeDirectory == "/new")
        #expect(reloaded.protocolVersion == 23)
        #expect(reloaded.loginPATH == "/new/bin")
    }

    @Test func readingAnotherTargetDoesNotEraseTheKeptFacts() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = Host.fixture()
        var other = host
        other.address = "other"
        let cache = ConsoleInventoryCache(directory: directory)
        cache.connectionMemory(for: host).rememberProtocolVersion(22)
        #expect(cache.connectionMemory(for: other).protocolVersion == nil)
        #expect(cache.connectionMemory(for: host).protocolVersion == 22)
        cache.flush()
    }
}
