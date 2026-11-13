import Foundation
import Testing

@testable import Waycar

/// Public-owner safety nets, intentionally independent of the extracted machines.
@MainActor
struct ChatLifecycleCharacterizationTests {
    @Test func localMarkerGraceExpiresAtItsBoundaryAndRetirementSurvivesReload() throws {
        let suite = "chat-lifecycle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = UUID()
        let id = ConsoleAgent.ID(hostID: host, paneID: "pane")
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let marker = ChatModeMarker(
            paneID: id.paneID, terminalID: "terminal", kind: "claude", cwd: "/work",
            session: nil, launchedAt: now)
        let store = ChatModeStore(defaults: defaults, now: { now })
        store.record(marker, hostID: host)
        #expect(store.replaceMarkers([], for: host).rewrites == [marker])
        now += ChatModeStore.localRecordGrace
        #expect(store.replaceMarkers([], for: host).rewrites.isEmpty)
        #expect(store.marker(for: id) == nil)
        store.record(marker, hostID: host)
        store.retire(id)
        let reloaded = ChatModeStore(defaults: defaults, now: { now })
        #expect(reloaded.replaceMarkers([marker], for: host).deletes == [id.paneID])
        #expect(reloaded.marker(for: id) == nil)
    }

    @Test func versionOneMarkerBlobKeepsLocalGraceAndRetiredLaunches() throws {
        let suite = "chat-lifecycle-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let local = ChatModeMarker(
            paneID: "local", terminalID: "terminal", kind: "claude", cwd: "/work",
            session: .init(kind: "id", value: "session"), launchedAt: now)
        let markerJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(local))
        // The pre-conversion version-1 shape, including default Date encoding
        // for local-record and retirement timestamps (marker dates are ISO).
        let blob: [String: Any] = [
            "version": 1,
            "entries": [["hostID": host.uuidString, "marker": markerJSON,
                         "recordedAt": now.timeIntervalSinceReferenceDate]],
            "tombstones": [["hostID": host.uuidString, "paneID": "retired",
                            "launchedAt": now.timeIntervalSinceReferenceDate]],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: blob), forKey: ChatModeStore.defaultsKey)
        let store = ChatModeStore(defaults: defaults, now: { now })
        let retired = ChatModeMarker(
            paneID: "retired", terminalID: nil, kind: "claude", cwd: nil,
            session: nil, launchedAt: now)
        let repairs = store.replaceMarkers([retired], for: host)
        #expect(repairs.rewrites == [local])
        #expect(repairs.deletes == ["retired"])
        #expect(store.revision == 0, "repairs alone do not change the held markers")
        #expect(store.marker(for: .init(hostID: host, paneID: "local")) == local)
    }

    @Test func missingCacheThenRepeatedSavesKeepNewestMemoryAndDiskInVersionThree() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatTranscriptCache(directory: directory)
        let key = ChatTranscriptCache.Key(hostID: UUID(), paneID: "pane", terminalID: "terminal", launchedAt: "launch")
        let first = ChatTranscriptMessage(id: "1", role: .assistant, text: "first", timestamp: nil)
        let newest = ChatTranscriptMessage(id: "2", role: .assistant, text: "newest", timestamp: nil)
        #expect(cache.messages(for: key).isEmpty)
        cache.save([first], for: key, identity: "session")
        cache.save([first, newest], for: key, identity: "session")
        #expect(cache.messages(for: key, identity: "session") == [first, newest])
        #expect(cache.messages(for: key, identity: "other").isEmpty)
        cache.flush()
        let json = try #require(try JSONSerialization.jsonObject(
            with: Data(contentsOf: cache.fileURL(for: key))) as? [String: Any])
        #expect(json["version"] as? Int == 3)
        #expect(json["identity"] as? String == "session")
        #expect(json["terminalID"] as? String == key.terminalID)
        #expect(json["launchedAt"] as? String == key.launchedAt)
        #expect(ChatTranscriptCache(directory: directory).messages(for: key, identity: "session") == [first, newest])
    }

    @Test func cacheSaveRemoveSaveOrderingKeepsOnlyTheReplacement() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ChatTranscriptCache(directory: directory)
        let key = ChatTranscriptCache.Key(hostID: UUID(), paneID: "pane", terminalID: "terminal", launchedAt: "")
        let old = ChatTranscriptMessage(id: "1", role: .assistant, text: "old", timestamp: nil)
        let new = ChatTranscriptMessage(id: "2", role: .assistant, text: "new", timestamp: nil)
        cache.save([old], for: key)
        cache.flush()
        cache.remove(key)
        cache.flush()
        cache.save([new], for: key)
        #expect(cache.messages(for: key) == [new])
        cache.flush()
        #expect(ChatTranscriptCache(directory: directory).messages(for: key) == [new])
    }

    @Test func prefetchDeduplicatesUpdatesAndRetainsAttemptCooldownAfterCancel() async throws {
        let host = UUID()
        let agent = ConsoleAgent(
            hostID: host, hostName: "host",
            agent: Agent(terminalID: "t", kind: "claude", title: "Task", status: .done,
                         workspaceID: "w", tabID: "tab", paneID: "pane", cwd: "/", revision: 1),
            workspaceLabel: nil, repositoryCheckout: nil)
        var reads = 0
        let prefetcher = ChatTranscriptPrefetcher(source: .init(
            isActive: { true }, agents: { [agent] }, canRead: { _ in true }, savedAt: { _ in nil },
            fetch: { _ in reads += 1 }, now: { Date(timeIntervalSince1970: 1_800_000_000) },
            sleep: { _ in try await Task.sleep(for: .seconds(3600)) }))
        defer { prefetcher.cancel() }
        prefetcher.update()
        prefetcher.update()
        try await waitUntil("one prefetch") { reads == 1 }
        prefetcher.cancel()
        prefetcher.update()
        #expect(reads == 1)
    }
}
