import Foundation
import Testing

@testable import Waycar

/// The AI summaries setting is off until the user opts in, and an explicit
/// choice either way survives relaunch and iCloud Sync reloads.
@MainActor
@Suite("AI summaries setting")
struct AgentSummarySettingsTests {
    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "agent-summaries-\(UUID().uuidString)"))
    }

    @Test func aNeverChosenSettingIsOff() throws {
        let settings = AgentSummarySettings(defaults: try makeDefaults())

        #expect(settings.choice == nil)
        #expect(!settings.isEnabled)
    }

    @Test func anEarlierOptInStaysOnAcrossLaunches() throws {
        let defaults = try makeDefaults()
        defaults.set(true, forKey: AgentSummarySettings.defaultsKey)

        let relaunched = AgentSummarySettings(defaults: defaults)
        #expect(relaunched.choice == true)
        #expect(relaunched.isEnabled)
    }

    @Test func anExplicitOffStaysOffAcrossLaunches() throws {
        let defaults = try makeDefaults()
        let settings = AgentSummarySettings(defaults: defaults)
        settings.setEnabled(false)
        #expect(!settings.needsChoice)

        let relaunched = AgentSummarySettings(defaults: defaults)
        #expect(relaunched.choice == false)
        #expect(!relaunched.isEnabled)
        #expect(!relaunched.needsChoice)
    }

    @Test func anICloudSyncReloadFollowsTheOtherDevice() throws {
        let defaults = try makeDefaults()
        let settings = AgentSummarySettings(defaults: defaults)

        defaults.set(true, forKey: AgentSummarySettings.defaultsKey)
        settings.reload()
        #expect(settings.isEnabled)

        // The other device never chose: back to the default, off.
        defaults.removeObject(forKey: AgentSummarySettings.defaultsKey)
        settings.reload()
        #expect(!settings.isEnabled)
    }
}
