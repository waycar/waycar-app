import Foundation
import Observation

/// One line of a build's release notes: an SF Symbol name and a short,
/// plain-text sentence. CI writes these; the sheet falls back to a generic
/// symbol if a name does not resolve on this OS.
struct WhatsNewItem: Decodable, Equatable, Sendable {
    let symbol: String
    let text: String
}

/// The notes CI generated for one TestFlight build: what changed since the
/// build before it. An entry with an `id` is a local device build's notes
/// (`scripts/write-local-whats-new.sh`), shown by id rather than by build.
struct WhatsNewBuild: Decodable, Equatable, Sendable {
    let build: Int
    let date: String
    let items: [WhatsNewItem]
    var id: String? = nil
}

/// The What's New sheet shown on the first launch of a build newer than the
/// one this device last showed notes for.
///
/// Keyed on build number because CI summarizes each TestFlight build against
/// the previous one and bundles the recent history as `WhatsNew.json`: a
/// device that skipped builds sees every summary it missed, newest first, and
/// a build whose summary is empty shows nothing.
///
/// Local device builds (`make install NOTES=…`) bundle one entry with a unique
/// `id` instead. Several worktrees install to the same device with the same or
/// lower build number, so those show whenever their id differs from the last
/// local id shown, and never touch the build marker: the next TestFlight build
/// still shows its own notes. Only DEBUG builds read them.
@MainActor
@Observable
final class WhatsNewStore {
    static let lastSeenBuildKey = "whats-new.last-seen-build"
    static let lastSeenLocalIDKey = "whats-new.last-seen-local-id"
    #if DEBUG
    static let readsLocalNotes = true
    #else
    static let readsLocalNotes = false
    #endif
    /// Written by the superseded changelog-fingerprint implementation. Their
    /// presence marks a device that used the app before build tracking, and
    /// acknowledging removes them.
    static let legacyKeys = ["whats-new.seen-entries", "whats-new.seen-releases"]

    /// Builds to show, newest first, none of them empty; nil when there is
    /// nothing new.
    private(set) var pending: [WhatsNewBuild]?
    @ObservationIgnored private let currentBuild: Int?
    /// Set when the bundle carries local notes; acknowledging records it in
    /// place of the build marker.
    @ObservationIgnored private let localID: String?
    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    /// - Parameters:
    ///   - notes: the bundled `WhatsNew.json`; missing or undecodable data
    ///     shows nothing rather than failing launch.
    ///   - currentBuild: this build's `CFBundleVersion`; nil shows nothing,
    ///     since there is no build to compare against.
    ///   - isExistingInstall: whether this device used the app before it
    ///     could remember a build. A fresh install records the current build
    ///     without showing anything; an existing one is shown the current
    ///     build's notes once, as older history cannot be told apart from
    ///     what it already saw.
    ///   - readsLocalNotes: whether entries with an `id` count; DEBUG only by
    ///     default, so a Release build ignores them entirely.
    init(
        notes: Data?, currentBuild: Int?, isExistingInstall: Bool,
        defaults: UserDefaults = .standard, readsLocalNotes: Bool = WhatsNewStore.readsLocalNotes
    ) {
        self.defaults = defaults
        let all = notes.flatMap { try? Self.builds(from: $0) } ?? []
        let builds = all.filter { $0.id == nil }

        let local = readsLocalNotes ? all.first { $0.id != nil } : nil
        if let local {
            // A local build leaves the build marker alone, even with no items,
            // so a later CI build with this or a lower number still shows its notes.
            self.currentBuild = nil
            self.localID = local.id
            if !local.items.isEmpty, local.id != defaults.string(forKey: Self.lastSeenLocalIDKey) {
                pending = [local]
            }
            return
        }
        self.localID = nil
        self.currentBuild = currentBuild
        guard let currentBuild else { return }

        let lastSeen = defaults.object(forKey: Self.lastSeenBuildKey) as? Int
        let unseen: [WhatsNewBuild]
        if let lastSeen {
            unseen = builds.filter { lastSeen < $0.build && $0.build <= currentBuild }
        } else if isExistingInstall || Self.legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) {
            unseen = builds.filter { $0.build == currentBuild }
        } else {
            unseen = []
        }

        let shown = unseen.filter { !$0.items.isEmpty }.sorted { $0.build > $1.build }
        if !shown.isEmpty {
            pending = shown
        } else if lastSeen.map({ $0 < currentBuild }) ?? true {
            // Nothing to show still moves the marker up to this build: a
            // build with no user-visible notes would otherwise leave it
            // behind, and a later build would resurface notes this device
            // already launched past. Never moved down, so running an older
            // build does not replay newer notes on the way back up.
            markSeen(currentBuild)
        }
    }

    /// Decodes a `WhatsNew.json` payload. Unknown fields are ignored so CI can
    /// add metadata without breaking builds already in testers' hands.
    static func builds(from data: Data) throws -> [WhatsNewBuild] {
        try JSONDecoder().decode(Notes.self, from: data).builds
    }

    /// The bundled `WhatsNew.json`, or nil if the build did not bundle it.
    static func bundledNotes(in bundle: Bundle = .main) -> Data? {
        bundle.url(forResource: "WhatsNew", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
    }

    /// This build's `CFBundleVersion` as a number, or nil if it is not one.
    static func currentBuild(in bundle: Bundle = .main) -> Int? {
        (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String).flatMap { Int($0) }
    }

    /// Dismisses the sheet and remembers this build as shown.
    func acknowledge() {
        pending = nil
        if let localID { defaults.set(localID, forKey: Self.lastSeenLocalIDKey) }
        if let currentBuild { markSeen(currentBuild) }
    }

    private func markSeen(_ build: Int) {
        defaults.set(build, forKey: Self.lastSeenBuildKey)
        for key in Self.legacyKeys { defaults.removeObject(forKey: key) }
    }

    private struct Notes: Decodable {
        let builds: [WhatsNewBuild]
    }
}

/// One window's launch sheets. Notes are acknowledged app-wide by
/// `WhatsNewStore`, but a window that showed them blocks consent until its
/// own sheet has completely dismissed, even after pending notes become nil.
struct LaunchSheetMachine: StateMachine {
    enum State: Equatable, Sendable {
        case notesPending
        case notesShowing
        case notesDismissing
        case readyForConsent
    }

    enum Event: Equatable, Sendable {
        case notesChanged(pending: Bool)
        case appeared(notesPending: Bool)
        case dismissed(notesPending: Bool)
    }

    typealias Effect = Never

    private(set) var state: State = .readyForConsent

    var isReadyForConsent: Bool { state == .readyForConsent }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.readyForConsent, .notesChanged(pending: true)):
            state = .notesPending
        case (.notesPending, .notesChanged(pending: false)):
            state = .readyForConsent
        case (.notesShowing, .notesChanged(pending: false)):
            state = .notesDismissing
        case (.notesPending, .appeared(let pending)), (.notesShowing, .appeared(let pending)),
             (.notesDismissing, .appeared(let pending)), (.readyForConsent, .appeared(let pending)):
            state = pending ? .notesShowing : .notesDismissing
        case (.notesPending, .dismissed(let pending)), (.notesShowing, .dismissed(let pending)),
             (.notesDismissing, .dismissed(let pending)), (.readyForConsent, .dismissed(let pending)):
            state = pending ? .notesPending : .readyForConsent
        case (.readyForConsent, .notesChanged(pending: false)),
             (.notesPending, .notesChanged(pending: true)),
             (.notesShowing, .notesChanged(pending: true)),
             (.notesDismissing, .notesChanged):
            break
        }
        return []
    }
}
