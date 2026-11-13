import Foundation
import Observation
import Security

/// One synced UserDefaults key and the store that owns it.
struct SyncedPreference {
    /// Re-reads the owning store after another device changed the key.
    let reload: @MainActor () -> Void
    /// Whether this build can read a synced value (a property-list object).
    /// One it cannot — a newer build's data — is neither adopted nor
    /// overwritten, so an older device can never wipe it everywhere.
    var canRead: @MainActor (Any) -> Bool = { _ in true }
}

/// A replaced SSH key: the line to remove from every Host and the one to add.
struct KeyReplacement: Equatable {
    let oldLine: String?
    let newLine: String
}

/// Runs iCloud Sync on this device (ADR 0019): publishes this device's data
/// when sync is turned on, then pulls and pushes on launch, on every return to
/// the foreground or background, shortly after a synced preference or a
/// Closed Session changes on this device, and every `pollInterval` while the
/// app is active — iCloud Keychain posts no change notification, so
/// re-reading is the only way to notice what another device wrote.
///
/// Hosts, passwords and identities write through to iCloud Keychain as they
/// change (`HostStore`, `SyncAwareSecretStore`, `SyncedIdentityKeychain`), so
/// a pass mostly reads; Closed Sessions go up with the pass that follows a
/// change. A pass also republishes whatever this device has and iCloud
/// Keychain lacks, because a missing item is never read as a deletion (only
/// a tombstone or a preference removal marker is). `lastPassAt` only ever
/// says this device read and wrote its own items; whether iCloud Keychain
/// carried them anywhere is invisible to the app.
@MainActor
@Observable
final class ICloudSyncCoordinator {
    static let pollInterval: Duration = .seconds(30)
    static let changeDebounce: Duration = .seconds(2)

    var isEnabled: Bool { scheduler.isEnabled }
    private var scheduler: ICloudPassMachine
    /// When the last pass finished. Nil until one has.
    private(set) var lastPassAt: Date?
    /// Why the last pass, switch-off or key replacement failed, if one did.
    private(set) var lastError: String?
    /// Switching off failed to keep something on this device; the user may
    /// still turn sync off anyway (`turnOffAnyway`).
    private(set) var switchOffFailed = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let shared: any SecretStore
    @ObservationIgnored private let deviceSSH: any SecretStore
    @ObservationIgnored private let hostStore: HostStore
    /// Closed Sessions (ADR 0019): merged record by record after the Host
    /// catalog, whose Hosts decide which synced records arrive here.
    @ObservationIgnored private let closedSessions: ClosedSessionsStore?
    @ObservationIgnored private let knownHosts: UserDefaultsKnownHostsStore
    @ObservationIgnored let deviceKeys: DeviceKeyStore
    @ObservationIgnored let rsaKeys: RSAKeyStore
    @ObservationIgnored private let preferences: PreferenceSync
    @ObservationIgnored private let syncedPreferences: [String: SyncedPreference]
    @ObservationIgnored private let retryConnections: @MainActor () async -> Void
    @ObservationIgnored private let syncKnownHosts: @MainActor ([String: Data]) async -> Bool
    /// The canonical identity accounts seen by the last pass, to notice a key
    /// arriving from another device. Nil before the first pass.
    @ObservationIgnored private var canonicalIdentities: [String?]?
    @ObservationIgnored private var pass: Task<Void, Never>?
    @ObservationIgnored private var isSceneActive = false
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var defaultsObserver: (any NSObjectProtocol)?

    /// `preferences` maps each synced UserDefaults key to its owning store.
    /// `retryConnections` runs after a pass brings Hosts, fingerprints or a
    /// key this device did not have, since a Host that failed for want of
    /// them will not retry on its own; it must leave working Hosts alone.
    init(
        hostStore: HostStore,
        closedSessions: ClosedSessionsStore? = nil,
        preferences: [String: SyncedPreference],
        retryConnections: @escaping @MainActor () async -> Void,
        defaults: UserDefaults = .standard,
        shared: any SecretStore = ICloudSync.sharedKeychain,
        deviceSSH: any SecretStore = ICloudSync.deviceSSHKeychain,
        knownHosts: UserDefaultsKnownHostsStore = .shared,
        deviceKeys: DeviceKeyStore = DeviceKeyStore(),
        rsaKeys: RSAKeyStore = RSAKeyStore(),
        syncKnownHosts: (@MainActor ([String: Data]) async -> Bool)? = nil
    ) {
        self.hostStore = hostStore
        self.closedSessions = closedSessions
        syncedPreferences = preferences
        self.retryConnections = retryConnections
        self.defaults = defaults
        self.shared = shared
        self.deviceSSH = deviceSSH
        self.knownHosts = knownHosts
        self.syncKnownHosts = syncKnownHosts ?? { await knownHosts.syncWithShared($0) }
        self.deviceKeys = deviceKeys
        self.rsaKeys = rsaKeys
        self.preferences = PreferenceSync(defaults: defaults, keys: preferences.keys.sorted())
        scheduler = ICloudPassMachine(enabled: ICloudSync.isEnabled(in: defaults))
    }

