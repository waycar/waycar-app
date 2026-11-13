import Foundation

/// TOFU persistence: fingerprints are keyed by endpoint and SSH key
/// algorithm, matching OpenSSH's ability to trust more than one host-key
/// algorithm for the same machine. Not a secret: it guards against future
/// impostors, it does not authenticate us.
protocol KnownHostsStore: Sendable {
    func fingerprints(host: String, port: Int) async -> [HostKeyFingerprint]
    func fingerprint(host: String, port: Int, algorithm: String) async -> HostKeyFingerprint?
    func fingerprint(host: String, port: Int) async -> HostKeyFingerprint?
    func setFingerprint(_ fingerprint: HostKeyFingerprint, host: String, port: Int) async
}

extension KnownHostsStore {
    func fingerprint(host: String, port: Int) async -> HostKeyFingerprint? {
        await fingerprints(host: host, port: port).first
    }
}

/// Volatile store for tests and previews.
actor InMemoryKnownHostsStore: KnownHostsStore {
    private var storedFingerprints: [String: HostKeyFingerprint] = [:]

    func fingerprints(host: String, port: Int) -> [HostKeyFingerprint] {
        let prefix = Self.algorithmKeyPrefix(host: host, port: port)
        return storedFingerprints
            .filter { $0.key.hasPrefix(prefix) }
            .map(\.value)
    }

    func fingerprint(host: String, port: Int, algorithm: String) -> HostKeyFingerprint? {
        storedFingerprints[Self.algorithmKey(host: host, port: port, algorithm: algorithm)]
            ?? storedFingerprints[
                Self.algorithmKey(
                    host: host, port: port, algorithm: HostKeyFingerprint.unknownAlgorithm)]
    }

    func setFingerprint(_ fingerprint: HostKeyFingerprint, host: String, port: Int) {
        if fingerprint.algorithm != HostKeyFingerprint.unknownAlgorithm {
            storedFingerprints[
                Self.algorithmKey(
                    host: host, port: port, algorithm: HostKeyFingerprint.unknownAlgorithm)] = nil
        }
        storedFingerprints[
            Self.algorithmKey(host: host, port: port, algorithm: fingerprint.algorithm)] =
            fingerprint
    }

    static func endpointKey(host: String, port: Int) -> String {
        "\(host):\(port)"
    }

    static func algorithmKeyPrefix(host: String, port: Int) -> String {
        let endpoint = endpointKey(host: host, port: port)
        return "v2|\(endpoint.utf8.count)|\(endpoint)|"
    }

    static func algorithmKey(host: String, port: Int, algorithm: String) -> String {
        algorithmKeyPrefix(host: host, port: port) + algorithm
    }
}

