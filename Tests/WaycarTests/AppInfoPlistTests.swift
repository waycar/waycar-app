import Foundation
import Testing

@testable import Waycar

/// The purpose strings and declarations the compiled app ships with. Read
/// raw from the bundle's Info.plist, where the build settings land, so a
/// regenerated project that drops one fails here instead of at runtime.
@Suite("App Info.plist")
struct AppInfoPlistTests {
    private func infoPlist() throws -> [String: Any] {
        let url = try #require(Bundle.main.url(forResource: "Info", withExtension: "plist"))
        return try #require(NSDictionary(contentsOf: url) as? [String: Any])
    }

    /// Quick Look's Save Image and Save Video need it.
    @Test func declaresWhyItAddsToThePhotoLibrary() throws {
        let purpose = try infoPlist()["NSPhotoLibraryAddUsageDescription"] as? String
        #expect(purpose?.isEmpty == false)
    }

    /// An iPad asks with the same string and never connects to CarPlay, so
    /// it names no CarPlay.
    @Test func theMicrophonePurposeNamesNoCarPlay() throws {
        let purpose = try #require(try infoPlist()["NSMicrophoneUsageDescription"] as? String)
        #expect(!purpose.isEmpty)
        #expect(!purpose.localizedCaseInsensitiveContains("carplay"))
    }

    /// Find Computers browses SSH only, never backend or unrelated services.
    @Test func declaresOnlySSHBonjour() throws {
        #expect(try infoPlist()["NSBonjourServices"] as? [String] == ["_ssh._tcp"])
        #expect(try infoPlist()["NSLocalNetworkUsageDescription"] as? String
            == "Waycar finds computers on your network that have SSH on, and connects to them over SSH and mosh.")
    }
}
