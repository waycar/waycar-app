import Foundation
import Testing

@testable import Waycar

/// Pins the session usage follower's overlaps (CONSOLE-23) through
/// `AgentSessionUsageStore`'s own API: which refresh owns the store, what
/// `clear()` does to one in flight, and how window lookups coalesce.
@MainActor
@Suite("Agent session usage lifecycle")
struct AgentSessionUsageLifecycleTests {
    /// A Host's files, shared by every read closure a test hands out.
    private final class Files: @unchecked Sendable {
        var byPath: [String: Data] = [:]
        var ranges: [RemoteFileRange] = []

        func append(_ line: String, to path: String) {
            var contents = byPath[path] ?? Data()
            contents.append(Data(line.utf8))
            contents.append(0x0A)
            byPath[path] = contents
        }

        func slice(_ range: RemoteFileRange) -> RemoteFileSlice {
            ranges.append(range)
            guard let contents = byPath[range.path] else {
                return RemoteFileSlice(data: Data(), length: nil)
            }
            guard range.offset < UInt64(contents.count) else {
                return RemoteFileSlice(data: Data(), length: UInt64(contents.count))
            }
            let start = contents.startIndex.advanced(by: Int(range.offset))
            let end = min(contents.endIndex, start + range.maxBytes)
            return RemoteFileSlice(data: contents[start..<end], length: UInt64(contents.count))
        }
    }

    private final class Lookups: @unchecked Sendable {
        var selectors: [String] = []
    }

    /// A one-shot latch a test can park a read on.
    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var opened = false
        private(set) var entered = false

