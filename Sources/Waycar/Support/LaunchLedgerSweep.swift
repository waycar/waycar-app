import Foundation
import Security

/// Removes the Launch ledger Waycar Pro kept in the Keychain (ADR 0032).
/// Waycar is free and nothing reads it any more, but its synchronizable
/// items would stay in the user's iCloud Keychain for good. Deleting them
/// here deletes them on the user's other devices too.
enum LaunchLedgerSweep {
    /// The ledger's service: one synchronizable item per device and this
    /// device's `ThisDeviceOnly` device id.
    static let service = "com.otreva.waycar.launches"
    static let doneDefaultsKey = "com.otreva.waycar.launches.swept"

    /// Deletes every generic-password item of `service`, synchronizable or
    /// not, once per install. It records that it ran only once the Keychain
    /// answered: before the first unlock it is unreadable, and the next
    /// launch tries again.
    static func runOnce(service: String = service, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: doneDefaultsKey) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { return }
        defaults.set(true, forKey: doneDefaultsKey)
    }
}
