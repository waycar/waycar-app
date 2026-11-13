import Foundation
import ImageIO
import OSLog
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Each Agent's latest painted terminal frame, kept so entering the Agent
/// shows it under Ignition's Reconnecting veil instead of a cold loader:
/// on a tap from the list and on a cold launch that restores into the Agent
/// (#21, #27).
///
/// The `capacity` most recently captured Agents keep a frame, for at most
/// `maxAge`. Frames live in memory and under Caches (`AgentLastFrames/`),
/// one small JPEG per Agent plus an index, written with complete file
/// protection: unreadable while the device is locked, when the cache simply
/// misses. A frame names the connection target it was taken on, so an edited
/// Host never shows another herdr's screen. The in-memory index is the
/// truth; the disk mirrors it in order on one serial queue.
@MainActor
final class AgentLastFrameStore {
    /// A cached frame and the terminal size, in points, it was taken at.
    struct Frame {
        let image: UIImage
        let size: CGSize
    }

    struct Entry: Codable, Equatable, Sendable {
        let hostID: Host.ID
        let paneID: String
        let backend: HostBackend
        let target: ConsoleInventoryCache.Target
        let width: Double
        let height: Double
        let capturedAt: Date
        /// The image file's name in the store's directory; new per capture,
        /// so a write never races a read of the frame it replaces.
        let file: String

        var agentID: ConsoleAgent.ID { ConsoleAgent.ID(hostID: hostID, paneID: paneID) }
        var scope: ConsoleScope { ConsoleScope(hostID: hostID, backend: backend) }
    }

    private struct Index: Codable, Sendable {
        let version: Int
        let entries: [Entry]
    }

    /// The captured bitmap until its JPEG is encoded, then the JPEG.
    private enum Pixels {
        case captured(CapturedImage)
        case encoded(Data)
    }

    /// A `CGImage` is immutable once created, so handing it to the disk
    /// queue for encoding is safe.
    private struct CapturedImage: @unchecked Sendable {
        let image: CGImage
    }

    nonisolated static let capacity = 8
    nonisolated static let maxAge: TimeInterval = 24 * 60 * 60
    nonisolated static let jpegQuality: CGFloat = 0.6
    nonisolated static let formatVersion = 1
    nonisolated private static let indexName = "index.json"
    nonisolated private static let log = Logger(
        subsystem: "com.otreva.waycar", category: "AgentLastFrameStore")

    /// Nil keeps the cache in memory only.
    let directory: URL?
    private let now: () -> Date
    private let queue = DispatchQueue(label: "com.otreva.waycar.agent-last-frames")
    /// Most recent first; read once from disk on first use.
    private var entries: [Entry] = []
    private var pixels: [String: Pixels] = [:]
    /// The index has been read (or found missing). False while it exists
    /// but is unreadable: a CarPlay launch can start the app with the phone
    /// locked, and reading the `.complete` index as empty then would sweep
    /// every frame as an orphan. Until it loads, nothing is written or
    /// deleted on disk, and every use tries the read again.
    private var isLoaded = false
    /// The catalog `retainHosts` last asked for, applied once a deferred
    /// load lands.
    private var retainedTargets: [Host.ID: ConsoleInventoryCache.Target]?
    /// Pane removals while the index is unreadable apply to its old frames,
    /// not to fresh captures recorded after those removals.
    private var deferredDiscards: Set<ConsoleAgent.ID> = []
    private var deferredRetentions: [ConsoleScope: Set<ConsoleAgent.ID>] = [:]
    private let readIndex: @Sendable (URL) -> ConsoleInventoryCache.ReadResult

    init(
        directory: URL?, now: @escaping () -> Date = Date.init,
        readIndex: @escaping @Sendable (URL) -> ConsoleInventoryCache.ReadResult =
            ConsoleInventoryCache.FileAccess.live.read
    ) {
        self.directory = directory
        self.now = now
        self.readIndex = readIndex
    }

    /// The Agents holding a frame, most recently captured first.
    var cachedEntries: [Entry] {
        loadIfNeeded()
        return entries
    }