        func wait() async {
            entered = true
            if opened { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    private static let path = "/home/dev/.omp/sessions/s.jsonl"

    private static func turn(provider: String = "p", model: String, cost: Double) -> String {
        #"{"type":"message","message":{"role":"assistant","stopReason":"endTurn","provider":"\#(provider)","model":"\#(model)","contextSnapshot":{"promptTokens":10000},"usage":{"cost":{"total":\#(cost)}}}}"#
    }

    private static func costs(_ store: AgentSessionUsageStore, _ expected: Double) -> Bool {
        guard let value = store.usage.cost else { return false }
        return abs(value - expected) < 1e-9
    }

    @Test("clear() does not end a refresh in flight: its read still folds")
    func clearLeavesTheRefreshInFlightCurrent() async throws {
        // Kept pre-existing race: clear() drops the totals but not the read
        // generation, so a refresh whose read is out folds its bytes into the
        // cleared store. The screen never meets it (it cancels the follower
        // before clearing), but the conversion keeps it as it is.
        let store = AgentSessionUsageStore()
        let files = Files()
        files.append(Self.turn(model: "m", cost: 0.5), to: Self.path)
        let gate = Gate()
        let read: (RemoteFileRange) async throws -> RemoteFileSlice = { range in
            await gate.wait()
            return files.slice(range)
        }
        let refresh = Task { @MainActor in await store.refresh(path: Self.path, read: read) }
        try await waitUntil { gate.entered }
        store.clear()
        #expect(store.usage.cost == nil)
        gate.open()
        await refresh.value
        #expect(Self.costs(store, 0.5))

        // The cleared store follows no path, so the next refresh starts over.
        let plain: (RemoteFileRange) async throws -> RemoteFileSlice = { files.slice($0) }
        await store.refresh(path: Self.path, read: plain)
        #expect(Self.costs(store, 0.5))
        #expect(files.ranges.last?.offset == 0)
    }

    @Test("a config answer landing after a newer refresh began is dropped, and so is its follow")
    func staleConfigAnswerIsDropped() async throws {
        let sessionPath = "/home/dev/.omp/agent/sessions/-work/s.jsonl"
        let configPath = "/home/dev/.omp/agent/config.yml"
        let files = Files()
        files.append(Self.turn(model: "m", cost: 0.25), to: sessionPath)
        files.byPath[configPath] = Data("composer:\n  tokenRate: true\n".utf8)
        let gate = Gate()
        let store = AgentSessionUsageStore()
        let gated: (RemoteFileRange) async throws -> RemoteFileSlice = { range in
            let slice = files.slice(range)
            await gate.wait()
            return slice
        }
        let older = Task { @MainActor in await store.refresh(path: sessionPath, read: gated) }
        try await waitUntil { gate.entered }

        // The newer refresh still finds the config unread and asks again.
        files.byPath[configPath] = Data("composer:\n  tokenRate: false\n".utf8)
        let plain: (RemoteFileRange) async throws -> RemoteFileSlice = { files.slice($0) }
        await store.refresh(path: sessionPath, read: plain)
        #expect(!store.showsTokenRate)
        #expect(Self.costs(store, 0.25))
        #expect(files.ranges.map(\.path) == [configPath, configPath, sessionPath])

        gate.open()
        await older.value
        #expect(!store.showsTokenRate)
        #expect(Self.costs(store, 0.25))
        #expect(files.ranges.count == 3)
    }

    @Test("a lookup for the selector already being looked up waits for nothing and asks nothing")
    func sameSelectorLookupOverlapsANewerRefresh() async throws {
        let files = Files()
        files.append(Self.turn(model: "m", cost: 0.1), to: Self.path)
        let lookups = Lookups()
        let gate = Gate()
        let store = AgentSessionUsageStore()
        let read: (RemoteFileRange) async throws -> RemoteFileSlice = { files.slice($0) }
        let read2: (RemoteFileRange) async throws -> RemoteFileSlice = { files.slice($0) }
        let read3: (RemoteFileRange) async throws -> RemoteFileSlice = { files.slice($0) }
        let gatedResolve: (String) async throws -> Int? = { selector in
            lookups.selectors.append(selector)
            await gate.wait()
            return 200_000
        }
        let resolve: (String) async throws -> Int? = { selector in
            lookups.selectors.append(selector)
            return 100_000
        }
        let resolve2: (String) async throws -> Int? = { selector in
            lookups.selectors.append(selector)
            return 100_000
        }
        let older = Task { @MainActor in
            await store.refresh(path: Self.path, read: read, resolveContextWindow: gatedResolve)
        }
        try await waitUntil { gate.entered }

        // The newer refresh sees the lookup out and leaves it alone.
        await store.refresh(path: Self.path, read: read2, resolveContextWindow: resolve)
        #expect(lookups.selectors == ["p/m"])
        #expect(store.contextWindow == nil)

        // The older answer belongs to a refresh that no longer owns the store.
        gate.open()
        await older.value
        #expect(store.contextWindow == nil)

        // So the model is still unknown and the next refresh asks.
        await store.refresh(path: Self.path, read: read3, resolveContextWindow: resolve2)
        #expect(lookups.selectors == ["p/m", "p/m"])
        #expect(store.contextWindow == 100_000)
    }

    @Test("an older lookup ending frees the lookup slot even while a newer one is out")
    func olderLookupEndingFreesTheNewerSelector() async throws {
        // Kept pre-existing race: the slot holds one selector and whichever
        // lookup ends empties it, so a third refresh asks about the selector
        // the second is still looking up.
        let files = Files()
        files.append(Self.turn(model: "first", cost: 0.1), to: Self.path)
        let lookups = Lookups()
        let firstGate = Gate()
        let secondGate = Gate()
        let store = AgentSessionUsageStore()
        let read1: (RemoteFileRange) async throws -> RemoteFileSlice = { files.slice($0) }
        let read2: (RemoteFileRange) async throws -> RemoteFileSlice = { files.slice($0) }
        let read3: (RemoteFileRange) async throws -> RemoteFileSlice = { files.slice($0) }
        let resolve1: (String) async throws -> Int? = { selector in
            lookups.selectors.append(selector)
            await firstGate.wait()
            return 1_000
        }
        let resolve2: (String) async throws -> Int? = { selector in
            lookups.selectors.append(selector)
            await secondGate.wait()
            return 2_000
        }
        let resolve3: (String) async throws -> Int? = { selector in
            lookups.selectors.append(selector)
            return 3_000
        }
        let first = Task { @MainActor in
            await store.refresh(path: Self.path, read: read1, resolveContextWindow: resolve1)
        }
        try await waitUntil { firstGate.entered }

        files.append(Self.turn(model: "second", cost: 0.1), to: Self.path)
        let second = Task { @MainActor in
            await store.refresh(path: Self.path, read: read2, resolveContextWindow: resolve2)
        }
        try await waitUntil { secondGate.entered }
        #expect(lookups.selectors == ["p/first", "p/second"])

        firstGate.open()
        await first.value
        #expect(store.contextWindow == nil)

        await store.refresh(path: Self.path, read: read3, resolveContextWindow: resolve3)
        #expect(lookups.selectors == ["p/first", "p/second", "p/second"])
        #expect(store.contextWindow == 3_000)

        secondGate.open()
        await second.value
        #expect(store.contextWindow == 3_000)
    }

    @Test("a cancelled refresh's window answer is not remembered, and its slot is freed")
    func cancelledLookupIsNotRemembered() async throws {
        let files = Files()
        files.append(Self.turn(model: "m", cost: 0.1), to: Self.path)
        let lookups = Lookups()
        let gate = Gate()
        let store = AgentSessionUsageStore()
        let read1: (RemoteFileRange) async throws -> RemoteFileSlice = { files.slice($0) }
        let read2: (RemoteFileRange) async throws -> RemoteFileSlice = { files.slice($0) }
        let gatedResolve: (String) async throws -> Int? = { selector in
            lookups.selectors.append(selector)
            await gate.wait()
            return 200_000
        }
        let resolve: (String) async throws -> Int? = { selector in
            lookups.selectors.append(selector)
            return 100_000
        }
        let refresh = Task { @MainActor in
            await store.refresh(path: Self.path, read: read1, resolveContextWindow: gatedResolve)
        }
        try await waitUntil { gate.entered }
        refresh.cancel()
        gate.open()
        await refresh.value
        #expect(store.contextWindow == nil)

        await store.refresh(path: Self.path, read: read2, resolveContextWindow: resolve)
        #expect(lookups.selectors == ["p/m", "p/m"])
        #expect(store.contextWindow == 100_000)
    }

    @Test("a failed or missing read still lets the refresh size its model")
    func lookupFollowsAFailedOrVanishedRead() async {
        let files = Files()
        files.append(Self.turn(model: "m", cost: 0.1), to: Self.path)
        let lookups = Lookups()
        let store = AgentSessionUsageStore()
        let read: (RemoteFileRange) async throws -> RemoteFileSlice = { files.slice($0) }
        let resolve: (String) async throws -> Int? = { selector in
            lookups.selectors.append(selector)
            return nil
        }
        await store.refresh(path: Self.path, read: read, resolveContextWindow: resolve)
        #expect(lookups.selectors == ["p/m"])

        // A failing tail read keeps the totals and the remembered answer.
        let failing: (RemoteFileRange) async throws -> RemoteFileSlice = { _ in
            throw TransportError.timedOut
        }
        let resolve2: (String) async throws -> Int? = { selector in
            lookups.selectors.append(selector)
            return 1
        }
        await store.refresh(path: Self.path, read: failing, resolveContextWindow: resolve2)
        #expect(lookups.selectors == ["p/m"])
        #expect(store.contextText == "10K")

        // A vanished file drops the totals and the displayed window.
        files.byPath[Self.path] = nil
        let read2: (RemoteFileRange) async throws -> RemoteFileSlice = { files.slice($0) }
        await store.refresh(path: Self.path, read: read2, resolveContextWindow: resolve2)
        #expect(store.usage.cost == nil)
        #expect(store.contextWindow == nil)
        #expect(lookups.selectors == ["p/m"])
    }
}
