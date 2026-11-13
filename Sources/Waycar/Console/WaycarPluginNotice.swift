import Foundation
import Observation
import SwiftUI

/// The Hosts whose Console "Waycar plugin is out of date" row the user
/// answered with **Not now** (#209). A dismissal holds for the minimum it
/// was shown for: an app build that requires a newer plugin shows the row
/// again. Host detail's Waycar plugin section never reads this.
///
/// A synced preference (ADR 0019, `PreferenceSync`), so it reaches the
/// user's other devices and comes back after a reinstall with their Hosts;
/// `reload()` re-reads it after iCloud Sync replaced it.
///
/// One instance lives on the app model, so every window's Console hides
/// the row the moment any of them dismisses it.
///
/// A removed Host's entry stays behind: a few bytes under an id no Host
/// will carry again.
@MainActor
@Observable
final class WaycarPluginNoticeDismissals {
    static let defaultsKey = "waycar-plugin-notice-dismissals"

    /// Host id (`uuidString`) → the minimum version the row was dismissed at.
    private(set) var dismissedMinimums: [String: String]

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dismissedMinimums =
            defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    /// Re-reads the dismissals after iCloud Sync replaced them.
    func reload() {
        let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        if stored != dismissedMinimums { dismissedMinimums = stored }
    }

    /// Whether the row stays hidden for `hostID` while this build requires
    /// `minimum`: a dismissal counts only for the exact minimum it was made at.
    func isDismissed(
        _ hostID: Host.ID, minimum: String = WaycarPluginRequirement.minimumVersion
    ) -> Bool {
        dismissedMinimums[hostID.uuidString] == minimum
    }

    /// **Not now**: hides the row for `hostID` until the app requires a
    /// minimum other than `minimum`. Re-reads the stored entries first, so
    /// a write from elsewhere on this device is kept, not overwritten.
    func dismiss(_ hostID: Host.ID, minimum: String = WaycarPluginRequirement.minimumVersion) {
        var stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
        stored.merge(dismissedMinimums) { current, _ in current }
        stored[hostID.uuidString] = minimum
        dismissedMinimums = stored
        defaults.set(stored, forKey: Self.defaultsKey)
    }
}

/// Whether the Console offers **Install Waycar Host Tools** on a Host that
/// has no Waycar plugin, per Host (WAY-341), and the **move off Node**
/// prompt on a Host whose plugin is a Node-era one (WAY-451).
///
/// - **Not now** hides the offer for 14 days. It comes back once; a second
///   Not now ends the offers for that Host. The move-off-Node prompt keeps
///   its own count, keyed to `nativeToolsMinimumVersion`.
/// - **Remind me to install Host Tools** (Host detail), on by default: off
///   never shows either offer for that Host. Turning it on again also
///   forgets earlier Not now answers, so the offer returns at once.
///
/// The outdated-plugin row keeps its own answers (`WaycarPluginNoticeDismissals`).
/// Both are synced preferences (ADR 0019, `PreferenceSync`): an answer reaches
/// the user's other devices and survives deleting and reinstalling the app,
/// which keeps the synced Hosts and so their ids; `reload()` re-reads it after
/// iCloud Sync replaced it. One instance lives on the app model and reaches
/// every window through `\.hostToolsOffer`, so every window agrees.
@MainActor
@Observable
final class HostToolsOffer {
    static let defaultsKey = "waycar-host-tools-offer"
    /// How long the first Not now holds.
    static let notNowInterval: TimeInterval = 14 * 24 * 60 * 60
    /// Not now answers after which the offer never shows again.
    static let notNowLimit = 2

    struct Entry: Codable, Equatable {
        /// False once the user turned the Host's reminder off.
        var reminds = true
        var notNowCount = 0
        var lastNotNow: Date?
        /// Not now answers to the move-off-Node prompt; absent until one.
        var nativeTools: NativeToolsAnswer?
    }

    /// Not now answers to the move-off-Node prompt, for one
    /// `nativeToolsMinimumVersion`.
    struct NativeToolsAnswer: Codable, Equatable {
        var minimum: String
        var notNowCount = 0
        var lastNotNow: Date?
    }

    /// Host id (`uuidString`) → what the user answered. A Host with no
    /// entry has the defaults.
    private(set) var entries: [String: Entry]