    /// The production store under Caches, or a memory-only one when Caches
    /// cannot be resolved.
    static func caches() -> AgentLastFrameStore {
        let base = try? FileManager.default.url(
            for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return AgentLastFrameStore(
            directory: base?.appending(path: "AgentLastFrames", directoryHint: .isDirectory))
    }

    /// `agent`'s cached frame, or nil when there is none it may show: none
    /// kept, older than `maxAge`, taken on another connection target than
    /// `host`'s, or unreadable (the device is locked).
    func frame(for agent: ConsoleAgent.ID, host: Host?) -> Frame? {
        loadIfNeeded()
        guard let host, let entry = entries.first(where: { $0.agentID == agent }) else { return nil }
        guard isFresh(entry), entry.target == ConsoleInventoryCache.Target(host) else {
            remove { $0.agentID == agent }
            return nil
        }
        let size = CGSize(width: entry.width, height: entry.height)
        switch pixels[entry.file] {
        case .captured(let captured):
            return Frame(image: UIImage(cgImage: captured.image), size: size)
        case .encoded(let data):
            return UIImage(data: data).map { Frame(image: $0, size: size) }
        case nil:
            guard let url = directory?.appending(path: entry.file) else { return nil }
            let read = queue.sync { () -> (data: Data?, exists: Bool) in
                let data = try? Data(contentsOf: url)
                return (data, data != nil || FileManager.default.fileExists(atPath: url.path))
            }
            guard let data = read.data, let image = UIImage(data: data) else {
                // A file that is there but unreadable is locked, not gone.
                if !read.exists || read.data != nil { remove { $0.agentID == agent } }
                return nil
            }
            pixels[entry.file] = .encoded(data)
            return Frame(image: image, size: size)
        }
    }

    /// Keeps `image`, `agent`'s terminal as it stands at `size` points, as the
    /// Agent's latest frame, evicting the least recently captured Agents
    /// beyond `capacity`.
    func record(_ image: CGImage, size: CGSize, for agent: ConsoleAgent, host: Host) {
        guard size.width > 0, size.height > 0, agent.hostID == host.id else { return }
        loadIfNeeded()
        let entry = Entry(
            hostID: agent.hostID, paneID: agent.agent.paneID, backend: agent.backend,
            target: ConsoleInventoryCache.Target(host),
            width: size.width, height: size.height,
            capturedAt: now(), file: "\(UUID().uuidString).jpg")
        var removed = entries.filter { $0.agentID == agent.id || !isFresh($0) }
        entries.removeAll { $0.agentID == agent.id || !isFresh($0) }
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity {
            removed += entries[Self.capacity...]
            entries.removeLast(entries.count - Self.capacity)
        }
        let captured = CapturedImage(image: image)
        pixels[entry.file] = .captured(captured)
        for old in removed { pixels[old.file] = nil }
        persist(removing: removed) { directory in
            guard let data = Self.jpeg(captured.image) else { return nil }
            try Self.prepare(directory)
            try data.write(
                to: directory.appending(path: entry.file),
                options: [.atomic, .completeFileProtection])
            return data
        } then: { [weak self] data in
            guard let self, let data, case .captured = pixels[entry.file] else { return }
            pixels[entry.file] = .encoded(data)
        }
    }

    /// Forgets `agent`'s frame: it no longer stands for anything its terminal
    /// will show again.
    func discard(_ agent: ConsoleAgent.ID) {
        remove { $0.agentID == agent }
        if !isLoaded { deferredDiscards.insert(agent) }
    }

    /// Forgets the frames of Hosts no longer in the catalog and of Hosts whose
    /// connection target changed.
    func retainHosts(_ hosts: [Host]) {
        let targets = Dictionary(hosts.map { ($0.id, ConsoleInventoryCache.Target($0)) }) { _, last in last }
        retainedTargets = targets
        remove { targets[$0.hostID] != $0.target }
    }

    /// Forgets the frames of Agents whose pane is gone: a verified scope (its
    /// rows proven by a live snapshot) no longer lists them. An unverified
    /// scope's rows are last-known, so its frames stay.
    func retainAgents(_ listed: Set<ConsoleAgent.ID>, verifiedScopes: Set<ConsoleScope>) {
        remove { verifiedScopes.contains($0.scope) && !listed.contains($0.agentID) }
        guard !isLoaded else { return }
        for scope in verifiedScopes {
            // Once pruned, an old frame cannot return in a later inventory.
            deferredRetentions[scope] = deferredRetentions[scope].map { $0.intersection(listed) } ?? listed
        }
    }

    /// Returns once every disk write queued so far has finished.
    func settle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    // MARK: Disk

    private func isFresh(_ entry: Entry) -> Bool {
        now().timeIntervalSince(entry.capturedAt) <= Self.maxAge
    }

    private func remove(where shouldRemove: (Entry) -> Bool) {
        loadIfNeeded()
        let removed = entries.filter(shouldRemove)
        guard !removed.isEmpty else { return }
        entries.removeAll(where: shouldRemove)
        for entry in removed { pixels[entry.file] = nil }
        persist(removing: removed) { _ in nil } then: { _ in }
    }

    /// Queues `write`, the removal of `removed`'s files, and the index as it
    /// stands now, in that order, then hands `write`'s result back on the
    /// main actor.
    private func persist(
        removing removed: [Entry],
        write: @escaping @Sendable (URL) throws -> Data?,
        then: @escaping @MainActor (Data?) -> Void
    ) {
        // Before the index loads, the disk holds entries memory doesn't:
        // writing the index now would drop them.
        guard let directory, isLoaded else { return }
        let index = Index(version: Self.formatVersion, entries: entries)
        let files = removed.map(\.file)
        queue.async {
            var written: Data?
            do {
                written = try write(directory)
                for file in files {
                    try? FileManager.default.removeItem(at: directory.appending(path: file))
                }
                try Self.prepare(directory)
                try JSONEncoder().encode(index).write(
                    to: directory.appending(path: Self.indexName),
                    options: [.atomic, .completeFileProtection])
            } catch {
                Self.log.debug("Last frame write skipped: \(error.localizedDescription)")
            }
            let result = written
            Task { @MainActor in then(result) }
        }
    }

    /// Reads the index once, dropping expired entries and files no entry
    /// names (left by a write the app did not live to index). An index that
    /// exists but cannot be read (locked) is left alone and read again on
    /// the next use; anything recorded meanwhile stays and wins.
    private func loadIfNeeded() {
        guard !isLoaded else { return }
        guard let directory else {
            isLoaded = true
            return
        }
        let indexURL = directory.appending(path: Self.indexName)
        let read = queue.sync { readIndex(indexURL) }
        let loaded: [Entry]
        switch read {
        case .unreadable:
            return
        case .missing:
            loaded = []
        case .data(let data):
            if let index = try? JSONDecoder().decode(Index.self, from: data),
                index.version == Self.formatVersion
            {
                loaded = index.entries
            } else {
                loaded = []
            }
        }
        isLoaded = true
        let recorded = Set(entries.map(\.agentID))
        var merged = entries + loaded.filter {
            !recorded.contains($0.agentID) && !deferredDiscards.contains($0.agentID)
                && (deferredRetentions[$0.scope]?.contains($0.agentID) ?? true)
        }
        deferredDiscards.removeAll()
        deferredRetentions.removeAll()
        if let retainedTargets {
            merged.removeAll { retainedTargets[$0.hostID] != $0.target }
        }
        entries = Array(merged.filter(isFresh).sorted { $0.capturedAt > $1.capturedAt }
            .prefix(Self.capacity))
        let kept = Set(entries.map(\.file) + [Self.indexName])
        let index = Index(version: Self.formatVersion, entries: entries)
        let rewritesIndex = entries != loaded
        queue.async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names where !kept.contains(name) {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
            guard rewritesIndex, let data = try? JSONEncoder().encode(index) else { return }
            try? data.write(to: indexURL, options: [.atomic, .completeFileProtection])
        }
    }

    nonisolated private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    nonisolated private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

extension AgentLastFrameStore {
    /// Keeps what `terminal` shows as `agent`'s latest frame; nothing when it
    /// has no rendered frame or its Host is not in `hosts`.
    func record(_ terminal: UIView?, for agent: ConsoleAgent, hosts: [Host]) {
        guard let terminal, let host = hosts.first(where: { $0.id == agent.hostID }),
              let image = TerminalFrameCapture.image(of: terminal)
        else { return }
        record(image, size: terminal.bounds.size, for: agent, host: host)
    }

    /// Puts `agent`'s cached frame up on an entering screen's `lastFrame`
    /// while that screen has no frame of its own. True when it went up.
    @discardableResult
    func offer(to lastFrame: TerminalLastFrame, for agent: ConsoleAgent.ID, hosts: [Host]) -> Bool {
        guard lastFrame.snapshot == nil, lastFrame.paintedSurface == nil,
              let frame = frame(for: agent, host: hosts.first { $0.id == agent.hostID })
        else { return false }
        return lastFrame.offer(.cached(frame))
    }
}

extension EnvironmentValues {
    /// The app's per-Agent frame cache; nil (no cache) outside the app's
    /// windows, such as in tests and previews that do not inject one.
    @Entry var agentLastFrames: AgentLastFrameStore? = nil
}
