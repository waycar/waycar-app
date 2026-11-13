import Foundation
import Testing

@testable import Waycar

/// The Back button shows until the user hides it, and hiding it survives
/// relaunch and follows iCloud Sync reloads.
@MainActor
@Suite("Hide Back Button setting")
struct AgentBackButtonSettingsTests {
    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "agent-back-button-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    @Test func aNeverChosenBackButtonIsShown() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = AgentBackButtonSettings(defaults: defaults)

        #expect(!settings.isHidden)
    }

    @Test func aHiddenBackButtonStaysHiddenAcrossLaunches() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = AgentBackButtonSettings(defaults: defaults)

        settings.setHidden(true)
        #expect(settings.isHidden)

        let relaunched = AgentBackButtonSettings(defaults: defaults)
        #expect(relaunched.isHidden)
    }

    @Test func anICloudSyncReloadFollowsTheOtherDevice() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let settings = AgentBackButtonSettings(defaults: defaults)

        defaults.set(true, forKey: AgentBackButtonSettings.defaultsKey)
        settings.reload()
        #expect(settings.isHidden)

        // The other device never chose: back to the default, shown.
        defaults.removeObject(forKey: AgentBackButtonSettings.defaultsKey)
        settings.reload()
        #expect(!settings.isHidden)
    }
}