/// The app's persistent store. Production uses one shared actor so concurrent
/// first connects cannot lose each other's read-modify-write updates.
///
/// With iCloud Sync on (ADR 0019) every algorithm-keyed fingerprint is also an
/// iCloud Keychain item, so a Host trusted on one device connects on the
/// others without a first-connect prompt. Sync only ever adds a fingerprint a
/// device lacks: where this device already trusts a different key for the
/// same endpoint, its own trust decision stands, and a host-key mismatch is
/// settled on this device the usual way. Pre-algorithm (legacy endpoint)
/// entries stay on the device.
actor UserDefaultsKnownHostsStore: KnownHostsStore {
    static let shared = UserDefaultsKnownHostsStore()
    private static let defaultsKey = "knownHostFingerprints"
    static let syncedAccountPrefix = "known-host."
    private let defaults: UserDefaults
    private let sharedStore: @Sendable () -> (any SecretStore)?

    init() {
        defaults = .standard
        sharedStore = ICloudSync.sharedWhileEnabled
    }

    init?(
        suiteName: String,
        shared: @escaping @Sendable () -> (any SecretStore)? = { nil }
    ) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        self.defaults = defaults
        sharedStore = shared
    }

    func fingerprints(host: String, port: Int) -> [HostKeyFingerprint] {
        let stored = storedValues()
        let prefix = InMemoryKnownHostsStore.algorithmKeyPrefix(host: host, port: port)
        var fingerprints = stored.compactMap { key, base64 -> HostKeyFingerprint? in
            guard key.hasPrefix(prefix), let digest = Data(base64Encoded: base64) else {
                return nil
            }
            let algorithm = String(key.dropFirst(prefix.count))
            return HostKeyFingerprint(digest: digest, algorithm: algorithm)
        }
        if let legacy = legacyFingerprint(in: stored, host: host, port: port) {
            fingerprints.append(legacy)
        }
        return fingerprints
    }

    func fingerprint(host: String, port: Int, algorithm: String) -> HostKeyFingerprint? {
        let stored = storedValues()
        let key = InMemoryKnownHostsStore.algorithmKey(
            host: host, port: port, algorithm: algorithm)
        if let base64 = stored[key], let digest = Data(base64Encoded: base64) {
            return HostKeyFingerprint(digest: digest, algorithm: algorithm)
        }
        return legacyFingerprint(in: stored, host: host, port: port)
    }

    func setFingerprint(_ fingerprint: HostKeyFingerprint, host: String, port: Int) {
        var stored = storedValues()
        if fingerprint.algorithm != HostKeyFingerprint.unknownAlgorithm {
            stored[InMemoryKnownHostsStore.endpointKey(host: host, port: port)] = nil
        }
        let key = InMemoryKnownHostsStore.algorithmKey(
            host: host, port: port, algorithm: fingerprint.algorithm)
        let value = fingerprint.digest.base64EncodedString()
        stored[key] = value
        defaults.set(stored, forKey: Self.defaultsKey)
        // Best-effort: a write that fails leaves the key only on this device,
        // and the next sync pass publishes local fingerprints the shared
        // store lacks.
        try? sharedStore()?.write(Data(value.utf8), account: Self.syncedAccountPrefix + key)
    }

    /// One sync pass against `items` (a `readAll` of the shared store): adopt
    /// synced fingerprints for endpoints this device trusts no key for at
    /// all, and publish the ones iCloud Keychain lacks. Never adds to, or
    /// replaces, what this device already trusts for an endpoint — including
    /// a pre-algorithm pin or a pin for another algorithm, which the verifier
    /// relies on to flag a changed key. Returns whether local fingerprints
    /// changed.
    func syncWithShared(_ items: [String: Data]) -> Bool {
        guard let shared = sharedStore() else { return false }
        let before = storedValues()
        var stored = before
        var remoteKeys: Set<String> = []
        for (account, data) in items where account.hasPrefix(Self.syncedAccountPrefix) {
            let key = String(account.dropFirst(Self.syncedAccountPrefix.count))
            guard let endpoint = Self.endpoint(ofSyncedKey: key),
                let value = String(data: data, encoding: .utf8),
                Data(base64Encoded: value) != nil
            else { continue }
            remoteKeys.insert(key)
            let trustsEndpoint =
                before[endpoint.key] != nil || before.keys.contains { $0.hasPrefix(endpoint.prefix) }
            if !trustsEndpoint {
                stored[key] = value
            }
        }
        for (key, value) in before where key.hasPrefix(Self.syncedKeyPrefix) && !remoteKeys.contains(key) {
            try? shared.write(Data(value.utf8), account: Self.syncedAccountPrefix + key)
        }
        guard stored != before else { return false }
        defaults.set(stored, forKey: Self.defaultsKey)
        return true
    }

    /// The endpoint an algorithm-keyed entry (`v2|<length>|<host:port>|<algorithm>`)
    /// belongs to: its legacy endpoint key and the prefix every algorithm's
    /// key for it shares. Nil for anything else.
    private static func endpoint(ofSyncedKey key: String) -> (key: String, prefix: String)? {
        guard key.hasPrefix(syncedKeyPrefix) else { return nil }
        let rest = key.dropFirst(syncedKeyPrefix.count)
        guard let bar = rest.firstIndex(of: "|"), let length = Int(rest[..<bar]) else { return nil }
        let endpointUTF8 = rest[rest.index(after: bar)...].utf8
        guard endpointUTF8.count > length,
            let endpoint = String(endpointUTF8.prefix(length))
        else { return nil }
        return (endpoint, "\(syncedKeyPrefix)\(length)|\(endpoint)|")
    }

    /// Every host-key digest this device trusts for an endpoint, read
    /// without the actor for the main actor's synchronous callers (one Live
    /// Activity per computer). Two endpoints sharing a digest are one machine.
    static func trustedDigests(
        host: String, port: Int, in defaults: UserDefaults = .standard
    ) -> Set<Data> {
        let stored = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        let prefix = InMemoryKnownHostsStore.algorithmKeyPrefix(host: host, port: port)
        let legacy = InMemoryKnownHostsStore.endpointKey(host: host, port: port)
        return Set(
            stored.compactMap { key, base64 in
                key.hasPrefix(prefix) || key == legacy ? Data(base64Encoded: base64) : nil
            })
    }

    /// Only algorithm-keyed entries sync; see `InMemoryKnownHostsStore`.
    private static let syncedKeyPrefix = "v2|"

    private func storedValues() -> [String: String] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    private func legacyFingerprint(
        in stored: [String: String], host: String, port: Int
    ) -> HostKeyFingerprint? {
        guard
            let base64 = stored[InMemoryKnownHostsStore.endpointKey(host: host, port: port)],
            let digest = Data(base64Encoded: base64)
        else { return nil }
        return HostKeyFingerprint(digest: digest)
    }
}