    @ObservationIgnored private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = Self.stored(in: defaults)
    }

    /// Whether this build can read a synced value (`SyncedPreference.canRead`).
    static func canRead(_ data: Data) -> Bool {
        decode(data) != nil
    }

    /// Re-reads the answers after iCloud Sync replaced them.
    func reload() {
        let stored = Self.stored(in: defaults)
        if stored != entries { entries = stored }
    }

    /// The reminder switch: false means the offer never shows for `hostID`.
    func reminds(_ hostID: Host.ID) -> Bool {
        entries[hostID.uuidString]?.reminds ?? true
    }

    /// Whether the offer stays hidden for `hostID` at `now`.
    func isHidden(_ hostID: Host.ID, now: Date = Date()) -> Bool {
        guard let entry = entries[hostID.uuidString] else { return false }
        if !entry.reminds || entry.notNowCount >= Self.notNowLimit { return true }
        guard let last = entry.lastNotNow else { return false }
        return now.timeIntervalSince(last) < Self.notNowInterval
    }

    /// **Not now** on the offer shown for `hostID`.
    func notNow(_ hostID: Host.ID, now: Date = Date()) {
        update(hostID) {
            $0.notNowCount += 1
            $0.lastNotNow = now
        }
    }

    func setReminds(_ reminds: Bool, for hostID: Host.ID) {
        update(hostID) {
            $0.reminds = reminds
            if reminds {
                $0.notNowCount = 0
                $0.lastNotNow = nil
                $0.nativeTools = nil
            }
        }
    }

    /// Whether the **move off Node** prompt (a Host on a Node-era plugin,
    /// below `nativeToolsMinimumVersion`) stays hidden for `hostID` at `now`.
    /// The same rules as the install offer: the Host's reminder switch off
    /// hides it for good, **Not now** holds 14 days, it comes back once, and a
    /// second Not now ends it. Answers are keyed to `minimum`: a Not now made
    /// for another minimum never hides this prompt, so a build that raises the
    /// native minimum prompts again.
    func isNativeToolsPromptHidden(
        _ hostID: Host.ID, minimum: String = WaycarPluginRequirement.nativeToolsMinimumVersion,
        now: Date = Date()
    ) -> Bool {
        guard let entry = entries[hostID.uuidString] else { return false }
        if !entry.reminds { return true }
        guard let answer = entry.nativeTools, answer.minimum == minimum else { return false }
        if answer.notNowCount >= Self.notNowLimit { return true }
        guard let last = answer.lastNotNow else { return false }
        return now.timeIntervalSince(last) < Self.notNowInterval
    }

    /// **Not now** on the move-off-Node prompt shown for `hostID` at `minimum`.
    func nativeToolsNotNow(
        _ hostID: Host.ID, minimum: String = WaycarPluginRequirement.nativeToolsMinimumVersion,
        now: Date = Date()
    ) {
        update(hostID) {
            var answer = $0.nativeTools?.minimum == minimum
                ? $0.nativeTools ?? NativeToolsAnswer(minimum: minimum)
                : NativeToolsAnswer(minimum: minimum)
            answer.notNowCount += 1
            answer.lastNotNow = now
            $0.nativeTools = answer
        }
    }

    /// Re-reads the stored entries first, so a write from elsewhere on this
    /// device is kept, not overwritten.
    private func update(_ hostID: Host.ID, _ change: (inout Entry) -> Void) {
        var stored = Self.stored(in: defaults)
        var entry = stored[hostID.uuidString] ?? Entry()
        change(&entry)
        stored[hostID.uuidString] = entry
        entries = stored
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    private static func stored(in defaults: UserDefaults) -> [String: Entry] {
        defaults.data(forKey: defaultsKey).flatMap(decode) ?? [:]
    }

    private static func decode(_ data: Data) -> [String: Entry]? {
        try? JSONDecoder().decode([String: Entry].self, from: data)
    }
}

/// The Hosts with an "Update Waycar on this Host" run in flight (#209).
/// One instance lives on the app model and reaches every window through
/// `\.waycarPluginUpdateActivity`, so a second window, Host detail or Chat
/// cannot start a second installer on the same Host, and the Console keeps
/// Host detail up while its update runs.
@MainActor
@Observable
final class WaycarPluginUpdateActivity {
    private(set) var runningHosts: Set<Host.ID> = []

    /// Marks an update running on `hostID`; false when one already runs there.
    func begin(_ hostID: Host.ID) -> Bool {
        runningHosts.insert(hostID).inserted
    }

    /// The run on `hostID` finished or failed. Update stores call this only
    /// for their machine's matching release effect; a refused second run
    /// must never release the first one's hold.
    func end(_ hostID: Host.ID) {
        runningHosts.remove(hostID)
    }
}

/// Opens "Update Waycar on this Host" (#209) in place, over whatever shows
/// the prompt: the Console's plugin row, an Agent card's progress hint,
/// Chat Mode's outdated-plugin notice. `status` reads the Host's plugin
/// status from the Console, so a view outside it can follow the update.
struct WaycarPluginUpdateAction {
    let status: @MainActor (Host.ID) -> WaycarPluginStatus
    let present: @MainActor (Host.ID) -> Void

    @MainActor
    func callAsFunction(_ hostID: Host.ID) {
        present(hostID)
    }
}

extension EnvironmentValues {
    /// Set by the Console at its root, so its sheets and every Agent detail
    /// inherit it; nil (previews, the Settings preview) hides the update
    /// buttons.
    @Entry var requestWaycarPluginUpdate: WaycarPluginUpdateAction? = nil
    /// The app's one update tracker, injected at each window's root; nil in
    /// previews, where updates run untracked.
    @Entry var waycarPluginUpdateActivity: WaycarPluginUpdateActivity? = nil
    /// The app's one Host Tools offer record, injected at each window's
    /// root; nil in previews, where no Host is offered an install.
    @Entry var hostToolsOffer: HostToolsOffer? = nil
}
