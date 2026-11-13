import Foundation
import Testing

@testable import Waycar

/// The one-time removal of the old Launch ledger, on the real Keychain: a
/// synchronizable item and a device-only one, as the ledger kept them.
@Suite("Launch ledger sweep", .serialized)
struct LaunchLedgerSweepTests {
    private let service = "com.otreva.waycar.tests.launches-\(UUID().uuidString)"

    @Test func deletesSyncedAndDeviceOnlyItemsOnceAndRecordsIt() throws {
        let name = "launch-ledger-sweep-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let synced = KeychainSecretStore(service: service, synchronizable: true)
        let device = KeychainSecretStore(service: service)
        defer {
            try? synced.removeSecret(account: "launches.a")
            try? synced.removeSecret(account: "launches.b")
            try? device.removeSecret(account: "deviceID")
        }
        try synced.write(Data("[]".utf8), account: "launches.a")
        try synced.write(Data("[]".utf8), account: "launches.b")
        try device.write(Data("id".utf8), account: "deviceID")

        LaunchLedgerSweep.runOnce(service: service, defaults: defaults)

        #expect(try synced.readAll().isEmpty)
        #expect(try device.readAll().isEmpty)
        #expect(defaults.bool(forKey: LaunchLedgerSweep.doneDefaultsKey))

        // Once only: an item that turns up later is left alone.
        try synced.write(Data("[]".utf8), account: "launches.a")
        LaunchLedgerSweep.runOnce(service: service, defaults: defaults)
        #expect(try synced.read(account: "launches.a") != nil)
    }

    @Test func anEmptyKeychainStillRecordsTheSweep() throws {
        let name = "launch-ledger-sweep-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        LaunchLedgerSweep.runOnce(service: service, defaults: defaults)

        #expect(defaults.bool(forKey: LaunchLedgerSweep.doneDefaultsKey))
    }
}
