import Foundation
import Security

/// Whether the Host credentials can be read right now, for the launch dial.
///
/// Every Waycar secret is `AfterFirstUnlock` (`KeychainSecretStore.write`):
/// readable on a locked phone, unreadable only between a restart and the
/// first unlock. `UIApplication.isProtectedDataAvailable` reads false for
/// the whole of a locked phone, so gating on it kept a CarPlay launch with
/// the phone in a pocket from ever dialing (docs/design/carplay.md §6). The
/// probe asks the Keychain itself instead.
enum KeychainReadability {
    /// Tries one read of any of this app's generic passwords. Only
    /// `errSecInteractionNotAllowed` says "not yet"; an empty Keychain is
    /// readable, and any other failure is the dial's to report.
    static func isReadable() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        var item: CFTypeRef?
        return isReadable(status: SecItemCopyMatching(query as CFDictionary, &item))
    }

    static func isReadable(status: OSStatus) -> Bool {
        status != errSecInteractionNotAllowed
    }
}
