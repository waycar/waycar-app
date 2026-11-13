import Testing

@testable import Waycar

@MainActor
@Suite("Natural voice model store")
struct NaturalVoiceModelStoreTests {
    actor Reader {
        private(set) var requests = 0
        private var waiting: [Int: CheckedContinuation<NaturalVoiceModelStore.Snapshot, Never>] = [:]

        func read() async -> NaturalVoiceModelStore.Snapshot {
            requests += 1
            let request = requests
            return await withCheckedContinuation { waiting[request] = $0 }
        }

        func respond(_ request: Int, with snapshot: NaturalVoiceModelStore.Snapshot) {
            waiting.removeValue(forKey: request)?.resume(returning: snapshot)
        }
    }

    @Test func refreshPublishesDiskProjectionWithoutClaimingDownloadOwnership() async throws {
        let reader = Reader()
        let store = NaturalVoiceModelStore(readSnapshot: { await reader.read() })
        store.refresh()
        try await waitUntil { await reader.requests == 1 }
        #expect(store.busyModel == nil)
        #expect(!store.isDownloading)
        let voice = NaturalVoiceOption(id: "voice", name: "Voice", accent: "")
        await reader.respond(1, with: .init(
            phases: [.pocket: .installed(bytes: 123), .kokoro: .absent],
            voices: [.pocket: [voice]], freed: [.pocket: 100], download: [.pocket: 456], total: 123))
        try await waitUntil { store.totalBytes == 123 }
        #expect(store.isInstalled(.pocket))
        #expect(store.phase(.kokoro) == .absent)
        #expect(store.phase(.paradee) == .checking)
        #expect(store.voices[.pocket] == [voice])
        #expect(store.freedBytes[.pocket] == 100)
        #expect(store.downloadBytes[.pocket] == 456)
    }

    @Test func overlappingRefreshesKeepTheNewestSnapshotDemand() async throws {
        let reader = Reader()
        let store = NaturalVoiceModelStore(readSnapshot: { await reader.read() })
        store.refresh()
        try await waitUntil { await reader.requests == 1 }
        store.refresh()
        try await waitUntil { await reader.requests == 2 }
        await reader.respond(1, with: .init(total: 100))
        await reader.respond(2, with: .init(total: 200))
        try await waitUntil { store.totalBytes == 200 }
        #expect(!store.isDownloading)
        #expect(store.busyModel == nil)
    }
}
