import Foundation
import Testing

@testable import Waycar

@MainActor
struct EdgeDockSettingsTests {
    private func makeDefaults() throws -> UserDefaults {
        let suite = "EdgeDockSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func startsAtTheControlsDefaultUntilMoved() throws {
        let settings = EdgeDockSettings(defaults: try makeDefaults())
        #expect(settings.fraction(for: .messageJump) == 1)
    }

    @Test func remembersWhereTheControlWasDockedAcrossLaunches() throws {
        let defaults = try makeDefaults()
        let settings = EdgeDockSettings(defaults: defaults)
        settings.setFraction(0.75, for: .messageJump)
        #expect(settings.fraction(for: .messageJump) == 0.75)

        let relaunched = EdgeDockSettings(defaults: defaults)
        #expect(relaunched.fraction(for: .messageJump) == 0.75)
    }

    @Test func clampsToTheEdgeAndRejectsUnreadableValues() throws {
        let settings = EdgeDockSettings(defaults: try makeDefaults())
        settings.setFraction(1.4, for: .messageJump)
        #expect(settings.fraction(for: .messageJump) == 1)
        settings.setFraction(-3, for: .messageJump)
        #expect(settings.fraction(for: .messageJump) == 0)
        settings.setFraction(0.5, for: .messageJump)
        settings.setFraction(.nan, for: .messageJump)
        #expect(settings.fraction(for: .messageJump) == 0)
        #expect(EdgeDockSettings.clamped(.infinity) == 0)
    }

    @Test func liftTurnsPointsOfTravelIntoAFractionOfTheEdge() {
        typealias Coordinator = MessageJumpChromeOverlay.Coordinator
        #expect(Coordinator.fraction(base: 1, travel: -100, edgeTravel: 400) == 0.75)
        #expect(Coordinator.fraction(base: 0.5, travel: 400, edgeTravel: 400) == 1,
                "Dragging past the band docks at the lowest position")
        #expect(Coordinator.fraction(base: 0.5, travel: 50, edgeTravel: 0) == 0.5,
                "No room to slide: the chrome stays put")
    }
}
