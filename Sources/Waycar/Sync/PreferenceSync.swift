import Foundation

/// App preferences under iCloud Sync (ADR 0019): each synced UserDefaults key
/// is one iCloud Keychain item, `pref.<key>`, holding the value as a binary
/// property list, or `removedMarker` once a device removed the value.
///
/// A pass compares three states per key — this device's value, the synced
/// item, and the value both last agreed on (`base`, kept on this device) — so
/// it can tell which side changed. When only one side changed, that side
/// wins. When both did, this device wins, except the first time it syncs the
/// key: then the value the user's other devices already share wins, so a
/// newly added device adopts the user's settings instead of overwriting them.
///
/// A missing item is not a removal: it has not synced here yet, or iCloud
/// Keychain lost it. This device's value is published again instead.
struct PreferenceSync {
    static let accountPrefix = "pref."
    static let baseDefaultsKey = "icloud-sync.preference-base"
    /// Never a valid binary property list, which always starts `bplist`.
    static let removedMarker = Data("waycar:removed".utf8)

    struct Outcome {
        /// Keys whose value on this device changed; their stores must reload.
        var changedKeys: Set<String> = []
        /// The first key that failed, if any; the others were still synced.
        var failure: (any Error)?
    }

    let defaults: UserDefaults
    let keys: [String]

    /// One pass against `items` (a `readAll` of `shared`). `canRead` says
    /// whether this build can read a synced value (a property-list object);
    /// a value it cannot read — a newer build's data — is never overwritten
    /// or removed from here, even after this device reset its own copy.
    func reconcile(
        items: [String: Data],
        shared: any SecretStore,
        canRead: (String, Any) -> Bool = { _, _ in true }
    ) -> Outcome {
        let storedBase = defaults.dictionary(forKey: Self.baseDefaultsKey) as? [String: Data] ?? [:]
        var base = storedBase
        var outcome = Outcome()
        for key in keys {
            do {
                if try reconcile(key: key, remoteItem: items[Self.accountPrefix + key],
                    agreed: storedBase[key], base: &base, shared: shared,
                    canRead: { canRead(key, $0) })
                {
                    outcome.changedKeys.insert(key)
                }
            } catch {
                outcome.failure = outcome.failure ?? error
            }
        }
        if base != storedBase {
            defaults.set(base, forKey: Self.baseDefaultsKey)
        }
        return outcome
    }

    /// Returns whether this device's value changed.
    private func reconcile(
        key: String, remoteItem: Data?, agreed: Data?, base: inout [String: Data],
        shared: any SecretStore, canRead: (Any) -> Bool
    ) throws -> Bool {
        let account = Self.accountPrefix + key
        let local = try Self.encode(defaults.object(forKey: key))
        guard let remoteItem else {
            // Unknown to iCloud Keychain: publish what this device has.
            guard let local else { return false }
            try shared.write(local, account: account)
            base[key] = local
            return false
        }
        let remote = remoteItem == Self.removedMarker ? nil : remoteItem
        if local == remote {
            base[key] = local ?? Self.removedMarker
            return false
        }
        // A synced value this build cannot read (a newer build's data) is
        // neither adopted, which would leave this device's store unreadable,
        // nor overwritten, which would wipe it where it can be read.
        if let remote,
            !((try? PropertyListSerialization.propertyList(from: remote, format: nil)).map(canRead)
                ?? false)
        {
            return false
        }
        // Keep agreed absence distinct from a key this device never synced.
        // Existing baselines contain property lists and still compare as before.
        let localChanged = (local ?? Self.removedMarker) != agreed
        let remoteChanged = remoteItem != agreed
        if remoteChanged && (!localChanged || agreed == nil) {
            if let remote {
                defaults.set(
                    try PropertyListSerialization.propertyList(from: remote, format: nil),
                    forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
            base[key] = remoteItem
            return true
        }
        try shared.write(local ?? Self.removedMarker, account: account)
        base[key] = local ?? Self.removedMarker
        return false
    }

    private static func encode(_ value: Any?) throws -> Data? {
        guard let value else { return nil }
        return try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
}