    /// Starts the first pass and watches for local preference and Closed
    /// Session changes.
    func start() {
        guard defaultsObserver == nil, hostStore.participatesInICloudSync else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: defaults, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon() }
        }
        closedSessions?.onLocalChange = { [weak self] in self?.syncSoon() }
        syncNow()
    }

    func sceneDidBecomeActive() {
        isSceneActive = true
        syncNow()
        startPolling()
    }

    func sceneDidEnterBackground() {
        isSceneActive = false
        poll?.cancel()
        poll = nil
        syncNow()
    }

    /// Runs a pass now, or right after the one in flight, and returns the task
    /// that runs it. Inert for a Host catalog that does not sync (previews,
    /// demo and test compositions).
    @discardableResult
    func syncNow() -> Task<Void, Never>? {
        guard isEnabled, hostStore.participatesInICloudSync else { return nil }
        let effects = scheduler.handle(.request)
        guard case .run(let token) = effects.first else { return pass }
        let task = Task { [weak self] in
            var next: UInt64? = token
            while let current = next, let self {
                _ = self.scheduler.handle(.began(current))
                await self.runPass(current)
                let effects = self.scheduler.handle(.finished(current))
                if case .run(let token) = effects.first {
                    next = token
                } else {
                    next = nil
                    self.pass = nil
                }
            }
        }
        pass = task
        return task
    }

    /// Turning sync on publishes this device's Hosts and passwords changed
    /// while sync was off over the synced copies and merges the rest.
    ///
    /// Turning it off first copies what this device needs into its
    /// device-only Keychain: the synced passwords of current Hosts, which may
    /// have come from another device, and the canonical keys. If any copy
    /// fails, sync stays on and the error shows, rather than leaving a Host
    /// without its password or silently generating a new key later; the user
    /// can still `turnOffAnyway`. The synced copies, which other devices use,
    /// are left alone.
    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            defaults.set(true, forKey: ICloudSync.enabledDefaultsKey)
            defaults.set(false, forKey: ICloudSync.attachedDefaultsKey)
            _ = scheduler.handle(.enable)
            lastError = nil
            switchOffFailed = false
            syncNow()
            startPolling()
            return
        }
        if let failure = keepSyncedSecretsOnDevice() {
            lastError = "Sync is still on: \(Self.message(for: failure))"
            switchOffFailed = true
            return
        }
        turnOffAnyway()
    }

    /// Turns sync off without keeping anything more on this device, after
    /// switching off failed to copy something. Whatever this device lacks
    /// stays in iCloud Keychain.
    func turnOffAnyway() {
        _ = scheduler.handle(.disable)
        poll?.cancel()
        debounce?.cancel()
        defaults.set(false, forKey: ICloudSync.enabledDefaultsKey)
        defaults.set(false, forKey: ICloudSync.attachedDefaultsKey)
        lastError = nil
        switchOffFailed = false
    }

    /// Replaces the Device Key on every device (a lost or exposed device).
    /// The old key keeps working on every Host until its line is removed
    /// there, so the old line comes back alongside the new one.
    func replaceDeviceKey() -> KeyReplacement? {
        let comment = Self.replacementComment()
        return replace {
            let old = try deviceKeys.currentKey()?.authorizedKeysLine(comment: "waycar")
            let new = try deviceKeys.rotate().authorizedKeysLine(comment: comment)
            return KeyReplacement(oldLine: old, newLine: new)
        }
    }

    /// See `replaceDeviceKey`.
    func replaceRSAKey() -> KeyReplacement? {
        let comment = Self.replacementComment() + " rsa"
        return replace {
            let old = try rsaKeys.currentKey()?.authorizedKeysLine(comment: "waycar rsa")
            let new = try rsaKeys.rotate().authorizedKeysLine(comment: comment)
            return KeyReplacement(oldLine: old, newLine: new)
        }
    }

    private func replace(_ rotate: () throws -> KeyReplacement) -> KeyReplacement? {
        do {
            let replacement = try rotate()
            lastError = nil
            syncNow()
            return replacement
        } catch {
            lastError = Self.message(for: error)
            return nil
        }
    }

    /// Tells the new line apart from the old one in `authorized_keys`.
    private static func replacementComment() -> String {
        "waycar-" + Date().formatted(.iso8601.year().month().day())
    }

    private func startPolling() {
        poll?.cancel()
        guard isSceneActive, isEnabled, hostStore.participatesInICloudSync else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, let self else { return }
                self.syncNow()
            }
        }
    }

    private func syncSoon() {
        guard isEnabled else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.changeDebounce)
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }

    private func runPass(_ token: UInt64) async {
        guard scheduler.accepts(token), !Task.isCancelled else { return }
        do {
            // The first pass after sync is turned on lets this device's Hosts
            // and passwords win. It counts as done only once the catalog was
            // readable: a catalog recovered later must still be published
            // before synced records replace it.
            let preferLocal = !defaults.bool(forKey: ICloudSync.attachedDefaultsKey)
            // Never generates: a device without a key of its own has nothing
            // to publish, and generating one here would race the synced key.
            try? deviceKeys.publishDeviceKey()
            try? rsaKeys.publishDeviceKey()

            // One read for the Host catalog; it is replaced in the same
            // main-actor turn, so no local edit can slip in between.
            let items = try shared.readAll()
            let hostsChanged = try hostStore.reconcileWithSync(items, preferLocal: preferLocal)
            try publishPasswords(preferLocal: preferLocal, items: items)
            if preferLocal, hostStore.catalogLoadError == nil {
                defaults.set(true, forKey: ICloudSync.attachedDefaultsKey)
            }

            let outcome = preferences.reconcile(
                items: items, shared: shared,
                canRead: { [syncedPreferences] key, value in
                    syncedPreferences[key]?.canRead(value) ?? true
                })
            for key in outcome.changedKeys {
                syncedPreferences[key]?.reload()
            }
            // After the Host catalog, so a record arrives with its Host. Like
            // a preference, one that failed does not hold up the rest.
            var closedSessionsFailure: (any Error)?
            do {
                try closedSessions?.reconcileWithSync(
                    items, knownHosts: Set(hostStore.hosts.map(\.id)))
            } catch {
                closedSessionsFailure = error
            }
            let identities = [
                deviceKeys.canonicalAccount(in: items), rsaKeys.canonicalAccount(in: items),
            ]
            let identityChanged = canonicalIdentities.map { $0 != identities } ?? false
            let knownHostsChanged = await syncKnownHosts(items)
            await performPassEffects(scheduler.handle(.result(
                token, completedAt: Date(),
                error: (outcome.failure ?? closedSessionsFailure).map(Self.message(for:)),
                retry: hostsChanged || identityChanged || knownHostsChanged, identities: identities)))
        } catch {
            await performPassEffects(scheduler.handle(.failed(token, Self.message(for: error))))
        }
    }

    private func performPassEffects(_ effects: [ICloudPassMachine.Effect]) async {
        for effect in effects {
            switch effect {
            case .publish(let date, let error, let identities):
                canonicalIdentities = identities
                lastPassAt = date
                lastError = error
            case .reportError(let error):
                lastError = error
            case .retryConnections:
                await retryConnections()
            case .run:
                break // The serial pass Task performs run effects.
            }
        }
    }

    /// Passwords of current password Hosts that iCloud Keychain lacks — never
    /// published, or lost — go up from this device's copy. With `preferLocal`
    /// (the first pass after sync is turned back on), so do passwords set on
    /// this device while sync was off; any other device copy may be stale and
    /// never replaces the synced one. A Host deleted elsewhere is gone from
    /// `hostStore.hosts` by now, so its device copy is never resurrected.
    private func publishPasswords(preferLocal: Bool, items: [String: Data]) throws {
        let changedWhileOff = preferLocal ? hostStore.passwordsChangedWhileSyncWasOff : []
        for host in hostStore.hosts where host.authMethod == .password {
            let account = HostStore.passwordAccount(for: host.id)
            guard let password = try deviceSSH.read(account: account) else { continue }
            if let synced = items[account], synced == password || !changedWhileOff.contains(host.id) {
                continue
            }
            try shared.write(password, account: account)
        }
        if preferLocal {
            hostStore.forgetPasswordsChangedWhileSyncWasOff()
        }
    }

    /// Switching off: copies each synced password of a current Host and the
    /// canonical keys to the device-only Keychain. Tries every copy, and
    /// returns the first failure.
    private func keepSyncedSecretsOnDevice() -> (any Error)? {
        var firstFailure: (any Error)?
        func attempt(_ copy: () throws -> Void) {
            do { try copy() } catch { firstFailure = firstFailure ?? error }
        }
        for host in hostStore.hosts where host.authMethod == .password {
            let account = HostStore.passwordAccount(for: host.id)
            attempt {
                if let password = try shared.read(account: account) {
                    try deviceSSH.write(password, account: account)
                }
            }
        }
        attempt {
            try deviceKeys.publishDeviceKey()
            try deviceKeys.adoptCanonicalKey(from: shared)
        }
        attempt {
            try rsaKeys.publishDeviceKey()
            try rsaKeys.adoptCanonicalKey(from: shared)
        }
        return firstFailure
    }

    private static func message(for error: any Error) -> String {
        if case KeychainError.unexpectedStatus(let status) = error {
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
            return "The Keychain refused the change: \(detail)"
        }
        return error.localizedDescription
    }
}
