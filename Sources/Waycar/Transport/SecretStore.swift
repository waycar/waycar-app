import Foundation
import Security

/// Where secret bytes live. The real implementation is the Keychain; the
/// protocol keeps key management testable where the real Keychain is
/// unavailable or flaky (CI without a simulator keychain, previews).
protocol SecretStore: Sendable {
    func read(account: String) throws -> Data?
    /// Every stored secret keyed by account. The Notification Key lookup
    /// selects by a derived key id, so it must be able to walk all entries.
    func readAll() throws -> [String: Data]
    func write(_ secret: Data, account: String) throws
    func removeSecret(account: String) throws
}

/// Process-local secret storage for previews and deterministic development
/// compositions. Nothing is written to the Keychain or survives the process.
final class VolatileSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: Data] = [:]

    func read(account: String) throws -> Data? {
        lock.withLock { secrets[account] }
    }

    func readAll() throws -> [String: Data] {
        lock.withLock { secrets }
    }

    func write(_ secret: Data, account: String) throws {
        lock.withLock { secrets[account] = secret }
    }

    func removeSecret(account: String) throws {
        lock.withLock { secrets[account] = nil }
    }
}

enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}

/// Generic-password Keychain items under one service. By default items are
/// scoped to this device only (`ThisDeviceOnly`): they never migrate to
/// another device through backup or iCloud Keychain. A `synchronizable`
/// store is the exception iCloud Sync (ADR 0019) makes: its items sync
/// end-to-end encrypted through the user's iCloud Keychain, which requires
/// dropping `ThisDeviceOnly` for them.
///
/// An optional access group shares the items with other targets of this app
/// — the Notification Service Extension reads Notification Keys through the
/// app-group access group, which iOS accepts in `kSecAttrAccessGroup`
/// without the team id prefix.
struct KeychainSecretStore: SecretStore {
    let service: String
    var accessGroup: String?
    var synchronizable = false

    init(service: String, accessGroup: String? = nil, synchronizable: Bool = false) {
        self.service = service
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
    }

    func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func readAll() throws -> [String: Data] {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        switch status {
        case errSecSuccess:
            var secrets: [String: Data] = [:]
            for item in items as? [[String: Any]] ?? [] {
                guard let account = item[kSecAttrAccount as String] as? String,
                    let data = item[kSecValueData as String] as? Data
                else { continue }
                secrets[account] = data
            }
            return secrets
        case errSecItemNotFound:
            return [:]
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func write(_ secret: Data, account: String) throws {
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrAccessible as String] =
            synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = [kSecValueData as String: secret]
            let updateStatus = SecItemUpdate(
                baseQuery(account: account) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func removeSecret(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        // Part of the item's identity: a synced item and a device-only item
        // under the same service and account are two different items. Left
        // out for device-only stores, which Apple defines as the default.
        if synchronizable {
            query[kSecAttrSynchronizable as String] = kCFBooleanTrue
        }
        return query
    }
}
